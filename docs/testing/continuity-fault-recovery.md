# Continuity fault recovery verification

Run the deterministic RR-332 through RR-335 integration matrix with the project-compatible Python interpreter:

```sh
python3 services/continuity_fault_harness.py
```

The matrix injects transcription dropout, capture interruption, bridge loss, messenger crash, Codex and Claude provider hang/exit, daemon and IPC loss, stale session ownership, explicit provider fallback, simultaneous faults, and recovery-budget exhaustion. It drives the production incident detector, isolated continuity-agent lane, stable-health gate, foreground resume planner, and unresolved-report store. The JSON result fails unless every recoverable case records one classification, one agent launch, one broker action, restored health, and a canonical repeat/resume/reattach handoff without a manual session restart.

The safety assertions cap command execution and repeat TTS at one, keep stale and continuity-agent speech at zero, retain exact command/intent identity, and inject private canaries that must not reach prompts, audit evidence, reports, or proposals. Budget exhaustion must persist an unresolved sanitized report with draft permanent-fix proposals.

## Signed mounted app lane

Automated source evidence does not establish a signed mounted app or audible output. With a Developer ID signed app and authenticated real Codex and Claude sessions, record one complete voice scenario per provider in a privacy-safe continuity JSONL file. Each scenario uses a stable `scenario_id`, provider, command sequence/id, and these events: `speech_captured`, `transcript_captured`, `command_accepted`, and `command_completed`. Preserve the corresponding terminal-delivery and speech logs, then run:

```sh
python3 scripts/continuity-mounted-verification.py \
  --app '/Applications/Relay Runner.app' \
  --continuity-log /tmp/relay_continuity_mounted_events.jsonl \
  --delivery-log /tmp/relay_terminal_delivery_events.jsonl \
  --speech-log /tmp/relay_speech_events.jsonl
```

The mounted gate verifies the Developer ID identity and correlates each provider's capture, transcript, command lifecycle, unique provider acknowledgement, play-request ID, utterance ID, and `afplay_started`. Duplicate acknowledgements or playback fail closed. `afplay_started` is process evidence, not proof that sound was audible, so the default result remains `verification_blocked` until a human completes the physical-audio check and reruns with `--physical-audio-attested`.

Keep the three evidence classes separate in the ticket run log:

- automated source: deterministic suites and their counts;
- mounted app: exact Developer ID and Codex/Claude correlation result;
- physical audio: human audible-playback attestation, or the exact unavailable condition and resume action.
