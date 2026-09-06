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
