# Relay artifact retention and history

RR-337 replaces the original RR-273 age policy with the accepted terminal-count policy. The provider-neutral service API is `services/artifact_retention.py`; it writes only through `ArtifactStore`.

## Terminal-only count and ordering

Planning is read-only and remains available while retention is in preview-only mode. `terminal-count-v1` always materializes every nonterminal ticket without a count cap. Done and Canceled tickets form one pool; the 25 newest are retained. The deterministic order is descending canonical `activity_at`, then ascending immutable `artifact_id`. Display IDs and provider identity never affect the result.

`activity_at` is the maximum valid RFC 3339 instant among durable ticket activity fields: user/PM edit, dependency or status change, claim, run/review/merge outcome, attachment change, restore, and reopen. Tickets lacking a durable timestamp fail closed until migration supplies an explicit anchor; filesystem mtime is never used.

Reopening or restoring a terminal ticket refreshes canonical activity. A nonterminal reopen leaves the terminal pool immediately; a later Done or Canceled transition re-enters at its new canonical position. Archived catalog records participate in the same ranking without eager restoration. An archived record selected for the retained 25, or any archived nonterminal record, is reported in `materialize_ids` for the publication/recovery layer.

An older terminal ticket may remain temporarily materialized only for an active worker/reviewer lifecycle or snapshot lease, unpublished content, an in-flight retention transaction, or a retryable verification failure. Preview reports exact ticket IDs and reasons as `temporary_overage`. These reasons are reevaluated after canonical mutation; dependencies and user pins do not permanently exempt an old terminal ticket. Snapshot leases are durable and never expire from elapsed time alone.

## Archive transaction

The deterministic preview is re-evaluated under the project writer and lease locks. Every ticket and attachment blob is validated before mutation. One ordinary artifact commit writes the sorted JSONL catalog and deletes only terminal candidates outside the retained 25. Catalog entries retain immutable artifact/display identity, title/status/activity/dependencies, exact source commit, ticket blob, and attachment paths/blob IDs/MIME/sizes. The new head is accepted only after each deleted blob is proven reachable through that commit.

Local-only archival proceeds with a visible warning that device loss has no remote recovery. For a remote-enabled project, Relay runs exact-ref synchronization after the local archive commit. If normal fast-forward publication does not reach Clean, Relay compare-and-swap rewinds only that unpublished archive commit and rematerializes its verified parent. It never rewrites published history and never leaves active files removed after an offline/auth/conflict failure.

Failure before commit leaves the ref and projection unchanged. If the ref advances before a crash, normal artifact recovery rematerializes from that canonical ref. Missing, unreachable, or mismatched ticket/attachment objects stop before an active copy is removed.

## History, restore, dependencies, and delete

History search reads the compact catalog. Detail validates and streams the historical Git blob without rematerializing it. If a shallow clone lacks the source commit or blob, offline detail reports `needs_network`; an online caller may explicitly deepen only the configured artifact ref and retry. Catalog/path/blob disagreement reports `tampered`.

Restore verifies all objects, then creates one normal idempotent writer commit that re-adds the original immutable ticket and attachments, updates `activity_at`, and marks the catalog entry materialized. Archived Done dependencies satisfy active dependents through catalog metadata without restoring the predecessor; archived non-Done dependencies remain unresolved.

Routine Delete is an ordinary recoverable tombstone commit and warns that Git history remains. Sensitive-data purge is not a retention operation: rotate exposed credentials and use a separately reviewed, coordinated history-rewrite and remote-cleanup procedure.

## Honest storage accounting

The service reports materialized working-tree bytes/file count, all objects reachable from the artifact head, local run database/log bytes, derived index/cache bytes, and a safe reclaimable estimate. Retention removes only materialized ticket Markdown and Relay-owned attachments. Archived Git objects remain reachable; retention does not rewrite history, force-push, run destructive garbage collection, or label those objects reclaimable. Provider attribution cannot change eligibility, order, history, lease, archive, restore, or deletion behavior.
