## Recovery patterns

- **Codex worker fails with an authentication error.** Open a Terminal window with `codex login` running, wait for the user to finish sign-in, then re-dispatch the failed runs:

  ```bash
  osascript -e 'tell application "Terminal" to activate' \
            -e 'tell application "Terminal" to do script "codex login"'
  ```

  After sign-in completes (heuristic: `~/.codex/auth.json` exists and is fresh), re-dispatch via `mcp__relay-orchestrator__dispatch_ticket` for each failed run.

- **Claude worker fails with `401 Invalid authentication credentials`.** If the repo is explicitly configured to use Claude, open a Terminal window with `claude /login`, wait for the user to complete OAuth, then re-dispatch the failed runs:

  ```bash
  osascript -e 'tell application "Terminal" to activate' \
            -e 'tell application "Terminal" to do script "claude /login"'
  ```
