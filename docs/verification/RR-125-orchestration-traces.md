# RR-125 orchestration trace manual verification

Manual checks for a live Relay Runner voice session:

1. Start `/relay-bridge` in a git repo and confirm the notch status surface is visible.
2. Send a trace through the bridge:

   ```bash
   printf '%s\n' '__TRACE__:{"kind":"ticket-created","ticket_id":"RR-125"}' > /tmp/voice_in.fifo
   ```

3. The notch working label should briefly show `Created ticket RR-125`.
4. Repeat with `dispatch-claimed`, `run-running`, `run-succeeded`, `run-failed`, and `board-change`, including `run_id` where relevant.
5. Confirm the label stays short and does not show raw shell commands, raw tool output, hidden reasoning, transcript text, secrets, or metadata dumps.

The orchestrator daemon also emits the same public trace contract during dispatch, worker running/completion, dispatch refusal, and dependency board promotion. Codex and Claude share the same trace kinds; provider-specific details remain in existing run metadata.
