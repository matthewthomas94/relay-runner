//! The continuity lane against `services/continuity_*.py` and the daemon's
//! `ContinuityLifecycleAdapter` (RR-499).
//!
//! Each case runs one scenario through the Python modules (`DRIVER` below,
//! one phase per case) and through the Rust port, and compares the two as
//! sorted JSON: lifecycle classifications and emitted envelopes, live
//! recovery validations, sanitized bundles, reports and proposals, broker
//! outcomes, lane audits and prompts, execution contexts, child
//! environments, Codex and Claude launch lines, audit-file bytes, and report
//! rows written by one side and read by the other. Each case skips when no
//! Python can import `services/`.

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
    CAPABILITY_POLICIES, ComponentOwnedRecoveryBroker, HEALTH_CHECK, ProductionRecoveryCapability,
    RecoveryActionRequest, RecoveryActionResult, RecoveryActionValidation,
    RecoveryExecutionContext, RecoveryOwners, production_recovery_owners, recovery_request,
};
use relay_services::continuity::{Event, reports};
use relay_services::providers::catalog;
use relay_store::continuity::ContinuityReportStore;

use common::{TempRoot, python, run_python};

const DRIVER: &str = r#"
import dataclasses, json, threading
from pathlib import Path
import continuity_agent as ca
import continuity_recovery as cr
import continuity_reports as rep

phase = sys.argv[1]
data = json.loads(Path(sys.argv[2]).read_text())

def classification(result):
    return {"state": result.state, "fingerprint": result.fingerprint,
            "suppression_reason": result.suppression_reason,
            "incident": result.envelope.as_dict() if result.envelope is not None else None}

def attempt(function):
    try:
        return {"ok": function()}
    except (ValueError, RuntimeError) as error:
        return {"error": str(error)}

def health(value):
    return ca.RecoveryHealthEvidence(value["objective_restored"], value["stable_for_seconds"],
                                     tuple(value["evidence_codes"]))

def validation_dict(validation):
    value = dataclasses.asdict(validation)
    value["health"].pop("stable_for_seconds")
    return value

out = None
if phase == "adapter":
    from orchestrator import ContinuityLifecycleAdapter
    emitted = []
    adapter = ContinuityLifecycleAdapter(emit=emitted.append)
    steps = []
    for step in data["steps"]:
        if "sample" in step:
            steps.append(attempt(lambda: [classification(r) for r in adapter.sample(observed_at=step["sample"])]))
        else:
            steps.append(attempt(lambda: classification(adapter.observe(step["event"]))))
    requests = []
    for envelope in emitted:
        for capability in data["capabilities"]:
            request = cr.ComponentOwnedRecoveryBroker._request(
                None, capability, cr.CAPABILITY_POLICIES[capability], envelope,
                "continuity-" + "a" * 32, envelope["recovery_generation"], 1, 1.0e12)
            if isinstance(request, str):
                requests.append({"code": request})
            else:
                requests.append({"request": dataclasses.asdict(request),
                                 "validation": validation_dict(adapter.recovery_validation(request))})
    out = {"steps": steps, "emitted": emitted, "requests": requests}
elif phase == "sanitize":
    out = {
        "bundles": [attempt(lambda: ca.sanitize_incident_bundle(item)) for item in data["incidents"]],
        "reports": [attempt(lambda: rep.build_report(item, result))
                    for item in data["incidents"] for result in data["results"]],
        "defaults": [attempt(lambda: rep._default_proposal(item)) for item in data["defaults"]],
        "proposals": [attempt(lambda: rep.sanitize_proposal(item)) for item in data["proposals"]],
    }
elif phase == "broker":
    clock = [0.0]
    spec = data["spec"]
    def make(capability):
        entry = spec.get(capability, {})
        def inspect(request):
            fields = dict(data["default_validation"], **entry.get("validation", {}))
            fields["expected_postcondition"] = fields.pop("postcondition", request.expected_postcondition)
            fields["health"] = health(fields["health"])
            return cr.RecoveryActionValidation(**fields)
        def execute(request, validation, cancel):
            fields = dict(data["default_result"], **entry.get("result", {}))
            fields["health"] = health(fields["health"])
            return cr.RecoveryActionResult(**fields)
        def cleanup(request):
            return entry.get("cleanup", False)
        return cr.ProductionRecoveryCapability(inspect, execute, cleanup)
    capabilities = {name: make(name) for name in cr.CAPABILITY_POLICIES if name != "check_processing_health"}
    owners = cr.production_recovery_owners(lambda request: health(data["probe_health"]), capabilities=capabilities)
    if data.get("owners") is not None:
        owners = {name: owners[name] for name in data["owners"]}
    broker = cr.ComponentOwnedRecoveryBroker(owners, monotonic=lambda: clock[0])
    results = []
    for call in data["calls"]:
        clock[0] = call["now"]
        cancel = threading.Event()
        if call.get("cancel"):
            cancel.set()
        incident = data["incidents"][call["incident"]]
        results.append({
            "capabilities": list(broker.capabilities(incident)),
            "outcome": broker.perform(call["capability"], incident=incident,
                process_identity=call["process_identity"], recovery_generation=call["generation"],
                attempt=call["attempt"], deadline=call["deadline"], cancel_event=cancel).as_dict(),
        })
    out = results
elif phase == "lane":
    results = []
    for scenario in data["scenarios"]:
        prompts, calls, audits, finals = [], [], [], []
        decisions = list(scenario["decisions"])
        outcomes = list(scenario["outcomes"])
        class Session:
            provider = scenario["provider"]
            def decide(self, prompt, timeout):
                prompts.append(prompt)
                if not decisions:
                    raise RuntimeError("no decision")
                return decisions.pop(0)
            def interrupt(self): pass
            def shutdown(self): pass
        class Broker:
            def capabilities(self, incident):
                return tuple(scenario["capabilities"])
            def perform(self, capability, *, incident, process_identity, recovery_generation,
                        attempt, deadline, cancel_event):
                calls.append([capability, attempt, recovery_generation])
                item = outcomes.pop(0)
                return ca.RecoveryBrokerOutcome(item["capability"], item["status"], item["outcome_code"],
                                                health(item["health"]))
        def factory(process_identity, incident_id, generation):
            if scenario.get("fail_launch"):
                raise OSError("no provider")
            return Session()
        def audit(record):
            record = dict(record)
            record.pop("recorded_at")
            assert record.pop("process_identity").startswith("continuity-")
            audits.append(record)
        lane = ca.ContinuityAgentLane(factory, Broker(), on_audit=audit,
            on_result=lambda incident, result: finals.append(result),
            config=ca.ContinuityAgentConfig(**scenario["config"]),
            monotonic=lambda: 0.0, wait=lambda seconds: False)
        first = lane.submit(data["incident"])
        assert lane.wait_until_idle(10)
        second = lane.submit(data["incident"])
        results.append({"submitted": [first, second], "prompts": prompts, "calls": calls,
                        "audits": audits, "finals": finals})
    out = results
elif phase == "context":
    out = [attempt(lambda: cr.RecoveryExecutionContext.from_mapping(item).as_dict()) for item in data]
elif phase == "environment":
    out = [attempt(lambda: ca.continuity_agent_environment(
        "continuity-" + "b" * 32, "inc-0123456789ab", item["generation"],
        parent=data["parent"], provider=item["provider"])) for item in data["cases"]]
elif phase == "backends":
    import os
    os.environ["RELAY_CODEX_MODEL_LIST_JSON"] = data["models"]
    results = []
    for config in data["configs"]:
        create = ca.create_provider_session_factory(config, cwd=data["cwd"])
        session = create("continuity-" + "c" * 32, "inc-0123456789ab", "4")
        if isinstance(session, ca.UnavailableContinuitySession):
            results.append({"provider": session.provider, "unavailable": session.reason_code})
            continue
        backend = session._backend
        results.append({
            "provider": session.provider,
            "spawn": backend.spawn_command(),
            "thread": backend.thread_start_params() if session.provider == "codex" else None,
        })
    out = results
elif phase == "audit":
    for record in data["records"]:
        ca.append_audit_record(Path(data["path"]), record)
    out = True
elif phase == "store_write":
    store = rep.ContinuityReportStore(Path(data["path"]))
    first, _ = store.record_unresolved(data["incidents"][0], "circuit_open")
    store.update_draft(first["report_id"], first["proposals"][0]["id"], {"title": "Edited by Python"})
    second, _ = store.record_unresolved(data["incidents"][1], "Provider_Failed",
                                        proposals=[data["proposal"]])
    store.reject(second["report_id"], second["proposals"][0]["id"])
    out = [first["report_id"], second["report_id"]]
elif phase == "store_read":
    store = rep.ContinuityReportStore(Path(data["path"]))
    out = [store.get(report_id) for report_id in data["ids"]]
print(json.dumps(out, sort_keys=True))
"#;

/// Runs one driver phase over `input`; `None` without a Python.
fn python_phase(root: &TempRoot, phase: &str, input: &Value) -> Option<Value> {
    let python = python()?;
    let path = root.path.join(format!("{phase}.json"));
    fs::write(&path, json::dumps(input)).unwrap();
    let output = run_python(
        &python,
        &root.path,
        DRIVER,
        &[phase, path.to_str().unwrap()],
    );
    Some(json::parse(output.trim()).expect("driver JSON"))
}

fn parse(text: &str) -> Value {
    json::parse(text).unwrap_or_else(|| panic!("bad JSON: {text}"))
}

fn dict(value: &Value) -> Dict {
    value.as_dict().cloned().expect("object")
}

fn assert_same(label: &str, rust: &Value, python: &Value) {
    let (ours, theirs) = (json::dumps_sorted(rust), json::dumps_sorted(python));
    if ours != theirs {
        let position = ours
            .chars()
            .zip(theirs.chars())
            .position(|(a, b)| a != b)
            .unwrap_or(ours.len().min(theirs.len()));
        let start = position.saturating_sub(120);
        panic!(
            "{label} differs at {position}:\n rust:   …{}\n python: …{}",
            ours.chars().skip(start).take(400).collect::<String>(),
            theirs.chars().skip(start).take(400).collect::<String>(),
        );
    }
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
fn the_lifecycle_adapter_matches_the_daemon() {
    let steps = parse(ADAPTER_STEPS);
    let (rust, emitted) = rust_adapter(&steps, &CAPABILITIES);
    assert!(
        emitted.len() >= 5,
        "the scenario emits incidents: {}",
        emitted.len()
    );
    let root = TempRoot::new("continuity-adapter");
    let mut input = Dict::new();
    input.insert("steps", steps);
    input.insert(
        "capabilities",
        list(CAPABILITIES.iter().map(|c| Value::from(*c)).collect()),
    );
    let Some(python) = python_phase(&root, "adapter", &Value::Dict(input)) else {
        return;
    };
    assert!(
        json::dumps(&python).len() > 20_000,
        "the Python scenario ran"
    );
    assert_same("adapter", &rust, &python);
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

// -- sanitising, reports and proposals --------------------------------------

fn incident_variants(base: &Dict) -> Vec<Value> {
    let mut variants = vec![Value::Dict(base.clone())];
    let edit = |change: &dyn Fn(&mut Dict)| {
        let mut copy = base.clone();
        change(&mut copy);
        Value::Dict(copy)
    };
    let timing = |key: &'static str, value: Value| {
        move |copy: &mut Dict| {
            let mut timing = dict(copy.get("timing").unwrap());
            timing.insert(key, value.clone());
            copy.insert("timing", timing);
        }
    };
    variants.push(edit(&|c| {
        c.insert("transcript", "private transcript canary");
        c.insert("prompt", "secret");
    }));
    variants.push(edit(&|c| c.insert("schema_version", true)));
    variants.push(edit(&|c| c.insert("schema_version", 1.0)));
    variants.push(edit(&|c| c.insert("schema_version", 2)));
    variants.push(edit(&|c| c.insert("classification", "transient")));
    variants.push(edit(&|c| c.insert("classification", "recurring")));
    variants.push(edit(&|c| c.insert("command_id", 5)));
    variants.push(edit(&|c| c.insert("recovery_generation", 3)));
    variants.push(edit(&|c| c.insert("recovery_generation", true)));
    variants.push(edit(&|c| c.insert("health", "healthy")));
    variants.push(edit(&|c| c.insert("provider", "gemini")));
    variants.push(edit(&|c| c.insert("incident_id", "inc-xyz")));
    variants.push(edit(&|c| c.insert("fingerprint", "")));
    variants.push(edit(&|c| {
        c.remove("timing");
    }));
    variants.push(edit(&|c| {
        let mut objective = Dict::new();
        objective.insert("unavailable_capability", "made up");
        c.insert("recovery_objective", objective);
    }));
    variants.push(edit(&timing("post_grace_samples", Value::Bool(true))));
    variants.push(edit(&timing("post_grace_samples", Value::Int(-1))));
    variants.push(edit(&timing("failed_native_recovery", Value::Int(1))));
    variants.push(edit(&timing("first_observed_at", Value::from("1"))));
    variants.push(edit(&timing("cooldown_until", Value::Bool(false))));
    variants.push(edit(&timing("grace_deadline", Value::Float(f64::INFINITY))));
    variants.push(Value::List(vec![]));
    variants
}

fn proposal_variants() -> Vec<Value> {
    let base = reports::default_proposal(&dict(&parse(
        r#"{"component": "foreground_provider", "provider": "codex", "incident_id": "inc-0123456789ab"}"#,
    )));
    let mut variants = vec![Value::Dict(base.clone())];
    let edit = |pairs: &[(&str, Value)]| {
        let mut copy = base.clone();
        for (key, value) in pairs {
            copy.insert(key, value.clone());
        }
        Value::Dict(copy)
    };
    variants.push(edit(&[(
        "title",
        Value::from(format!("  {}\n\t end ", "x".repeat(130))),
    )]));
    variants.push(edit(&[(
        "depends_on",
        parse(r#"[" rr-1 ", "", null, 7, "gen-ß"]"#),
    )]));
    variants.push(edit(&[("depends_on", Value::from("RR-1"))]));
    variants.push(edit(&[("depends_on", Value::Null)]));
    variants.push(edit(&[("acceptance_criteria", parse("[]"))]));
    variants.push(edit(&[("acceptance_criteria", parse(r#"["ok", "  "]"#))]));
    variants.push(edit(&[("priority", Value::from(" URGENT "))]));
    variants.push(edit(&[("priority", Value::from("someday"))]));
    variants.push(edit(&[
        ("priority", Value::Null),
        ("worker_effort", Value::from("")),
    ]));
    variants.push(edit(&[("worker_effort", Value::from("max"))]));
    variants.push(edit(&[
        ("worker_effort", Value::from("MAX")),
        ("worker_model", Value::from("Claude:opus")),
    ]));
    variants.push(edit(&[("worker_effort", Value::from("ultra"))]));
    variants.push(edit(&[("worker_model", Value::Null)]));
    variants.push(edit(&[(
        "description",
        Value::from("Read the chain-of-thought."),
    )]));
    variants.push(edit(&[(
        "worker_provider_notes",
        Value::from("token ghp-abcdefghijklmnop"),
    )]));
    variants.push(edit(&[("worker_sizing_rationale", Value::from("   "))]));
    variants.push(edit(&[("title", Value::Int(42))]));
    variants.push(Value::from("not an object"));
    variants
}

#[test]
fn sanitising_reports_and_proposals_match_python() {
    let (_, emitted) = rust_adapter(&parse(ADAPTER_STEPS), &[]);
    let incidents: Vec<Value> = incident_variants(&emitted[0])
        .into_iter()
        .chain(emitted.iter().skip(1).cloned().map(Value::Dict))
        .collect();
    let results = ["circuit_open", " Canceled ", "restored", ""];
    let defaults: Vec<Value> = emitted
        .iter()
        .cloned()
        .map(Value::Dict)
        .chain([parse(
            r#"{"component": "x_y_z", "provider": "none", "incident_id": 3}"#,
        )])
        .collect();
    let proposals = proposal_variants();

    let mut rust = Dict::new();
    rust.insert(
        "bundles",
        list(
            incidents
                .iter()
                .map(|i| attempt(agent::sanitize_incident_bundle(i)))
                .collect(),
        ),
    );
    let mut built = Vec::new();
    for incident in &incidents {
        for result in results {
            built.push(attempt(reports::build_report(incident, result)));
        }
    }
    rust.insert("reports", list(built));
    rust.insert(
        "defaults",
        list(
            defaults
                .iter()
                .map(|item| ok(reports::default_proposal(&dict(item))))
                .collect(),
        ),
    );
    rust.insert(
        "proposals",
        list(
            proposals
                .iter()
                .map(|p| attempt(reports::sanitize_proposal(p)))
                .collect(),
        ),
    );

    let root = TempRoot::new("continuity-sanitize");
    let mut input = Dict::new();
    input.insert("incidents", list(incidents));
    input.insert(
        "results",
        list(results.iter().map(|r| Value::from(*r)).collect()),
    );
    input.insert("defaults", list(defaults));
    input.insert("proposals", list(proposals));
    let Some(python) = python_phase(&root, "sanitize", &Value::Dict(input)) else {
        return;
    };
    assert_same("sanitize", &Value::Dict(rust), &python);
}

// -- the component-owned broker ---------------------------------------------

const BROKER_SPEC: &str = r#"{
 "default_validation": {"validation_token": "fixed_probe", "exact_target_owned": true,
   "liveness": "confirmed_dead", "incident_active": true, "generation_matches": true,
   "command_phase": "none", "command_phase_matches": true, "idempotency_state": "new",
   "compensation_available": false, "cooldown_remaining": 0,
   "health": {"objective_restored": false, "stable_for_seconds": 0.0, "evidence_codes": []}},
 "default_result": {"status": "applied", "outcome_code": "component_restarted",
   "ephemeral_state_created": false, "health_worsened": false,
   "health": {"objective_restored": true, "stable_for_seconds": 3.5,
     "evidence_codes": ["bridge_process_alive", "bridge_heartbeat_fresh", "command_delivered"]}},
 "probe_health": {"objective_restored": true, "stable_for_seconds": 1.0,
   "evidence_codes": ["bridge_process_alive"]},
 "spec": {
   "reconnect_ipc": {"validation": {"exact_target_owned": false}},
   "restore_session_registration": {"validation": {"cooldown_remaining": 2.5}},
   "release_dead_ownership": {"validation": {"liveness": "slow"}},
   "launch_foreground_provider": {"validation": {"liveness": "stalled", "compensation_available": true},
     "result": {"status": "failed", "outcome_code": "launch_failed", "ephemeral_state_created": true},
     "cleanup": true},
   "restart_daemon": {"result": {"health_worsened": true}},
   "reinitialize_speech_capture": {"validation": {"idempotency_state": "applied"}},
   "reinitialize_transcription_delivery": {"validation": {"command_phase": "claimed"}},
   "restart_messenger": {"validation": {"postcondition": "something_else"},
     "result": {"status": "noop", "outcome_code": "already_running", "ephemeral_state_created": true,
       "health_worsened": true}}
 }
}"#;

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

fn broker_calls(incidents: &[Value]) -> Value {
    let mut calls = Vec::new();
    let mut call = |incident: usize, capability: &str, now: f64, extra: &[(&str, Value)]| {
        let generation = dict(&incidents[incident]).string("recovery_generation");
        let mut entry = Dict::new();
        entry.insert("incident", incident as i64);
        entry.insert("capability", capability);
        entry.insert("now", now);
        entry.insert("generation", generation);
        entry.insert("attempt", 1);
        entry.insert("deadline", 1000.0);
        entry.insert("process_identity", PROCESS);
        for (key, value) in extra {
            entry.insert(key, value.clone());
        }
        calls.push(Value::Dict(entry));
    };
    call(0, "restart_bridge", 1.0, &[]);
    call(0, "restart_bridge", 2.0, &[]);
    call(0, "restart_bridge", 3.0, &[]);
    call(0, "reconnect_ipc", 4.0, &[]);
    call(0, "edit_source", 4.0, &[]);
    call(0, "restart_messenger", 4.0, &[]);
    call(0, HEALTH_CHECK, 4.0, &[]);
    call(0, HEALTH_CHECK, 4.0, &[("generation", Value::from("99"))]);
    call(0, HEALTH_CHECK, 4.0, &[("generation", Value::from("-x"))]);
    call(
        0,
        HEALTH_CHECK,
        4.0,
        &[("process_identity", Value::from("continuity-xyz"))],
    );
    call(0, HEALTH_CHECK, 4.0, &[("attempt", Value::Int(0))]);
    call(0, "reinitialize_transcription_delivery", 4.0, &[]);
    call(0, HEALTH_CHECK, 4.0, &[("cancel", Value::Bool(true))]);
    call(0, HEALTH_CHECK, 2000.0, &[]);
    call(1, "release_dead_ownership", 5.0, &[]);
    call(1, "launch_foreground_provider", 5.0, &[]);
    call(1, "reconnect_ipc", 5.0, &[]);
    call(2, "restart_daemon", 6.0, &[]);
    call(2, "reconnect_ipc", 6.0, &[]);
    call(3, "restart_messenger", 7.0, &[]);
    call(3, "reconnect_ipc", 7.0, &[]);
    call(4, "reinitialize_speech_capture", 8.0, &[]);
    call(5, "reinitialize_transcription_delivery", 9.0, &[]);
    call(6, "restore_session_registration", 9.0, &[]);
    call(6, "launch_foreground_provider", 9.0, &[]);
    call(6, "release_dead_ownership", 9.0, &[]);
    Value::List(calls)
}

fn rust_broker(spec: &Dict, incidents: &[Value], calls: &Value, owners: Option<&[&str]>) -> Value {
    let clock = Arc::new(Mutex::new(0.0_f64));
    let mut capabilities = BTreeMap::new();
    let entries = dict(spec.get("spec").unwrap());
    for (name, _) in CAPABILITY_POLICIES
        .iter()
        .filter(|(n, _)| *n != HEALTH_CHECK)
    {
        let entry = entries
            .get(name)
            .and_then(Value::as_dict)
            .cloned()
            .unwrap_or_default();
        let mut validation = dict(spec.get("default_validation").unwrap());
        if let Some(over) = entry.get("validation").and_then(Value::as_dict) {
            validation.update(over);
        }
        let mut result = dict(spec.get("default_result").unwrap());
        if let Some(over) = entry.get("result").and_then(Value::as_dict) {
            result.update(over);
        }
        let cleanup = entry.get("cleanup").is_some_and(Value::truthy);
        let inspect = move |request: &RecoveryActionRequest| {
            let v = &validation;
            RecoveryActionValidation {
                validation_token: v.string("validation_token"),
                exact_target_owned: v.get("exact_target_owned").unwrap().truthy(),
                liveness: v.string("liveness"),
                incident_active: v.get("incident_active").unwrap().truthy(),
                generation_matches: v.get("generation_matches").unwrap().truthy(),
                command_phase: v.string("command_phase"),
                command_phase_matches: v.get("command_phase_matches").unwrap().truthy(),
                idempotency_state: v.string("idempotency_state"),
                compensation_available: v.get("compensation_available").unwrap().truthy(),
                cooldown_remaining: v.get("cooldown_remaining").unwrap().py_float().unwrap(),
                expected_postcondition: v
                    .get("postcondition")
                    .map_or_else(|| request.expected_postcondition.clone(), Value::py_str),
                health: health_from(v.get("health").unwrap()),
            }
            .validated()
        };
        let execute = move |_: &RecoveryActionRequest, _: &RecoveryActionValidation, _: &Event| {
            RecoveryActionResult {
                status: result.string("status"),
                outcome_code: result.string("outcome_code"),
                health: health_from(result.get("health").unwrap()),
                ephemeral_state_created: result.get("ephemeral_state_created").unwrap().truthy(),
                health_worsened: result.get("health_worsened").unwrap().truthy(),
            }
            .validated()
        };
        capabilities.insert(
            name.to_string(),
            ProductionRecoveryCapability {
                inspect: Arc::new(inspect),
                execute: Arc::new(execute),
                cleanup: Some(Arc::new(move |_: &RecoveryActionRequest| Ok(cleanup))),
            },
        );
    }
    let probe = health_from(spec.get("probe_health").unwrap());
    let mut registry: RecoveryOwners =
        production_recovery_owners(Arc::new(move |_| Ok(probe.clone())), &capabilities).unwrap();
    if let Some(names) = owners {
        registry.retain(|name, _| names.contains(&name.as_str()));
    }
    let reader = Arc::clone(&clock);
    let broker = ComponentOwnedRecoveryBroker::new(
        registry,
        Some(Arc::new(move || *reader.lock().unwrap())),
    )
    .unwrap();
    let mut results = Vec::new();
    for call in calls.as_list().unwrap() {
        let call = dict(call);
        *clock.lock().unwrap() = call.get("now").unwrap().py_float().unwrap();
        let cancel = Event::new();
        if call.get("cancel").is_some_and(Value::truthy) {
            cancel.set();
        }
        let incident = dict(&incidents[call.get("incident").unwrap().py_int().unwrap() as usize]);
        let offered = broker.capabilities(&incident).unwrap();
        let outcome = broker
            .perform(
                &call.string("capability"),
                BrokerCall {
                    incident: incident.clone(),
                    process_identity: call.string("process_identity"),
                    recovery_generation: call.string("generation"),
                    attempt: call.get("attempt").unwrap().py_int().unwrap(),
                    deadline: call.get("deadline").unwrap().py_float().unwrap(),
                    cancel,
                },
            )
            .unwrap();
        let mut entry = Dict::new();
        entry.insert("capabilities", strings(&offered));
        entry.insert("outcome", outcome.as_dict());
        results.push(Value::Dict(entry));
    }
    Value::List(results)
}

#[test]
fn the_component_owned_broker_matches_python() {
    let spec = dict(&parse(BROKER_SPEC));
    let incidents = broker_incidents();
    let calls = broker_calls(&incidents);
    let root = TempRoot::new("continuity-broker");
    for owners in [None, Some(&["app"][..])] {
        let rust = rust_broker(&spec, &incidents, &calls, owners);
        let mut input = spec.clone();
        input.insert("incidents", list(incidents.clone()));
        input.insert("calls", calls.clone());
        input.insert(
            "owners",
            owners.map_or(Value::Null, |names| {
                list(names.iter().map(|n| Value::from(*n)).collect())
            }),
        );
        let Some(python) = python_phase(&root, "broker", &Value::Dict(input)) else {
            return;
        };
        assert_same("broker", &rust, &python);
    }
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
fn the_agent_lane_matches_python_for_both_providers() {
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
    let root = TempRoot::new("continuity-lane");
    let mut input = Dict::new();
    input.insert("scenarios", scenarios);
    input.insert("incident", incident);
    let Some(python) = python_phase(&root, "lane", &Value::Dict(input)) else {
        return;
    };
    assert_same("lane", &rust, &python);
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
fn execution_contexts_parse_like_python() {
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
    let root = TempRoot::new("continuity-context");
    let Some(python) = python_phase(&root, "context", &list(payloads)) else {
        return;
    };
    assert_same("context", &rust, &python);
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
    let mut input = Dict::new();
    let mut parent_dict = Dict::new();
    for (key, value) in &parent {
        parent_dict.insert(key, value.as_str());
    }
    input.insert("parent", parent_dict);
    input.insert(
        "cases",
        list(
            cases
                .iter()
                .map(|(provider, generation)| {
                    let mut case = Dict::new();
                    case.insert("provider", *provider);
                    case.insert("generation", *generation);
                    Value::Dict(case)
                })
                .collect(),
        ),
    );
    let root = TempRoot::new("continuity-environment");
    let Some(python) = python_phase(&root, "environment", &Value::Dict(input)) else {
        return;
    };
    assert_same("environment", &rust, &python);
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
fn codex_and_claude_launch_lines_match_python() {
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
    let mut input = Dict::new();
    input.insert("configs", configs);
    input.insert("cwd", cwd.as_str());
    input.insert("models", MODELS);
    let Some(python) = python_phase(&root, "backends", &Value::Dict(input)) else {
        return;
    };
    assert_same("backends", &rust, &python);
}

// -- files and rows shared with the Python daemon ----------------------------

#[test]
fn audit_lines_are_byte_identical() {
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
    let theirs = root.path.join("python/continuity_agent_events.jsonl");
    let mut input = Dict::new();
    input.insert("path", theirs.to_string_lossy().as_ref());
    input.insert(
        "records",
        list(records.into_iter().map(Value::Dict).collect()),
    );
    if python_phase(&root, "audit", &Value::Dict(input)).is_none() {
        return;
    }
    assert_eq!(fs::read(&ours).unwrap(), fs::read(&theirs).unwrap());
    assert_eq!(
        fs::metadata(&theirs).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[test]
fn reports_written_by_either_daemon_read_the_same() {
    let incidents = broker_incidents();
    let root = TempRoot::new("continuity-reports");
    let path = root.data_root().join("continuity_reports.db");
    let proposal = Value::Dict(reports::default_proposal(&dict(&incidents[1])));

    // Python writes; Rust reads what Python reads.
    let mut write = Dict::new();
    write.insert("path", path.to_string_lossy().as_ref());
    write.insert("incidents", list(incidents[..2].to_vec()));
    write.insert("proposal", proposal);
    let Some(ids) = python_phase(&root, "store_write", &Value::Dict(write)) else {
        return;
    };
    let mut read = Dict::new();
    read.insert("path", path.to_string_lossy().as_ref());
    read.insert("ids", ids.clone());
    let python_view = python_phase(&root, "store_read", &Value::Dict(read.clone())).unwrap();
    let store = ContinuityReportStore::open(&path).unwrap();
    let rust_view = list(
        ids.as_list()
            .unwrap()
            .iter()
            .map(|id| Value::Dict(store.get(&id.py_str()).unwrap().unwrap()))
            .collect(),
    );
    assert_same("python-written reports", &rust_view, &python_view);
    let first = dict(&rust_view.as_list().unwrap()[0]);
    let draft = dict(
        dict(&first.get("proposals").unwrap().as_list().unwrap()[0])
            .get("draft")
            .unwrap(),
    );
    assert_eq!(draft.string("title"), "Edited by Python");

    // Rust writes over the same file; Python reads what Rust reads.
    let (report, recorded) =
        reports::record_unresolved(&store, &incidents[2], " CANCELED", None).unwrap();
    assert!(recorded);
    let (again, recorded) =
        reports::record_unresolved(&store, &incidents[2], "canceled", None).unwrap();
    assert!(!recorded);
    assert_same(
        "idempotent report",
        &Value::Dict(again),
        &Value::Dict(report.clone()),
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
    let mut all_ids = ids.as_list().unwrap().to_vec();
    all_ids.push(Value::from(report_id.as_str()));
    read.insert("ids", list(all_ids.clone()));
    let python_view = python_phase(&root, "store_read", &Value::Dict(read)).unwrap();
    let rust_view = list(
        all_ids
            .iter()
            .map(|id| Value::Dict(store.get(&id.py_str()).unwrap().unwrap()))
            .collect(),
    );
    assert_same("rust-written reports", &rust_view, &python_view);
}
