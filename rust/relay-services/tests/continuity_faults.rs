//! The daemon half of `services/continuity_fault_harness.py`'s fault matrix
//! (RR-499): every fault case runs detector → agent lane → component-owned
//! broker → report, for Codex and Claude continuity agents alike. A restored
//! case runs each fixed recovery action at most once; an unresolved one
//! leaves exactly one privacy-safe report with a reviewable draft. The
//! harness's bridge half (intent inbox, resume, speech) belongs to the voice
//! bridge in relay-rs and is not repeated here.

mod common;

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use relay_intents::json::{self, Dict, Value};
use relay_services::continuity::agent::{
    ContinuityAgentLane, ContinuityProviderSession, LaneOptions, RecoveryHealthEvidence,
    SessionFactory,
};
use relay_services::continuity::incidents::{
    ContinuityIncidentDetector, DetectorConfig, Emit, Observation, objective,
};
use relay_services::continuity::recovery::{
    CAPABILITY_POLICIES, ComponentOwnedRecoveryBroker, HEALTH_CHECK, ProductionRecoveryCapability,
    RecoveryActionRequest, RecoveryActionResult, RecoveryActionValidation,
    production_recovery_owners,
};
use relay_services::continuity::{Event, opaque_identifier, reports};
use relay_store::continuity::ContinuityReportStore;

use common::TempRoot;

/// `FAULT_CASES`: name, component, phase, provider, agent provider, result.
/// `(name, component, phase, provider, agent provider, recovery result)`.
type FaultCase = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    Option<&'static str>,
    &'static str,
);

const FAULT_CASES: [FaultCase; 14] = [
    (
        "transcription_dropout",
        "transcription",
        "transcription",
        "none",
        None,
        "restored",
    ),
    (
        "capture_interruption",
        "speech_capture",
        "capture",
        "none",
        None,
        "restored",
    ),
    (
        "bridge_loss",
        "bridge",
        "delivery",
        "none",
        None,
        "restored",
    ),
    (
        "messenger_crash",
        "messenger",
        "component_liveness",
        "codex",
        None,
        "restored",
    ),
    (
        "foreground_codex_hang",
        "foreground_provider",
        "provider_turn",
        "codex",
        None,
        "restored",
    ),
    (
        "foreground_codex_exit",
        "foreground_provider",
        "provider_turn",
        "codex",
        None,
        "restored",
    ),
    (
        "foreground_claude_hang",
        "foreground_provider",
        "provider_turn",
        "claude",
        None,
        "restored",
    ),
    (
        "foreground_claude_exit",
        "foreground_provider",
        "provider_turn",
        "claude",
        None,
        "restored",
    ),
    (
        "daemon_loss",
        "daemon",
        "component_liveness",
        "none",
        None,
        "restored",
    ),
    (
        "ipc_loss",
        "orchestrator",
        "component_liveness",
        "none",
        None,
        "restored",
    ),
    (
        "stale_session_ownership",
        "session",
        "session_liveness",
        "codex",
        None,
        "restored",
    ),
    (
        "configured_provider_fallback",
        "foreground_provider",
        "provider_turn",
        "codex",
        Some("claude"),
        "restored",
    ),
    (
        "simultaneous_component_faults",
        "bridge",
        "delivery",
        "none",
        None,
        "restored",
    ),
    (
        "recovery_budget_exhaustion",
        "bridge",
        "delivery",
        "none",
        None,
        "circuit_open",
    ),
];

const PRIVATE_CANARIES: [&str; 3] = [
    "private transcript canary",
    "private credential canary",
    "/private/repository/canary",
];
const FORBIDDEN_REPORT_KEYS: [&str; 10] = [
    "audio",
    "credential",
    "external_data",
    "prompt",
    "provider_output",
    "raw_log",
    "repository",
    "screenshot",
    "source_command",
    "transcript",
];

fn incident(case: usize, component: &str, phase: &str, provider: &str) -> Dict {
    let emitted: Arc<Mutex<Vec<Dict>>> = Arc::default();
    let sink = Arc::clone(&emitted);
    let emit: Emit = Box::new(move |envelope| sink.lock().unwrap().push(envelope.clone()));
    let mut detector = ContinuityIncidentDetector::new(DetectorConfig::default(), Some(emit));
    let observation = Observation {
        session_id: opaque_identifier("session", &format!("fault-session-{case}")).unwrap(),
        command_id: Some(opaque_identifier("command", &format!("fault-command-{case}")).unwrap()),
        component: component.to_string(),
        provider: provider.to_string(),
        recovery_generation: format!("gen-{case}"),
        phase: phase.to_string(),
        health: "recovery_failed".to_string(),
        observed_at: 1_000.0 + case as f64,
        native_recovery_failed: true,
    }
    .validated()
    .unwrap();
    let result = detector.observe(&observation, None).unwrap();
    assert_eq!(result.state, "stalled");
    let mut envelope = emitted.lock().unwrap().pop().expect("an incident envelope");
    // Native components may attach private material; the lane must drop it.
    envelope.insert("transcript", PRIVATE_CANARIES[0]);
    envelope.insert("credential", PRIVATE_CANARIES[1]);
    envelope.insert("repository", PRIVATE_CANARIES[2]);
    envelope
}

struct Agent {
    provider: String,
    escalate: bool,
}

impl ContinuityProviderSession for Agent {
    fn provider(&self) -> String {
        self.provider.clone()
    }

    fn decide(&self, prompt: &str, _timeout: f64) -> relay_services::Result<String> {
        for canary in PRIVATE_CANARIES {
            assert!(
                !prompt.contains(canary),
                "private material reached the provider"
            );
        }
        if self.escalate {
            return Ok(r#"{"kind":"finish","result":"escalate"}"#.to_string());
        }
        let state = prompt.split("Recovery state:\n").nth(1).unwrap();
        let state = json::parse(state).unwrap();
        let offered = state.as_dict().unwrap().get("broker_capabilities").unwrap();
        let capability = offered
            .as_list()
            .unwrap()
            .iter()
            .map(Value::py_str)
            .find(|capability| capability != HEALTH_CHECK)
            .unwrap_or_else(|| HEALTH_CHECK.to_string());
        Ok(format!(
            r#"{{"kind":"broker_call","capability":"{capability}"}}"#
        ))
    }

    fn interrupt(&self) -> relay_services::Result<()> {
        Ok(())
    }

    fn shutdown(&self) -> relay_services::Result<()> {
        Ok(())
    }
}

type Executions = Arc<Mutex<HashMap<String, usize>>>;

fn owners(executions: &Executions) -> relay_services::continuity::recovery::RecoveryOwners {
    let mut capabilities = BTreeMap::new();
    for (name, _) in CAPABILITY_POLICIES
        .iter()
        .filter(|(n, _)| *n != HEALTH_CHECK)
    {
        let counter = Arc::clone(executions);
        capabilities.insert(
            name.to_string(),
            ProductionRecoveryCapability {
                inspect: Arc::new(|request: &RecoveryActionRequest| {
                    RecoveryActionValidation {
                        validation_token: "fault_matrix_owner".into(),
                        exact_target_owned: true,
                        liveness: "confirmed_dead".into(),
                        incident_active: true,
                        generation_matches: true,
                        command_phase: "none".into(),
                        command_phase_matches: true,
                        idempotency_state: "new".into(),
                        compensation_available: false,
                        cooldown_remaining: 0.0,
                        expected_postcondition: request.expected_postcondition.clone(),
                        health: RecoveryHealthEvidence::default(),
                    }
                    .validated()
                }),
                execute: Arc::new(
                    move |request: &RecoveryActionRequest,
                          _: &RecoveryActionValidation,
                          _: &Event| {
                        *counter
                            .lock()
                            .unwrap()
                            .entry(request.idempotency_key.clone())
                            .or_default() += 1;
                        let restored = objective(&request.component).unwrap().restored_when;
                        RecoveryActionResult::new(
                            "applied",
                            "component_recovered",
                            RecoveryHealthEvidence::new(true, 60.0, restored)?,
                        )
                    },
                ),
                cleanup: None,
            },
        );
    }
    production_recovery_owners(
        Arc::new(|_| Ok(RecoveryHealthEvidence::default())),
        &capabilities,
    )
    .unwrap()
}

#[test]
fn every_fault_restores_or_escalates_without_duplicate_effects() {
    let root = TempRoot::new("continuity-faults");
    let store = Arc::new(
        ContinuityReportStore::open(&root.data_root().join("continuity_reports.db")).unwrap(),
    );
    for (index, (name, component, phase, provider, agent_provider, expected)) in
        FAULT_CASES.iter().enumerate()
    {
        let executions: Executions = Arc::default();
        let finals: Arc<Mutex<Vec<String>>> = Arc::default();
        let reports_seen: Arc<Mutex<Vec<Dict>>> = Arc::default();
        let agent = agent_provider.map(str::to_string).unwrap_or_else(|| {
            if *provider == "none" {
                ["codex", "claude"][index % 2]
            } else {
                provider
            }
            .to_string()
        });
        let escalate = *expected != "restored";
        let factory: SessionFactory = Arc::new(move |_, _, _| {
            Ok(Arc::new(Agent {
                provider: agent.clone(),
                escalate,
            }) as Arc<dyn ContinuityProviderSession>)
        });
        let broker =
            Arc::new(ComponentOwnedRecoveryBroker::new(owners(&executions), None).unwrap());
        let (final_sink, report_store, report_sink) = (
            Arc::clone(&finals),
            Arc::clone(&store),
            Arc::clone(&reports_seen),
        );
        let lane = ContinuityAgentLane::new(
            factory,
            broker,
            Arc::new(|_: &Dict| Ok(())),
            LaneOptions {
                on_result: Some(Arc::new(move |incident: &Dict, result: &str| {
                    final_sink.lock().unwrap().push(result.to_string());
                    if result != "restored" {
                        let (report, _) = reports::record_unresolved(
                            &report_store,
                            &Value::Dict(incident.clone()),
                            result,
                            None,
                        )?;
                        report_sink.lock().unwrap().push(report);
                    }
                    Ok(())
                })),
                ..LaneOptions::default()
            },
        );
        let mut submitted = vec![incident(index, component, phase, provider)];
        if *name == "simultaneous_component_faults" {
            submitted.push(incident(
                100 + index,
                "messenger",
                "component_liveness",
                "claude",
            ));
        }
        for envelope in &submitted {
            assert!(
                ["launched", "single_flight"]
                    .contains(&lane.submit(&Value::Dict(envelope.clone())).unwrap()),
                "{name}"
            );
        }
        assert!(lane.wait_until_idle(10.0), "{name} settles");
        let finals = finals.lock().unwrap().clone();
        assert_eq!(
            finals,
            vec![expected.to_string(); submitted.len()],
            "{name}"
        );
        let executions = executions.lock().unwrap();
        assert!(
            executions.values().all(|count| *count == 1),
            "{name}: duplicate recovery effect {executions:?}"
        );
        if escalate {
            assert!(executions.is_empty(), "{name}");
            let reports = reports_seen.lock().unwrap();
            assert_eq!(reports.len(), 1, "{name}");
            let report = &reports[0];
            let text = json::dumps(&Value::Dict(report.clone()));
            for canary in PRIVATE_CANARIES {
                assert!(
                    !text.contains(canary),
                    "{name}: private material in the report"
                );
            }
            let incident = report.get("incident").unwrap().as_dict().unwrap();
            for key in FORBIDDEN_REPORT_KEYS {
                assert!(
                    incident.get(key).is_none() && report.get(key).is_none(),
                    "{name}: {key}"
                );
            }
            // The lane already dropped the private fields, as in Python, so the
            // report it hands over has nothing left to redact.
            assert_eq!(report.get("redaction_count").unwrap().py_int(), Some(0));
            let proposals = report.get("proposals").unwrap().as_list().unwrap();
            assert_eq!(proposals.len(), 1);
            assert_eq!(proposals[0].as_dict().unwrap().string("state"), "draft");
        } else {
            assert_eq!(executions.len(), submitted.len(), "{name}");
        }
        lane.shutdown();
    }
}
