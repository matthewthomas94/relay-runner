//! `continuity_reports.db`: `ContinuityReportStore` in
//! `services/continuity_reports.py`, unresolved continuity reports and their
//! permanent-fix drafts. Building a report and sanitising a draft are the
//! continuity lane's rules (`build_report`, `sanitize_proposal`); the store
//! takes the report built and a sanitiser for edits.

use std::path::Path;

use rusqlite::Connection;

use relay_intents::json;
use relay_intents::sha256::hex_digest;

use crate::followups::decode_draft;
use crate::sql::{self, DEFAULT_TIMEOUT, Db, int, opt_text, real, text};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY,
        incident_id TEXT NOT NULL UNIQUE,
        state TEXT NOT NULL,
        report_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY,
        report_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(report_id, position)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_proposals_report
        ON proposals(report_id, position);
    ";

pub fn proposal_id(report_id: &str, position: i64) -> String {
    format!(
        "continuity-proposal-{}",
        &hex_digest(format!("{report_id}\0{position}").as_bytes())[..16]
    )
}

pub struct ContinuityReportStore {
    db: Db,
}

impl ContinuityReportStore {
    /// Opens the store; an acceptance a restart interrupted goes back to
    /// `draft` for another review.
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(|c| {
            c.execute_batch(SCHEMA)?;
            sql::execute(
                c,
                "UPDATE proposals SET state = 'draft', error = ? WHERE state = 'accepting'",
                &[text("acceptance interrupted; review again")],
            )?;
            Ok(())
        })?;
        Ok(store)
    }

    /// Records a built report (`report_id`, `incident.incident_id`) with its
    /// sanitised drafts, once. The flag says whether it was recorded now.
    pub fn record_unresolved(&self, report: &Dict, drafts: &[Dict]) -> Result<(Dict, bool)> {
        let report_id = report
            .get("report_id")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::invalid("report_id is required"))?
            .to_string();
        let incident_id = report
            .get("incident")
            .and_then(Value::as_dict)
            .and_then(|incident| incident.get("incident_id"))
            .and_then(Value::as_str)
            .ok_or_else(|| Error::invalid("incident_id is required"))?
            .to_string();
        let now = sql::now();
        self.db.with(|c| {
            if sql::row(c, "SELECT 1 FROM reports WHERE id = ?", &[text(&report_id)])?.is_some() {
                return Ok((get_report(c, &report_id)?, false));
            }
            sql::transaction(c, "BEGIN IMMEDIATE", || {
                sql::execute(
                    c,
                    "INSERT INTO reports VALUES (?, ?, 'unresolved', ?, ?, ?)",
                    &[
                        text(&report_id),
                        text(&incident_id),
                        text(json::dumps_sorted(&Value::Dict(report.clone()))),
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
                            text(proposal_id(&report_id, position)),
                            text(&report_id),
                            int(position),
                            text(json::dumps_sorted(&Value::Dict(draft.clone()))),
                            real(now),
                        ],
                    )?;
                }
                Ok(())
            })?;
            Ok((get_report(c, &report_id)?, true))
        })
    }

    pub fn get(&self, report_id: &str) -> Result<Option<Dict>> {
        self.db.with(|c| {
            if sql::row(c, "SELECT 1 FROM reports WHERE id = ?", &[text(report_id)])?.is_none() {
                return Ok(None);
            }
            get_report(c, report_id).map(Some)
        })
    }

    /// Applies `updates` over a draft proposal's draft, through `sanitize`
    /// (`sanitize_proposal({**draft, **updates})`), under the store lock.
    pub fn update_draft(
        &self,
        report_id: &str,
        proposal_id: &str,
        updates: &Dict,
        sanitize: impl FnOnce(&Dict) -> Result<Dict>,
    ) -> Result<Dict> {
        self.db.with(|c| {
            let row = proposal(c, report_id, proposal_id)?;
            require_draft(&row)?;
            let mut merged = match sql::loads(sql::field_str(&row, "draft_json"), "draft_json")? {
                Value::Dict(draft) => draft,
                _ => Dict::new(),
            };
            merged.update(updates);
            let draft = sanitize(&merged)?;
            let now = sql::now();
            sql::execute(
                c,
                "UPDATE proposals SET draft_json = ?, error = NULL, updated_at = ? WHERE id = ?",
                &[
                    text(json::dumps_sorted(&Value::Dict(draft))),
                    real(now),
                    text(proposal_id),
                ],
            )?;
            touch(c, report_id, now)?;
            get_report(c, report_id)
        })
    }

    /// Moves a draft to `accepting` and returns its draft; `None` when it is
    /// already accepted.
    pub fn claim_acceptance(&self, report_id: &str, proposal_id: &str) -> Result<Option<Value>> {
        self.db.with(|c| {
            let row = proposal(c, report_id, proposal_id)?;
            if sql::field_str(&row, "state") == "accepted" {
                return Ok(None);
            }
            require_draft(&row)?;
            let changed = sql::execute(
                c,
                "UPDATE proposals SET state = 'accepting', error = NULL, updated_at = ? \
                 WHERE id = ? AND state = 'draft'",
                &[real(sql::now()), text(proposal_id)],
            )?;
            if changed != 1 {
                return Err(Error::invalid(
                    "continuity proposal acceptance raced another review",
                ));
            }
            sql::loads(sql::field_str(&row, "draft_json"), "draft_json").map(Some)
        })
    }

    /// Ends an acceptance: `accepted` with its ticket, or back to `draft`
    /// with the error.
    pub fn finish_acceptance(
        &self,
        report_id: &str,
        proposal_id: &str,
        ticket_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<Dict> {
        let state = if ticket_id.is_some_and(|id| !id.is_empty()) {
            "accepted"
        } else {
            "draft"
        };
        self.db.with(|c| {
            proposal(c, report_id, proposal_id)?;
            let now = sql::now();
            sql::execute(
                c,
                "UPDATE proposals SET state = ?, ticket_id = ?, error = ?, updated_at = ? \
                 WHERE id = ?",
                &[
                    text(state),
                    opt_text(ticket_id),
                    opt_text(error),
                    real(now),
                    text(proposal_id),
                ],
            )?;
            touch(c, report_id, now)?;
            get_report(c, report_id)
        })
    }

    pub fn reject(&self, report_id: &str, proposal_id: &str) -> Result<Dict> {
        self.db.with(|c| {
            let row = proposal(c, report_id, proposal_id)?;
            require_draft(&row)?;
            let now = sql::now();
            sql::execute(
                c,
                "UPDATE proposals SET state = 'rejected', updated_at = ? WHERE id = ?",
                &[real(now), text(proposal_id)],
            )?;
            touch(c, report_id, now)?;
            get_report(c, report_id)
        })
    }
}

fn require_draft(row: &Dict) -> Result<()> {
    let state = sql::field_str(row, "state");
    if state != "draft" {
        return Err(Error::invalid(format!(
            "continuity proposal is already {state}"
        )));
    }
    Ok(())
}

fn touch(c: &Connection, report_id: &str, now: f64) -> Result<()> {
    sql::execute(
        c,
        "UPDATE reports SET updated_at = ? WHERE id = ?",
        &[real(now), text(report_id)],
    )?;
    Ok(())
}

fn proposal(c: &Connection, report_id: &str, proposal_id: &str) -> Result<Dict> {
    sql::row(
        c,
        "SELECT * FROM proposals WHERE report_id = ? AND id = ?",
        &[text(report_id), text(proposal_id)],
    )?
    .ok_or_else(|| Error::invalid(format!("continuity proposal {proposal_id} not found")))
}

/// `_get`: the stored report with its timestamps and proposals.
fn get_report(c: &Connection, report_id: &str) -> Result<Dict> {
    let row = sql::row(c, "SELECT * FROM reports WHERE id = ?", &[text(report_id)])?
        .ok_or_else(|| Error::invalid(format!("continuity report {report_id} not found")))?;
    let mut payload = match sql::loads(sql::field_str(&row, "report_json"), "report_json")? {
        Value::Dict(payload) => payload,
        _ => return Err(Error::invalid("report_json is not an object")),
    };
    for key in ["created_at", "updated_at"] {
        payload.insert(key, row.get(key).cloned().unwrap_or(Value::Null));
    }
    let proposals = sql::rows(
        c,
        "SELECT * FROM proposals WHERE report_id = ? ORDER BY position",
        &[text(report_id)],
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
