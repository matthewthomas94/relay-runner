# Provider setup and parity

Relay Runner supports Codex and Claude Code as equivalent session providers. The provider CLI still controls account access, model availability, upstream data handling, and its own command behavior.

## Setup

| | Codex | Claude Code |
| --- | --- | --- |
| Executable discovery | Bundled Codex executable in ChatGPT.app or Codex.app, followed by configured command resolution. | Configured command or `~/.local/bin/claude`. Onboarding can run Claude's official installer when neither supported CLI is present. |
| Authentication check | Presence of `~/.codex/auth.json`. | Presence of the `Claude Code-credentials` login-keychain item; API-key-only setups may need to skip the onboarding check. |
| Manual sign-in | `codex login` | `claude /login` |
| Relay install | Relay skills and the Relay Actions, Relay Vision, and orchestrator MCP helpers are registered for the available CLI. | Same. |

Relay Runner does not read provider credential values. It checks the local presence needed to avoid launching directly into an authentication failure.

## Models and effort

Relay Runner stores stable product choices rather than freezing transient concrete model ids.

### Codex

- Families: Sol, Terra, and Luna.
- Before launch, Relay Runner asks the installed Codex catalog to resolve the newest account-visible concrete model in the selected family.
- Sol and Terra expose Low, Medium, High, Extra High, Max, and Ultra.
- Luna exposes Low, Medium, High, Extra High, and Max.
- The resolved value is passed as Codex `model_reasoning_effort`.

Availability, especially newer families and Ultra effort, depends on the user's Codex plan and installed catalog. A failed family resolution stops launch with an explicit error instead of silently choosing another family.

### Claude

- Stable choices: Fable, Opus, Sonnet, and Haiku.
- Fable and Opus expose Low through Max.
- Sonnet exposes Low, Medium, High, and Max.
- Haiku exposes Low.
- The chosen values are passed with Claude's `--model` and `--effort` flags.

Fable requires an eligible plan or usage credits and is unavailable with zero data retention. Claude model availability remains subject to Anthropic's account and product rules.

The messenger model and sub-agent sizing are selected independently. Shared worker effort values are Low, Medium, High, and Extra High; Max must not be inferred as a Codex worker value until Codex support is verified.

## Session permissions

**Bypass agent permission prompts** is enabled by default for smooth voice operation:

- Codex: `--dangerously-bypass-approvals-and-sandbox`
- Claude: `--dangerously-skip-permissions`

Disable the setting to retain each provider's normal per-tool approval flow. This provider flag is independent of macOS Microphone, Accessibility, Input Monitoring, and Screen Recording permissions.

## Session entry points

The supported default is **Start Session** in Workspace. It launches the selected provider inside the embedded terminal, starts the app-owned voice bridge, binds the selected project scope, and keeps the provider's visible terminal output available.

For a terminal you launched yourself, install Relay Skills from **Settings → General**, then invoke the relay-bridge skill from the active Codex or Claude session. `relay-stop` ends that manual bridge. Directly running `services/voice_bridge.py` is an implementation path, not a supported user entry point.

## Shared behavior

Both providers use the same:

- onboarding and macOS permission ownership;
- registered-project selection and explicit scope token;
- local Parakeet and Kokoro speech path;
- embedded Terminal and external Terminal.app compatibility route;
- Relay Actions, Relay Vision, and ActionGlow behavior;
- ticket schema, worker lifecycle, verification-blocked state, review, and queue progression;
- public messenger context and raw-transcript exclusion.

Intentional differences are limited to executable discovery, authentication, model catalogs, launch flags, provider-native hooks or event streams, and account limitations. Shared changes should be tested with both providers or record the exact external parity check that remains.
