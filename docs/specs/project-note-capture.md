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

Unsupported system-audio formats and microphone format/conversion failures keep
the source visibly `unavailable` and emit the distinct, recoverable
`format_changed` issue. Ordinary device or stream loss emits
`source_unavailable`; consumers therefore do not have to infer a format change
from display text.

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

On 2026-09-21, `/usr/bin/time -l swift test --filter
MeetingTranscriptProducerTests` ran on the dispatch Mac (arm64, the Swift test
target set to macOS 14). The deterministic 60-minute case feeds two sources at
10 synthetic samples per second. Its producer counters reported 7,200 accepted
chunks, maximum queue depth 2, maximum sampled audio-buffer storage 4,720 bytes,
fixture processing latency 3 ms, and zero dropped samples. The complete filtered
suite executes 35 tests. The enclosing build
and test command reached 121,569,280 bytes maximum RSS, which includes SwiftPM,
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

A new note starts recording regardless of Caps Lock. A recovered note starts
paused until the user explicitly resumes it with double-tap Option.
The exclusive owner calls `pause()` to stop every adapter that successfully
started, but first closes the capture ingress at the pause request boundary.
Ingress submission and close share one lock-held gate, so no callback can enter
between marking the boundary closed and terminating its bounded stream.
Its single consumer drains only frames already accepted before that boundary
while asynchronous adapter teardown runs; teardown-time and stale callbacks are
rejected. The producer then finalizes the accepted pre-pause tail. `resume()`
creates new timing epochs. Rapid duplicate pause/resume calls are idempotent
only in their matching state.

Stop uses the same adapter-stop and ingress-drain barrier before it drains final
ASR tails and emits one `MeetingProducerFinalBoundary`. Adapter ownership remains
separate from source availability, so a running adapter that reports a later
format/source failure is still stopped during teardown. An interrupted or
failed source is ingress-gated before its recovery work begins, so stale adapter
callbacks cannot persist audio, create another epoch, or revive public capture
state. Only an explicit recovery event or a fresh successful start reopens that
source. Each start receives a capture generation. Frames emitted before that
start returns are held in a bounded per-source buffer behind an ordered success
marker; success releases them in order, while interruption or failure discards
them. Pause and stop wait for the complete in-flight source-start operation,
including its failure and zero-success cleanup, before a later resume can reuse
an adapter. Every obsolete attempt is stopped unconditionally after completion,
even when ingress overload already removed its tracked ownership. Stale
generations cannot revive capture, and a failure handled during
`start()` cannot be overwritten as `capturing` when the adapter's start call
later returns. Model failure,
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

## Coordinator, checkpoints, and recovery

RR-368 adds one `MeetingNoteCoordinator` actor as the serialized owner of note
identity, capture control, artifact writes, and recovery. Its public phases are
`idle`, `preparing`, `recording`, `paused`, `stopping`, `saved`, `interrupted`,
and `error`; these are presentation/lifecycle states and never ticket statuses.
The project repository path and optional registered project identity are bound
before capture starts and are reused for every create, checkpoint, retry, and
recovery call. A later Workspace selection cannot redirect the note.

Accepted audio uses a write-before-ack rule: the RR-365 producer awaits the
recovery store before it adds a chunk to its ASR buffer. Consequently the
maximum accepted-but-unpersisted audio interval is zero milliseconds. Final
segment revisions target a 15-second canonical Markdown cadence while recording
and are also published at pause, resume, manual checkpoint, and completion
boundaries. Daemon/writer latency or outage can extend canonical publication;
the acknowledged tail remains locally replayable rather than being claimed as
already canonical.
Partial hypotheses remain distinguishable from canonical durable segments and
are not published as final transcript text. The exact pending artifact request
and its stable request ID are journaled before a writer call, so a process death
or injected failure retries the same idempotent mutation rather than appending
the transcript twice.

Transient state lives under Application Support at `Relay Runner/Note
Recovery`, never under the project or source checkout. Each session has an
atomic JSON journal and raw Float32 chunk files with opaque encoded names. The
default per-session audio budget is 256 MiB. At 16 kHz mono Float32 this is a
hard upper bound of 2,097 seconds (34m57s) with both sources continuously
retained, or 4,194 seconds (69m54s) with one source; reaching it fails capture
instead of accepting uncheckpointed speech. After a successful canonical checkpoint,
audio not named by the producer's pending descriptor cursor is removed.
Successful completion removes the complete owned recovery directory. Neither
audio samples nor transcript text are written to diagnostics, provider input,
or application logs.

On relaunch the coordinator lists incomplete journals without starting FluidAudio,
a capture adapter, a provider, a messenger, a bridge, or a microphone. Recovery
first retries any pending idempotent writer mutation and reads the last canonical
artifact revision from the immutable original project. The user can then:

- replay exactly the descriptor-addressed local audio tail and remain paused;
- replay that tail and finalize the note; or
- discard only the incomplete tail and complete the last canonical transcript.

Replay restores producer cursors before loading audio, rejects missing or
mismatched chunks, and remains paused after the `recover` choice. Resuming a
microphone requires a later explicit resume action. Already saved canonical
segments are never deleted by incomplete-tail discard.

`AppState` uses its existing `endSession()` / `resetActiveSessionState()` path
for work-to-note transitions, stops the ordinary STT key owner, and waits for
the embedded provider process and bridge to physically release before capture
starts. Note-to-work snapshots the requested destination, waits for the capture
stop barrier and completed local artifact write, then launches the requested
Codex or Claude session. A local writer failure blocks launch and preserves
recovery. A response whose sync state is `pending` is still a successful local
save and does not block the switch. Daemon-dispatched workers are not touched.

While note mode owns the foreground, a clean double-tap Option toggles pause
and resume. Single taps, held Option, and Option keyboard shortcuts do not
toggle. Caps Lock does not control notes. Ordinary STT routing, including Option
replay and Caps Lock activation, is restored only after successful note teardown.
Recorder presentation maps `recording` to
the expanded orange listening glyph with exactly **Taking notes**, and `paused`
to the expanded non-animated white-only glyph with exactly **Paused**.
