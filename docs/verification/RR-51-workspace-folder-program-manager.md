# RR-51 Workspace Folder Program Manager Verification

Date: 2026-06-06
Branch: `relay/rr-51`
Run: 37

## Result

PASS. The workspace-folder Program Manager flow is covered by app-level Swift tests, generated MCP instruction checks, and Python daemon tests. No runtime code changes were required for RR-51; the remaining gap was stale documentation and generated instruction text that still described bridge cwd resolution as "find the containing repo."

## Workspace-Folder Invariant

Relay Runner keeps the existing `general.working_directory` config key for compatibility, but the app now treats it as a workspace folder.

- A folder with direct child git repos is a workspace root. Discovery registers the root and child projects, records provider metadata, opens Program Board, and does not create a parent `.orchestrator/`.
- A single git repo is a project. Discovery/bridge activation opens that repo's project board and initializes `.orchestrator/config.toml` when needed.
- A non-git folder with no child git repos is refused. Relay Runner does not run `git init` implicitly.
- Codex and Claude use the same registry schema and resolver path. Provider-specific differences are limited to launch command flags and the provider metadata value written by Start Session (`codex` or `claude`).

## Migration Behavior

Existing installs migrate through the same resolver instead of a one-off data migration:

- On app launch, `AppState` refreshes non-empty configured workspace discovery.
- On saved workspace-folder changes, onboarding/settings force a refresh.
- On provider changes, the configured folder is refreshed so the provider metadata records the active Codex or Claude path.

The legacy single-repo case is intentionally preserved: a configured repo path migrates to one active project and may initialize that repo's `.orchestrator/config.toml`. A configured parent folder such as `/Users/matthewthomas/dev` migrates to a workspace root only when child repos are found.

## Verified Flows

Swift app/test-double coverage:

- `ProjectRegistryTests.testWorkspaceFolderRefreshDiscoversConfiguredWorkingDirectoryForBothProviders` verifies a multi-repo configured folder discovers child projects for Codex and Claude, records both provider metadata entries, and does not create a parent `.orchestrator/`.
- `ProjectRegistryTests.testWorkspaceFolderRefreshMigratesLegacySingleRepoWorkingDirectory` verifies a legacy single-repo `working_directory` opens one project board and initializes `.orchestrator/config.toml`.
- `ProjectRegistryTests.testBoardRouteOpensProgramBoardForWorkspaceBridgeSession` verifies board toggle routing for a workspace bridge session for Codex and Claude.
- `ProjectRegistryTests.testBoardRouteOpensProjectBoardForSingleProjectBridgeSession` verifies board toggle routing for a single repo bridge session.
- `ProjectRegistryTests.testBridgeResolveClassifiesWorkspaceRootWithoutCreatingParentBoard` verifies bridge cwd activation records a workspace root without returning a project board.
- `ProcessManagerLaunchTests.testLaunchScriptUsesWorkspaceFolderForCodexAndClaude` verifies Start Session launches both providers from the configured workspace folder and exports the provider metadata value consumed by the bridge.
- `GeneralConfigTests.testWorkspaceFolderResolvesLegacyWorkingDirectoryValues` verifies legacy `working_directory` strings still resolve as before.

Documentation and generated instruction updates:

- `docs/orchestrator.md` now documents repo vs workspace board routing, compatibility of the `working_directory` key, migration behavior, and Start Session provider parity.
- `docs/specs/orchestrator-tickets.md` now documents workspace-root classification and migration invariants in the ticket/board lifecycle spec.
- `services/instructions/board-hotkey.md` and `services/instructions/orchestration-workflow.md` now describe Program Board routing for workspace roots; generated MCP instruction payloads and `CLAUDE.md` were regenerated from those sources.

## Checks

- `python3 -m unittest discover tests` - PASS, 36 tests.
- `swift test` - PASS, 80 XCTest tests and 0 Swift Testing tests.
- `scripts/build-instructions --check` - PASS.
- `bash -n scripts/build-dmg.sh` - PASS.
- `bash -n scripts/relay-orchestrator` - PASS.
- `bash -n scripts/relay-bridge` - PASS.

Full DMG creation was not run because RR-51 changed docs and generated instruction text, not packaging behavior; local DMG builds also depend on optional `dmgbuild`, signing, and notarization setup. The packaging surface was covered by shell syntax checks, and the Swift build/test path compiled the updated generated MCP instruction constants.

## Residual Risks

- The live macOS menu-bar app was not launched and the Program Board was not visually inspected in this isolated worker run.
- Tests used temporary fixture repos and bridge/provider files rather than mutating the user's live `/Users/matthewthomas/dev` workspace or Application Support program registry.
- Workspace discovery only scans direct child directories for git repos; nested workspace discovery remains outside this ticket's scope.
