//! `services/followup_tickets.py`: implementation-ticket proposals derived
//! from a spike's findings, and their durable review state.
//!
//! The store opens the database the Python daemon writes, with the same
//! schema text, rows and `json.dumps(draft, sort_keys=True)` drafts. One
//! difference is deliberate: `create_or_get` checks for an existing batch
//! inside its `BEGIN IMMEDIATE` transaction, where Python checks before it.
//! Without contention the results are the same; under contention a second
//! writer reads the first one's batch instead of failing on its primary key.

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fancy_regex::Regex;
use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern;
use relay_intents::sha256::hex_digest;
use rusqlite::{Connection, OptionalExtension, params};

use crate::{Error, Result, paths, pystr};

static PRIVATE_CONTENT: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"\b(raw\s+(?:provider\s+)?transcript|chain[- ]of[- ]thought|hidden\s+reasoning|scratchpad|system\s+prompt|tool\s+log)\b|\b(?:sk|ghp|github_pat)-[A-Za-z0-9_-]{12,}\b|BEGIN [A-Z ]*PRIVATE KEY",
        true,
    )
});
static WHITESPACE_RUN: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"\s+", false));
// re.MULTILINE | re.DOTALL | re.IGNORECASE, so `$` and `^` work per line
// and `\Z` is the end of the text.
static NEXT_STEPS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ims)^\*\*Recommended next steps\*\*[\s\x1c-\x1f]*\n(.*?)(?=^\*\*[^\n]+\*\*[\s\x1c-\x1f]*$|^## |\z)",
    )
    .expect("next steps pattern")
});
static BULLET: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"^\s*[-*]\s+(.+?)\s*$", false));

pub const FOLLOWUP_KEY_PREFIX: &str = "relay-spike-followup-key:";
pub const PROPOSAL_STATES: [&str; 3] = ["draft", "accepted", "rejected"];
pub const PRIORITIES: [&str; 4] = ["urgent", "high", "medium", "low"];
pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// `_clean_text`. `value` is `None` for a missing key.
fn clean_text(value: Option<&Value>, field: &str, multiline: bool) -> Result<String> {
    let raw = value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default();
    let raw = pystr::strip(&raw);
    if raw.is_empty() {
        return Err(Error::value(format!("{field} is required")));
    }
    let text = if multiline {
        raw.to_string()
    } else {
        WHITESPACE_RUN.replace_all(raw, " ").into_owned()
    };
    if pattern::search(&PRIVATE_CONTENT, &text) {
        return Err(Error::value(format!(
            "{field} contains private provider or secret material"
        )));
    }
    Ok(text)
}

/// `_clean_text(value or default, field)`.
fn clean_text_or(value: Option<&Value>, default: &str, field: &str) -> Result<String> {
    let fallback = Value::Str(default.to_string());
    clean_text(
        Some(value.filter(|value| value.truthy()).unwrap_or(&fallback)),
        field,
        false,
    )
}

fn string_list(value: Option<&Value>, field: &str) -> Result<Vec<String>> {
    let Some(Value::List(items)) = value else {
        return Err(Error::value(format!("{field} must be a list")));
    };
    let mut result = Vec::new();
    for item in items {
        let text = if item.truthy() {
            item.py_str()
        } else {
            String::new()
        };
        if !pystr::strip(&text).is_empty() {
            result.push(clean_text(Some(item), field, false)?);
        }
    }
    if result.is_empty() {
        return Err(Error::value(format!("{field} must be a non-empty list")));
    }
    Ok(result)
}

/// `str(value or default).strip().lower()`.
fn lowered(value: Option<&Value>, default: &str) -> String {
    let text = value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_else(|| default.to_string());
    pystr::strip(&text).to_lowercase()
}

/// `sanitize_followup_draft`.
pub fn sanitize_followup_draft(value: &Value, origin_repo_path: &str) -> Result<Dict> {
    let Some(value) = value.as_dict() else {
        return Err(Error::value("each follow-up proposal must be an object"));
    };
    let priority = lowered(value.get("priority"), "medium");
    if !PRIORITIES.contains(&priority.as_str()) {
        return Err(Error::value(format!(
            "invalid follow-up priority: {}",
            pystr::repr(&priority)
        )));
    }
    let model = clean_text_or(value.get("worker_model"), "balanced", "worker_model")?;
    let effort = lowered(value.get("worker_effort"), "medium");
    if !EFFORTS.contains(&effort.as_str()) {
        return Err(Error::value(format!(
            "invalid follow-up worker_effort: {}",
            pystr::repr(&effort)
        )));
    }
    if effort == "max" && !model.to_lowercase().starts_with("claude:") {
        return Err(Error::value(
            "worker_effort max requires an explicitly Claude-scoped worker_model",
        ));
    }
    let dependencies = match value.get("depends_on") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::List(items)) => items.clone(),
        Some(_) => return Err(Error::value("depends_on must be a list")),
    };
    let title: String = clean_text(value.get("title"), "title", false)?
        .chars()
        .take(120)
        .collect();
    let description = clean_text(value.get("description"), "description", true)?;
    let criteria = string_list(value.get("acceptance_criteria"), "acceptance_criteria")?;
    let depends_on: Vec<Value> = dependencies
        .iter()
        .map(|item| pystr::strip(&item.py_str()).to_uppercase())
        .filter(|item| !item.is_empty())
        .map(Value::Str)
        .collect();
    let rationale = clean_text_or(
        value.get("worker_sizing_rationale"),
        "Spike follow-up uses balanced sizing until the user refines the implementation scope.",
        "worker_sizing_rationale",
    )?;
    let notes = clean_text_or(
        value.get("worker_provider_notes"),
        "Codex and Claude must implement the same accepted ticket contract.",
        "worker_provider_notes",
    )?;
    let target = match value.truthy("target_repo_path") {
        Some(Value::Str(path)) => path.clone(),
        // `Path()` refuses anything but a string with TypeError.
        Some(other) => {
            return Err(Error::new(
                crate::ErrorKind::Type,
                format!(
                    "argument should be a str or an os.PathLike object where __fspath__ returns a str, not '{}'",
                    pystr::type_name(other)
                ),
            ));
        }
        None => origin_repo_path.to_string(),
    };
    let target = paths::resolve(&paths::expanduser(&target)?);
    let mut draft = Dict::new();
    draft.insert("title", title);
    draft.insert("description", description);
    draft.insert(
        "acceptance_criteria",
        criteria.into_iter().map(Value::Str).collect::<Vec<_>>(),
    );
    draft.insert("priority", priority);
    draft.insert("depends_on", depends_on);
    draft.insert("worker_model", model);
    draft.insert("worker_effort", effort);
    draft.insert("worker_sizing_rationale", rationale);
    draft.insert("worker_provider_notes", notes);
    draft.insert("target_repo_path", target);
    Ok(draft)
}

/// `recommended_next_steps`: the bullets under a spike report's
/// `**Recommended next steps**` heading.
pub fn recommended_next_steps(spike_body: &str) -> Result<Vec<String>> {
    let Some(found) = NEXT_STEPS.captures(spike_body).ok().flatten() else {
        return Ok(Vec::new());
    };
    let mut steps = Vec::new();
    for line in pystr::splitlines(&found[1]) {
        if let Some(item) = pattern::group(&BULLET, line, 1) {
            let item = clean_text(
                Some(&Value::Str(item.to_string())),
                "recommended next step",
                false,
            )?;
            if !item.to_lowercase().starts_with("no follow-up recommended") {
                steps.push(item);
            }
        }
    }
    Ok(steps)
}

/// `automatic_followup_drafts`: one sanitized draft per recommendation.
pub fn automatic_followup_drafts(spike_body: &str, origin_repo_path: &str) -> Result<Vec<Dict>> {
    let mut drafts = Vec::new();
    for recommendation in recommended_next_steps(spike_body)? {
        let mut title = recommendation.trim_end_matches('.').to_string();
        if title.chars().count() > 76 {
            let shortened: String = title.chars().take(73).collect();
            title = format!("{}...", shortened.trim_end_matches(pystr::is_space));
        }
        let mut draft = Dict::new();
        draft.insert("title", title);
        draft.insert("description", recommendation.as_str());
        draft.insert(
            "acceptance_criteria",
            vec![
                Value::Str(format!(
                    "The accepted spike recommendation is implemented: {recommendation}"
                )),
                Value::from("Focused verification covers the changed behavior."),
                Value::from(
                    "The run log records the implementation outcome and any remaining uncertainty.",
                ),
            ],
        );
        draft.insert("priority", "medium");
        draft.insert("depends_on", Vec::<Value>::new());
        draft.insert("worker_model", "balanced");
        draft.insert("worker_effort", "medium");
        draft.insert(
            "worker_sizing_rationale",
            "Automatically proposed from a completed spike; review and adjust sizing before acceptance.",
        );
        draft.insert(
            "worker_provider_notes",
            "Codex uses model_reasoning_effort and Claude uses --effort while preserving the same ticket outcome.",
        );
        draft.insert("target_repo_path", origin_repo_path);
        drafts.push(sanitize_followup_draft(
            &Value::Dict(draft),
            origin_repo_path,
        )?);
    }
    Ok(drafts)
}

/// `batch_id`: stable per origin repository, ticket and run.
pub fn batch_id(origin_repo_path: &str, origin_ticket_id: &str, origin_run_id: i64) -> String {
    let canonical = format!(
        "{}\0{}\0{origin_run_id}",
        paths::resolve(origin_repo_path),
        origin_ticket_id.to_uppercase()
    );
    format!("spike-{}", &hex_digest(canonical.as_bytes())[..24])
}

/// `proposal_id`.
pub fn proposal_id(batch: &str, position: usize) -> String {
    format!(
        "proposal-{}",
        &hex_digest(format!("{batch}\0{position}").as_bytes())[..16]
    )
}

/// `acceptance_key`.
pub fn acceptance_key(batch: &str, proposal: &str) -> String {
    hex_digest(format!("{batch}\0{proposal}").as_bytes())
}

/// `FollowupProposalStore.SCHEMA`, byte for byte: SQLite keeps each
/// statement's text, and either daemon may create the database.
const SCHEMA: &str = "\n    CREATE TABLE IF NOT EXISTS batches (\n        id TEXT PRIMARY KEY,\n        origin_repo_path TEXT NOT NULL,\n        origin_ticket_id TEXT NOT NULL,\n        origin_run_id INTEGER NOT NULL,\n        provider_key TEXT,\n        created_at REAL NOT NULL,\n        updated_at REAL NOT NULL\n    );\n    CREATE TABLE IF NOT EXISTS proposals (\n        id TEXT PRIMARY KEY,\n        batch_id TEXT NOT NULL,\n        position INTEGER NOT NULL,\n        state TEXT NOT NULL,\n        draft_json TEXT NOT NULL,\n        ticket_id TEXT,\n        error TEXT,\n        updated_at REAL NOT NULL,\n        UNIQUE(batch_id, position)\n    );\n    CREATE INDEX IF NOT EXISTS idx_followup_proposals_batch ON proposals(batch_id, position);\n    ";

/// Python's `sqlite3.connect` default timeout.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `FollowupProposalStore`: one connection per call, serialized per store.
pub struct FollowupProposalStore {
    path: PathBuf,
    lock: Mutex<()>,
}

fn column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Value> {
    use rusqlite::types::ValueRef;
    Ok(match row.get_ref(index)? {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(number) => Value::Int(number),
        ValueRef::Real(number) => Value::Float(number),
        ValueRef::Text(text) | ValueRef::Blob(text) => {
            Value::Str(String::from_utf8_lossy(text).into_owned())
        }
    })
}

fn row_dict(row: &rusqlite::Row<'_>) -> rusqlite::Result<Dict> {
    let mut dict = Dict::new();
    for index in 0..row.as_ref().column_count() {
        let name = row.as_ref().column_name(index)?.to_string();
        dict.insert(&name, column(row, index)?);
    }
    Ok(dict)
}

impl FollowupProposalStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let store = Self {
            path: path.to_path_buf(),
            lock: Mutex::new(()),
        };
        store.with_connection(|connection| Ok(connection.execute_batch(SCHEMA)?))?;
        Ok(store)
    }

    fn with_connection<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let _guard = self
            .lock
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let connection = Connection::open(&self.path)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        work(&connection)
    }

    /// `create_or_get`: the batch, and whether this call created it.
    pub fn create_or_get(
        &self,
        origin_repo_path: &str,
        origin_ticket_id: &str,
        origin_run_id: i64,
        provider_key: Option<&str>,
        drafts: &[Dict],
    ) -> Result<(Dict, bool)> {
        let identifier = batch_id(origin_repo_path, origin_ticket_id, origin_run_id);
        let now = now();
        self.with_connection(|connection| {
            connection.execute_batch("BEGIN IMMEDIATE")?;
            let result = (|| -> Result<bool> {
                if exists(connection, &identifier)? {
                    return Ok(false);
                }
                connection.execute(
                    "INSERT INTO batches VALUES (?, ?, ?, ?, ?, ?, ?)",
                    params![
                        identifier,
                        origin_repo_path,
                        origin_ticket_id,
                        origin_run_id,
                        provider_key,
                        now,
                        now
                    ],
                )?;
                for (position, draft) in drafts.iter().enumerate() {
                    connection.execute(
                        "INSERT INTO proposals VALUES (?, ?, ?, 'draft', ?, NULL, NULL, ?)",
                        params![
                            proposal_id(&identifier, position),
                            identifier,
                            position as i64,
                            json::dumps_sorted(&Value::Dict(draft.clone())),
                            now
                        ],
                    )?;
                }
                Ok(true)
            })();
            match result {
                Ok(created) => {
                    connection.execute_batch("COMMIT")?;
                    Ok((batch(connection, &identifier)?, created))
                }
                Err(error) => {
                    let _ = connection.execute_batch("ROLLBACK");
                    Err(error)
                }
            }
        })
    }

    pub fn get(&self, identifier: &str) -> Result<Option<Dict>> {
        self.with_connection(|connection| {
            if exists(connection, identifier)? {
                Ok(Some(batch(connection, identifier)?))
            } else {
                Ok(None)
            }
        })
    }

    pub fn update_draft(&self, identifier: &str, proposal: &str, draft: &Dict) -> Result<Dict> {
        let now = now();
        self.with_connection(|connection| {
            let state: Option<String> = connection
                .query_row(
                    "SELECT state FROM proposals WHERE batch_id = ? AND id = ?",
                    params![identifier, proposal],
                    |row| row.get(0),
                )
                .optional()?;
            match state.as_deref() {
                None => {
                    return Err(Error::value(format!(
                        "follow-up proposal {proposal} not found"
                    )));
                }
                Some("draft") => {}
                Some(state) => {
                    return Err(Error::value(format!(
                        "follow-up proposal {proposal} is already {state}"
                    )));
                }
            }
            connection.execute(
                "UPDATE proposals SET draft_json = ?, error = NULL, updated_at = ? WHERE id = ?",
                params![
                    json::dumps_sorted(&Value::Dict(draft.clone())),
                    now,
                    proposal
                ],
            )?;
            connection.execute(
                "UPDATE batches SET updated_at = ? WHERE id = ?",
                params![now, identifier],
            )?;
            batch(connection, identifier)
        })
    }

    pub fn set_result(
        &self,
        identifier: &str,
        proposal: &str,
        state: &str,
        ticket_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<Dict> {
        if !PROPOSAL_STATES.contains(&state) {
            return Err(Error::value(format!(
                "invalid follow-up proposal state: {state}"
            )));
        }
        let now = now();
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE proposals SET state = ?, ticket_id = ?, error = ?, updated_at = ? \
                 WHERE batch_id = ? AND id = ?",
                params![state, ticket_id, error, now, identifier, proposal],
            )?;
            if changed == 0 {
                return Err(Error::value(format!(
                    "follow-up proposal {proposal} not found"
                )));
            }
            connection.execute(
                "UPDATE batches SET updated_at = ? WHERE id = ?",
                params![now, identifier],
            )?;
            batch(connection, identifier)
        })
    }

    pub fn set_error(&self, identifier: &str, proposal: &str, error: &str) -> Result<Dict> {
        let now = now();
        self.with_connection(|connection| {
            connection.execute(
                "UPDATE proposals SET error = ?, updated_at = ? WHERE batch_id = ? AND id = ?",
                params![error, now, identifier, proposal],
            )?;
            connection.execute(
                "UPDATE batches SET updated_at = ? WHERE id = ?",
                params![now, identifier],
            )?;
            batch(connection, identifier)
        })
    }
}

fn exists(connection: &Connection, identifier: &str) -> Result<bool> {
    Ok(connection
        .query_row("SELECT 1 FROM batches WHERE id = ?", [identifier], |_| {
            Ok(())
        })
        .optional()?
        .is_some())
}

/// `_get`: the batch row with its proposals, each draft decoded.
fn batch(connection: &Connection, identifier: &str) -> Result<Dict> {
    let mut payload = connection
        .query_row("SELECT * FROM batches WHERE id = ?", [identifier], row_dict)
        .optional()?
        .ok_or_else(|| Error::value(format!("follow-up batch {identifier} not found")))?;
    let mut statement =
        connection.prepare("SELECT * FROM proposals WHERE batch_id = ? ORDER BY position")?;
    let rows = statement.query_map([identifier], row_dict)?;
    let mut proposals = Vec::new();
    for row in rows {
        let mut proposal = row?;
        let draft = proposal
            .remove("draft_json")
            .and_then(|text| text.as_str().and_then(json::parse))
            .ok_or_else(|| Error::value("follow-up proposal draft_json is invalid JSON"))?;
        proposal.insert("draft", draft);
        proposals.push(Value::Dict(proposal));
    }
    payload.insert("proposals", proposals);
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_steps_follow_the_heading() {
        let body = "## Spike report\n\n**Recommended next steps**\n\n- Port the thing.\n  * Measure it  \n\
                    -nospace\n- No follow-up recommended here\n\n**Uncertainties**\n- Not a step\n";
        assert_eq!(
            recommended_next_steps(body).unwrap(),
            ["Port the thing.", "Measure it"]
        );
        assert!(
            recommended_next_steps("**Recommended next steps**")
                .unwrap()
                .is_empty()
        );
        assert!(recommended_next_steps("- step\n").unwrap().is_empty());
    }

    #[test]
    fn drafts_refuse_private_material() {
        let draft = json::parse(
            r#"{"title": "Review the raw  transcript", "description": "d", "acceptance_criteria": ["a"]}"#,
        )
        .unwrap();
        assert_eq!(
            sanitize_followup_draft(&draft, "/tmp").unwrap_err().message,
            "title contains private provider or secret material"
        );
    }

    #[test]
    fn identities_are_stable_digests() {
        let batch = batch_id("/", "rr-1", 7);
        assert_eq!(
            batch,
            format!("spike-{}", &hex_digest(b"/\0RR-1\x007")[..24])
        );
        assert_eq!(proposal_id(&batch, 0).len(), "proposal-".len() + 16);
    }
}
