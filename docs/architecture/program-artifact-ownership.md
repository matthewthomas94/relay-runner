# Program artifact ownership

This is the RR-270 phase 7 ownership contract implemented by RR-287. A
project's `relay/artifacts` ref is the only durable authority for project
Program captures. `graphify.db`, its FTS tables, and every Program UI view are
rebuildable projections and must never accept an independent project write.

## Record classification

| Record family | Classification | Durable authority and rebuild input |
| --- | --- | --- |
| Project identity and artifact configuration | Project-owned durable | `.orchestrator/config.toml` on `relay/artifacts`; the app-global registry stores only locator identity, bookmark references, availability, and active-project preference. |
| Registered project list and filesystem bookmarks | App-global durable | Registry v2 plus Keychain/bookmark storage. It is cross-project routing data, not ticket or Program content. |
| Initiative | Project-owned durable, unsupported writer | No production writer currently creates initiatives. Any legacy initiative stops migration for review until a typed artifact schema exists; it is never silently retained only in Graphify. |
| Ticket, attachment, archive catalog, dependency identity | Project-owned durable | Allowlisted artifact paths. Graphify ticket nodes and dependency edges are derived. |
| Decision, Risk, Idea, Status, ProgramEvent capture | Project-owned durable | Immutable `.orchestrator/program/events/<event-id>.json` records described below. |
| Run process, PID, workspace, raw state, activity, exit, retry, local log path | Local operational/audit | `runs.db` and bounded local diagnostics. These are permitted rebuild inputs but are not synchronized as canonical project claims. |
| Reviewed bounded run summary and terminal ticket outcome | Project-owned durable | Ticket lifecycle event on `relay/artifacts`; raw logs remain local. |
| AgentProvider node and provider/model availability | Derived plus app-global capability data | Rebuilt from registry and permitted local run metadata. Provider attribution on a durable capture is metadata, not a separate schema or authority. |
| Project, Ticket, Run, AgentProvider, capture, and File graph nodes | Derived | Rebuilt from registry, the artifact ref/materialization, and permitted `runs.db` rows. |
| `belongs_to`, `contains`, `depends_on`, `blocks`, `executes`, `awaits_merge`, `related_to`, `uses_provider`, `mentions_file` edges | Derived | Recomputed from the same inputs; edges are never written as durable truth. |
| File manifest, chunks, FTS/search tables, thumbnails, caches | Derived | Disposable and capped. Source and artifact objects are the rebuild inputs. |
| `graphify.db`, SQLite WAL/SHM, search database | Derived app-global projection | May be deleted and rebuilt. A pre-export backup is retained only as the RR-287 rollback boundary. |
| Cross-project UI preferences | App-global durable | Application Support preferences only when they contain no project work content. No current Graphify capture kind qualifies. |
| Raw logs, raw audio, raw or sensitive transcripts, hidden reasoning, session/tool traces, secrets, and large binaries | Prohibited from Git | Rejected by the typed artifact writer or excluded from the whitelisted event schema. Raw logs remain bounded local operational data. |

## Durable event schema and write order

Schema version 1 contains an immutable event ID derived from the Graph stable
key, immutable artifact project ID, record kind, capture ID/index, summary,
optional details, occurrence time, capture source, provider attribution,
bounded ticket/run evidence, and kind-specific attributes. Unknown fields are
rejected. Caller transcript context and the legacy `raw_entry` object are not
part of the durable schema.

For artifact-enabled projects, `session_capture` first validates the same
registry-v2 scope token used by dispatch, commits all event records through one
serialized artifact mutation, and only then refreshes Graphify. A retry with
the same content is idempotent. Reusing an event identity with different
content fails; event files cannot be overwritten. Codex and Claude use the
same fields and validation. Provider identity only changes the `provider`
metadata value.

## Legacy export, rebuild, and rollback

The exporter inventories all five capture families, writes a deterministic
pre-export manifest, and refuses to commit when it finds malformed, duplicate,
orphaned, or cross-project records. The review report is stored in Relay-owned
local state. It creates a consistent SQLite backup, then publishes immutable
events with a deterministic writer event ID. Its journal stages are
`validated`, `exported`, and `verified`; interruption after the commit resumes
without creating a duplicate event or commit.

After artifact hashes match the pre-export manifest, a clean temporary
Graphify database is built from registry, artifact materialization, and
permitted run inputs. It replaces the old projection only if its durable
capture manifest exactly matches the expected manifest. The pre-export and
pre-rebuild databases remain available for rollback. Rollback may restore the
old projection reader, but it never deletes already emitted artifact events;
divergent event identities require explicit reconciliation.
