# RR-340 Workspace history and retention verification

This record keeps source verification separate from physical installed-app evidence. A passing unit test, source build, or disposable Git harness is not evidence that a signed app mounted from a DMG behaved correctly on another Mac.

## Source and contract checks

| Check | Evidence | Result |
|---|---|---|
| Mixed Done/Canceled pool and archived-card exclusion | `python3 Tests/test_program_status.py` | Passed as part of 21 tests |
| Unlimited nonterminal lanes | `python3 Tests/test_program_status.py` | Passed as part of 21 tests |
| History decoding, state badges, scoped requests, storage copy, accessibility labels | `swift test --filter 'WorkspaceHistoryTests\|OrchestratorClientTests\|ProgramBoardStatusTests\|WorkspaceDotMatrixTests'` | Passed, 114 tests |
| 300 terminal records, history/restore, offline/tamper, interrupted retention, storage separation | Six selected `test_artifact_retention.py` cases under Python 3.13 | Passed, 6 tests in 555.828 seconds |
| Scoped daemon response contract | `test_retention_history_and_storage_client_contracts_are_scoped_and_provider_neutral` under Python 3.13 | Passed |
| Codex/Claude parity | Same Workspace UI and provider-neutral `/v1/artifacts` contracts; provider is metadata only | Passed in source/contract coverage |

## Physical and mounted UAT

| Scenario | Required evidence | Current result |
|---|---|---|
| Mounted fresh install | Developer ID signed and notarized app launched from a mounted release image; History and Storage exercised | Not run in this source worktree |
| Second device | Confirmed selected GitHub remote recovered on a separate clean device without source checkout state | Not run in this source worktree |
| Offline recovery | Installed app shows Needs Network, keeps files local, reconnects, and retries successfully | Not run in this source worktree |
| Publication/auth/divergence/integrity failure | Installed app shows actionable blocked state and no candidate file disappears before proof | Not run in this source worktree |
| 300-plus terminal migration | Installed app preview and apply checked against a project containing more than 300 terminal tickets | Not run in this source worktree |

These installed checks require an authorized signed build, mounted image, clean second-device environment, configured test remote, and failure-injection fixtures. Until that environment is supplied and the evidence is attached here, RR-340 is verification-blocked rather than physically validated.
