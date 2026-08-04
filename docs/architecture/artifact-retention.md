# Relay artifact retention and history

This is RR-273 phase 5 and implements the [RR-270 retention and materialization policy](../investigations/RR-270-repo-local-retention-and-scope.md#retention-and-materialization-policy). The provider-neutral service API is `services/artifact_retention.py`; it writes only through `ArtifactStore`.

## Exact age and exemptions

Planning is read-only and remains available while retention is in preview-only mode. At one captured UTC instant `T`, the inclusive recent boundary is `T - 30 * 24 hours`. Exactly 30 days remains materialized; one microsecond older is eligible. Time-zone and daylight-saving changes cannot alter this duration.

`activity_at` is the maximum valid RFC 3339 instant among durable ticket activity fields: user/PM edit, dependency or status change, claim, run/review/merge outcome, attachment change, restore, and reopen. Tickets lacking a durable timestamp fail closed until migration supplies an explicit anchor; filesystem mtime is never used.

Ready, in-progress, verification-blocked, awaiting-review, merge-conflict, blocked, active-run, unresolved-dependency, pending-sync, unpublished-conflict, pinned, and active worker/reviewer snapshot-lease tickets are exempt. Snapshot leases are durable app-local records tied to immutable project, ticket, artifact head, run, role, provider, and attachment paths. They are idempotent and never expire from age alone; daemon recovery must prove a terminal path and explicitly release them.

## Archive transaction

The deterministic preview is re-evaluated under the project writer and lease locks. Every ticket and attachment blob is validated before mutation. One ordinary artifact commit writes the sorted JSONL catalog and deletes the selected head paths. Catalog entries retain immutable artifact/display identity, title/status/activity, exact source commit, ticket blob, and attachment paths/blob IDs/MIME/sizes. The new head is accepted only after each deleted blob is proven reachable through that commit.

Local-only archival proceeds with a visible warning that device loss has no remote recovery. For a remote-enabled project, Relay runs exact-ref synchronization after the local archive commit. If normal fast-forward publication does not reach Clean, Relay compare-and-swap rewinds only that unpublished archive commit and rematerializes its verified parent. It never rewrites published history and never leaves active files removed after an offline/auth/conflict failure.

Failure before commit leaves the ref and projection unchanged. If the ref advances before a crash, normal artifact recovery rematerializes from that canonical ref. Missing, unreachable, or mismatched ticket/attachment objects stop before an active copy is removed.

## History, restore, dependencies, and delete

History search reads the compact catalog. Detail validates and streams the historical Git blob without rematerializing it. If a shallow clone lacks the source commit or blob, offline detail reports `needs_network`; an online caller may explicitly deepen only the configured artifact ref and retry. Catalog/path/blob disagreement reports `tampered`.

Restore verifies all objects, then creates one normal idempotent writer commit that re-adds the original immutable ticket and attachments, updates `activity_at`, and marks the catalog entry materialized. Archived Done dependencies satisfy active dependents through their catalog record; archived non-Done dependencies remain unresolved.

Routine Delete is an ordinary recoverable tombstone commit and warns that Git history remains. Sensitive-data purge is not a retention operation: rotate exposed credentials and use a separately reviewed, coordinated history-rewrite and remote-cleanup procedure.

## Honest storage accounting

The service reports materialized working-tree bytes/file count, all objects reachable from the artifact head, local run database/log bytes, derived index/cache bytes, and a safe reclaimable estimate. Archived Git objects remain reachable and are never labeled reclaimable merely because their files left the head. Provider attribution cannot change age, exemption, history, lease, archive, restore, or deletion behavior.
