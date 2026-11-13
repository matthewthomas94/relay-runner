//! The bridge's use of `services/continuity_incidents.py`,
//! `continuity_recovery.py` and `continuity_resume.py` (RR-492): the opaque
//! continuity identities, the recovery capability policies with the typed
//! execution context the daemon hands a component owner, and the resume
//! decision after a stable-health handoff.
//!
//! A `ValueError` the Python raises is an `Err` carrying its message.

use crate::json::{Dict, Value};
use crate::sha256::hex_digest;

/// `opaque_identifier(kind, native_value)`: a stable identifier that does
/// not retain the native one.
pub fn opaque_identifier(kind: &str, native_value: &str) -> Result<String, &'static str> {
    if kind != "session" && kind != "command" {
        return Err("opaque identifier kind must be session or command");
    }
    if native_value.is_empty() {
        return Err("opaque identifier source must not be empty");
    }
    let digest = hex_digest(format!("continuity-v1:{kind}:{native_value}").as_bytes());
    Ok(format!("{kind}-{}", &digest[..24]))
}

/// `_RECOVERY_GENERATION_RE.fullmatch(text)`:
/// `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`.
fn is_recovery_generation(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b".-_:".contains(b))
}

/// `normalize_recovery_generation(value)`: the lossless wire identity every
/// continuity component uses; a non-negative integer becomes its digits.
/// `None` is a missing value.
pub fn normalize_recovery_generation(value: Option<&Value>) -> Result<String, &'static str> {
    const INVALID: &str = "invalid recovery generation";
    let text = match value {
        Some(Value::Int(number)) if *number >= 0 => number.to_string(),
        Some(Value::BigInt(digits)) if !digits.starts_with('-') => digits.clone(),
        Some(Value::Str(text)) => text.clone(),
        _ => return Err(INVALID),
    };
    if is_recovery_generation(&text) {
        Ok(text)
    } else {
        Err(INVALID)
    }
}

/// `_CODE_RE.fullmatch(text)`: `[a-z][a-z0-9_]{0,63}`.
fn is_code(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

/// `<prefix>[0-9a-f]{length}` in full.
fn is_prefixed_hex(text: &str, prefix: &str, length: usize) -> bool {
    text.strip_prefix(prefix).is_some_and(|hex| {
        hex.len() == length
            && hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

const LIVENESS: [&str; 6] = [
    "healthy",
    "slow",
    "unhealthy",
    "stalled",
    "confirmed_dead",
    "unknown",
];
const IDEMPOTENCY_STATES: [&str; 4] = ["new", "applied", "compensated", "conflict"];
const SAFE_COMMAND_PHASES: [&str; 7] = [
    "none",
    "before_command",
    "captured",
    "undelivered",
    "unclaimed",
    "claimed",
    "in_flight",
];
const UNHEALTHY_OR_DEAD: [&str; 2] = ["unhealthy", "confirmed_dead"];
const CONFIRMED_DEAD: [&str; 1] = ["confirmed_dead"];

/// `_COMPONENT_OWNERS`.
const COMPONENT_OWNERS: [(&str, &str); 9] = [
    ("speech_capture", "app"),
    ("transcription", "app"),
    ("bridge", "app"),
    ("messenger", "bridge"),
    ("foreground_provider", "app"),
    ("orchestrator", "daemon"),
    ("daemon", "app"),
    ("session", "bridge"),
    ("command", "daemon"),
];
const ALL_COMPONENTS: [&str; 9] = [
    "speech_capture",
    "transcription",
    "bridge",
    "messenger",
    "foreground_provider",
    "orchestrator",
    "daemon",
    "session",
    "command",
];

/// `RecoveryCapabilityPolicy`: who executes a capability, for which
/// components and phases, and how often.
#[derive(Debug)]
pub struct RecoveryCapabilityPolicy {
    /// The executing owner, or `dynamic` for the component's own owner.
    pub owner: &'static str,
    pub components: &'static [&'static str],
    pub phases: &'static [&'static str],
    pub postcondition: &'static str,
    pub max_attempts: i64,
    pub cooldown_seconds: f64,
    pub required_liveness: &'static [&'static str],
    pub command_phases: &'static [&'static str],
}

const fn policy(
    owner: &'static str,
    components: &'static [&'static str],
    phases: &'static [&'static str],
    postcondition: &'static str,
) -> RecoveryCapabilityPolicy {
    RecoveryCapabilityPolicy {
        owner,
        components,
        phases,
        postcondition,
        max_attempts: 2,
        cooldown_seconds: 5.0,
        required_liveness: &UNHEALTHY_OR_DEAD,
        command_phases: &SAFE_COMMAND_PHASES,
    }
}

/// `CAPABILITY_POLICIES`, by capability name.
pub static CAPABILITY_POLICIES: [(&str, RecoveryCapabilityPolicy); 10] = [
    (
        "check_processing_health",
        RecoveryCapabilityPolicy {
            max_attempts: 4,
            cooldown_seconds: 0.0,
            required_liveness: &LIVENESS,
            ..policy(
                "dynamic",
                &ALL_COMPONENTS,
                &[
                    "capture",
                    "transcription",
                    "delivery",
                    "component_liveness",
                    "provider_turn",
                    "command_processing",
                    "session_liveness",
                ],
                "processing_health_observed",
            )
        },
    ),
    (
        "reinitialize_speech_capture",
        policy(
            "app",
            &["speech_capture"],
            &["capture"],
            "capture_progress_observed",
        ),
    ),
    (
        "reinitialize_transcription_delivery",
        RecoveryCapabilityPolicy {
            command_phases: &["none", "before_command", "captured", "undelivered"],
            ..policy(
                "app",
                &["transcription"],
                &["transcription", "delivery"],
                "transcription_completed",
            )
        },
    ),
    (
        "restart_bridge",
        policy(
            "app",
            &["bridge"],
            &["delivery", "component_liveness"],
            "bridge_process_alive",
        ),
    ),
    (
        "restart_messenger",
        policy(
            "bridge",
            &["messenger"],
            &["component_liveness"],
            "messenger_process_alive",
        ),
    ),
    (
        "restart_daemon",
        RecoveryCapabilityPolicy {
            required_liveness: &CONFIRMED_DEAD,
            max_attempts: 1,
            cooldown_seconds: 15.0,
            ..policy(
                "app",
                &["daemon"],
                &["component_liveness"],
                "daemon_process_alive",
            )
        },
    ),
    (
        "reconnect_ipc",
        policy(
            "dynamic",
            &["bridge", "messenger", "orchestrator", "daemon", "session"],
            &["delivery", "component_liveness", "session_liveness"],
            "ipc_connection_restored",
        ),
    ),
    (
        "restore_session_registration",
        policy(
            "bridge",
            &["orchestrator", "session"],
            &["component_liveness", "session_liveness"],
            "session_heartbeat_fresh",
        ),
    ),
    (
        "release_dead_ownership",
        RecoveryCapabilityPolicy {
            required_liveness: &CONFIRMED_DEAD,
            max_attempts: 1,
            ..policy(
                "dynamic",
                &["foreground_provider", "orchestrator", "session", "command"],
                &[
                    "provider_turn",
                    "component_liveness",
                    "session_liveness",
                    "command_processing",
                ],
                "dead_ownership_released",
            )
        },
    ),
    (
        "launch_foreground_provider",
        RecoveryCapabilityPolicy {
            required_liveness: &CONFIRMED_DEAD,
            max_attempts: 1,
            cooldown_seconds: 15.0,
            ..policy(
                "app",
                &["foreground_provider", "session"],
                &["provider_turn", "session_liveness"],
                "provider_process_alive",
            )
        },
    ),
];

/// `CAPABILITY_POLICIES.get(capability)`.
pub fn capability_policy(capability: &str) -> Option<&'static RecoveryCapabilityPolicy> {
    CAPABILITY_POLICIES
        .iter()
        .find(|(name, _)| *name == capability)
        .map(|(_, policy)| policy)
}

/// `recovery_owner_for(capability, component)`: who executes the
/// capability for that component, or `""` for none.
pub fn recovery_owner_for(capability: &str, component: &str) -> &'static str {
    let Some(policy) = capability_policy(capability) else {
        return "";
    };
    if policy.owner != "dynamic" {
        return policy.owner;
    }
    COMPONENT_OWNERS
        .iter()
        .find(|(name, _)| *name == component)
        .map_or("", |(_, owner)| owner)
}

/// `RecoveryActionRequest`.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryActionRequest {
    pub capability: String,
    pub incident_id: String,
    pub session_id: String,
    pub command_id: Option<String>,
    pub component: String,
    pub provider: String,
    pub recovery_generation: String,
    pub incident_phase: String,
    pub process_identity: String,
    pub attempt: i64,
    pub idempotency_key: String,
    pub expected_postcondition: String,
    pub incident_observed_at: f64,
    pub deadline: f64,
}

/// `RecoveryActionValidation`, without the owner's health evidence, which
/// no IPC payload carries.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryActionValidation {
    pub validation_token: String,
    pub exact_target_owned: bool,
    pub liveness: String,
    pub incident_active: bool,
    pub generation_matches: bool,
    pub command_phase: String,
    pub command_phase_matches: bool,
    pub idempotency_state: String,
    pub compensation_available: bool,
    pub cooldown_remaining: f64,
    pub expected_postcondition: String,
}

/// `RecoveryExecutionContext`: the typed request plus the validation carried
/// to the executing component.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryExecutionContext {
    pub request: RecoveryActionRequest,
    pub validation: RecoveryActionValidation,
}

const INVALID_CONTEXT: &str = "invalid_recovery_context";

/// The typed readers of `from_mapping`: no coercion is accepted.
struct Fields<'a>(&'a Dict);

impl Fields<'_> {
    fn string(&self, name: &str, valid: impl Fn(&str) -> bool) -> Result<String, &'static str> {
        match self.0.get(name) {
            Some(Value::Str(text)) if valid(text) => Ok(text.clone()),
            _ => Err(INVALID_CONTEXT),
        }
    }

    fn code(&self, name: &str) -> Result<String, &'static str> {
        self.string(name, is_code)
    }

    fn integer(&self, name: &str, minimum: i64) -> Result<i64, &'static str> {
        match self.0.get(name) {
            Some(Value::Int(number)) if *number >= minimum => Ok(*number),
            // Beyond i64 a Python int is still accepted; it can only exceed
            // every attempt limit.
            Some(Value::BigInt(digits)) if !digits.starts_with('-') => Ok(i64::MAX),
            _ => Err(INVALID_CONTEXT),
        }
    }

    fn number(&self, name: &str) -> Result<f64, &'static str> {
        let number = match self.0.get(name) {
            Some(Value::Int(number)) => *number as f64,
            Some(Value::BigInt(digits)) => digits.parse().map_err(|_| INVALID_CONTEXT)?,
            Some(Value::Float(number)) => *number,
            _ => return Err(INVALID_CONTEXT),
        };
        if number.is_finite() {
            Ok(number)
        } else {
            Err(INVALID_CONTEXT)
        }
    }

    fn boolean(&self, name: &str) -> Result<bool, &'static str> {
        match self.0.get(name) {
            Some(Value::Bool(flag)) => Ok(*flag),
            _ => Err(INVALID_CONTEXT),
        }
    }
}

impl RecoveryExecutionContext {
    /// `RecoveryExecutionContext.from_mapping(payload)`: parses an IPC
    /// payload without accepting coercions or extra authority.
    pub fn from_mapping(payload: &Dict) -> Result<Self, &'static str> {
        let fields = Fields(payload);
        let command_id = match payload.get("command_id") {
            None | Some(Value::Null) => None,
            Some(_) => {
                Some(fields.string("command_id", |text| is_prefixed_hex(text, "command-", 24))?)
            }
        };
        let recovery_generation = match payload.get("recovery_generation") {
            Some(value @ Value::Str(_)) => {
                normalize_recovery_generation(Some(value)).map_err(|_| INVALID_CONTEXT)?
            }
            _ => return Err(INVALID_CONTEXT),
        };
        let request = RecoveryActionRequest {
            capability: fields.code("capability")?,
            incident_id: fields.string("incident_id", |text| is_prefixed_hex(text, "inc-", 12))?,
            session_id: fields
                .string("session_id", |text| is_prefixed_hex(text, "session-", 24))?,
            command_id,
            component: fields.code("component")?,
            provider: fields.code("provider")?,
            recovery_generation,
            incident_phase: fields.code("incident_phase")?,
            process_identity: fields.string("process_identity", |text| {
                is_prefixed_hex(text, "continuity-", 32)
            })?,
            attempt: fields.integer("attempt", 1)?,
            idempotency_key: fields.string("idempotency_key", |text| {
                is_prefixed_hex(text, "recovery_", 24)
            })?,
            expected_postcondition: fields.code("expected_postcondition")?,
            incident_observed_at: fields.number("incident_observed_at")?,
            deadline: fields.number("deadline")?,
        };
        let validation = RecoveryActionValidation {
            validation_token: fields.code("validation_token")?,
            exact_target_owned: fields.boolean("exact_target_owned")?,
            liveness: fields.code("liveness")?,
            incident_active: fields.boolean("incident_active")?,
            generation_matches: fields.boolean("generation_matches")?,
            command_phase: fields.code("command_phase")?,
            command_phase_matches: fields.boolean("command_phase_matches")?,
            idempotency_state: fields.code("idempotency_state")?,
            compensation_available: fields.boolean("compensation_available")?,
            cooldown_remaining: fields.number("cooldown_remaining")?,
            expected_postcondition: request.expected_postcondition.clone(),
        };
        validation.check()?;

        let identity = [
            request.incident_id.as_str(),
            &request.recovery_generation,
            &request.capability,
            &request.component,
            &request.session_id,
            request.command_id.as_deref().unwrap_or("none"),
        ]
        .join("|");
        let expected_key = format!("recovery_{}", &hex_digest(identity.as_bytes())[..24]);
        if request.idempotency_key != expected_key {
            return Err(INVALID_CONTEXT);
        }
        let allowed = capability_policy(&request.capability).is_some_and(|policy| {
            policy.components.contains(&request.component.as_str())
                && policy.phases.contains(&request.incident_phase.as_str())
                && request.expected_postcondition == policy.postcondition
        });
        if !allowed || !["none", "codex", "claude"].contains(&request.provider.as_str()) {
            return Err(INVALID_CONTEXT);
        }
        Ok(Self {
            request,
            validation,
        })
    }
}

impl RecoveryActionValidation {
    /// `RecoveryActionValidation.__post_init__`.
    fn check(&self) -> Result<(), &'static str> {
        if !is_code(&self.validation_token) {
            return Err("component validation requires an opaque token");
        }
        if !LIVENESS.contains(&self.liveness.as_str()) {
            return Err("component validation returned invalid liveness");
        }
        let phase = self.command_phase.as_str();
        if !SAFE_COMMAND_PHASES.contains(&phase) && phase != "completed" && phase != "ambiguous" {
            return Err("component validation returned invalid command phase");
        }
        if !IDEMPOTENCY_STATES.contains(&self.idempotency_state.as_str()) {
            return Err("component validation returned invalid idempotency state");
        }
        if !self.cooldown_remaining.is_finite() || self.cooldown_remaining < 0.0 {
            return Err("component validation returned invalid cooldown");
        }
        if !is_code(&self.expected_postcondition) {
            return Err("component validation returned invalid postcondition");
        }
        Ok(())
    }
}

/// `PLEASE_REPEAT_TEXT`.
pub const PLEASE_REPEAT_TEXT: &str = "Relay Runner is listening again, but your last speech was not captured. \
     Please repeat your request.";
/// `RECOVERY_ACTION_REQUIRED_TEXT`.
pub const RECOVERY_ACTION_REQUIRED_TEXT: &str = "Relay Runner could not safely restore processing. \
     Start a new session, then repeat or review the command.";

/// `_PRECOMMAND_SPEECH_LOSS`: the capability each speech-loss incident must
/// report, by (component, phase).
const PRECOMMAND_SPEECH_LOSS: [((&str, &str), &str); 2] = [
    (
        ("speech_capture", "capture"),
        "Relay Runner cannot capture speech for the active voice session.",
    ),
    (
        ("transcription", "transcription"),
        "Relay Runner cannot turn captured speech into a command.",
    ),
];

/// `ContinuityResumeDecision`.
#[derive(Clone, Debug, PartialEq)]
pub struct ContinuityResumeDecision {
    pub phase: &'static str,
    pub action: &'static str,
    pub reason: &'static str,
    pub intent_id: Option<String>,
}

impl ContinuityResumeDecision {
    fn new(phase: &'static str, action: &'static str, reason: &'static str) -> Self {
        Self {
            phase,
            action,
            reason,
            intent_id: None,
        }
    }

    fn with_intent(mut self, intent_id: Option<String>) -> Self {
        self.intent_id = intent_id;
        self
    }

    /// `ContinuityResumeDecision.as_dict()`.
    pub fn as_dict(&self) -> Dict {
        let mut dict = Dict::new();
        dict.insert("phase", self.phase);
        dict.insert("action", self.action);
        dict.insert("reason", self.reason);
        dict.insert("intent_id", self.intent_id.clone());
        dict
    }
}

/// `int(item.get(key) or default)` for an inbox row's integer column.
fn row_integer(record: &Dict, key: &str, default: i64) -> i64 {
    record
        .truthy(key)
        .and_then(Value::py_int)
        .unwrap_or(default)
}

/// `_matching_record`: of the inbox rows for the opaque command, the first
/// live one in turn order, else the last.
fn matching_record<'a>(opaque_command_id: &str, records: &'a [Dict]) -> Option<&'a Dict> {
    let mut matches: Vec<&Dict> = records
        .iter()
        .filter(|record| {
            let native = record.text("command_id");
            !native.is_empty()
                && opaque_identifier("command", &native).is_ok_and(|id| id == opaque_command_id)
        })
        .collect();
    matches.sort_by_key(|item| {
        (
            row_integer(item, "command_seq", 0),
            row_integer(item, "within_turn_order", 1),
            row_integer(item, "ordinal", 0),
        )
    });
    matches
        .iter()
        .find(|item| !matches!(item.string("state").as_str(), "cancelled" | "completed"))
        .or(matches.last())
        .copied()
}

/// `plan_continuity_resume(incident, records, final_result=...,
/// provider_turn_state=...)`: a fail-closed foreground action chosen without
/// reading command content.
pub fn plan_continuity_resume(
    incident: &Dict,
    records: &[Dict],
    final_result: &str,
    provider_turn_state: Option<&str>,
) -> Result<ContinuityResumeDecision, &'static str> {
    normalize_recovery_generation(incident.get("recovery_generation"))?;
    let decision = ContinuityResumeDecision::new;
    if final_result != "restored" {
        return Ok(decision(
            "recovery_incomplete",
            "foreground_review",
            "stable_health_not_proven",
        ));
    }

    let Some(command_id) = incident.truthy("command_id") else {
        let incident_phase = (incident.string("component"), incident.string("phase"));
        let speech_loss = PRECOMMAND_SPEECH_LOSS
            .iter()
            .find(|((component, phase), _)| {
                (*component, *phase) == (incident_phase.0.as_str(), incident_phase.1.as_str())
            })
            .map(|(_, capability)| *capability);
        return Ok(match speech_loss {
            Some(capability)
                if !incident
                    .get("unavailable_capability")
                    .is_some_and(|reported| reported.is_str(capability)) =>
            {
                decision(
                    "speech_not_captured",
                    "foreground_review",
                    "speech_loss_capability_mismatch",
                )
            }
            Some(_) => decision("speech_not_captured", "ask_repeat", "no_durable_command"),
            None => decision("commandless_liveness", "noop", "no_command_resume_required"),
        });
    };

    let Some(record) = matching_record(&command_id.py_str(), records) else {
        return Ok(decision(
            "command_state_unknown",
            "foreground_review",
            "durable_command_not_found",
        ));
    };
    let intent_id = Some(record.string("intent_id")).filter(|id| !id.is_empty());
    let chosen = match record.string("state").as_str() {
        "pending" => decision(
            "transcript_captured",
            "resume_exact",
            "captured_not_delivered",
        ),
        "delivered" | "recovery_pending" => decision(
            "delivered_unclaimed",
            "resume_exact",
            "delivery_provably_unclaimed",
        ),
        "claimed" | "review_required" => decision(
            "claimed_ambiguous",
            "foreground_review",
            "claim_may_have_started_effect",
        ),
        "acked"
            if matches!(
                provider_turn_state,
                Some("active" | "completed_final" | "terminated")
            ) =>
        {
            decision(
                "in_flight_or_completed",
                "reattach",
                "authoritative_provider_state",
            )
        }
        "acked" => decision(
            "in_flight_or_completed",
            "foreground_review",
            "provider_state_ambiguous",
        ),
        "cancelled" | "completed" => decision("completed_or_revoked", "noop", "terminal_command"),
        _ => decision(
            "command_state_unknown",
            "foreground_review",
            "unsupported_command_state",
        ),
    };
    Ok(chosen.with_intent(intent_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    fn dict(text: &str) -> Dict {
        parse(text).unwrap().as_dict().unwrap().clone()
    }

    #[test]
    fn opaque_identifiers_match_python() {
        // `opaque_identifier(...)` from services/continuity_incidents.py.
        assert_eq!(
            opaque_identifier("session", "project:0123456789abcdef").unwrap(),
            "session-d0fcc8c99692fbfd1664bdae"
        );
        assert_eq!(
            opaque_identifier("command", "native-command").unwrap(),
            "command-7f11510ec225388764a192e6"
        );
        assert!(opaque_identifier("intent", "x").is_err());
        assert!(opaque_identifier("command", "").is_err());
    }

    #[test]
    fn recovery_generations_are_lossless_wire_identities() {
        let normalize = |text: &str| normalize_recovery_generation(Some(&parse(text).unwrap()));
        assert_eq!(normalize("4").unwrap(), "4");
        assert_eq!(normalize("0").unwrap(), "0");
        assert_eq!(normalize("\"generation-7\"").unwrap(), "generation-7");
        assert_eq!(normalize("\"a.b_c:d-e\"").unwrap(), "a.b_c:d-e");
        assert_eq!(
            normalize("123456789012345678901234567890").unwrap(),
            "123456789012345678901234567890"
        );
        let longest = format!("\"{}\"", "a".repeat(128));
        assert!(normalize(&longest).is_ok());
        for invalid in [
            "-1",
            "true",
            "false",
            "4.0",
            "null",
            "\"\"",
            "\"-lead\"",
            "\"has space\"",
            "\"tail\\n\"",
            "[1]",
            "\"é\"",
        ] {
            assert!(normalize(invalid).is_err(), "{invalid}");
        }
        assert!(normalize(&format!("\"{}\"", "a".repeat(129))).is_err());
        assert!(normalize_recovery_generation(None).is_err());
    }

    #[test]
    fn owners_follow_the_policy_or_the_component() {
        let cases = [
            ("reinitialize_speech_capture", "speech_capture", "app"),
            ("restart_bridge", "bridge", "app"),
            ("restart_messenger", "messenger", "bridge"),
            ("restart_daemon", "daemon", "app"),
            ("reconnect_ipc", "bridge", "app"),
            ("reconnect_ipc", "messenger", "bridge"),
            ("reconnect_ipc", "session", "bridge"),
            ("reconnect_ipc", "orchestrator", "daemon"),
            ("restore_session_registration", "session", "bridge"),
            ("release_dead_ownership", "foreground_provider", "app"),
            ("release_dead_ownership", "session", "bridge"),
            ("launch_foreground_provider", "foreground_provider", "app"),
            ("check_processing_health", "command", "daemon"),
            ("check_processing_health", "unknown", ""),
            ("format_disk", "bridge", ""),
        ];
        for (capability, component, owner) in cases {
            assert_eq!(
                recovery_owner_for(capability, component),
                owner,
                "{capability}"
            );
        }
        assert_eq!(CAPABILITY_POLICIES.len(), 10);
        for (_, policy) in &CAPABILITY_POLICIES {
            assert!(is_code(policy.owner) && is_code(policy.postcondition));
            assert!(policy.max_attempts >= 1 && policy.cooldown_seconds >= 0.0);
        }
        let daemon = capability_policy("restart_daemon").unwrap();
        assert_eq!((daemon.max_attempts, daemon.cooldown_seconds), (1, 15.0));
        assert_eq!(daemon.required_liveness, ["confirmed_dead"]);
        let health = capability_policy("check_processing_health").unwrap();
        assert_eq!(health.required_liveness.len(), 6);
        assert_eq!(health.components.len(), 9);
    }

    /// A payload as `RecoveryExecutionContext(request, validation).as_dict()`
    /// writes it, from tests/test_continuity_integration.py's
    /// `_recovery_request`.
    fn payload(capability: &str, component: &str, postcondition: &str, phase: &str) -> Dict {
        let session = opaque_identifier("session", "project:0123456789abcdef").unwrap();
        let command = opaque_identifier("command", "native-command").unwrap();
        let identity = format!("inc-123456789abc|4|{capability}|{component}|{session}|{command}");
        let key = format!("recovery_{}", &hex_digest(identity.as_bytes())[..24]);
        dict(&format!(
            r#"{{"capability": "{capability}", "incident_id": "inc-123456789abc",
            "session_id": "{session}", "command_id": "{command}", "component": "{component}",
            "provider": "none", "recovery_generation": "4", "incident_phase": "{phase}",
            "process_identity": "continuity-1234567890abcdef1234567890abcdef", "attempt": 1,
            "idempotency_key": "{key}", "expected_postcondition": "{postcondition}",
            "incident_observed_at": 1700000000.5, "deadline": 1234.25,
            "validation_token": "live_continuity_watch", "exact_target_owned": true,
            "liveness": "unhealthy", "incident_active": true, "generation_matches": true,
            "command_phase": "none", "command_phase_matches": true, "idempotency_state": "new",
            "compensation_available": false, "cooldown_remaining": 0}}"#
        ))
    }

    fn messenger_payload() -> Dict {
        payload(
            "restart_messenger",
            "messenger",
            "messenger_process_alive",
            "component_liveness",
        )
    }

    #[test]
    fn a_daemon_payload_parses_into_its_typed_context() {
        // The key matches what Python computes for the same identity.
        assert_eq!(
            messenger_payload().string("idempotency_key"),
            "recovery_0f74ad5c9398223f693132df"
        );
        let context = RecoveryExecutionContext::from_mapping(&messenger_payload()).unwrap();
        let request = &context.request;
        assert_eq!(request.capability, "restart_messenger");
        assert_eq!(
            request.command_id.as_deref(),
            Some("command-7f11510ec225388764a192e6")
        );
        assert_eq!(request.recovery_generation, "4");
        assert_eq!((request.attempt, request.deadline), (1, 1234.25));
        assert_eq!(request.incident_observed_at, 1_700_000_000.5);
        let validation = &context.validation;
        assert_eq!(validation.validation_token, "live_continuity_watch");
        assert!(validation.exact_target_owned && !validation.compensation_available);
        assert_eq!(validation.cooldown_remaining, 0.0);
        assert_eq!(validation.expected_postcondition, "messenger_process_alive");

        for (capability, component, postcondition, phase) in [
            (
                "reconnect_ipc",
                "messenger",
                "ipc_connection_restored",
                "component_liveness",
            ),
            (
                "reconnect_ipc",
                "session",
                "ipc_connection_restored",
                "session_liveness",
            ),
            (
                "restore_session_registration",
                "orchestrator",
                "session_heartbeat_fresh",
                "component_liveness",
            ),
            (
                "release_dead_ownership",
                "session",
                "dead_ownership_released",
                "session_liveness",
            ),
        ] {
            let parsed = RecoveryExecutionContext::from_mapping(&payload(
                capability,
                component,
                postcondition,
                phase,
            ));
            assert!(parsed.is_ok(), "{capability} {component}");
        }
    }

    #[test]
    fn a_command_free_payload_uses_none_in_its_identity() {
        let mut free = messenger_payload();
        free.insert("command_id", Value::Null);
        assert!(RecoveryExecutionContext::from_mapping(&free).is_err());
        let session = free.string("session_id");
        let identity = format!("inc-123456789abc|4|restart_messenger|messenger|{session}|none");
        free.insert(
            "idempotency_key",
            format!("recovery_{}", &hex_digest(identity.as_bytes())[..24]),
        );
        let context = RecoveryExecutionContext::from_mapping(&free).unwrap();
        assert_eq!(context.request.command_id, None);
        free.remove("command_id");
        assert!(RecoveryExecutionContext::from_mapping(&free).is_ok());
    }

    #[test]
    fn coerced_or_unauthorized_payloads_are_refused() {
        let changes: [(&str, &str); 24] = [
            ("attempt", "\"1\""),
            ("attempt", "true"),
            ("attempt", "0"),
            ("attempt", "1.0"),
            ("deadline", "\"1\""),
            ("deadline", "true"),
            ("deadline", "1e999"),
            ("exact_target_owned", "1"),
            ("recovery_generation", "4"),
            ("recovery_generation", "\"-4\""),
            ("capability", "\"Restart\""),
            ("capability", "\"restart_bridge\""),
            ("component", "\"session\""),
            ("incident_phase", "\"delivery\""),
            ("expected_postcondition", "\"bridge_process_alive\""),
            ("provider", "\"gemini\""),
            ("session_id", "\"session-1\""),
            ("command_id", "\"native-command\""),
            ("incident_id", "\"inc-123456789ABC\""),
            ("process_identity", "\"continuity-1\""),
            ("liveness", "\"zombie\""),
            ("command_phase", "\"delivered\""),
            ("idempotency_state", "\"maybe\""),
            ("cooldown_remaining", "-1"),
        ];
        for (field, value) in changes {
            let mut changed = messenger_payload();
            changed.insert(field, parse(value).unwrap());
            assert!(
                RecoveryExecutionContext::from_mapping(&changed).is_err(),
                "{field} = {value}"
            );
        }
        let mut missing = messenger_payload();
        missing.remove("validation_token");
        assert!(RecoveryExecutionContext::from_mapping(&missing).is_err());
        // Completed and ambiguous command phases are valid evidence.
        let mut completed = messenger_payload();
        completed.insert("command_phase", "completed");
        assert!(RecoveryExecutionContext::from_mapping(&completed).is_ok());
    }

    fn incident(command_id: Option<&str>) -> Dict {
        let mut incident = Dict::new();
        incident.insert(
            "command_id",
            command_id.map(|id| opaque_identifier("command", id).unwrap()),
        );
        incident.insert(
            "component",
            if command_id.is_some() {
                "command"
            } else {
                "speech_capture"
            },
        );
        incident.insert(
            "phase",
            if command_id.is_some() {
                "command_processing"
            } else {
                "capture"
            },
        );
        incident.insert("recovery_generation", "generation-7");
        incident.insert(
            "unavailable_capability",
            if command_id.is_some() {
                None
            } else {
                Some("Relay Runner cannot capture speech for the active voice session.")
            },
        );
        incident
    }

    fn record(state: &str, order: i64) -> Dict {
        dict(&format!(
            r#"{{"ordinal": {order}, "intent_id": "intent-{order}", "command_seq": 1,
            "command_id": "command-one", "within_turn_order": {order}, "state": "{state}",
            "recovery_generation": "generation-7"}}"#
        ))
    }

    fn plan(incident: &Dict, records: &[Dict], final_result: &str) -> ContinuityResumeDecision {
        plan_continuity_resume(incident, records, final_result, None).unwrap()
    }

    fn triple(decision: &ContinuityResumeDecision) -> (&str, &str, &str) {
        (decision.phase, decision.action, decision.reason)
    }

    #[test]
    fn pretranscript_loss_has_one_deterministic_repeat_outcome() {
        let decision = plan(&incident(None), &[], "restored");
        assert_eq!(
            triple(&decision),
            ("speech_not_captured", "ask_repeat", "no_durable_command")
        );
        assert!(PLEASE_REPEAT_TEXT.contains("Please repeat your request"));

        let mut mismatched = incident(None);
        mismatched.insert(
            "unavailable_capability",
            "Relay Runner cannot turn captured speech into a command.",
        );
        assert_eq!(
            triple(&plan(&mismatched, &[], "restored")),
            (
                "speech_not_captured",
                "foreground_review",
                "speech_loss_capability_mismatch"
            )
        );
    }

    #[test]
    fn commandless_liveness_recovery_has_no_speech_outcome() {
        for (component, phase) in [
            ("bridge", "delivery"),
            ("messenger", "component_liveness"),
            ("daemon", "component_liveness"),
            ("session", "session_liveness"),
        ] {
            let mut handoff = incident(None);
            handoff.insert("component", component);
            handoff.insert("phase", phase);
            assert_eq!(
                triple(&plan(&handoff, &[], "restored")),
                ("commandless_liveness", "noop", "no_command_resume_required")
            );
        }
    }

    #[test]
    fn handoff_waits_for_stable_health_and_a_valid_generation() {
        let decision = plan(
            &incident(Some("command-one")),
            &[record("pending", 1)],
            "circuit_open",
        );
        assert_eq!(
            (decision.action, decision.reason),
            ("foreground_review", "stable_health_not_proven")
        );
        let mut invalid = incident(Some("command-one"));
        invalid.insert("recovery_generation", "");
        assert!(plan_continuity_resume(&invalid, &[], "restored", None).is_err());
    }

    #[test]
    fn captured_and_delivered_unclaimed_commands_resume_original_intent() {
        for (state, phase, reason) in [
            ("pending", "transcript_captured", "captured_not_delivered"),
            (
                "delivered",
                "delivered_unclaimed",
                "delivery_provably_unclaimed",
            ),
            (
                "recovery_pending",
                "delivered_unclaimed",
                "delivery_provably_unclaimed",
            ),
        ] {
            let decision = plan(
                &incident(Some("command-one")),
                &[record(state, 1)],
                "restored",
            );
            assert_eq!(triple(&decision), (phase, "resume_exact", reason));
            assert_eq!(decision.intent_id.as_deref(), Some("intent-1"));
        }
    }

    #[test]
    fn claimed_acknowledged_and_terminal_commands_never_replay() {
        let command = incident(Some("command-one"));
        for state in ["claimed", "review_required"] {
            let decision = plan(&command, &[record(state, 1)], "restored");
            assert_eq!(
                (decision.action, decision.reason),
                ("foreground_review", "claim_may_have_started_effect")
            );
        }
        for provider_state in ["active", "completed_final", "terminated"] {
            let decision = plan_continuity_resume(
                &command,
                &[record("acked", 1)],
                "restored",
                Some(provider_state),
            )
            .unwrap();
            assert_eq!(decision.action, "reattach");
        }
        assert_eq!(
            plan(&command, &[record("acked", 1)], "restored").action,
            "foreground_review"
        );
        for state in ["cancelled", "completed"] {
            assert_eq!(
                plan(&command, &[record(state, 1)], "restored").action,
                "noop"
            );
        }
        assert_eq!(
            triple(&plan(&command, &[record("mystery", 1)], "restored")),
            (
                "command_state_unknown",
                "foreground_review",
                "unsupported_command_state"
            )
        );
        let missing = plan(
            &incident(Some("stale-command")),
            &[record("pending", 1)],
            "restored",
        );
        assert_eq!(
            (missing.action, missing.reason, missing.intent_id),
            ("foreground_review", "durable_command_not_found", None)
        );
    }

    #[test]
    fn ordered_siblings_skip_revoked_item_and_resume_next_exact_intent() {
        let decision = plan(
            &incident(Some("command-one")),
            &[record("pending", 2), record("cancelled", 1)],
            "restored",
        );
        assert_eq!(decision.action, "resume_exact");
        assert_eq!(decision.intent_id.as_deref(), Some("intent-2"));
        // With every sibling terminal, the last one in order decides.
        let decision = plan(
            &incident(Some("command-one")),
            &[record("completed", 2), record("cancelled", 1)],
            "restored",
        );
        assert_eq!(decision.intent_id.as_deref(), Some("intent-2"));
    }

    #[test]
    fn the_decision_serializes_as_python_as_dict() {
        let decision = plan(&incident(None), &[], "restored");
        assert_eq!(
            crate::json::dumps(&Value::Dict(decision.as_dict())),
            r#"{"phase": "speech_not_captured", "action": "ask_repeat", "reason": "no_durable_command", "intent_id": null}"#
        );
    }
}
