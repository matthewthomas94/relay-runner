# RR-347: Codex original and replay confirmation

## Scope and provenance

Human-assisted UAT on 2026-09-05 (Australia/Melbourne), using the installed
`/Applications/Relay Runner.app` and a fresh Codex voice bridge (PID 37653).
The installed app was rebuilt from merge `b444973` (RR-347 worker run 107),
containing fix `ab5c0f6` for atomic speech-intent acceptance and playback arming.

- Installed executable SHA-256: `11cc15cc3455553c0d7d24a563c9abf539d4832712d231a6c61c039ec33d3cb4`.
- Source and installed `speech_coordinator.py` SHA-256 both:
  `f16b7c5da557cd31255207f3c17bc40d6abcc47a1a983c3e216090f8af26a61a`.
- This is installed-app, ad-hoc-signed UAT on this Mac, not evidence of a
  Developer ID/notarized or mounted-DMG acceptance run.

## Three-request queue exercise

Three separate natural spoken requests asked for working-tree cleanliness,
the checked-out branch, and the latest commit subject. Provider-turn records
for commands 72, 73, and 74 all reached `completed_final` with delivery `sent`;
commands 73 and 74 were observed pending behind earlier work. All three
authoritative speech intents reached the queued state. The earlier unplayed
responses were superseded by later responses as the requests progressed.

The final command identity was `37653-1788592727312084000-74` (sequence 74).
Its authoritative utterance was `a2b7e9af-e522-482b-ad73-4e5c101902b5`.
The pill displayed the latest commit subject, `merge RR-347 worker run 107`.

## Original and replay

The original utterance remained available until the user requested playback.
The speech event log recorded preparation, start, visual acknowledgment,
audio-player start, and successful completion. The user confirmed that the
heard response matched the displayed response: "yes this matched".

Explicit replay utterance `cf58d7db-fec7-41ba-9428-464d402401e3` retained the
same command identity and referenced the original utterance through both
`original_utterance_id` and `replay_of`. It reached queued, preparing,
first-WAV-ready, started, audio-player-started, and played states. The user
then confirmed the match again: "matched again".

Selected event timestamps (Unix seconds):

| Event | Original | Replay |
| --- | --- | --- |
| Preparing | 1788593126.898598 | 1788593582.343105 |
| Started | 1788593126.899955 | 1788593584.170256 |
| Audio player started | 1788593126.9203641 | 1788593584.175966 |
| Played | 1788593133.389067 | 1788593590.598055 |

Evidence was correlated from the live provider-turn ledger, speech event log,
Relay Vision observation, and the user's independent audible confirmations.
Logs alone do not prove that sound was heard.

## Result and remaining gates

The tested Codex queued-final original/replay path passes: the authoritative
response was available, played, and replayed with matching visible and
human-confirmed audible content. The prior accepted-but-not-queued/orphaned
preview failure did not recur in this exercise.

This is not blanket completion of RR-347, RR-348, or RR-346:

- Claude live UAT remains deferred at the user's request, not passed.
- RR-347's exact mounted signed-app gate is not established by this installed
  ad-hoc-signed run.
- RR-348 still lacks human-audible confirmation of the earlier responses in
  this queue exercise; only the final response and its replay were heard.
- RR-346 still requires its eligible ten-turn latency sample set. Intentional
  waits before manual playback here cannot establish its audible-latency gate.

Ticket statuses remain unchanged; this report records partial verification
without administratively clearing external acceptance requirements.

## Subsequent acceptance and closure — 2026-09-05

The user subsequently removed Apple Developer ID/notarization and mounted-DMG
requirements, accepted the recorded Codex playback/replay evidence, and
explicitly requested RR-347 be closed. RR-347 is Done on that accepted scope;
Claude live testing remains deferred, not passed, and is non-blocking for this
closure. The later test-generated preview leak was isolated in `320784d`, with
36 replay tests passing and zero real-socket attempts under a guarded check.

This supersedes the historical remaining-gate snapshot above without rewriting
the observed evidence. RR-346 was separately closed on explicit user acceptance
of its measured latency. RR-348 remains open for its own queued-audio UAT.
