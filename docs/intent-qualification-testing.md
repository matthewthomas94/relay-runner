# Task / Action / Discussion testing

This source baseline adds no inference call or dependency. Messenger still receives each turn before deterministic qualification. The bridge publishes a provisional bucket, command identity, unresolved/mixed flags, and original wording to the PM, and updates public Messenger context afterward. Both Codex and Claude use the same contract. Existing control, cancellation, inbox, and mutation ledger paths remain separate.

Tasks request project implementation or explicit tracking/delegation. Actions are bounded foreground operations (including shell/API calls). Discussion covers research, feasibility, explanation and status even when read-only tools are used. Labels do not grant authority. The PM resolves references, recipients, ordered mixed requests and permission. A bare assent remains unresolved; the rules do not reconstruct dialogue from private provider traces. Explicit no-dispatch/backlog-only constraints retain ticket-authoring permissions but remove dispatch and worker-request permissions.

## Source evaluation

From this checkout, using the repository Python runtime:

```sh
python3 scripts/evaluate-intent-qualification.py > /tmp/intent-qualification-development.json
python3 -m unittest discover -s tests -p 'test_intent_qualification.py'
python3 -m unittest discover -s tests -p 'test_command_actions.py'
python3 -m unittest discover -s tests -p 'test_intent_arbitration.py'
python3 -m unittest discover -s tests -p 'test_voice_bridge_preemption.py'
python3 -m unittest discover -s tests -p 'test_messenger.py'
python3 scripts/build-instructions --check
```

The evaluator reads the legacy classifier from commit `09b0885b68761156127143debc03031761749e01` via Git and compares it with the current framework. It only classifies text; fixtures cannot send email, open applications, invoke a provider, create tickets or dispatch workers. `--corpus /path/to/corpus.json` permits a separately collected blind evaluation set. `--repeats 100` measures qualification-only p50/p95, excluding STT, provider, transport and action execution. An increase here is not end-to-end voice latency. Results include every prediction, confusion counts, action-kind errors and false Task/Action predictions.

The initial 2026-09-26 development run on this Mac (Python 3.9.6, 100 repetitions per case) matched 40/40 expected buckets and internal routes, versus 30/40 for the legacy classifier. Legacy had three Discussion-to-Task/Action errors and three Task/Action confusions; this framework had zero on these fixtures. Qualification-only p50/p95 was 0.0178/0.0391 ms versus legacy 0.0123/0.0275 ms. These are local development-fixture measurements, not a production accuracy or latency claim.

After the classification rules were frozen, a foreground reviewer evaluated 36 independently authored synthetic stress cases using Python 3.13.13. The framework matched **24/36** expected buckets, versus **23/36** for legacy. Both produced **one Discussion-to-Task error**. Framework qualification-only p50/p95 was **0.0234/0.0445 ms**, versus legacy **0.0150/0.0290 ms**. This modest improvement on unseen wording is a more cautious signal than the development result: unfamiliar paraphrases and the inherited stop-word/control behavior still require PM resolution. No classification changes or tuning were made using these holdout results.

The exact [independent corpus](intent-qualification-results/rr-intent-independent-holdout.json) and [raw comparison results](intent-qualification-results/rr-baseline-independent-holdout-result.json) are retained outside the regression suite as evidence. The reviewer authored the cases before inspecting the implementation, kept them separate from development fixtures, and evaluated after the rules froze. These are synthetic stress cases, not actual voice recordings, a population accuracy estimate, or measured PM decisions. End-to-end PM accuracy, actual voice qualification accuracy, and voice response latency remain unmeasured. Paths inside the raw result identify the original evaluation inputs; the checked-in copies preserve those files unchanged.

`tests/fixtures/intent_qualification.json` is a synthetic **development** corpus, including positive commands, politeness, corrections, negation, mixed turns, status, spikes, controls and contextual assent. Its results are regression evidence, not held-out accuracy or evidence about real user speech. Freeze rules/prompts before evaluating a separate holdout; record its provenance and do not tune against its labels. The `context` field supports experiment parity, but the deterministic baseline deliberately defers context-dependent assent to the PM.

## Existing workflow trial

Source tests do not change the installed app. After reviewed integration and a separately coordinated preserving install, start a normal Codex session and a normal Claude session in a disposable test project. Try the corpus's Discussion and explicit backlog-only cases first. Check the claimed command's `intent_qualification`, original wording and authoritative PM reply. No tickets should result from discussion or status, and backlog-only should not dispatch. For mixed turns, verify the PM preserves every requested operation and resolves scope before mutation. For “Yes, do that”, verify the PM uses the actual pending proposal.

Then test a harmless Action such as opening an already available browser and confirm it stays foreground. Dev-server and email examples are classification-only fixtures until their arguments and desired effects are explicitly supplied for a live trial. A draft request must not send email. Genuine test-ticket creation and dispatch require a disposable project and explicit trial authority. Verify accepted-work continuity by asking for status during a test worker run; the status turn must not cancel it. Measure existing speech-latency events alongside qualification timing, especially Messenger submission, first speech and PM delivery. The installed end-to-end trial is unperformed by this source change.

## Rollback and limitations

Keep the Laya experiment on its separate branch; this baseline imports no ML runtime. To undo the baseline after integration, revert its reviewed commit and use the normal preserving install when the session is safe to restart. For source-only tests, leave the isolated worktree and use the unchanged original checkout. Do not reset unrelated notes work.

These small rules improve known wording but are not semantic understanding. Unknown paraphrases, scoped corrections and incomplete audio may still need PM correction. Mixed bucket requests conservatively preserve the full turn as unresolved Discussion rather than granting mutation from a partial clause. No confidence score is claimed. Production acceptance requires held-out and actual voice evidence; source tests alone do not establish installed UI, audible behavior, real-world accuracy or end-to-end latency.
