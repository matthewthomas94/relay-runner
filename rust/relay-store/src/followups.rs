//! `followup_proposals.db`: `FollowupProposalStore` in
//! `services/followup_tickets.py`, durable proposal state for tickets derived
//! from a spike's findings. Drafts arrive already sanitised
//! (`sanitize_followup_draft` stays with the caller).

use std::path::Path;

use rusqlite::Connection;

use relay_intents::json;
use relay_intents::sha256::hex_digest;

use crate::sql::{self, DEFAULT_TIMEOUT, Db, int, opt_text, real, text};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS batches (
        id TEXT PRIMARY KEY,
        origin_repo_path TEXT NOT NULL,
        origin_ticket_id TEXT NOT NULL,
        origin_run_id INTEGER NOT NULL,
        provider_key TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY,
        batch_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(batch_id, position)
    );
    CREATE INDEX IF NOT EXISTS idx_followup_proposals_batch ON proposals(batch_id, position);
    ";

pub const PROPOSAL_STATES: [&str; 3] = ["accepted", "draft", "rejected"];

/// `batch_id`: one batch per resolved origin repository, ticket and run.
pub fn batch_id(origin_repo_path: &str, origin_ticket_id: &str, origin_run_id: i64) -> String {
    let canonical = format!(
        "{}\0{}\0{origin_run_id}",
        sql::resolve(origin_repo_path),
        origin_ticket_id.to_uppercase()
    );
    format!("spike-{}", &hex_digest(canonical.as_bytes())[..24])
}

pub fn proposal_id(batch: &str, position: i64) -> String {
    format!(
        "proposal-{}",
        &hex_digest(format!("{batch}\0{position}").as_bytes())[..16]
    )
}

pub fn acceptance_key(batch: &str, proposal: &str) -> String {
    hex_digest(format!("{batch}\0{proposal}").as_bytes())
}

pub struct FollowupProposalStore {
    db: Db,
}

impl FollowupProposalStore {
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(|c| Ok(c.execute_batch(SCHEMA)?))?;
        Ok(store)
    }

    /// The origin run's batch, created with `drafts` as its proposals when it
    /// does not exist yet. The flag says whether it was created.
    pub fn create_or_get(
        &self,
        origin_repo_path: &str,
        origin_ticket_id: &str,
        origin_run_id: i64,
        provider_key: Option<&str>,
        drafts: &[Dict],
    ) -> Result<(Dict, bool)> {
        let identifier = batch_id(origin_repo_path, origin_ticket_id, origin_run_id);
        let now = sql::now();
        self.db.with(|c| {
            if sql::row(
                c,
                "SELECT 1 FROM batches WHERE id = ?",
                &[text(&identifier)],
            )?
            .is_some()
            {
                return Ok((get_batch(c, &identifier)?, false));
            }
            sql::transaction(c, "BEGIN IMMEDIATE", || {
                sql::execute(
                    c,
                    "INSERT INTO batches VALUES (?, ?, ?, ?, ?, ?, ?)",
                    &[
                        text(&identifier),
                        text(origin_repo_path),
                        text(origin_ticket_id),
                        int(origin_run_id),
                        opt_text(provider_key),
                        real(now),
                        real(now),
                    ],
                )?;
                for (position, draft) in drafts.iter().enumerate() {
                    let position = position as i64;
                    sql::execute(
                        c,
                        "INSERT INTO proposals VALUES (?, ?, ?, 'draft', ?, NULL, NULL, ?)",
                        &[
                            text(proposal_id(&identifier, position)),
                            text(&identifier),
                            int(position),
                            text(json::dumps_sorted(&Value::Dict(draft.clone()))),
                            real(now),
                        ],
                    )?;
                }
                Ok(())
            })?;
            Ok((get_batch(c, &identifier)?, true))
        })
    }

    pub fn get(&self, identifier: &str) -> Result<Option<Dict>> {
        self.db.with(|c| {
            if sql::row(c, "SELECT 1 FROM batches WHERE id = ?", &[text(identifier)])?.is_none() {
                return Ok(None);
            }
            get_batch(c, identifier).map(Some)
        })
    }

    /// Replaces a draft proposal's draft; refuses one already decided.
    pub fn update_draft(&self, identifier: &str, proposal: &str, draft: &Dict) -> Result<Dict> {
        let now = sql::now();
        self.db.with(|c| {
            let current = sql::row(
                c,
                "SELECT state FROM proposals WHERE batch_id = ? AND id = ?",
                &[text(identifier), text(proposal)],
            )?
            .ok_or_else(|| Error::invalid(format!("follow-up proposal {proposal} not found")))?;
            let state = sql::field_str(&current, "state");
            if state != "draft" {
                return Err(Error::invalid(format!(
                    "follow-up proposal {proposal} is already {state}"
                )));
            }
            sql::execute(
                c,
                "UPDATE proposals SET draft_json = ?, error = NULL, updated_at = ? WHERE id = ?",
                &[
                    text(json::dumps_sorted(&Value::Dict(draft.clone()))),
                    real(now),
                    text(proposal),
                ],
            )?;
            touch(c, identifier, now)?;
            get_batch(c, identifier)
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
            return Err(Error::invalid(format!(
                "invalid follow-up proposal state: {state}"
            )));
        }
        let now = sql::now();
        self.db.with(|c| {
            let changed = sql::execute(
                c,
                "UPDATE proposals SET state = ?, ticket_id = ?, error = ?, updated_at = ? \
                 WHERE batch_id = ? AND id = ?",
                &[
                    text(state),
                    opt_text(ticket_id),
                    opt_text(error),
                    real(now),
                    text(identifier),
                    text(proposal),
                ],
            )?;
            if changed == 0 {
                return Err(Error::invalid(format!(
                    "follow-up proposal {proposal} not found"
                )));
            }
            touch(c, identifier, now)?;
            get_batch(c, identifier)
        })
    }

    pub fn set_error(&self, identifier: &str, proposal: &str, error: &str) -> Result<Dict> {
        let now = sql::now();
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE proposals SET error = ?, updated_at = ? WHERE batch_id = ? AND id = ?",
                &[text(error), real(now), text(identifier), text(proposal)],
            )?;
            touch(c, identifier, now)?;
            get_batch(c, identifier)
        })
    }
}

fn touch(c: &Connection, identifier: &str, now: f64) -> Result<()> {
    sql::execute(
        c,
        "UPDATE batches SET updated_at = ? WHERE id = ?",
        &[real(now), text(identifier)],
    )?;
    Ok(())
}

/// `_get`: the batch row with its proposals, each draft decoded.
fn get_batch(c: &Connection, identifier: &str) -> Result<Dict> {
    let mut payload = sql::row(c, "SELECT * FROM batches WHERE id = ?", &[text(identifier)])?
        .ok_or_else(|| Error::invalid(format!("follow-up batch {identifier} not found")))?;
    let proposals = sql::rows(
        c,
        "SELECT * FROM proposals WHERE batch_id = ? ORDER BY position",
        &[text(identifier)],
    )?;
    payload.insert(
        "proposals",
        Value::List(
            proposals
                .into_iter()
                .map(decode_draft)
                .collect::<Result<Vec<_>>>()?,
        ),
    );
    Ok(payload)
}

/// A proposal row with `draft_json` decoded into a trailing `draft`.
pub(crate) fn decode_draft(mut row: Dict) -> Result<Value> {
    let raw = row
        .remove("draft_json")
        .map(|raw| raw.py_str())
        .unwrap_or_default();
    row.insert("draft", sql::loads(&raw, "draft_json")?);
    Ok(Value::Dict(row))
}
