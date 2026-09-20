# Project note capture and transcription producer

RR-365 adds a note-only producer inside Relay Runner. It captures microphone
and supported computer audio, transcribes both locally, and emits typed segment
revisions for the project-note artifact contract. It does not instantiate
`STTEngine`, write the voice FIFO, start Codex or Claude, launch a messenger,
dispatch a command, or generate a title or summary.

RR-368 is the exclusive foreground-mode and durability owner. It must stop the
work-session bridge/audio/TTS lifecycle before constructing
`MeetingNoteCaptureSession`, persist every `MeetingAcceptedAudio` callback, and
durably save the resulting note before starting a work session. RR-367 owns the
user controls and visible state. Background orchestrator workers are outside
this lifecycle.

## Initial support matrix and capture choice

| Path | Initial source and conversion | Permission | Source/fixture status | Installed evidence |
| --- | --- | --- | --- | --- |
| Microphone | System-default input through the existing `AudioCaptureLifecycle`; native route is converted to 16 kHz mono Float32 | Microphone | Builds on the macOS 14 target; synthetic producer fixtures pass | RR-372 must exercise built-in, wired, and Bluetooth routes, disconnect, format change, sleep/wake, denial, and revocation |
| Computer / meeting audio | Audio-only ScreenCaptureKit stream for the first display; 16 kHz mono Float32; Relay Runner's own playback excluded | Screen Recording | Builds on the macOS 14 target; dual-source synthetic fixtures pass | RR-372 must prove a consented meeting source, permission UX, route changes, and simultaneous local/remote speech |
| Local ASR | FluidAudio 0.13.6 / Parakeet v2 or v3 selected by existing STT configuration | Model download on first use; none once cached | Adapter builds against pinned package revision `57551cd90e0bbec342766244358bcf08afb05290`; deterministic fake-ASR fixtures pass | RR-372 must measure the selected model on a representative Apple-silicon Mac |
| Intel Mac | Outside Relay Runner's existing Apple-silicon hardware requirement | N/A | Not supported by the shipped app | No support claim |

ScreenCaptureKit is the smallest source implementation for the current app: it
already runs inside Relay Runner's signed process, works on the existing macOS
14 floor, exposes an audio-only stream, and uses a permission Relay Runner
already brokers. A Core Audio process tap remains a possible later adapter, but
Apple's sample requires macOS 14.2 and an additional audio-capture usage flow;
choosing it here would either raise or fragment the current 14.0 baseline.
See Apple's [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
and [Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
RR-359's pinned native comparator is Logue at
[`ea61172f33970d40b9f9b5e4c52f30eb82836e58`](https://github.com/bitwize-ai/Logue/tree/ea61172f33970d40b9f9b5e4c52f30eb82836e58);
no source was copied from it.

Screen Recording denial never masquerades as whole-meeting capture. The system
source becomes `denied` with a typed `permission_denied` issue while any usable
microphone source remains separately labelled. If neither source starts, the
session start fails. Relay Vision and note capture share the macOS capability,
but neither operation starts the other.

## Channels, timing, and revisions

Microphone and system audio stay as separate 16 kHz mono sources. They are not
summed, because a destructive mix loses source provenance and can clip
overlapping local and remote speech. Both adapters timestamp the first sample
of every frame on the host-monotonic timeline (using ScreenCaptureKit's audio
PTS when available). A source that begins later therefore begins later in the
note instead of incorrectly starting at zero. Each source retains its own
ordered chunks and timing epochs on that shared timeline. Pause/resume, route
recovery, and producer restart create new epochs without allocating a new note.

The default ASR window is six seconds with one second of right overlap. A
window owns only its first five seconds; token midpoints in the overlap are
context and are emitted by the next window. The final tail owns its complete
accepted range. Stable segment IDs derive from source, epoch, and owned start
sample. Partial hypotheses increase `revision` for that ID; a final revision
closes it. Late lower revisions are rejected. A repeated sentence in a later
owned range has a different segment ID and is retained; there is no global
substring suppression like `TranscriptAccumulator.join`.

`MeetingTranscriptSegmentRevision.projectNoteSegment` maps final producer
output into the RR-364 storage type. RR-368 should checkpoint meaningful
batches, not every partial callback.

## Bounded processing and backpressure

Capture callbacks enter one tracked consumer through a 32-item bounded ingress
(audio frames and rare source events share the bound);
there is no task allocation per frame. Accepted chunks reach the RR-368 sink
before entering the ASR buffer. The producer then retains at most the current
window plus overlap per active source, plus a configurable bounded transcription
queue (eight windows by default). If capture ingress overflows, dropped frame and
sample counters are recorded, every started adapter is stopped, and capture
enters `failed` with `backpressure_exceeded`. When the transcription queue is
busy, a superseded partial refresh may be skipped with a typed issue; accepted
audio remains available for the final window. If a final window cannot be
queued, capture likewise fails instead of silently dropping speech.

On 2026-09-20, `/usr/bin/time -l swift test --filter
MeetingTranscriptProducerTests` ran on the dispatch Mac (arm64, the Swift test
target set to macOS 14). The deterministic 60-minute case feeds two sources at
10 synthetic samples per second. Its producer counters reported 7,200 accepted
chunks, maximum queue depth 2, maximum sampled audio-buffer storage 4,720 bytes,
fixture processing latency 3 ms, and zero dropped samples. The complete filtered
suite executed 19 tests in about 0.3 seconds after build. The enclosing build
and test command reached 642,351,104 bytes maximum RSS, which includes SwiftPM,
the compiler, linked FluidAudio, and the XCTest host and therefore is not a
producer-only memory measurement.

The fixture checks:

- 36,000 accepted samples per source and zero dropped samples;
- no transcription failures;
- queue depth never exceeds the configured bound (observed maximum 2 of 16);
- reported processing latency remains the fixture's 3 ms per window; and
- the sampled producer buffer stays below 4,800 bytes (observed 4,720).

These are source/fixture measurements, not an RSS, thermal, accuracy, or audio
device claim. RR-372 owns installed measurements for peak RSS, p50/p95 first
and final text latency, sustained processing, dropped frames, drift, CPU/GPU/ANE
use, thermal behavior, and real simultaneous paths.

## Pause, stop, failure, and replay

The capture session reads the actual Caps Lock state by default. Starting while
Caps Lock is on prepares the local model but starts paused and accepts no audio.
The exclusive owner calls `pause()` to stop every adapter that successfully
started, but first closes the capture ingress at the pause request boundary.
Its single consumer drains only frames already accepted before that boundary
while asynchronous adapter teardown runs; teardown-time and stale callbacks are
rejected. The producer then finalizes the accepted pre-pause tail. `resume()`
creates new timing epochs. Rapid duplicate pause/resume calls are idempotent
only in their matching state.

Stop uses the same adapter-stop and ingress-drain barrier before it drains final
ASR tails and emits one `MeetingProducerFinalBoundary`. Adapter ownership remains
separate from source availability, so a running adapter that reports a later
format/source failure is still stopped during teardown. Model failure,
permission denial, source loss, format failure, transcription failure,
checkpoint failure, and backpressure are typed and preserve already emitted
revisions. Source recovery starts a new epoch.

`MeetingProducerCheckpoint` records the shared timeline origin and source
cursors, epochs, the next contiguous unfinished window per epoch, successful
windows beyond any earlier failure, final/emitted revision cursors, metrics,
and descriptors for unfinished audio. RR-368 owns the referenced audio bytes
and cleanup. On restart it restores the checkpoint and passes exactly those
persisted chunks to `replayAcceptedAudio`. Replay processes each epoch in order,
trims a retained chunk that crosses a committed-window boundary, and skips
already successful windows. A later successful window never releases audio
needed by an earlier failed window. The audio sink failing is a capture failure:
the producer does not retain the unpersisted chunk or allow the destination
foreground mode to start.

## Offline and licensing boundary

Recognition calls only FluidAudio's local `AsrManager`; there is no hosted
fallback. The existing first-use model acquisition reports checking,
downloading, compiling, ready, and failed states. Once the selected model is in
FluidAudio's local cache, capture and transcription need no provider or network.

FluidAudio is Apache-2.0. The downloaded Parakeet v2/v3 Core ML models are
CC-BY-4.0 and retain NVIDIA/Fluid Inference attribution. The resolved versions,
model links, and packaging obligations are recorded in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md). The app does not add a
new model, redistribute new weights, or change those existing terms.

Only synthetic arrays or explicitly consented recordings may be used for this
producer. Tests in this ticket use synthetic samples and fake ASR text. They do
not establish installed permission behavior, device support, transcription
quality, provider isolation in a signed app, or audible/visible UX; those are
RR-372 evidence gates.
