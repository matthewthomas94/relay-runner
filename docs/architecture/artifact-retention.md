# Relay artifact retention and history

RR-337 replaces the original RR-273 age policy with the accepted terminal-count policy. The provider-neutral service API is `services/artifact_retention.py`; it writes only through `ArtifactStore`.

## Automatic operation and agent retrieval

Completed-ticket housekeeping runs for every available registered project at
daemon startup and every 60 seconds, independently of the Workspace UI. Opening,
adding, or creating a project also wakes the background check. Boards with 25 or
fewer completed tickets are left unchanged; unfinished tickets have no count cap.

When a project first exceeds 25 completed tickets, Relay automatically selects
its configured archive remote, its existing `origin`, or its sole GitHub remote.
It migrates a legacy board through the verified archive writer, publishes the
records, and removes only the excess local files. No per-project activation or
Storage screen is required. Missing, ambiguous, or unreachable backup destinations
preserve local files and are retried; Relay does not create a GitHub repository.

An agent can explicitly choose a destination when multiple remotes are ambiguous:

```bash
scripts/relay-ticket-history enable --repo /path/to/project --remote origin
```

The selected fetch and push destinations are recorded durably. Changed
destinations pause housekeeping; ordinary batches need no confirmation or UI
action. All unfinished tickets and the newest 25 combined Done-or-Canceled
tickets stay local. Explicitly paused or opted-out projects and paused rollout
cohorts are not published. Default `local_only` registration metadata does not
disable automatic setup once a GitHub remote exists. Failed initial setup and
incomplete archive transactions are retried automatically.

New repositories do not need a first source commit. If their GitHub remote is
added later, the next background pass picks it up and applies the same limit.
Migration preserves the unborn source branch and unrelated staged work. Existing
canonical boards also acquire the automatic writer without a second legacy import.
Recovery checks migration and materialization journals before treating a missing
ticket directory as an empty project. A failed project never stops housekeeping
for other registered projects, including inactive ones.

Interrupted setup revalidates the recorded fetch and push destinations before
publishing. Ticket edits made since the migration backup pause source cleanup
for reconciliation, preserving those edits.

Agents can discover and retrieve old work without restoring ticket files:

```bash
scripts/relay-ticket-history search "voice playback" --repo /path/to/project
scripts/relay-ticket-history search "implementation detail" --full-text --repo /path/to/project
scripts/relay-ticket-history show RR-42 --repo /path/to/project
```

Results include immutable GitHub blob URLs. `show` returns the verified complete
ticket and attachment metadata. A fresh agent can add `--remote origin` to search
or show directly from GitHub in a disposable repository; no migration, local
archive checkout, or ticket restoration is required. The installed
entrypoint is `/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-ticket-history`.
Codex and Claude use identical commands and retention behavior. History is an
optional browser; there is no Storage tab or manual cleanup workflow.

The limit applies to materialized ticket files and their managed attachments.
Ordinary Git history, including historical archive blobs, remains recoverable;
this is not a Git history purge.

## Terminal-only count and ordering

Planning is read-only and remains available while retention is in preview-only mode. `terminal-count-v1` always materializes every nonterminal ticket without a count cap. Done and Canceled tickets form one pool; the 25 newest are retained. The deterministic order is descending canonical `activity_at`, then ascending immutable `artifact_id`. Display IDs and provider identity never affect the result.

`activity_at` is the maximum valid RFC 3339 instant among durable ticket activity fields: user/PM edit, dependency or status change, claim, run/review/merge outcome, attachment change, restore, and reopen. Tickets lacking a durable timestamp fail closed until migration supplies an explicit anchor; filesystem mtime is never used.

Reopening or restoring a terminal ticket refreshes canonical activity. A nonterminal reopen leaves the terminal pool immediately; a later Done or Canceled transition re-enters at its new canonical position. Archived catalog records participate in the same ranking without eager restoration. An archived record selected for the retained 25, or any archived nonterminal record, is reported in `materialize_ids` for the publication/recovery layer.

An older terminal ticket may remain temporarily materialized only for an active worker/reviewer lifecycle or snapshot lease, unpublished content, an in-flight retention transaction, or a retryable verification failure. Preview reports exact ticket IDs and reasons as `temporary_overage`. These reasons are reevaluated after canonical mutation; dependencies and user pins do not permanently exempt an old terminal ticket. Snapshot leases are durable and never expire from elapsed time alone.

## Archive transaction

The deterministic preview is re-evaluated under the project writer and lease locks. Automatic setup binds the existing `github.com` remote name plus its fetch and sole effective push URL digests. Relay revalidates the push destination immediately before archive publication and pushes to that exact destination. Relay never creates, renames, or rewrites a remote. Projects without a usable destination and explicitly paused projects remain temporary overage.

Every ticket and attachment blob is validated before mutation. Relay prepares one ordinary descendant commit on a private scratch ref; it writes the sorted JSONL catalog and deletes only terminal candidates outside the retained 25. Catalog entries retain immutable artifact/display identity, title/status/activity/dependencies, exact source commit, ticket blob, and attachment paths/blob IDs/MIME/sizes. Preparing the commit does not advance `refs/heads/relay/artifacts` or rebuild `.orchestrator`.

The synchronizer first reconciles the selected remote to the preview base using only the exposure-confirmed fetch and push URL digests. It then fast-forward-pushes only the exact prepared artifact refspec under a compare-and-swap lease bound to the exact preflight head, creates a second fresh quarantine, refetches only that ref through the confirmed fetch URL, and proves that the prepared commit is reachable and the catalog, ticket, and attachment blob identities and SHA-256 digests match. An indeterminate push is resolved by refetching. A remote descendant that still reaches the prepared commit is safe; deletion, rewind, advancement, unrelated, missing, protected, non-fast-forward, offline, authentication, shallow-object, and integrity outcomes remain retryable blockers. The direct-descendant check prevents the lease from authorizing a non-fast-forward candidate.

Only after remote proof succeeds does a compare-and-swap advance the local artifact authority and atomically rebuild `.orchestrator`. The prepared commit is pinned on its private scratch ref before a durable owner-only journal can expose the `prepared` phase; the journal then records `published`, `local_ref_advanced`, and `materialized`, and every phase is idempotently resumable. Before local adoption, candidates remain materialized. After adoption, the artifact store's own materialization journal reconstructs the verified canonical head after a crash. Completing the transaction removes its scratch ref and journal.

Fresh-install and second-device recovery use the same confirmed remote URL digest. A disposable quarantine fetches only `refs/heads/relay/artifacts` from that exact destination, validates project identity, linear orphan history, allowlisted content, selected sync configuration, and the terminal-count layout, then compare-and-swap imports the ref and materializes it. Recovery refuses remote retargeting, an existing unowned `.orchestrator` tree, local materialization edits, divergence, candidates still outside the newest 25, or required archived cards that are not materialized.

## History, restore, dependencies, and delete

History search reads the compact catalog. Detail validates and streams the historical Git blob without rematerializing it. If a shallow clone lacks the source commit or blob, offline detail reports `needs_network`; an online caller may explicitly deepen only the configured artifact ref and retry. Catalog/path/blob disagreement reports `tampered`.

The loopback daemon exposes scoped preview/status/apply/retry, history search/detail, verified attachment retrieval, restore/reopen, dependency summary, and storage routes below `/v1/artifacts`. Read routes never restore Markdown as a side effect. Mutating routes require the same confirmed project-scope token as the artifact-backed board writer plus a stable request ID; remote archival and online history fetch additionally require explicit GitHub exposure confirmation.

Graphify ingests archived and tombstoned catalog entries as metadata-only ticket nodes. Those nodes keep title, terminal state, immutable artifact identity, and dependency edges searchable while their Markdown remains absent; malformed historical identities fail ingestion instead of silently pruning known history.

Restore verifies all objects, then creates one normal idempotent writer commit that re-adds the original immutable ticket and attachments, updates `activity_at`, and marks the catalog entry materialized. Reopen performs the same verification but clears terminal/run ownership and moves the ticket to Backlog, making it uncapped immediately. Archived Done dependencies satisfy active dependents through verified catalog history without restoring the predecessor; missing or tampered history is surfaced as an explicit dependency blocker.

The Workspace exposes this contract from the selected project's **History** control. The live board contains every materialized nonterminal ticket plus the materialized Done-or-Canceled pool; metadata-only terminal records appear in History instead of a live lane. Search and detail do not restore files. Detail shows dependency and attachment availability, while **Restore detail** explicitly rematerializes a terminal record and **Reopen in Backlog** moves it into the uncapped nonterminal set.

User-facing state badges are intentionally specific: **Materialized**, **Temporary Safety Overage**, **GitHub-backed • Locally Reachable Through Git**, **Needs Network**, **Local Archive Only**, **Missing**, and **Tampered**. “GitHub-backed” never means “remote only”: a verified historical object may still be reachable in local Git even when its Markdown is absent from `.orchestrator/`.

The diagnostic retention APIs still expose retained tickets, candidates and retry reasons to agents. Setup, routine cleanup and retry are automatic. Offline, authentication, divergence, interruption, or integrity failures keep candidate files materialized.

Routine Delete is an ordinary recoverable tombstone commit and warns that Git history remains. Sensitive-data purge is not a retention operation: rotate exposed credentials and use a separately reviewed, coordinated history-rewrite and remote-cleanup procedure.

## Honest storage accounting

The service separately reports materialized ticket and attachment bytes/file counts, retained-terminal/nonterminal/temporary-overage counts, verified remote-backed history, reachable Git objects, databases, run logs, indexes, caches, and a safe reclaimable estimate. Retention removes only materialized ticket Markdown and Relay-owned attachments. Archived Git objects remain reachable; retention does not rewrite history, force-push, run destructive garbage collection, or label those objects reclaimable. Provider attribution cannot change eligibility, order, history, lease, archive, restore, or deletion behavior.
