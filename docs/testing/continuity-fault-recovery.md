# Continuity fault recovery verification

Run the deterministic RR-332 through RR-335 integration matrix with the project-compatible Python interpreter:

```sh
python3 services/continuity_fault_harness.py
```

The matrix injects transcription dropout, capture interruption, bridge loss, messenger crash, Codex and Claude provider hang/exit, daemon and IPC loss, stale session ownership, explicit provider fallback, simultaneous faults, and recovery-budget exhaustion. It drives the production incident detector, isolated continuity-agent lane, component-owned broker, durable intent inbox, canonical bridge handoff, and unresolved-report store. The JSON result fails unless every recoverable case records one classification, one agent launch, one broker action, restored health, and a canonical repeat/resume/reattach handoff without a manual session restart.

Every safety count is derived from the append-only effect ledger rather than the planned handoff. Resumable commands and repeat TTS must produce exactly one expected effect; stale replies, continuity-agent speech, and project mutations must produce none. Duplicate handoff and stale-generation probes exercise the production idempotency gates, while adversarial tests prove that an injected duplicate command effect or filesystem mutation fails the matrix. Private canaries must not reach prompts, durable events, reports, or proposals. Budget exhaustion must persist an unresolved sanitized report with draft permanent-fix proposals.

## Signed mounted app lane

Automated source evidence does not establish a signed mounted app or audible output. With a Developer ID signed app and authenticated real Codex and Claude sessions, record one complete recovered voice scenario per provider in a privacy-safe continuity JSONL file. Every event uses one stable `scenario_id`, provider, command sequence/id, and the recovery events use one exact `recovery_generation`, incident ID, opaque session ID, and opaque command ID. Required events are `speech_captured`, `transcript_captured`, `incident_classified`, `continuity_agent_launched`, `broker_result`, `continuity_agent_completed`, canonical `continuity_resume`, `command_accepted`, `command_completed`, and `audible_playback_attested`. The broker result must contain production `broker_outcome` evidence for at least 60 seconds of restored health; the completion and handoff must both report `restored`, and the handoff must record the canonical bridge's `resume_exact` or `reattach` action. The audible attestation must name the exact play-request and utterance IDs from the speech log. Preserve the corresponding terminal-delivery and speech logs, then run:

```sh
python3 scripts/continuity-mounted-verification.py \
  --app '/Applications/Relay Runner.app' \
  --continuity-log /tmp/relay_continuity_mounted_events.jsonl \
  --delivery-log /tmp/relay_terminal_delivery_events.jsonl \
  --speech-log /tmp/relay_speech_events.jsonl
```

The mounted gate verifies the Developer ID identity and correlates each provider's production incident classification, continuity-agent process, broker outcome, restored stable health, canonical recovery handoff, command lifecycle, unique terminal provider acknowledgement, play-request ID, utterance ID, `afplay_started`, and human audible-playback attestation. Healthy non-recovery paths, duplicate effects, and mixed provider, generation, incident, session, or command evidence fail closed. `afplay_started` remains process evidence rather than proof that sound was audible, so the default result stays `verification_blocked` until the matching attestation is recorded and the human reruns with `--physical-audio-attested`.

Keep the three evidence classes separate in the ticket run log:

- automated source: deterministic suites and their counts;
- mounted app: exact Developer ID and Codex/Claude correlation result;
- physical audio: human audible-playback attestation, or the exact unavailable condition and resume action.
