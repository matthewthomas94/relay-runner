//! The continuity lane and the daemon's `ContinuityLifecycleAdapter`
//! (RR-499): lifecycle classifications and the incidents they emit, the
//! agent lane's outcomes for both providers, execution contexts, child
//! environments, Codex and Claude launch lines, the audit file and the
//! report store.

mod common;

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{Arc, Mutex};

use relay_intents::json::{self, Dict, Value};
use relay_services::continuity::agent::{
    self, BrokerCall, ContinuityAgentConfig, ContinuityAgentLane, ContinuityProviderSession,
    LaneOptions, RecoveryBroker, RecoveryBrokerOutcome, RecoveryHealthEvidence, SessionFactory,
};
use relay_services::continuity::incidents::Emit;
use relay_services::continuity::lifecycle::ContinuityLifecycleAdapter;
use relay_services::continuity::providers::{
    CatalogResolver, ContinuityBackend, ContinuityProviderPlan, MessengerConfig,
    plan_provider_session,
};
use relay_services::continuity::recovery::{
    RecoveryActionRequest, RecoveryActionValidation, RecoveryExecutionContext, recovery_request,
};
use relay_services::continuity::{Event, reports};
use relay_services::providers::catalog;
use relay_store::continuity::ContinuityReportStore;

use common::TempRoot;

fn parse(text: &str) -> Value {
    json::parse(text).unwrap_or_else(|| panic!("bad JSON: {text}"))
}

fn dict(value: &Value) -> Dict {
    value.as_dict().cloned().expect("object")
}

fn ok(value: impl Into<Value>) -> Value {
    let mut wrapped = Dict::new();
    wrapped.insert("ok", value.into());
    Value::Dict(wrapped)
}

fn failed(error: relay_services::Error) -> Value {
    assert!(
        ["ValueError", "RuntimeError"].contains(&error.class),
        "unexpected class {}",
        error.class
    );
    let mut wrapped = Dict::new();
    wrapped.insert("error", error.message);
    Value::Dict(wrapped)
}

fn attempt<T: Into<Value>>(result: relay_services::Result<T>) -> Value {
    match result {
        Ok(value) => ok(value),
        Err(error) => failed(error),
    }
}

fn list(items: Vec<Value>) -> Value {
    Value::List(items)
}

fn strings(items: &[String]) -> Value {
    list(
        items
            .iter()
            .map(|item| Value::from(item.as_str()))
            .collect(),
    )
}

fn health_from(value: &Value) -> RecoveryHealthEvidence {
    let value = dict(value);
    RecoveryHealthEvidence::new(
        value.get("objective_restored").unwrap().truthy(),
        value.get("stable_for_seconds").unwrap().py_float().unwrap(),
        value
            .get("evidence_codes")
            .unwrap()
            .as_list()
            .unwrap()
            .iter()
            .map(Value::py_str)
            .collect(),
    )
    .unwrap()
}

fn request_dict(request: &RecoveryActionRequest) -> Dict {
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
    value
}

fn validation_dict(validation: &RecoveryActionValidation) -> Dict {
    let mut health = Dict::new();
    health.insert("objective_restored", validation.health.objective_restored);
    health.insert("evidence_codes", strings(&validation.health.evidence_codes));
    let mut value = Dict::new();
    value.insert("validation_token", validation.validation_token.as_str());
    value.insert("exact_target_owned", validation.exact_target_owned);
    value.insert("liveness", validation.liveness.as_str());
    value.insert("incident_active", validation.incident_active);
    value.insert("generation_matches", validation.generation_matches);
    value.insert("command_phase", validation.command_phase.as_str());
    value.insert("command_phase_matches", validation.command_phase_matches);
    value.insert("idempotency_state", validation.idempotency_state.as_str());
    value.insert("compensation_available", validation.compensation_available);
    // The adapter builds its validation with `cooldown_remaining=0`, an int
    // the dataclass keeps.
    value.insert("cooldown_remaining", validation.cooldown_remaining as i64);
    assert_eq!(validation.cooldown_remaining, 0.0);
    value.insert(
        "expected_postcondition",
        validation.expected_postcondition.as_str(),
    );
    value.insert("health", health);
    value
}

// -- the lifecycle adapter --------------------------------------------------

const ADAPTER_STEPS: &str = r#"[
 {"event": {"source": "bridge", "event": "command_received", "session_id": "app-session-1", "provider": "claude", "observed_at": 100.0}},
 {"event": {"source": "bridge", "event": "teleported", "session_id": "app-session-1"}},
 {"event": {"source": "bridge", "event": "command_received"}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s1", "relay_command_id": "c1", "observed_at": 101.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s1", "relay_command_id": "c1", "observed_at": 117.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s1", "relay_command_id": "c1", "observed_at": 118.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s1", "relay_command_id": "c1", "observed_at": 119.0}},
 {"event": {"source": "stt", "event": "capture_started", "session_id": "s1", "observed_at": 120.0}},
 {"sample": 126.0},
 {"sample": 127.0},
 {"event": {"source": "provider", "provider": "codex", "event": "turn_started", "session_id": "s2", "command_id": "c2", "observed_at": 130.0}},
 {"event": {"source": "provider", "provider": "Claude-Code", "event": "stream_started", "session_id": "s3", "command_id": "c3", "recovery_generation": "7", "observed_at": 130.0}},
 {"event": {"source": "provider", "provider": "claude", "event": "process_exit", "session_id": "s3", "command_id": "c3", "recovery_generation": "7", "observed_at": 131.0}},
 {"event": {"source": "provider", "provider": "codex", "event": "stream_started", "session_id": "s2"}},
 {"sample": 161.0},
 {"sample": 162.0},
 {"sample": 163.0},
 {"event": {"source": "messenger", "event": "failed", "session_id": "s4", "provider": "codex", "observed_at": 140.0}},
 {"event": {"source": "messenger", "event": "failed", "session_id": "s5", "provider": "codex", "observed_at": 141.0}},
 {"event": {"source": "command", "event": "accepted", "session_id": "s6", "relay_command_id": "c6", "observed_at": 150.0}},
 {"event": {"source": "command", "event": "completed", "session_id": "s6", "relay_command_id": "c6", "observed_at": 151.0}},
 {"event": {"source": "command", "event": "failed", "session_id": "s6", "relay_command_id": "c6", "observed_at": 152.0}},
 {"event": {"source": "command", "event": "planning", "session_id": "s10", "relay_command_id": "c10", "provider": "claude", "observed_at": 150.0}},
 {"event": {"source": "session", "event": "explicit_stop", "session_id": "s7", "observed_at": 160.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s7", "observed_at": 161.0}},
 {"event": {"source": "session", "event": "started", "session_id": "s7", "observed_at": 162.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s8", "recovery_generation": "-bad", "observed_at": 170.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s8", "observed_at": "soon"}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s8", "recovery_generation": null, "observed_at": 170.0}},
 {"event": {"source": "bridge", "event": "delivery_failed", "session_id": "s8", "recovery_generation": 5, "observed_at": "171.5"}},
 {"event": {"source": "daemon", "event": "heartbeat_missed", "session_id": "s9", "observed_at": 200.0}},
 {"sample": 231.0},
 {"sample": 232.0},
 {"event": {"source": "stt", "event": "transcription_started", "session_id": "s11", "observed_at": 240.0}},
 {"event": {"source": "bridge", "event": "command_received", "session_id": "s11", "relay_command_id": "c11", "observed_at": 241.0}},
 {"sample": 300.0},
 {"event": {"source": "daemon", "event": "heartbeat", "session_id": "s9", "observed_at": 301.0}},
 {"sample": 400.0}
]"#;

const PROCESS: &str = "continuity-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn rust_adapter(steps: &Value, capabilities: &[&str]) -> (Value, Vec<Dict>) {
    let emitted: Arc<Mutex<Vec<Dict>>> = Arc::default();
    let sink = Arc::clone(&emitted);
    let emit: Emit = Box::new(move |envelope| sink.lock().unwrap().push(envelope.clone()));
    let adapter = ContinuityLifecycleAdapter::new(Some(emit));
    let mut results = Vec::new();
    for step in steps.as_list().unwrap() {
        let step = dict(step);
        results.push(match step.get("sample") {
            Some(at) => attempt(
                adapter
                    .sample(at.py_float())
                    .map(|items| list(items.iter().map(|r| Value::Dict(r.as_dict())).collect())),
            ),
            None => attempt(
                adapter
                    .observe(&dict(step.get("event").unwrap()))
                    .map(|r| r.as_dict()),
            ),
        });
    }
    let emitted = emitted.lock().unwrap().clone();
    let mut requests = Vec::new();
    for envelope in &emitted {
        for capability in capabilities {
            let generation = envelope.string("recovery_generation");
            let mut entry = Dict::new();
            match recovery_request(capability, envelope, PROCESS, &generation, 1, 1.0e12) {
                Err(code) => entry.insert("code", code),
                Ok(request) => {
                    entry.insert("request", request_dict(&request));
                    entry.insert(
                        "validation",
                        validation_dict(&adapter.recovery_validation(&request)),
                    );
                }
            }
            requests.push(Value::Dict(entry));
        }
    }
    let mut out = Dict::new();
    out.insert("steps", list(results));
    out.insert(
        "emitted",
        list(emitted.iter().cloned().map(Value::Dict).collect()),
    );
    out.insert("requests", list(requests));
    (Value::Dict(out), emitted)
}

const CAPABILITIES: [&str; 4] = [
    "release_dead_ownership",
    "check_processing_health",
    "restart_bridge",
    "reinitialize_speech_capture",
];

#[test]
fn the_lifecycle_adapter_emits_incidents_for_the_scenario() {
    let steps = parse(ADAPTER_STEPS);
    let (_, emitted) = rust_adapter(&steps, &CAPABILITIES);
    assert!(
        emitted.len() >= 5,
        "the scenario emits incidents: {}",
        emitted.len()
    );
}

/// The RR-485 contract case `test_continuity_observation_and_messenger_routes`,
/// its continuity half, at library level.
#[test]
fn contract_continuity_observation() {
    let adapter = ContinuityLifecycleAdapter::new(None);
    let event = dict(&parse(
        r#"{"source": "bridge", "event": "command_received", "session_id": "app-session-1", "provider": "claude"}"#,
    ));
    let observed = adapter.observe(&event).unwrap().as_dict();
    assert_eq!(observed.string("state"), "healthy");
    assert!(
        observed
            .get("incident")
            .is_some_and(|i| matches!(i, Value::Null))
    );
    let teleported = dict(&parse(
        r#"{"source": "bridge", "event": "teleported", "session_id": "app-session-1"}"#,
    ));
    let error = adapter.observe(&teleported).unwrap_err();
    assert_eq!(
        (error.class, error.message.as_str()),
        ("ValueError", "unsupported continuity lifecycle event")
    );
}

// -- incidents ------------------------------------------------------------

fn incident_for(events: &str) -> Dict {
    let emitted: Arc<Mutex<Vec<Dict>>> = Arc::default();
    let sink = Arc::clone(&emitted);
    let emit: Emit = Box::new(move |envelope| sink.lock().unwrap().push(envelope.clone()));
    let fresh = ContinuityLifecycleAdapter::new(Some(emit));
    for event in parse(events).as_list().unwrap() {
        fresh.observe(&dict(event)).unwrap();
    }
    emitted
        .lock()
        .unwrap()
        .last()
        .cloned()
        .expect("an incident")
}

fn broker_incidents() -> Vec<Value> {
    vec![
        Value::Dict(incident_for(
            r#"[{"source": "bridge", "event": "delivery_failed", "session_id": "b1", "relay_command_id": "bc1", "observed_at": 10.0},
                {"source": "bridge", "event": "delivery_failed", "session_id": "b1", "relay_command_id": "bc1", "observed_at": 30.0},
                {"source": "bridge", "event": "delivery_failed", "session_id": "b1", "relay_command_id": "bc1", "observed_at": 31.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "provider", "provider": "codex", "event": "turn_failed", "session_id": "p1", "command_id": "pc1", "observed_at": 10.0},
                {"source": "provider", "provider": "codex", "event": "turn_failed", "session_id": "p1", "command_id": "pc1", "observed_at": 45.0},
                {"source": "provider", "provider": "codex", "event": "turn_failed", "session_id": "p1", "command_id": "pc1", "observed_at": 46.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "daemon", "event": "heartbeat_missed", "session_id": "d1", "observed_at": 10.0},
                {"source": "daemon", "event": "heartbeat_missed", "session_id": "d1", "observed_at": 45.0},
                {"source": "daemon", "event": "heartbeat_missed", "session_id": "d1", "observed_at": 46.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "messenger", "event": "failed", "session_id": "m1", "provider": "claude", "observed_at": 10.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "stt", "event": "capture_failed", "session_id": "t1", "observed_at": 10.0},
                {"source": "stt", "event": "capture_failed", "session_id": "t1", "observed_at": 15.0},
                {"source": "stt", "event": "capture_failed", "session_id": "t1", "observed_at": 16.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "stt", "event": "transcription_failed", "session_id": "t2", "observed_at": 10.0},
                {"source": "stt", "event": "transcription_failed", "session_id": "t2", "observed_at": 20.0},
                {"source": "stt", "event": "transcription_failed", "session_id": "t2", "observed_at": 21.0}]"#,
        )),
        Value::Dict(incident_for(
            r#"[{"source": "session", "event": "process_exit", "session_id": "o1", "provider": "codex", "observed_at": 10.0},
                {"source": "session", "event": "process_exit", "session_id": "o1", "provider": "codex", "observed_at": 45.0},
                {"source": "session", "event": "process_exit", "session_id": "o1", "provider": "codex", "observed_at": 46.0}]"#,
        )),
    ]
}

// -- the agent lane ---------------------------------------------------------

const LANE_SCENARIOS: &str = r#"[
 {"provider": "codex", "capabilities": ["restart_bridge", "check_processing_health", "restart_bridge"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}"],
  "outcomes": [
    {"capability": "restart_bridge", "status": "applied", "outcome_code": "bridge_restarted",
     "health": {"objective_restored": true, "stable_for_seconds": 10.0, "evidence_codes": ["bridge_process_alive"]}},
    {"capability": "check_processing_health", "status": "noop", "outcome_code": "processing_health_checked",
     "health": {"objective_restored": true, "stable_for_seconds": 60.0, "evidence_codes": ["bridge_process_alive"]}}]},
 {"provider": "claude", "capabilities": ["restart_bridge"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"finish\",\"result\":\"escalate\"}"], "outcomes": []},
 {"provider": "claude", "capabilities": ["restart_bridge"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["I restored it!"], "outcomes": []},
 {"provider": "codex", "capabilities": ["restart_bridge"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}"],
  "outcomes": [{"capability": "restart_bridge", "status": "authorization_required", "outcome_code": "target_ownership_not_proven",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}}]},
 {"provider": "codex", "capabilities": ["restart_bridge", "check_processing_health"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_messenger\"}"], "outcomes": []},
 {"provider": "codex", "capabilities": ["restart_bridge"], "fail_launch": true,
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": [], "outcomes": []},
 {"provider": "claude", "capabilities": ["restart_bridge"],
  "config": {"max_attempts": 4, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}"],
  "outcomes": [{"capability": "restart_bridge", "status": "circuit_open", "outcome_code": "broker_call_timed_out",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}}]},
 {"provider": "codex", "capabilities": ["restart_bridge"],
  "config": {"max_attempts": 1, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}", "{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}"],
  "outcomes": [{"capability": "restart_bridge", "status": "failed", "outcome_code": "restart_failed",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}}]},
 {"provider": "codex", "capabilities": ["restart_bridge", "check_processing_health"],
  "config": {"max_attempts": 2, "wall_clock_seconds": 120.0, "stable_health_seconds": 60.0, "cooldown_seconds": 900.0},
  "decisions": ["{\"kind\":\"broker_call\",\"capability\":\"restart_bridge\"}", "{\"kind\":\"finish\",\"result\":\"escalate\"}",
                "{\"kind\":\"finish\",\"result\":\"escalate\"}", "{\"kind\":\"finish\",\"result\":\"escalate\"}"],
  "outcomes": [
    {"capability": "restart_bridge", "status": "applied", "outcome_code": "bridge_restarted",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}},
    {"capability": "check_processing_health", "status": "noop", "outcome_code": "processing_health_checked",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}},
    {"capability": "check_processing_health", "status": "noop", "outcome_code": "processing_health_checked",
     "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}}]}
]"#;

struct ScriptedSession {
    provider: String,
    decisions: Mutex<Vec<String>>,
    prompts: Arc<Mutex<Vec<Value>>>,
}

impl ContinuityProviderSession for ScriptedSession {
    fn provider(&self) -> String {
        self.provider.clone()
    }

    fn decide(&self, prompt: &str, _timeout: f64) -> relay_services::Result<String> {
        self.prompts.lock().unwrap().push(Value::from(prompt));
        let mut decisions = self.decisions.lock().unwrap();
        if decisions.is_empty() {
            return Err(relay_services::Error::runtime("no decision"));
        }
        Ok(decisions.remove(0))
    }

    fn interrupt(&self) -> relay_services::Result<()> {
        Ok(())
    }

    fn shutdown(&self) -> relay_services::Result<()> {
        Ok(())
    }
}

struct ScriptedBroker {
    capabilities: Vec<String>,
    outcomes: Mutex<Vec<Value>>,
    calls: Arc<Mutex<Vec<Value>>>,
}

impl RecoveryBroker for ScriptedBroker {
    fn capabilities(&self, _incident: &Dict) -> relay_services::Result<Vec<String>> {
        Ok(self.capabilities.clone())
    }

    fn perform(
        &self,
        capability: &str,
        call: BrokerCall,
    ) -> relay_services::Result<RecoveryBrokerOutcome> {
        self.calls.lock().unwrap().push(list(vec![
            capability.into(),
            call.attempt.into(),
            call.recovery_generation.as_str().into(),
        ]));
        let item = dict(&self.outcomes.lock().unwrap().remove(0));
        RecoveryBrokerOutcome::new(
            &item.string("capability"),
            &item.string("status"),
            &item.string("outcome_code"),
            health_from(item.get("health").unwrap()),
        )
    }
}

fn rust_lane(scenario: &Dict, incident: &Dict) -> Value {
    let prompts: Arc<Mutex<Vec<Value>>> = Arc::default();
    let calls: Arc<Mutex<Vec<Value>>> = Arc::default();
    let audits: Arc<Mutex<Vec<Value>>> = Arc::default();
    let finals: Arc<Mutex<Vec<Value>>> = Arc::default();
    let decisions: Vec<String> = scenario
        .get("decisions")
        .unwrap()
        .as_list()
        .unwrap()
        .iter()
        .map(Value::py_str)
        .collect();
    let provider = scenario.string("provider");
    let fail_launch = scenario.get("fail_launch").is_some_and(Value::truthy);
    let session_prompts = Arc::clone(&prompts);
    let factory: SessionFactory = Arc::new(move |_, _, _| {
        if fail_launch {
            return Err(relay_services::Error::new("OSError", "no provider"));
        }
        Ok(Arc::new(ScriptedSession {
            provider: provider.clone(),
            decisions: Mutex::new(decisions.clone()),
            prompts: Arc::clone(&session_prompts),
        }) as Arc<dyn ContinuityProviderSession>)
    });
    let broker = Arc::new(ScriptedBroker {
        capabilities: scenario
            .get("capabilities")
            .unwrap()
            .as_list()
            .unwrap()
            .iter()
            .map(Value::py_str)
            .collect(),
        outcomes: Mutex::new(
            scenario
                .get("outcomes")
                .unwrap()
                .as_list()
                .unwrap()
                .to_vec(),
        ),
        calls: Arc::clone(&calls),
    });
    let audit_sink = Arc::clone(&audits);
    let final_sink = Arc::clone(&finals);
    let config = dict(scenario.get("config").unwrap());
    let number = |key: &str| config.get(key).unwrap().py_float().unwrap();
    let lane = ContinuityAgentLane::new(
        factory,
        broker,
        Arc::new(move |record: &Dict| {
            let mut record = record.clone();
            record.remove("recorded_at");
            let identity = record.remove("process_identity").unwrap().py_str();
            assert!(identity.starts_with("continuity-") && identity.len() == 43);
            audit_sink.lock().unwrap().push(Value::Dict(record));
            Ok(())
        }),
        LaneOptions {
            on_result: Some(Arc::new(move |_: &Dict, result: &str| {
                final_sink.lock().unwrap().push(Value::from(result));
                Ok(())
            })),
            config: ContinuityAgentConfig {
                max_attempts: config.get("max_attempts").unwrap().py_int().unwrap(),
                wall_clock_seconds: number("wall_clock_seconds"),
                stable_health_seconds: number("stable_health_seconds"),
                cooldown_seconds: number("cooldown_seconds"),
            }
            .validated()
            .unwrap(),
            monotonic: Arc::new(|| 0.0),
            wait: Some(Arc::new(|_| false)),
        },
    );
    let incident = Value::Dict(incident.clone());
    let first = lane.submit(&incident).unwrap();
    assert!(lane.wait_until_idle(10.0));
    let second = lane.submit(&incident).unwrap();
    let mut out = Dict::new();
    out.insert("submitted", list(vec![first.into(), second.into()]));
    out.insert("prompts", list(prompts.lock().unwrap().clone()));
    out.insert("calls", list(calls.lock().unwrap().clone()));
    out.insert("audits", list(audits.lock().unwrap().clone()));
    out.insert("finals", list(finals.lock().unwrap().clone()));
    Value::Dict(out)
}

#[test]
fn the_agent_lane_finishes_each_scenario_for_both_providers() {
    let incident = dict(&broker_incidents()[0]);
    let scenarios = parse(LANE_SCENARIOS);
    let rust = list(
        scenarios
            .as_list()
            .unwrap()
            .iter()
            .map(|scenario| rust_lane(&dict(scenario), &incident))
            .collect(),
    );
    let finals: Vec<String> = rust
        .as_list()
        .unwrap()
        .iter()
        .map(|r| dict(r).get("finals").unwrap().as_list().unwrap()[0].py_str())
        .collect();
    assert_eq!(
        finals,
        [
            "restored",
            "circuit_open",
            "provider_failed",
            "authorization_required",
            "provider_failed",
            "provider_failed",
            "circuit_open",
            "circuit_open",
            "circuit_open",
        ]
    );
}

#[test]
fn the_lane_queues_a_distinct_incident_and_refuses_an_invalid_one() {
    let incidents = broker_incidents();
    let release = Event::new();
    let gate = release.clone();
    let launched: Arc<Mutex<Vec<String>>> = Arc::default();
    let seen = Arc::clone(&launched);
    let factory: SessionFactory = Arc::new(move |_, incident_id, _| {
        seen.lock().unwrap().push(incident_id.to_string());
        gate.wait(5.0);
        Ok(Arc::new(ScriptedSession {
            provider: "claude".into(),
            decisions: Mutex::new(vec![r#"{"kind":"finish","result":"escalate"}"#.into()]),
            prompts: Arc::default(),
        }) as Arc<dyn ContinuityProviderSession>)
    });
    let lane = ContinuityAgentLane::new(
        factory,
        Arc::new(agent::UnavailableRecoveryBroker),
        Arc::new(|_: &Dict| Ok(())),
        LaneOptions::default(),
    );
    assert_eq!(lane.submit(&incidents[0]).unwrap(), "launched");
    assert_eq!(lane.submit(&incidents[0]).unwrap(), "duplicate");
    assert_eq!(lane.submit(&incidents[1]).unwrap(), "single_flight");
    assert_eq!(lane.submit(&incidents[1]).unwrap(), "duplicate");
    assert_eq!(
        lane.submit(&Value::List(vec![])).unwrap_err().message,
        "continuity incident must be an object"
    );
    release.set();
    assert!(lane.wait_until_idle(10.0));
    assert_eq!(launched.lock().unwrap().len(), 2);
    assert_eq!(lane.submit(&incidents[0]).unwrap(), "cooldown");
    lane.shutdown();
    assert_eq!(lane.submit(&incidents[2]).unwrap(), "shutdown");
}

// -- execution contexts, environments and launch lines ----------------------

#[test]
fn execution_contexts_parse_a_valid_payload() {
    let (_, emitted) = rust_adapter(&parse(ADAPTER_STEPS), &[]);
    let incident = &emitted[0];
    let request = recovery_request(
        "restart_bridge",
        incident,
        PROCESS,
        &incident.string("recovery_generation"),
        2,
        500.5,
    )
    .unwrap();
    let validation = RecoveryActionValidation {
        validation_token: "live_continuity_watch".into(),
        exact_target_owned: true,
        liveness: "confirmed_dead".into(),
        incident_active: true,
        generation_matches: true,
        command_phase: "undelivered".into(),
        command_phase_matches: true,
        idempotency_state: "new".into(),
        compensation_available: false,
        cooldown_remaining: 0.0,
        expected_postcondition: request.expected_postcondition.clone(),
        health: RecoveryHealthEvidence::default(),
    };
    let payload = RecoveryExecutionContext {
        request,
        validation,
    }
    .as_dict();
    let mut payloads = vec![Value::Dict(payload.clone())];
    for (key, value) in [
        ("attempt", Value::Bool(true)),
        ("attempt", Value::Int(0)),
        ("deadline", Value::from("500")),
        ("deadline", Value::Int(7)),
        (
            "idempotency_key",
            Value::from("recovery_000000000000000000000000"),
        ),
        ("provider", Value::from("gemini")),
        ("recovery_generation", Value::Int(3)),
        ("command_id", Value::Null),
        ("cooldown_remaining", Value::Float(-1.0)),
        ("liveness", Value::from("asleep")),
        ("incident_phase", Value::from("capture")),
        (
            "expected_postcondition",
            Value::from("bridge_heartbeat_fresh"),
        ),
        ("exact_target_owned", Value::Int(1)),
        ("process_identity", Value::from("continuity-1")),
    ] {
        let mut copy = payload.clone();
        copy.insert(key, value);
        payloads.push(Value::Dict(copy));
    }
    let rust = list(
        payloads
            .iter()
            .map(|p| attempt(RecoveryExecutionContext::from_mapping(&dict(p)).map(|c| c.as_dict())))
            .collect(),
    );
    assert!(dict(&rust.as_list().unwrap()[0]).get("ok").is_some());
}

#[test]
fn child_environments_carry_only_the_launched_providers_login() {
    let parent: BTreeMap<String, String> = [
        ("HOME", "/Users/someone"),
        ("PATH", "/usr/bin:/bin"),
        ("LANG", "en_AU.UTF-8"),
        ("ANTHROPIC_API_KEY", "sk-not-forwarded"),
        ("OPENAI_API_KEY", "sk-not-forwarded"),
        ("CODEX_HOME", "/Users/someone/.codex"),
        ("CLAUDE_CONFIG_DIR", "/Users/someone/.claude"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "subscription-token"),
        ("RELAY_REPLY_HELPER", "/tmp/reply"),
        ("VOICE_COMMAND_STATE_FILE", "/tmp/state.json"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    let cases: [(Option<&str>, &str); 4] = [
        (Some("codex"), "0"),
        (Some("claude"), "gen-2"),
        (None, "3"),
        (Some("claude"), "-bad"),
    ];
    let rust = list(
        cases
            .iter()
            .map(|(provider, generation)| {
                attempt(
                    agent::continuity_agent_environment(
                        "continuity-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "inc-0123456789ab",
                        generation,
                        Some(&parent),
                        *provider,
                    )
                    .map(|environment| {
                        let mut value = Dict::new();
                        for (key, item) in environment {
                            value.insert(&key, item);
                        }
                        value
                    }),
                )
            })
            .collect(),
    );
    let claude = dict(dict(&rust.as_list().unwrap()[1]).get("ok").unwrap());
    assert!(claude.get("CLAUDE_CODE_OAUTH_TOKEN").is_some());
    assert!(claude.get("CODEX_HOME").is_none() && claude.get("ANTHROPIC_API_KEY").is_none());
}

const MODELS: &str = r#"{"data": [
 {"id": "gpt-6-luna", "model": "gpt-6-luna", "defaultReasoningEffort": "low",
  "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}], "inputModalities": ["text"]},
 {"id": "gpt-6.1-terra", "model": "gpt-6.1-terra", "defaultReasoningEffort": "medium",
  "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}, {"reasoningEffort": "high"}]},
 {"id": "gpt-6-terra", "model": "gpt-6-terra", "supportedReasoningEfforts": ["low"]},
 {"id": "gpt-6-sol", "model": "gpt-6-sol", "hidden": true}
]}"#;

fn fixture_resolver() -> CatalogResolver {
    Arc::new(|config: &MessengerConfig| {
        if config.provider != "codex" {
            return Ok(config.clone());
        }
        let family =
            catalog::normalize_codex_family(&config.model, catalog::CODEX_MESSENGER_DEFAULT_FAMILY);
        let models = catalog::models_from_model_list(&parse(MODELS));
        let resolved = catalog::resolve_family(&family, &models)?;
        let effort = catalog::resolve_effort(&config.effort, &resolved)?;
        Ok(MessengerConfig {
            model: resolved.launch_model().to_string(),
            effort,
            ..config.clone()
        })
    })
}

fn fake_executable(directory: &Path, name: &str) -> String {
    let path = directory.join(name);
    fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path.to_string_lossy().into_owned()
}

#[test]
fn codex_and_claude_launch_lines_run_as_the_continuity_agent() {
    let root = TempRoot::new("continuity-backends");
    let bin = root.path.join("bin with space");
    fs::create_dir_all(&bin).unwrap();
    let claude = fake_executable(&bin, "claude");
    let codex = fake_executable(&bin, "codex");
    let cwd = root.path.to_string_lossy().into_owned();
    let configs_text = format!(
        r#"[
 {{"general": {{"provider": "claude", "command": "{claude}", "model": "opus", "orchestrator_effort": "high"}}}},
 {{"general": {{"provider": "claude", "command": "{claude}"}}, "continuity": {{"model": "haiku", "effort": "high"}}}},
 {{"general": {{"provider": "codex", "command": "{codex}"}}, "continuity": {{"model": "terra", "effort": "high"}}}},
 {{"general": {{"provider": "codex", "command": "{codex}", "model": "gpt-6-luna"}}}},
 {{"general": {{"provider": "codex", "command": "{codex}"}}, "continuity": {{"model": "astra"}}}},
 {{"general": {{"provider": "codex", "command": "{codex}"}}, "continuity": {{"model": "terra", "effort": "ultra"}}}},
 {{"general": {{"provider": "codex", "command": "/nonexistent/codex"}}}},
 {{"general": {{"provider": "codex", "command": "/nonexistent/codex"}},
   "continuity": {{"fallback_provider": "Claude", "fallback_command": "{claude}", "fallback_model": "sonnet", "fallback_effort": "low"}}}},
 {{"general": {{"provider": "codex", "command": "/nonexistent/codex"}},
   "continuity": {{"fallback_provider": "claude", "fallback_command": "{claude}", "fallback_model": "sonnet"}}}},
 {{"general": {{"provider": "claude", "command": "/nonexistent/claude"}},
   "continuity": {{"fallback_provider": "claude", "fallback_command": "{claude}", "fallback_model": "sonnet", "fallback_effort": "low"}}}}
]"#
    );
    let configs = parse(&configs_text);
    let resolver = fixture_resolver();
    let empty = BTreeMap::new();
    let rust = list(
        configs
            .as_list()
            .unwrap()
            .iter()
            .map(|config| {
                let mut out = Dict::new();
                match plan_provider_session(&dict(config), &cwd, &resolver) {
                    ContinuityProviderPlan::Unavailable {
                        provider,
                        reason_code,
                    } => {
                        out.insert("provider", provider);
                        out.insert("unavailable", reason_code);
                    }
                    ContinuityProviderPlan::Ready(config) => {
                        let backend = ContinuityBackend::new(
                            config,
                            "continuity-cccccccccccccccccccccccccccccccc",
                            "inc-0123456789ab",
                            "4",
                            Some(&empty),
                        )
                        .unwrap();
                        out.insert("provider", backend.provider());
                        out.insert("spawn", strings(&backend.spawn_command()));
                        out.insert(
                            "thread",
                            if backend.provider() == "codex" {
                                Value::Dict(backend.thread_start_params())
                            } else {
                                Value::Null
                            },
                        );
                        assert_eq!(
                            backend.child_environment().get("RELAY_ACTOR_ROLE").unwrap(),
                            "continuity-agent"
                        );
                    }
                }
                Value::Dict(out)
            })
            .collect(),
    );
    let launched: Vec<String> = rust
        .as_list()
        .unwrap()
        .iter()
        .map(dict)
        .filter(|out| out.get("spawn").is_some())
        .map(|out| out.string("provider"))
        .collect();
    assert!(
        launched.iter().any(|provider| provider == "codex")
            && launched.iter().any(|provider| provider == "claude"),
        "{launched:?}"
    );
}

// -- the audit file and the report store -----------------------------------

#[test]
fn audit_lines_are_appended_owner_only() {
    let incident = dict(&broker_incidents()[0]);
    let outcome = RecoveryBrokerOutcome::new(
        "restart_bridge",
        "applied",
        "bridge_restarted",
        RecoveryHealthEvidence::new(true, 12.25, vec!["bridge_process_alive".into()]).unwrap(),
    )
    .unwrap();
    let records = vec![
        agent::audit_record(
            &incident,
            PROCESS,
            "codex",
            "launched",
            0,
            None,
            None,
            1_780_000_000.5,
        ),
        agent::audit_record(
            &incident,
            PROCESS,
            "claude",
            "broker_outcome",
            1,
            Some(&outcome),
            None,
            1_780_000_001.0,
        ),
        agent::audit_record(
            &incident,
            PROCESS,
            "claude",
            "completed",
            1,
            None,
            Some("restored"),
            1_780_000_002.125,
        ),
        dict(&parse(
            r#"{"unicode": "café ✓", "nested": {"b": 1, "a": [1.5, null, true]}}"#,
        )),
    ];
    let root = TempRoot::new("continuity-audit");
    let ours = root.path.join("rust/continuity_agent_events.jsonl");
    for record in &records {
        agent::append_audit_record(&ours, record).unwrap();
    }
    assert_eq!(
        fs::metadata(&ours).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // Each record is one line that reads back as written.
    let lines: Vec<String> = fs::read_to_string(&ours)
        .unwrap()
        .lines()
        .map(|line| json::dumps_sorted(&parse(line)))
        .collect();
    let written: Vec<String> = records
        .into_iter()
        .map(|record| json::dumps_sorted(&Value::Dict(record)))
        .collect();
    assert_eq!(lines, written);
}

#[test]
fn reports_are_recorded_edited_and_accepted() {
    let incidents = broker_incidents();
    let root = TempRoot::new("continuity-reports");
    let path = root.data_root().join("continuity_reports.db");
    let proposal = reports::default_proposal(&dict(&incidents[1]));

    // Two reports: one with an edited default draft, one with a rejected
    // explicit proposal. A reopened store reads them back.
    let ids = {
        let store = ContinuityReportStore::open(&path).unwrap();
        let (first, _) =
            reports::record_unresolved(&store, &incidents[0], "circuit_open", None).unwrap();
        let first_id = first.string("report_id");
        let first_proposal =
            dict(&first.get("proposals").unwrap().as_list().unwrap()[0]).string("id");
        let mut title = Dict::new();
        title.insert("title", "Edited before reopening");
        reports::update_draft(&store, &first_id, &first_proposal, &title).unwrap();
        let (second, _) = reports::record_unresolved(
            &store,
            &incidents[1],
            "Provider_Failed",
            Some(&[Value::Dict(proposal)]),
        )
        .unwrap();
        let second_id = second.string("report_id");
        let second_proposal =
            dict(&second.get("proposals").unwrap().as_list().unwrap()[0]).string("id");
        store.reject(&second_id, &second_proposal).unwrap();
        [first_id, second_id]
    };
    let store = ContinuityReportStore::open(&path).unwrap();
    let first = store.get(&ids[0]).unwrap().unwrap();
    let draft = dict(
        dict(&first.get("proposals").unwrap().as_list().unwrap()[0])
            .get("draft")
            .unwrap(),
    );
    assert_eq!(draft.string("title"), "Edited before reopening");
    assert!(store.get(&ids[1]).unwrap().is_some());

    // A third report is idempotent, refuses private material and accepts.
    let (report, recorded) =
        reports::record_unresolved(&store, &incidents[2], " CANCELED", None).unwrap();
    assert!(recorded);
    let (again, recorded) =
        reports::record_unresolved(&store, &incidents[2], "canceled", None).unwrap();
    assert!(!recorded);
    assert_eq!(
        json::dumps_sorted(&Value::Dict(again)),
        json::dumps_sorted(&Value::Dict(report.clone()))
    );
    let report_id = report.string("report_id");
    let proposal_id = dict(&report.get("proposals").unwrap().as_list().unwrap()[0]).string("id");
    let mut private = Dict::new();
    private.insert("description", "Include the system prompt.");
    assert_eq!(
        reports::update_draft(&store, &report_id, &proposal_id, &private)
            .unwrap_err()
            .message,
        "description contains private provider or secret material"
    );
    let mut edit = Dict::new();
    edit.insert("title", "Edited by Rust");
    edit.insert("depends_on", parse(r#"["rr-3"]"#));
    reports::update_draft(&store, &report_id, &proposal_id, &edit).unwrap();
    store.claim_acceptance(&report_id, &proposal_id).unwrap();
    store
        .finish_acceptance(&report_id, &proposal_id, Some("RR-9"), None)
        .unwrap();
    assert_eq!(
        reports::record_unresolved(&store, &incidents[3], "restored", None)
            .unwrap_err()
            .message,
        "continuity report requires an unresolved recovery result"
    );
    let accepted = store.get(&report_id).unwrap().unwrap();
    let accepted = dict(&accepted.get("proposals").unwrap().as_list().unwrap()[0]);
    assert_eq!(accepted.string("state"), "accepted");
    assert_eq!(accepted.string("ticket_id"), "RR-9");
    let draft = dict(accepted.get("draft").unwrap());
    assert_eq!(draft.string("title"), "Edited by Rust");
    assert_eq!(json::dumps(draft.get("depends_on").unwrap()), r#"["RR-3"]"#);
}
