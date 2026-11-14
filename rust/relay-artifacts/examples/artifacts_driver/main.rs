//! A test driver for the crate: one JSON request per stdin line, one JSON
//! answer per stdout line. `tests/relay_artifacts_support.py` runs the same
//! scenarios through it and through the Python modules, on one data root.
//!
//! A request is `{"op": "<module>.<function>", ...arguments}`; the answer is
//! `{"ok": true, "result": ...}` or `{"ok": false, "error": "<Python class>",
//! "message": "<str(exception)>"}`. Bytes travel as lowercase hex. A TOML
//! integer outside `i64` is `{"$bigint": "<digits>"}` and a TOML date or
//! time `{"$datetime": "<str()>"}`, as the Python side writes them.
//! It is an example, so `cargo test` builds it and no release ships it.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use relay_artifacts::followup::{self, FollowupProposalStore};
use relay_artifacts::store::{self, ArtifactStore, Mutation, Operation, StoreOptions};
use relay_artifacts::tickets::{self, Fields, Ticket, TicketDocument};
use relay_artifacts::{Error, ErrorKind, board_config, catalog, config, isotime, notes, toml};
use relay_intents::json::{self, Dict, Value};

pub(crate) type Answer = Result<Value, Error>;

mod lifecycle;
mod migration;
mod retention;
mod rollout;
mod sync;
mod verification;

pub(crate) fn invalid(message: &str) -> Error {
    Error::new(ErrorKind::Value, message)
}

pub(crate) fn text(request: &Dict, key: &str) -> String {
    request
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

pub(crate) fn optional_text(request: &Dict, key: &str) -> Option<String> {
    request.get(key).and_then(Value::as_str).map(str::to_string)
}

pub(crate) fn integer(request: &Dict, key: &str) -> Option<i64> {
    request.present(key).and_then(Value::py_int)
}

pub(crate) fn dict(request: &Dict, key: &str) -> Dict {
    request
        .get(key)
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default()
}

pub(crate) fn dicts(request: &Dict, key: &str) -> Vec<Dict> {
    request
        .get(key)
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .cloned()
        .collect()
}

pub(crate) fn hex(bytes: &[u8]) -> Value {
    Value::Str(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) fn unhex(request: &Dict, key: &str) -> Result<Vec<u8>, Error> {
    let digits = text(request, key);
    if !digits.len().is_multiple_of(2) {
        return Err(invalid("odd hex length"));
    }
    (0..digits.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&digits[index..index + 2], 16).map_err(|_| invalid("bad hex"))
        })
        .collect()
}

pub(crate) fn strings(values: &[String]) -> Value {
    Value::List(
        values
            .iter()
            .map(|value| Value::Str(value.clone()))
            .collect(),
    )
}

pub(crate) fn operation(request: &Dict) -> Result<Operation, Error> {
    let t = |key: &str| text(request, key);
    Ok(match t("type").as_str() {
        "TicketWrite" => Operation::TicketWrite {
            ticket_id: t("ticket_id"),
            artifact_id: t("artifact_id"),
            markdown: unhex(request, "markdown")?,
        },
        "TicketDelete" => Operation::TicketDelete {
            ticket_id: t("ticket_id"),
        },
        "NoteWrite" => Operation::NoteWrite {
            note_id: t("note_id"),
            artifact_id: t("artifact_id"),
            project_id: t("project_id"),
            markdown: unhex(request, "markdown")?,
        },
        "NoteDelete" => Operation::NoteDelete {
            note_id: t("note_id"),
            artifact_id: t("artifact_id"),
        },
        "NoteIndexWrite" => Operation::NoteIndexWrite {
            content: unhex(request, "content")?,
        },
        "AttachmentWrite" => Operation::AttachmentWrite {
            ticket_id: t("ticket_id"),
            filename: t("filename"),
            mime_type: t("mime_type"),
            content: unhex(request, "content")?,
        },
        "AttachmentDelete" => Operation::AttachmentDelete {
            ticket_id: t("ticket_id"),
            filename: t("filename"),
        },
        "ConfigWrite" => Operation::ConfigWrite {
            content: unhex(request, "content")?,
        },
        "ArchiveIndexWrite" => Operation::ArchiveIndexWrite {
            content: unhex(request, "content")?,
        },
        "ProgramEventWrite" => Operation::ProgramEventWrite {
            event_id: t("event_id"),
            content: unhex(request, "content")?,
        },
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}

pub(crate) fn mutation(request: &Dict) -> Result<Mutation, Error> {
    let source = dict(request, "mutation");
    let operations = dicts(&source, "operations")
        .iter()
        .map(operation)
        .collect::<Result<Vec<_>, _>>()?;
    let mut mutation = Mutation::new(
        &text(&source, "event_id"),
        &text(&source, "actor_type"),
        &text(&source, "device_id"),
        operations,
    );
    mutation.expected_base = optional_text(&source, "expected_base");
    mutation.provider = optional_text(&source, "provider");
    if let Some(summary) = optional_text(&source, "summary") {
        mutation.summary = summary;
    }
    Ok(mutation)
}

pub(crate) fn write_result(result: store::WriteResult) -> Value {
    let mut value = Dict::new();
    value.insert("event_id", result.event_id);
    value.insert("commit_id", result.commit_id);
    value.insert("tree_id", result.tree_id);
    value.insert("base_commit", result.base_commit);
    value.insert("idempotent", result.idempotent);
    value.insert("warnings", strings(&result.warnings));
    Value::Dict(value)
}

/// The dict `tickets.parse` returns.
pub(crate) fn ticket_value(ticket: &Ticket) -> Value {
    let mut value = Dict::new();
    value.insert("id", ticket.id.as_str());
    value.insert("title", ticket.title.as_str());
    value.insert("status", ticket.status.as_str());
    value.insert("priority", ticket.priority.as_str());
    value.insert("execution_mode", ticket.execution_mode.as_str());
    value.insert("depends_on", strings(&ticket.depends_on));
    value.insert("run_id", ticket.run_id);
    value.insert("canceled", ticket.canceled);
    value.insert("draft", ticket.draft);
    value.insert("verification_blocker", ticket.verification_blocker.clone());
    value.insert("verification_resume", ticket.verification_resume.clone());
    value.insert("verification_origin", ticket.verification_origin.clone());
    value.insert("order", ticket.order);
    value.insert("body", ticket.body.as_str());
    let mut raw = Dict::new();
    for (key, field) in ticket.raw_fields.iter() {
        raw.insert(key, field);
    }
    value.insert("_raw_fields", raw);
    Value::Dict(value)
}

/// A parsed ticket dict, possibly edited, as `tickets.write` takes it.
pub(crate) fn ticket_from(value: &Dict) -> Ticket {
    let optional = |key: &str| optional_text(value, key);
    let mut raw_fields = Fields::default();
    for (key, field) in dict(value, "_raw_fields").iter() {
        raw_fields.insert(key, &field.py_str());
    }
    Ticket {
        id: text(value, "id"),
        title: text(value, "title"),
        status: text(value, "status"),
        priority: text(value, "priority"),
        execution_mode: text(value, "execution_mode"),
        depends_on: value
            .get("depends_on")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .collect(),
        run_id: integer(value, "run_id"),
        canceled: value.get("canceled").is_some_and(Value::truthy),
        draft: value.get("draft").is_some_and(Value::truthy),
        verification_blocker: optional("verification_blocker"),
        verification_resume: optional("verification_resume"),
        verification_origin: optional("verification_origin"),
        order: integer(value, "order").unwrap_or(0),
        body: text(value, "body"),
        raw_fields,
    }
}

fn toml_value(value: &toml::Value) -> Value {
    match value {
        toml::Value::String(text) => Value::Str(text.clone()),
        toml::Value::Integer(number) => Value::Int(*number),
        toml::Value::BigInteger(digits) => {
            let mut wrapped = Dict::new();
            wrapped.insert("$bigint", digits.as_str());
            Value::Dict(wrapped)
        }
        toml::Value::Float(number) => Value::Float(*number),
        toml::Value::Boolean(flag) => Value::Bool(*flag),
        toml::Value::Datetime(datetime) => {
            let mut wrapped = Dict::new();
            wrapped.insert("$datetime", datetime.py_str());
            Value::Dict(wrapped)
        }
        toml::Value::Array(items) => Value::List(items.iter().map(toml_value).collect()),
        toml::Value::Table(table) => toml_table(table),
    }
}

fn toml_table(table: &toml::Table) -> Value {
    let mut value = Dict::new();
    for (key, item) in table.iter() {
        value.insert(key, toml_value(item));
    }
    Value::Dict(value)
}

fn note_value(document: &notes::NoteDocument) -> Value {
    let identity = &document.identity;
    let mut identity_value = Dict::new();
    identity_value.insert("note_id", identity.note_id.as_str());
    identity_value.insert("artifact_id", identity.artifact_id.as_str());
    identity_value.insert("project_id", identity.project_id.as_str());
    identity_value.insert("created_at", identity.created_at.as_str());
    identity_value.insert("capture_started_at", identity.capture_started_at.as_str());
    let update = &document.update;
    let mut value = Dict::new();
    value.insert("identity", identity_value);
    value.insert("captured_at", update.captured_at.as_str());
    value.insert("recording_state", update.recording_state.as_str());
    value.insert("checkpoint_reason", update.checkpoint_reason.as_str());
    let segments = update
        .segments
        .iter()
        .map(|segment| {
            let mut item = segment.metadata();
            item.insert("text", segment.text.as_str());
            Value::Dict(item)
        })
        .collect::<Vec<_>>();
    value.insert("segments", segments);
    if let Some(ended) = &update.capture_ended_at {
        value.insert("capture_ended_at", ended.as_str());
    }
    value.insert("metadata", document.metadata.clone());
    Value::Dict(value)
}

#[derive(Default)]
pub(crate) struct Driver {
    pub(crate) store: Option<ArtifactStore>,
    followups: Option<FollowupProposalStore>,
}

impl Driver {
    pub(crate) fn store(&self) -> Result<&ArtifactStore, Error> {
        self.store
            .as_ref()
            .ok_or_else(|| Error::new(ErrorKind::Runtime, "store is not open"))
    }

    fn followups(&self) -> Result<&FollowupProposalStore, Error> {
        self.followups
            .as_ref()
            .ok_or_else(|| Error::new(ErrorKind::Runtime, "follow-up store is not open"))
    }

    fn handle(&mut self, request: &Dict) -> Answer {
        let op = text(request, "op");
        let (module, function) = op.split_once('.').unwrap_or((op.as_str(), ""));
        match module {
            "store" => self.store_op(function, request),
            "tickets" => tickets_op(function, request),
            "followup" => self.followup_op(function, request),
            "rollout" => rollout::handle(self, function, request),
            "sync" => sync::handle(self, function, request),
            "retention" => retention::handle(self, function, request),
            "lifecycle" => lifecycle::handle(self, function, request),
            "migration" => migration::handle(self, function, request),
            "automatic_retention" => migration::handle_automatic(self, function, request),
            "verification" => verification::handle(self, function, request),
            _ => module_op(module, function, request),
        }
    }

    fn store_op(&mut self, function: &str, request: &Dict) -> Answer {
        if function == "open" {
            self.store = None;
            let fail_stage = optional_text(request, "fail_stage");
            let options = StoreOptions {
                enabled: request.get("enabled").is_none_or(Value::truthy),
                project_warning_bytes: integer(request, "project_warning_bytes")
                    .map_or(store::DEFAULT_PROJECT_WARNING_BYTES, |bytes| bytes as u64),
                failure_injector: fail_stage.map(|wanted| {
                    Box::new(move |stage: &str| {
                        if stage == wanted {
                            Err(Error::new(
                                ErrorKind::InjectedFailure,
                                format!("injected failure at {stage}"),
                            ))
                        } else {
                            Ok(())
                        }
                    }) as store::FailureInjector
                }),
                ..StoreOptions::default()
            };
            self.store = Some(ArtifactStore::open(
                Path::new(&text(request, "repo")),
                &text(request, "project_id"),
                Path::new(&text(request, "state_root")),
                options,
            )?);
            return Ok(Value::Null);
        }
        let store = self.store()?;
        Ok(match function {
            "initialize" => write_result(store.initialize(
                &text(request, "device_id"),
                &optional_text(request, "actor_type").unwrap_or_else(|| "system".to_string()),
            )?),
            "mutate" => write_result(store.mutate(&mutation(request)?)?),
            "prepare_mutation" => write_result(store.prepare_mutation(&mutation(request)?)?),
            "bootstrap_legacy" => write_result(store.bootstrap_legacy(&mutation(request)?)?),
            "recover" => Value::Str(store.recover()?),
            "snapshot" => {
                let snapshot = store.snapshot()?;
                let mut files = Dict::new();
                for (path, content) in &snapshot.files {
                    files.insert(path, hex(content));
                }
                let mut value = Dict::new();
                value.insert("project_id", snapshot.project_id);
                value.insert("commit_id", snapshot.commit_id);
                value.insert("tree_id", snapshot.tree_id);
                value.insert("files", files);
                Value::Dict(value)
            }
            "digest" => Value::Str(store::mutation_digest(&mutation(request)?)),
            _ => return Err(Error::new(ErrorKind::Type, "unknown store operation")),
        })
    }

    fn followup_op(&mut self, function: &str, request: &Dict) -> Answer {
        let origin = text(request, "origin_repo_path");
        Ok(match function {
            "sanitize" => Value::Dict(followup::sanitize_followup_draft(
                request.get("draft").unwrap_or(&Value::Null),
                &origin,
            )?),
            "recommended_next_steps" => {
                strings(&followup::recommended_next_steps(&text(request, "body"))?)
            }
            "automatic_drafts" => Value::List(
                followup::automatic_followup_drafts(&text(request, "body"), &origin)?
                    .into_iter()
                    .map(Value::Dict)
                    .collect(),
            ),
            "batch_id" => Value::Str(followup::batch_id(
                &origin,
                &text(request, "origin_ticket_id"),
                integer(request, "origin_run_id").unwrap_or(0),
            )),
            "proposal_id" => Value::Str(followup::proposal_id(
                &text(request, "batch"),
                integer(request, "position").unwrap_or(0) as usize,
            )),
            "acceptance_key" => Value::Str(followup::acceptance_key(
                &text(request, "batch"),
                &text(request, "proposal"),
            )),
            "open" => {
                self.followups = None;
                self.followups = Some(FollowupProposalStore::open(Path::new(&text(
                    request, "path",
                )))?);
                Value::Null
            }
            "create_or_get" => {
                let (batch, created) = self.followups()?.create_or_get(
                    &origin,
                    &text(request, "origin_ticket_id"),
                    integer(request, "origin_run_id").unwrap_or(0),
                    optional_text(request, "provider_key").as_deref(),
                    &dicts(request, "drafts"),
                )?;
                Value::List(vec![Value::Dict(batch), Value::Bool(created)])
            }
            "get" => self.followups()?.get(&text(request, "batch"))?.into(),
            "update_draft" => Value::Dict(self.followups()?.update_draft(
                &text(request, "batch"),
                &text(request, "proposal"),
                &dict(request, "draft"),
            )?),
            "set_result" => Value::Dict(self.followups()?.set_result(
                &text(request, "batch"),
                &text(request, "proposal"),
                &text(request, "state"),
                optional_text(request, "ticket_id").as_deref(),
                optional_text(request, "error").as_deref(),
            )?),
            "set_error" => Value::Dict(self.followups()?.set_error(
                &text(request, "batch"),
                &text(request, "proposal"),
                &text(request, "error"),
            )?),
            _ => return Err(Error::new(ErrorKind::Type, "unknown follow-up operation")),
        })
    }
}

fn tickets_op(function: &str, request: &Dict) -> Answer {
    Ok(match function {
        "parse" => ticket_value(&tickets::parse(&text(request, "text"))?),
        "read" => ticket_value(&tickets::read(Path::new(&text(request, "path")))?),
        "write" => {
            tickets::write(
                Path::new(&text(request, "path")),
                &ticket_from(&dict(request, "ticket")),
            )?;
            Value::Null
        }
        "roundtrip" => Value::Str(TicketDocument::parse(&text(request, "text"))?.serialise()),
        "scan_repo" => Value::List(
            tickets::scan_repo(Path::new(&text(request, "repo")))?
                .iter()
                .map(|(path, ticket)| {
                    let Value::Dict(mut value) = ticket_value(ticket) else {
                        unreachable!("tickets are dicts")
                    };
                    value.insert("_path", path.to_string_lossy().into_owned());
                    Value::Dict(value)
                })
                .collect(),
        ),
        "all_deps_done" => {
            let all: Vec<Ticket> = dicts(request, "all").iter().map(ticket_from).collect();
            Value::Bool(tickets::all_deps_done(
                &ticket_from(&dict(request, "ticket")),
                &all,
            ))
        }
        _ => return Err(Error::new(ErrorKind::Type, "unknown tickets operation")),
    })
}

fn module_op(module: &str, function: &str, request: &Dict) -> Answer {
    Ok(match (module, function) {
        ("board", "ticket_config") => {
            let (prefix, next_id) = board_config::ticket_config(&text(request, "text"))?;
            Value::List(vec![Value::Str(prefix), Value::Int(next_id)])
        }
        ("board", "with_next_id") => Value::Str(board_config::with_next_id(
            &text(request, "text"),
            integer(request, "next_id").unwrap_or(0),
        )),
        ("board", "claim_next_id") => {
            let claim = board_config::claim_next_id(&unhex(request, "content")?)?;
            let mut value = Dict::new();
            value.insert("prefix", claim.prefix);
            value.insert("next_id", claim.next_id);
            value.insert("config", claim.config);
            Value::Dict(value)
        }
        ("catalog", "validate") => {
            let fields: Vec<String> = match request.get("activity_fields").and_then(Value::as_list)
            {
                Some(fields) => fields.iter().map(Value::py_str).collect(),
                None => catalog::DEFAULT_ACTIVITY_FIELDS
                    .iter()
                    .map(|field| field.to_string())
                    .collect(),
            };
            let fields: Vec<&str> = fields.iter().map(String::as_str).collect();
            let front = catalog::validate_catalog_ticket_metadata(
                &dict(request, "entry"),
                &unhex(request, "content")?,
                &fields,
            )?;
            let mut value = Dict::new();
            for (key, field) in front {
                value.insert(&key, field);
            }
            Value::Dict(value)
        }
        ("config", "load") => toml_table(&config::load_config(
            Some(&PathBuf::from(text(request, "path"))),
            integer(request, "macos_major").map(|major| major as i32),
            request
                .get("phonon_default_active")
                .is_none_or(Value::truthy),
        )?),
        ("toml", "loads") => toml_table(&toml::loads(&text(request, "text"))?),
        ("toml", "loads_bytes") => toml_table(&toml::loads_bytes(&unhex(request, "content")?)?),
        ("isotime", "fromisoformat") => {
            let parsed = isotime::fromisoformat(&text(request, "text"))?;
            let mut value = Dict::new();
            for (key, field) in [
                ("year", parsed.year),
                ("month", parsed.month),
                ("day", parsed.day),
                ("hour", parsed.hour),
                ("minute", parsed.minute),
                ("second", parsed.second),
                ("microsecond", parsed.microsecond),
            ] {
                value.insert(key, i64::from(field));
            }
            value.insert("offset_us", parsed.offset_us);
            value.insert("utc_micros", parsed.utc_micros().transpose()?);
            Value::Dict(value)
        }
        ("notes", "parse") => note_value(&notes::parse_note_document(&unhex(request, "content")?)?),
        ("notes", "normalize") => {
            let document = notes::parse_note_document(&unhex(request, "content")?)?;
            hex(&notes::render_note_document(&document)?)
        }
        ("notes", "validate_metadata") => Value::Dict(notes::validate_note_metadata(
            request.get("value").unwrap_or(&Value::Null),
        )?),
        ("notes", "decode_index") => {
            let mut value = Dict::new();
            for (artifact_id, entry) in
                notes::decode_note_index(&unhex(request, "content")?, &text(request, "project_id"))?
            {
                value.insert(&artifact_id, entry);
            }
            Value::Dict(value)
        }
        ("notes", "validate_note_id") => {
            let (note_id, number) = notes::validate_note_id(&text(request, "value"))?;
            Value::List(vec![Value::Str(note_id), Value::Int(number as i64)])
        }
        ("store", _) | ("tickets", _) | ("followup", _) => unreachable!("dispatched above"),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}

fn main() {
    let mut driver = Driver::default();
    let stdout = io::stdout();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let answer = match json::parse(&line) {
            Some(Value::Dict(request)) => driver.handle(&request),
            _ => Err(invalid("request is not a JSON object")),
        };
        let mut reply = Dict::new();
        match answer {
            Ok(result) => {
                reply.insert("ok", true);
                reply.insert("result", result);
            }
            Err(error) => {
                reply.insert("ok", false);
                reply.insert("error", error.kind.python_class());
                reply.insert("message", error.message);
                // The extra attributes some error classes carry.
                if let Some(code) = error.code {
                    reply.insert("code", code);
                }
                if let Some(recovery) = error.recovery {
                    reply.insert("recovery", recovery);
                }
                if let Some(report) = error.report {
                    reply.insert("report", report);
                }
            }
        }
        let mut out = stdout.lock();
        let _ = writeln!(out, "{}", json::dumps_compact(&Value::Dict(reply)));
        let _ = out.flush();
    }
}
