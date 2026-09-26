# RR-379: local intent qualification experiment

This experiment lives on `codex/laya-intent-qualification`. It is not approved for
production routing or automatic merge. Local Laya is fast enough in the measured
warm tests, but the stock checkpoints did **not** improve qualification accuracy
on the independent synthetic set. Keep the PM authoritative.

The three choices are Task (project work, tickets, spikes and workers), Action
(bounded foreground operations), and Discussion (research, status, explanation,
ideas and feasibility). Both Codex and Claude use the same contract. Laya emits
one fixed-choice answer; it does not generate prose or execute a command.

## What the branch changes

`services/laya_qualification.py` supplies a standard-library-only bridge client
and an explicitly loaded MLX adapter. `RELAY_LAYA_TEST_MODE=1` enables a bounded
request to a preloaded local service through a private Unix socket. The default
is off. The branch's voice bridge submits to Messenger first, then attaches an
advisory Laya result to the PM metadata and prompt. Existing actions, work
dispositions, cancellation, authorization, and current-command checks are not
changed by the Laya result. The complete original request remains in the prompt.

The PM always qualifies the command, including hints with high probabilities.
Probabilities are not calibrated for RR. Negations, corrections, references and
detected mixed requests abstain; raw model decisions remain visible in evaluation
results so these guards cannot conceal model errors. They are conservative
heuristics, not comprehensive semantic protections. The observed errors show why
the hint cannot become execution authority.

No model download or runtime import occurs on ordinary startup or a voice command.
An absent service returns immediately; one absolute client deadline covers
connect, send and receive, capped at 100 ms. Stale response identities are dropped.
Inputs that exceed the actual checkpoint state budget abstain rather than silently
truncate. There is no network endpoint or cloud inference option.

The evaluator and preview accept ordered `role`/`content` conversation context.
The current live bridge does not own complete provider conversation history, so
its hint receives the current utterance only. References therefore stay with the
PM. Do not infer context-aware voice accuracy from the isolated context fixtures.

## Reproduce setup

Requirements: Apple Silicon, macOS 14 or later, Python 3.11 or later, and a session
with Metal GPU access. The measured machine is an Apple M4 with 24 GiB unified
memory, macOS 26.7 and Python 3.13.13. Sandbox processes may report “No Metal device
available”; the measurements used explicitly approved GPU access.

From this branch's checkout:

```sh
cd /private/tmp/relay-laya-intent-qualification
/opt/homebrew/bin/python3.13 -m venv /private/tmp/rr-laya-runtime
/private/tmp/rr-laya-runtime/bin/python -m pip install -r experiments/laya/requirements.txt
HF_HOME=/private/tmp/rr-laya-hf /private/tmp/rr-laya-runtime/bin/python scripts/relay-laya-qualify setup --checkpoint english --model-dir /private/tmp/rr-laya-models/english
HF_HOME=/private/tmp/rr-laya-hf /private/tmp/rr-laya-runtime/bin/python scripts/relay-laya-qualify setup --checkpoint multilingual --model-dir /private/tmp/rr-laya-models/multilingual
```

Only `setup` contacts the public model host. It pins the full checkpoint revision
and verifies the published weights SHA256. Dependencies are exactly pinned in
`requirements.txt`; the runtime is `laya-mlx==0.2.0`, `mlx==0.32.2`, FP16 on GPU.
Checkpoints, environments and caches stay outside tracked source. English uses
revision `047678560251f28113ee8f5df4be82102c7bf336`; multilingual uses
`ba40c87fcb357f1643d04d71323af9cdc3b9e591`.

## Start a separate read-only test session

In one terminal, preload a service. It prints `ready: true` only after loading and
warming the model:

```sh
mkdir -p /private/tmp/rr-laya-preview
chmod 700 /private/tmp/rr-laya-preview
/private/tmp/rr-laya-runtime/bin/python scripts/relay-laya-qualify serve --checkpoint english --model-dir /private/tmp/rr-laya-models/english --socket /private/tmp/rr-laya-preview/qualifier.sock
```

In another terminal in the same checkout:

```sh
/opt/homebrew/bin/python3.13 experiments/laya/preview_session.py --socket /private/tmp/rr-laya-preview/qualifier.sock --provider codex
```

Type utterances to see the baseline action, local hint and resulting PM prompt.
The preview preserves each complete utterance and includes the shared baseline
`IntentQualification`. It does not normalize or deliver real bridge work items.
This is a read-only terminal preview, not microphone or provider UAT. Nothing is
sent to Codex/Claude, the installed app, the daemon, email or the desktop. Use
`--provider claude` for the equivalent metadata contract, `--text 'Open Chrome'`
for one request, and `--context /path/to/context.json` for known conversation.
Context is explicit and static; the preview does not invent previous PM replies.
Ctrl-D exits the preview; Ctrl-C stops the service.

The actual branch voice hook uses `RELAY_LAYA_TEST_MODE=1` and
`RELAY_LAYA_SOCKET=/private/tmp/rr-laya-preview/qualifier.sock` in the source bridge
process environment. Do not launch a second standard bridge beside an active
installed session: RR still has shared global voice transport paths. The preview
above exists to test safely without installing or restarting the app. A later
controlled installed-app voice test is separate work.

## Read-only evaluation

```sh
/private/tmp/rr-laya-runtime/bin/python scripts/relay-laya-qualify evaluate --checkpoint english --model-dir /private/tmp/rr-laya-models/english --corpus tests/fixtures/intent_qualification_holdout.json --split all --output /private/tmp/laya-english-holdout.json
/private/tmp/rr-laya-runtime/bin/python scripts/relay-laya-qualify evaluate --checkpoint multilingual --model-dir /private/tmp/rr-laya-models/multilingual --corpus tests/fixtures/intent_qualification_holdout.json --split all --output /private/tmp/laya-multilingual-holdout.json
/private/tmp/rr-laya-runtime/bin/python experiments/laya/measure_ipc.py --model-root /private/tmp/rr-laya-models --corpus tests/fixtures/intent_qualification_holdout.json --output /private/tmp/laya-ipc.json
```

`measure_ipc.py` starts its own sequential English/multilingual services, measures
the actual bridge client, and stops them. It never starts RR's voice bridge.
For the shared development cases, change the corpus to
`tests/fixtures/intent_qualification.json` and pass `--split development`.

Results include every decision, probabilities, command identity, fallback reason,
confusion matrix, false Task/Action decisions, coverage, per-sample timings,
checkpoint/runtime identity and input hashes. Load time is separate from warm
inference. `mx.synchronize()` completes GPU work within the timing boundary.
The cold first-call cost is excluded from warm latency but reported explicitly.
Development fixtures and the independent holdout are separate. Do not tune on this
holdout and then call it held out again.

## Measured results, 2026-09-26

The prompt was frozen before the foreground reviewer supplied 36 independent
synthetic stress cases (10 Tasks, 10 Actions, 16 Discussions). Two Discussion
labels represent unresolved inputs; `resolved_only` reports the other 34
separately. This small synthetic set is not a population accuracy estimate.

| Metric | English | Multilingual |
| --- | ---: | ---: |
| Raw correct / all 36 cases | 23 (63.9%) | 17 (47.2%) |
| Raw correct / 34 resolvable cases | 23 (67.6%) | 17 (50.0%) |
| Discussion wrongly called Task/Action / 16 | 4 | 15 |
| Guarded hint coverage | 26/36 (72.2%) | 26/36 (72.2%) |
| Guarded correct / 26 covered | 16 (61.5%) | 14 (53.8%) |
| Guarded false Discussion activations | 2 | 8 |
| Offline warm p50 / p95 | 41.41 / 43.44 ms | 16.65 / 17.25 ms |
| Actual warm IPC p50 / p95 | 42.63 / 50.09 ms | 15.82 / 16.59 ms |
| Actual warm IPC maximum | 52.30 ms | 16.93 ms |
| IPC timeouts / model-service errors | 0 / 0 | 0 / 0 |
| Process start to ready, warmed filesystem | 666 ms | 940 ms |

Each timing run used three repetitions of each case (108 calls/checkpoint), after
warmup. Runs were sequential, so the offline and IPC numbers are separate samples,
not a subtraction estimate of IPC overhead. The first-ever English probe took
about 1.49 s to load and 1.07 s for its first inference before warmed filesystem /
Metal caches; never load on a voice command.

The raw English model recognised 9/10 Actions but only 2/10 Tasks. The multilingual
model wrongly treated 15/16 Discussions as execution buckets. For example,
“What would happen if we dispatched all three tickets together?” was classified
Action with probability 0.9779, and a past-shipping question was Task with 0.9544.
This reproduces the broader confidence/semantic concern with RR-specific inputs.

The measured warm latency meets the proposed p95 <=100 ms target. Accuracy does
not support adopting either stock checkpoint as RR's routing authority. An
RR-specific training experiment may be justified, using new training data and a
new untouched holdout. The initial evaluation did not fine-tune, calibrate, tune
thresholds, or select prompts against the holdout.

On the shared development corpus, English scored 22/38 and multilingual 16/38
three-way cases; the two control cases are excluded from these bucket-accuracy
denominators. The deterministic framework matched all 38 development labels.
These were development fixtures, so the independent results remain the relevant
comparison for generalisation.

On the same holdout, the new deterministic framework scored 24/36 (66.7%), versus
23/36 (63.9%) for the legacy action-kind mapping. Both made one false Task/Action
decision on a Discussion. This modest change also needs more evaluation; none of
these small-set results establish reliable automatic intent qualification.

Committed raw reports in `results/` preserve both baseline comparisons and the
exact evaluated prompt/source hashes. The framework comparison was added after
cherry-picking baseline commit `e20f5179`; the frozen raw Laya outputs and timing
samples were retained without rerunning or tuning. Legacy baseline labels are
an explicit mapping from previous action kinds, not an existing shipped three-way
classifier.

Unperformed: installed-app deployment, physical microphone/voice UAT, actual
Messenger acknowledgement/PM completion timing, concurrent STT/TTS load, power or
memory-pressure measurement, and real-user distribution accuracy. All experiment
services used for the recorded tests were stopped; the installed app and daemon
were not restarted or modified.

## Regression verification

212 focused tests passed: 13 Laya client/guard/budget tests, 145 existing voice
bridge tests (including Messenger-before-Laya ordering), 30 command-action tests,
16 intent-arbitration tests, and eight framework/authority tests. The initial
voice run exposed a missing bundle manifest entry, which was corrected. One
duplicate-empty-warning test failed transiently in that run; it passed in
isolation and in both subsequent complete 145-test voice runs. No failure remains
in the final focused runs. Python compile checks and `git diff --check` also pass.

The runtime tests use explicit doubles to verify guards and transport; they are
separate from the recorded real MLX inference and warmed-service measurements.

## Disable / revert

Leave `RELAY_LAYA_TEST_MODE` unset (or set it to `0`) to skip the hook entirely.
Stop the optional service to release its memory. The experiment remains on its
branch; switching away removes its source integration. No settings, installed
application, launchd jobs, tickets or user voice state need restoring.

## Primary references

- [Laya-MLX runtime](https://github.com/mizorewww/laya-mlx)
- [Pinned publication revisions and hashes](https://github.com/mizorewww/laya-mlx/blob/main/benchmarks/results/hub-publication.json)
- [Upstream Laya](https://github.com/NandhaKishorM/laya)
- [Documented negation failure](https://github.com/NandhaKishorM/laya/issues/377)

Upstream latency figures are not the RR measurements above. The MLX port is an
independent Apache-2.0 project, not an official upstream runtime.
