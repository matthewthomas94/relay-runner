# RR-105 Voice Bridge Diagnostics

## Forced restart check

1. Start a Relay voice session from either Codex or Claude.
2. Confirm `/tmp/voice_bridge.log` contains the new session header:
   - `previous_log=...`
   - `reason=start`
   - `provider=codex` or `provider=claude`
3. Simulate an unexpected bridge exit:

   ```bash
   pkill -f '[v]oice_bridge.py'
   ```

4. Let the active Relay session or app watchdog restart the bridge.
5. Inspect `/tmp/voice_bridge.log` for the fresh restart header and launch result lines:
   - `reason=restart` or `reason=watchdog-recovery`
   - `launchctl submit exit_status=...`
   - either `launchctl produced socket...` or `launchctl print follows`
   - `direct fallback launched...` if launchctl did not produce a socket
6. Inspect the preserved previous log at the path named by `previous_log=...`, usually:

   ```bash
   ls -lt /tmp/voice_bridge.*.log
   ```

The direct and launchctl wrappers append bridge process exit status to the active log when the shell can observe it. Codex and Claude use the same diagnostic path; provider metadata is only used to label which agent session launched the shared bridge.
