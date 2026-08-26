# Provider-turn fault matrix

Build the focused Swift projection consumer, then run the lifecycle matrix from
the repository root:

```sh
swift test --filter RelayVoiceCommandDeliveryTests/testRestartFaultMatrixEmitsEvidence
python3 services/provider_turn_fault_harness.py
```

The matrix runs Codex and Claude through the same ownership contract. It injects
Messenger, foreground-provider, daemon, bridge, and Swift consumer restarts at
accepted, delivered, claimed, acknowledgement-delayed, acknowledged, terminal,
and effect-reserved boundaries. It restarts the production `MessengerRuntime`,
completion-hook adapter, `IntentInbox`, and bridge-owned
`ProviderTurnBroker`/`SpeechCoordinator` objects. The harness invokes the focused
Swift test with `--skip-build` and consumes evidence emitted by the real
`RelayVoiceCommandDelivery` projection consumer; it does not create Swift
restart evidence in Python. Each replacement must recover the same durable turn
identity before the scenario can continue.

The matrix also duplicates terminal callbacks and competing outputs, then
revokes turns through cancellation and replacement before attempting a late
effect and after reserving an effect but before delivery authorization. A
revoked reservation must persist as failed without a Messenger or TTS
submission. Once delivery authorization commits, later revocation is too late
and the external submission can be finalized truthfully.

The harness fails unless each normal turn has one claim, one terminal inbox
acknowledgement, one provider-terminal transition, and one delivered effect.
Diagnostics are capped at 100 records and allowlist only provider, component,
boundary, invariant, expected, and observed values. Fixture prompt text and
filesystem paths are never reported. The p95 uses only finite timestamps emitted
by the durable inbox acknowledgement and the real `SpeechCoordinator`
`afplay_started` observer path. Missing, boolean, NaN, or infinite values fail
the sample-count invariant instead of being synthesized, coerced, or replaced
with an acknowledgement-plus-constant fixture.

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

Measure mounted acknowledgement-to-playback latency by correlating the terminal
delivery log's `provider_acknowledged.timestamp` with the speech log's
`afplay_started.at` through command, play-request, and utterance identities:

```sh
python3 scripts/speech-latency-report.py /tmp/relay_speech_events.jsonl \
  --delivery-log /tmp/relay_terminal_delivery_events.jsonl --json
```

The mounted gate passes only when both providers have complete correlated
samples, no duplicate accepted effect, and
`ack_to_first_audio_p95_ms <= 500`. An Option gesture is not required: a mounted
resume sample is valid when the terminal acknowledgement and a unique
`afplay_started` record have the required privacy-safe identities. The exact
RR-325 reporter contract requires that playback record to carry
`authoritative: true`, `kind: final`, a non-empty `source` and `lifecycle_role`,
the acknowledged command sequence/id, and non-empty play-request and utterance
ids. Exactly one authoritative playback may exist for that command. Messenger
handoffs and other non-authoritative conversation are excluded from both sample
selection and duplicate-authoritative-effect counting.

The report is process evidence: it proves that the correlated `afplay` process
started and measures that boundary, but it cannot prove that a person heard the
audio. Human audible attestation is a separate mounted acceptance record and
must not be inferred from `afplay_started` alone.

The remaining physical gate is exact: a signed Relay Runner app with
authenticated real Codex and Claude clients is unavailable in an isolated
worker run, so real-audio playback and correlated `afplay_started` evidence
cannot be captured there.
