## Subscription-only provider access

Relay Runner uses only the user's own Claude or ChatGPT subscription for model requests — never an API key, cloud-provider account (Bedrock, Vertex, Foundry), gateway, or other pay-as-you-go credential. This covers every Relay-launched provider process: foreground sessions, workers and reviews, spikes, messenger, continuity recovery, sidecar research, and note metadata.

When authentication is missing, expired, failed (for example a 401), or cannot be verified as a subscription, stop the affected work and send the user to subscription sign-in (`claude auth login` for Claude, `codex login` for Codex), then re-dispatch. Never suggest setting `ANTHROPIC_API_KEY`, an API-key helper, or another metered route to repair an auth failure, and never print credential values.

To start sign-in, ask the user to sign in inside Relay Runner, then re-dispatch each failed run with `mcp__relay-orchestrator__dispatch_ticket`. Relay Runner runs the provider's login command (`claude auth login --claudeai` or `codex login`) in its own embedded terminal: Start Session does it when the subscription check finds no sign-in, and onboarding's sign-in step (Settings > Redo Onboarding…) does it on request. Do not open Terminal.app, run `osascript`, or start the login command in a window of your own; wait for the user to say sign-in is done.
