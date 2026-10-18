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

Meeting notes do not transcribe while recording (RR-406). The coordinator
builds its producer with `transcribesLive: false`: it keeps the shared
timeline and timing epochs and hands every accepted chunk to the recorder, but
it never prepares a model, submits a window, or emits a partial hypothesis.
After Stop, `MeetingRecordingTranscriber` runs the finished recording through
the same windows and segment IDs once, forwarding final revisions only.

`MeetingTranscriptSegmentRevision.projectNoteSegment` maps final producer
output into the RR-364 storage type. The coordinator publishes those finals in
the single completed checkpoint, never per partial callback.

## Bounded processing and backpressure

Capture callbacks enter one tracked consumer through a bounded ingress (audio
frames and rare source events share the bound); there is no task allocation per
frame. The live note session batches about 100 ms per source and holds 600
items, roughly 30 seconds of two-source audio, so a transient stall delays
persistence instead of dropping speech. Accepted chunks reach the recorder
sink before the producer acknowledges them. Record-only note capture then
retains no samples. The coordinator drops repeated source-state events before
buffering them, so uninterrupted recording retains only state transitions,
not one event per audio chunk; failure events remain ordered and delivered.
A live or post-Stop pass retains at most the current
window plus overlap per active source, plus a configurable bounded transcription
queue (24 windows by default, about a minute of two-source final windows). If capture ingress overflows, dropped frame and
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
rejected. The producer then finalizes the accepted pre-pause tail, and note
capture closes each source's open recorder segment so all pre-pause audio is
readable on disk. `resume()` creates new timing epochs. Rapid duplicate pause/resume calls are idempotent
only in their matching state.

Stop uses the same adapter-stop and ingress-drain barrier before it emits one
`MeetingProducerFinalBoundary`. Record-only capture has no ASR tail to drain;
the coordinator then closes the recording and transcribes it. Adapter ownership remains
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
and descriptors for unfinished audio. Record-only capture writes it only when a
timing epoch opens (start, resume, source recovery), never per chunk, so its
`pendingAudio` stays empty and its source cursors can trail the recorded audio.
Recovery advances each source cursor past the recorded segments before a
resumed capture opens new epochs. There is no live replay path;
`replayAcceptedAudio` has been removed. A journal from before compressed
recording may still name raw Float32 chunks in `pendingAudio`: the post-Stop
pass reads those first, rebases their epochs past windows the live producer
already completed so segment IDs match, and then reads the recording. The audio
sink failing is a capture failure: the producer does not acknowledge the chunk
or allow the destination foreground mode to start.

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

Accepted audio uses a write-before-ack rule: the producer awaits the session
recorder before it acknowledges a chunk. `MeetingCompressedAudioRecorder`
encodes each source as AAC-LC `.m4a` segments (16 kHz mono, 32 kbps) of at
most 30 seconds, and a segment enters the recording manifest only when it
closes: at 30 seconds, at pause, at Stop, or when an interruption closes the
recorder. A hard crash or power loss therefore loses at most one open segment,
30 seconds or less per source; every closed segment survives.

While recording there are no live partials and no transcript text. The
coordinator creates the empty note before capture starts and then publishes
only state checkpoints at pause and resume, each carrying zero segments. There
is no periodic, per-chunk, or partial-callback checkpoint, and the journal is
not rewritten per chunk. Daemon/writer latency or outage cannot lose audio,
because the recording stays local until the completed note is saved. Pause,
resume, and completion checkpoints fail into recovery as before.

Stop transcribes once. After the capture barrier the coordinator closes the
recording and shows **Transcribing notes** while `MeetingRecordingTranscriber`
prepares FluidAudio, transcribes the complete recording, and releases the
model. It then shows **Saving notes** and publishes one completed checkpoint
with every segment's stable ID, source speaker, and millisecond timing. The
exact pending artifact request and its stable request ID are journaled before a
writer call, so a process death or injected failure retries the same idempotent
mutation rather than appending the transcript twice.

Transient state lives under Application Support at `Relay Runner/Note
Recovery`, never under the project or source checkout. Each session has an
atomic JSON journal, a separate atomic producer checkpoint, and an owner-only
`recording` directory holding the compressed segments and their manifest. The
recording directory, its segments, and its manifest are excluded from Time
Machine and other macOS backups. On load, the newer of the two replay cursors
wins. The default recording budget is 192 MiB across both sources. At the
nominal 4,000 bytes per second per source this is about 25,165 seconds
(6h59m) with both sources continuously recorded, or about 50,331 seconds
(13h58m) with one source. The recorder counts each open segment's projected
size plus container overhead, so reaching the budget fails capture with
`recording_budget_exceeded` and keeps the recording for recovery rather than
accepting audio it cannot store. After a successful completed save the
coordinator deletes the recording and then the complete owned recovery
directory. A failed transcription or save deletes nothing: the recording and
journal remain and the note is listed as a recovery offer. Neither
audio samples nor transcript text are written to diagnostics, provider input,
or application logs. Capture interruptions are logged under the
`com.relayrunner.app` subsystem, `notes` category, as cause codes and producer
counters only.

A failure that ends capture while recording or paused shows "Recording
interrupted", never "Transcribing notes" or "Saving notes"; those are reserved
for a Stop the user requested. Stop pressed during that teardown waits for it, then finalizes
from the recovery journal.

On relaunch the coordinator lists incomplete journals and reads their
recording manifests without starting FluidAudio, a capture adapter, a provider,
a messenger, a bridge, or a microphone. Recovery first retries any pending
idempotent writer mutation and reads the last canonical artifact revision from
the immutable original project. The user can then:

- reopen the recording and remain paused (`recoverPaused`); a later explicit
  resume records new epochs after the recorded audio, and Stop transcribes the
  audio from before and after the interruption together;
- transcribe the recording and finalize the note (`finalize`); or
- delete the recording and complete the last canonical transcript
  (`discardIncompleteTail`).

Recovery restores producer cursors before capture restarts and rejects a
missing or mismatched recording segment or legacy chunk. Resuming a microphone
requires a later explicit resume action. Already saved canonical segments are
never deleted by discard. A journal written before compressed recording still
finalizes from its raw Float32 chunks.

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
