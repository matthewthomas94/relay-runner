# Laya-triggered computer actions: branch experiment

This extension is on `codex/laya-fast-actions`, based on the existing Task / Action /
Discussion evaluation in `codex/laya-intent-qualification`. It is **off by default**
and has not been installed for live voice testing. Laya supplies a local Action
decision; Relay code resolves and executes one exact operation. Laya does not
generate a shell command, coordinates, an email, or a multi-step plan.

## What this branch runs

Set both `RELAY_LAYA_TEST_MODE=1` and `RELAY_LAYA_FAST_ACTIONS=1` in the voice
bridge process, with `RELAY_LAYA_SOCKET` pointing to the already warm private
service described in [README.md](README.md). The service and installed app are
not started by a voice command. The branch requires one accepted voice item,
matching command identity, current-command freshness, Laya `Action` without an
abstention, and the shared framework's `Action` classification. It then requires
one exact, locally parsed operation. A missing model, timeout, disagreement,
mixed utterance or unsupported operation follows the normal PM path.

The current exact operations are:

| Example | Execution path |
| --- | --- |
| “Open Calculator”; “Bring up Google Chrome” | `/usr/bin/open -a` with argument vector |
| “Open https://example.com” | `/usr/bin/open` with validated HTTP(S) URL |
| “Open the project folder”; “Reveal /path in Finder” | `/usr/bin/open` for an existing path |
| “Press Escape”; “Press Command S” | Relay Actions app-side `key` host |
| “Type hello into the focused field” | Relay Actions app-side `type` host |
| “Click at 123, 456”; “Scroll down 3 lines at 123, 456” | Relay Actions app-side host with explicit coordinates |

The bridge sends a completed result directly to Messenger and does not publish a
second PM execution request. A submitted action whose completion cannot be
confirmed gets an uncertainty reply; Relay does not retry it automatically.
The optional flags and exact parser bound the experiment, but this is not yet a
production execution policy.

“Click Save,” “send an email,” “start the dev server,” and other commands needing
target discovery, account state, project-specific setup or more than one step
continue to the PM. This is a deliberate observed capability limit, not an
intent-label failure. The branch must not claim these were executed locally.

## Research and setup decision

[Laya-MLX](https://github.com/mizorewww/laya-mlx) describes Laya as a typed
decision model: `choice`, `score`, and yes/no in one forward pass, with no text
generation. Its reported short-question p95 is 13.92 ms on an M3 Max, excluding
load. The Relay-specific warm English service measured 42.63 ms p50 and 50.09 ms
p95 over actual Unix-socket calls on this M4; prompt length and runtime differ.
Keep the pinned English FP16 checkpoint loaded before voice input, run it offline
through the private socket, synchronize GPU work, and maintain the existing
absolute 100 ms client deadline. The service's two-second idle warmup avoids the
previously observed 171 ms first call after idle, at an unmeasured energy cost.

The [Laya-MLX runtime](https://github.com/mizorewww/laya-mlx) offers optional
compilation, padding and prompt caching for repeated questions, but describes
only modest measured speedups for its Snake workload and warns about first-use
compilation and shape costs. The experiment uses one stable three-choice
question; adding a second model question for operation selection would increase
work within the 100 ms budget. A local 12-case operation-choice probe got 11
expected labels but called “What would happen if we opened Calculator?”
`open_app` with 0.867 confidence. That probe is too small and unsafe to grant
operation authority, so the branch extracts operations from exact syntax.

[FluidUse](https://github.com/FluidInference/FluidUse#laya-typed-decisions)
reports a Core ML Laya decision around 3.7 ms per short question on an M5 Pro.
That is a different checkpoint and machine; its application accuracy and Relay
latency have not been measured here. Migrating runtimes before fixing intent
accuracy would not address false execution.

For arbitrary controls, the [Laya computer-use harness](https://github.com/ChenneyZhuang/laya-computer-use)
uses an Accessibility element table and a separate executor, but reports 0/12
control-selection cases for official Laya checkpoints. Its observed AX walk plus
model decision takes about 220 ms per step on the reported M4. This supports a
future Relay Actions Accessibility candidate API and task-specific training
experiment, not zero-shot execution of semantic clicks today. The custom Relay
Actions host remains the screen-control path in this repo.

The [upstream browser-control fine-tune](https://github.com/NandhaKishorM/laya/blob/main/docs/finetune_browser_agent.md)
shows a plausible training path: construct operation and element candidates,
include action history and completed states, train on task-specific examples,
then fit calibration and evaluate on held-out pages. Its reported real-task
success rose from 0% zero-shot to 62% for one fine-tuned checkpoint, with
17–23 ms model steps in that setup. Those numbers are browser-specific and
still leave substantial failures. A Relay desktop checkpoint would need its
own labeled AX/voice corpus and untouched holdout before it could select UI
controls or send external messages automatically.

## Verification boundary

Focused tests cover exact parsing, Task/Action/Discussion agreement, abstention,
stale commands, cancellation, one-item routing, argument-vector app launch and
Relay Actions forwarding. A live local dry run with execution mocked out gave:

| Utterance | Laya | Shared framework | Fast execution |
| --- | --- | --- | --- |
| Open Calculator | Action | Action | eligible |
| I want to talk through opening Calculator | Discussion | Discussion | blocked |
| Create a ticket to fix Calculator | Action | Task | blocked |

The third row demonstrates why the model alone cannot fire an action. No
installed voice-to-computer timing or false-action rate has been measured for
this new branch. A 20-call warm local dry run of “Open Calculator” took 33.92 ms
p50 and 35.57 ms p95 for Laya IPC plus shared routing with execution mocked;
all 20 were eligible. This excludes speech recognition, Messenger, the operating
system effect and spoken delivery. Before enabling it beyond testing, record
speech-end-to-effect p50/p95, wrong-action count, duplicate-action count,
stale-turn behavior, and
Messenger speech ordering on both Codex and Claude.
