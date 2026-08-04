#!/usr/bin/env python3
"""Bounded Relay artifact materialization, history, and snapshot leases.

Retention changes only the project-owned artifact ref through ``ArtifactStore``.
The source branch, source index, worktree state, and configured remotes remain
outside this module.
"""

from __future__ import annotations

import contextlib
import dataclasses
import enum
import fcntl
import json
import os
import re
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Mapping, Sequence

try:
    from services.artifact_store import (
        ArchiveIndexWrite,
        ArtifactConcurrentUpdate,
        ArtifactMaterializationConflict,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ArtifactWriteResult,
        AttachmentWrite,
        TicketDelete,
        TicketWrite,
        _attachment_mime_for_filename,
    )
except ModuleNotFoundError:  # Direct services/*.py execution.
    from artifact_store import (  # type: ignore[no-redef]
        ArchiveIndexWrite,
        ArtifactConcurrentUpdate,
        ArtifactMaterializationConflict,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ArtifactWriteResult,
        AttachmentWrite,
        TicketDelete,
        TicketWrite,
        _attachment_mime_for_filename,
    )


UTC = timezone.utc
RETENTION_AGE = timedelta(days=30)
CATALOG_SCHEMA_VERSION = 1
LEASE_SCHEMA_VERSION = 1

ACTIVITY_FIELDS = (
    "activity_at",
    "user_edited_at",
    "pm_edited_at",
    "dependency_updated_at",
    "status_updated_at",
    "claimed_at",
    "run_outcome_at",
    "review_outcome_at",
    "merge_outcome_at",
    "attachment_updated_at",
    "restored_at",
    "reopened_at",
)

ACTIVE_STATUSES = {
    "ready",
    "in_progress",
    "verification_blocked",
    "awaiting_review",
    "merge_conflict",
}
ACTIVE_RUN_STATES = {"claimed", "running", "awaiting_review", "reviewing", "merge_conflict"}
ARCHIVEABLE_STATUSES = {"backlog", "done", "canceled", "cancelled"}

_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
_lease_locks_guard = threading.Lock()
_lease_locks: dict[str, threading.RLock] = {}
_lease_lock_depth = threading.local()


class RetentionState(str, enum.Enum):
    MATERIALIZED_RECENT = "materialized_recent"
    MATERIALIZED_EXEMPT = "materialized_exempt"
    ARCHIVE_ELIGIBLE = "archive_eligible"
    ARCHIVE_PENDING_SYNC = "archive_pending_sync"
    ARCHIVED = "archived"
    RESTORE_PENDING_FETCH = "restore_pending_fetch"
    RESTORE_PENDING_SYNC = "restore_pending_sync"
    CONFLICT = "conflict"
    DELETED_TOMBSTONE = "deleted_tombstone"


class HistoryAvailability(str, enum.Enum):
    AVAILABLE = "available"
    NEEDS_NETWORK = "needs_network"
    TAMPERED = "tampered"
    NOT_FOUND = "not_found"


@dataclasses.dataclass(frozen=True)
class SnapshotLease:
    lease_id: str
    project_id: str
    ticket_id: str
    artifact_id: str
    artifact_head: str
    run_id: str
    role: str
    provider: str
    attachment_paths: tuple[str, ...]
    created_at: datetime
    heartbeat_at: datetime
    state: str = "active"
    released_at: datetime | None = None
    terminal_reason: str | None = None


@dataclasses.dataclass(frozen=True)
class RetentionTicket:
    ticket_id: str
    artifact_id: str
    title: str
    status: str
    activity_at: datetime
    path: str
    blob_id: str
    source_commit: str
    dependencies: tuple[str, ...]
    attachment_paths: tuple[str, ...]
    exemptions: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class RetentionPlan:
    project_id: str
    artifact_head: str
    evaluated_at: datetime
    cutoff: datetime
    candidates: tuple[RetentionTicket, ...]
    recent: tuple[RetentionTicket, ...]
    exempt: tuple[RetentionTicket, ...]

    @property
    def candidate_ids(self) -> tuple[str, ...]:
        return tuple(ticket.ticket_id for ticket in self.candidates)


@dataclasses.dataclass(frozen=True)
class ArchiveResult:
    state: RetentionState
    write: ArtifactWriteResult | None
    ticket_ids: tuple[str, ...]
    warnings: tuple[str, ...] = ()
    recovery: str | None = None


@dataclasses.dataclass(frozen=True)
class HistoricalCard:
    artifact_id: str
    ticket_id: str
    title: str
    status: str
    activity_at: datetime
    state: RetentionState
    attachment_count: int
    attachment_bytes: int


@dataclasses.dataclass(frozen=True)
class HistoricalDetail:
    availability: HistoryAvailability
    card: HistoricalCard | None
    ticket_bytes: bytes | None = None
    attachments: tuple[Mapping[str, object], ...] = ()
    recovery: str | None = None


@dataclasses.dataclass(frozen=True)
class StorageMetrics:
    materialized_worktree_bytes: int
    materialized_file_count: int
    reachable_git_object_bytes: int
    run_database_log_bytes: int
    derived_index_cache_bytes: int
    reclaimable_estimate_bytes: int


class SnapshotLeaseStore:
    """Durable, provider-neutral archive exemptions for worker snapshots."""

    def __init__(self, store: ArtifactStore) -> None:
        self.store = store
        self.path = store.project_state / "snapshot-leases.json"
        self.lock_path = store.project_state / "snapshot-leases.lock"

    def acquire(
        self,
        *,
        lease_id: str,
        ticket_id: str,
        artifact_id: str,
        artifact_head: str,
        run_id: str,
        role: str,
        provider: str,
        attachment_paths: Sequence[str] = (),
        now: datetime | None = None,
    ) -> SnapshotLease:
        for value, label in (
            (lease_id, "lease ID"),
            (ticket_id, "ticket ID"),
            (artifact_id, "artifact ID"),
            (run_id, "run ID"),
        ):
            _validate_safe_id(value, label)
        if role not in {"worker", "reviewer"}:
            raise ArtifactValidationError(f"invalid snapshot lease role: {role!r}")
        if provider not in {"codex", "claude"}:
            raise ArtifactValidationError(f"invalid snapshot lease provider: {provider!r}")
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", artifact_head):
            raise ArtifactValidationError("snapshot lease artifact head is not a Git object ID")
        normalized_paths = tuple(sorted(set(attachment_paths)))
        for path in normalized_paths:
            expected_prefix = f".orchestrator/attachments/{ticket_id}/"
            if not path.startswith(expected_prefix) or PurePosixPath(path).name == "":
                raise ArtifactValidationError(
                    f"snapshot lease attachment is not owned by {ticket_id}: {path!r}"
                )
        instant = _utc(now or datetime.now(UTC))
        proposed = SnapshotLease(
            lease_id=lease_id,
            project_id=self.store.project_id,
            ticket_id=ticket_id,
            artifact_id=artifact_id,
            artifact_head=artifact_head,
            run_id=run_id,
            role=role,
            provider=provider,
            attachment_paths=normalized_paths,
            created_at=instant,
            heartbeat_at=instant,
        )
        with self._locked():
            leases = self._load_unlocked()
            existing = leases.get(lease_id)
            if existing:
                comparable_existing = dataclasses.replace(
                    existing,
                    heartbeat_at=proposed.heartbeat_at,
                    created_at=proposed.created_at,
                )
                if comparable_existing != proposed:
                    raise ArtifactValidationError(
                        f"snapshot lease ID {lease_id!r} was reused with different ownership"
                    )
                return existing
            leases[lease_id] = proposed
            self._write_unlocked(leases)
            return proposed

    def heartbeat(self, lease_id: str, *, now: datetime | None = None) -> SnapshotLease:
        with self._locked():
            leases = self._load_unlocked()
            lease = leases.get(lease_id)
            if not lease or lease.state != "active":
                raise ArtifactValidationError(f"snapshot lease {lease_id!r} is not active")
            updated = dataclasses.replace(lease, heartbeat_at=_utc(now or datetime.now(UTC)))
            leases[lease_id] = updated
            self._write_unlocked(leases)
            return updated

    def release(
        self,
        lease_id: str,
        *,
        terminal_reason: str,
        now: datetime | None = None,
    ) -> SnapshotLease:
        if not terminal_reason.strip() or len(terminal_reason) > 200:
            raise ArtifactValidationError("snapshot lease release needs a bounded terminal reason")
        with self._locked():
            leases = self._load_unlocked()
            lease = leases.get(lease_id)
            if not lease:
                raise ArtifactValidationError(f"unknown snapshot lease {lease_id!r}")
            if lease.state == "released":
                if lease.terminal_reason != terminal_reason:
                    raise ArtifactValidationError(
                        f"snapshot lease {lease_id!r} was already released for another reason"
                    )
                return lease
            updated = dataclasses.replace(
                lease,
                state="released",
                released_at=_utc(now or datetime.now(UTC)),
                terminal_reason=terminal_reason,
            )
            leases[lease_id] = updated
            self._write_unlocked(leases)
            return updated

    def active(self) -> tuple[SnapshotLease, ...]:
        with self._locked():
            return tuple(
                sorted(
                    (lease for lease in self._load_unlocked().values() if lease.state == "active"),
                    key=lambda lease: lease.lease_id,
                )
            )

    def active_ticket_ids(self) -> frozenset[str]:
        # Deliberately no time expiry. Daemon recovery must prove a terminal run
        # before releasing a lease; an old heartbeat alone is never such proof.
        return frozenset(lease.ticket_id for lease in self.active())

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        key = str(self.lock_path)
        with _lease_locks_guard:
            process_lock = _lease_locks.setdefault(key, threading.RLock())
        with process_lock:
            depths = getattr(_lease_lock_depth, "depths", None)
            if depths is None:
                depths = {}
                _lease_lock_depth.depths = depths
            if depths.get(key, 0) > 0:
                depths[key] += 1
                try:
                    yield
                finally:
                    depths[key] -= 1
                return
            with self.lock_path.open("a+b") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                depths[key] = 1
                try:
                    yield
                finally:
                    depths.pop(key, None)
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _load_unlocked(self) -> dict[str, SnapshotLease]:
        if not self.path.exists():
            return {}
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"snapshot lease store is corrupt: {error}") from error
        if payload.get("schema_version") != LEASE_SCHEMA_VERSION:
            raise ArtifactValidationError("snapshot lease schema is unsupported")
        if payload.get("project_id") != self.store.project_id:
            raise ArtifactValidationError("snapshot lease store belongs to another project")
        result: dict[str, SnapshotLease] = {}
        for raw in payload.get("leases", []):
            lease = SnapshotLease(
                lease_id=raw["lease_id"],
                project_id=raw["project_id"],
                ticket_id=raw["ticket_id"],
                artifact_id=raw["artifact_id"],
                artifact_head=raw["artifact_head"],
                run_id=raw["run_id"],
                role=raw["role"],
                provider=raw["provider"],
                attachment_paths=tuple(raw.get("attachment_paths", [])),
                created_at=_parse_instant(raw["created_at"]),
                heartbeat_at=_parse_instant(raw["heartbeat_at"]),
                state=raw.get("state", "active"),
                released_at=_parse_instant(raw["released_at"]) if raw.get("released_at") else None,
                terminal_reason=raw.get("terminal_reason"),
            )
            if lease.project_id != self.store.project_id or lease.lease_id in result:
                raise ArtifactValidationError("snapshot lease identity is invalid or duplicated")
            result[lease.lease_id] = lease
        return result

    def _write_unlocked(self, leases: Mapping[str, SnapshotLease]) -> None:
        payload = {
            "schema_version": LEASE_SCHEMA_VERSION,
            "project_id": self.store.project_id,
            "leases": [_lease_json(leases[key]) for key in sorted(leases)],
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + f".{uuid.uuid4().hex}.tmp")
        temporary.write_text(_canonical_json(payload) + "\n", encoding="utf-8")
        os.replace(temporary, self.path)


class ArtifactRetentionManager:
    """Plans and commits retention without creating another ticket authority."""

    def __init__(
        self,
        store: ArtifactStore,
        *,
        lease_store: SnapshotLeaseStore | None = None,
        remote_mode: str = "local_only",
        enabled: bool = False,
        now: Callable[[], datetime] | None = None,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        if remote_mode not in {"local_only", "enabled", "paused"}:
            raise ArtifactValidationError(f"invalid retention remote mode: {remote_mode!r}")
        self.store = store
        self.lease_store = lease_store or SnapshotLeaseStore(store)
        self.remote_mode = remote_mode
        self.enabled = enabled
        self.now = now or (lambda: datetime.now(UTC))
        self.failure_injector = failure_injector

    def preview(self, *, evaluated_at: datetime | None = None) -> RetentionPlan:
        instant = _utc(evaluated_at or self.now())
        snapshot = self.store.snapshot()
        entries = self.store._tree_entries(snapshot.commit_id)
        leased = self.lease_store.active_ticket_ids()
        active_statuses = self._ticket_status_map(snapshot.files)
        recent: list[RetentionTicket] = []
        exempt: list[RetentionTicket] = []
        candidates: list[RetentionTicket] = []
        for path in sorted(snapshot.files):
            if not _is_ticket_path(path):
                continue
            ticket_id = PurePosixPath(path).stem
            content = snapshot.files[path]
            ticket = self._retention_ticket(
                snapshot.commit_id,
                ticket_id,
                path,
                content,
                entries[path].oid,
                snapshot.files,
                active_statuses,
                leased,
            )
            if ticket.exemptions:
                exempt.append(ticket)
            elif ticket.activity_at >= instant - RETENTION_AGE:
                recent.append(ticket)
            elif ticket.status in ARCHIVEABLE_STATUSES:
                candidates.append(ticket)
            else:
                exempt.append(dataclasses.replace(ticket, exemptions=("nonterminal_status",)))
        key = lambda ticket: (ticket.activity_at, ticket.artifact_id, ticket.ticket_id)
        return RetentionPlan(
            project_id=self.store.project_id,
            artifact_head=snapshot.commit_id,
            evaluated_at=instant,
            cutoff=instant - RETENTION_AGE,
            candidates=tuple(sorted(candidates, key=key)),
            recent=tuple(sorted(recent, key=key)),
            exempt=tuple(sorted(exempt, key=key)),
        )

    def archive(
        self,
        plan: RetentionPlan,
        *,
        event_id: str,
        device_id: str,
        actor_type: str = "system",
        provider: str | None = None,
        synchronizer: object | None = None,
    ) -> ArchiveResult:
        self._require_enabled()
        if plan.project_id != self.store.project_id:
            raise ArtifactValidationError("retention plan belongs to another project")
        if not plan.candidates:
            return ArchiveResult(RetentionState.ARCHIVED, None, ())
        with self.lease_store._locked(), self.store._writer_lock():
            current = self.store._head()
            if current != plan.artifact_head:
                raise ArtifactConcurrentUpdate("artifact head changed since retention preview")
            refreshed = self.preview(evaluated_at=plan.evaluated_at)
            if refreshed.candidate_ids != plan.candidate_ids:
                raise ArtifactConcurrentUpdate("retention eligibility changed since preview")
            entries = self.store._tree_entries(current)
            catalog = self._catalog(current)
            for ticket in refreshed.candidates:
                self._verify_active_ticket(ticket, entries)
                catalog[ticket.artifact_id] = self._catalog_entry(ticket, entries, plan.evaluated_at)
            operations = [ArchiveIndexWrite(_encode_catalog(catalog))]
            operations.extend(TicketDelete(ticket.ticket_id) for ticket in refreshed.candidates)
            self._inject("before_archive_commit")
            write = self.store.mutate(
                ArtifactMutation(
                    event_id=event_id,
                    actor_type=actor_type,
                    device_id=device_id,
                    provider=provider,
                    expected_base=current,
                    operations=tuple(operations),
                    summary=f"Archive {len(refreshed.candidates)} Relay ticket(s)",
                )
            )
            self._verify_archived_reachability(write.commit_id, refreshed.candidates, catalog)
            if self.remote_mode == "enabled":
                if synchronizer is None:
                    self._rewind_unpublished_archive(write)
                    return ArchiveResult(
                        RetentionState.ARCHIVE_PENDING_SYNC,
                        None,
                        refreshed.candidate_ids,
                        recovery="Remote-enabled archival requires a verified synchronizer; active files were retained.",
                    )
                sync_result = synchronizer.sync()
                if getattr(getattr(sync_result, "state", None), "value", None) != "clean":
                    self._rewind_unpublished_archive(write)
                    return ArchiveResult(
                        RetentionState.ARCHIVE_PENDING_SYNC,
                        None,
                        refreshed.candidate_ids,
                        recovery=(
                            getattr(sync_result, "recovery", None)
                            or "Artifact archive could not be fast-forward-published; active files were retained."
                        ),
                    )
            warnings = ()
            if self.remote_mode == "local_only":
                warnings = (
                    "Archived history is local only; device loss is not remotely recoverable.",
                )
            return ArchiveResult(
                RetentionState.ARCHIVED,
                write,
                refreshed.candidate_ids,
                warnings=warnings,
            )

    def historical_search(self, query: str = "") -> tuple[HistoricalCard, ...]:
        catalog = self._catalog(self._head_required())
        needle = query.casefold().strip()
        cards = []
        for entry in catalog.values():
            state = entry.get("state")
            if state not in {RetentionState.ARCHIVED.value, RetentionState.DELETED_TOMBSTONE.value}:
                continue
            haystack = f"{entry.get('ticket_id', '')} {entry.get('title', '')}".casefold()
            if needle and needle not in haystack:
                continue
            cards.append(_card(entry))
        return tuple(sorted(cards, key=lambda card: (card.activity_at, card.artifact_id), reverse=True))

    def historical_detail(
        self,
        artifact_id: str,
        *,
        online: bool = False,
        deepen: Callable[[str], None] | None = None,
    ) -> HistoricalDetail:
        catalog = self._catalog(self._head_required())
        entry = catalog.get(artifact_id)
        if not entry:
            return HistoricalDetail(HistoryAvailability.NOT_FOUND, None)
        card = _card(entry)
        source_commit = str(entry.get("source_commit", ""))
        if not self._object_exists(source_commit):
            if not online or deepen is None:
                return HistoricalDetail(
                    HistoryAvailability.NEEDS_NETWORK,
                    card,
                    recovery="Connect and explicitly deepen the configured artifact ref.",
                )
            deepen(source_commit)
        try:
            ticket_bytes = self._verified_historical_blob(
                source_commit,
                str(entry["ticket_path"]),
                str(entry["ticket_blob"]),
            )
            for attachment in entry.get("attachments", []):
                self._verified_historical_blob(
                    source_commit,
                    str(attachment["path"]),
                    str(attachment["blob"]),
                )
        except _MissingHistoricalObject:
            return HistoricalDetail(
                HistoryAvailability.NEEDS_NETWORK,
                card,
                recovery="Required historical objects are unavailable; explicitly deepen while online.",
            )
        except ArtifactValidationError as error:
            return HistoricalDetail(
                HistoryAvailability.TAMPERED,
                card,
                recovery=str(error),
            )
        return HistoricalDetail(
            HistoryAvailability.AVAILABLE,
            card,
            ticket_bytes=ticket_bytes,
            attachments=tuple(dict(item) for item in entry.get("attachments", [])),
        )

    def restore(
        self,
        artifact_id: str,
        *,
        event_id: str,
        device_id: str,
        actor_type: str = "user",
        provider: str | None = None,
        restored_at: datetime | None = None,
        online: bool = False,
        deepen: Callable[[str], None] | None = None,
    ) -> ArchiveResult:
        self._require_enabled()
        prior = self.store._find_event(event_id)
        if prior:
            return ArchiveResult(
                RetentionState.RESTORE_PENDING_SYNC
                if self.remote_mode == "enabled"
                else RetentionState.MATERIALIZED_RECENT,
                _prior_result(self.store, event_id, prior[0]),
                (),
            )
        head = self._head_required()
        catalog = self._catalog(head)
        entry = catalog.get(artifact_id)
        if not entry or entry.get("state") not in {
            RetentionState.ARCHIVED.value,
            RetentionState.DELETED_TOMBSTONE.value,
        }:
            raise ArtifactValidationError(f"artifact {artifact_id!r} is not archived")
        detail = self.historical_detail(artifact_id, online=online, deepen=deepen)
        if detail.availability != HistoryAvailability.AVAILABLE or detail.ticket_bytes is None:
            raise ArtifactValidationError(detail.recovery or "historical ticket is unavailable")
        instant = _utc(restored_at or self.now())
        ticket_id = str(entry["ticket_id"])
        markdown = _set_front_matter_value(detail.ticket_bytes, "activity_at", _format_instant(instant))
        operations: list[object] = [TicketWrite(ticket_id, artifact_id, markdown)]
        source_commit = str(entry["source_commit"])
        for attachment in entry.get("attachments", []):
            path = str(attachment["path"])
            content = self._verified_historical_blob(
                source_commit,
                path,
                str(attachment["blob"]),
            )
            operations.append(
                AttachmentWrite(
                    ticket_id,
                    PurePosixPath(path).name,
                    str(attachment["mime_type"]),
                    content,
                )
            )
        entry = dict(entry)
        entry["state"] = RetentionState.MATERIALIZED_RECENT.value
        entry["restored_at"] = _format_instant(instant)
        catalog[artifact_id] = entry
        operations.append(ArchiveIndexWrite(_encode_catalog(catalog)))
        write = self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type=actor_type,
                device_id=device_id,
                provider=provider,
                expected_base=head,
                operations=tuple(operations),
                summary=f"Restore Relay ticket {ticket_id}",
            )
        )
        return ArchiveResult(
            RetentionState.RESTORE_PENDING_SYNC
            if self.remote_mode == "enabled"
            else RetentionState.MATERIALIZED_RECENT,
            write,
            (ticket_id,),
        )

    def delete(
        self,
        ticket_id: str,
        *,
        event_id: str,
        device_id: str,
        actor_type: str = "user",
        provider: str | None = None,
        deleted_at: datetime | None = None,
    ) -> ArchiveResult:
        self._require_enabled()
        instant = _utc(deleted_at or self.now())
        head = self._head_required()
        snapshot = self.store.snapshot()
        path = f".orchestrator/{ticket_id}.md"
        if path not in snapshot.files:
            raise ArtifactValidationError(f"ticket {ticket_id!r} is not materialized")
        entries = self.store._tree_entries(head)
        statuses = self._ticket_status_map(snapshot.files)
        ticket = self._retention_ticket(
            head,
            ticket_id,
            path,
            snapshot.files[path],
            entries[path].oid,
            snapshot.files,
            statuses,
            self.lease_store.active_ticket_ids(),
        )
        if ticket.exemptions:
            raise ArtifactValidationError(
                f"ticket {ticket_id} cannot be deleted while exempt: {', '.join(ticket.exemptions)}"
            )
        catalog = self._catalog(head)
        entry = self._catalog_entry(ticket, entries, instant)
        entry["state"] = RetentionState.DELETED_TOMBSTONE.value
        entry["deleted_at"] = _format_instant(instant)
        catalog[ticket.artifact_id] = entry
        write = self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type=actor_type,
                device_id=device_id,
                provider=provider,
                expected_base=head,
                operations=(ArchiveIndexWrite(_encode_catalog(catalog)), TicketDelete(ticket_id)),
                summary=f"Recoverably delete Relay ticket {ticket_id}",
            )
        )
        return ArchiveResult(
            RetentionState.DELETED_TOMBSTONE,
            write,
            (ticket_id,),
            warnings=(
                "Routine Delete is recoverable and does not erase Git history. Rotate exposed secrets and use a separately reviewed coordinated purge if privacy erasure is required.",
            ),
        )

    def dependency_satisfied(self, dependency_id: str) -> bool:
        snapshot = self.store.snapshot()
        path = f".orchestrator/{dependency_id}.md"
        if path in snapshot.files:
            return _front_matter(snapshot.files[path]).get("status", "") == "done"
        for entry in self._catalog(snapshot.commit_id).values():
            if entry.get("ticket_id") == dependency_id:
                return entry.get("status") == "done"
        return False

    def storage_metrics(
        self,
        *,
        run_paths: Sequence[Path] = (),
        index_cache_paths: Sequence[Path] = (),
    ) -> StorageMetrics:
        materialized_files = [
            path
            for path in self.store.materialized_path.rglob("*")
            if path.is_file() and not path.is_symlink()
        ] if self.store.materialized_path.exists() else []
        materialized_bytes = sum(path.stat().st_size for path in materialized_files)
        reachable = 0
        seen: set[str] = set()
        head = self._head_required()
        for line in self.store._git("rev-list", "--objects", head).stdout.splitlines():
            oid = line.split(" ", 1)[0]
            if oid and oid not in seen:
                seen.add(oid)
                reachable += self.store._blob_size(oid)
        run_bytes = sum(_disk_usage(path) for path in run_paths)
        derived_bytes = sum(_disk_usage(path) for path in index_cache_paths)
        catalog = self._catalog(head)
        # Reachable artifact history is not reclaimable without a separately
        # reviewed history rewrite. Derived indexes/caches are the only safely
        # reclaimable bytes represented by this view.
        reclaimable = derived_bytes
        return StorageMetrics(
            materialized_worktree_bytes=materialized_bytes,
            materialized_file_count=len(materialized_files),
            reachable_git_object_bytes=reachable,
            run_database_log_bytes=run_bytes,
            derived_index_cache_bytes=derived_bytes,
            reclaimable_estimate_bytes=reclaimable,
        )

    def _retention_ticket(
        self,
        head: str,
        ticket_id: str,
        path: str,
        content: bytes,
        blob_id: str,
        files: Mapping[str, bytes],
        statuses: Mapping[str, str],
        leased: frozenset[str],
    ) -> RetentionTicket:
        front = _front_matter(content)
        artifact_id = front.get("artifact_id")
        if not artifact_id:
            raise ArtifactValidationError(f"ticket {ticket_id} has no immutable artifact_id")
        activity_values = []
        for field in ACTIVITY_FIELDS:
            if front.get(field):
                activity_values.append(_parse_instant(front[field]))
        if not activity_values:
            raise ArtifactValidationError(
                f"ticket {ticket_id} has no durable activity timestamp; migration must anchor activity_at"
            )
        activity_at = max(activity_values)
        status = front.get("status", "backlog")
        dependencies = tuple(sorted(_parse_list(front.get("depends_on", "[]"))))
        exemptions: list[str] = []
        if status in ACTIVE_STATUSES:
            exemptions.append(status)
        run_state = front.get("run_state", "")
        if run_state in ACTIVE_RUN_STATES:
            exemptions.append(run_state)
        if _parse_bool(front.get("blocked", "false")):
            exemptions.append("blocked")
        if _parse_bool(front.get("pinned", "false")):
            exemptions.append("pinned")
        if _parse_bool(front.get("pending_sync", "false")):
            exemptions.append("pending_sync")
        if _parse_bool(front.get("unpublished_conflict", "false")):
            exemptions.append("unpublished_conflict")
        unresolved = [dependency for dependency in dependencies if statuses.get(dependency) != "done"]
        if unresolved:
            exemptions.append("unresolved_dependency:" + ",".join(unresolved))
        if ticket_id in leased:
            exemptions.append("snapshot_lease")
        attachment_prefix = f".orchestrator/attachments/{ticket_id}/"
        attachment_paths = tuple(sorted(path for path in files if path.startswith(attachment_prefix)))
        return RetentionTicket(
            ticket_id=ticket_id,
            artifact_id=artifact_id,
            title=front.get("title", ticket_id),
            status=status,
            activity_at=activity_at,
            path=path,
            blob_id=blob_id,
            source_commit=head,
            dependencies=dependencies,
            attachment_paths=attachment_paths,
            exemptions=tuple(sorted(set(exemptions))),
        )

    def _ticket_status_map(self, files: Mapping[str, bytes]) -> dict[str, str]:
        statuses = {
            PurePosixPath(path).stem: _front_matter(content).get("status", "backlog")
            for path, content in files.items()
            if _is_ticket_path(path)
        }
        for entry in self._catalog_from_files(files).values():
            statuses.setdefault(str(entry.get("ticket_id")), str(entry.get("status", "")))
        return statuses

    def _catalog_entry(
        self,
        ticket: RetentionTicket,
        entries: Mapping[str, object],
        archived_at: datetime,
    ) -> dict[str, object]:
        attachments = []
        for path in ticket.attachment_paths:
            entry = entries.get(path)
            if not entry:
                raise ArtifactValidationError(f"referenced attachment is missing: {path}")
            content = self.store._cat_blob(entry.oid)
            self.store._validate_content_for_path(path, content)
            attachments.append(
                {
                    "path": path,
                    "blob": entry.oid,
                    "size": len(content),
                    "mime_type": _attachment_mime_for_filename(PurePosixPath(path).name),
                }
            )
        return {
            "schema_version": CATALOG_SCHEMA_VERSION,
            "artifact_id": ticket.artifact_id,
            "ticket_id": ticket.ticket_id,
            "title": ticket.title,
            "status": ticket.status,
            "activity_at": _format_instant(ticket.activity_at),
            "state": RetentionState.ARCHIVED.value,
            "ticket_path": ticket.path,
            "ticket_blob": ticket.blob_id,
            "ticket_size": self.store._blob_size(ticket.blob_id),
            "attachments": attachments,
            "source_commit": ticket.source_commit,
            "archived_at": _format_instant(archived_at),
            "restored_at": None,
            "deleted_at": None,
        }

    def _verify_active_ticket(self, ticket: RetentionTicket, entries: Mapping[str, object]) -> None:
        entry = entries.get(ticket.path)
        if not entry or entry.oid != ticket.blob_id:
            raise ArtifactConcurrentUpdate(f"ticket {ticket.ticket_id} changed before archival")
        content = self.store._cat_blob(ticket.blob_id)
        self.store._validate_content_for_path(ticket.path, content)
        for path in ticket.attachment_paths:
            attachment = entries.get(path)
            if not attachment:
                raise ArtifactValidationError(f"referenced attachment is missing: {path}")
            self.store._validate_content_for_path(path, self.store._cat_blob(attachment.oid))

    def _verify_archived_reachability(
        self,
        commit_id: str,
        tickets: Sequence[RetentionTicket],
        catalog: Mapping[str, Mapping[str, object]],
    ) -> None:
        for ticket in tickets:
            entry = catalog[ticket.artifact_id]
            if not self.store._git(
                "merge-base", "--is-ancestor", str(entry["source_commit"]), commit_id,
                allowed_statuses={0, 1, 128},
            ).returncode == 0:
                raise ArtifactValidationError("archive source commit is not reachable from archive head")
            self._verified_historical_blob(
                str(entry["source_commit"]), str(entry["ticket_path"]), str(entry["ticket_blob"])
            )
            for attachment in entry.get("attachments", []):
                self._verified_historical_blob(
                    str(entry["source_commit"]), str(attachment["path"]), str(attachment["blob"])
                )

    def _verified_historical_blob(self, commit_id: str, path: str, expected_blob: str) -> bytes:
        if not self._object_exists(commit_id) or not self._object_exists(expected_blob):
            raise _MissingHistoricalObject()
        result = self.store._git(
            "rev-parse", f"{commit_id}:{path}", allowed_statuses={0, 128}
        )
        if result.returncode != 0:
            raise ArtifactValidationError(f"archive catalog path is absent from source commit: {path}")
        actual = result.stdout.strip()
        if actual != expected_blob:
            raise ArtifactValidationError(
                f"archive catalog blob mismatch for {path}: expected {expected_blob}, found {actual}"
            )
        return self.store._cat_blob(expected_blob)

    def _object_exists(self, object_id: str) -> bool:
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", object_id):
            return False
        return self.store._git(
            "cat-file", "-e", object_id, allowed_statuses={0, 1, 128}
        ).returncode == 0

    def _rewind_unpublished_archive(self, write: ArtifactWriteResult) -> None:
        if not write.base_commit:
            raise ArtifactValidationError("archive commit has no verified parent for recovery")
        update = self.store._git(
            "update-ref",
            self.store.artifact_ref,
            write.base_commit,
            write.commit_id,
            allowed_statuses={0, 128},
        )
        if update.returncode != 0:
            raise ArtifactConcurrentUpdate(
                "archive publication failed and the local artifact ref advanced; explicit reconciliation required"
            )
        self.store._materialize(write.base_commit)

    def _catalog(self, head: str) -> dict[str, dict[str, object]]:
        snapshot = self.store.snapshot()
        if snapshot.commit_id != head:
            raise ArtifactConcurrentUpdate("artifact head changed while reading archive catalog")
        return self._catalog_from_files(snapshot.files)

    def _catalog_from_files(self, files: Mapping[str, bytes]) -> dict[str, dict[str, object]]:
        content = files.get(".orchestrator/archive-index.jsonl", b"")
        result: dict[str, dict[str, object]] = {}
        for line_number, line in enumerate(content.decode("utf-8").splitlines(), 1):
            if not line.strip():
                continue
            value = json.loads(line)
            if value.get("schema_version") != CATALOG_SCHEMA_VERSION:
                raise ArtifactValidationError(
                    f"archive catalog line {line_number} has unsupported schema"
                )
            artifact_id = value.get("artifact_id")
            if not isinstance(artifact_id, str) or artifact_id in result:
                raise ArtifactValidationError("archive catalog has invalid or duplicate artifact identity")
            result[artifact_id] = value
        return result

    def _head_required(self) -> str:
        head = self.store._head()
        if not head:
            raise ArtifactValidationError("artifact store is not initialized")
        return head

    def _require_enabled(self) -> None:
        if not self.enabled:
            raise ArtifactValidationError("retention is preview-only until explicitly enabled")

    def _inject(self, stage: str) -> None:
        if self.failure_injector:
            self.failure_injector(stage)


class _MissingHistoricalObject(Exception):
    pass


def _is_ticket_path(path: str) -> bool:
    return (
        path.startswith(".orchestrator/")
        and path.endswith(".md")
        and "/" not in path.removeprefix(".orchestrator/")
    )


def _front_matter(content: bytes) -> dict[str, str]:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ArtifactValidationError("ticket front matter is not UTF-8") from error
    if not lines or lines[0].strip() != "---":
        raise ArtifactValidationError("ticket has no front matter")
    result: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return result
        key, separator, value = line.partition(":")
        if separator:
            result[key.strip()] = value.strip().strip("\"'")
    raise ArtifactValidationError("ticket front matter is not closed")


def _set_front_matter_value(content: bytes, key: str, value: str) -> bytes:
    lines = content.decode("utf-8").splitlines()
    closing = None
    for index, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            closing = index
            break
    if closing is None:
        raise ArtifactValidationError("ticket front matter is not closed")
    for index in range(1, closing):
        existing, separator, _ = lines[index].partition(":")
        if separator and existing.strip() == key:
            lines[index] = f"{key}: {value}"
            break
    else:
        lines.insert(closing, f"{key}: {value}")
    return ("\n".join(lines).rstrip("\n") + "\n").encode("utf-8")


def _parse_list(value: str) -> tuple[str, ...]:
    stripped = value.strip()
    if not stripped or stripped == "[]":
        return ()
    if stripped.startswith("[") and stripped.endswith("]"):
        stripped = stripped[1:-1]
    values = []
    for item in stripped.split(","):
        normalized = item.strip().strip("\"'")
        if normalized:
            values.append(normalized)
    return tuple(values)


def _parse_bool(value: str) -> bool:
    return value.strip().lower() in {"true", "yes", "1"}


def _parse_instant(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ArtifactValidationError(f"invalid RFC 3339 activity instant: {value!r}") from error
    if parsed.tzinfo is None:
        raise ArtifactValidationError(f"activity instant has no UTC offset: {value!r}")
    return parsed.astimezone(UTC)


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise ArtifactValidationError("retention evaluation instant must be timezone-aware")
    return value.astimezone(UTC)


def _format_instant(value: datetime) -> str:
    return _utc(value).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _encode_catalog(catalog: Mapping[str, Mapping[str, object]]) -> bytes:
    return (
        "".join(_canonical_json(catalog[key]) + "\n" for key in sorted(catalog))
    ).encode("utf-8")


def _card(entry: Mapping[str, object]) -> HistoricalCard:
    attachments = entry.get("attachments", [])
    return HistoricalCard(
        artifact_id=str(entry["artifact_id"]),
        ticket_id=str(entry["ticket_id"]),
        title=str(entry["title"]),
        status=str(entry["status"]),
        activity_at=_parse_instant(str(entry["activity_at"])),
        state=RetentionState(str(entry["state"])),
        attachment_count=len(attachments),
        attachment_bytes=sum(int(item.get("size", 0)) for item in attachments),
    )


def _lease_json(lease: SnapshotLease) -> dict[str, object]:
    return {
        "lease_id": lease.lease_id,
        "project_id": lease.project_id,
        "ticket_id": lease.ticket_id,
        "artifact_id": lease.artifact_id,
        "artifact_head": lease.artifact_head,
        "run_id": lease.run_id,
        "role": lease.role,
        "provider": lease.provider,
        "attachment_paths": list(lease.attachment_paths),
        "created_at": _format_instant(lease.created_at),
        "heartbeat_at": _format_instant(lease.heartbeat_at),
        "state": lease.state,
        "released_at": _format_instant(lease.released_at) if lease.released_at else None,
        "terminal_reason": lease.terminal_reason,
    }


def _validate_safe_id(value: str, label: str) -> str:
    if not _SAFE_ID_RE.fullmatch(value):
        raise ArtifactValidationError(f"invalid {label}: {value!r}")
    return value


def _prior_result(store: ArtifactStore, event_id: str, commit_id: str) -> ArtifactWriteResult:
    return ArtifactWriteResult(
        event_id=event_id,
        commit_id=commit_id,
        tree_id=store._tree_id(commit_id),
        base_commit=store._first_parent(commit_id),
        idempotent=True,
    )


def _disk_usage(path: Path) -> int:
    if not path.exists() or path.is_symlink():
        return 0
    if path.is_file():
        return path.stat().st_size
    total = 0
    for child in path.rglob("*"):
        if child.is_file() and not child.is_symlink():
            total += child.stat().st_size
    return total


__all__ = [
    "ACTIVITY_FIELDS",
    "ArchiveResult",
    "ArtifactRetentionManager",
    "HistoricalCard",
    "HistoricalDetail",
    "HistoryAvailability",
    "RetentionPlan",
    "RetentionState",
    "RetentionTicket",
    "SnapshotLease",
    "SnapshotLeaseStore",
    "StorageMetrics",
]
