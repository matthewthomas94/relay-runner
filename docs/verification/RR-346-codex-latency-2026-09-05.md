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
