# RR-102 Worker Model and Effort Controls Verification

Date: 2026-06-27
Branch: `relay/rr-102`
Run: 283

## Result

PASS. Relay Runner can launch Codex workers with an explicit model and reasoning effort by appending `--model` plus `--config model_reasoning_effort=...` to the existing `codex exec` command. Claude Code has a provider-specific equivalent on its non-interactive worker surface: `claude -p --model ... --effort ...`.

The commands below use absolute binary paths because this isolated worker shell did not resolve `codex` or `claude` from `PATH`. Relay Runner already invokes the resolved `self.agent_bin` in `services/orchestrator.py`, so the implementation follow-up should add flags to that resolved binary rather than assuming a command name.

## Current Relay Runner Worker Commands

`services/orchestrator.py` currently builds these provider commands:

```bash
codex exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust
```

```bash
claude -p --dangerously-skip-permissions --verbose --output-format stream-json
```

Neither command currently includes model or effort controls.

## Codex Verification

Installed CLI:

```bash
/Applications/Codex.app/Contents/Resources/codex --version
# codex-cli 0.142.3
```

Help-only parser check, with Relay Runner's existing worker flags plus explicit model and effort:

```bash
/Applications/Codex.app/Contents/Resources/codex exec \
  --model gpt-5.5 \
  --config model_reasoning_effort=high \
  --json \
  --ephemeral \
  --dangerously-bypass-approvals-and-sandbox \
  --dangerously-bypass-hook-trust \
  --help
```

Result: exit 0. The help output includes `--model <MODEL>`, `--config <key=value>`, `--json`, `--ephemeral`, `--dangerously-bypass-approvals-and-sandbox`, and `--dangerously-bypass-hook-trust`, so this command shape is accepted without starting a worker task.

Recommended Codex worker launch shape:

```bash
codex exec \
  --json \
  --ephemeral \
  --dangerously-bypass-approvals-and-sandbox \
  --dangerously-bypass-hook-trust \
  --model gpt-5.5 \
  --config model_reasoning_effort=high
```

The current Codex manual also documents that custom agent files can set `model` and `model_reasoning_effort`, and that omitted values inherit from the parent session:

- https://developers.openai.com/codex/subagents
- https://developers.openai.com/codex/concepts/subagents
- https://developers.openai.com/codex/cli/reference

### Codex Effort Vocabulary

Installed-model catalog check:

```bash
/Applications/Codex.app/Contents/Resources/codex debug models \
  | jq -r '[.models[].supported_reasoning_levels[]?.effort] | unique | join(",")'
# high,low,medium,xhigh
```

For the current recommended Codex models in the installed catalog:

```bash
/Applications/Codex.app/Contents/Resources/codex debug models \
  | jq -r '.models[] | select(.slug=="gpt-5.5" or .slug=="gpt-5.4" or .slug=="gpt-5.4-mini" or .slug=="gpt-5.3-codex-spark") | [.slug, ([.supported_reasoning_levels[].effort] | join(","))] | @tsv'
# gpt-5.5              low,medium,high,xhigh
# gpt-5.4              low,medium,high,xhigh
# gpt-5.4-mini         low,medium,high,xhigh
# gpt-5.3-codex-spark low,medium,high,xhigh
```

`xhigh` is supported by the installed Codex catalog. `max` is not supported by any installed Codex catalog entry:

```bash
/Applications/Codex.app/Contents/Resources/codex debug models \
  | jq -r '.models[] | select((.supported_reasoning_levels // []) | map(.effort) | index("max")) | .slug'
# no output
```

The current Codex configuration reference still lists `minimal | low | medium | high | xhigh`, but the installed model catalog for current Codex-listed models advertises only `low | medium | high | xhigh`. For Relay Runner sizing, use the installed catalog set for dispatchable Codex workers: `low`, `medium`, `high`, and `xhigh`. Do not allow GPT-5.6 `max` for Codex dispatch until a future Codex release exposes it through `codex debug models`, current docs, or a validated CLI surface.

## Claude Code Verification

Installed CLI:

```bash
/Users/matthewthomas/.local/bin/claude --version
# 2.1.175 (Claude Code)
```

Help-only parser check, with Relay Runner's existing worker flags plus explicit model and effort:

```bash
/Users/matthewthomas/.local/bin/claude -p \
  --model sonnet \
  --effort high \
  --dangerously-skip-permissions \
  --verbose \
  --output-format stream-json \
  --help
```

Result: exit 0. Claude Code help documents `--model <model>` for the current session and `--effort <level>` with `low`, `medium`, `high`, `xhigh`, and `max`.

Recommended Claude worker launch shape:

```bash
claude -p \
  --dangerously-skip-permissions \
  --verbose \
  --output-format stream-json \
  --model sonnet \
  --effort high
```

Claude's effort vocabulary intentionally differs from Codex in the installed tools: Claude Code 2.1.175 exposes `max`; Codex 0.142.3 does not.

## Provider Parity Notes

| Area | Codex worker | Claude worker |
| --- | --- | --- |
| Non-interactive surface | `codex exec` | `claude -p` |
| Model flag | `--model <model>` | `--model <model>` |
| Effort flag | `--config model_reasoning_effort=<effort>` | `--effort <effort>` |
| Current installed effort values for sizing | `low`, `medium`, `high`, `xhigh` | `low`, `medium`, `high`, `xhigh`, `max` |
| Permission bypass remains provider-specific | `--dangerously-bypass-approvals-and-sandbox` plus `--dangerously-bypass-hook-trust` | `--dangerously-skip-permissions` |

Intentional difference: Codex effort is a config override because `codex exec --help` does not expose a dedicated `--effort` flag. Claude Code exposes effort as a first-class CLI option. Relay Runner should keep a provider-specific flag renderer while using one provider-neutral ticket sizing concept.

## Follow-up for RR-103/RR-104

- Store the provider-neutral worker sizing decision on the ticket, but render provider-specific CLI flags at dispatch time.
- For Codex, reject `max` until the installed Codex catalog or docs expose it. `xhigh` is safe to allow for current Codex workers.
- For Claude, `max` is available in the installed CLI help, but it should remain provider-scoped rather than added to the Codex vocabulary by association.
