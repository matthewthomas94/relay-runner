//! `services/continuity_agent.py`: the isolated, bounded provider lane for
//! voice continuity recovery.
//!
//! The provider has no native tools. It can only return a small JSON request
//! that the lane validates against a [`RecoveryBroker`]; concrete runtime
//! recovery belongs to the broker, not to this module or the provider
//! process. The provider process itself is behind
//! [`ContinuityProviderSession`]: [`super::providers`] builds its Codex or
//! Claude launch configuration, and the daemon supplies the process.
//!
//! Where Python catches any exception and prints only its class, the Rust lane
//! does the same with the [`Error`](crate::Error) class; a panic in a broker
//! call counts as a failed call.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::panic::{self, AssertUnwindSafe};
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use relay_intents::json;

use super::incidents::{OBJECTIVES, PHASES, PROVIDERS};
use super::{
    Clock, Event, generation, is_code, is_prefixed_hex, monotonic_clock,
    normalize_recovery_generation, random_hex32, wall_clock,
};
use crate::{Dict, Error, Result, Value};

pub const ACTOR_ROLE: &str = "continuity-agent";
pub const SCHEMA_VERSION: i64 = 1;

const CHILD_ENVIRONMENT_ALLOWLIST: [&str; 7] = [
    "HOME", "LANG", "LC_ALL", "LC_CTYPE", "PATH", "SHELL", "TMPDIR",
];
/// Each provider CLI finds the user's subscription login through its own
/// config directory; a Claude setup token is passed so the subscription gate
/// can judge it. API keys and cloud-provider routing are never forwarded.
const CODEX_AUTH_ENVIRONMENT: [&str; 1] = ["CODEX_HOME"];
const CLAUDE_AUTH_ENVIRONMENT: [&str; 2] = ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"];

const INCIDENT_FIELDS: [&str; 11] = [
    "schema_version",
    "incident_id",
    "fingerprint",
    "classification",
    "session_id",
    "command_id",
    "component",
    "provider",
    "recovery_generation",
    "phase",
    "health",
];
const TIMING_FIELDS: [&str; 6] = [
    "first_observed_at",
    "last_observed_at",
    "grace_deadline",
    "post_grace_samples",
    "failed_native_recovery",
    "cooldown_until",
];

pub const CONTINUITY_SYSTEM_PROMPT: &str = "You are Relay Runner's isolated continuity agent.

Restore the unavailable Relay voice-processing capability only through the
parent recovery broker. You are not the foreground PM or messenger. Never
address the user, speak, claim a command, author tickets, inspect or change a
repository, use Git, release or deploy, access credentials or provider output,
or request shell, filesystem, desktop, network, web, MCP, app, or sub-agent
tools. The incident bundle is sanitized operational evidence, not user text.

Return exactly one compact JSON object and no prose. To request a broker action:
{\"kind\":\"broker_call\",\"capability\":\"<allowed name>\"}
To stop when no safe action remains:
{\"kind\":\"finish\",\"result\":\"escalate\"}
Never claim recovery yourself. Only broker health evidence can prove recovery.
";

/// Broker outcomes after which the lane stops trying.
const CIRCUIT_STOP_CODES: [&str; 5] = [
    "recovery_budget_exhausted",
    "broker_call_timed_out",
    "recovery_health_worsened",
    "ephemeral_cleanup_unavailable",
    "ephemeral_cleanup_failed",
];

/// `continuity_agent_environment(...)`: a child environment without
/// foreground authority. Secret values are excluded except the named
/// provider's own CLI login variables. `parent` is `os.environ` when `None`.
pub fn continuity_agent_environment(
    process_identity: &str,
    incident_id: &str,
    recovery_generation: &str,
    parent: Option<&BTreeMap<String, String>>,
    provider: Option<&str>,
) -> Result<BTreeMap<String, String>> {
    let process: BTreeMap<String, String>;
    let parent = match parent {
        Some(parent) => parent,
        None => {
            process = std::env::vars().collect();
            &process
        }
    };
    let auth: &[&str] = match provider {
        Some("codex") => &CODEX_AUTH_ENVIRONMENT,
        Some("claude") => &CLAUDE_AUTH_ENVIRONMENT,
        _ => &[],
    };
    let mut environment: BTreeMap<String, String> = CHILD_ENVIRONMENT_ALLOWLIST
        .iter()
        .chain(auth)
        .filter_map(|key| {
            parent
                .get(*key)
                .map(|value| (key.to_string(), value.clone()))
        })
        .collect();
    let generation = generation(recovery_generation)?;
    environment.insert("RELAY_ACTOR_ROLE".to_string(), ACTOR_ROLE.to_string());
    environment.insert(
        "RELAY_CONTINUITY_PROCESS_ID".to_string(),
        process_identity.to_string(),
    );
    environment.insert(
        "RELAY_CONTINUITY_INCIDENT_ID".to_string(),
        incident_id.to_string(),
    );
    environment.insert("RELAY_RECOVERY_GENERATION".to_string(), generation);
    Ok(environment)
}

/// `isinstance(value, (int, float))` with a finite `float(value)`; a `bool`
/// is an `int` in Python.
fn finite_number(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(_) | Value::Int(_)) => true,
        Some(Value::BigInt(digits)) => digits.parse::<f64>().is_ok_and(f64::is_finite),
        Some(Value::Float(number)) => number.is_finite(),
        _ => false,
    }
}

fn text_field<'d>(bundle: &'d Dict, key: &str) -> Option<&'d str> {
    bundle
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
}

/// `sanitize_incident_bundle(envelope)`: only the fixed incident envelope,
/// copied into the provider-facing bundle and checked field by field.
pub fn sanitize_incident_bundle(envelope: &Value) -> Result<Dict> {
    let Some(envelope) = envelope.as_dict() else {
        return Err(Error::value("continuity incident must be an object"));
    };
    let mut bundle = Dict::new();
    for key in INCIDENT_FIELDS {
        bundle.insert(key, envelope.get(key).cloned().unwrap_or(Value::Null));
    }
    let (Some(timing), Some(_)) = (
        envelope.get("timing").and_then(Value::as_dict),
        envelope.get("recovery_objective").and_then(Value::as_dict),
    ) else {
        return Err(Error::value(
            "continuity incident is missing timing or recovery objective",
        ));
    };
    let mut timing_bundle = Dict::new();
    for key in TIMING_FIELDS {
        timing_bundle.insert(key, timing.get(key).cloned().unwrap_or(Value::Null));
    }

    let required = [
        "incident_id",
        "fingerprint",
        "classification",
        "session_id",
        "component",
        "provider",
        "phase",
        "health",
    ];
    if required
        .iter()
        .any(|key| text_field(&bundle, key).is_none())
    {
        return Err(Error::value(
            "continuity incident is missing required identity fields",
        ));
    }
    let text = |key: &str| text_field(&bundle, key).unwrap_or_default().to_string();
    if !json::py_eq(
        bundle.get("schema_version").unwrap_or(&Value::Null),
        &Value::Int(1),
    ) {
        return Err(Error::value("unsupported continuity incident schema"));
    }
    if !["stalled", "recurring"].contains(&text("classification").as_str()) {
        return Err(Error::value(
            "continuity agent requires a stalled or recurring incident",
        ));
    }
    let component = text("component");
    let component_known = OBJECTIVES.iter().any(|(name, _, _)| *name == component);
    if !component_known || !PROVIDERS.contains(&text("provider").as_str()) {
        return Err(Error::value("unsupported continuity component or provider"));
    }
    if !PHASES.contains(&text("phase").as_str())
        || !["unavailable", "recovery_failed"].contains(&text("health").as_str())
    {
        return Err(Error::value("unsupported continuity phase or health"));
    }
    if !is_prefixed_hex(&text("incident_id"), "inc-", 12) {
        return Err(Error::value("invalid continuity incident identity"));
    }
    if !is_prefixed_hex(&text("fingerprint"), "fp-", 24) {
        return Err(Error::value("invalid continuity fingerprint"));
    }
    if !is_prefixed_hex(&text("session_id"), "session-", 24) {
        return Err(Error::value("invalid continuity session identity"));
    }
    if let Some(command) = bundle.present("command_id")
        && !is_prefixed_hex(&command.py_str(), "command-", 24)
    {
        return Err(Error::value("invalid continuity command identity"));
    }
    let generation = normalize_recovery_generation(bundle.get("recovery_generation"))
        .map_err(|_| Error::value("invalid continuity recovery generation"))?;
    bundle.insert("recovery_generation", generation);
    for key in [
        "first_observed_at",
        "last_observed_at",
        "grace_deadline",
        "cooldown_until",
    ] {
        if !finite_number(timing_bundle.get(key)) {
            return Err(Error::value("invalid continuity timing evidence"));
        }
    }
    let samples_valid = match timing_bundle.get("post_grace_samples") {
        Some(Value::Bool(_)) => true,
        Some(Value::Int(number)) => *number >= 0,
        Some(Value::BigInt(digits)) => !digits.starts_with('-'),
        _ => false,
    };
    if !samples_valid {
        return Err(Error::value("invalid continuity liveness samples"));
    }
    if !matches!(
        timing_bundle.get("failed_native_recovery"),
        Some(Value::Bool(_))
    ) {
        return Err(Error::value("invalid continuity recovery evidence"));
    }
    bundle.insert("timing", timing_bundle);
    let objective = super::incidents::objective(&component)
        .ok_or_else(|| Error::value("unsupported continuity component or provider"))?;
    bundle.insert("recovery_objective", objective.as_dict());
    Ok(bundle)
}

/// `RecoveryHealthEvidence`: objective health proven by component evidence.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RecoveryHealthEvidence {
    pub objective_restored: bool,
    pub stable_for_seconds: f64,
    pub evidence_codes: Vec<String>,
}

impl RecoveryHealthEvidence {
    /// `RecoveryHealthEvidence(...)` with its `__post_init__` checks.
    pub fn new(
        objective_restored: bool,
        stable_for_seconds: f64,
        evidence_codes: Vec<String>,
    ) -> Result<Self> {
        if !stable_for_seconds.is_finite() || stable_for_seconds < 0.0 {
            return Err(Error::value(
                "stable health duration must be finite and non-negative",
            ));
        }
        if evidence_codes.iter().any(|code| !is_code(code)) {
            return Err(Error::value("health evidence must use sanitized codes"));
        }
        Ok(Self {
            objective_restored,
            stable_for_seconds,
            evidence_codes,
        })
    }

    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("objective_restored", self.objective_restored);
        value.insert("stable_for_seconds", self.stable_for_seconds);
        value.insert(
            "evidence_codes",
            Value::List(
                self.evidence_codes
                    .iter()
                    .map(|code| Value::from(code.as_str()))
                    .collect(),
            ),
        );
        value
    }
}

pub const BROKER_STATUSES: [&str; 6] = [
    "applied",
    "noop",
    "rejected",
    "failed",
    "authorization_required",
    "circuit_open",
];

/// `RecoveryBrokerOutcome`: one sanitized broker result.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryBrokerOutcome {
    pub capability: String,
    pub status: String,
    pub outcome_code: String,
    pub health: RecoveryHealthEvidence,
}

impl RecoveryBrokerOutcome {
    /// `RecoveryBrokerOutcome(...)` with its `__post_init__` checks.
    pub fn new(
        capability: &str,
        status: &str,
        outcome_code: &str,
        health: RecoveryHealthEvidence,
    ) -> Result<Self> {
        if !is_code(capability) {
            return Err(Error::value("invalid recovery capability"));
        }
        if !BROKER_STATUSES.contains(&status) {
            return Err(Error::value("invalid recovery broker status"));
        }
        if !is_code(outcome_code) {
            return Err(Error::value("recovery outcomes must use sanitized codes"));
        }
        Ok(Self {
            capability: capability.to_string(),
            status: status.to_string(),
            outcome_code: outcome_code.to_string(),
            health,
        })
    }

    /// An outcome whose status and code are fixed by this crate; only the
    /// capability can be invalid, which leaves it as written.
    pub(crate) fn fixed(capability: &str, status: &str, code: &str) -> Self {
        Self::fixed_with(capability, status, code, RecoveryHealthEvidence::default())
    }

    pub(crate) fn fixed_with(
        capability: &str,
        status: &str,
        code: &str,
        health: RecoveryHealthEvidence,
    ) -> Self {
        Self {
            capability: capability.to_string(),
            status: status.to_string(),
            outcome_code: code.to_string(),
            health,
        }
    }

    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("capability", self.capability.as_str());
        value.insert("status", self.status.as_str());
        value.insert("outcome_code", self.outcome_code.as_str());
        value.insert("health", self.health.as_dict());
        value
    }
}

/// The arguments of one `RecoveryBroker.perform` call.
#[derive(Clone)]
pub struct BrokerCall {
    pub incident: Dict,
    pub process_identity: String,
    pub recovery_generation: String,
    pub attempt: i64,
    pub deadline: f64,
    pub cancel: Event,
}

/// `RecoveryBroker`: what the lane may ask for, and the call that does it.
pub trait RecoveryBroker: Send + Sync {
    fn capabilities(&self, incident: &Dict) -> Result<Vec<String>>;
    fn perform(&self, capability: &str, call: BrokerCall) -> Result<RecoveryBrokerOutcome>;
}

/// `UnavailableRecoveryBroker`: the fallback for callers that have not
/// installed the component-owned broker.
pub struct UnavailableRecoveryBroker;

impl RecoveryBroker for UnavailableRecoveryBroker {
    fn capabilities(&self, _incident: &Dict) -> Result<Vec<String>> {
        Ok(vec!["inspect_recovery_availability".to_string()])
    }

    fn perform(&self, capability: &str, _call: BrokerCall) -> Result<RecoveryBrokerOutcome> {
        if capability != "inspect_recovery_availability" {
            return RecoveryBrokerOutcome::new(
                capability,
                "rejected",
                "capability_not_allowed",
                RecoveryHealthEvidence::default(),
            );
        }
        RecoveryBrokerOutcome::new(
            capability,
            "circuit_open",
            "recovery_broker_unavailable",
            RecoveryHealthEvidence::default(),
        )
    }
}

/// `ContinuityAgentConfig`.
#[derive(Clone, Debug, PartialEq)]
pub struct ContinuityAgentConfig {
    /// Attempts for each distinct broker capability.
    pub max_attempts: i64,
    pub wall_clock_seconds: f64,
    pub stable_health_seconds: f64,
    pub cooldown_seconds: f64,
}

impl Default for ContinuityAgentConfig {
    fn default() -> Self {
        Self {
            max_attempts: 4,
            wall_clock_seconds: 120.0,
            stable_health_seconds: 60.0,
            cooldown_seconds: 15.0 * 60.0,
        }
    }
}

impl ContinuityAgentConfig {
    /// `ContinuityAgentConfig.__post_init__`.
    pub fn validated(self) -> Result<Self> {
        if self.max_attempts < 1 {
            return Err(Error::value(
                "continuity agent requires at least one attempt",
            ));
        }
        for value in [
            self.wall_clock_seconds,
            self.stable_health_seconds,
            self.cooldown_seconds,
        ] {
            if !value.is_finite() || value < 0.0 {
                return Err(Error::value(
                    "continuity lifecycle limits must be finite and non-negative",
                ));
            }
        }
        Ok(self)
    }

    /// The daemon's `[continuity]` table, as `Orchestrator.__init__` reads it:
    /// at least one attempt and one second, never a negative duration.
    pub fn from_app_config(continuity: &Dict) -> Result<Self> {
        let integer = |key: &str, default: i64| -> Result<i64> {
            match continuity.get(key) {
                None => Ok(default),
                Some(value) => value
                    .py_int()
                    .ok_or_else(|| Error::value(format!("invalid continuity {key}"))),
            }
        };
        let number = |key: &str, default: f64| -> Result<f64> {
            match continuity.get(key) {
                None => Ok(default),
                Some(value) => value
                    .py_float()
                    .ok_or_else(|| Error::value(format!("invalid continuity {key}"))),
            }
        };
        Self {
            max_attempts: integer("max_attempts", 4)?.max(1),
            wall_clock_seconds: number("wall_clock_seconds", 120.0)?.max(1.0),
            stable_health_seconds: number("stable_health_seconds", 60.0)?.max(0.0),
            cooldown_seconds: number("cooldown_seconds", 900.0)?.max(0.0),
        }
        .validated()
    }
}

/// `ContinuityProviderSession`: one tool-less provider process.
pub trait ContinuityProviderSession: Send + Sync {
    fn provider(&self) -> String;
    /// The provider's answer to `prompt`, stripped.
    fn decide(&self, prompt: &str, timeout: f64) -> Result<String>;
    fn interrupt(&self) -> Result<()>;
    fn shutdown(&self) -> Result<()>;
}

/// `UnavailableContinuitySession`: a provider that cannot launch; every
/// decision fails with its reason code.
pub struct UnavailableContinuitySession {
    pub provider: String,
    pub reason_code: String,
}

impl ContinuityProviderSession for UnavailableContinuitySession {
    fn provider(&self) -> String {
        self.provider.clone()
    }

    fn decide(&self, _prompt: &str, _timeout: f64) -> Result<String> {
        Err(Error::runtime(self.reason_code.clone()))
    }

    fn interrupt(&self) -> Result<()> {
        Ok(())
    }

    fn shutdown(&self) -> Result<()> {
        Ok(())
    }
}

/// `session_factory(process_identity, incident_id, recovery_generation)`.
pub type SessionFactory =
    Arc<dyn Fn(&str, &str, &str) -> Result<Arc<dyn ContinuityProviderSession>> + Send + Sync>;
/// `on_audit(record)`.
pub type AuditSink = Arc<dyn Fn(&Dict) -> Result<()> + Send + Sync>;
/// `on_result(incident, final_result)`.
pub type ResultSink = Arc<dyn Fn(&Dict, &str) -> Result<()> + Send + Sync>;
/// `wait(seconds)`: whether the wait was interrupted.
pub type Wait = Arc<dyn Fn(f64) -> bool + Send + Sync>;

/// The lane's optional keyword arguments.
#[derive(Clone)]
pub struct LaneOptions {
    pub on_result: Option<ResultSink>,
    pub config: ContinuityAgentConfig,
    pub monotonic: Clock,
    pub wait: Option<Wait>,
}

impl Default for LaneOptions {
    fn default() -> Self {
        Self {
            on_result: None,
            config: ContinuityAgentConfig::default(),
            monotonic: monotonic_clock(),
            wait: None,
        }
    }
}

#[derive(Default)]
struct LaneState {
    active_incident: Option<String>,
    active_session: Option<Arc<dyn ContinuityProviderSession>>,
    active_broker_cancel: Option<Event>,
    pending: Vec<Dict>,
    cooldowns: BTreeMap<String, f64>,
}

struct Lane {
    factory: SessionFactory,
    broker: Arc<dyn RecoveryBroker>,
    on_audit: AuditSink,
    options: LaneOptions,
    state: Mutex<LaneState>,
    shutdown: Event,
    idle: Event,
}

/// `ContinuityAgentLane`: a single-flight continuity agent with broker,
/// attempt, wall-clock and cooldown limits. Each incident runs on its own
/// thread; a distinct incident submitted meanwhile waits its turn.
#[derive(Clone)]
pub struct ContinuityAgentLane {
    lane: Arc<Lane>,
}

enum Decision {
    Finish,
    Call(String),
}

impl ContinuityAgentLane {
    pub fn new(
        factory: SessionFactory,
        broker: Arc<dyn RecoveryBroker>,
        on_audit: AuditSink,
        options: LaneOptions,
    ) -> Self {
        let idle = Event::new();
        idle.set();
        Self {
            lane: Arc::new(Lane {
                factory,
                broker,
                on_audit,
                options,
                state: Mutex::new(LaneState::default()),
                shutdown: Event::new(),
                idle,
            }),
        }
    }

    pub fn config(&self) -> &ContinuityAgentConfig {
        &self.lane.options.config
    }

    /// `submit(envelope)`: `launched`, `duplicate`, `single_flight` (queued
    /// behind the active incident), `cooldown` or `shutdown`. An invalid
    /// envelope is a `ValueError`.
    pub fn submit(&self, envelope: &Value) -> Result<&'static str> {
        let incident = sanitize_incident_bundle(envelope)?;
        let incident_id = incident.string("incident_id");
        let fingerprint = incident.string("fingerprint");
        let now = (self.lane.options.monotonic)();
        {
            let mut state = self.lane.lock();
            if self.lane.shutdown.is_set() {
                return Ok("shutdown");
            }
            if let Some(active) = &state.active_incident {
                if *active == incident_id
                    || state
                        .pending
                        .iter()
                        .any(|pending| pending.string("incident_id") == incident_id)
                {
                    return Ok("duplicate");
                }
                state.pending.push(incident);
                return Ok("single_flight");
            }
            if now < state.cooldowns.get(&fingerprint).copied().unwrap_or(0.0) {
                return Ok("cooldown");
            }
            state.active_incident = Some(incident_id.clone());
            self.lane.idle.clear();
        }
        Lane::start(&self.lane, incident);
        Ok("launched")
    }

    pub fn wait_until_idle(&self, timeout: f64) -> bool {
        self.lane.idle.wait(timeout.max(0.0))
    }

    pub fn shutdown(&self) {
        self.lane.shutdown.set();
        let (session, cancel) = {
            let state = self.lane.lock();
            (
                state.active_session.clone(),
                state.active_broker_cancel.clone(),
            )
        };
        if let Some(cancel) = cancel {
            cancel.set();
        }
        if let Some(session) = session {
            let _ = session.interrupt();
        }
        self.lane.idle.wait(2.0);
    }
}

impl Lane {
    fn lock(&self) -> MutexGuard<'_, LaneState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn now(&self) -> f64 {
        (self.options.monotonic)()
    }

    fn start(lane: &Arc<Lane>, incident: Dict) {
        let name = format!("relay-continuity-{}", incident.string("incident_id"));
        let worker = Arc::clone(lane);
        let spawned = thread::Builder::new()
            .name(name)
            .spawn(move || worker.run(incident));
        if spawned.is_err() {
            eprintln!("[continuity-agent] recovery lane failed (RuntimeError)");
            let mut state = lane.lock();
            state.active_incident = None;
            lane.idle.set();
        }
    }

    fn run(self: Arc<Self>, incident: Dict) {
        let incident_id = incident.string("incident_id");
        let fingerprint = incident.string("fingerprint");
        let generation = incident.string("recovery_generation");
        let process_identity = format!("continuity-{}", random_hex32());
        let started = self.now();
        let deadline = started + self.options.config.wall_clock_seconds;
        let session = match (self.factory)(&process_identity, &incident_id, &generation) {
            Ok(session) => session,
            Err(error) => {
                eprintln!(
                    "[continuity-agent] provider launch failed ({})",
                    error.class
                );
                let provider = incident
                    .truthy("provider")
                    .map_or_else(|| "none".to_string(), Value::py_str);
                self.audit(
                    &incident,
                    &process_identity,
                    &provider,
                    "launch_failed",
                    0,
                    None,
                    Some("provider_failed"),
                );
                self.publish_result(&incident, "provider_failed");
                Self::finish_incident(&self, &fingerprint);
                return;
            }
        };
        self.lock().active_session = Some(Arc::clone(&session));
        let provider = session.provider();
        self.audit(
            &incident,
            &process_identity,
            &provider,
            "launched",
            0,
            None,
            None,
        );
        let (final_result, attempts) = self.recover(
            &incident,
            &session,
            &process_identity,
            &generation,
            deadline,
        );
        let _ = session.shutdown();
        self.audit(
            &incident,
            &process_identity,
            &provider,
            "completed",
            attempts,
            None,
            Some(final_result),
        );
        self.publish_result(&incident, final_result);
        Self::finish_incident(&self, &fingerprint);
    }

    /// The broker loop of `_run`: the final result and how many outcomes it
    /// recorded.
    fn recover(
        &self,
        incident: &Dict,
        session: &Arc<dyn ContinuityProviderSession>,
        process_identity: &str,
        generation: &str,
        deadline: f64,
    ) -> (&'static str, i64) {
        let config = &self.options.config;
        let provider = session.provider();
        let mut final_result = "circuit_open";
        let mut history: Vec<Value> = Vec::new();
        let mut capability_attempts: Vec<(String, i64)> = Vec::new();
        let mut recovery_applied = false;
        let mut forced: Option<String> = None;
        let attempts_of = |attempts: &[(String, i64)], capability: &str| {
            attempts
                .iter()
                .find(|(name, _)| name == capability)
                .map_or(0, |(_, count)| *count)
        };
        let capabilities = match self
            .broker
            .capabilities(incident)
            .and_then(validated_capabilities)
        {
            Ok(capabilities) => capabilities,
            Err(error) => {
                eprintln!("[continuity-agent] recovery lane failed ({})", error.class);
                return (final_result, 0);
            }
        };
        let health_check = "check_processing_health";
        let offers_health_check = capabilities.iter().any(|item| item == health_check);
        let max_steps = config
            .max_attempts
            .saturating_mul(capabilities.len() as i64);
        for sequence in 1..=max_steps {
            if self.shutdown.is_set() {
                final_result = "canceled";
                break;
            }
            let remaining = deadline - self.now();
            if remaining <= 0.0 {
                break;
            }
            let capability = match forced.take() {
                Some(capability) => capability,
                None => {
                    let prompt = prompt(
                        incident,
                        &capabilities,
                        &history,
                        sequence,
                        &capability_attempts,
                    );
                    let decision = session
                        .decide(&prompt, remaining)
                        .and_then(|raw| parse_decision(&raw));
                    match decision {
                        Err(error) => {
                            eprintln!(
                                "[continuity-agent] provider decision failed ({})",
                                error.class
                            );
                            final_result = "provider_failed";
                            break;
                        }
                        Ok(Decision::Finish) => {
                            if recovery_applied
                                && offers_health_check
                                && attempts_of(&capability_attempts, health_check)
                                    < config.max_attempts
                            {
                                health_check.to_string()
                            } else {
                                break;
                            }
                        }
                        Ok(Decision::Call(capability)) => capability,
                    }
                }
            };
            let attempt = attempts_of(&capability_attempts, &capability) + 1;
            match capability_attempts
                .iter_mut()
                .find(|(name, _)| *name == capability)
            {
                Some(entry) => entry.1 = attempt,
                None => capability_attempts.push((capability.clone(), attempt)),
            }
            let outcome = if !capabilities.contains(&capability) {
                RecoveryBrokerOutcome::fixed(&capability, "rejected", "capability_not_allowed")
            } else {
                match self.perform_broker_action(
                    &capability,
                    incident,
                    process_identity,
                    generation,
                    attempt,
                    deadline,
                ) {
                    Ok(outcome) => outcome,
                    Err(error) => {
                        eprintln!(
                            "[continuity-agent] recovery broker failed ({})",
                            error.class
                        );
                        RecoveryBrokerOutcome::fixed(&capability, "failed", "broker_call_failed")
                    }
                }
            };
            history.push(Value::Dict(outcome.as_dict()));
            self.audit(
                incident,
                process_identity,
                &provider,
                "broker_outcome",
                sequence,
                Some(&outcome),
                None,
            );
            if outcome.status == "applied" && capability != health_check {
                recovery_applied = true;
            }
            if outcome.health.objective_restored
                && outcome.health.stable_for_seconds >= config.stable_health_seconds
            {
                final_result = "restored";
                break;
            }
            if recovery_applied
                && outcome.health.objective_restored
                && offers_health_check
                && attempts_of(&capability_attempts, health_check) < config.max_attempts
            {
                let stable_wait = (config.stable_health_seconds
                    - outcome.health.stable_for_seconds)
                    .max(0.0)
                    .min((deadline - self.now()).max(0.0));
                if stable_wait <= 0.0 {
                    break;
                }
                let interrupted = match &self.options.wait {
                    Some(wait) => wait(stable_wait),
                    None => self.shutdown.wait(stable_wait),
                };
                if interrupted || self.shutdown.is_set() {
                    final_result = "canceled";
                    break;
                }
                forced = Some(health_check.to_string());
            }
            if outcome.status == "authorization_required" {
                final_result = "authorization_required";
                break;
            }
            if outcome.status == "circuit_open"
                && CIRCUIT_STOP_CODES.contains(&outcome.outcome_code.as_str())
            {
                break;
            }
        }
        (final_result, history.len() as i64)
    }

    fn finish_incident(lane: &Arc<Lane>, fingerprint: &str) {
        let next = {
            let mut state = lane.lock();
            let now = lane.now();
            state.cooldowns.insert(
                fingerprint.to_string(),
                now + lane.options.config.cooldown_seconds,
            );
            state.active_incident = None;
            state.active_session = None;
            let mut next = None;
            if lane.shutdown.is_set() {
                state.pending.clear();
            } else {
                while !state.pending.is_empty() {
                    let candidate = state.pending.remove(0);
                    let candidate_fingerprint = candidate.string("fingerprint");
                    if now
                        < state
                            .cooldowns
                            .get(&candidate_fingerprint)
                            .copied()
                            .unwrap_or(0.0)
                    {
                        continue;
                    }
                    state.active_incident = Some(candidate.string("incident_id"));
                    next = Some(candidate);
                    break;
                }
            }
            if next.is_none() {
                lane.idle.set();
            }
            next
        };
        if let Some(incident) = next {
            Lane::start(lane, incident);
        }
    }

    fn publish_result(&self, incident: &Dict, final_result: &str) {
        if let Some(on_result) = &self.options.on_result
            && let Err(error) = on_result(incident, final_result)
        {
            eprintln!(
                "[continuity-agent] result callback failed ({})",
                error.class
            );
        }
    }

    fn perform_broker_action(
        &self,
        capability: &str,
        incident: &Dict,
        process_identity: &str,
        generation: &str,
        attempt: i64,
        deadline: f64,
    ) -> Result<RecoveryBrokerOutcome> {
        let timed_out =
            || RecoveryBrokerOutcome::fixed(capability, "circuit_open", "broker_call_timed_out");
        if deadline - self.now() <= 0.0 {
            return Ok(timed_out());
        }
        let cancel = Event::new();
        {
            let mut state = self.lock();
            state.active_broker_cancel = Some(cancel.clone());
            if self.shutdown.is_set() {
                cancel.set();
            }
        }
        let call = BrokerCall {
            incident: incident.clone(),
            process_identity: process_identity.to_string(),
            recovery_generation: generation.to_string(),
            attempt,
            deadline,
            cancel: cancel.clone(),
        };
        let (sender, receiver) = mpsc::channel();
        let broker = Arc::clone(&self.broker);
        let name = capability.to_string();
        let spawned = thread::Builder::new()
            .name(format!("relay-continuity-broker-{capability}"))
            .spawn(move || {
                let result = panic::catch_unwind(AssertUnwindSafe(|| broker.perform(&name, call)))
                    .unwrap_or_else(|_| Err(Error::runtime("recovery broker panicked")));
                let _ = sender.send(result);
            });
        let result = match spawned {
            Err(error) => Err(Error::from(error)),
            Ok(_) => {
                let remaining = (deadline - self.now()).max(0.0);
                match receiver.recv_timeout(Duration::from_secs_f64(remaining.min(1.0e9))) {
                    Ok(result) => result,
                    Err(RecvTimeoutError::Timeout) => {
                        cancel.set();
                        let _ = receiver.recv();
                        Ok(timed_out())
                    }
                    Err(RecvTimeoutError::Disconnected) => {
                        Err(Error::runtime("recovery broker stopped"))
                    }
                }
            }
        };
        let mut state = self.lock();
        if state
            .active_broker_cancel
            .as_ref()
            .is_some_and(|active| active.same(&cancel))
        {
            state.active_broker_cancel = None;
        }
        result
    }

    #[allow(clippy::too_many_arguments)]
    fn audit(
        &self,
        incident: &Dict,
        process_identity: &str,
        provider: &str,
        phase: &str,
        attempt: i64,
        outcome: Option<&RecoveryBrokerOutcome>,
        final_result: Option<&str>,
    ) {
        let record = audit_record(
            incident,
            process_identity,
            provider,
            phase,
            attempt,
            outcome,
            final_result,
            wall_clock(),
        );
        if let Err(error) = (self.on_audit)(&record) {
            eprintln!("[continuity-agent] audit callback failed ({})", error.class);
        }
    }
}

/// `_validated_capabilities`: non-empty sanitized codes, first of each kept.
fn validated_capabilities(capabilities: Vec<String>) -> Result<Vec<String>> {
    if capabilities.is_empty() || capabilities.iter().any(|item| !is_code(item)) {
        return Err(Error::value("recovery broker exposed invalid capabilities"));
    }
    let mut unique: Vec<String> = Vec::new();
    for capability in capabilities {
        if !unique.contains(&capability) {
            unique.push(capability);
        }
    }
    Ok(unique)
}

/// `_parse_decision(raw)`.
fn parse_decision(raw: &str) -> Result<Decision> {
    let decision =
        json::parse(raw).ok_or_else(|| Error::value("continuity agent returned invalid JSON"))?;
    let Some(decision) = decision.as_dict() else {
        return Err(Error::value(
            "continuity agent returned an invalid decision",
        ));
    };
    if decision
        .iter()
        .any(|(key, _)| !["kind", "capability", "result"].contains(&key))
    {
        return Err(Error::value(
            "continuity agent returned an invalid decision",
        ));
    }
    let kind = decision.get("kind");
    if kind.is_some_and(|kind| kind.is_str("finish"))
        && decision
            .get("result")
            .is_some_and(|result| result.is_str("escalate"))
    {
        return Ok(Decision::Finish);
    }
    let capability = decision.get("capability").and_then(Value::as_str);
    let (true, Some(capability)) = (
        kind.is_some_and(|kind| kind.is_str("broker_call")),
        capability,
    ) else {
        return Err(Error::value(
            "continuity agent returned an invalid broker request",
        ));
    };
    if !is_code(capability) {
        return Err(Error::value(
            "continuity agent returned an invalid capability",
        ));
    }
    Ok(Decision::Call(capability.to_string()))
}

/// `_parse_decision(raw)` as the decision dict Python returns.
pub fn parse_decision_dict(raw: &str) -> Result<Dict> {
    let mut value = Dict::new();
    match parse_decision(raw)? {
        Decision::Finish => {
            value.insert("kind", "finish");
            value.insert("result", "escalate");
        }
        Decision::Call(capability) => {
            value.insert("kind", "broker_call");
            value.insert("capability", capability);
        }
    }
    Ok(value)
}

/// `_prompt(...)`: the system prompt and the sanitized recovery state.
pub fn prompt(
    incident: &Dict,
    capabilities: &[String],
    history: &[Value],
    sequence: i64,
    capability_attempts: &[(String, i64)],
) -> String {
    let mut objective = Dict::new();
    objective.insert("name", "restore_processing");
    if let Some(recovery) = incident.get("recovery_objective").and_then(Value::as_dict) {
        objective.update(recovery);
    }
    let mut attempts = Dict::new();
    for (capability, count) in capability_attempts {
        attempts.insert(capability, *count);
    }
    let mut payload = Dict::new();
    payload.insert("incident", incident.clone());
    payload.insert("broker_objective", objective);
    payload.insert(
        "broker_capabilities",
        Value::List(
            capabilities
                .iter()
                .map(|item| Value::from(item.as_str()))
                .collect(),
        ),
    );
    payload.insert("sanitized_outcomes", Value::List(history.to_vec()));
    payload.insert("sequence", sequence);
    payload.insert("capability_attempts", attempts);
    format!(
        "{CONTINUITY_SYSTEM_PROMPT}\n\nRecovery state:\n{}",
        json::dumps_compact_sorted(&Value::Dict(payload))
    )
}

/// One lane audit record, as `_audit` builds it at `recorded_at`.
#[allow(clippy::too_many_arguments)]
pub fn audit_record(
    incident: &Dict,
    process_identity: &str,
    provider: &str,
    phase: &str,
    attempt: i64,
    outcome: Option<&RecoveryBrokerOutcome>,
    final_result: Option<&str>,
    recorded_at: f64,
) -> Dict {
    let field = |key: &str| incident.get(key).cloned().unwrap_or(Value::Null);
    let mut record = Dict::new();
    record.insert("schema_version", SCHEMA_VERSION);
    record.insert("recorded_at", recorded_at);
    record.insert("incident_id", field("incident_id"));
    record.insert("fingerprint", field("fingerprint"));
    record.insert("actor_role", ACTOR_ROLE);
    record.insert("process_identity", process_identity);
    record.insert("provider", provider);
    record.insert("recovery_generation", field("recovery_generation"));
    record.insert("phase", phase);
    record.insert("attempt", attempt);
    if let Some(outcome) = outcome {
        record.insert("broker_outcome", outcome.as_dict());
    }
    if let Some(final_result) = final_result {
        record.insert("final_result", final_result);
    }
    record
}

/// `append_audit_record(path, record)`: one sorted, compact JSON line,
/// appended, with the file left owner-only. The daemon writes its incident
/// log (`continuity_incidents.jsonl`) the same way.
pub fn append_audit_record(path: &Path, record: &Dict) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut line = json::dumps_compact_sorted(&Value::Dict(record.clone()));
    line.push('\n');
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(line.as_bytes())?;
    drop(file);
    fs::set_permissions(path, Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decisions_parse_strictly() {
        assert_eq!(
            json::dumps(&Value::Dict(
                parse_decision_dict(r#"{"kind":"broker_call","capability":"restart_bridge"}"#)
                    .unwrap()
            )),
            r#"{"kind": "broker_call", "capability": "restart_bridge"}"#
        );
        assert!(matches!(
            parse_decision(r#"{"kind":"finish","result":"escalate"}"#),
            Ok(Decision::Finish)
        ));
        for (raw, message) in [
            ("nope", "continuity agent returned invalid JSON"),
            ("[1]", "continuity agent returned an invalid decision"),
            (
                r#"{"kind":"x","extra":1}"#,
                "continuity agent returned an invalid decision",
            ),
            (
                r#"{"kind":"finish"}"#,
                "continuity agent returned an invalid broker request",
            ),
            (
                r#"{"kind":"broker_call","capability":"Bad"}"#,
                "continuity agent returned an invalid capability",
            ),
        ] {
            assert_eq!(parse_decision_dict(raw).unwrap_err().message, message);
        }
    }

    #[test]
    fn config_bounds() {
        assert!(
            ContinuityAgentConfig {
                max_attempts: 0,
                ..Default::default()
            }
            .validated()
            .is_err()
        );
        let mut table = Dict::new();
        table.insert("max_attempts", 0);
        table.insert("wall_clock_seconds", "0.5");
        let config = ContinuityAgentConfig::from_app_config(&table).unwrap();
        assert_eq!((config.max_attempts, config.wall_clock_seconds), (1, 1.0));
    }
}
