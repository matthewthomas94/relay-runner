# RR-237 — Workspace and terminal responsiveness audit

Date: 2026-07-28

Source baseline: `6b2633f`

Audit scope: measurement and bounded, opt-in diagnostics only; no production remediation

## Executive finding

The reported symptoms do not have one universal cause.

The Workspace hover and drag failures share one confirmed main-thread bottleneck:
every `ProgramWorkColumnPanel` body evaluation asks
`ProgramDashboardSnapshot.ticketItems` to sort its lane, and the comparison
function obtains each ticket's modification date from the filesystem. With 227
tickets, the real sort takes 553 ms p50 and 708 ms p95 in the debug harness.
An eligible drag takes 0.74 ms when the main thread is free, but the same queued
drag waits 761 ms behind one sort. A queued hover waits 792 ms. The installed
app's Time Profiler trace independently attributes 330 ms of inclusive sampled
CPU to this path during a ten-second Program Workspace capture.

Recurring repository discovery is a second, independent pressure source. The
one-second notch activity refresh scans ticket files and re-resolves registered
projects, while route resolution can synchronously launch `git` processes and
rewrite registry state. Those stacks account for hundreds of milliseconds of
inclusive sampled CPU in the installed capture. Some run on a utility task, but
route/status entry points also execute synchronous work on the main actor.

Terminal input delivery itself is fast. Relay/SwiftTerm input reaches the send
delegate in less than 0.06 ms p95, and a `/bin/cat` PTY echo returns within
2.4 ms p95 on the CoreGraphics path. Current CoreGraphics parsing and display
submission adds about 24–29 ms. Codex's own warm TUI echo is sub-millisecond;
Claude's is about 14 ms p50 and 21 ms p95, with much larger first-paint
outliers. Provider TUI work therefore explains provider-specific variance, but
not Workspace pointer stalls.

SwiftTerm's optional Metal renderer is not a safe latency fix. At both 1.14.0
and 1.15.0 it reduced measured process RSS and render-submission median, but
whole-frame p95 stayed near 49 ms, PTY-to-render p95 reached 63–65 ms, and the
representative high-output workload was slower than CoreGraphics. SwiftTerm
1.15.0 remains worth a separately verified compatibility upgrade for its Metal
buffer-growth, packaged-app failure, mouse, scroll, and IME fixes; Metal should
remain off by default until it wins the latency gates in an installed app.

The Workspace label **Checking for updates** is dashboard refresh state, not a
Sparkle software-update check. Its animated glyph adds continuous 60 Hz main
thread drawing while a dashboard request is active, but the trace does not
support it as the primary 0.7–0.8 second stall.

## Environment

| Item | Value |
| --- | --- |
| Hardware | MacBook Pro `Mac16,1`, Apple M4, 10 cores (4 performance / 6 efficiency), 24 GB |
| OS | macOS 26.5.2 (25F84) |
| Toolchain | Xcode 26.2; Swift 6.2.3 |
| Source | `relay-runner` at `6b2633f`; 522 tracked files, approximately 16 MB |
| Project workload | One project with 227 `.orchestrator/RR-*.md` ticket files |
| Installed app | `/Applications/Relay Runner.app`, 0.4.27 (31), ad-hoc signed |
| Installed executable | mtime 2026-07-28 09:21:09 +1000; SHA-256 `bf182cb01607796ab6c90e6935d5bceef9f1d4106059226ea07bfdad6404500e` |
| Providers | Codex CLI 0.145.0; Claude Code 2.1.218 |
| SwiftTerm | Relay pin v1.14.0, `849e8a4f3d6f79ddee07152400137f1370c32621`; comparison v1.15.0, `dd2fb8ac5b861e7bf617c872895e338f38165648` |

The installed app was relaunched from the current build before capture. The
debug app and test bundle were built from the source baseline. The first debug
build took 347 seconds and peaked at 511 MiB RSS; subsequent benchmark runs
used the incremental build.

## Reproducible matrix

The current unified Workspace uses the same board component for a single
project and for a program. The selected project scope distinguishes the
Project Workspace case from the all-project Program Workspace case.

| Surface / state | Build | Workload | Provider / workers | Coverage and result |
| --- | --- | --- | --- | --- |
| Project Workspace, idle | Debug mounted hierarchy | One repo, 227 tickets, single selected project | Provider-independent, no worker data in the mounted snapshot | Direct hover below timer resolution; eligible Backlog → Queued feedback 0.74 ms; lane sort 553/708 ms p50/p95 |
| Project Workspace, refresh overlap | Debug mounted hierarchy | Queue real hover/drag event, synchronously evaluate 227-ticket lane first | Provider-independent | Hover delayed 792 ms; eligible drag delayed 761 ms |
| Program Workspace, foreground turn and several workers | Fresh installed app, Work tab visible | Multiple registered projects; dashboard refresh; RR-237 and RR-240 active | Codex foreground session, two Codex workers | 23.7% sampled app CPU average, 17.0% on main; `top` ranged 18–35%; 241–246 MiB RSS |
| Program Workspace, one worker | Fresh installed app, Terminal tab visible after RR-240 merged | Same installed process; RR-237 active | Codex foreground session, one Codex worker | `top` samples 4.1–10.3%; 242 MiB RSS. This row is tab-confounded and is not used to claim worker-count scaling. |
| Dashboard refresh / **Checking for updates** | Installed trace plus debug slow-fetch test | Initial and ten-second refresh; 50 ms injected fetch verifies overlap suppression | Provider-neutral | The state starts before async fetch and ends afterward; a second poll is coalesced. Sorting and snapshot invalidation occur on completion. The live label was too brief to time visually. |
| Terminal, idle interactive | Debug mounted `RelayTerminalView` + real SwiftTerm `LocalProcess` and `/bin/cat` | 30 input trials after warm-up | Provider-independent | CoreGraphics visible-submit 25.4/30.1 ms p50/p95 |
| Terminal, high output | Same | 662,250 bytes of ANSI text in 64 KiB chunks and 100 full 42-row frames | Provider-independent | CoreGraphics 910.2 ms; Metal 1,020.4 ms on 1.14.0 |
| Terminal while work is active | Debug harness run while the installed session and workers remained active | Same terminal workload under the audit session's system load | Codex worker(s) active in installed process | No PTY delivery inflation: input-to-send remained below 0.06 ms p95 |
| Provider TUI, warm typing | Actual CLI in a PTY controlled by `expect`; no prompt submitted | Type/backspace trials after initial paint | Codex and Claude separately | Codex 0.234/0.318 ms; Claude 13.831/20.999 ms p50/p95 from key send to TUI PTY output |

The Claude run exposed a one-time “Claude in Chrome extension detected” chooser.
The session selected Escape (browser tools off for that process) without
changing configuration. One cold first-input run took 375 ms, and another
timed out at two seconds; these startup outliers are reported separately from
warm TUI latency.

No Claude worker was dispatched merely to populate this audit. The equivalent
Claude terminal path was measured directly at the actual Claude TUI, while all
shared Relay/SwiftTerm measurements are provider-independent.

## Reproduction

The committed `RR237ResponsivenessBenchmarkTests` is opt-in and skips in the
normal suite:

```sh
RR237_BENCHMARK=board \
  swift test --disable-sandbox \
  --filter RR237ResponsivenessBenchmarkTests/testProgramBoardEventAndSortLatency

RR237_BENCHMARK=terminal RR237_RENDERER=core-graphics \
  swift test --disable-sandbox \
  --filter RR237ResponsivenessBenchmarkTests/testSwiftTermPTYAndRendererLatency

RR237_BENCHMARK=terminal RR237_RENDERER=metal \
  swift test --disable-sandbox \
  --filter RR237ResponsivenessBenchmarkTests/testSwiftTermPTYAndRendererLatency
```

The board harness scans the real ticket directory, mounts
`ProgramWorkColumnPanel` in an `NSHostingView`/`NSWindow`, posts AppKit events
through `ProgramWorkCardDragEventView`, and measures the model's eligible drop
target. It separately queues events behind a real lane sort to reproduce an
event-loop gap.

The terminal harness mounts Relay's `RelayTerminalView`, launches `/bin/cat`
through SwiftTerm's real `LocalProcess`, and records:

1. `insertText` (AppKit text commit boundary) to `TerminalViewDelegate.send`;
2. send-delegate timestamp to echoed PTY output;
3. echoed output receipt to synchronous display/draw submission; and
4. input commit to completed display/draw submission.

The second interval is an upper bound on SwiftTerm's asynchronous PTY write:
it includes the dispatch write, `cat` scheduling, and the return read. SwiftTerm
does not expose its `DispatchIO.write` completion to Relay. “Visible” in this
report means renderer submission completed; it is not a photodiode measurement.
That distinction matters for Metal because the GPU presents asynchronously.

Provider TUI runs used an `expect`-owned PTY, waited for each CLI's initial
paint, then measured a key send to the next bytes emitted by the TUI. No prompt
was submitted and no terminal input or transcript was recorded.

The installed profile was captured with:

```sh
xcrun xctrace record --template 'Time Profiler' \
  --attach relay-runner --time-limit 10s \
  --output /tmp/rr237-trace.xHkXTX/installed-program.trace
```

The resulting trace contains Time Profiler samples and potential-hang
instrument data. The potential-hang table contained no events. That does not
contradict the benchmarked queue delay: the profiler shows sustained sampled
work rather than a lock-classified hang. An attempted File Activity trace was
discarded because Instruments generated an incomplete 952 MB capture and kept
using a full CPU core after the requested window; the diagnostic process was
stopped. File and process evidence below comes from symbolicated Time Profiler
stacks and the bounded harness.

## Measurements

### Workspace events and sorting

| Metric | Result |
| --- | ---: |
| Ticket count | 227 |
| Lane sort p50 / p95 | 552.962 / 707.514 ms |
| Independent first run sort p50 / p95 | 637.489 / 789.727 ms |
| Direct mounted hover callback p50 / p95 | <0.001 / <0.001 ms |
| Direct eligible Backlog → Queued drag target | 0.742 ms |
| Queued hover behind one sort | 791.836 ms |
| Queued eligible drag behind one sort | 760.686 ms |
| Manual Backlog → In Progress request | Accepted |

The policy result is a correctness finding, not latency: an idle ticket can be
manually moved into In Progress. Same-lane moves, items without identity, active
worker cards, and awaiting-merge cards are rejected. The worker-owned lifecycle
documented by Relay Runner therefore does not match current idle-ticket drop
policy at `ProgramBoardDropPolicy.request`.

The hot source chain is:

- `Sources/relay-runner/Board/ProgramBoardOverlayView.swift:889-906` computes
  lane items inside every column body;
- `Sources/relay-runner/Board/ProgramBoardStatus.swift:24-40` filters and sorts;
- `Sources/relay-runner/Board/ProgramBoardStatus.swift:1650-1658` calls the
  comparator twice per comparison; and
- `Sources/relay-runner/Board/ProgramBoardStatus.swift:1719-1722` reconstructs
  the ticket identity and asks `URL.resourceValues` for modification time.

This is `O(n log n)` filesystem metadata lookup inside the main-thread
invalidation graph. `ProjectResolver.scanTickets` already loads each ticket's
modification date at `ProjectResolver.swift:208-227`, so the dashboard payload
or local item can carry a stable sort key instead of restatting during view
evaluation.

### Installed app profile

Ten seconds of the installed Program Workspace with a foreground Codex session
and two worker cards produced 2,371 ms of sampled app CPU, or 23.71% of one
core averaged over the capture. The main thread accounted for 1,695 ms
(16.95% of one core). Inclusive stacks overlap; they identify hot chains and
must not be summed.

| Inclusive symbol / chain | Sampled CPU |
| --- | ---: |
| `ProgramBoardViewModel` / `ProgramDashboardSnapshot.ticketItems` | 330 ms |
| `AppState.loadNotchActivitySnapshot` | 368 ms |
| `ProjectResolver.scanTickets` | 250 ms |
| `ProjectRegistry.gitRepoRoot` / `runGit` | 190 / 175 ms |
| `ProgramStatusItem.ticketFileModifiedAt` | 176 ms |
| `ProjectRegistry.activateBridgeCwd` | 156 ms |
| `ProjectResolver.resolveActivityProjects` | 145 ms |
| Project classification / child repository discovery | approximately 145 ms |
| `ProgramTicketIdentity.ticketURL` | 135 ms |
| Notch drawing paths | 161 ms and 92 ms |
| Board scroll update/layout | 79 ms |
| Workspace status-poll check | 62 ms |

Concrete I/O/process evidence includes `URL.resourceValues`/filesystem metadata
frames in the sort, ticket file reads in `ProjectResolver.scanTickets`, and
`Process.waitUntilExit` below `ProjectRegistry.runGit`
(`ProjectRegistry.swift:454-468`). The synchronous process wait can run a nested
run loop, which explains re-entrant timer activity in the sampled stacks. The
bridge/project route also rewrites registry activation metadata even when the
route has not changed.

### Terminal renderers and SwiftTerm versions

All numbers are milliseconds except RSS. Each row uses the same 1,200 × 700
view, 42-row changing frame, ANSI high-output stream, and `/bin/cat` PTY.

| SwiftTerm / renderer | Input→send p50/p95 | Send→PTY echo p50/p95 | Output→render submit p50/p95 | Input→render submit p50/p95 | Frame p50/p95 | High output | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1.14.0 CoreGraphics | 0.040 / 0.057 | 0.226 / 1.441 | 23.896 / 29.348 | 25.434 / 30.067 | 29.560 / 35.329 | 910.164 | 155.2 MiB |
| 1.14.0 Metal | 0.011 / 0.033 | 0.137 / 63.008 | 0.151 / 63.412 | 0.402 / 66.382 | 43.065 / 49.818 | 1,020.354 | 78.9 MiB |
| 1.15.0 CoreGraphics | 0.046 / 0.051 | 0.246 / 2.303 | 26.511 / 28.532 | 27.114 / 28.980 | 32.230 / 38.454 | 920.854 | 155.0 MiB |
| 1.15.0 Metal | 0.019 / 0.036 | 0.208 / 65.114 | 0.339 / 64.984 | 2.358 / 68.222 | 42.890 / 49.418 | 1,031.632 | 78.7 MiB |

SwiftTerm's debug Metal telemetry settled around 18–25 FPS for the full-frame
workload (with a 4.8 FPS cold interval on 1.14.0), rebuilding 42 or 43 of 43
rows. `isUsingMetalRenderer` verified that the GPU-backed path was active.
Direct GPU occupancy counters were not available: `powermetrics` requires
superuser privileges in this worker. The measured FPS, CPU-side submission
latency, wall time, and RSS are sufficient to reject a default renderer switch,
but a future installed-app gate should capture Metal System Trace counters.

SwiftTerm 1.15.0 deliberately avoids `Bundle.module` fatal errors in packaged
apps (`MetalTerminalRenderer.swift:2825-2855`). In the SwiftPM XCTest host it
instead failed safely with `shaderSourceMissing` because the generated resource
bundle was not among its candidates. The benchmark therefore used a
test-only candidate-bundle shim in an untracked temporary checkout. This is not
evidence of an installed-app failure, but it is a required packaging/test case
for an upgrade ticket. CoreGraphics remains a functional fallback.

SwiftTerm already provides important backpressure and interactivity controls:
`LocalProcess.swift:79-107,132-208` reads on a private queue, drains main-queue
delivery in four-millisecond slices, and pauses at 4 MiB until the backlog falls
below 1 MiB. `AppleTerminalView.swift:2137-2188` immediately schedules display
after recent user input while coalescing redundant redraws. Relay should not
duplicate those mechanisms without a failing measurement.

### Provider-specific TUI processing

| Provider | Warm key→TUI PTY output p50/p95 | Cold behavior |
| --- | ---: | --- |
| Codex CLI 0.145.0 | 0.234 / 0.318 ms | No material outlier in the measured run |
| Claude Code 2.1.218 | 13.831 / 20.999 ms | 375 ms first-input outlier in one run; another first input exceeded 2 s |

Relay's shared input-to-send and PTY round-trip are below 2.4 ms p95 on
CoreGraphics. Claude's steady-state TUI work is measurably slower than Codex's,
and its first-paint path is much slower, but neither provider accounts for the
Workspace's 0.7–0.8 second event-loop gaps. The user-visible terminal total
contains both the provider's output delay and SwiftTerm's roughly one-to-two
frame display cost.

## Recurring and triggered work

| Work | Frequency / trigger | Context | Cancellation / coalescing and overlap |
| --- | --- | --- | --- |
| STT state poll | 20 Hz while overlay services run | Main run loop | Timer invalidated on service stop; no per-tick coalescing; only mutates when state changes |
| Workspace theme/session poll | 10 Hz while Workspace visible | Main run loop | Invalidated on hide; values assigned only on change |
| Workspace dashboard/status poll | Immediately on open and every 10 s; also after create/edit/drop/delete | Main actor route/scope work, then async local HTTP fetch | Suppressed while editing or a reload is in flight; stopped on hide |
| **Checking for updates** glyph | 60 Hz while dashboard request active | Main run loop / AppKit draw | Timer exists only while loading; Reduce Motion disables animation |
| Notch activity snapshot | 1 Hz while an active session exists | Main timer starts a detached utility task; result returns to main | One-task gate; cancellation checked on stop; overlaps ticket scans, project discovery, dashboard, and sleep monitoring |
| Bridge watchdog / route refresh | Every 3 s | Main run loop; synchronous process/filesystem checks | Invalidated when bridge monitoring stops; current `refreshRouteIfNeeded` avoids route work when Work tab is already available |
| Sleep prevention activity | 1 Hz when preference enabled | Main timer, detached activity load, main result | One-task gate and cancellation on disable/stop; reads run-state data independently of notch refresh |
| Voice command delivery | Every 200 ms while embedded session runs | Private serial queue | Single pending submission/ack state; retries bounded; stopped with terminal |
| SwiftTerm PTY reads | Event-triggered | `sender` read queue, four-millisecond main delivery slices | 4 MiB/1 MiB high/low-water backpressure; feed/display coalescing |
| Private terminal diagnostics | Per PTY output chunk, only when marker file opts in | Private diagnostics queue | Disabled by default; newest 1 MiB retained; atomic rewrite per chunk when enabled |
| Reveal and hover motion | 60 Hz only during finite reveal/retract or active loading/hover animation | Main run loop | Explicit timer invalidation; Reduce Motion paths |
| Overlay/perimeter particle fields | 30 Hz while their surface is active | Main/AppKit/Metal drawing depending on surface | Lifecycle-scoped timers; contributes steady CPU but not the measured long sort |
| Ready/dependency sweep | Every Program dashboard GET and explicit ready/save triggers | Orchestrator HTTP thread / SQLite and ticket files | Serialized by daemon sweep locks; no duplicate dispatch because run/dependency state is rechecked |
| Review/queue-drain reconciliation | Every 5 s | Daemon background thread | Event-state guarded; independent of app dashboard polling |
| Command processing | Every 2 s | Daemon background thread | Up to ten commands per pass |
| Run index prune / refresh | Every 30 s | Daemon background thread | Rewrites retained run index; no overlap gate |
| Worker health observation | Every 10 minutes by default | Daemon path | Signature comparison; advisory only |
| Settings status refresh | 1 Hz only while Settings status view exists | Main Combine timer | View-lifecycle scoped |
| Sparkle update check | 86,400 s plus explicit user check | Sparkle updater | Separate from Workspace dashboard state; automatic checks enabled in `Info.plist` |

The highest-risk overlap is a ten-second dashboard result invalidating the
board while a one-second activity scan and the checking glyph are active. The
sort itself is not scheduled work; it is recomputed opportunistically by
SwiftUI, so any observable change can trigger it.

## Confirmed findings and ruled-out causes

| Rank | Finding | Impact / frequency | Confidence | Expected cost |
| --- | --- | --- | --- | --- |
| 1 | Main-thread lane sorting performs filesystem metadata I/O inside the comparator | Critical interaction loss; every affected column body evaluation; worsens with ticket count | Confirmed by mounted queue-delay benchmark and installed symbols | Medium |
| 2 | Project/ticket discovery repeats scans and synchronous Git/registry activation across independent refreshers | High sustained CPU and intermittent route stalls while sessions are active | Confirmed by installed symbols and source boundaries; exact user-visible share varies | Medium |
| 3 | CoreGraphics terminal render submission costs roughly 24–29 ms; provider TUI adds separate latency | Medium typing softness, especially Claude and cold startup; independent of board | Confirmed by real PTY and actual provider TUIs | Medium |
| 4 | Manual idle-ticket movement into In Progress is accepted despite worker-owned lifecycle expectations | High semantic confusion; can look like a drag-policy inconsistency | Confirmed by mounted policy path and source | Low |

Ruled out or not supported:

- **Sparkle as the “Checking for updates” stall:** ruled out. The visible label
  is set by `ProgramBoardOverlayController.checkForUpdates`; Sparkle's scheduled
  interval is 24 hours.
- **Reveal animation as the sustained cause:** ruled out. RR-209/RR-219 timing
  probes remain finite and the reproduced stall occurs on a fully mounted board.
- **Eligible drag policy as the primary failure:** ruled out for Backlog →
  Queued. The direct policy and event path accepts it in under one millisecond;
  the event is delayed when main work runs first.
- **Terminal process/view recreation:** ruled out. `EmbeddedTerminalSession`
  retains one AppKit view/process across SwiftUI tab/surface changes.
- **Unbounded SwiftTerm PTY backlog:** not reproduced. The current 4 MiB/1 MiB
  watermarks bound it; high output completed without runaway process RSS.
- **Private transcript diagnostics by default:** ruled out for the captured
  session. The feature is marker-gated and disabled normally.
- **Metal as an automatic fix:** ruled out by both SwiftTerm versions.

Still unproven:

- Worker count may increase invalidation and daemon/dashboard work, but the
  one-worker installed sample used the Terminal tab and cannot isolate that
  factor. Do not use the 18–35% versus 4–10% samples as a worker-scaling curve.
- The exact display-present latency of Metal requires an installed-app Metal
  System Trace or external presentation measurement; the XCTest metric ends at
  submission.
- No formal Instruments hang was recorded even though queued interaction delay
  exceeded 750 ms. This looks like long synchronous work, not a lock deadlock.

## Comparative implementation research

### Ghostty

Pinned revision: `2dd79f3bc6af649e68422b08e21ad0300fd8b391`.

| Exact pattern | Relay hypothesis and local measurement | Decision |
| --- | --- | --- |
| `src/termio/Thread.zig:1-12` dedicates a writer/event thread and keeps the reader hot path focused on parsing and terminal state. | Relay input/send is already sub-millisecond and SwiftTerm already has read/write dispatch queues and backpressure. A replacement IO engine is not justified. | Reject a libghostty/IO rewrite; retain the latency segmentation as a regression gate. |
| `src/renderer/Thread.zig:21-69,282-310,546-660` owns a render mailbox/thread, changes QoS with visibility/focus, and rebuilds/draws on wakeup. | Relay's CoreGraphics output/display work is main-thread work at 24–29 ms, while Workspace can block that main thread for 0.7–0.8 s. A narrower render boundary is relevant after the board fix. | Adapt the visibility/on-demand and queue-boundary ideas in a later renderer spike; do not replace SwiftTerm. |
| `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:9-10,212-264,1078-1156` makes AppKit own input/state and caches expensive screen-content reads for 500 ms. `Ghostty.Surface.swift:45-69` is a narrow main-actor wrapper over the core. | Relay already gives AppKit ownership to a persistent `RelayTerminalView`; the board finding independently proves the value of precomputed/cached data instead of I/O during rendering. | Adapt the cache-before-view principle to ticket ordering; keep the existing terminal ownership. |

Ghostty's architecture is evidence for separating hot terminal work from UI
composition, not evidence that an embedded app should import `libghostty`.

### CodeEdit

Pinned revision: `cec6287a49a0a460cd7cab17f254eebc3ada828e`.

| Exact pattern | Relay hypothesis and local measurement | Decision |
| --- | --- | --- |
| `TerminalCache.swift:11-41` retains terminal NSViews outside the SwiftUI hierarchy. `TerminalEmulatorView.swift:15-20,148-177` reuses them through `NSViewRepresentable`. | Relay's `EmbeddedTerminalSession` already owns a long-lived process/view (`EmbeddedTerminal.swift:33-70`) and its host only borrows that view. No recreation appeared in the trace. | Adopted already; reject a terminal-cache rewrite. |
| `UtilityAreaTerminalView.swift:91-120` gives the selected terminal a stable ID and embeds it in a constrained native view. | Relay's host has the same stable AppKit boundary. The measured cost is renderer work, not SwiftUI identity churn. | Retain Relay's current boundary. |
| `CELocalShellTerminalView.swift:12-21` is a deliberate SwiftTerm fork/copy that survives zero-sized removal and background operation. | CodeEdit's workaround is specific to its lifecycle. Relay does not zero/recreate its retained process view and did not reproduce this failure. | Reject copying the fork. Add only a focused lifecycle regression if Relay later changes host behavior. |

CodeEdit does not pin upstream SwiftTerm. Its Xcode project uses
`https://github.com/thecoolwinter/SwiftTerm`, branch `codeedit`, at revision
`2f36f54742d3882e69ff009d084e8675b80934bd`. Its behavior therefore cannot
substitute for testing upstream 1.14.0/1.15.0 in Relay.

### SwiftTerm 1.15.0

Between the pinned revisions, relevant upstream commits are:

- `d83d8a1` — power-of-two Metal buffer size classes to stop unbounded pool
  growth under changing content;
- `f02e34b` — avoid packaged-app `Bundle.module` fatal errors;
- `d6e0709` — glyph-atlas overflow hardening;
- `ac99a54`, `91863f0`, and `dd2fb8a` — mouse/focus/scroll corrections; and
- `f11586b` through `be0300c` — Korean IME transaction fixes.

The local comparison finds no latency win but does identify correctness and
memory-safety reasons for a guarded upgrade. Upgrade and renderer selection
must remain separate decisions.

## Remediation verification budgets

| Boundary | Current | Required gate |
| --- | ---: | ---: |
| Cached 227-ticket lane ordering | 553/708 ms p50/p95 | <8 ms p50, <16.7 ms p95 on main |
| Hover feedback when a dashboard result lands | 792 ms | <16.7 ms p95 |
| Eligible drag target when a dashboard result lands | 761 ms | <25 ms p95; no lost drag |
| Main-actor route/scope preparation | Sync Git/process work present | <5 ms p95 and no `Process.waitUntilExit` on main |
| One-second activity refresh | Full project/ticket discovery | <25 ms background CPU p95; zero main I/O |
| Input commit → SwiftTerm send | <0.06 ms p95 | Preserve <1 ms p95 for Codex and Claude |
| Send → PTY echo upper bound | 1.44–2.30 ms p95 | Preserve <5 ms p95 |
| CoreGraphics output → render submit | 28–29 ms p95 | <16.7 ms p95 preferred, <25 ms hard ceiling |
| Full changing terminal frame | 35–38 ms p95 CG; ~49 ms Metal | <25 ms p95 before changing renderer default |
| 662 KiB high-output workload | 910–921 ms CG | No slower than current CG; bounded RSS and no main queue starvation |

Run the board gate at 25, 100, 227, and 500 synthetic/real ticket items to
guard the growth curve, not only the current fixture size.

## Structured PM/orchestrator handoff

The audit worker must not create unrelated ticket files. The following is the
complete, ordered materialization input for the foreground PM/orchestrator.
All items must be created in Backlog and none may be dispatched merely because
this audit is accepted.

```yaml
relay_runner_ticket_handoff:
  version: 1
  source_ticket: RR-237
  state: materialized
  generated_ticket_ids:
    cache_workspace_lane_order: RR-241
    coalesce_project_activity_discovery: RR-242
    protect_worker_owned_in_progress: RR-243
    upgrade_swiftterm_1_15_guarded: RR-244
  tickets:
    - key: cache_workspace_lane_order
      order: 1
      title: Cache Workspace ticket ordering outside SwiftUI body evaluation
      status: backlog
      priority: urgent
      depends_on: []
      description: >-
        Remove filesystem metadata reads and identity reconstruction from the
        Program Workspace lane comparator. Carry one stable modification/sort
        key per dashboard item or precompute ordered lane arrays when a snapshot
        changes, then render those stable values without restatting files.
      likely_files:
        - Sources/relay-runner/Board/ProgramBoardStatus.swift
        - Sources/relay-runner/Board/ProgramBoardOverlayView.swift
        - services/program_status.py
        - tests/RelayRunnerTests/ProgramBoardStatusTests.swift
      acceptance_criteria:
        - No URL resource-value read or ticket-path reconstruction occurs inside a sort comparator or SwiftUI column body.
        - A 227-ticket mounted benchmark meets <8 ms p50 and <16.7 ms p95 lane ordering.
        - Queued hover is <16.7 ms p95 and eligible drag feedback is <25 ms p95 during snapshot replacement.
        - Ordering remains newest-ticket-file first with deterministic ID/title fallback in Project and Program scopes.
        - Relevant Swift and Python status/dashboard suites pass.
      worker_model: strong
      worker_effort: high
      worker_sizing_rationale: >-
        The change crosses the Python dashboard contract and SwiftUI snapshot
        invalidation but has a tightly measured hot path and bounded surface.
      worker_provider_notes: >-
        Provider-neutral Workspace behavior; validate equivalent foreground
        interaction while Codex or Claude is active.

    - key: coalesce_project_activity_discovery
      order: 2
      title: Coalesce Workspace route and activity project discovery
      status: backlog
      priority: high
      depends_on: []
      description: >-
        Stop one-second notch/sleep/dashboard refreshers from independently
        reclassifying repositories, synchronously launching Git, rewriting
        unchanged registry activation, and rescanning the same tickets. Build a
        cached activity/run snapshot with explicit invalidation and move all
        subprocess and filesystem discovery off the main actor.
      likely_files:
        - Sources/relay-runner/App/AppState.swift
        - Sources/relay-runner/Board/ProjectResolver.swift
        - Sources/relay-runner/Board/ProjectRegistry.swift
        - Sources/relay-runner/Board/ProgramBoardOverlayController.swift
        - Sources/relay-runner/Process/ProcessManager.swift
        - tests/RelayRunnerTests/ProjectRegistryTests.swift
      acceptance_criteria:
        - No Process.waitUntilExit, Git subprocess, registry write, or ticket-directory scan runs on the main actor during a steady active session.
        - Unchanged bridge/project state does not rewrite the registry or repeat repository classification.
        - Concurrent notch, sleep, and dashboard consumers share or coalesce one in-flight refresh and cancel it on service/session stop.
        - Route/scope preparation is <5 ms p95 on main and the background activity refresh is <25 ms p95 at 227 tickets.
        - Project Workspace, Program Workspace, workspace-root discovery, Codex, and Claude lifecycle regressions pass.
      worker_model: strong
      worker_effort: xhigh
      worker_sizing_rationale: >-
        Lifecycle, cache invalidation, subprocess isolation, and three
        independent refresh consumers create a broad concurrency risk.
      worker_provider_notes: >-
        Preserve identical project routing and activity visibility for Codex
        and Claude; provider metadata may differ but refresh semantics must not.

    - key: protect_worker_owned_in_progress
      order: 3
      title: Enforce worker ownership of the In Progress lane
      status: backlog
      priority: high
      depends_on: []
      description: >-
        Align ProgramBoardDropPolicy with the orchestrator lifecycle so an idle
        ticket cannot be manually moved into In Progress. Keep Backlog to Queued
        eligible and dispatched, and surface invalid drop feedback without
        conflating policy rejection with event latency.
      likely_files:
        - Sources/relay-runner/Board/ProgramBoardStatus.swift
        - Sources/relay-runner/Board/ProgramBoardOverlayView.swift
        - tests/RelayRunnerTests/ProgramBoardStatusTests.swift
        - tests/RelayRunnerTests/RR237ResponsivenessBenchmarkTests.swift
      acceptance_criteria:
        - Backlog to Queued remains eligible and requests dispatch when dependencies permit.
        - Manual Backlog/Queued/Done to In Progress is rejected unless a documented orchestrator-owned transition API performs it.
        - Active-worker and awaiting-merge cards remain non-draggable.
        - Mounted tests distinguish rejected-policy feedback from a delayed eligible drag and keep eligible feedback <25 ms p95.
      worker_model: balanced
      worker_effort: medium
      worker_sizing_rationale: >-
        This is a small policy change with user-visible drag semantics and
        focused regression coverage.
      worker_provider_notes: >-
        Provider-neutral board lifecycle; Codex and Claude workers own the same
        In Progress transition.

    - key: upgrade_swiftterm_1_15_guarded
      order: 4
      title: Upgrade SwiftTerm to 1.15.0 with installed renderer gates
      status: backlog
      priority: medium
      depends_on:
        - cache_workspace_lane_order
      description: >-
        Upgrade upstream SwiftTerm for its Metal buffer-growth, packaged-app,
        mouse/focus/scroll, and IME fixes while retaining CoreGraphics as the
        default. Make renderer activation fail safely, validate SwiftPM resource
        packaging in the installed app, and keep Metal opt-in until it beats the
        RR-237 latency and high-output budgets.
      likely_files:
        - Package.swift
        - Package.resolved
        - Sources/relay-runner/Terminal/EmbeddedTerminal.swift
        - tests/RelayRunnerTests/EmbeddedTerminalSessionTests.swift
        - tests/RelayRunnerTests/RR237ResponsivenessBenchmarkTests.swift
        - scripts/build-dmg.sh
      acceptance_criteria:
        - Package resolution pins SwiftTerm 1.15.0 at dd2fb8ac5b861e7bf617c872895e338f38165648.
        - A DMG-installed app loads the SwiftTerm Metal resources without fatal error and falls back to CoreGraphics on any activation error.
        - CoreGraphics remains the default unless Metal achieves <25 ms p95 full-frame latency and is no slower on the 662 KiB high-output workload.
        - CPU-side latency, Metal System Trace GPU data, RSS, mouse reporting, selection, scroll, focus, Korean IME, and packaged launch are recorded.
        - Equivalent Codex and Claude sessions preserve <1 ms p95 input-to-send and <5 ms p95 PTY round-trip upper bound.
        - Full Swift tests and the DMG build pass.
      worker_model: balanced
      worker_effort: high
      worker_sizing_rationale: >-
        The package bump is small, but renderer resources, installed packaging,
        AppKit input correctness, and performance gates require careful UAT.
      worker_provider_notes: >-
        Shared terminal engine with separate real Codex and Claude TUI smokes;
        document provider-startup variance rather than changing shared input.
```

The PM/orchestrator materialized this handoff atomically in `209db1a`, replacing
the final item's symbolic dependency with `RR-241`, allocating `RR-241` through
`RR-244` with the matching `.orchestrator/config.toml` update, and leaving all
four generated tickets in Backlog.
