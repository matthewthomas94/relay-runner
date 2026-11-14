//! The daemon's `ContinuityLifecycleAdapter` (`services/orchestrator.py`):
//! allowlisted live Relay events, as `/v1/continuity/observation` and the
//! daemon's own command lifecycle report them, translated into the incident
//! detector; plus the live watches the recovery owners inspect, and the
//! `continuity_resume` handoff to the canonical bridge.
//!
//! [`ContinuityLifecycleAdapter::observe`] answers the route with
//! [`Classification::as_dict`]; an unsupported or malformed event is a
//! `ValueError` with the daemon's message (`unsupported continuity lifecycle
//! event`, `continuity event requires session_id`, ...).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::os::unix::net::UnixDatagram;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use relay_intents::json::{self, py_strip};
use relay_store::continuity::ContinuityReportStore;

use super::agent::RecoveryHealthEvidence;
use super::incidents::{
    Classification, ContinuityIncidentDetector, DetectorConfig, Emit, Observation,
    provider_observation,
};
use super::recovery::{RecoveryActionRequest, RecoveryActionValidation};
use super::{Clock, normalize_recovery_generation, opaque_identifier, wall_clock};
use crate::{Dict, Error, Result, Value};

/// A `(source, event)` pair.
type EventName = (&'static str, &'static str);
/// `(component, phase, health, failed native recovery)`.
type EventMeaning = (&'static str, &'static str, &'static str, bool);
/// `(session, command, generation)`.
type EvidenceKey = (String, Option<String>, String);

/// `_CONTINUITY_LIFECYCLE_EVENTS`.
const LIFECYCLE_EVENTS: [(EventName, EventMeaning); 20] = [
    (
        ("stt", "capture_started"),
        ("speech_capture", "capture", "healthy", false),
    ),
    (
        ("stt", "capture_failed"),
        ("speech_capture", "capture", "unavailable", false),
    ),
    (
        ("stt", "transcription_started"),
        ("transcription", "transcription", "healthy", false),
    ),
    (
        ("stt", "transcription_failed"),
        ("transcription", "transcription", "unavailable", false),
    ),
    (
        ("bridge", "command_received"),
        ("command", "command_processing", "healthy", false),
    ),
    (
        ("bridge", "command_delivered"),
        ("bridge", "delivery", "healthy", false),
    ),
    (
        ("bridge", "delivery_failed"),
        ("bridge", "delivery", "unavailable", false),
    ),
    (
        ("messenger", "progress"),
        ("messenger", "component_liveness", "healthy", false),
    ),
    (
        ("messenger", "failed"),
        ("messenger", "component_liveness", "recovery_failed", true),
    ),
    (
        ("daemon", "heartbeat"),
        ("daemon", "component_liveness", "healthy", false),
    ),
    (
        ("daemon", "heartbeat_missed"),
        ("daemon", "component_liveness", "unavailable", false),
    ),
    (
        ("command", "accepted"),
        ("command", "command_processing", "healthy", false),
    ),
    (
        ("command", "planning"),
        ("command", "command_processing", "healthy", false),
    ),
    (
        ("command", "completed"),
        ("command", "command_processing", "completed", false),
    ),
    (
        ("command", "failed"),
        ("command", "command_processing", "recovery_failed", true),
    ),
    (
        ("session", "started"),
        ("session", "session_liveness", "healthy", false),
    ),
    (
        ("session", "process_exit"),
        ("session", "session_liveness", "unavailable", false),
    ),
    (
        ("session", "explicit_stop"),
        ("session", "session_liveness", "unavailable", false),
    ),
    (
        ("session", "update"),
        ("session", "session_liveness", "unavailable", false),
    ),
    (
        ("session", "reset"),
        ("session", "session_liveness", "unavailable", false),
    ),
];

/// `_CONTINUITY_DEADLINE_STARTS`.
const DEADLINE_STARTS: [(EventName, EventName); 2] = [
    (("stt", "capture_started"), ("speech_capture", "capture")),
    (
        ("stt", "transcription_started"),
        ("transcription", "transcription"),
    ),
];

/// `_CONTINUITY_PROGRESS_RESOLVES`.
const PROGRESS_RESOLVES: [(EventName, &[&str]); 2] = [
    (("stt", "transcription_started"), &["speech_capture"]),
    (
        ("bridge", "command_received"),
        &["speech_capture", "transcription"],
    ),
];

/// `_CONTINUITY_OBJECTIVE_EVIDENCE`.
const OBJECTIVE_EVIDENCE: [(EventName, &[&str]); 15] = [
    (("stt", "capture_started"), &["capture_progress_observed"]),
    (
        ("stt", "transcription_started"),
        &["capture_progress_observed", "transcription_started"],
    ),
    (
        ("bridge", "command_received"),
        &[
            "transcription_completed",
            "command_created",
            "bridge_process_alive",
        ],
    ),
    (
        ("bridge", "command_delivered"),
        &[
            "bridge_process_alive",
            "bridge_heartbeat_fresh",
            "command_delivered",
        ],
    ),
    (
        ("messenger", "progress"),
        &["messenger_process_alive", "messenger_progress_observed"],
    ),
    (
        ("daemon", "heartbeat"),
        &[
            "daemon_process_alive",
            "daemon_heartbeat_fresh",
            "orchestrator_heartbeat_fresh",
        ],
    ),
    (("command", "accepted"), &["command_progress_observed"]),
    (("command", "planning"), &["command_progress_observed"]),
    (
        ("command", "completed"),
        &["command_progress_observed", "command_completed"],
    ),
    (
        ("session", "started"),
        &["session_owner_alive", "session_heartbeat_fresh"],
    ),
    (
        ("provider", "process_ready"),
        &["provider_process_alive", "provider_processing_ready"],
    ),
    (("provider", "turn_started"), &["provider_process_alive"]),
    (("provider", "stream_started"), &["provider_process_alive"]),
    (
        ("provider", "turn_progress"),
        &[
            "provider_process_alive",
            "provider_processing_ready",
            "provider_progress_observed",
        ],
    ),
    (
        ("provider", "stream_progress"),
        &[
            "provider_process_alive",
            "provider_processing_ready",
            "provider_progress_observed",
        ],
    ),
];

/// The most `(session, command, generation)` evidence entries kept.
const EVIDENCE_LIMIT: usize = 512;

fn lookup<'t, T>(table: &'t [(EventName, T)], source: &str, name: &str) -> Option<&'t T> {
    table
        .iter()
        .find(|((s, n), _)| *s == source && *n == name)
        .map(|(_, value)| value)
}

/// `OrchestratorSessionStore._normalize_provider`.
pub fn normalize_provider(provider_key: &str) -> &'static str {
    let provider = py_strip(provider_key).to_lowercase();
    if provider.contains("claude") {
        "claude"
    } else {
        "codex"
    }
}

/// `(session, command, component, provider, generation, phase)`.
type WatchKey = (String, Option<String>, String, String, String, String);

fn watch_key(observation: &Observation) -> WatchKey {
    (
        observation.session_id.clone(),
        observation.command_id.clone(),
        observation.component.clone(),
        observation.provider.clone(),
        observation.recovery_generation.clone(),
        observation.phase.clone(),
    )
}

/// A `dict` keyed by watch: insertion-ordered, an update keeps its place.
#[derive(Default)]
struct Watches(Vec<(WatchKey, Observation)>);

impl Watches {
    fn insert(&mut self, key: WatchKey, observation: Observation) {
        match self.0.iter_mut().find(|(existing, _)| *existing == key) {
            Some(entry) => entry.1 = observation,
            None => self.0.push((key, observation)),
        }
    }

    fn remove(&mut self, key: &WatchKey) {
        self.0.retain(|(existing, _)| existing != key);
    }

    /// Removes and returns every entry `matches` selects, in order.
    fn take(&mut self, matches: impl Fn(&Observation) -> bool) -> Vec<(WatchKey, Observation)> {
        let (taken, kept) = std::mem::take(&mut self.0)
            .into_iter()
            .partition(|(_, observation)| matches(observation));
        self.0 = kept;
        taken
    }
}

struct AdapterState {
    detector: ContinuityIncidentDetector,
    watches: Watches,
    active_incidents: Watches,
    active_identity: HashMap<WatchKey, (String, String)>,
    suppressed_sessions: HashMap<String, String>,
    /// `(session, command, generation)` to each evidence code's time, in
    /// insertion order.
    objective_evidence: Vec<(EvidenceKey, BTreeMap<String, f64>)>,
    confirmed_dead: HashSet<WatchKey>,
}

/// `ContinuityLifecycleAdapter`.
pub struct ContinuityLifecycleAdapter {
    state: Mutex<AdapterState>,
    clock: Clock,
}

impl ContinuityLifecycleAdapter {
    /// An adapter whose detector emits each incident envelope to `emit`.
    pub fn new(emit: Option<Emit>) -> Self {
        Self::with_detector(
            ContinuityIncidentDetector::new(DetectorConfig::default(), emit),
            None,
        )
    }

    /// An adapter over a configured detector; `clock` is `time.time` unless
    /// given.
    pub fn with_detector(detector: ContinuityIncidentDetector, clock: Option<Clock>) -> Self {
        Self {
            state: Mutex::new(AdapterState {
                detector,
                watches: Watches::default(),
                active_incidents: Watches::default(),
                active_identity: HashMap::new(),
                suppressed_sessions: HashMap::new(),
                objective_evidence: Vec::new(),
                confirmed_dead: HashSet::new(),
            }),
            clock: clock.unwrap_or_else(|| Arc::new(wall_clock)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, AdapterState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// `observe(event)`.
    pub fn observe(&self, event: &Dict) -> Result<Classification> {
        let lower = |key: &str| py_strip(&event.string(key)).to_lowercase();
        let source = lower("source");
        let name = lower("event");
        let native_session_id = first_text(event, "app_session_id", "session_id");
        if native_session_id.is_empty() {
            return Err(Error::value("continuity event requires session_id"));
        }
        let native_command_id = first_text(event, "relay_command_id", "command_id");
        let timing_error = || Error::value("invalid continuity timing or generation");
        let default_generation = Value::from("0");
        let generation = normalize_recovery_generation(Some(
            event
                .get("recovery_generation")
                .unwrap_or(&default_generation),
        ))
        .map_err(|_| timing_error())?;
        let observed_at = match event.truthy("observed_at") {
            Some(value) => value.py_float().ok_or_else(timing_error)?,
            None => (self.clock)(),
        };
        let provider = normalize_provider(
            &event
                .truthy("provider")
                .map_or_else(|| "codex".to_string(), Value::py_str),
        );
        let session_id = opaque_identifier("session", &native_session_id)?;
        let command_id = if native_command_id.is_empty() {
            None
        } else {
            Some(opaque_identifier("command", &native_command_id)?)
        };

        let observation = if source == "provider" {
            provider_observation(
                provider,
                &name,
                &session_id,
                command_id.as_deref(),
                &generation,
                observed_at,
            )?
        } else {
            let (component, phase, health, failed) = lookup(&LIFECYCLE_EVENTS, &source, &name)
                .ok_or_else(|| Error::value("unsupported continuity lifecycle event"))?;
            Observation {
                session_id: session_id.clone(),
                command_id: command_id.clone(),
                component: component.to_string(),
                provider: if ["messenger", "session", "command"].contains(component) {
                    provider.to_string()
                } else {
                    "none".to_string()
                },
                recovery_generation: generation.clone(),
                phase: phase.to_string(),
                health: health.to_string(),
                observed_at,
                native_recovery_failed: *failed,
            }
            .validated()?
        };

        let suppression = (source == "session"
            && ["explicit_stop", "update", "reset"].contains(&name.as_str()))
        .then(|| name.clone());
        let mut state = self.lock();
        if (source == "provider" || source == "session") && name == "process_exit" {
            state.confirmed_dead.insert(watch_key(&observation));
        }
        if let Some(codes) = lookup(&OBJECTIVE_EVIDENCE, &source, &name) {
            let evidence_key = (session_id.clone(), command_id.clone(), generation.clone());
            let position = match state
                .objective_evidence
                .iter()
                .position(|(key, _)| *key == evidence_key)
            {
                Some(position) => position,
                None => {
                    state
                        .objective_evidence
                        .push((evidence_key, BTreeMap::new()));
                    state.objective_evidence.len() - 1
                }
            };
            for code in *codes {
                state.objective_evidence[position]
                    .1
                    .insert(code.to_string(), observed_at);
            }
            if state.objective_evidence.len() > EVIDENCE_LIMIT {
                let newest = |entry: &BTreeMap<String, f64>| {
                    entry.values().copied().fold(f64::NEG_INFINITY, f64::max)
                };
                let mut oldest = 0;
                for (index, (_, entry)) in state.objective_evidence.iter().enumerate() {
                    if newest(entry) < newest(&state.objective_evidence[oldest].1) {
                        oldest = index;
                    }
                }
                state.objective_evidence.remove(oldest);
            }
        }
        if let Some(reason) = &suppression {
            state
                .suppressed_sessions
                .insert(session_id.clone(), reason.clone());
            state.detector.suppress_session(&session_id)?;
            state
                .watches
                .take(|watched| watched.session_id == session_id);
            for (key, _) in state
                .active_incidents
                .take(|active| active.session_id == session_id)
            {
                state.active_identity.remove(&key);
            }
            return state.detector.observe(&observation, Some(reason));
        }
        if let Some(suppressed) = state.suppressed_sessions.get(&session_id).cloned() {
            if source != "session" || name != "started" {
                return state.detector.observe(&observation, Some(&suppressed));
            }
            state.suppressed_sessions.remove(&session_id);
        }

        if observation.health == "healthy" || observation.health == "completed" {
            state.confirmed_dead.remove(&watch_key(&observation));
            clear_recovered_watches(&mut state, &observation);
        }
        if let Some(components) = lookup(&PROGRESS_RESOLVES, &source, &name) {
            clear_component_watches(&mut state, &observation, components);
        }
        let result = state.detector.observe(&observation, None)?;

        if observation.health == "unavailable" || observation.health == "recovery_failed" {
            record_watch(&mut state, observation.clone(), &result);
        } else {
            let mut deadline = lookup(&DEADLINE_STARTS, &source, &name).copied();
            if source == "provider"
                && [
                    "turn_started",
                    "stream_started",
                    "turn_progress",
                    "stream_progress",
                ]
                .contains(&name.as_str())
            {
                deadline = Some(("foreground_provider", "provider_turn"));
            }
            let pending = if let Some((component, phase)) = deadline {
                Some(Observation {
                    session_id: session_id.clone(),
                    command_id: command_id.clone(),
                    component: component.to_string(),
                    provider: if component == "foreground_provider" {
                        provider.to_string()
                    } else {
                        "none".to_string()
                    },
                    recovery_generation: generation.clone(),
                    phase: phase.to_string(),
                    health: "unavailable".to_string(),
                    observed_at,
                    native_recovery_failed: false,
                })
            } else if source == "command" && (name == "accepted" || name == "planning") {
                Some(Observation {
                    session_id: session_id.clone(),
                    command_id: command_id.clone(),
                    component: "command".to_string(),
                    provider: provider.to_string(),
                    recovery_generation: generation.clone(),
                    phase: "command_processing".to_string(),
                    health: "unavailable".to_string(),
                    observed_at,
                    native_recovery_failed: false,
                })
            } else {
                None
            };
            if let Some(pending) = pending {
                let pending = pending.validated()?;
                let watched = state.detector.observe(&pending, None)?;
                record_watch(&mut state, pending, &watched);
            }
        }
        Ok(result)
    }

    /// `sample(observed_at=...)`: re-observes unresolved failures so one-shot
    /// native events can qualify.
    pub fn sample(&self, observed_at: Option<f64>) -> Result<Vec<Classification>> {
        let now = observed_at.unwrap_or_else(|| (self.clock)());
        let mut state = self.lock();
        let mut results = Vec::new();
        let watches: Vec<(WatchKey, Observation)> = state.watches.0.clone();
        for (key, watched) in watches {
            if state.suppressed_sessions.contains_key(&watched.session_id) {
                state.watches.remove(&key);
                continue;
            }
            let sample = watched.at(now)?;
            let result = state.detector.observe(&sample, None)?;
            if result.state != "transient" {
                state.watches.remove(&key);
                if let Some(envelope) = &result.envelope {
                    state.active_incidents.insert(key.clone(), watched.clone());
                    state.active_identity.insert(
                        key,
                        (
                            envelope.incident_id.clone(),
                            envelope.classification.clone(),
                        ),
                    );
                }
            }
            results.push(result);
        }
        Ok(results)
    }

    /// `recovery_health(request)`: only fresh, objective lifecycle evidence
    /// for one request.
    pub fn recovery_health(&self, request: &RecoveryActionRequest) -> RecoveryHealthEvidence {
        let mut evidence: BTreeMap<String, f64> = BTreeMap::new();
        {
            let state = self.lock();
            for ((session_id, command_id, generation), observed) in &state.objective_evidence {
                if *session_id == request.session_id
                    && *generation == request.recovery_generation
                    && (command_id.is_none() || *command_id == request.command_id)
                {
                    for (code, observed_at) in observed {
                        if *observed_at >= request.incident_observed_at {
                            let entry = evidence.entry(code.clone()).or_insert(0.0);
                            *entry = entry.max(*observed_at);
                        }
                    }
                }
            }
        }
        if evidence.is_empty() {
            return RecoveryHealthEvidence::default();
        }
        let latest = evidence.values().copied().fold(f64::NEG_INFINITY, f64::max);
        RecoveryHealthEvidence {
            objective_restored: true,
            stable_for_seconds: ((self.clock)() - latest).max(0.0),
            evidence_codes: evidence.into_keys().collect(),
        }
    }

    /// `recovery_validation(request)`: inspects the exact active detector
    /// watch; never infers a live owner.
    pub fn recovery_validation(&self, request: &RecoveryActionRequest) -> RecoveryActionValidation {
        let mut watched: Option<Observation> = None;
        let mut confirmed_dead = false;
        let mut classified_stall = false;
        {
            let state = self.lock();
            let observations = state
                .watches
                .0
                .iter()
                .chain(state.active_incidents.0.iter())
                .map(|(_, observation)| observation);
            for observation in observations {
                if observation.session_id == request.session_id
                    && observation.command_id == request.command_id
                    && observation.component == request.component
                    && observation.provider == request.provider
                    && observation.phase == request.incident_phase
                {
                    let key = watch_key(observation);
                    let identity = state.active_identity.get(&key);
                    if identity.is_some_and(|(incident, _)| *incident != request.incident_id) {
                        continue;
                    }
                    watched = Some(observation.clone());
                    confirmed_dead =
                        state.confirmed_dead.contains(&key) || observation.native_recovery_failed;
                    classified_stall = identity.is_some_and(|(_, classification)| {
                        classification == "stalled" || classification == "recurring"
                    });
                    break;
                }
            }
        }
        let command_phase = match request.incident_phase.as_str() {
            "capture" => "before_command",
            "transcription" => "captured",
            "delivery" => "undelivered",
            "component_liveness" | "session_liveness" => "none",
            "provider_turn" | "command_processing" => "in_flight",
            _ => "ambiguous",
        };
        let generation_matches = watched
            .as_ref()
            .is_some_and(|watched| watched.recovery_generation == request.recovery_generation);
        let liveness = match &watched {
            None => "unknown",
            Some(_) if confirmed_dead => "confirmed_dead",
            Some(_) if classified_stall => "stalled",
            Some(_) => "unhealthy",
        };
        RecoveryActionValidation {
            validation_token: "live_continuity_watch".to_string(),
            exact_target_owned: watched.is_some(),
            liveness: liveness.to_string(),
            incident_active: watched.is_some(),
            generation_matches,
            command_phase: command_phase.to_string(),
            command_phase_matches: command_phase != "ambiguous",
            idempotency_state: "new".to_string(),
            compensation_available: false,
            cooldown_remaining: 0.0,
            expected_postcondition: request.expected_postcondition.clone(),
            health: self.recovery_health(request),
        }
    }
}

/// `str(event.get(a) or event.get(b) or "").strip()`.
fn first_text(event: &Dict, first: &str, second: &str) -> String {
    let value = event.truthy(first).or_else(|| event.truthy(second));
    value.map_or_else(String::new, |value| py_strip(&value.py_str()).to_string())
}

/// A failure observation stays watched while transient, and becomes an
/// active incident once the detector emitted one.
fn record_watch(state: &mut AdapterState, observation: Observation, result: &Classification) {
    let key = watch_key(&observation);
    if result.state == "transient" {
        state.watches.insert(key, observation);
        return;
    }
    state.watches.remove(&key);
    if let Some(envelope) = &result.envelope {
        state.active_incidents.insert(key.clone(), observation);
        state.active_identity.insert(
            key,
            (
                envelope.incident_id.clone(),
                envelope.classification.clone(),
            ),
        );
    }
}

/// `_clear_recovered_watches(observation)`.
fn clear_recovered_watches(state: &mut AdapterState, observation: &Observation) {
    let matches = |watched: &Observation| {
        watched.session_id == observation.session_id
            && watched.component == observation.component
            && watched.provider == observation.provider
            && watched.recovery_generation == observation.recovery_generation
            && (watched.command_id == observation.command_id || watched.command_id.is_none())
    };
    state.watches.take(matches);
    for (key, _) in state.active_incidents.take(matches) {
        state.active_identity.remove(&key);
    }
    state.detector.resolve_related(observation);
}

/// `_clear_component_watches(observation, components)`.
fn clear_component_watches(
    state: &mut AdapterState,
    observation: &Observation,
    components: &[&str],
) {
    let components: BTreeSet<&str> = components.iter().copied().collect();
    let matches = |watched: &Observation| {
        watched.session_id == observation.session_id
            && components.contains(watched.component.as_str())
            && watched.recovery_generation == observation.recovery_generation
            && (watched.command_id.is_none() || watched.command_id == observation.command_id)
    };
    for (_, watched) in state.watches.take(matches) {
        state.detector.resolve_related(&watched);
    }
    for (key, watched) in state.active_incidents.take(matches) {
        state.active_identity.remove(&key);
        state.detector.resolve_related(&watched);
    }
}

/// The `continuity_resume` datagram `_publish_continuity_resume` sends the
/// canonical bridge.
pub fn continuity_resume_payload(incident: &Dict, final_result: &str) -> Dict {
    let field = |key: &str| incident.get(key).cloned().unwrap_or(Value::Null);
    let unavailable = incident
        .get("recovery_objective")
        .and_then(Value::as_dict)
        .map_or(Value::Null, |objective| {
            objective
                .get("unavailable_capability")
                .cloned()
                .unwrap_or(Value::Null)
        });
    let observed_at = incident
        .truthy("timing")
        .and_then(Value::as_dict)
        .and_then(|timing| timing.get("last_observed_at").cloned())
        .unwrap_or(Value::Null);
    let mut payload = Dict::new();
    payload.insert("type", "continuity_resume");
    payload.insert("final_result", final_result);
    payload.insert("incident_id", field("incident_id"));
    payload.insert("session_id", field("session_id"));
    payload.insert("command_id", field("command_id"));
    payload.insert("component", field("component"));
    payload.insert("phase", field("phase"));
    payload.insert("unavailable_capability", unavailable);
    payload.insert("provider", field("provider"));
    payload.insert("recovery_generation", field("recovery_generation"));
    payload.insert("incident_observed_at", observed_at);
    payload
}

/// `_publish_continuity_resume(incident, final_result)`: an unresolved
/// result is recorded as a report first (a failure is only logged), then
/// authority returns to the canonical bridge over its control socket. A
/// missing bridge means no safe command or speech owner; nothing is sent.
pub fn publish_continuity_resume(
    reports: Option<&ContinuityReportStore>,
    bridge_control_socket: &Path,
    incident: &Dict,
    final_result: &str,
) {
    if final_result != "restored"
        && let Some(reports) = reports
        && let Err(error) = super::reports::record_unresolved(
            reports,
            &Value::Dict(incident.clone()),
            final_result,
            None,
        )
    {
        eprintln!("[orchestrator] could not record continuity report: {error}");
    }
    let payload = continuity_resume_payload(incident, final_result);
    let line = json::dumps_compact(&Value::Dict(payload));
    if let Ok(socket) = UnixDatagram::unbound() {
        let _ = socket.send_to(line.as_bytes(), bridge_control_socket);
    }
}
