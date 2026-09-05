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
