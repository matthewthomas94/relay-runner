//! `services/artifact_rollout.py` (and `artifact_rollout_cli.py`): the staged
//! artifact rollout policy in `<state root>/rollout/artifact-rollout-v1.json`.
//!
//! The policy is a JSON document kept exactly as Python keeps it: read with
//! `json.loads`, validated, changed in place under an exclusive `flock` on
//! `artifact-rollout-v1.lock`, and written with
//! `json.dumps(document, sort_keys=True, indent=2) + "\n"` through a temporary
//! file, after copying the previous valid primary to the backup. A Rust and a
//! Python store therefore take turns on one state root and leave the same
//! bytes behind.
//!
//! Known differences, each failing closed where Python would not:
//!
//! - A `revision` beyond `i64`, which Python's unbounded `int` accepts, makes
//!   the document invalid.
//! - A lone surrogate escape in the document, which a Rust string cannot
//!   hold, makes the document invalid rather than being carried through.
//! - Evidence `providers` or `scenario_ids` of mixed non-string types are
//!   refused with a `TypeError` as Python's `sorted()` refuses them, but the
//!   two type names in the message may come in the other order.
//! - The CLI's argument errors are reported with exit status 2 as argparse
//!   does, but not with argparse's usage text; a JSON decode failure in an
//!   evidence file is reported without Python's position details.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use relay_intents::json::{self, Dict, Value};

use crate::instant::Instant;
use crate::{Error, ErrorKind, Result, isotime, paths, pystr};

pub const ROLLOUT_SCHEMA_VERSION: i64 = 1;
pub const PROJECT_OPT_IN: &str = "project_opt_in";
pub const NEW_PROJECT_DEFAULT: &str = "new_project_default";
pub const LEGACY_MIGRATION_OFFER: &str = "legacy_migration_offer";
pub const COHORTS: [&str; 3] = [PROJECT_OPT_IN, NEW_PROJECT_DEFAULT, LEGACY_MIGRATION_OFFER];

pub const EVIDENCE_KINDS: [&str; 10] = [
    "source_matrix",
    "two_device_remote",
    "failure_injection",
    "signed_installed_workspace",
    "installed_provider_parity",
    "fresh_install_reset",
    "migration_rollback",
    "operator_recovery",
    "opt_in_cohort_accepted",
    "new_project_cohort_accepted",
];

pub const NEW_PROJECT_REQUIRED_EVIDENCE: [&str; 8] = [
    "source_matrix",
    "two_device_remote",
    "failure_injection",
    "signed_installed_workspace",
    "installed_provider_parity",
    "fresh_install_reset",
    "operator_recovery",
    "opt_in_cohort_accepted",
];

/// `NEW_PROJECT_REQUIRED_EVIDENCE | {"migration_rollback", "new_project_cohort_accepted"}`.
pub const LEGACY_REQUIRED_EVIDENCE: [&str; 10] = [
    "source_matrix",
    "two_device_remote",
    "failure_injection",
    "signed_installed_workspace",
    "installed_provider_parity",
    "fresh_install_reset",
    "operator_recovery",
    "opt_in_cohort_accepted",
    "migration_rollback",
    "new_project_cohort_accepted",
];

const FORBIDDEN_DIAGNOSTIC_KEYS: [&str; 14] = [
    "audio",
    "conversation",
    "hidden_reasoning",
    "log",
    "logs",
    "prompt",
    "raw_log",
    "raw_transcript",
    "reasoning",
    "secret",
    "token",
    "tool_output",
    "trace",
    "transcript",
];

const EVIDENCE_KEYS: [&str; 12] = [
    "evidence_id",
    "kind",
    "outcome",
    "recorded_at",
    "report_sha256",
    "build_version",
    "build_number",
    "bundle_sha256",
    "signer_team_id",
    "providers",
    "scenario_ids",
    "rejection_code",
];

const DOCUMENT_KEYS: [&str; 7] = [
    "schema_version",
    "revision",
    "last_event",
    "updated_at",
    "cohorts",
    "project_opt_ins",
    "evidence",
];

const COHORT_KEYS: [&str; 6] = [
    "enabled",
    "paused",
    "writes_allowed",
    "sync_allowed",
    "pause_reason_code",
    "updated_at",
];

const PROJECT_OPT_IN_KEYS: [&str; 2] = ["enabled", "updated_at"];

/// `ArtifactRolloutError(message, code=..., recovery=...)`.
fn rollout_error(message: impl Into<String>, code: &str, recovery: &str) -> Error {
    Error::new(ErrorKind::Rollout, message)
        .with_code(code)
        .with_recovery(recovery)
}

/// `ArtifactRolloutBlocked(message, code=..., recovery=...)`.
fn blocked(message: impl Into<String>, code: &str, recovery: &str) -> Error {
    Error::new(ErrorKind::RolloutBlocked, message)
        .with_code(code)
        .with_recovery(recovery)
}

fn type_error(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Type, message)
}

/// Python's `repr(value)` for a JSON value.
fn py_repr(value: &Value) -> String {
    match value {
        Value::Str(text) => pystr::repr(text),
        other => other.py_str(),
    }
}

/// Whether `set(keys) == expected`.
fn same_keys(dict: &Dict, expected: &[&str]) -> bool {
    dict.len() == expected.len() && expected.iter().all(|key| dict.get(key).is_some())
}

fn is_unhashable(value: &Value) -> bool {
    matches!(value, Value::List(_) | Value::Dict(_))
}

/// CPython 3.14's `TypeError` for a list or object used as a set element.
fn unhashable(value: &Value) -> Error {
    let name = pystr::type_name(value);
    type_error(format!(
        "cannot use '{name}' as a set element (unhashable type: '{name}')"
    ))
}

/// `value in {strings}`, raising Python's `TypeError` for an unhashable value.
fn member(value: &Value, options: &[&str]) -> Result<bool> {
    if is_unhashable(value) {
        return Err(unhashable(value));
    }
    Ok(value.as_str().is_some_and(|text| options.contains(&text)))
}

/// `list(value)` (or `tuple(value)`) for a JSON value: a list's items, a
/// string's characters, an object's keys.
fn py_iter(value: &Value) -> Result<Vec<Value>> {
    Ok(match value {
        Value::List(items) => items.clone(),
        Value::Str(text) => text
            .chars()
            .map(|character| Value::Str(character.to_string()))
            .collect(),
        Value::Dict(dict) => dict
            .iter()
            .map(|(key, _)| Value::Str(key.to_string()))
            .collect(),
        other => {
            return Err(type_error(format!(
                "'{}' object is not iterable",
                pystr::type_name(other)
            )));
        }
    })
}

/// `tuple(value or ())`.
fn tuple_or_empty(value: Option<&Value>) -> Result<Vec<Value>> {
    match value {
        Some(value) if value.truthy() => py_iter(value),
        _ => Ok(Vec::new()),
    }
}

/// `tuple(sorted(set(values)))`.
fn sorted_set(values: &[Value]) -> Result<Vec<Value>> {
    let mut distinct: Vec<Value> = Vec::new();
    for value in values {
        if is_unhashable(value) {
            return Err(unhashable(value));
        }
        if !distinct.iter().any(|seen| json::py_eq(seen, value)) {
            distinct.push(value.clone());
        }
    }
    if distinct.len() < 2 {
        return Ok(distinct);
    }
    if distinct.iter().all(|value| matches!(value, Value::Str(_))) {
        distinct.sort_by(|left, right| left.as_str().cmp(&right.as_str()));
        return Ok(distinct);
    }
    let number = |value: &Value| match value {
        Value::Bool(flag) => Some(f64::from(u8::from(*flag))),
        Value::Int(number) => Some(*number as f64),
        Value::Float(number) => Some(*number),
        _ => None,
    };
    if distinct.iter().all(|value| number(value).is_some()) {
        distinct.sort_by(|left, right| {
            number(left)
                .partial_cmp(&number(right))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        return Ok(distinct);
    }
    let first = pystr::type_name(&distinct[0]);
    let other = distinct
        .iter()
        .map(pystr::type_name)
        .find(|name| *name != first)
        .unwrap_or(first);
    Err(type_error(format!(
        "'<' not supported between instances of '{other}' and '{first}'"
    )))
}

/// `pattern.fullmatch(value)` for a value that must be a string.
fn require_text(value: &Value) -> Result<&str> {
    value.as_str().ok_or_else(|| {
        type_error(format!(
            "expected string or bytes-like object, got '{}'",
            pystr::type_name(value)
        ))
    })
}

/// `^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$`.
fn is_safe_id(text: &str) -> bool {
    let bytes = text.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 128
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.:-".contains(byte))
}

/// `^[A-Za-z0-9][A-Za-z0-9_.+-]{0,63}$`.
fn is_safe_version(text: &str) -> bool {
    let bytes = text.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.+-".contains(byte))
}

/// `^[0-9a-f]{64}$`.
fn is_sha256(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `^[a-z][a-z0-9_]{0,63}$`.
fn is_scenario_id(text: &str) -> bool {
    let bytes = text.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
}

fn validate_id(value: &Value, label: &str) -> Result<()> {
    if value.as_str().is_some_and(is_safe_id) {
        return Ok(());
    }
    Err(rollout_error(
        format!("Invalid {label}: {}", py_repr(value)),
        "invalid_identifier",
        "Use a bounded alphanumeric identifier after confirming project identity.",
    ))
}

fn validate_sha(value: &Value, label: &str) -> Result<()> {
    if value.as_str().is_some_and(is_sha256) {
        return Ok(());
    }
    Err(rollout_error(
        format!("Invalid {label}."),
        "invalid_evidence_hash",
        "Hash the reviewed evidence bytes with SHA-256 and record the lowercase digest.",
    ))
}

fn validate_cohort(cohort: &str) -> Result<()> {
    if COHORTS.contains(&cohort) {
        return Ok(());
    }
    Err(rollout_error(
        format!("Unknown artifact rollout cohort: {}", pystr::repr(cohort)),
        "invalid_cohort",
        &format!("Use one of: {}.", COHORTS.join(", ")),
    ))
}

/// `RolloutEvidence`. Fields hold whatever the caller passed, as the Python
/// dataclass does; validation decides what is acceptable.
#[derive(Clone, Debug)]
pub struct RolloutEvidence {
    pub evidence_id: Value,
    pub kind: Value,
    pub outcome: Value,
    pub recorded_at: Value,
    pub report_sha256: Value,
    pub build_version: Value,
    pub build_number: Value,
    pub bundle_sha256: Value,
    pub signer_team_id: Value,
    pub providers: Vec<Value>,
    pub scenario_ids: Vec<Value>,
    pub rejection_code: Value,
}

impl RolloutEvidence {
    /// `RolloutEvidence(field=raw.get(field), ..., providers=tuple(raw.get(
    /// "providers") or ()), scenario_ids=tuple(raw.get("scenario_ids") or ()))`,
    /// as the document validation and the CLI build it.
    pub fn from_raw(raw: &Dict) -> Result<Self> {
        let field = |key: &str| raw.get(key).cloned().unwrap_or(Value::Null);
        Ok(Self {
            evidence_id: field("evidence_id"),
            kind: field("kind"),
            outcome: field("outcome"),
            recorded_at: field("recorded_at"),
            report_sha256: field("report_sha256"),
            build_version: field("build_version"),
            build_number: field("build_number"),
            bundle_sha256: field("bundle_sha256"),
            signer_team_id: field("signer_team_id"),
            providers: tuple_or_empty(raw.get("providers"))?,
            scenario_ids: tuple_or_empty(raw.get("scenario_ids"))?,
            rejection_code: field("rejection_code"),
        })
    }

    /// `dataclasses.asdict(evidence)` with the tuples as lists.
    pub fn as_dict(&self) -> Dict {
        let mut payload = Dict::new();
        payload.insert("evidence_id", self.evidence_id.clone());
        payload.insert("kind", self.kind.clone());
        payload.insert("outcome", self.outcome.clone());
        payload.insert("recorded_at", self.recorded_at.clone());
        payload.insert("report_sha256", self.report_sha256.clone());
        payload.insert("build_version", self.build_version.clone());
        payload.insert("build_number", self.build_number.clone());
        payload.insert("bundle_sha256", self.bundle_sha256.clone());
        payload.insert("signer_team_id", self.signer_team_id.clone());
        payload.insert("providers", Value::List(self.providers.clone()));
        payload.insert("scenario_ids", Value::List(self.scenario_ids.clone()));
        payload.insert("rejection_code", self.rejection_code.clone());
        payload
    }
}

/// `RolloutDecision`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RolloutDecision {
    pub project_id: String,
    pub cohort: Option<String>,
    pub artifact_writes_enabled: bool,
    pub artifact_sync_enabled: bool,
    pub offer_legacy_migration: bool,
    pub reason_code: String,
}

impl RolloutDecision {
    /// `dataclasses.asdict(decision)`.
    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("project_id", self.project_id.as_str());
        value.insert(
            "cohort",
            self.cohort.as_deref().map_or(Value::Null, Value::from),
        );
        value.insert("artifact_writes_enabled", self.artifact_writes_enabled);
        value.insert("artifact_sync_enabled", self.artifact_sync_enabled);
        value.insert("offer_legacy_migration", self.offer_legacy_migration);
        value.insert("reason_code", self.reason_code.as_str());
        value
    }
}

fn decision(
    project_id: &str,
    cohort: Option<&str>,
    writes: bool,
    sync: bool,
    offer: bool,
    reason_code: &str,
) -> RolloutDecision {
    RolloutDecision {
        project_id: project_id.to_string(),
        cohort: cohort.map(str::to_string),
        artifact_writes_enabled: writes,
        artifact_sync_enabled: sync,
        offer_legacy_migration: offer,
        reason_code: reason_code.to_string(),
    }
}

/// The validated document's nested objects, which validation guarantees.
fn object<'d>(document: &'d Dict, key: &str) -> &'d Dict {
    document
        .get(key)
        .and_then(Value::as_dict)
        .expect("validated rollout document")
}

fn flag(state: &Dict, key: &str) -> bool {
    matches!(state.get(key), Some(Value::Bool(true)))
}

/// `ArtifactRolloutStore`: atomic local policy store with fail-closed staged
/// cohort transitions.
pub struct ArtifactRolloutStore {
    pub state_root: PathBuf,
    pub rollout_root: PathBuf,
    pub path: PathBuf,
    pub backup_path: PathBuf,
    pub lock_path: PathBuf,
    now: Box<dyn Fn() -> Instant + Send + Sync>,
}

impl ArtifactRolloutStore {
    /// `ArtifactRolloutStore(state_root, now=now)`.
    pub fn new(
        state_root: &Path,
        now: Option<Box<dyn Fn() -> Instant + Send + Sync>>,
    ) -> Result<Self> {
        let state_root = PathBuf::from(paths::resolve(&paths::expanduser(
            &state_root.to_string_lossy(),
        )?));
        let rollout_root = state_root.join("rollout");
        Ok(Self {
            path: rollout_root.join("artifact-rollout-v1.json"),
            backup_path: rollout_root.join("artifact-rollout-v1.backup.json"),
            lock_path: rollout_root.join("artifact-rollout-v1.lock"),
            rollout_root,
            state_root,
            now: now.unwrap_or_else(|| Box::new(Instant::now)),
        })
    }

    /// Load the current policy; corruption fails closed unless the backup
    /// is valid.
    pub fn load(&self) -> Result<Dict> {
        if !self.path.exists() {
            return Ok(self.default_document());
        }
        match self.read_document(&self.path) {
            Ok(document) => Ok(document),
            Err(error) if error.kind == ErrorKind::Rollout => {
                if self.backup_path.exists() {
                    match self.read_document(&self.backup_path) {
                        Ok(mut recovered) => {
                            recovered.insert("recovery_state", "primary_corrupt_using_backup");
                            return Ok(recovered);
                        }
                        Err(error) if error.kind == ErrorKind::Rollout => {}
                        Err(error) => return Err(error),
                    }
                }
                Err(blocked(
                    "Artifact rollout policy and backup are unreadable; all new artifact starts are blocked.",
                    "rollout_state_corrupt",
                    "Stop artifact writers, restore a reviewed rollout backup, then explicitly resume the intended cohort.",
                ))
            }
            Err(error) => Err(error),
        }
    }

    pub fn record_evidence(&self, evidence: &RolloutEvidence) -> Result<Dict> {
        let validated = self.validate_evidence(evidence)?;
        let payload = validated.as_dict();
        let idempotent = self.locked_document(|document| {
            let existing = document
                .get("evidence")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .find(|item| {
                    item.as_dict().is_some_and(|item| {
                        json::py_eq_optional(item.get("evidence_id"), Some(&validated.evidence_id))
                    })
                })
                .cloned();
            if let Some(existing) = existing {
                if !json::py_eq(&existing, &Value::Dict(payload.clone())) {
                    return Err(blocked(
                        format!(
                            "Evidence ID {} already has different content.",
                            py_repr(&validated.evidence_id)
                        ),
                        "evidence_id_collision",
                        "Use a new immutable evidence ID after reviewing both records.",
                    ));
                }
                return Ok(Some(self.diagnostics(Some(document))?));
            }
            let mut evidence = document
                .get("evidence")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .to_vec();
            evidence.push(Value::Dict(payload.clone()));
            document.insert("evidence", Value::List(evidence));
            self.advance(document, "evidence_recorded");
            Ok(None)
        })?;
        match idempotent {
            Some(diagnostics) => Ok(diagnostics),
            None => self.diagnostics(None),
        }
    }

    pub fn set_project_opt_in(
        &self,
        project_id: &str,
        enabled: bool,
        confirmed: bool,
        writers_drained: bool,
        sync_frozen: bool,
    ) -> Result<RolloutDecision> {
        validate_id(&Value::from(project_id), "project ID")?;
        if !confirmed {
            return Err(blocked(
                "Per-project artifact rollout requires explicit confirmation.",
                "project_confirmation_required",
                "Review the project identity and rollback boundary, then confirm the opt-in change.",
            ));
        }
        self.locked_document(|document| {
            let cohort = object(object(document, "cohorts"), PROJECT_OPT_IN);
            if enabled && (flag(cohort, "paused") || !flag(cohort, "writes_allowed")) {
                return Err(blocked(
                    "The per-project cohort kill switch currently blocks new artifact writes.",
                    "project_opt_in_paused",
                    "Resolve the recorded cohort failure before an explicit operator resume.",
                ));
            }
            if !enabled && (!writers_drained || !sync_frozen) {
                return Err(blocked(
                    "Disabling a project requires drained writers and frozen synchronization.",
                    "project_not_drained",
                    "Drain or safely freeze active work and sync, then retry the rollback.",
                ));
            }
            let mut record = Dict::new();
            record.insert("enabled", enabled);
            record.insert("updated_at", self.timestamp());
            let mut projects = object(document, "project_opt_ins").clone();
            projects.insert(project_id, Value::Dict(record));
            document.insert("project_opt_ins", Value::Dict(projects));
            self.advance(document, "project_opt_in_changed");
            Ok(())
        })?;
        self.decision(project_id, "existing", false)
    }

    pub fn promote_cohort(&self, cohort: &str, confirmed: bool) -> Result<Dict> {
        validate_cohort(cohort)?;
        if cohort == PROJECT_OPT_IN {
            return Err(blocked(
                "The per-project opt-in cohort is the baseline and projects remain individually off.",
                "baseline_cohort",
                "Use an explicit per-project opt-in; do not replace it with a global default.",
            ));
        }
        if !confirmed {
            return Err(blocked(
                format!("Promoting {cohort} requires an explicit operator confirmation."),
                "cohort_confirmation_required",
                "Review accepted evidence and recovery documentation, then confirm promotion.",
            ));
        }
        self.locked_document(|document| {
            let missing = missing_evidence(document, cohort);
            if !missing.is_empty() {
                return Err(blocked(
                    format!(
                        "Cohort {cohort} is missing accepted evidence: {}.",
                        missing.join(", ")
                    ),
                    "cohort_evidence_incomplete",
                    "Record accepted external evidence for every listed kind; source tests alone are insufficient.",
                ));
            }
            let timestamp = self.timestamp();
            self.update_cohort(document, cohort, |state| {
                state.insert("enabled", true);
                state.insert("paused", false);
                state.insert("writes_allowed", true);
                state.insert("sync_allowed", true);
                state.insert("updated_at", timestamp.as_str());
            });
            self.advance(document, "cohort_promoted");
            Ok(())
        })?;
        self.diagnostics(None)
    }

    pub fn pause_cohort(
        &self,
        cohort: &str,
        writers_drained: bool,
        sync_frozen: bool,
        reason_code: &str,
    ) -> Result<Dict> {
        validate_cohort(cohort)?;
        validate_id(&Value::from(reason_code), "reason code")?;
        if !writers_drained || !sync_frozen {
            return Err(blocked(
                "A cohort kill switch requires drained writers and safely frozen synchronization.",
                "cohort_not_drained",
                "Drain or freeze active work without deleting refs/history, then retry the kill switch.",
            ));
        }
        self.locked_document(|document| {
            let timestamp = self.timestamp();
            self.update_cohort(document, cohort, |state| {
                state.insert("paused", true);
                state.insert("writes_allowed", false);
                state.insert("sync_allowed", false);
                state.insert("pause_reason_code", reason_code);
                state.insert("updated_at", timestamp.as_str());
            });
            self.advance(document, "cohort_paused");
            Ok(())
        })?;
        self.diagnostics(None)
    }

    pub fn resume_cohort(&self, cohort: &str, confirmed: bool) -> Result<Dict> {
        validate_cohort(cohort)?;
        if !confirmed {
            return Err(blocked(
                "Resuming a rollout cohort requires explicit confirmation.",
                "cohort_confirmation_required",
                "Review the failure and preserved refs/history before resuming.",
            ));
        }
        self.locked_document(|document| {
            let state = object(object(document, "cohorts"), cohort);
            if cohort != PROJECT_OPT_IN && !flag(state, "enabled") {
                return Err(blocked(
                    format!("Cohort {cohort} has not been promoted."),
                    "cohort_not_promoted",
                    "Satisfy its evidence gate and explicitly promote it first.",
                ));
            }
            let missing = missing_evidence(document, cohort);
            if cohort != PROJECT_OPT_IN && !missing.is_empty() {
                return Err(blocked(
                    format!(
                        "Cohort {cohort} no longer has accepted evidence: {}.",
                        missing.join(", ")
                    ),
                    "cohort_evidence_incomplete",
                    "Resolve the rejected evidence and record a new immutable acceptance record.",
                ));
            }
            let timestamp = self.timestamp();
            self.update_cohort(document, cohort, |state| {
                state.insert("paused", false);
                state.insert("writes_allowed", true);
                state.insert("sync_allowed", true);
                state.insert("pause_reason_code", Value::Null);
                state.insert("updated_at", timestamp.as_str());
            });
            self.advance(document, "cohort_resumed");
            Ok(())
        })?;
        self.diagnostics(None)
    }

    pub fn decision(
        &self,
        project_id: &str,
        project_kind: &str,
        configured_opt_in: bool,
    ) -> Result<RolloutDecision> {
        validate_id(&Value::from(project_id), "project ID")?;
        if !["existing", "new", "legacy"].contains(&project_kind) {
            return Err(rollout_error(
                format!("Unsupported project kind: {}", pystr::repr(project_kind)),
                "invalid_project_kind",
                "Use existing, new, or legacy after confirming registry identity.",
            ));
        }
        if configured_opt_in && project_kind != "existing" {
            return Err(rollout_error(
                "A repository-configured opt-in is valid only for an existing project.",
                "invalid_configured_opt_in",
                "Use the staged new-project or legacy cohort decision for this project.",
            ));
        }
        let document = self.load()?;
        if document
            .get("recovery_state")
            .is_some_and(|state| state.is_str("primary_corrupt_using_backup"))
        {
            return Err(blocked(
                "Artifact rollout policy is using a backup; new artifact starts remain blocked until reviewed repair.",
                "rollout_state_recovery_required",
                "Stop artifact writers, repair the primary policy from the reviewed backup, then explicitly resume the intended cohort.",
            ));
        }
        let explicit = object(&document, "project_opt_ins")
            .get(project_id)
            .and_then(Value::as_dict)
            .and_then(|record| record.get("enabled"))
            .and_then(|enabled| match enabled {
                Value::Bool(flag) => Some(*flag),
                _ => None,
            });
        let cohorts = object(&document, "cohorts");
        if explicit == Some(false) {
            return Ok(decision(
                project_id,
                None,
                false,
                false,
                false,
                "explicit_project_opt_out",
            ));
        }
        if explicit == Some(true) || configured_opt_in {
            let state = object(cohorts, PROJECT_OPT_IN);
            let enabled = !flag(state, "paused") && flag(state, "writes_allowed");
            let reason_code = if !enabled {
                "project_opt_in_kill_switch"
            } else if explicit == Some(true) {
                "explicit_project_opt_in"
            } else {
                "configured_project_opt_in"
            };
            return Ok(decision(
                project_id,
                Some(PROJECT_OPT_IN),
                enabled,
                enabled && flag(state, "sync_allowed"),
                false,
                reason_code,
            ));
        }
        if project_kind == "new" {
            let state = object(cohorts, NEW_PROJECT_DEFAULT);
            let enabled =
                flag(state, "enabled") && !flag(state, "paused") && flag(state, "writes_allowed");
            return Ok(decision(
                project_id,
                flag(state, "enabled").then_some(NEW_PROJECT_DEFAULT),
                enabled,
                enabled && flag(state, "sync_allowed"),
                false,
                if enabled {
                    "new_project_default"
                } else {
                    "new_project_default_gated"
                },
            ));
        }
        if project_kind == "legacy" {
            let state = object(cohorts, LEGACY_MIGRATION_OFFER);
            let offer = flag(state, "enabled") && !flag(state, "paused");
            return Ok(decision(
                project_id,
                flag(state, "enabled").then_some(LEGACY_MIGRATION_OFFER),
                false,
                false,
                offer,
                if offer {
                    "legacy_migration_offered"
                } else {
                    "legacy_migration_gated"
                },
            ));
        }
        Ok(decision(
            project_id,
            None,
            false,
            false,
            false,
            "project_default_off",
        ))
    }

    /// Bounded, privacy-safe rollout diagnostics only.
    pub fn diagnostics(&self, document: Option<&Dict>) -> Result<Dict> {
        let current = match document {
            Some(document) if !document.is_empty() => document.clone(),
            _ => self.load()?,
        };
        let latest = latest_evidence(&current);
        let mut cohorts = Dict::new();
        let all = object(&current, "cohorts");
        for name in COHORTS {
            let state = object(all, name);
            let missing = missing_evidence(&current, name);
            let mut summary = Dict::new();
            summary.insert("enabled", flag(state, "enabled"));
            summary.insert("paused", flag(state, "paused"));
            summary.insert("writes_allowed", flag(state, "writes_allowed"));
            summary.insert("sync_allowed", flag(state, "sync_allowed"));
            summary.insert(
                "missing_evidence",
                Value::List(missing.into_iter().map(Value::from).collect()),
            );
            summary.insert(
                "pause_reason_code",
                state
                    .get("pause_reason_code")
                    .cloned()
                    .unwrap_or(Value::Null),
            );
            cohorts.insert(name, Value::Dict(summary));
        }
        let revision = current
            .get("revision")
            .and_then(Value::py_int)
            .unwrap_or_default();
        let opt_in_count = object(&current, "project_opt_ins")
            .iter()
            .filter(|(_, value)| {
                value
                    .as_dict()
                    .and_then(|record| record.get("enabled"))
                    .is_some_and(|enabled| matches!(enabled, Value::Bool(true)))
            })
            .count();
        let mut evidence = Dict::new();
        for (kind, item) in &latest {
            let mut summary = Dict::new();
            let field = |key: &str| item.get(key).cloned().unwrap_or(Value::Null);
            summary.insert("outcome", field("outcome"));
            summary.insert("report_sha256", field("report_sha256"));
            summary.insert("bundle_sha256", field("bundle_sha256"));
            summary.insert(
                "providers",
                Value::List(tuple_or_empty(item.get("providers"))?),
            );
            summary.insert(
                "scenario_count",
                tuple_or_empty(item.get("scenario_ids"))?.len() as i64,
            );
            summary.insert("rejection_code", field("rejection_code"));
            evidence.insert(kind, Value::Dict(summary));
        }
        let mut result = Dict::new();
        result.insert("schema_version", ROLLOUT_SCHEMA_VERSION);
        result.insert("revision", revision);
        result.insert(
            "last_event",
            current.get("last_event").cloned().unwrap_or(Value::Null),
        );
        result.insert(
            "recovery_state",
            current
                .get("recovery_state")
                .cloned()
                .unwrap_or_else(|| Value::from("normal")),
        );
        result.insert("cohorts", Value::Dict(cohorts));
        result.insert("project_opt_in_count", opt_in_count as i64);
        result.insert("evidence", Value::Dict(evidence));
        Ok(result)
    }

    // -- validation and persistence -------------------------------------

    fn default_document(&self) -> Dict {
        let timestamp = self.timestamp();
        let cohort = |enabled: bool| {
            let mut state = Dict::new();
            state.insert("enabled", enabled);
            state.insert("paused", false);
            state.insert("writes_allowed", enabled);
            state.insert("sync_allowed", enabled);
            state.insert("pause_reason_code", Value::Null);
            state.insert("updated_at", timestamp.as_str());
            Value::Dict(state)
        };
        let mut cohorts = Dict::new();
        cohorts.insert(PROJECT_OPT_IN, cohort(true));
        cohorts.insert(NEW_PROJECT_DEFAULT, cohort(false));
        cohorts.insert(LEGACY_MIGRATION_OFFER, cohort(false));
        let mut document = Dict::new();
        document.insert("schema_version", ROLLOUT_SCHEMA_VERSION);
        document.insert("revision", 0i64);
        document.insert("last_event", "initialized_default_off");
        document.insert("updated_at", timestamp.as_str());
        document.insert("cohorts", Value::Dict(cohorts));
        document.insert("project_opt_ins", Value::Dict(Dict::new()));
        document.insert("evidence", Value::List(Vec::new()));
        document
    }

    fn read_document(&self, path: &Path) -> Result<Dict> {
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let invalid = |detail: String| {
            rollout_error(
                format!("Invalid rollout state at {name}: {detail}"),
                "invalid_rollout_state",
                "Restore a reviewed backup while artifact writers are stopped.",
            )
        };
        let bytes = fs::read(path).map_err(|error| invalid(os_error(&error, path)))?;
        let text = pystr::decode_utf8(&bytes).map_err(|error| invalid(error.message))?;
        let text = pystr::universal_newlines(text);
        let value = match json::parse_reporting(&text) {
            Some((value, surrogates)) if surrogates.is_empty() => value,
            Some(_) => return Err(invalid("lone surrogate escape".to_string())),
            None => return Err(invalid("Expecting value".to_string())),
        };
        validate_document(&value, self)?;
        match value {
            Value::Dict(document) => Ok(document),
            _ => unreachable!("validated rollout document"),
        }
    }

    fn validate_evidence(&self, evidence: &RolloutEvidence) -> Result<RolloutEvidence> {
        validate_id(&evidence.evidence_id, "evidence ID")?;
        if !member(&evidence.kind, &EVIDENCE_KINDS)? {
            return Err(rollout_error(
                format!(
                    "Unsupported rollout evidence kind: {}",
                    py_repr(&evidence.kind)
                ),
                "invalid_evidence_kind",
                "Use a documented bounded evidence kind.",
            ));
        }
        if !member(&evidence.outcome, &["accepted", "rejected"])? {
            return Err(rollout_error(
                "Rollout evidence outcome must be accepted or rejected.",
                "invalid_evidence_outcome",
                "Record the external review result explicitly.",
            ));
        }
        let timestamp_error = |message: &str| {
            rollout_error(
                message,
                "invalid_evidence_timestamp",
                "Record a UTC evidence timestamp.",
            )
        };
        let parsed = evidence
            .recorded_at
            .as_str()
            .and_then(|text| isotime::fromisoformat(&text.replace('Z', "+00:00")).ok())
            .ok_or_else(|| timestamp_error("Rollout evidence timestamp must be ISO-8601."))?;
        if parsed.offset_us.is_none() {
            return Err(timestamp_error(
                "Rollout evidence timestamp must include a timezone.",
            ));
        }
        validate_sha(&evidence.report_sha256, "report SHA-256")?;
        if !matches!(evidence.bundle_sha256, Value::Null) {
            validate_sha(&evidence.bundle_sha256, "bundle SHA-256")?;
        }
        for (value, label) in [
            (&evidence.build_version, "build version"),
            (&evidence.build_number, "build number"),
            (&evidence.signer_team_id, "signer team ID"),
            (&evidence.rejection_code, "rejection code"),
        ] {
            if matches!(value, Value::Null) {
                continue;
            }
            if !is_safe_version(require_text(value)?) {
                return Err(rollout_error(
                    format!("Rollout evidence {label} is not a bounded identifier."),
                    "unsafe_evidence_field",
                    "Use an identifier only; keep paths, logs, transcripts, and free-form text outside diagnostics.",
                ));
            }
        }
        let providers = sorted_set(&evidence.providers)?;
        if providers
            .iter()
            .any(|provider| !provider.is_str("codex") && !provider.is_str("claude"))
        {
            return Err(rollout_error(
                "Rollout provider evidence is invalid.",
                "invalid_evidence_provider",
                "Use only codex and claude provider identifiers.",
            ));
        }
        let scenarios = sorted_set(&evidence.scenario_ids)?;
        let unsafe_scenarios = rollout_error(
            "Rollout scenario evidence contains an unsafe or unbounded identifier.",
            "unsafe_evidence_scenarios",
            "Use at most 128 documented lowercase scenario IDs.",
        );
        if scenarios.len() > 128 {
            return Err(unsafe_scenarios);
        }
        for scenario in &scenarios {
            if !is_scenario_id(require_text(scenario)?) {
                return Err(unsafe_scenarios);
            }
        }
        if evidence.outcome.is_str("rejected") && matches!(evidence.rejection_code, Value::Null) {
            return Err(rollout_error(
                "Rejected evidence requires a stable rejection code.",
                "missing_rejection_code",
                "Record a bounded reason code; keep detailed recovery in the verification report.",
            ));
        }
        if (evidence.kind.is_str("signed_installed_workspace")
            || evidence.kind.is_str("installed_provider_parity"))
            && (!evidence.bundle_sha256.truthy() || !evidence.signer_team_id.truthy())
        {
            return Err(rollout_error(
                "Installed evidence requires signed bundle identity.",
                "missing_signed_bundle_identity",
                "Verify the Developer ID signed installed app and record its bundle hash and team ID.",
            ));
        }
        if evidence.kind.is_str("installed_provider_parity")
            && !(providers.len() == 2
                && providers.iter().any(|provider| provider.is_str("codex"))
                && providers.iter().any(|provider| provider.is_str("claude")))
        {
            return Err(rollout_error(
                "Installed provider parity evidence must cover Codex and Claude.",
                "provider_parity_incomplete",
                "Run the same installed scope/lifecycle scenarios with both providers.",
            ));
        }
        Ok(RolloutEvidence {
            providers,
            scenario_ids: scenarios,
            ..evidence.clone()
        })
    }

    /// `_locked_document`: the document under the exclusive lock, written
    /// back only when the work changed it.
    fn locked_document<T>(&self, work: impl FnOnce(&mut Dict) -> Result<T>) -> Result<T> {
        fs::create_dir_all(&self.rollout_root)
            .map_err(|error| io_error(&error, &self.rollout_root))?;
        let handle = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(&self.lock_path)
            .map_err(|error| io_error(&error, &self.lock_path))?;
        handle
            .lock()
            .map_err(|error| io_error(&error, &self.lock_path))?;
        let result = (|| {
            let mut document = self.load()?;
            // Never persist the transient load diagnostic marker.
            document.remove("recovery_state");
            let before = json::dumps_compact_sorted(&Value::Dict(document.clone()));
            let value = work(&mut document)?;
            validate_document(&Value::Dict(document.clone()), self)?;
            let after = json::dumps_compact_sorted(&Value::Dict(document.clone()));
            if after != before {
                self.write_atomic(&document)?;
            }
            Ok(value)
        })();
        let _ = handle.unlock();
        result
    }

    fn write_atomic(&self, document: &Dict) -> Result<()> {
        let payload = format!("{}\n", dumps_indent_sorted(&Value::Dict(document.clone())));
        let primary_valid = match self.path.exists() {
            false => false,
            true => match self.read_document(&self.path) {
                Ok(_) => true,
                // A valid backup is the recovery authority. Never replace it
                // with corrupt primary bytes while repairing the primary.
                Err(error) if error.kind == ErrorKind::Rollout => false,
                Err(error) => return Err(error),
            },
        };
        if primary_valid {
            let current = fs::read(&self.path).map_err(|error| io_error(&error, &self.path))?;
            replace_file(&self.backup_path, &current)?;
        }
        replace_file(&self.path, payload.as_bytes())
    }

    fn update_cohort(&self, document: &mut Dict, cohort: &str, change: impl FnOnce(&mut Dict)) {
        let mut cohorts = object(document, "cohorts").clone();
        let mut state = object(&cohorts, cohort).clone();
        change(&mut state);
        cohorts.insert(cohort, Value::Dict(state));
        document.insert("cohorts", Value::Dict(cohorts));
    }

    fn advance(&self, document: &mut Dict, event: &str) {
        let revision = document
            .get("revision")
            .and_then(Value::py_int)
            .unwrap_or_default();
        document.insert("revision", revision + 1);
        document.insert("last_event", event);
        document.insert("updated_at", self.timestamp());
    }

    fn timestamp(&self) -> String {
        (self.now)().isoformat_z()
    }
}

fn validate_document(value: &Value, store: &ArtifactRolloutStore) -> Result<()> {
    let document = match value {
        Value::Dict(document)
            if same_keys(document, &DOCUMENT_KEYS)
                && json::py_eq_optional(
                    document.get("schema_version"),
                    Some(&Value::Int(ROLLOUT_SCHEMA_VERSION)),
                ) =>
        {
            document
        }
        _ => {
            return Err(rollout_error(
                "Unsupported artifact rollout state schema.",
                "invalid_rollout_schema",
                "Upgrade Relay Runner or restore a compatible reviewed backup.",
            ));
        }
    };
    if !matches!(
        document.get("revision"),
        Some(Value::Bool(_)) | Some(Value::Int(0..))
    ) {
        return Err(rollout_error(
            "Artifact rollout revision is invalid.",
            "invalid_rollout_revision",
            "Restore a reviewed backup while writers are stopped.",
        ));
    }
    let cohorts = match document.get("cohorts") {
        Some(Value::Dict(cohorts)) if same_keys(cohorts, &COHORTS) => cohorts,
        _ => {
            return Err(rollout_error(
                "Artifact rollout cohorts are incomplete.",
                "invalid_rollout_cohorts",
                "Restore a reviewed schema-1 rollout document.",
            ));
        }
    };
    for (name, state) in cohorts.iter() {
        let state = match state {
            Value::Dict(state) if same_keys(state, &COHORT_KEYS) => state,
            _ => {
                return Err(rollout_error(
                    format!("Rollout cohort {name} is invalid."),
                    "invalid_rollout_cohort",
                    "Restore a reviewed rollout document.",
                ));
            }
        };
        for key in ["enabled", "paused", "writes_allowed", "sync_allowed"] {
            if !matches!(state.get(key), Some(Value::Bool(_))) {
                return Err(rollout_error(
                    format!("Rollout cohort {name} has invalid {key}."),
                    "invalid_rollout_cohort",
                    "Restore a reviewed rollout document.",
                ));
            }
        }
    }
    let Some(Value::Dict(projects)) = document.get("project_opt_ins") else {
        return Err(rollout_error(
            "Per-project opt-in state is invalid.",
            "invalid_project_opt_ins",
            "Restore a reviewed rollout document.",
        ));
    };
    for (project_id, state) in projects.iter() {
        validate_id(&Value::from(project_id), "project ID")?;
        let valid = matches!(state, Value::Dict(state)
            if same_keys(state, &PROJECT_OPT_IN_KEYS)
                && matches!(state.get("enabled"), Some(Value::Bool(_))));
        if !valid {
            return Err(rollout_error(
                format!(
                    "Per-project opt-in state is invalid for {}.",
                    pystr::repr(project_id)
                ),
                "invalid_project_opt_ins",
                "Restore a reviewed rollout document.",
            ));
        }
    }
    let Some(Value::List(evidence)) = document.get("evidence") else {
        return Err(rollout_error(
            "Rollout evidence list is invalid.",
            "invalid_rollout_evidence",
            "Restore a reviewed rollout document.",
        ));
    };
    let mut seen: Vec<Value> = Vec::new();
    for raw in evidence {
        let raw = match raw {
            Value::Dict(raw) if same_keys(raw, &EVIDENCE_KEYS) => raw,
            _ => {
                return Err(rollout_error(
                    "Rollout evidence entry has an unsupported or missing field.",
                    "invalid_rollout_evidence",
                    "Restore a reviewed rollout document.",
                ));
            }
        };
        let parsed = store.validate_evidence(&RolloutEvidence::from_raw(raw)?)?;
        if seen.iter().any(|id| json::py_eq(id, &parsed.evidence_id)) {
            return Err(rollout_error(
                "Rollout evidence IDs are not unique.",
                "duplicate_rollout_evidence",
                "Restore a reviewed rollout document and reconcile immutable evidence IDs.",
            ));
        }
        seen.push(parsed.evidence_id);
    }
    Ok(())
}

/// `_latest_evidence`: the last entry of each kind, by kind.
fn latest_evidence(document: &Dict) -> Vec<(String, Dict)> {
    let mut latest: Vec<(String, Dict)> = Vec::new();
    for item in document
        .get("evidence")
        .and_then(Value::as_list)
        .unwrap_or_default()
    {
        let Some(item) = item.as_dict() else { continue };
        let kind = item.get("kind").map(Value::py_str).unwrap_or_default();
        match latest.iter_mut().find(|(existing, _)| *existing == kind) {
            Some(entry) => entry.1 = item.clone(),
            None => latest.push((kind, item.clone())),
        }
    }
    latest.sort_by(|left, right| left.0.cmp(&right.0));
    latest
}

fn missing_evidence(document: &Dict, cohort: &str) -> Vec<String> {
    if cohort == PROJECT_OPT_IN {
        return Vec::new();
    }
    let required: &[&str] = if cohort == NEW_PROJECT_DEFAULT {
        &NEW_PROJECT_REQUIRED_EVIDENCE
    } else {
        &LEGACY_REQUIRED_EVIDENCE
    };
    let latest = latest_evidence(document);
    let mut missing: Vec<String> = required
        .iter()
        .filter(|kind| {
            !latest.iter().any(|(existing, item)| {
                existing == *kind
                    && item
                        .get("outcome")
                        .is_some_and(|outcome| outcome.is_str("accepted"))
            })
        })
        .map(|kind| kind.to_string())
        .collect();
    missing.sort();
    missing
}

/// Python's `str(OSError)`: `[Errno N] description: 'path'`.
fn os_error(error: &std::io::Error, path: &Path) -> String {
    let description = error.to_string();
    let description = match error.raw_os_error() {
        Some(code) => {
            let suffix = format!(" (os error {code})");
            let text = description.strip_suffix(&suffix).unwrap_or(&description);
            format!("[Errno {code}] {text}")
        }
        None => description,
    };
    format!("{description}: {}", pystr::repr(&path.to_string_lossy()))
}

fn io_error(error: &std::io::Error, path: &Path) -> Error {
    Error::new(ErrorKind::Io, os_error(error, path))
}

/// `tempfile.mkstemp`'s random part: eight characters of `[a-z0-9_]`.
fn random_name() -> String {
    const CHARACTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789_";
    let mut bytes = [0u8; 8];
    let read = File::open("/dev/urandom").and_then(|mut source| source.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = ((nanos as u64) ^ u64::from(std::process::id())).to_le_bytes();
    }
    bytes
        .iter()
        .map(|byte| CHARACTERS[usize::from(*byte) % CHARACTERS.len()] as char)
        .collect()
}

/// `_replace_file`: a 0600 temporary file in the destination's directory,
/// synced, renamed over the destination, then the directory synced.
fn replace_file(destination: &Path, payload: &[u8]) -> Result<()> {
    let directory = destination.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(directory).map_err(|error| io_error(&error, directory))?;
    let name = destination
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let (temporary, mut handle) = loop {
        let candidate = directory.join(format!(".{name}.{}", random_name()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(handle) => break (candidate, handle),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(io_error(&error, &candidate)),
        }
    };
    let result = (|| {
        handle
            .write_all(payload)
            .and_then(|()| handle.flush())
            .and_then(|()| handle.sync_all())
            .map_err(|error| io_error(&error, &temporary))?;
        drop(handle);
        fs::rename(&temporary, destination).map_err(|error| io_error(&error, &temporary))?;
        File::open(directory)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error(&error, directory))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// `json.dumps(value, sort_keys=True, indent=2)`.
pub fn dumps_indent_sorted(value: &Value) -> String {
    fn write(out: &mut String, value: &Value, level: usize) {
        let pad = |level: usize| "  ".repeat(level);
        match value {
            Value::List(items) if !items.is_empty() => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(level + 1));
                    write(out, item, level + 1);
                }
                out.push('\n');
                out.push_str(&pad(level));
                out.push(']');
            }
            Value::Dict(dict) if !dict.is_empty() => {
                let mut entries: Vec<(&str, &Value)> = dict.iter().collect();
                entries.sort_by(|left, right| left.0.cmp(right.0));
                out.push('{');
                for (index, (key, item)) in entries.into_iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(level + 1));
                    out.push_str(&json::dumps_sorted(&Value::Str(key.to_string())));
                    out.push_str(": ");
                    write(out, item, level + 1);
                }
                out.push('\n');
                out.push_str(&pad(level));
                out.push('}');
            }
            other => out.push_str(&json::dumps_sorted(other)),
        }
    }
    let mut out = String::new();
    write(&mut out, value, 0);
    out
}

/// `privacy_safe_report_digest`: the SHA-256 of a bounded report, after
/// refusing prohibited diagnostic keys and unbounded strings.
pub fn privacy_safe_report_digest(report: &Value) -> Result<String> {
    fn inspect(value: &Value) -> Result<()> {
        match value {
            Value::Dict(dict) => {
                for (key, child) in dict.iter() {
                    if FORBIDDEN_DIAGNOSTIC_KEYS.contains(&key.to_lowercase().as_str()) {
                        return Err(rollout_error(
                            format!(
                                "Verification report contains prohibited diagnostic field: {key}"
                            ),
                            "prohibited_diagnostic_field",
                            "Replace raw/private content with bounded counts, states, IDs, and hashes.",
                        ));
                    }
                    inspect(child)?;
                }
            }
            Value::List(items) => {
                for child in items {
                    inspect(child)?;
                }
            }
            Value::Str(text) if text.len() > 4096 => {
                return Err(rollout_error(
                    "Verification report contains an unbounded string.",
                    "unbounded_diagnostic_field",
                    "Store the detailed evidence separately and report only its hash and stable outcome code.",
                ));
            }
            _ => {}
        }
        Ok(())
    }
    inspect(report)?;
    let payload = json::dumps_compact_sorted(report);
    if payload.len() > 256 * 1024 {
        return Err(rollout_error(
            "Verification report exceeds the 256 KiB diagnostic limit.",
            "diagnostic_report_too_large",
            "Keep bounded outcomes and hashes only.",
        ));
    }
    Ok(relay_intents::sha256::hex_digest(payload.as_bytes()))
}

// -- the command line -------------------------------------------------------

/// One parsed `--option`: its value, or `None` for a flag.
struct Options {
    values: Vec<(String, Option<String>)>,
}

impl Options {
    fn value(&self, name: &str) -> Option<&str> {
        self.values
            .iter()
            .rev()
            .find(|(key, _)| key == name)
            .and_then(|(_, value)| value.as_deref())
    }

    fn flag(&self, name: &str) -> bool {
        self.values.iter().any(|(key, _)| key == name)
    }
}

fn usage_error(message: &str) -> u8 {
    eprintln!(
        "usage: artifact_rollout_cli.py [-h] [--state-root STATE_ROOT] {{status,decision,opt-in,opt-out,record-evidence,promote,pause,resume}} ..."
    );
    eprintln!("artifact_rollout_cli.py: error: {message}");
    2
}

/// argparse's option matching: exact names, `--name=value` and unique
/// prefixes. `valued` options take an argument; the rest are flags.
fn parse_options(
    arguments: &[String],
    valued: &[&str],
    flags: &[&str],
    stop_at_positional: bool,
) -> std::result::Result<(Options, Vec<String>), String> {
    let mut values = Vec::new();
    let mut rest = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if !argument.starts_with("--") || argument == "--" {
            if stop_at_positional {
                rest.extend_from_slice(&arguments[index..]);
                break;
            }
            return Err(format!("unrecognized arguments: {argument}"));
        }
        let (name, inline) = match argument.split_once('=') {
            Some((name, value)) => (name.to_string(), Some(value.to_string())),
            None => (argument.clone(), None),
        };
        let known: Vec<&str> = valued.iter().chain(flags).copied().collect();
        let resolved = if known.contains(&name.as_str()) {
            name.clone()
        } else {
            let matches: Vec<&&str> = known
                .iter()
                .filter(|option| option.starts_with(name.as_str()))
                .collect();
            match matches.as_slice() {
                [only] => only.to_string(),
                [] => return Err(format!("unrecognized arguments: {argument}")),
                _ => return Err(format!("ambiguous option: {name}")),
            }
        };
        if valued.contains(&resolved.as_str()) {
            let value = match inline {
                Some(value) => value,
                None => {
                    index += 1;
                    match arguments.get(index) {
                        Some(value) if !value.starts_with('-') || value.len() == 1 => value.clone(),
                        _ => return Err(format!("argument {resolved}: expected one argument")),
                    }
                }
            };
            values.push((resolved, Some(value)));
        } else {
            if inline.is_some() {
                return Err(format!(
                    "argument {resolved}: ignored explicit argument {:?}",
                    inline.unwrap_or_default()
                ));
            }
            values.push((resolved, None));
        }
        index += 1;
    }
    Ok((Options { values }, rest))
}

fn print_json(value: &Value) {
    println!("{}", dumps_indent_sorted(value));
}

/// `artifact_rollout_cli.main()`: returns the exit status.
pub fn cli_main(arguments: &[String]) -> u8 {
    if arguments
        .iter()
        .any(|argument| argument == "-h" || argument == "--help")
    {
        println!(
            "usage: artifact_rollout_cli.py [-h] [--state-root STATE_ROOT] {{status,decision,opt-in,opt-out,record-evidence,promote,pause,resume}} ...\n\nInspect or explicitly change artifact rollout gates."
        );
        return 0;
    }
    let (global, rest) = match parse_options(arguments, &["--state-root"], &[], true) {
        Ok(parsed) => parsed,
        Err(message) => return usage_error(&message),
    };
    let Some((action, rest)) = rest.split_first() else {
        return usage_error("the following arguments are required: action");
    };
    let (valued, flags): (&[&str], &[&str]) = match action.as_str() {
        "status" => (&[], &[]),
        "decision" => (&["--project-id", "--project-kind"], &[]),
        "opt-in" => (&["--project-id"], &["--confirm"]),
        "opt-out" => (
            &["--project-id"],
            &["--confirm", "--writers-drained", "--sync-frozen"],
        ),
        "record-evidence" => (&["--file"], &[]),
        "promote" | "resume" => (&["--cohort"], &["--confirm"]),
        "pause" => (
            &["--cohort", "--reason-code"],
            &["--writers-drained", "--sync-frozen"],
        ),
        other => {
            return usage_error(&format!(
                "argument action: invalid choice: {} (choose from status, decision, opt-in, opt-out, record-evidence, promote, pause, resume)",
                pystr::repr(other)
            ));
        }
    };
    let options = match parse_options(rest, valued, flags, false) {
        Ok((options, _)) => options,
        Err(message) => return usage_error(&message),
    };
    let missing: Vec<&str> = valued
        .iter()
        .copied()
        .filter(|name| options.value(name).is_none())
        .collect();
    if !missing.is_empty() {
        return usage_error(&format!(
            "the following arguments are required: {}",
            missing.join(", ")
        ));
    }
    let choice = |name: &str, choices: &[&str]| -> std::result::Result<String, u8> {
        let value = options.value(name).unwrap_or_default();
        if choices.contains(&value) {
            Ok(value.to_string())
        } else {
            let quoted: Vec<String> = choices.iter().map(|choice| choice.to_string()).collect();
            Err(usage_error(&format!(
                "argument {name}: invalid choice: {} (choose from {})",
                pystr::repr(value),
                quoted.join(", ")
            )))
        }
    };
    let state_root = global.value("--state-root").map_or_else(
        || {
            let home = std::env::var("HOME").unwrap_or_default();
            PathBuf::from(home).join("Library/Application Support/relay-runner")
        },
        PathBuf::from,
    );
    let outcome = (|| -> std::result::Result<Result<Value>, u8> {
        let store = match ArtifactRolloutStore::new(&state_root, None) {
            Ok(store) => store,
            Err(error) => return Ok(Err(error)),
        };
        Ok(match action.as_str() {
            "status" => store.diagnostics(None).map(Value::Dict),
            "decision" => {
                let kind = choice("--project-kind", &["existing", "new", "legacy"])?;
                store
                    .decision(
                        options.value("--project-id").unwrap_or_default(),
                        &kind,
                        false,
                    )
                    .map(|decision| Value::Dict(decision.as_dict()))
            }
            "opt-in" | "opt-out" => store
                .set_project_opt_in(
                    options.value("--project-id").unwrap_or_default(),
                    action == "opt-in",
                    options.flag("--confirm"),
                    options.flag("--writers-drained"),
                    options.flag("--sync-frozen"),
                )
                .map(|decision| Value::Dict(decision.as_dict())),
            "record-evidence" => {
                record_evidence_file(&store, options.value("--file").unwrap_or_default())
            }
            "promote" => {
                let cohort = choice("--cohort", &COHORTS)?;
                store
                    .promote_cohort(&cohort, options.flag("--confirm"))
                    .map(Value::Dict)
            }
            "pause" => {
                let cohort = choice("--cohort", &COHORTS)?;
                store
                    .pause_cohort(
                        &cohort,
                        options.flag("--writers-drained"),
                        options.flag("--sync-frozen"),
                        options.value("--reason-code").unwrap_or_default(),
                    )
                    .map(Value::Dict)
            }
            _ => {
                let cohort = choice("--cohort", &COHORTS)?;
                store
                    .resume_cohort(&cohort, options.flag("--confirm"))
                    .map(Value::Dict)
            }
        })
    })();
    let result = match outcome {
        Ok(result) => result,
        Err(code) => return code,
    };
    let mut reply = Dict::new();
    match result {
        Ok(value) => {
            reply.insert("ok", true);
            reply.insert("result", value);
            print_json(&Value::Dict(reply));
            0
        }
        Err(error)
            if matches!(
                error.kind,
                ErrorKind::Rollout | ErrorKind::RolloutBlocked | ErrorKind::Io
            ) || error.code.as_deref() == Some("invalid_rollout_input") =>
        {
            reply.insert("ok", false);
            reply.insert(
                "error_code",
                error.code.as_deref().unwrap_or("invalid_rollout_input"),
            );
            reply.insert("error", error.message.as_str());
            reply.insert(
                "recovery",
                error.recovery.as_deref().unwrap_or(
                    "Review the bounded input file and retry without changing cohort state.",
                ),
            );
            print_json(&Value::Dict(reply));
            2
        }
        Err(error) => {
            // Python lets any other exception escape as a traceback.
            eprintln!("{}: {}", error.kind.python_class(), error.message);
            1
        }
    }
}

/// The `record-evidence` action: read the bounded evidence file. Its read,
/// UTF-8 and JSON failures are reported like rollout errors, as the Python
/// CLI catches `OSError`, `UnicodeDecodeError` and `JSONDecodeError`.
fn record_evidence_file(store: &ArtifactRolloutStore, file: &str) -> Result<Value> {
    let input =
        |message: String| Error::new(ErrorKind::Value, message).with_code("invalid_rollout_input");
    let path = PathBuf::from(paths::expanduser(file)?);
    let bytes = fs::read(&path).map_err(|error| io_error(&error, &path))?;
    let text = pystr::decode_utf8(&bytes).map_err(|error| input(error.message))?;
    let text = pystr::universal_newlines(text);
    let raw = json::parse(&text).ok_or_else(|| input("Expecting value".to_string()))?;
    let raw = match raw {
        Value::Dict(raw) if same_keys(&raw, &EVIDENCE_KEYS) => raw,
        _ => {
            return Err(rollout_error(
                "Evidence file must contain exactly the bounded rollout evidence fields.",
                "invalid_rollout_evidence",
                "Use one bounded RolloutEvidence JSON object.",
            ));
        }
    };
    store
        .record_evidence(&RolloutEvidence::from_raw(&raw)?)
        .map(Value::Dict)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(root: &Path) -> ArtifactRolloutStore {
        let fixed = Instant::fromisoformat_z("2026-08-05T00:00:00Z")
            .unwrap()
            .unwrap();
        ArtifactRolloutStore::new(root, Some(Box::new(move || fixed))).unwrap()
    }

    fn temporary() -> PathBuf {
        let root = std::env::temp_dir().join(format!("relay-rollout-unit-{}", random_name()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn indent_matches_python() {
        let value =
            json::parse(r#"{"b": [], "a": {"y": [1, {"z": null}], "x": {}}, "c": "é"}"#).unwrap();
        assert_eq!(
            dumps_indent_sorted(&value),
            "{\n  \"a\": {\n    \"x\": {},\n    \"y\": [\n      1,\n      {\n        \"z\": null\n      }\n    ]\n  },\n  \"b\": [],\n  \"c\": \"\\u00e9\"\n}"
        );
    }

    #[test]
    fn opt_in_writes_and_backs_up() {
        let root = temporary();
        let store = store(&root);
        assert!(
            !store
                .decision("project-a", "existing", false)
                .unwrap()
                .artifact_writes_enabled
        );
        let error = store
            .set_project_opt_in("project-a", true, false, false, false)
            .unwrap_err();
        assert_eq!(error.kind, ErrorKind::RolloutBlocked);
        assert_eq!(error.code.as_deref(), Some("project_confirmation_required"));
        assert!(
            store
                .set_project_opt_in("project-a", true, true, false, false)
                .unwrap()
                .artifact_writes_enabled
        );
        store
            .set_project_opt_in("project-b", true, true, false, false)
            .unwrap();
        assert!(store.backup_path.is_file());
        let diagnostics = store.diagnostics(None).unwrap();
        assert_eq!(diagnostics.get("revision").and_then(Value::py_int), Some(2));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn digest_refuses_private_fields() {
        let report = json::parse(r#"{"rows": [{"RAW_LOG": "x"}]}"#).unwrap();
        let error = privacy_safe_report_digest(&report).unwrap_err();
        assert_eq!(error.code.as_deref(), Some("prohibited_diagnostic_field"));
        let report = json::parse(r#"{"b": 1, "a": "x"}"#).unwrap();
        assert_eq!(
            privacy_safe_report_digest(&report).unwrap(),
            relay_intents::sha256::hex_digest(br#"{"a":"x","b":1}"#)
        );
    }
}
