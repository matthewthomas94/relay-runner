//! `services/continuity_recovery.py`: validated, component-owned runtime
//! recovery for Relay voice processing.
//!
//! The continuity provider can select a capability, but it cannot execute
//! one. The broker checks the fixed incident identity and a fresh
//! component-owner inspection before asking that owner to make a bounded
//! Relay-runtime change. There is deliberately no generic command, path, URL
//! or payload capability.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex};

use relay_intents::sha256::hex_digest;

use super::agent::{BrokerCall, RecoveryBroker, RecoveryBrokerOutcome, RecoveryHealthEvidence};
use super::{
    Clock, Event, generation, is_code, is_prefixed_hex, monotonic_clock,
    normalize_recovery_generation,
};
use crate::{Dict, Error, Result, Value};

pub const RESTORE_PROCESSING_OBJECTIVE: &str = "restore_processing";
pub const HEALTH_CHECK: &str = "check_processing_health";

pub const LIVENESS: [&str; 6] = [
    "healthy",
    "slow",
    "unhealthy",
    "stalled",
    "confirmed_dead",
    "unknown",
];
pub const IDEMPOTENCY_STATES: [&str; 4] = ["new", "applied", "compensated", "conflict"];
pub const SAFE_COMMAND_PHASES: [&str; 7] = [
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
const DEAD_OR_UNHEALTHY: [&str; 2] = ["confirmed_dead", "unhealthy"];
const ALL_PHASES: [&str; 7] = [
    "capture",
    "transcription",
    "delivery",
    "component_liveness",
    "provider_turn",
    "command_processing",
    "session_liveness",
];

/// `_COMPONENT_OWNERS`: which component owner recovers each component.
pub const COMPONENT_OWNERS: [(&str, &str); 9] = [
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

/// The owner of `component`, or `""`.
pub fn component_owner(component: &str) -> &'static str {
    COMPONENT_OWNERS
        .iter()
        .find(|(name, _)| *name == component)
        .map_or("", |(_, owner)| owner)
}

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

/// `CAPABILITY_POLICIES`, in the Python dict's order.
pub static CAPABILITY_POLICIES: [(&str, RecoveryCapabilityPolicy); 10] = [
    (
        HEALTH_CHECK,
        RecoveryCapabilityPolicy {
            max_attempts: 4,
            cooldown_seconds: 0.0,
            required_liveness: &LIVENESS,
            ..policy(
                "dynamic",
                &ALL_COMPONENTS,
                &ALL_PHASES,
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
        RecoveryCapabilityPolicy {
            required_liveness: &DEAD_OR_UNHEALTHY,
            ..policy(
                "app",
                &["bridge"],
                &["delivery", "component_liveness"],
                "bridge_process_alive",
            )
        },
    ),
    (
        "restart_messenger",
        RecoveryCapabilityPolicy {
            required_liveness: &DEAD_OR_UNHEALTHY,
            ..policy(
                "bridge",
                &["messenger"],
                &["component_liveness"],
                "messenger_process_alive",
            )
        },
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

/// Operations no recovery capability may perform.
pub const DISALLOWED_RECOVERY_OPERATIONS: [&str; 22] = [
    "edit_source",
    "edit_ticket",
    "change_git_state",
    "change_configuration",
    "change_authentication",
    "access_keychain",
    "change_permissions",
    "install_update",
    "install_software",
    "create_release",
    "deploy",
    "mutate_database",
    "mutate_durable_user_data",
    "send_message",
    "external_action",
    "cancel_live_work",
    "kill_live_provider",
    "switch_provider",
    "switch_model",
    "replay_ambiguous_command",
    "destructive_reset",
    "reinstall",
];

/// `CAPABILITY_POLICIES.get(capability)`.
pub fn capability_policy(capability: &str) -> Option<&'static RecoveryCapabilityPolicy> {
    CAPABILITY_POLICIES
        .iter()
        .find(|(name, _)| *name == capability)
        .map(|(_, policy)| policy)
}

fn owner_name(policy: &RecoveryCapabilityPolicy, component: &str) -> &'static str {
    if policy.owner == "dynamic" {
        component_owner(component)
    } else {
        policy.owner
    }
}

/// `recovery_owner_for(capability, component)`: who executes the capability
/// for that component, or `""` for none.
pub fn recovery_owner_for(capability: &str, component: &str) -> &'static str {
    capability_policy(capability).map_or("", |policy| owner_name(policy, component))
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

/// `RecoveryActionValidation`: a component owner's fresh inspection.
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
    pub health: RecoveryHealthEvidence,
}

impl RecoveryActionValidation {
    /// `RecoveryActionValidation.__post_init__`.
    pub fn validated(self) -> Result<Self> {
        if !is_code(&self.validation_token) {
            return Err(Error::value(
                "component validation requires an opaque token",
            ));
        }
        if !LIVENESS.contains(&self.liveness.as_str()) {
            return Err(Error::value(
                "component validation returned invalid liveness",
            ));
        }
        let phase = self.command_phase.as_str();
        if !SAFE_COMMAND_PHASES.contains(&phase) && phase != "completed" && phase != "ambiguous" {
            return Err(Error::value(
                "component validation returned invalid command phase",
            ));
        }
        if !IDEMPOTENCY_STATES.contains(&self.idempotency_state.as_str()) {
            return Err(Error::value(
                "component validation returned invalid idempotency state",
            ));
        }
        if !self.cooldown_remaining.is_finite() || self.cooldown_remaining < 0.0 {
            return Err(Error::value(
                "component validation returned invalid cooldown",
            ));
        }
        if !is_code(&self.expected_postcondition) {
            return Err(Error::value(
                "component validation returned invalid postcondition",
            ));
        }
        Ok(self)
    }
}

/// The idempotency key of one capability on one incident.
pub fn idempotency_key(
    incident_id: &str,
    recovery_generation: &str,
    capability: &str,
    component: &str,
    session_id: &str,
    command_id: Option<&str>,
) -> String {
    let command = command_id.filter(|id| !id.is_empty()).unwrap_or("none");
    let identity = [
        incident_id,
        recovery_generation,
        capability,
        component,
        session_id,
        command,
    ]
    .join("|");
    format!("recovery_{}", &hex_digest(identity.as_bytes())[..24])
}

/// `RecoveryExecutionContext`: the typed request plus validation carried to
/// the executing component.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryExecutionContext {
    pub request: RecoveryActionRequest,
    pub validation: RecoveryActionValidation,
}

const INVALID_CONTEXT: &str = "invalid_recovery_context";

fn invalid_context() -> Error {
    Error::value(INVALID_CONTEXT)
}

/// The typed readers of `from_mapping`: no coercion is accepted.
struct Fields<'a>(&'a Dict);

impl Fields<'_> {
    fn string(&self, name: &str, valid: impl Fn(&str) -> bool) -> Result<String> {
        match self.0.get(name) {
            Some(Value::Str(text)) if valid(text) => Ok(text.clone()),
            _ => Err(invalid_context()),
        }
    }

    fn code(&self, name: &str) -> Result<String> {
        self.string(name, is_code)
    }

    fn integer(&self, name: &str, minimum: i64) -> Result<i64> {
        match self.0.get(name) {
            Some(Value::Int(number)) if *number >= minimum => Ok(*number),
            // A Python int beyond i64 can only exceed every attempt limit.
            Some(Value::BigInt(digits)) if !digits.starts_with('-') => Ok(i64::MAX),
            _ => Err(invalid_context()),
        }
    }

    fn number(&self, name: &str) -> Result<f64> {
        let number = match self.0.get(name) {
            Some(Value::Int(number)) => *number as f64,
            Some(Value::BigInt(digits)) => digits.parse().map_err(|_| invalid_context())?,
            Some(Value::Float(number)) => *number,
            _ => return Err(invalid_context()),
        };
        if number.is_finite() {
            Ok(number)
        } else {
            Err(invalid_context())
        }
    }

    fn boolean(&self, name: &str) -> Result<bool> {
        match self.0.get(name) {
            Some(Value::Bool(flag)) => Ok(*flag),
            _ => Err(invalid_context()),
        }
    }
}

impl RecoveryExecutionContext {
    pub fn as_dict(&self) -> Dict {
        let request = &self.request;
        let validation = &self.validation;
        let mut value = Dict::new();
        value.insert("capability", request.capability.as_str());
        value.insert("incident_id", request.incident_id.as_str());
        value.insert("session_id", request.session_id.as_str());
        value.insert("command_id", request.command_id.as_deref());
        value.insert("component", request.component.as_str());
        value.insert("provider", request.provider.as_str());
        value.insert("recovery_generation", request.recovery_generation.as_str());
        value.insert("incident_phase", request.incident_phase.as_str());
        value.insert("process_identity", request.process_identity.as_str());
        value.insert("attempt", request.attempt);
        value.insert("idempotency_key", request.idempotency_key.as_str());
        value.insert(
            "expected_postcondition",
            request.expected_postcondition.as_str(),
        );
        value.insert("incident_observed_at", request.incident_observed_at);
        value.insert("deadline", request.deadline);
        value.insert("validation_token", validation.validation_token.as_str());
        value.insert("exact_target_owned", validation.exact_target_owned);
        value.insert("liveness", validation.liveness.as_str());
        value.insert("incident_active", validation.incident_active);
        value.insert("generation_matches", validation.generation_matches);
        value.insert("command_phase", validation.command_phase.as_str());
        value.insert("command_phase_matches", validation.command_phase_matches);
        value.insert("idempotency_state", validation.idempotency_state.as_str());
        value.insert("compensation_available", validation.compensation_available);
        value.insert("cooldown_remaining", validation.cooldown_remaining);
        value
    }

    /// `RecoveryExecutionContext.from_mapping(payload)`: parses an IPC
    /// payload without accepting coercions or extra authority.
    pub fn from_mapping(payload: &Dict) -> Result<Self> {
        let fields = Fields(payload);
        let capability = fields.code("capability")?;
        let incident_id = fields.string("incident_id", |text| is_prefixed_hex(text, "inc-", 12))?;
        let session_id =
            fields.string("session_id", |text| is_prefixed_hex(text, "session-", 24))?;
        let command_id = match payload.get("command_id") {
            None | Some(Value::Null) => None,
            Some(_) => {
                Some(fields.string("command_id", |text| is_prefixed_hex(text, "command-", 24))?)
            }
        };
        let component = fields.code("component")?;
        let provider = fields.code("provider")?;
        let recovery_generation = match payload.get("recovery_generation") {
            Some(Value::Str(text)) => generation(text).map_err(|_| invalid_context())?,
            _ => return Err(invalid_context()),
        };
        let request = RecoveryActionRequest {
            capability,
            incident_id,
            session_id,
            command_id,
            component,
            provider,
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
            health: RecoveryHealthEvidence::default(),
        }
        .validated()?;
        let expected = idempotency_key(
            &request.incident_id,
            &request.recovery_generation,
            &request.capability,
            &request.component,
            &request.session_id,
            request.command_id.as_deref(),
        );
        if request.idempotency_key != expected {
            return Err(invalid_context());
        }
        let allowed = capability_policy(&request.capability).is_some_and(|policy| {
            policy.components.contains(&request.component.as_str())
                && policy.phases.contains(&request.incident_phase.as_str())
                && request.expected_postcondition == policy.postcondition
        });
        if !allowed || !["none", "codex", "claude"].contains(&request.provider.as_str()) {
            return Err(invalid_context());
        }
        Ok(Self {
            request,
            validation,
        })
    }
}

/// `RecoveryActionResult`: what a component owner did.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryActionResult {
    pub status: String,
    pub outcome_code: String,
    pub health: RecoveryHealthEvidence,
    pub ephemeral_state_created: bool,
    pub health_worsened: bool,
}

impl RecoveryActionResult {
    /// `RecoveryActionResult(status, outcome_code, health)`.
    pub fn new(status: &str, outcome_code: &str, health: RecoveryHealthEvidence) -> Result<Self> {
        Self {
            status: status.to_string(),
            outcome_code: outcome_code.to_string(),
            health,
            ephemeral_state_created: false,
            health_worsened: false,
        }
        .validated()
    }

    /// `RecoveryActionResult.__post_init__`.
    pub fn validated(self) -> Result<Self> {
        if !["applied", "noop", "failed"].contains(&self.status.as_str()) {
            return Err(Error::value(
                "component owner returned invalid recovery status",
            ));
        }
        if !is_code(&self.outcome_code) {
            return Err(Error::value("component owner returned unsanitized outcome"));
        }
        Ok(self)
    }
}

/// `ComponentRecoveryOwner`: one component owner's inspection and fixed
/// actions.
pub trait ComponentRecoveryOwner: Send + Sync {
    fn owner(&self) -> &str;
    /// Whether this owner offers `capability` (`supports`, when the Python
    /// owner defines it; every capability otherwise).
    fn supports(&self, _capability: &str) -> bool {
        true
    }
    fn inspect(&self, request: &RecoveryActionRequest) -> Result<RecoveryActionValidation>;
    fn execute(
        &self,
        request: &RecoveryActionRequest,
        validation: &RecoveryActionValidation,
        cancel: &Event,
    ) -> Result<RecoveryActionResult>;
    fn cleanup(
        &self,
        request: &RecoveryActionRequest,
        validation: &RecoveryActionValidation,
    ) -> Result<bool>;
}

/// A component's fresh objective health for a request.
pub type HealthProbe =
    Arc<dyn Fn(&RecoveryActionRequest) -> Result<RecoveryHealthEvidence> + Send + Sync>;
pub type InspectFn =
    Arc<dyn Fn(&RecoveryActionRequest) -> Result<RecoveryActionValidation> + Send + Sync>;
pub type ExecuteFn = Arc<
    dyn Fn(
            &RecoveryActionRequest,
            &RecoveryActionValidation,
            &Event,
        ) -> Result<RecoveryActionResult>
        + Send
        + Sync,
>;
pub type CleanupFn = Arc<dyn Fn(&RecoveryActionRequest) -> Result<bool> + Send + Sync>;

/// `ProductionRecoveryCapability`: the fixed component callbacks of one
/// production recovery capability.
#[derive(Clone)]
pub struct ProductionRecoveryCapability {
    pub inspect: InspectFn,
    pub execute: ExecuteFn,
    pub cleanup: Option<CleanupFn>,
}

/// `ObjectiveEvidenceRecoveryOwner` (and its `App`, `Bridge` and `Daemon`
/// forms): objective health owned by one Relay component, with mutation
/// capabilities fixed at construction.
pub struct ObjectiveEvidenceRecoveryOwner {
    owner: String,
    health_probe: HealthProbe,
    capabilities: BTreeMap<String, ProductionRecoveryCapability>,
}

impl ObjectiveEvidenceRecoveryOwner {
    pub fn new(
        owner: &str,
        health_probe: HealthProbe,
        capabilities: BTreeMap<String, ProductionRecoveryCapability>,
    ) -> Result<Self> {
        if !["app", "bridge", "daemon"].contains(&owner) {
            return Err(Error::value("invalid recovery owner adapter"));
        }
        for capability in capabilities.keys() {
            let mismatched = capability == HEALTH_CHECK
                || capability_policy(capability)
                    .is_none_or(|policy| policy.owner != owner && policy.owner != "dynamic");
            if mismatched {
                return Err(Error::value(
                    "production recovery capability owner mismatch",
                ));
            }
        }
        Ok(Self {
            owner: owner.to_string(),
            health_probe,
            capabilities,
        })
    }

    /// The fixed capabilities this owner executes besides the health check.
    pub fn fixed_capabilities(&self) -> Vec<String> {
        self.capabilities.keys().cloned().collect()
    }
}

impl ComponentRecoveryOwner for ObjectiveEvidenceRecoveryOwner {
    fn owner(&self) -> &str {
        &self.owner
    }

    fn supports(&self, capability: &str) -> bool {
        capability == HEALTH_CHECK || self.capabilities.contains_key(capability)
    }

    fn inspect(&self, request: &RecoveryActionRequest) -> Result<RecoveryActionValidation> {
        if let Some(capability) = self.capabilities.get(&request.capability) {
            return (capability.inspect)(request);
        }
        let exact_owner = component_owner(&request.component) == self.owner;
        let health = (self.health_probe)(request)?;
        RecoveryActionValidation {
            validation_token: "objective_health_probe".to_string(),
            exact_target_owned: exact_owner,
            liveness: "unhealthy".to_string(),
            incident_active: true,
            generation_matches: true,
            command_phase: "none".to_string(),
            command_phase_matches: true,
            idempotency_state: "new".to_string(),
            compensation_available: false,
            cooldown_remaining: 0.0,
            expected_postcondition: request.expected_postcondition.clone(),
            health,
        }
        .validated()
    }

    fn execute(
        &self,
        request: &RecoveryActionRequest,
        validation: &RecoveryActionValidation,
        cancel: &Event,
    ) -> Result<RecoveryActionResult> {
        if let Some(capability) = self.capabilities.get(&request.capability) {
            return (capability.execute)(request, validation, cancel);
        }
        if cancel.is_set() || request.capability != HEALTH_CHECK {
            return RecoveryActionResult::new(
                "failed",
                "owner_capability_unavailable",
                RecoveryHealthEvidence::default(),
            );
        }
        RecoveryActionResult::new(
            "noop",
            "processing_health_checked",
            (self.health_probe)(request)?,
        )
    }

    fn cleanup(
        &self,
        request: &RecoveryActionRequest,
        _validation: &RecoveryActionValidation,
    ) -> Result<bool> {
        match self
            .capabilities
            .get(&request.capability)
            .and_then(|capability| capability.cleanup.as_ref())
        {
            Some(cleanup) => cleanup(request),
            None => Ok(false),
        }
    }
}

/// The owner registry the broker consults, by owner name.
pub type RecoveryOwners = BTreeMap<String, Arc<dyn ComponentRecoveryOwner>>;

/// `production_recovery_owners(health_probe, capabilities=...)`: the fixed
/// production owner registry the daemon uses. Every capability but the health
/// check must be supplied.
pub fn production_recovery_owners(
    health_probe: HealthProbe,
    capabilities: &BTreeMap<String, ProductionRecoveryCapability>,
) -> Result<RecoveryOwners> {
    let required: BTreeSet<&str> = CAPABILITY_POLICIES
        .iter()
        .map(|(name, _)| *name)
        .filter(|name| *name != HEALTH_CHECK)
        .collect();
    let supplied: BTreeSet<&str> = capabilities.keys().map(String::as_str).collect();
    if supplied != required {
        return Err(Error::value(
            "production recovery registry requires every fixed capability",
        ));
    }
    let mut by_owner: BTreeMap<&str, BTreeMap<String, ProductionRecoveryCapability>> =
        ["app", "bridge", "daemon"]
            .into_iter()
            .map(|owner| (owner, BTreeMap::new()))
            .collect();
    for (capability, adapter) in capabilities {
        let Some(policy) = capability_policy(capability).filter(|_| capability != HEALTH_CHECK)
        else {
            return Err(Error::value("unsupported production recovery capability"));
        };
        if policy.owner == "dynamic" {
            for component in policy.components {
                if let Some(owned) = by_owner.get_mut(component_owner(component)) {
                    owned.insert(capability.clone(), adapter.clone());
                }
            }
        } else if let Some(owned) = by_owner.get_mut(policy.owner) {
            owned.insert(capability.clone(), adapter.clone());
        }
    }
    let mut owners = RecoveryOwners::new();
    for (name, owned) in by_owner {
        let owner = ObjectiveEvidenceRecoveryOwner::new(name, Arc::clone(&health_probe), owned)?;
        owners.insert(name.to_string(), Arc::new(owner));
    }
    Ok(owners)
}

/// The broker's typed request for `capability` on `incident` (`_request`),
/// or the code it rejects the call with.
pub fn recovery_request(
    capability: &str,
    incident: &Dict,
    process_identity: &str,
    recovery_generation: &str,
    attempt: i64,
    deadline: f64,
) -> std::result::Result<RecoveryActionRequest, &'static str> {
    let policy = capability_policy(capability).ok_or("capability_not_allowed")?;
    let call = BrokerCall {
        incident: incident.clone(),
        process_identity: process_identity.to_string(),
        recovery_generation: recovery_generation.to_string(),
        attempt,
        deadline,
        cancel: Event::new(),
    };
    ComponentOwnedRecoveryBroker::request(capability, policy, incident, &call)
}

#[derive(Default)]
struct BrokerState {
    attempts: HashMap<String, i64>,
    cooldowns: HashMap<String, f64>,
    applied: HashSet<String>,
}

/// `ComponentOwnedRecoveryBroker`: the fail-closed broker for the
/// restore-processing objective.
pub struct ComponentOwnedRecoveryBroker {
    owners: RecoveryOwners,
    monotonic: Clock,
    state: Mutex<BrokerState>,
}

fn outcome(
    capability: &str,
    status: &str,
    code: &str,
    health: Option<RecoveryHealthEvidence>,
) -> RecoveryBrokerOutcome {
    RecoveryBrokerOutcome::fixed_with(capability, status, code, health.unwrap_or_default())
}

impl ComponentOwnedRecoveryBroker {
    pub fn new(owners: RecoveryOwners, monotonic: Option<Clock>) -> Result<Self> {
        for (name, owner) in &owners {
            if !["app", "bridge", "daemon"].contains(&name.as_str()) || owner.owner() != name {
                return Err(Error::value("recovery owner registry identity mismatch"));
            }
        }
        Ok(Self {
            owners,
            monotonic: monotonic.unwrap_or_else(monotonic_clock),
            state: Mutex::new(BrokerState::default()),
        })
    }

    fn now(&self) -> f64 {
        (self.monotonic)()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BrokerState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// `_request(...)`: the typed request, or the rejection code.
    fn request(
        capability: &str,
        policy: &RecoveryCapabilityPolicy,
        incident: &Dict,
        call: &BrokerCall,
    ) -> std::result::Result<RecoveryActionRequest, &'static str> {
        let text = |key: &str| {
            incident
                .get(key)
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty())
        };
        if [
            "incident_id",
            "session_id",
            "component",
            "provider",
            "phase",
        ]
        .iter()
        .any(|key| text(key).is_none())
        {
            return Err("invalid_incident_identity");
        }
        let incident_generation =
            normalize_recovery_generation(incident.get("recovery_generation"))
                .map_err(|_| "invalid_recovery_generation")?;
        let recovery_generation =
            generation(&call.recovery_generation).map_err(|_| "invalid_recovery_generation")?;
        let component = text("component").unwrap_or_default();
        let phase = text("phase").unwrap_or_default();
        if recovery_generation != incident_generation {
            return Err("recovery_generation_mismatch");
        }
        if !policy.components.contains(&component) || !policy.phases.contains(&phase) {
            return Err("capability_outside_incident_scope");
        }
        if !is_prefixed_hex(&call.process_identity, "continuity-", 32) {
            return Err("invalid_continuity_process");
        }
        if call.attempt < 1 {
            return Err("invalid_recovery_attempt");
        }
        if !call.deadline.is_finite() {
            return Err("invalid_recovery_deadline");
        }
        let observed = incident
            .get("timing")
            .and_then(Value::as_dict)
            .and_then(|timing| timing.get("last_observed_at"));
        let incident_observed_at = match observed {
            Some(Value::Bool(flag)) => f64::from(u8::from(*flag)),
            Some(Value::Int(number)) => *number as f64,
            Some(Value::BigInt(digits)) => digits.parse().unwrap_or(f64::INFINITY),
            Some(Value::Float(number)) => *number,
            _ => return Err("invalid_incident_timing"),
        };
        if !incident_observed_at.is_finite() {
            return Err("invalid_incident_timing");
        }
        let command_id = match incident.get("command_id") {
            None | Some(Value::Null) => None,
            Some(Value::Str(text)) => Some(text.clone()),
            Some(_) => return Err("invalid_incident_identity"),
        };
        let incident_id = text("incident_id").unwrap_or_default();
        let session_id = text("session_id").unwrap_or_default();
        Ok(RecoveryActionRequest {
            capability: capability.to_string(),
            incident_id: incident_id.to_string(),
            session_id: session_id.to_string(),
            idempotency_key: idempotency_key(
                incident_id,
                &recovery_generation,
                capability,
                component,
                session_id,
                command_id.as_deref(),
            ),
            command_id,
            component: component.to_string(),
            provider: text("provider").unwrap_or_default().to_string(),
            recovery_generation,
            incident_phase: phase.to_string(),
            process_identity: call.process_identity.clone(),
            attempt: call.attempt,
            expected_postcondition: policy.postcondition.to_string(),
            incident_observed_at,
            deadline: call.deadline,
        })
    }

    /// `_validation_rejection(...)`: the status and code that refuse an
    /// inspected action, or `None`.
    fn validation_rejection(
        policy: &RecoveryCapabilityPolicy,
        request: &RecoveryActionRequest,
        validation: &RecoveryActionValidation,
    ) -> Option<(&'static str, &'static str)> {
        if !validation.exact_target_owned {
            return Some(("authorization_required", "target_ownership_not_proven"));
        }
        if !validation.incident_active || !validation.generation_matches {
            return Some(("rejected", "stale_recovery_generation"));
        }
        if !validation.command_phase_matches {
            return Some(("authorization_required", "command_phase_ambiguous"));
        }
        if !policy
            .command_phases
            .contains(&validation.command_phase.as_str())
        {
            return Some(("authorization_required", "command_replay_not_recoverable"));
        }
        let provider_action = ["release_dead_ownership", "launch_foreground_provider"]
            .contains(&request.capability.as_str());
        let stalled_provider_authority = request.component == "foreground_provider"
            && provider_action
            && validation.liveness == "stalled";
        if !policy
            .required_liveness
            .contains(&validation.liveness.as_str())
            && !stalled_provider_authority
        {
            let code =
                if provider_action && ["healthy", "slow"].contains(&validation.liveness.as_str()) {
                    "live_provider_must_not_be_killed"
                } else {
                    "target_health_not_proven"
                };
            return Some(("rejected", code));
        }
        if validation.idempotency_state == "conflict" {
            return Some(("authorization_required", "idempotency_conflict"));
        }
        if validation.cooldown_remaining > 0.0 {
            return Some(("circuit_open", "component_cooldown_active"));
        }
        if validation.expected_postcondition != policy.postcondition {
            return Some(("rejected", "postcondition_mismatch"));
        }
        None
    }

    /// `_validated_health(incident, health)`: restoration counts only with
    /// every code the incident's objective requires.
    pub fn validated_health(
        incident: &Dict,
        health: &RecoveryHealthEvidence,
    ) -> RecoveryHealthEvidence {
        let required: BTreeSet<&str> = incident
            .get("recovery_objective")
            .and_then(Value::as_dict)
            .and_then(|objective| objective.get("restored_when"))
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_str)
            .filter(|code| is_code(code))
            .collect();
        let proven = health.objective_restored
            && !required.is_empty()
            && required
                .iter()
                .all(|code| health.evidence_codes.iter().any(|have| have == code));
        RecoveryHealthEvidence {
            objective_restored: proven,
            stable_for_seconds: health.stable_for_seconds,
            evidence_codes: health.evidence_codes.clone(),
        }
    }
}

impl RecoveryBroker for ComponentOwnedRecoveryBroker {
    fn capabilities(&self, incident: &Dict) -> Result<Vec<String>> {
        let component = incident.string("component");
        let phase = incident.string("phase");
        let available: Vec<String> = CAPABILITY_POLICIES
            .iter()
            .filter(|(capability, policy)| {
                policy.components.contains(&component.as_str())
                    && policy.phases.contains(&phase.as_str())
                    && self
                        .owners
                        .get(owner_name(policy, &component))
                        .is_some_and(|owner| owner.supports(capability))
            })
            .map(|(capability, _)| capability.to_string())
            .collect();
        // The lane needs one bounded choice to reach a concise escalation
        // when the affected component owner is unavailable.
        Ok(if available.is_empty() {
            vec![HEALTH_CHECK.to_string()]
        } else {
            available
        })
    }

    fn perform(&self, capability: &str, call: BrokerCall) -> Result<RecoveryBrokerOutcome> {
        let Some(policy) = capability_policy(capability) else {
            return Ok(outcome(
                capability,
                "rejected",
                "capability_not_allowed",
                None,
            ));
        };
        let incident = &call.incident;
        let request = match Self::request(capability, policy, incident, &call) {
            Ok(request) => request,
            Err(code) => return Ok(outcome(capability, "rejected", code, None)),
        };
        if call.cancel.is_set() || self.now() >= call.deadline {
            return Ok(outcome(
                capability,
                "circuit_open",
                "recovery_budget_exhausted",
                None,
            ));
        }
        let Some(owner) = self.owners.get(owner_name(policy, &request.component)) else {
            return Ok(outcome(
                capability,
                "authorization_required",
                "component_owner_unavailable",
                None,
            ));
        };
        let broker_cooldown_active = {
            let mut state = self.lock();
            let attempts = state
                .attempts
                .get(&request.idempotency_key)
                .copied()
                .unwrap_or(0);
            if attempts >= policy.max_attempts {
                return Ok(outcome(
                    capability,
                    "circuit_open",
                    "capability_attempt_cap_reached",
                    None,
                ));
            }
            let cooling = self.now()
                < state
                    .cooldowns
                    .get(&request.idempotency_key)
                    .copied()
                    .unwrap_or(0.0);
            state
                .attempts
                .insert(request.idempotency_key.clone(), attempts + 1);
            cooling
        };

        let validation = owner.inspect(&request)?;
        if let Some((status, code)) = Self::validation_rejection(policy, &request, &validation) {
            return Ok(outcome(
                capability,
                status,
                code,
                Some(Self::validated_health(incident, &validation.health)),
            ));
        }
        let already_applied = self.lock().applied.contains(&request.idempotency_key);
        if already_applied || validation.idempotency_state == "applied" {
            return Ok(outcome(
                capability,
                "noop",
                "action_already_applied",
                Some(Self::validated_health(incident, &validation.health)),
            ));
        }
        if broker_cooldown_active {
            return Ok(outcome(
                capability,
                "circuit_open",
                "capability_cooldown_active",
                None,
            ));
        }
        if call.cancel.is_set() || self.now() >= call.deadline {
            return Ok(outcome(
                capability,
                "circuit_open",
                "recovery_budget_exhausted",
                None,
            ));
        }

        let result = owner.execute(&request, &validation, &call.cancel)?;
        if result.ephemeral_state_created && (result.status == "failed" || result.health_worsened) {
            let health = Self::validated_health(incident, &result.health);
            if !validation.compensation_available {
                return Ok(outcome(
                    capability,
                    "circuit_open",
                    "ephemeral_cleanup_unavailable",
                    Some(health),
                ));
            }
            let cleaned = owner.cleanup(&request, &validation)?;
            let (status, code) = if cleaned {
                ("failed", "ephemeral_cleanup_applied")
            } else {
                ("circuit_open", "ephemeral_cleanup_failed")
            };
            return Ok(outcome(capability, status, code, Some(health)));
        }
        if result.health_worsened {
            return Ok(outcome(
                capability,
                "circuit_open",
                "recovery_health_worsened",
                Some(Self::validated_health(incident, &result.health)),
            ));
        }
        let health = Self::validated_health(incident, &result.health);
        if result.status == "applied" {
            let mut state = self.lock();
            state.applied.insert(request.idempotency_key.clone());
            state.cooldowns.insert(
                request.idempotency_key.clone(),
                self.now() + policy.cooldown_seconds,
            );
        }
        RecoveryBrokerOutcome::new(capability, &result.status, &result.outcome_code, health)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_follow_the_policy() {
        assert_eq!(recovery_owner_for("restart_bridge", "bridge"), "app");
        assert_eq!(recovery_owner_for("reconnect_ipc", "messenger"), "bridge");
        assert_eq!(
            recovery_owner_for("reconnect_ipc", "orchestrator"),
            "daemon"
        );
        assert_eq!(recovery_owner_for("edit_source", "bridge"), "");
        for operation in DISALLOWED_RECOVERY_OPERATIONS {
            assert!(capability_policy(operation).is_none());
        }
    }

    #[test]
    fn the_production_registry_needs_every_fixed_capability() {
        let probe: HealthProbe = Arc::new(|_| Ok(RecoveryHealthEvidence::default()));
        assert_eq!(
            production_recovery_owners(probe, &BTreeMap::new())
                .err()
                .unwrap()
                .message,
            "production recovery registry requires every fixed capability"
        );
    }
}
