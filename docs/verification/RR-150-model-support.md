# RR-150 ChatGPT Codex and Claude Model Support

PASS. Relay Runner's Settings and onboarding pickers now use the committed RR-150 matrix for session models and model-specific effort values.

## Source Snapshot

- ChatGPT-bundled Codex `0.144.0-alpha.4` authenticated `debug models`, checked 2026-07-12: GPT-5.6 Sol, Terra, Luna; GPT-5.5; GPT-5.4; GPT-5.4 Mini; GPT-5.3 Codex Spark. The account-visible catalogue is primary. The bundled offline fallback was not used to replace Spark with GPT-5.2, and `codex-auto-review` stays hidden.
- Claude Code `2.1.175` `--help`, checked 2026-07-12: `best`, `fable`, `opus`, `sonnet`, and `haiku` aliases. `claude-fable-5` is launchable through the documented `fable` alias; Sonnet remains the compatible alias for this installed CLI.

## Validation

- Default provider model omits `--model`; Default effort omits explicit effort flags.
- Codex session launch renders effort as `-c 'model_reasoning_effort="..."'`.
- Claude session launch renders effort as `--effort ...`.
- Config migration resets retired, cross-provider, or model-unsupported effort values to Default.
- Sub-agent worker sizing remains provider-neutral and unchanged: `low`, `medium`, `high`, and `xhigh`.
