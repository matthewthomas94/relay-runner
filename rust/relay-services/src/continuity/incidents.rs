//! `services/continuity_incidents.py`: privacy-safe voice continuity incident
//! classification.
//!
//! Component owners translate their native liveness into [`Observation`]s.
//! This module has no access to transcripts, prompts, repositories, provider
//! output or process arguments; it decides when bounded evidence is strong
//! enough for a separate recovery owner to act.
//!
//! Observation times are `f64`, as the daemon always passes `float(...)`; an
//! incident identity therefore hashes Python's `repr` of a float.

use std::collections::{HashMap, HashSet};

use relay_intents::json::{self, float_repr};
use relay_intents::sha256::hex_digest;

use super::{generation, is_prefixed_hex};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA_VERSION: i64 = 1;
pub const COMPONENTS: [&str; 9] = [
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
pub const PHASES: [&str; 7] = [
    "capture",
    "transcription",
    "delivery",
    "component_liveness",
    "provider_turn",
    "command_processing",
    "session_liveness",
];
pub const HEALTH_VALUES: [&str; 5] = [
    "healthy",
    "degraded",
    "unavailable",
    "recovery_failed",
    "completed",
];
pub const PROVIDERS: [&str; 3] = ["codex", "claude", "none"];
pub const SUPPRESSION_REASONS: [&str; 3] = ["explicit_stop", "update", "reset"];

const CODEX_SIGNALS: [(&str, &str); 7] = [
    ("process_ready", "healthy"),
    ("turn_started", "healthy"),
    ("turn_progress", "healthy"),
    ("turn_completed", "completed"),
    ("turn_failed", "unavailable"),
    ("app_server_timeout", "unavailable"),
    ("process_exit", "unavailable"),
];
const CLAUDE_SIGNALS: [(&str, &str); 7] = [
    ("process_ready", "healthy"),
    ("stream_started", "healthy"),
    ("stream_progress", "healthy"),
    ("result_success", "completed"),
    ("result_error", "unavailable"),
    ("timeout", "unavailable"),
    ("process_exit", "unavailable"),
];

/// `_OBJECTIVES`: what each component's loss means and the evidence that
/// proves it restored.
pub const OBJECTIVES: [(&str, &str, &[&str]); 9] = [
    (
        "speech_capture",
        "Relay Runner cannot capture speech for the active voice session.",
        &["capture_progress_observed", "transcription_started"],
    ),
    (
        "transcription",
        "Relay Runner cannot turn captured speech into a command.",
        &["transcription_completed", "command_created"],
    ),
    (
        "bridge",
        "Relay Runner cannot deliver captured input to the active session.",
        &[
            "bridge_process_alive",
            "bridge_heartbeat_fresh",
            "command_delivered",
        ],
    ),
    (
        "messenger",
        "Relay Runner cannot provide voice-session conversation updates.",
        &["messenger_process_alive", "messenger_progress_observed"],
    ),
    (
        "foreground_provider",
        "Relay Runner cannot continue foreground project processing.",
        &["provider_process_alive", "provider_processing_ready"],
    ),
    (
        "orchestrator",
        "Relay Runner cannot plan or route accepted project work.",
        &["orchestrator_heartbeat_fresh", "command_progress_observed"],
    ),
    (
        "daemon",
        "Relay Runner cannot continue daemon-owned project work.",
        &["daemon_process_alive", "daemon_heartbeat_fresh"],
    ),
    (
        "session",
        "Relay Runner cannot continue the active voice session.",
        &["session_owner_alive", "session_heartbeat_fresh"],
    ),
    (
        "command",
        "Relay Runner cannot advance an accepted voice command.",
        &["command_progress_observed", "command_completed"],
    ),
];

/// The objective of a supported component.
pub fn objective(component: &str) -> Option<RecoveryObjective> {
    OBJECTIVES
        .iter()
        .find(|(name, _, _)| *name == component)
        .map(|(_, capability, restored)| RecoveryObjective {
            unavailable_capability: capability.to_string(),
            restored_when: restored.iter().map(|code| code.to_string()).collect(),
        })
}

/// `_validate_opaque(value, kind)`.
fn validate_opaque(value: Option<&str>, kind: &str) -> Result<()> {
    let Some(text) = value else {
        if kind == "command" {
            return Ok(());
        }
        return Err(Error::value(format!(
            "{kind}_id must be created with opaque_identifier"
        )));
    };
    let prefix = format!("{kind}-");
    let suffix: String = text.chars().skip(prefix.chars().count()).collect();
    if !text.starts_with(&prefix) || suffix.chars().count() != 24 {
        return Err(Error::value(format!(
            "{kind}_id must be created with opaque_identifier"
        )));
    }
    if !is_prefixed_hex(text, &prefix, 24) {
        return Err(Error::value(format!("invalid opaque {kind}_id")));
    }
    Ok(())
}

/// `Observation`: one bounded liveness sample in the shared contract.
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub session_id: String,
    pub command_id: Option<String>,
    pub component: String,
    pub provider: String,
    pub recovery_generation: String,
    pub phase: String,
    pub health: String,
    pub observed_at: f64,
    pub native_recovery_failed: bool,
}

impl Observation {
    /// `Observation.__post_init__`: validates the fields and normalises the
    /// recovery generation.
    pub fn validated(mut self) -> Result<Self> {
        validate_opaque(Some(&self.session_id), "session")?;
        validate_opaque(self.command_id.as_deref(), "command")?;
        if !COMPONENTS.contains(&self.component.as_str()) {
            return Err(Error::value(format!(
                "unsupported component: {}",
                self.component
            )));
        }
        if !PROVIDERS.contains(&self.provider.as_str()) {
            return Err(Error::value(format!(
                "unsupported provider: {}",
                self.provider
            )));
        }
        if !PHASES.contains(&self.phase.as_str()) {
            return Err(Error::value(format!("unsupported phase: {}", self.phase)));
        }
        if !HEALTH_VALUES.contains(&self.health.as_str()) {
            return Err(Error::value(format!("unsupported health: {}", self.health)));
        }
        self.recovery_generation = generation(&self.recovery_generation)?;
        if !self.observed_at.is_finite() {
            return Err(Error::value("observed_at must be finite"));
        }
        Ok(self)
    }

    /// The same observation at another time (`_at` in the daemon adapter).
    pub fn at(&self, observed_at: f64) -> Result<Self> {
        Self {
            observed_at,
            ..self.clone()
        }
        .validated()
    }
}

/// `provider_observation(provider, signal, ...)`: only allowlisted provider
/// signals become foreground-provider observations.
pub fn provider_observation(
    provider: &str,
    signal: &str,
    session_id: &str,
    command_id: Option<&str>,
    recovery_generation: &str,
    observed_at: f64,
) -> Result<Observation> {
    let signals: &[(&str, &str)] = match provider {
        "codex" => &CODEX_SIGNALS,
        "claude" => &CLAUDE_SIGNALS,
        _ => &[],
    };
    let health = signals
        .iter()
        .find(|(name, _)| *name == signal)
        .map(|(_, health)| *health)
        .ok_or_else(|| Error::value("unsupported provider signal"))?;
    Observation {
        session_id: session_id.to_string(),
        command_id: command_id.map(str::to_string),
        component: "foreground_provider".to_string(),
        provider: provider.to_string(),
        recovery_generation: recovery_generation.to_string(),
        phase: "provider_turn".to_string(),
        health: health.to_string(),
        observed_at,
        native_recovery_failed: false,
    }
    .validated()
}

/// `DetectorConfig`.
#[derive(Clone, Debug, PartialEq)]
pub struct DetectorConfig {
    pub grace_periods: Vec<(String, f64)>,
    pub post_grace_samples: i64,
    pub recurrence_count: usize,
    pub recurrence_window: f64,
    pub failed_recovery_count: usize,
    pub failed_recovery_window: f64,
    pub cooldown: f64,
}

impl Default for DetectorConfig {
    fn default() -> Self {
        let grace = [
            ("speech_capture", 5.0),
            ("transcription", 10.0),
            ("bridge", 15.0),
            ("messenger", 15.0),
            ("foreground_provider", 30.0),
            ("orchestrator", 30.0),
            ("daemon", 30.0),
            ("session", 30.0),
            ("command", 30.0),
        ];
        Self {
            grace_periods: grace
                .iter()
                .map(|(name, seconds)| (name.to_string(), *seconds))
                .collect(),
            post_grace_samples: 2,
            recurrence_count: 3,
            recurrence_window: 30.0 * 60.0,
            failed_recovery_count: 2,
            failed_recovery_window: 10.0 * 60.0,
            cooldown: 15.0 * 60.0,
        }
    }
}

impl DetectorConfig {
    /// `DetectorConfig.__post_init__`.
    pub fn validated(self) -> Result<Self> {
        let named: HashSet<&str> = self.grace_periods.iter().map(|(n, _)| n.as_str()).collect();
        let expected: HashSet<&str> = COMPONENTS.into_iter().collect();
        if named != expected {
            return Err(Error::value(
                "grace_periods must name every supported component",
            ));
        }
        if self
            .grace_periods
            .iter()
            .any(|(_, value)| !value.is_finite() || *value < 0.0)
        {
            return Err(Error::value(
                "grace periods must be finite and non-negative",
            ));
        }
        if self.post_grace_samples < 2 {
            return Err(Error::value(
                "at least two post-grace liveness samples are required",
            ));
        }
        Ok(self)
    }

    fn grace(&self, component: &str) -> f64 {
        self.grace_periods
            .iter()
            .find(|(name, _)| name == component)
            .map_or(0.0, |(_, seconds)| *seconds)
    }
}

/// `RecoveryObjective`.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryObjective {
    pub unavailable_capability: String,
    pub restored_when: Vec<String>,
}

impl RecoveryObjective {
    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert(
            "unavailable_capability",
            self.unavailable_capability.as_str(),
        );
        value.insert(
            "restored_when",
            Value::List(
                self.restored_when
                    .iter()
                    .map(|code| Value::from(code.as_str()))
                    .collect(),
            ),
        );
        value
    }
}

/// `IncidentEnvelope`: the fixed, privacy-safe incident the detector emits.
#[derive(Clone, Debug, PartialEq)]
pub struct IncidentEnvelope {
    pub incident_id: String,
    pub fingerprint: String,
    pub classification: String,
    pub session_id: String,
    pub command_id: Option<String>,
    pub component: String,
    pub provider: String,
    pub recovery_generation: String,
    pub phase: String,
    pub health: String,
    pub first_observed_at: f64,
    pub last_observed_at: f64,
    pub grace_deadline: f64,
    pub post_grace_samples: i64,
    pub failed_native_recovery: bool,
    pub cooldown_until: f64,
    pub objective: RecoveryObjective,
}

impl IncidentEnvelope {
    pub fn as_dict(&self) -> Dict {
        let mut timing = Dict::new();
        timing.insert("first_observed_at", self.first_observed_at);
        timing.insert("last_observed_at", self.last_observed_at);
        timing.insert("grace_deadline", self.grace_deadline);
        timing.insert("post_grace_samples", self.post_grace_samples);
        timing.insert("failed_native_recovery", self.failed_native_recovery);
        timing.insert("cooldown_until", self.cooldown_until);
        let mut value = Dict::new();
        value.insert("schema_version", SCHEMA_VERSION);
        value.insert("incident_id", self.incident_id.as_str());
        value.insert("fingerprint", self.fingerprint.as_str());
        value.insert("classification", self.classification.as_str());
        value.insert("session_id", self.session_id.as_str());
        value.insert("command_id", self.command_id.as_deref());
        value.insert("component", self.component.as_str());
        value.insert("provider", self.provider.as_str());
        value.insert("recovery_generation", self.recovery_generation.as_str());
        value.insert("phase", self.phase.as_str());
        value.insert("health", self.health.as_str());
        value.insert("timing", timing);
        value.insert("recovery_objective", self.objective.as_dict());
        value
    }
}

/// `Classification`: the detector's verdict on one observation.
#[derive(Clone, Debug, PartialEq)]
pub struct Classification {
    pub state: String,
    pub fingerprint: Option<String>,
    pub envelope: Option<IncidentEnvelope>,
    pub suppression_reason: Option<String>,
}

impl Classification {
    fn new(state: &str, fingerprint: &str) -> Self {
        Self {
            state: state.to_string(),
            fingerprint: Some(fingerprint.to_string()),
            envelope: None,
            suppression_reason: None,
        }
    }

    fn suppressed(state: &str, fingerprint: &str, reason: &str) -> Self {
        Self {
            suppression_reason: Some(reason.to_string()),
            ..Self::new(state, fingerprint)
        }
    }

    /// The daemon's `observe_continuity_event` answer: state, fingerprint,
    /// suppression reason and the incident envelope, if one was emitted.
    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("state", self.state.as_str());
        value.insert("fingerprint", self.fingerprint.as_deref());
        value.insert("suppression_reason", self.suppression_reason.as_deref());
        value.insert(
            "incident",
            self.envelope
                .as_ref()
                .map_or(Value::Null, |envelope| Value::Dict(envelope.as_dict())),
        );
        value
    }
}

#[derive(Clone, Debug)]
struct Episode {
    first_observed_at: f64,
    last_observed_at: f64,
    last_post_grace_sample_at: Option<f64>,
    post_grace_samples: i64,
    failed_native_recovery: bool,
    classification: Option<String>,
}

#[derive(Clone, Debug)]
struct Occurrence {
    observed_at: f64,
    session_id: String,
    failed_native_recovery: bool,
}

/// The callback that receives each emitted envelope.
pub type Emit = Box<dyn Fn(&Dict) + Send + Sync>;

type EpisodeKey = (String, String, Option<String>, String);

/// `ContinuityIncidentDetector`: classifies bounded liveness observations
/// without initiating recovery.
pub struct ContinuityIncidentDetector {
    pub config: DetectorConfig,
    emit: Option<Emit>,
    episodes: HashMap<EpisodeKey, Episode>,
    history: HashMap<String, Vec<Occurrence>>,
    cooldown_until: HashMap<String, f64>,
    completed_commands: HashSet<String>,
}

impl ContinuityIncidentDetector {
    pub fn new(config: DetectorConfig, emit: Option<Emit>) -> Self {
        Self {
            config,
            emit,
            episodes: HashMap::new(),
            history: HashMap::new(),
            cooldown_until: HashMap::new(),
            completed_commands: HashSet::new(),
        }
    }

    /// Discards unresolved evidence when the owning session is intentionally
    /// stopped.
    pub fn suppress_session(&mut self, session_id: &str) -> Result<()> {
        validate_opaque(Some(session_id), "session")?;
        self.episodes.retain(|key, _| key.1 != session_id);
        Ok(())
    }

    /// Clears component evidence resolved by a matching healthy observation.
    pub fn resolve_related(&mut self, observation: &Observation) {
        let fingerprint = Self::fingerprint(observation);
        self.episodes
            .retain(|(episode_fingerprint, session, command, generation), _| {
                !(*episode_fingerprint == fingerprint
                    && *session == observation.session_id
                    && *generation == observation.recovery_generation
                    && (*command == observation.command_id || command.is_none()))
            });
    }

    /// `fingerprint(observation)`: the component, provider and phase, hashed.
    pub fn fingerprint(observation: &Observation) -> String {
        let material = json::dumps_compact(&Value::List(vec![
            Value::Int(SCHEMA_VERSION),
            Value::from(observation.component.as_str()),
            Value::from(observation.provider.as_str()),
            Value::from(observation.phase.as_str()),
        ]));
        format!("fp-{}", &hex_digest(material.as_bytes())[..24])
    }

    pub fn observe(
        &mut self,
        observation: &Observation,
        suppression: Option<&str>,
    ) -> Result<Classification> {
        let fingerprint = Self::fingerprint(observation);
        let key: EpisodeKey = (
            fingerprint.clone(),
            observation.session_id.clone(),
            observation.command_id.clone(),
            observation.recovery_generation.clone(),
        );
        if let Some(reason) = suppression {
            if !SUPPRESSION_REASONS.contains(&reason) {
                return Err(Error::value("unsupported suppression reason"));
            }
            self.episodes.remove(&key);
            return Ok(Classification::suppressed(
                "suppressed",
                &fingerprint,
                reason,
            ));
        }
        if observation
            .command_id
            .as_ref()
            .is_some_and(|command| self.completed_commands.contains(command))
        {
            self.episodes.remove(&key);
            return Ok(Classification::suppressed(
                "suppressed",
                &fingerprint,
                "completed_work",
            ));
        }
        if observation.health == "healthy" || observation.health == "completed" {
            self.episodes.remove(&key);
            if observation.health == "completed"
                && let Some(command) = &observation.command_id
            {
                self.completed_commands.insert(command.clone());
            }
            return Ok(Classification::new(&observation.health, &fingerprint));
        }

        let grace = self.config.grace(&observation.component);
        let post_grace_required = self.config.post_grace_samples;
        if let Some(episode) = self.episodes.get(&key)
            && observation.observed_at < episode.last_observed_at
        {
            return Err(Error::value(
                "observations for an incident must be time ordered",
            ));
        }
        let episode = self.episodes.entry(key).or_insert(Episode {
            first_observed_at: observation.observed_at,
            last_observed_at: observation.observed_at,
            last_post_grace_sample_at: None,
            post_grace_samples: 0,
            failed_native_recovery: false,
            classification: None,
        });
        episode.last_observed_at = observation.observed_at;
        episode.failed_native_recovery = episode.failed_native_recovery
            || observation.native_recovery_failed
            || observation.health == "recovery_failed";

        let grace_deadline = episode.first_observed_at + grace;
        if observation.observed_at >= grace_deadline
            && episode
                .last_post_grace_sample_at
                .is_none_or(|last| observation.observed_at > last)
        {
            episode.post_grace_samples += 1;
            episode.last_post_grace_sample_at = Some(observation.observed_at);
        }
        let qualifies =
            episode.failed_native_recovery || episode.post_grace_samples >= post_grace_required;
        if !qualifies {
            return Ok(Classification::new("transient", &fingerprint));
        }
        if let Some(classification) = &episode.classification {
            return Ok(Classification::new(classification, &fingerprint));
        }
        let (first_observed_at, last_observed_at) =
            (episode.first_observed_at, episode.last_observed_at);
        let (post_grace_samples, failed_native_recovery) =
            (episode.post_grace_samples, episode.failed_native_recovery);

        let cutoff = observation.observed_at - self.config.recurrence_window;
        let mut history: Vec<Occurrence> = self
            .history
            .get(&fingerprint)
            .map(|items| {
                items
                    .iter()
                    .filter(|item| item.observed_at >= cutoff)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        history.push(Occurrence {
            observed_at: observation.observed_at,
            session_id: observation.session_id.clone(),
            failed_native_recovery,
        });
        let recurring = self.is_recurring(&history, observation.observed_at);
        self.history.insert(fingerprint.clone(), history);
        let classification = if recurring { "recurring" } else { "stalled" };
        if let Some(episode) = self.episodes.get_mut(&(
            fingerprint.clone(),
            observation.session_id.clone(),
            observation.command_id.clone(),
            observation.recovery_generation.clone(),
        )) {
            episode.classification = Some(classification.to_string());
        }

        let cooldown_until = self
            .cooldown_until
            .get(&fingerprint)
            .copied()
            .unwrap_or(0.0);
        if observation.observed_at < cooldown_until {
            return Ok(Classification::suppressed(
                classification,
                &fingerprint,
                "cooldown",
            ));
        }
        let cooldown_until = observation.observed_at + self.config.cooldown;
        self.cooldown_until
            .insert(fingerprint.clone(), cooldown_until);
        let objective = objective(&observation.component)
            .ok_or_else(|| Error::value("unsupported component"))?;
        let material = format!(
            "{fingerprint}:{}:{}:{}:{}",
            observation.session_id,
            observation.command_id.as_deref().unwrap_or("none"),
            float_repr(first_observed_at),
            observation.recovery_generation
        );
        let envelope = IncidentEnvelope {
            incident_id: format!("inc-{}", &hex_digest(material.as_bytes())[..12]),
            fingerprint: fingerprint.clone(),
            classification: classification.to_string(),
            session_id: observation.session_id.clone(),
            command_id: observation.command_id.clone(),
            component: observation.component.clone(),
            provider: observation.provider.clone(),
            recovery_generation: observation.recovery_generation.clone(),
            phase: observation.phase.clone(),
            health: observation.health.clone(),
            first_observed_at,
            last_observed_at,
            grace_deadline,
            post_grace_samples,
            failed_native_recovery,
            cooldown_until,
            objective,
        };
        if let Some(emit) = &self.emit {
            emit(&envelope.as_dict());
        }
        Ok(Classification {
            envelope: Some(envelope),
            ..Classification::new(classification, &fingerprint)
        })
    }

    fn is_recurring(&self, history: &[Occurrence], now: f64) -> bool {
        if history.len() >= self.config.recurrence_count {
            return true;
        }
        let recovery_cutoff = now - self.config.failed_recovery_window;
        let failed = history
            .iter()
            .filter(|item| item.observed_at >= recovery_cutoff && item.failed_native_recovery)
            .count();
        if failed >= self.config.failed_recovery_count {
            return true;
        }
        history
            .iter()
            .map(|item| item.session_id.as_str())
            .collect::<HashSet<_>>()
            .len()
            >= 2
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::continuity::opaque_identifier;

    fn observation(health: &str, at: f64) -> Observation {
        Observation {
            session_id: opaque_identifier("session", "s").unwrap(),
            command_id: None,
            component: "bridge".to_string(),
            provider: "none".to_string(),
            recovery_generation: "0".to_string(),
            phase: "delivery".to_string(),
            health: health.to_string(),
            observed_at: at,
            native_recovery_failed: false,
        }
        .validated()
        .unwrap()
    }

    #[test]
    fn a_stalled_component_qualifies_after_two_post_grace_samples() {
        let mut detector = ContinuityIncidentDetector::new(DetectorConfig::default(), None);
        let states: Vec<String> = [0.0, 15.0, 16.0, 17.0]
            .iter()
            .map(|at| {
                detector
                    .observe(&observation("unavailable", *at), None)
                    .unwrap()
                    .state
            })
            .collect();
        assert_eq!(states, ["transient", "transient", "stalled", "stalled"]);
        assert_eq!(
            detector
                .observe(&observation("unavailable", 1.0), None)
                .unwrap_err()
                .message,
            "observations for an incident must be time ordered"
        );
    }

    #[test]
    fn invalid_observations_name_the_field() {
        let mut bad = observation("healthy", 0.0);
        bad.session_id = "session-raw".to_string();
        assert_eq!(
            bad.validated().unwrap_err().message,
            "session_id must be created with opaque_identifier"
        );
        let mut bad = observation("healthy", 0.0);
        bad.health = "busy".to_string();
        assert_eq!(
            bad.validated().unwrap_err().message,
            "unsupported health: busy"
        );
        assert!(
            DetectorConfig {
                post_grace_samples: 1,
                ..DetectorConfig::default()
            }
            .validated()
            .is_err()
        );
    }
}
