# RR-72 Board New Ticket Creation Verification

Date: 2026-06-12
Branch: `relay/rr-72`
Run: 69

## Result

PASS. The integrated project-board and Program Board creation paths are covered by focused Swift tests for deterministic file/model behavior, plus manual verification notes for the UI lifecycle that depends on the live macOS overlay.

## Automated Coverage

- `BoardProjectConfigTests.testMintDraftClaimsSelectedProjectNextIdWithoutMutatingPeerProject` verifies project-board creation claims the selected repo's `next_id`, writes the selected repo ticket, and leaves a peer repo's config and ticket files untouched.
- `BoardProjectConfigTests.testProjectBoardCreatedDraftCanBeSavedAndDeleted` verifies the project-board draft/editor lifecycle primitives: a newly minted draft is marked as a new editor item, save clears `draft` while preserving title/description, and delete removes a newly-created ticket file.
- `ProgramBoardStatusTests.testProgramBoardCreateFlowRequiresProjectWhenAllSelectedAndPreselectsFilteredProject` verifies all-project Program Board creation cannot mint without a registered project, rejects unknown project paths, and preselects the filtered project for single-project scope.
- `ProgramBoardStatusTests.testProgramBoardTicketCreatorWritesOnlySelectedProjectAndClearsDraft` verifies Program Board save writes only to the selected child repo, bumps only that repo's `next_id`, clears `draft`, and returns `shouldDispatch` for ready tickets.
- `ProjectRegistryTests.testBoardRouteOpensProgramBoardForWorkspaceBridgeSession` and `ProjectRegistryTests.testBoardRouteOpensProjectBoardForSingleProjectBridgeSession` cover workspace-session Program Board routing and single-project session project-board routing for both Codex and Claude provider metadata.

## Manual Verification Notes

Program Board creation from a workspace session:

1. Start a Relay session from a workspace folder with at least two child git repos.
2. Open the board and confirm it routes to Program Board without creating a parent `.orchestrator/`.
3. In All tickets scope, click a lane's new-ticket button and confirm the modal requires a project selection before Save enables.
4. Select a child project, save a backlog ticket, and confirm the ticket appears under that project after reload with only that child repo's `config.toml` incremented.
5. Repeat in the Ready lane and confirm save triggers the existing `program-board-save` auto-dispatch path.

Project-board creation from a single-project session:

1. Start a Relay session from a single git repo.
2. Open the board and confirm it routes to the project board and initializes/reuses that repo's `.orchestrator/config.toml`.
3. Click a lane's new-ticket button and confirm the existing editor opens for the new draft.
4. Cancel and confirm the unsaved draft file is deleted; create again, save title/description, and confirm `draft` is removed.
5. Create/save in Ready and confirm save triggers the existing `board-save` auto-dispatch path only after the editor save.

## Provider Parity

Ticket creation is provider-neutral. Codex and Claude sessions both route through `ProjectResolver`, `ProjectRegistry`, `TicketWriter`, and the same `.orchestrator/` ticket/config files. Provider-specific behavior is limited to session launch/auth metadata; no provider-specific ticket creation branch exists.

## Checks

- `swift test --skip-update --filter BoardProjectConfigTests` - PASS, 17 tests.
- `swift test --skip-update --filter ProgramBoardStatusTests` - PASS, 18 tests.
- `swift test --skip-update` - PASS, 131 XCTest tests and 0 Swift Testing tests.
- `python3 -m unittest discover tests` - PASS, 55 tests.

## Residual Risks

- This isolated worker did not launch the live menu-bar app or operate the overlays visually; the UI steps above remain the live manual checklist.
- The tests use temporary fixture repos and registry files rather than the user's live workspace registry.
