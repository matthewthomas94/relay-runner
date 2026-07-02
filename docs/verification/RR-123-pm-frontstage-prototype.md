# RR-123 PM Frontstage Prototype

This prototype defines a side-effect-free PM/frontstage contract in
`services/pm_frontstage.py`. It does not replace the live bridge or dispatch
daemon. It proves the event and outcome shape that a later integration can wire
into `voice_bridge.py`, the TTS FIFO, and `orchestrator.py`.

## Status Event Contract

Each public status event includes:

- `phase`: `acknowledged`, `planning`, `outcome`, or `stale`.
- `message`: concise user-facing text. It must not contain hidden reasoning.
- `source`: `pm`, `orchestrator`, or `worker`.
- `command`: Relay command metadata with `relay_command_seq`,
  `relay_command_id`, and optional `provider`.
- Optional references: `ticket_id` and `run_id`.

The public event intentionally omits raw `source_text`; command transcript text
remains private metadata unless the PM deliberately refines it into a visible
ticket.

## Backstage Outcome Contract

The backstage planner returns one of:

- `execute_solo`: the PM/frontstage session can keep the work.
- `delegate_plan`: the backstage planner proposes bounded worker requests, but
  the PM owns the actual dispatch call.
- `needs_user`: the PM needs clarification before ticket edits or dispatch.

Delegation requests carry `pm_controls_dispatch: true` and a
`dispatch_payload` containing `ticket_id`, `repo_path`, `relay_command_seq`, and
`relay_command_id`. This preserves stale-action protection without letting the
backstage planner spawn workers ad hoc.

## Manual Exercise

Run the deterministic harness:

```bash
python3 services/pm_frontstage.py \
  --command "dispatch RR-7 to a worker" \
  --seq 4 \
  --id demo-4 \
  --repo .
```

To observe the acknowledgement before a slow backstage planner completes:

```bash
python3 services/pm_frontstage.py \
  --command "dispatch RR-7 to a worker" \
  --seq 5 \
  --id demo-5 \
  --repo . \
  --planner-delay-seconds 1
```

Expected output is JSONL: `acknowledged` first, then `planning`, then `outcome`
with a `delegate_plan`.

## Latency Checkpoints To Measure Next

- Time from STT final transcript to PM `acknowledged` event.
- Time from `acknowledged` event to first TTS or overlay acknowledgement.
- Time from PM `planning` event to backstage outcome.
- Time from PM-controlled `delegate_plan` acceptance to daemon `dispatch`.
- Time from worker run creation to first public worker status event.

## Provider Parity

Codex and Claude use the same PM status event and backstage outcome contracts.
The prototype treats stale-command checks as provider-neutral: both providers
must stop follow-up ticket edits, dispatches, and TTS when a newer Relay command
supersedes the claimed metadata.

Intentional provider-specific behavior remains below this contract:

- Codex renders effort through `model_reasoning_effort`.
- Claude renders effort through `--effort`.
- Both providers currently share `low`, `medium`, `high`, and `xhigh` worker
  effort values for provider-neutral tickets.
- Neither provider gets a stronger hard-cancel guarantee for already-running
  tools in this prototype; both rely on cooperative stale checkpoints before
  follow-up actions and TTS.
