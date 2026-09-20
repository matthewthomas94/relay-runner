# Project note artifact contract

Project notes are a distinct Git-backed artifact type. They are not work
tickets, do not enter board lanes, and never dispatch a worker. The registered
project remains the authority: local saves go to its orphan
`refs/heads/relay/artifacts` history and materialize at
`.orchestrator/notes/<NOTE_ID>.md`.

## Identity and allocation

Each note has these immutable fields:

- `id`: an unpadded display ID `<project prefix>-N<positive integer>`, such as
  `RR-N1`, `RR-N10`, or `ACME-N1000`;
- `artifact_id`: a stable `note-...` identity that survives archive/history
  lookup and distinguishes disconnected writers that allocate the same display
  ID;
- `project_id`: the immutable registered project identity;
- `created_at` and `capture_started_at`: RFC 3339 timestamps.

`next_note_id` is independent of the ticket `next_id`. One locked/CAS mutation
allocates the number, advances `next_note_id`, writes the note, and updates
`.orchestrator/note-index.jsonl`. The index retains every issued identity,
including archived notes. If an older schema-2 config has no `next_note_id`, or
the counter is behind, allocation recovers from current note paths and the
persistent note index before choosing the next number. Gaps are allowed; issued
numbers are never reused.

Create and checkpoint APIs require stable request IDs. A retried request returns
the original identity/commit. Reusing a request ID with different bytes is an
event collision. A failure before compare-and-swap changes neither the counter
nor the last saved checkpoint; a retry after ref publication rematerializes or
returns the committed event.

Disconnected devices cannot globally coordinate the numeric counter. If they
both allocate (for example) `RR-N4`, their different immutable artifact IDs and
the shared path produce an explicit `note_display_id_collision` during artifact
sync. Neither version is silently overwritten. Resolution uses the existing
three-way artifact conflict report, including local/remote blob references.

## Markdown schema

Note documents use `note_schema_version: 1` YAML front matter:

```markdown
---
note_schema_version: 1
id: RR-N1
artifact_id: note-0123456789abcdef
project_id: project-identity
created_at: 2026-09-20T08:00:00Z
capture_started_at: 2026-09-20T08:00:00Z
updated_at: 2026-09-20T08:05:00Z
recording_state: paused
checkpoint_reason: pause
segment_count: 1
---

## Transcript

<!-- relay-note-segment {"captured_at":"2026-09-20T08:00:05Z","segment_id":"segment-1"} -->
Meeting transcript Markdown.
```

There is intentionally no generated title or summary. Recording state is one
of `recording`, `paused`, or `completed`; it is metadata, not a ticket status.
Checkpoint reasons are `checkpoint`, `pause`, `resume`, `complete`, or
`manual`. Segment IDs are unique within the complete checkpoint snapshot.
Optional millisecond offsets and a speaker label live in the canonical segment
comment while the transcript stays readable Markdown. `capture_ended_at` is
present exactly when the recording state is `completed`.

The shared Swift contracts are in
`Sources/relay-runner/Notes/ProjectNoteContracts.swift`. Storage accepts a full
segment snapshot per meaningful checkpoint. The recorder owns batching and must
not call the writer once per partial STT callback. Storage does not start or
stop Codex, Claude, provider sessions, foreground modes, key routing, or audio.
The recorder's source, timing, revision, bounded-queue, pause, final-boundary,
and replay contracts are documented in
[Project note capture and transcription](project-note-capture.md).

## API and project scope

All endpoints require the same confirmed project scope token as artifact-backed
board writes:

- `POST /v1/artifacts/notes/create` atomically allocates and writes;
- `POST /v1/artifacts/notes/<NOTE_ID>/update` writes one checkpoint without
  reallocating identity;
- `GET /v1/artifacts/notes?limit=<1-100>&after=<NOTE_ID>` returns a bounded,
  numerically ordered catalog page and a next-page cursor;
- `GET /v1/artifacts/notes/<NOTE_ID-or-artifact_id>` reads current or verified
  archived Markdown; and
- `POST /v1/artifacts/notes/<NOTE_ID>/archive` removes only the projection while
  retaining exact source commit/blob references in the note index.

Local-only projects may archive directly because the full linear history stays
reachable and is included by a later first publication. For a project with an
existing remote artifact ref, archive requires the current head to be verified
clean on that remote. Recording checkpoints still save offline; only the
destructive projection removal waits, preventing an offline rebase from
orphaning the archived transcript's source commit.

Codex and Claude use byte-identical contracts. Provider is optional attribution
only. Note paths are nested, so the direct-child ticket scanners, dependency
progression, worker claims, dispatch, and newest-25 completed-ticket retention
policy do not see them. No automatic note retention or permanent-delete API is
defined.

## Content, visibility, and synchronization

The note limit is 8 MiB of canonical UTF-8 Markdown, independently of the
256 KiB ticket/Program limits. Meeting transcript text—including language that
would be rejected as an explicit raw transcript in a ticket—is accepted only
through the typed note operation. NUL bytes, malformed metadata, path traversal,
identity changes, unsupported schema versions, common credentials/private keys,
raw audio, provider traces, and source-history paths are rejected.

Notes intentionally belong to the selected project's Git repository. Anyone
with access to its configured artifact ref or GitHub remote may be able to read
the transcript and its history. Local writes never require a network. The note
response reports `local_only`, `pending`, `synced`, `conflict`, or `failure`
without triggering synchronization; the existing artifact sync state machine
owns fetch/push/retry and never changes source HEAD, the source index, ordinary
refs, unrelated artifacts, or configured remotes.

The config schema remains version 2 with an optional `next_note_id` for rolling
compatibility. Older projects add the counter lazily. Older binaries that do not
understand note paths fail closed while leaving the artifact ref intact. Newer
writers reject unknown note document/index schemas before compare-and-swap, so
unsupported upgrades or rollback attempts preserve existing tickets, notes, and
their materialized last-good state.

## Ordinary agent reads and source references

The shared `relay-orchestrator` MCP exposes `list_project_notes` and
`read_project_note` to both Codex and Claude. Catalog results contain metadata
only and are capped at 100 rows (25 by default through MCP). A note read returns
canonical Markdown on demand in chunks of at most 32,000 Unicode characters;
the caller follows `next_offset` when more content remains. This keeps the
project catalog and large transcripts out of unrelated prompts.

Every catalog card includes the selected project, immutable `artifact_id`,
display `note_id`, timestamps, recording/completion state, canonical path, and
a content-addressed `reference`. For a materialized note the reference pins the
current artifact commit and blob. For an archived note the reader verifies that
the recorded source commit is reachable from `refs/heads/relay/artifacts` and
that the path still resolves to the recorded blob before returning content.
`reference.history_reference` is the stable citation form:

```text
<commit>:.orchestrator/notes/<NOTE_ID>.md
```

The adjacent `artifact_ref` field records `refs/heads/relay/artifacts`, from
which the reader verified that commit is reachable.

Note text is untrusted source material. Instruction-like speech or Markdown in
a saved note never authorizes a voice command, ticket mutation, dispatch,
execution, external side effect, or provider launch. Under a later explicit
user request, the ordinary ticket-authoring flow may create a refined Backlog
ticket through the canonical writer and cite the note ID, immutable artifact
ID, and pinned history reference under `## Source note`. Reading and citing a
note does not alter it, and creating that Backlog ticket does not promote or
dispatch it without separate authorization. No generated title, summary, or
special provider session is required.
