# RR-346 Codex latency UAT — 2026-09-05

Installed run-107 build, active Codex bridge 37653. Auto-play is enabled for
this test; no Option press is requested. Claude and mounted-build verification
remain deferred, not passed. Each sample begins at final transcript receipt.

The visible timing below is the speech report's queued-event proxy, not an
independently measured screen-render timestamp. Human confirmation establishes
heard/displayed content matching, not stopwatch timing.

| Sample | Command sequence | Semantic output | Queued / visible proxy | Audio-player start | Human confirmation | Joint timing result |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 75 | 4.020 s | 4.023 s | 7.458 s | Heard response matched pill | Fail |
| 2 | 76 | 2.297 s | 2.299 s | 4.309 s | Heard response matched pill | Fail |

## Sample 1

- Prompt: explain briefly what Relay Runner does.
- Command ID: `37653-1788595429570577000-75`.
- Utterance ID: `0312202c-10cb-4d58-816a-7786a849d9e7`.
- Source: Messenger; completed with `played`.
- Receipt: `1788595429.5705779`.
- Messenger provider started: `1788595429.58071`.
- First semantic output: `1788595433.59092`.
- Queued: `1788595433.593655`.
- TTS preparing: `1788595434.789767`.
- First WAV ready: `1788595437.022263`.
- Audio player started: `1788595437.028623`.
- Played: `1788595449.2024791`.
- User confirmation: "matched".

The measured delay includes about 4.010 seconds between Messenger provider
start and semantic output, 1.196 seconds from queued to TTS preparing, and
2.232 seconds from preparation to the first WAV. This sample misses both
the two-second visible and three-second audible targets; it is not excluded
as a warm-up or presumed network outlier. Further samples are still required.

## Sample 2

- Prompt: explain the difference between speech recognition and text to speech.
- Command ID: `37653-1788595532590449000-76`.
- Utterance ID: `3687ce3a-3199-4bb0-bcea-e0aa17cdb0a9`.
- Source: Messenger; completed with `played`.
- Receipt: `1788595532.590453`.
- Messenger provider started: `1788595532.5975392`.
- First semantic output: `1788595534.887934`.
- Queued: `1788595534.889867`.
- TTS preparing: `1788595536.170379`.
- First WAV ready: `1788595536.893162`.
- Audio player started: `1788595536.899534`.
- Played: `1788595544.2147388`.
- User confirmation: "matched".

The second sample also misses both targets. Provider start to semantic output
took 2.290 seconds, queued to preparation took 1.281 seconds, and preparation
to first WAV took 0.723 seconds. Successful matching playback is distinct
from the failed latency requirement. With two failures, the planned ten-turn
batch can no longer achieve nine passes; pause acceptance sampling to diagnose
latency rather than discard either failure or restart the count silently.

## Post-fix installation — 2026-09-05

Rebuilt with the standard `scripts/build-dmg.sh` from clean source revision
`320784d932df53ceb6cbd2b5d669356fa9c0fcf8`, containing merged latency fix
`41a35ca` and the replay-test socket-isolation follow-up. Developer ID signing
and notarization were explicitly disabled; the ad-hoc-signed bundle passed
deep strict signature verification before and after installation.

The previous app was quit and moved to
`/tmp/relay-runner-pre-320784d.aoy7yu/Relay Runner.app` as a temporary recoverable
backup. No voice bridge process remained at replacement time. The new bundle
was installed at `/Applications/Relay Runner.app` and launched. Settings and
tickets were preserved; Auto-play remains enabled.

Verified SHA-256 matches between source/build output and installed files:

- Executable: `1596f7c12807e175c3bd9c354ef5e8d232ff1b447a9185ac2a49d811b1bd8b0e`.
- `tts_worker.py`: `87315bab61c40d79aef3c6b0fce1c0fbc192c778e7920f19e9936ef8edec7a3d`.
- `messenger.py`: `b9a149db5ec38c9f5767dd9255efdcbb908bb02802ff3c03677510f91040da78`.

These checks establish installed provenance, not a latency pass. A fresh
post-fix human-confirmed voice sample remains required; samples 1 and 2 above
remain failed pre-fix evidence.

## Post-fix sample 1

Fresh Codex session: app PID 81667, embedded Codex PID 81935, bridge PID
83685 launched from the installed bundle at 2026-09-05T10:21:07Z
(20:21:07 Australia/Melbourne). Source and installed Messenger
and TTS-worker hashes were rechecked before testing and matched the values above.

- Command ID: `83685-1788604489540930000-77` (sequence 77).
- Utterance ID: `84330732-425a-4cd5-a8c3-411b3fd2f2e6`.
- Receipt: `1788604489.5409331`.
- First semantic output: `1788604491.4961128` (1.955 s).
- Queued / visible proxy: `1788604491.498782` (1.958 s).
- TTS preparing: `1788604491.500963` (1.960 s).
- First WAV ready: `1788604493.5017312` (3.961 s).
- Audio player started: `1788604493.509548` (3.969 s).
- Played: `1788604501.833015`.

The queued-event proxy meets two seconds, but audio misses the three-second
target. Queue-to-preparation is now 2.181 ms; preparation-to-first-WAV remains
2.001 s. This demonstrates removal of the previous local autoplay delay, not
a complete latency pass. After clarification, the user explicitly confirmed
hearing the response and matching pill text: "yes for both".

## Post-fix sample 2

- Command ID: `83685-1788606459954996000-78` (sequence 78).
- Utterance ID: `32d177d1-8f4c-4347-af9e-20e4b5d6b8f1`.
- Receipt: `1788606459.954999`.
- Messenger provider started: `1788606459.983874`.
- First semantic output: `1788606463.0820742` (3.127 s).
- Queued / visible proxy: `1788606463.0838678` (3.129 s).
- TTS preparing: `1788606463.084831` (3.130 s).
- First WAV ready: `1788606465.189306` (5.234 s).
- Audio player started: `1788606465.200952` (5.246 s).
- Played: `1788606471.938866`.
- Human audible/visible match confirmation: "match".

This sample misses both latency targets despite successful matching playback.
Queue-to-preparation is 0.963 ms, confirming that the old autoplay delay did
not recur. Provider-start to first semantic output took 3.098 s; preparation
to first WAV took 2.104 s. These stage timings do not establish whether the
remaining delay is network, model inference, buffering, synthesis, or locking.
With two joint-target failures, this planned ten-turn post-fix batch cannot
achieve nine passes. Pause acceptance sampling pending further diagnosis;
retain both pre-fix and post-fix failures rather than resetting the count.

## User acceptance — 2026-09-05

After reviewing these results, the user explicitly accepted the measured speed,
passed RR-346, and requested Done. This replaces the original numerical latency
and ten-turn completion gates for this ticket's closure. The measurements above
remain failures against the original thresholds; no nine-of-ten benchmark pass
is asserted. Both post-fix audible/visible matches are human-confirmed. Claude
live verification remains deferred, not passed, and is non-blocking for this
explicit user-authorized RR-346 closure. RR-347 and RR-348 are unaffected.
