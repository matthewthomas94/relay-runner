# RR-99 GPT-5.6 Codex Preview Support Contract

Date: 2026-06-27
Branch: `relay/rr-99`
Run: 282

## Result

PASS. GPT-5.6 can be listed in Relay Runner as a Codex-only preview model family only if the UI makes preview access constraints clear. The current public Codex contract does not support enabling GPT-5.6 as broadly available, does not expose `max` as a usable `model_reasoning_effort` value in this installed Codex build, and does not document Ultra mode as a Relay Runner setting.

## Source Snapshot

Primary OpenAI sources checked:

- OpenAI launch announcement: <https://openai.com/index/previewing-gpt-5-6-sol/>
- Current Help Center article: <https://help.openai.com/en/articles/20001325-a-preview-of-gpt-56-sol-terra-and-luna>
- Codex manual fetched with `node /Users/matthewthomas/.codex/skills/.system/openai-docs/scripts/fetch-codex-manual.mjs`: <https://developers.openai.com/codex/codex-manual.md>

Findings:

- GPT-5.6 model IDs are `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`.
- During preview, GPT-5.6 is available through the API and Codex only to a limited set of trusted partners and organizations.
- Access is scoped independently to approved API organizations and approved Codex workspaces. API approval does not imply Codex approval, and Codex approval does not imply API approval.
- GPT-5.6 is not available in ChatGPT during preview.
- OpenAI says broader availability is planned "in the coming weeks", but there is no announced public GA date.
- The launch announcement introduces `max` reasoning effort for GPT-5.6 Sol and an `ultra` mode that uses subagents for complex work.

## Installed Codex Probe

Environment:

- `codex` was not on this worker shell's `PATH`.
- Bundled binary used: `/Applications/Codex.app/Contents/Resources/codex`
- Version: `codex-cli 0.142.3`

CLI/catalog checks:

- `codex --model gpt-5.6-sol --help` exited 0. This proves parser-level acceptance of the model string.
- `codex exec --model gpt-5.6-sol --version` exited 0. This also proves parser-level acceptance for `codex exec`.
- `codex debug models --bundled` lists `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, and `gpt-5.2`; it does not list `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna`.
- The bundled catalog reports supported reasoning levels for the listed GPT-5 models as `low`, `medium`, `high`, and `xhigh`.

Authenticated execution checks:

```text
codex exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only --json --model gpt-5.6-sol -c 'model_reasoning_effort="max"' 'Reply with OK only.'
```

Result: the CLI started the thread, warned that model metadata for `gpt-5.6-sol` was missing, then failed with:

```text
The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account.
```

This confirms the model slug is syntactically accepted, but this ChatGPT-account Codex workspace does not have GPT-5.6 access.

```text
codex exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only --json --model gpt-5.5 -c 'model_reasoning_effort="max"' 'Reply with OK only.'
```

Result: the request failed with:

```text
Invalid value: 'max'. Supported values are: 'none', 'minimal', 'low', 'medium', 'high', and 'xhigh'.
```

This confirms `model_reasoning_effort="max"` parses as CLI configuration, but the current Codex request path rejects it for a supported public Codex model. The current Codex manual documents `model_reasoning_effort` for config files and one-off `--config` overrides, but its sample configuration still lists `minimal`, `low`, `medium`, `high`, and `xhigh`; it does not document `max` as an accepted Codex config value.

The Codex manual documents `/model` as an interactive way to choose the active model and reasoning effort when available. I did not start the interactive TUI to probe `/model`; the installed catalog and service-side `codex exec` rejection above are the reliable checks for this ticket.

## Relay Runner Decision

- GPT-5.6 preview model entries may be added to Codex model choices as explicit preview options, but they must not be treated as generally available.
- Relay Runner should not offer `max` reasoning effort yet. Downstream reasoning-effort work should stay within currently accepted Codex values unless a later Codex build/catalog accepts `max`.
- Ultra mode is out of scope for this build. Public sources describe it as a subagent-powered mode, not as a Codex CLI flag, `config.toml` key, API parameter, or Relay Runner model/reasoning setting.
- Provider parity: this is Codex-only research. Claude behavior should remain unchanged. Any future UI for model or reasoning effort must be provider-scoped so Codex preview settings do not affect Claude launch or worker behavior.

## Checks

- `node /Users/matthewthomas/.codex/skills/.system/openai-docs/scripts/fetch-codex-manual.mjs` - PASS, manual already current.
- `/Applications/Codex.app/Contents/Resources/codex --version` - PASS, `codex-cli 0.142.3`.
- `/Applications/Codex.app/Contents/Resources/codex debug models --bundled` - PASS, no GPT-5.6 slugs in bundled catalog.
- `/Applications/Codex.app/Contents/Resources/codex exec ... --model gpt-5.6-sol -c 'model_reasoning_effort="max"'` - FAIL as expected, model unsupported for this ChatGPT account.
- `/Applications/Codex.app/Contents/Resources/codex exec ... --model gpt-5.5 -c 'model_reasoning_effort="max"'` - FAIL as expected, `max` is not an accepted reasoning effort on current public Codex request path.
