# RR-53 Claude Workspace Rollout Parity Verification

Date: 2026-06-06
Branch: `relay/rr-53`
Run: 38

## Result

PASS. Claude uses the same workspace-root versus project-repo classifier, registry shape, board routing, Program Manager capture schema, Graphify provider model, and Relay-message steering contract as Codex. No runtime parity bug was found.

The only code change for RR-53 is a focused unit test proving native session capture normalizes Claude provider metadata into Graphify. The rest of this pass is verification and documentation of existing provider-specific launch/auth differences.

## Side-by-Side Verification

| Area | Codex behavior | Claude behavior | Evidence |
| --- | --- | --- | --- |
| Start Session from workspace root | `ProcessManager` exports `RELAY_RUNNER_PROVIDER='codex'`, `cd`s to the configured workspace folder, and launches Codex with the relay-bridge prompt. `scripts/relay-bridge` writes that cwd to `/tmp/voice_bridge.cwd` before starting the daemon. | `ProcessManager` exports `RELAY_RUNNER_PROVIDER='claude'`, `cd`s to the same configured workspace folder, and launches Claude with `/relay-bridge`. The same bridge script writes the same cwd/provider metadata files. | `ProcessManagerLaunchTests.testLaunchScriptUsesWorkspaceFolderForCodexAndClaude`; `ProjectRegistryTests.testWorkspaceFolderRefreshDiscoversConfiguredWorkingDirectoryForBothProviders`; `ProjectRegistryTests.testBridgeResolveClassifiesWorkspaceRootWithoutCreatingParentBoard`. |
| Workspace root discovery | Direct child git repos are registered as projects, the workspace root is registered separately, active project is cleared, and the parent `.orchestrator/` is not created. | Same behavior. Claude provider metadata is recorded under the same `workspaceRoots[].providers["claude"]` shape. | `ProjectRegistryTests.testDiscoveryRegistersNonGitWorkspaceChildrenWithoutWorkspaceProject`; `ProjectRegistryTests.testWorkspaceFolderRefreshDiscoversConfiguredWorkingDirectoryForBothProviders`. |
| Start Session from single project repo | The bridge cwd resolves to a single project, initializes/uses that repo's `.orchestrator/config.toml`, and opens project-board behavior. | Same behavior. Claude metadata is recorded under `projects[].providers["claude"]`. | `ProjectRegistryTests.testDiscoveryTreatsSingleGitRepoAsActiveProject`; `ProjectRegistryTests.testWorkspaceFolderRefreshMigratesLegacySingleRepoWorkingDirectory`; `ProjectRegistryTests.testBridgeResolveRecordsProviderMetadataForCodexAndClaude`. |
| Board routing | A live bridge rooted in a workspace opens Program Board; a live bridge rooted in a single repo opens the repo board; an ambiguous parent repo with child repos prefers workspace-root routing unless the parent repo was explicitly activated as a project. | Same routing, using the same `ProjectResolver.resolveBoardRoute` path and normalized `claude` provider metadata. | `ProjectRegistryTests.testBoardRouteOpensProgramBoardForWorkspaceBridgeSession`; `ProjectRegistryTests.testBoardRouteOpensProjectBoardForSingleProjectBridgeSession`; `ProjectRegistryTests.testBoardRoutePrefersWorkspaceRootForAmbiguousParentRepo`; `ProjectRegistryTests.testExplicitParentProjectActivationCanOpenProjectBoard`. |
| Program Manager capture | `session_capture` writes `provider_key: codex` into capture node bodies when the caller passes Codex context. | `session_capture` normalizes `Claude Code`/Claude context to `provider_key: claude` and returns `provider: claude`. The daemon still requires callers to pass concise entries/context; it does not scrape provider transcripts for either provider. | `SessionCaptureTests.test_capture_creates_structured_nodes_and_links_existing_project_ticket_and_run`; `SessionCaptureTests.test_capture_normalizes_claude_provider_metadata`. |
| Graphify ingestion/status | Registered projects and runs create provider nodes/edges and can filter/report Codex runs. Codex stream logs can be inferred when explicit provider fields are absent. | Registered projects and runs create the same provider nodes/edges and can filter/report Claude runs. Claude stream-json logs can be inferred when explicit provider fields are absent. | `GraphifyIngestTests.test_ingests_registered_projects_tickets_dependencies_and_runs_idempotently`; `ProgramStatusTests.test_active_work_includes_project_ticket_and_provider_labels`; `GraphifyCoreTests.test_provider_neutral_run_representation`. |
| Relay-message steering | Generated Codex relay-bridge skill uses atomic command claiming, preemption checkpoints before new work/TTS, stale TTS suppression, and cooperative handling for already-running tools. | Generated Claude `/relay-bridge` command has the same contract and checkpoint text. Already-running shell commands/MCP calls are not hard-canceled for either provider; the user-facing fallback is newest-intent-wins before follow-up actions and before TTS. | `VoiceBridgePreemptionTests.test_latest_command_wins_before_agent_claims_input`; `VoiceBridgePreemptionTests.test_newer_command_suppresses_stale_tts_after_first_claimed`; `VoiceBridgePreemptionTests.test_generated_provider_skills_share_preemption_contract`. |

## Intentional Claude Differences

- Launch command: Claude uses `claude ... "/relay-bridge"` because Claude Code exposes relay startup as a slash command. Codex uses `codex ... 'Use the relay-bridge skill now.'` because Codex consumes the installed skill as a normal initial prompt.
- Permission bypass flag: Claude uses `--dangerously-skip-permissions`; Codex uses `--dangerously-bypass-approvals-and-sandbox`. Both are gated by the same `general.bypass_permissions` setting.
- CLI resolution: Claude prefers Relay Runner's installed Claude symlink path from `ClaudeAuth.claudeBinaryPath`, then falls back to `claude` on `PATH`. Codex prefers the bundled Codex app CLI, then `codex` on `PATH`.
- Auth recovery: Claude worker auth failures require `claude /login`; Codex worker auth failures require `codex login`. This is documented in `services/instructions/recovery-401-auth.md`.
- Interruption: Claude has no stronger hard-cancel guarantee than Codex for already-running shell commands or MCP calls. Both providers use cooperative preemption checkpoints and stale TTS suppression.

## Checks

- `python3 -m unittest tests.test_session_capture` - PASS, 3 tests.
- `python3 -m unittest discover tests` - PASS.
- `swift test` - PASS.
- `scripts/build-instructions --check` - PASS.
- `bash -n scripts/relay-bridge` - PASS.

## Residual Risks

- This isolated worker did not launch the live macOS menu-bar app or a live Claude terminal session; coverage is through deterministic Swift/Python tests and generated command text.
- The tests use temporary fixture repos and bridge metadata files rather than mutating the user's live workspace registry.
- Nested workspace discovery remains outside this rollout; the classifier intentionally scans direct child git repos.
