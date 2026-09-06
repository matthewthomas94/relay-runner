# RR-349: Astra and Claude Fable 5.1 support

## Scope and implementation

The user canceled worker run 110 and requested inline implementation. The worker stopped with exit -15 before source edits; its worktree and logs remain recoverable. The foreground implemented and reviewed this change directly. No replacement worker was dispatched.

- Added Astra to Swift/Python model families, shared Settings/onboarding options, config persistence, Messenger validation, and worker/command selection. Concrete `gpt-6-astra` normalizes to Astra without losing explicit Messenger effort.
- Added a separate Fable 5.1 option stored and launched as `claude-fable-5-1`; generic `fable` is retained unchanged. Foreground, Messenger, and `claude:claude-fable-5-1` worker overrides preserve the exact identifier.
- Explicit `codex:astra` and `codex:gpt-6-astra` workers accept Max/Ultra, then validate the configured provider catalog before launch. Missing, hidden, non-text, or effort-incompatible Astra entries do not silently become Sol. Shared worker tiers and other model defaults were not changed.
- Fable 5.1 uses the existing Low/Medium/High/Extra High/Max effort path and 1M native-context fixture. No new compaction policy, authentication mechanism, or provider API integration was introduced.
- Updated ticket schema/worker guidance and regenerated the MCP/Claude instruction artifacts.

## Provider evidence

Read-only CLI/catalog checks on 2026-09-06:

| Client | Evidence |
| --- | --- |
| `/Users/matthewthomas/.local/bin/codex`, 0.151.0 | Successful model/list query returned no Astra model. An initial sandboxed query timed out; a host-permitted retry succeeded. |
| `/Applications/ChatGPT.app/Contents/Resources/codex`, 0.153.4 | model/list advertises visible `gpt-6-astra`, text/image inputs, default Medium, supported Low/Medium/High/Extra High/Max/Ultra. |
| `/Users/matthewthomas/.local/bin/claude`, 2.1.239 | `--help` supports full model identifiers and `--effort` Low/Medium/High/Extra High/Max. Full-model CLI parsing is not authenticated model-access evidence. |

Source references inspected during scoping:

- [OpenAI Codex changelog](https://learn.chatgpt.com/docs/changelog): Astra catalog support in 0.153.1 and bundled visibility fix in 0.153.4.
- [Claude Code model configuration](https://support.claude.com/en/articles/11940350-claude-code-model-configuration): supported-model list and launch example name `claude-fable-5-1`. Ignore the inconsistent extra digit in that page's ZSH export example.
- [Fable 5.1 reference](https://platform.claude.com/docs/en/models/fable-5-1/overview): exact identifier and 1M context; Mythos 5.1 is a distinct invitation-only offering outside this ticket's scope.

## Verification

- 46 Python tests passed with Homebrew Python 3.13: `test_astra_fable_support`, `test_codex_model_catalog`, `test_config`, MessengerConfigTests, MessengerBackendContractTests, and three existing worker/reviewer command-rendering regressions.
- 51 Swift tests passed: AstraFableSupportTests, GeneralConfigTests, ConfigManagerTests, OnboardingModelSelectionTests, and ProcessManagerLaunchTests. This includes configuration save/reload, selection callbacks, unavailable model handling, and every supported foreground model/effort launch combination.
- `scripts/build-instructions --check` and `git diff --check` pass.
- New tests use in-memory model catalogs, temporary configuration directories, and command rendering without spawning providers. Existing selected backend tests use fake processes/callbacks. No live TTS/voice queue test was run.
- Initial test setup issues were corrected: system Python 3.9 cannot import existing Python 3.10+ union types, a new Swift test required the nested `GeneralConfig.AgentProvider` type, and a Python fixture needed the existing `_raw_fields` ticket shape. Final suites are green.

## External gate

No rebuild/install, authenticated generation, or human-visible/audible model smoke has occurred for this change. The installed app and active voice session were not replaced or restarted. RR-349 remains verification-blocked until a coordinated rebuild/install and authenticated test of both models. Select a CLI that advertises Astra (the observed bundled 0.153.4 does); a picker entry does not grant account access. No Apple Developer ID, notarization, or mounted-DMG gate applies.

## Rebuild and preserving install — 2026-09-06

This update supersedes the earlier not-yet-installed status above. The user explicitly requested rebuild/install.

- Built clean source `fafe8528266844e96bcc3198008e7ba47aa33a54` using `RELAY_SKIP_APPLICATIONS_REFRESH=1 SIGN_IDENTITY= NOTARY_PROFILE= ./scripts/build-dmg.sh`. App, DMG, and ZIP packaging completed; ad-hoc deep/strict signature verification passed.
- The app and voice bridge were already stopped. No Claimed, Running, Reviewing, or AwaitingReview worker runs existed. Stopped the idle launchd daemon before replacement; preserving-installer preflight reported no active run IDs.
- Executed `scripts/relay-runner-fresh-install --app 'dist/Relay Runner.app' --destination '/Applications/Relay Runner.app' --execute`. It returned `state_preserved: true` and `repositories_preserved: true` without resetting any state.
- Recoverable old app: `/Users/matthewthomas/.Trash/Relay Runner.app-before-reinstall-20260906-040357-c2d9032e`.
- Installed executable exactly matches the build; SHA-256 `23b09b5992e7745cf5a4a24eb44b33509eb3d2d3e3d06ae457c7571a7563b430`. Installed `codex_model_catalog.py` and `orchestrator.py` also match the source. Installed deep/strict codesign verification passed.
- Restarted the bundled daemon and opened the updated app. Observed app PID 17077 and daemon PID 17167; health endpoint returned healthy. Preserved settings remain Codex, command `codex`, model `sol`, auto-start false. The foreground resolver prefers the available ChatGPT-bundled Codex 0.153.4 for this non-absolute command.
- Installed human model-selection and authenticated generation tests for Astra and Fable 5.1 are still pending. Build/install success is not a model-access or audio UAT pass.

## User acceptance and closure — 2026-09-06

Following the installed-app Astra test instruction, the user reported the test passed and explicitly authorized marking RR-349 Done. The canonical ticket is closed on this user-accepted scope. The confirmation did not enumerate separate model tests; no independently correlated Claude Fable 5.1 live smoke or per-model audio evidence is claimed. Earlier pending-gate statements above are historical and superseded by this closure decision, while the source tests and installation evidence remain unchanged.
