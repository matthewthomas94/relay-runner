## Recovery patterns

- **Worker fails with `401 Invalid authentication credentials`.** The daemon is launched by the menu-bar app and inherits a minimal environment (no `ANTHROPIC_API_KEY`), so the spawned `claude` falls back to `~/.claude/.credentials.json`. When that OAuth file is stale or expired, every dispatched worker dies in under 10 seconds. Don't just tell the user — auto-recover: open a Terminal window with `claude` running, send the `/login` slash command, wait for the user to complete OAuth, then re-dispatch the failed runs. The osascript skeleton:

  ```bash
  osascript -e 'tell application "Terminal" to activate' \
            -e 'tell application "Terminal" to do script "claude"'
  sleep 2
  osascript -e 'tell application "System Events" to keystroke "/login"' \
            -e 'tell application "System Events" to keystroke return'
  ```

  After OAuth completes (heuristic: `~/.claude/.credentials.json` mtime is fresh), re-dispatch via `mcp__relay-orchestrator__dispatch_ticket` for each failed run.
