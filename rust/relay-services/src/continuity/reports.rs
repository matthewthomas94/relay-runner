//! The report rules of `services/continuity_reports.py`: privacy-safe
//! unresolved continuity reports and their reviewable permanent-fix drafts.
//!
//! The rows live in `continuity_reports.db` through
//! [`relay_store::continuity::ContinuityReportStore`]; this module builds the
//! report and sanitises each draft before the store sees them, as
//! `ContinuityReportStore.record_unresolved` and `update_draft` do in Python.

use std::sync::LazyLock;

use relay_intents::json::py_strip;
use relay_intents::pattern::{self, Regex};
use relay_intents::sha256::hex_digest;
use relay_store::continuity::ContinuityReportStore;

use super::agent::sanitize_incident_bundle;
use crate::{Dict, Error, Result, Value};

pub const UNRESOLVED_RESULTS: [&str; 4] = [
    "authorization_required",
    "canceled",
    "circuit_open",
    "provider_failed",
];

/// `followup_tickets.PRIVATE_CONTENT_RE`.
static PRIVATE_CONTENT: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"\b(raw\s+(?:provider\s+)?transcript|chain[- ]of[- ]thought|hidden\s+reasoning|scratchpad|system\s+prompt|tool\s+log)\b|\b(?:sk|ghp|github_pat)-[A-Za-z0-9_-]{12,}\b|BEGIN [A-Z ]*PRIVATE KEY",
        true,
    )
});
static WHITESPACE_RUN: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"\s+", false));

/// `str(value or "")`.
fn py_text(value: Option<&Value>) -> String {
    value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default()
}

/// `_clean(value, field)`: one line of text with no private material.
fn clean(value: Option<&Value>, field: &str) -> Result<String> {
    let stripped = py_strip(&py_text(value)).to_string();
    let text = WHITESPACE_RUN.replace_all(&stripped, " ").into_owned();
    if text.is_empty() {
        return Err(Error::value(format!("{field} is required")));
    }
    if pattern::search(&PRIVATE_CONTENT, &text) {
        return Err(Error::value(format!(
            "{field} contains private provider or secret material"
        )));
    }
    Ok(text)
}

fn first_chars(text: &str, count: usize) -> String {
    text.chars().take(count).collect()
}

fn strings(items: &[&str]) -> Value {
    Value::List(items.iter().map(|item| Value::from(*item)).collect())
}

/// `_default_proposal(incident)`: the permanent-fix draft an unresolved
/// report gets when none is supplied.
pub fn default_proposal(incident: &Dict) -> Dict {
    let component = incident
        .get("component")
        .map(Value::py_str)
        .unwrap_or_default();
    let provider = incident
        .get("provider")
        .map(Value::py_str)
        .unwrap_or_default();
    let incident_id = incident
        .get("incident_id")
        .map(Value::py_str)
        .unwrap_or_default();
    let provider_scope = if provider != "none" {
        " for both Codex and Claude"
    } else {
        ""
    };
    let mut draft = Dict::new();
    draft.insert(
        "title",
        first_chars(
            &format!(
                "Prevent recurring {} continuity failure",
                component.replace('_', " ")
            ),
            120,
        ),
    );
    draft.insert(
        "description",
        format!(
            "Diagnose and permanently correct the sanitized {component} continuity \
             failure represented by incident {incident_id}{provider_scope}."
        ),
    );
    draft.insert(
        "acceptance_criteria",
        strings(&[
            "The underlying continuity defect is reproduced with privacy-safe evidence.",
            "The permanent fix preserves exact command, reply, and speech ownership.",
            "Focused Codex and Claude regression coverage passes.",
        ]),
    );
    draft.insert("priority", "high");
    draft.insert("depends_on", Value::List(Vec::new()));
    draft.insert("worker_model", "strong");
    draft.insert("worker_effort", "high");
    draft.insert(
        "worker_sizing_rationale",
        "Continuity defects cross process recovery, command identity, and speech safety.",
    );
    draft.insert(
        "worker_provider_notes",
        "Codex and Claude must preserve the same recovery and no-duplicate guarantees.",
    );
    draft
}

/// `sanitize_proposal(value)`: a reviewable ticket draft, refused with the
/// Python message when a field is missing, invalid or private.
pub fn sanitize_proposal(value: &Value) -> Result<Dict> {
    let Some(value) = value.as_dict() else {
        return Err(Error::value("continuity proposal must be an object"));
    };
    let criteria = match value.get("acceptance_criteria") {
        Some(Value::List(items)) if !items.is_empty() => items,
        _ => {
            return Err(Error::value("acceptance_criteria must be a non-empty list"));
        }
    };
    let empty = Vec::new();
    let dependencies = match value.get("depends_on") {
        None => &empty,
        Some(Value::List(items)) => items,
        Some(_) => return Err(Error::value("depends_on must be a list")),
    };
    let choice = |key: &str, default: &str| -> String {
        let raw = value
            .truthy(key)
            .map_or_else(|| default.to_string(), Value::py_str);
        py_strip(&raw).to_lowercase()
    };
    let priority = choice("priority", "high");
    if !["urgent", "high", "medium", "low"].contains(&priority.as_str()) {
        return Err(Error::value("invalid continuity proposal priority"));
    }
    let effort = choice("worker_effort", "high");
    if !["low", "medium", "high", "xhigh", "max"].contains(&effort.as_str()) {
        return Err(Error::value("invalid continuity proposal effort"));
    }
    let strong = Value::from("strong");
    let model = clean(
        Some(value.truthy("worker_model").unwrap_or(&strong)),
        "worker_model",
    )?;
    if effort == "max" && !model.to_lowercase().starts_with("claude:") {
        return Err(Error::value(
            "worker_effort max requires an explicitly Claude-scoped model",
        ));
    }
    let title = first_chars(&clean(value.get("title"), "title")?, 120);
    let description = clean(value.get("description"), "description")?;
    let criteria = criteria
        .iter()
        .map(|item| clean(Some(item), "acceptance_criteria").map(Value::from))
        .collect::<Result<Vec<_>>>()?;
    let depends_on: Vec<Value> = dependencies
        .iter()
        .map(|item| py_strip(&item.py_str()).to_uppercase())
        .filter(|item| !item.is_empty())
        .map(Value::from)
        .collect();
    let rationale = clean(
        value.get("worker_sizing_rationale"),
        "worker_sizing_rationale",
    )?;
    let notes = clean(value.get("worker_provider_notes"), "worker_provider_notes")?;
    let mut draft = Dict::new();
    draft.insert("title", title);
    draft.insert("description", description);
    draft.insert("acceptance_criteria", Value::List(criteria));
    draft.insert("priority", priority);
    draft.insert("depends_on", Value::List(depends_on));
    draft.insert("worker_model", model);
    draft.insert("worker_effort", effort);
    draft.insert("worker_sizing_rationale", rationale);
    draft.insert("worker_provider_notes", notes);
    Ok(draft)
}

/// `build_report(incident, final_result)`: the unresolved report, with only
/// the sanitized incident and a count of the fields left out.
pub fn build_report(incident: &Value, final_result: &str) -> Result<Dict> {
    let sanitized = sanitize_incident_bundle(incident)?;
    let redaction_count = incident.as_dict().map_or(0, |original| {
        original
            .iter()
            .filter(|(key, _)| sanitized.get(key).is_none())
            .count()
    });
    let result = py_strip(final_result).to_lowercase();
    if !UNRESOLVED_RESULTS.contains(&result.as_str()) {
        return Err(Error::value(
            "continuity report requires an unresolved recovery result",
        ));
    }
    let incident_id = sanitized.string("incident_id");
    let generation = sanitized.string("recovery_generation");
    let report_id = format!(
        "continuity-report-{}",
        &hex_digest(format!("{incident_id}\0{generation}").as_bytes())[..20]
    );
    let recurrence = if sanitized.string("classification") == "recurring" {
        "high"
    } else {
        "unknown"
    };
    let component = sanitized.string("component");
    let mut report = Dict::new();
    report.insert("schema_version", 1);
    report.insert("report_id", report_id);
    report.insert("status", "unresolved");
    report.insert("incident", sanitized);
    report.insert("recovery_result", result);
    report.insert("likely_cause_category", format!("{component}_unavailable"));
    report.insert("cause_confidence", "unconfirmed");
    report.insert("recurrence_likelihood", recurrence);
    report.insert(
        "risks",
        strings(&["voice_processing_continuity_unavailable"]),
    );
    report.insert(
        "unresolved_questions",
        strings(&["Which component-owned defect prevented stable recovery?"]),
    );
    report.insert("redaction_count", redaction_count as i64);
    Ok(report)
}

/// `ContinuityReportStore.record_unresolved(incident, final_result,
/// proposals=...)`: the report and whether it was recorded now. With no
/// proposals (or an empty list) the report gets [`default_proposal`].
pub fn record_unresolved(
    store: &ContinuityReportStore,
    incident: &Value,
    final_result: &str,
    proposals: Option<&[Value]>,
) -> Result<(Dict, bool)> {
    let report = build_report(incident, final_result)?;
    let drafts = match proposals.filter(|items| !items.is_empty()) {
        Some(items) => items
            .iter()
            .map(sanitize_proposal)
            .collect::<Result<Vec<_>>>()?,
        None => {
            let incident = report
                .get("incident")
                .and_then(Value::as_dict)
                .cloned()
                .unwrap_or_default();
            vec![sanitize_proposal(&Value::Dict(default_proposal(
                &incident,
            )))?]
        }
    };
    Ok(store.record_unresolved(&report, &drafts)?)
}

/// `ContinuityReportStore.update_draft(report_id, proposal_id, updates)`:
/// the updates applied over a draft proposal, sanitised again.
pub fn update_draft(
    store: &ContinuityReportStore,
    report_id: &str,
    proposal_id: &str,
    updates: &Dict,
) -> Result<Dict> {
    Ok(
        store.update_draft(report_id, proposal_id, updates, |merged| {
            sanitize_proposal(&Value::Dict(merged.clone()))
                .map_err(|error| relay_store::Error::Invalid(error.message))
        })?,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proposals_are_cleaned_and_checked() {
        let mut draft = default_proposal(&Dict::new());
        draft.insert("title", "  Fix\n the   bridge ");
        draft.insert("depends_on", Value::List(vec![" rr-1 ".into(), "".into()]));
        let clean = sanitize_proposal(&Value::Dict(draft.clone())).unwrap();
        assert_eq!(clean.string("title"), "Fix the bridge");
        assert_eq!(
            clean.get("depends_on").unwrap().as_list().unwrap()[0].as_str(),
            Some("RR-1")
        );
        draft.insert("description", "Paste the raw transcript here.");
        assert_eq!(
            sanitize_proposal(&Value::Dict(draft.clone()))
                .unwrap_err()
                .message,
            "description contains private provider or secret material"
        );
        draft.insert("worker_effort", "max");
        assert_eq!(
            sanitize_proposal(&Value::Dict(draft)).unwrap_err().message,
            "worker_effort max requires an explicitly Claude-scoped model"
        );
    }
}
