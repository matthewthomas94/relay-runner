# Provider-turn fault matrix

Run the deterministic lifecycle matrix from the repository root:

```sh
python3 services/provider_turn_fault_harness.py
```

The matrix runs Codex and Claude through the same ownership contract. It injects
Messenger, foreground-provider, daemon, bridge, and Swift consumer restarts at
accepted, delivered, claimed, acknowledgement-delayed, acknowledged, terminal,
and effect-reserved boundaries. Every component owns a distinct file-backed
runtime generation and must recover the same durable turn identity before the
scenario can continue. The matrix also duplicates terminal callbacks and
competing outputs, then revokes turns through cancellation and replacement
before attempting a late effect and after reserving an effect but before
delivery authorization. A revoked reservation must persist as failed without a
Messenger or TTS submission. Once delivery authorization commits, later
revocation is too late and the external submission can be finalized truthfully.

The harness fails unless each normal turn has one claim, one terminal inbox
acknowledgement, one provider-terminal transition, and one delivered effect.
Diagnostics are capped at 100 records and allowlist only provider, component,
boundary, invariant, expected, and observed values. Fixture prompt text and
filesystem paths are never reported. The deterministic p95 uses only finite
timestamps observed in the durable acknowledged intent and delivered effect
records; missing, boolean, NaN, or infinite values fail the sample-count
invariant instead of being synthesized or coerced.

Codex and Claude intentionally differ only at their native hook adapters. Once
an adapter supplies native session and turn identity plus the shared foreground
ownership envelope, both providers use the same broker, restart, cancellation,
effect, and latency assertions.

## Mounted acceptance

The deterministic matrix does not replace a signed-app run with the real Codex
and Claude clients. For each provider, accept one current voice turn, play its
retained authoritative result, then preserve the privacy-safe terminal delivery
and speech event logs. The accepted playback must correlate one command
sequence/id, one play-request id, one utterance id, one `provider_acknowledged`,
and one `afplay_started` event, with no second authoritative effect.

Measure the mounted acknowledgement-to-playback latency from the speech log:

```sh
python3 scripts/speech-latency-report.py /tmp/relay_speech_events.jsonl --json
```

The mounted gate passes only when both providers have complete correlated
samples, no duplicate accepted effect, and
`ack_to_first_audio_p95_ms <= 500`.
