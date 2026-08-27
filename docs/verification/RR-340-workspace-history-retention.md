# RR-340 Workspace history and retention verification

This record keeps source verification separate from physical installed-app evidence. A passing unit test, source build, or disposable Git harness is not evidence that a signed app mounted from a DMG behaved correctly on another Mac.

## Source and contract checks

| Check | Evidence | Result |
|---|---|---|
| Mixed Done/Canceled pool and archived-card exclusion | `python3 Tests/test_program_status.py` | Passed as part of 21 tests |
| Unlimited nonterminal lanes | `python3 Tests/test_program_status.py` | Passed as part of 21 tests |
| History decoding, state badges, scoped requests, storage copy, accessibility labels, and unique recovery errors | `swift test` | Passed, 806 tests; 3 skipped; 0 failures |
| 300 terminal records, history/restore, offline/tamper, interrupted retention, storage separation | Six selected `test_artifact_retention.py` cases under Python 3.13 | Passed, 6 tests in 555.828 seconds |
| Scoped daemon response contract | `test_retention_history_and_storage_client_contracts_are_scoped_and_provider_neutral` under Python 3.13 | Passed |
| Affected migration, lifecycle, orchestrator, and ready-sweeper regressions | 49 affected Python tests | Passed in 132.6 seconds |
| Codex/Claude parity | Same Workspace UI and provider-neutral `/v1/artifacts` contracts; provider is metadata only | Passed in source/contract coverage |
| Patch hygiene | `git diff --check` | Passed |

## Physical and mounted UAT

| Scenario | Required evidence | Current result |
|---|---|---|
| Mounted fresh install | Developer ID signed and notarized app launched from a mounted release image; History and Storage exercised | Passed on 2026-08-27 with the exact final DMG-mounted app |
| Second device | Confirmed selected GitHub remote recovered on a separate clean device without source checkout state | Not run; user explicitly accepted this remaining risk on 2026-08-27 |
| Offline recovery | Installed app shows Needs Network, keeps files local, reconnects, and retries successfully | Passed with a controlled missing GitHub remote and restored-remote recovery |
| Publication/auth/divergence/integrity failure | Installed app shows actionable blocked state and no candidate file disappears before proof | Passed for the mounted publication/synchronization failure path; affected files and refs remained intact |
| 300-plus terminal migration | Installed app preview and apply checked against a project containing more than 300 terminal tickets | Passed with 325 terminal and 8 unfinished tickets |

## Mounted evidence — 2026-08-27

- Final app notarization submission: `621f5454-c3c9-4893-8e78-05897aaf211f` (Accepted and stapled).
- Final DMG notarization submission: `4af0acf7-b9f8-4fa8-96e5-c63f7c56094a` (Accepted and stapled).
- Mounted and distribution app executable SHA-256: `371cb6642fe193e7c1270fd16b555d42639eb3178de92573f59481a3e4103a71`.
- DMG SHA-256: `fd60664d809e1748ea630b70fbe6d8e8fd1b297a794c551b5f769e278d09b962`.
- ZIP SHA-256: `f6a34faeb71efc357948dfe9dcf395df6dbeec6c20ba8d79d39da150166642a0`.
- The mounted app passed deep `codesign`, Gatekeeper reported `Notarized Developer ID`, and both the app and DMG passed stapler validation.
- `/Applications/Relay Runner.app` was deliberately preserved; its executable SHA-256 remained `1c5b3ce39a379a5c811083b11d988f1b3395fccd8848a354b5bb0b123f97d402` before and after the mounted run.

The mounted app selected the fixture project without re-entering the full setup loop and visibly retained the selected state. History search found archived RR-42, displayed its Canceled status, RR-1 dependency, and 27-byte `proof.png`, and did not recreate either file merely by viewing the record.

Storage preview reported 336 materialized files, 8 uncapped unfinished tickets, 25 retained Done-or-Canceled tickets, and 300 deletion candidates. Verified cleanup reduced the materialization to 35 files. A controlled missing-remote attempt then rendered one actionable synchronization error and disabled unsafe retry. At that point, all 333 ticket files, RR-42 and its attachment, the original artifact ref, and a clean working tree remained intact with no retention or materialization journal. Restoring the confirmed GitHub remote and recovering from the notarized bundle converged local ref, materialization metadata, sync metadata, and remote ref at `62d88a95f88397cdacdb260cbc67d27a3cb41b3b`; 33 ticket files and 35 total files remained, RR-42 and `proof.png` were absent, and the worktree and journals were clean.

The separate clean-device scenario was not executed and is not claimed as passed. The user explicitly accepted that residual risk on 2026-08-27, allowing RR-340 to close with the omission recorded rather than concealed.
