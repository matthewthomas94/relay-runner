# Relay artifact retention and history

RR-337 replaces the original RR-273 age policy with the accepted terminal-count policy. The provider-neutral service API is `services/artifact_retention.py`; it writes only through `ArtifactStore`.

## Terminal-only count and ordering

Planning is read-only and remains available while retention is in preview-only mode. `terminal-count-v1` always materializes every nonterminal ticket without a count cap. Done and Canceled tickets form one pool; the 25 newest are retained. The deterministic order is descending canonical `activity_at`, then ascending immutable `artifact_id`. Display IDs and provider identity never affect the result.

`activity_at` is the maximum valid RFC 3339 instant among durable ticket activity fields: user/PM edit, dependency or status change, claim, run/review/merge outcome, attachment change, restore, and reopen. Tickets lacking a durable timestamp fail closed until migration supplies an explicit anchor; filesystem mtime is never used.

Reopening or restoring a terminal ticket refreshes canonical activity. A nonterminal reopen leaves the terminal pool immediately; a later Done or Canceled transition re-enters at its new canonical position. Archived catalog records participate in the same ranking without eager restoration. An archived record selected for the retained 25, or any archived nonterminal record, is reported in `materialize_ids` for the publication/recovery layer.

An older terminal ticket may remain temporarily materialized only for an active worker/reviewer lifecycle or snapshot lease, unpublished content, an in-flight retention transaction, or a retryable verification failure. Preview reports exact ticket IDs and reasons as `temporary_overage`. These reasons are reevaluated after canonical mutation; dependencies and user pins do not permanently exempt an old terminal ticket. Snapshot leases are durable and never expire from elapsed time alone.

## Archive transaction

The deterministic preview is re-evaluated under the project writer and lease locks. Cleanup is disabled until the user selects an existing `github.com` remote and explicitly confirms exposing Relay ticket content; the confirmation is bound to that remote name plus its fetch and sole effective push URL digests. Relay revalidates the push destination immediately before publication and pushes to that exact confirmed URL. Relay never creates, guesses, renames, or rewrites the remote. Local-only and paused projects remain visible temporary overage.

Every ticket and attachment blob is validated before mutation. Relay prepares one ordinary descendant commit on a private scratch ref; it writes the sorted JSONL catalog and deletes only terminal candidates outside the retained 25. Catalog entries retain immutable artifact/display identity, title/status/activity/dependencies, exact source commit, ticket blob, and attachment paths/blob IDs/MIME/sizes. Preparing the commit does not advance `refs/heads/relay/artifacts` or rebuild `.orchestrator`.

The synchronizer first reconciles the selected remote to the preview base. It then normally fast-forward-pushes only the exact prepared artifact refspec, creates a second fresh quarantine, refetches only that ref, and proves that the prepared commit is reachable and the catalog, ticket, and attachment blob identities and SHA-256 digests match. An indeterminate push is resolved by refetching. A remote descendant that still reaches the prepared commit is safe; unrelated, missing, protected, non-fast-forward, offline, authentication, shallow-object, and integrity outcomes remain retryable blockers. No force path exists.

Only after remote proof succeeds does a compare-and-swap advance the local artifact authority and atomically rebuild `.orchestrator`. A durable owner-only journal records `prepared`, `published`, `local_ref_advanced`, and `materialized`; every phase is idempotently resumable. Before local adoption, candidates remain materialized. After adoption, the artifact store's own materialization journal reconstructs the verified canonical head after a crash. Completing the transaction removes its scratch ref and journal.

Fresh-install and second-device recovery use the same confirmed remote. A disposable quarantine fetches only `refs/heads/relay/artifacts`, validates project identity, linear orphan history, allowlisted content, selected sync configuration, and the terminal-count layout, then compare-and-swap imports the ref and materializes it. Recovery refuses an existing unowned `.orchestrator` tree, local materialization edits, divergence, candidates still outside the newest 25, or required archived cards that are not materialized.

## History, restore, dependencies, and delete

History search reads the compact catalog. Detail validates and streams the historical Git blob without rematerializing it. If a shallow clone lacks the source commit or blob, offline detail reports `needs_network`; an online caller may explicitly deepen only the configured artifact ref and retry. Catalog/path/blob disagreement reports `tampered`.

Restore verifies all objects, then creates one normal idempotent writer commit that re-adds the original immutable ticket and attachments, updates `activity_at`, and marks the catalog entry materialized. Archived Done dependencies satisfy active dependents through catalog metadata without restoring the predecessor; archived non-Done dependencies remain unresolved.

Routine Delete is an ordinary recoverable tombstone commit and warns that Git history remains. Sensitive-data purge is not a retention operation: rotate exposed credentials and use a separately reviewed, coordinated history-rewrite and remote-cleanup procedure.

## Honest storage accounting

The service reports materialized working-tree bytes/file count, all objects reachable from the artifact head, local run database/log bytes, derived index/cache bytes, and a safe reclaimable estimate. Retention removes only materialized ticket Markdown and Relay-owned attachments. Archived Git objects remain reachable; retention does not rewrite history, force-push, run destructive garbage collection, or label those objects reclaimable. Provider attribution cannot change eligibility, order, history, lease, archive, restore, or deletion behavior.
