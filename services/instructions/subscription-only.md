## Subscription-only provider access

Relay Runner uses only the user's own Claude or ChatGPT subscription for model requests — never an API key, cloud-provider account (Bedrock, Vertex, Foundry), gateway, or other pay-as-you-go credential. This covers every Relay-launched provider process: foreground sessions, workers and reviews, spikes, messenger, continuity recovery, sidecar research, and note metadata.

When authentication is missing, expired, failed (for example a 401), or cannot be verified as a subscription, stop the affected work and send the user to subscription sign-in (`claude auth login` for Claude, `codex login` for Codex), then re-dispatch. Never suggest setting `ANTHROPIC_API_KEY`, an API-key helper, or another metered route to repair an auth failure, and never print credential values.

To start sign-in, open a Terminal window running the provider's login command (`claude auth login` or `codex login`), wait for the user to finish, then re-dispatch each failed run with `mcp__relay-orchestrator__dispatch_ticket`:

```bash
osascript -e 'tell application "Terminal" to activate' \
          -e 'tell application "Terminal" to do script "claude auth login"'
```
