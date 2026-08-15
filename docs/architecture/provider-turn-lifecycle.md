# Provider-turn lifecycle broker

Relay stores provider-turn authority beside the durable intent inbox in
`relay_intent_inbox.sqlite3`. The broker is provider-neutral: Codex and Claude
hooks supply their native session and turn identifiers, but both use the same
owner, transition, effect, and projection contracts.

## Authority and projection

Four broker tables separate durable concerns:

- `provider_turn_owners` uniquely identifies an app session, recovery
  generation, foreground actor role, and gate handle.
- `provider_turns` stores the current state for one provider-native physical
  turn. Every row repeats its app-session and generation key so a stale owner
  cannot become current after restart.
- `provider_turn_transitions` is an idempotent event ledger. Event ids are
  unique, and only validated `active` to terminal changes can mutate current
  state. Intent delivery, claim, acknowledgement, recovery, and cancellation
  events are written in the same SQLite transaction as their inbox changes.
- `provider_turn_effects` reserves one authoritative effect per owner and
  intent (or source-command identity when an old intent has none). The bridge
  reserves before forwarding a final to speech, then atomically authorizes
  delivery immediately before the first Messenger or TTS submission. A
  cancellation or replacement committed first fails the reservation without
  submission; authorization committed first is the too-late boundary and its
  external result is finalized as delivered or failed. Duplicate or late Codex
  and Claude completions cannot create a second authoritative effect.

Swift reads `/tmp/voice_provider_turns_v2.json`, a sorted schema-v2 projection
written from a committed database snapshot under an interprocess lock. Swift
never edits that projection. Provider exit and app teardown travel back to the
bridge as a scoped lifecycle event, which the broker applies only to the exact
app session, recovery generation, gate handle, and provider session.

## Dual-write migration

The rollout default is `RELAY_PROVIDER_TURN_BROKER_MODE=dual_write`:

1. Provider hooks commit broker state first and continue writing the v1
   `/tmp/voice_provider_turns.json` compatibility ledger.
2. Current Swift builds consume only the v2 projection. Older installed builds
   can continue consuming the v1 ledger during the mixed-version window.
3. Existing v1-only turns may finish through the compatibility path, but every
   newly accepted turn is broker-owned. The database and v2 projection never
   infer an active owner from a v1 record.
4. After one release confirms mounted Codex and Claude fault coverage, remove
   v1 writes and the compatibility exception as a separate change.

For rollback, set `RELAY_PROVIDER_TURN_BROKER_MODE=legacy` and run the previous
Swift consumer. This disables new broker/projection writes without deleting the
SQLite tables, effect reservations, or durable inbox. Do not clear the database
or reuse a recovery generation. Returning to `dual_write` resumes from the
preserved v2 history while new foreground ownership continues under a fresh
generation.
