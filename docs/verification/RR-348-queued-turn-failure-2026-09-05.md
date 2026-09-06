# RR-348 installed Codex queue UAT failure — 2026-09-05

## Observation

The user submitted three separate natural voice requests: tracked file count,
current branch, and latest commit subject. Only the count result (769) was
heard. All three requests were captured; the second and third remained pending
after the first provider turn completed. This is a failed queued-audio UAT,
not evidence that STT missed the latter requests.

Installed build provenance is recorded in the RR-346 latency report: source
`320784d`, including RR-348 implementation `79929e3`. Auto-play was enabled.
At inspection the app PID was 81667 and embedded Codex PID 95058, started
2026-09-05T11:10:08Z. The existing bridge PID 83685 dated from the earlier
2026-09-05T10:21:07Z session start.

## Correlated records

| Sequence | Command ID | Durable inbox | Provider turn | Final audio |
| --- | --- | --- | --- | --- |
| 79 | `83685-1788610099861321000-79` | claimed, no ack timestamp | completed_final, delivery sent | Played; user heard 769 |
| 80 | `83685-1788610104616455000-80` | pending, no delivery or claim timestamp | No matching record | No final audio event |
| 81 | `83685-1788610111970729000-81` | pending, no delivery or claim timestamp | No matching record | No final audio event |

The first provider record was created at `1788610100.606001` and terminalized
at `1788610133.3944068`, with origin `relay`, state `completed_final`, and
release reason `provider_stop`. There was no phantom manual record in this
test's provider-turn rows. The terminal delivery event log stops at sequence
79's delivery acknowledgment; it contains no submissions for 80 or 81.

The count's fallback final utterance `877dd71d-1982-4e94-91dc-68a92407311c`
started audio at `1788610134.3448179` and reached played at
`1788610137.868681`. Messenger handoffs for 79 and 80 were accepted then
canceled before queueing; sequence 81's handoff reached played. The user
reported only the count answer, so the handoff event is not treated as human
confirmation of the missing branch or commit results.

## Diagnostic cause and boundary

The running bridge launch job retained provider-session ID
`96b13107-5875-4d1b-8fbd-0785eb57afbf`, whereas the current provider-session
file and sequence 79's completed record use
`018dd771-9fc1-4475-8d61-4d5b772a42d8`. The app-session identity in both the
job arguments and record is `227410d0-6469-4a8b-bc56-0327aa813f66`.

In `voice_bridge.py`, `_provider_turn_seen` delegates to `_provider_turn_state`,
which filters by the provider-session ID captured at module startup. The inbox
pump therefore cannot acknowledge a matching command whose provider session
changed. The durable inbox remains claimed, blocking materialization of the
two pending requests. `reconcile_terminal_claims` only handles review-required
claims, not this ordinary claimed state. Together these explain the observed
stranded queue; they do not authorize weakening cross-session protections.

No runtime records were cleared, prompts injected, queue entries canceled, or
processes restarted during diagnosis. Repair must reconcile an authenticated,
exact app/provider ownership transition, preserve real manual-turn barriers,
and drain each pending intent exactly once. Keep stale/foreign-session cases
fail-closed, test both provider adapters, and isolate test sockets from the live
app. User-confirmed installed Codex queue UAT remains required after repair;
Claude live UAT remains deferred, not passed.

## Rebuilt installation — 2026-09-06

The standard build script completed from clean source
`d08c93cf43ee8d55afaaf11449da54bfcce75478`, including run 109's provider-handoff
fix `9785b5f`. Ad-hoc signing was selected explicitly; no Developer ID or
notarization requirement was reinstated. Deep strict signature verification
passed for both staged and installed bundles.

The old app and bridge were already stopped. The old installed app was moved
to `/tmp/relay-runner-pre-d08c93c.ty0dw3/Relay Runner.app`, and the new bundle
was installed at `/Applications/Relay Runner.app` and launched. Auto-play was
enabled. Settings and tickets were not reset.

Build/installed executable SHA-256 matched:
`7548db842263a7bcdb8591159dc6f66951f31a597d698d5e6e7a76ce834cfe31`.
Source/installed `voice_bridge.py` SHA-256 matched:
`884930a5375aa801657cc7b53b3516923f2e4ff15946570673fdea30be7ad1d4`.

The durable queue remained 79 claimed, 80/81 pending before installation; it
was not cleared or edited. A SQLite backup (integrity check: ok), speech events,
and bridge log were preserved in the same temporary backup directory. The old
JSON provider-turn projection was already absent, so it could not be copied.
These are installation/provenance checks only; recovered queue behavior and
fresh human-confirmed queued-audio UAT remain to be tested in the new session.

## Post-install recovery and fresh queue test — 2026-09-06

The new Codex session recovered the retained queue: sequence 79 became acked
with `terminal_claim_reconciled`; 80 and 81 were then acknowledged, completed
with final delivery sent, and produced audio. The user confirmed both recovered
answers were heard and matched the pill.

A fresh three-request exercise then used command sequences 82, 83, and 84
under bridge PID 7807. Requests asked for tracked file count, current branch,
and latest commit subject. The latter two were submitted while the first was
active. Observation caught 82 completed, 83 active, and 84 pending, followed
by all three provider records reaching `completed_final` with delivery `sent`.

| Sequence | Command ID | Provider completion | Final audio start | Final utterance |
| --- | --- | --- | --- | --- |
| 82 | `7807-1788665742424752000-82` | 1788665770.5809011 | 1788665771.558802 | `71d55098-b644-4cf3-bb3e-b2c48ce211e2` |
| 83 | `7807-1788665747794199000-83` | 1788665789.638825 | 1788665790.4539268 | `f05c692e-5565-491f-9580-ebaa6032dfb9` |
| 84 | `7807-1788665754443795000-84` | 1788665804.988116 | 1788665806.829599 | `e2bd2c9c-6c55-4de1-b073-d1b0370364f9` |

The user explicitly confirmed: "all 3 came through". This establishes human
audible delivery for the fresh test, not merely audio-player telemetry. Asked
whether each spoken answer matched its pill, the user explicitly confirmed
"yes". All three final utterances reached `played` (82 at 1788665775.0486069,
83 at 1788665793.373302, and 84 at 1788665813.195285). All three inbox entries
were acked and provider records completed_final with origin relay, with no
phantom manual record in the fresh test. Codex installed-app queue/audio UAT
passes. Claude live verification remains deferred, not passed; accepting it as
non-blocking for ticket closure remains a separate scope decision.

## User-authorized closure — 2026-09-06

The user explicitly approved marking RR-348 Done with Claude live testing
deferred, following successful Codex recovery and fresh queue/audio tests.
Claude live testing is non-blocking for this accepted closure scope and is
not recorded as passed. Original failure evidence is preserved above.
