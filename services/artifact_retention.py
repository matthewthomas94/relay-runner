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
import hashlib
import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Mapping, Sequence

try:
    from services.artifact_catalog import (
        CatalogSemanticError,
        validate_catalog_ticket_metadata,
    )
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
    from services.artifact_sync import ArtifactRemoteProof
except ModuleNotFoundError:  # Direct services/*.py execution.
    from artifact_catalog import (  # type: ignore[no-redef]
        CatalogSemanticError,
        validate_catalog_ticket_metadata,
    )
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
    from artifact_sync import ArtifactRemoteProof  # type: ignore[no-redef]


UTC = timezone.utc
RETENTION_POLICY = "terminal-count-v1"
RETENTION_PLAN_SCHEMA_VERSION = 1
TERMINAL_RETENTION_LIMIT = 25
CATALOG_SCHEMA_VERSION = 1
LEASE_SCHEMA_VERSION = 1
RETENTION_TRANSACTION_SCHEMA_VERSION = 1

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

ACTIVE_RUN_STATES = {"claimed", "running", "awaiting_review", "reviewing", "merge_conflict"}
TERMINAL_STATUSES = {"done", "canceled", "cancelled"}

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
    materialized: bool = True


@dataclasses.dataclass(frozen=True)
class RetentionPlan:
    schema_version: int
    policy: str
    limit: int
    project_id: str
    artifact_head: str
    evaluated_at: datetime
    candidates: tuple[RetentionTicket, ...]
    retained_terminal: tuple[RetentionTicket, ...]
    nonterminal: tuple[RetentionTicket, ...]
    materialize: tuple[RetentionTicket, ...]
    exempt: tuple[RetentionTicket, ...]
    ranked_terminal: tuple[RetentionTicket, ...]

    @property
    def candidate_ids(self) -> tuple[str, ...]:
        return tuple(ticket.ticket_id for ticket in self.candidates)

    @property
    def retained_terminal_ids(self) -> tuple[str, ...]:
        return tuple(ticket.ticket_id for ticket in self.retained_terminal)

    @property
    def nonterminal_ids(self) -> tuple[str, ...]:
        return tuple(ticket.ticket_id for ticket in self.nonterminal)

    @property
    def materialize_ids(self) -> tuple[str, ...]:
        return tuple(ticket.ticket_id for ticket in self.materialize)

    @property
    def temporary_overage(self) -> Mapping[str, tuple[str, ...]]:
        return {ticket.ticket_id: ticket.exemptions for ticket in self.exempt}


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


class DependencyHistoryUnavailable(ArtifactValidationError):
    """Preserve a verified history failure across dependency evaluation."""

    def __init__(self, dependency_id: str, detail: HistoricalDetail):
        self.dependency_id = dependency_id
        self.detail = detail
        super().__init__(
            detail.recovery
            or f"archived dependency {dependency_id} is {detail.availability.value}"
        )


@dataclasses.dataclass(frozen=True)
class HistoricalAttachment:
    artifact_id: str
    ticket_id: str
    filename: str
    mime_type: str
    content: bytes
    blob_id: str


@dataclasses.dataclass(frozen=True)
class StorageMetrics:
    materialized_worktree_bytes: int
    materialized_file_count: int
    materialized_ticket_bytes: int
    materialized_ticket_count: int
    materialized_attachment_bytes: int
    materialized_attachment_count: int
    retained_terminal_count: int
    nonterminal_count: int
    temporary_overage_count: int
    remotely_backed_history_count: int
    reachable_git_object_bytes: int
    database_bytes: int
    run_log_bytes: int
    index_bytes: int
    cache_bytes: int
    run_database_log_bytes: int
    derived_index_cache_bytes: int
    reclaimable_estimate_bytes: int


@dataclasses.dataclass(frozen=True)
class ArchiveRemoteConfirmation:
    """User-approved exposure of one exact, existing GitHub remote."""

    service: str
    remote_name: str
    remote_url_sha256: str
    push_url_sha256: str
    exposure_confirmed: bool


def _configured_remote_urls(store: ArtifactStore, remote_name: str) -> tuple[str, str]:
    fetch = store._git(
        "remote", "get-url", remote_name, allowed_statuses={0, 2, 128}
    )
    push = store._git(
        "remote", "get-url", "--push", "--all", remote_name,
        allowed_statuses={0, 2, 128},
    )
    push_urls = push.stdout.splitlines()
    if fetch.returncode != 0 or not fetch.stdout.strip() or push.returncode != 0:
        raise ArtifactValidationError(
            f"selected existing remote {remote_name!r} is unavailable; Relay will not create it"
        )
    if len(push_urls) != 1 or not push_urls[0]:
        raise ArtifactValidationError(
            "terminal cleanup requires exactly one explicitly confirmed push destination"
        )
    return fetch.stdout.strip(), push_urls[0]


def confirm_github_remote(
    store: ArtifactStore,
    remote_name: str,
    *,
    exposure_confirmed: bool,
) -> ArchiveRemoteConfirmation:
    """Bind explicit exposure consent to the selected remote's current URL."""
    if not exposure_confirmed:
        raise ArtifactValidationError(
            "GitHub archival requires explicit confirmation that ticket content will be exposed"
        )
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", remote_name):
        raise ArtifactValidationError(f"invalid configured remote name: {remote_name!r}")
    remote_url, push_url = _configured_remote_urls(store, remote_name)
    if not _is_github_url(remote_url) or not _is_github_url(push_url):
        raise ArtifactValidationError(
            "terminal cleanup requires an explicitly confirmed github.com remote for both fetch and push"
        )
    return ArchiveRemoteConfirmation(
        service="github",
        remote_name=remote_name,
        remote_url_sha256=hashlib.sha256(remote_url.encode("utf-8")).hexdigest(),
        push_url_sha256=hashlib.sha256(push_url.encode("utf-8")).hexdigest(),
        exposure_confirmed=True,
    )


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
        remote_confirmation: ArchiveRemoteConfirmation | None = None,
        synchronizer: object | None = None,
        enabled: bool = False,
        now: Callable[[], datetime] | None = None,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        if remote_mode not in {"local_only", "enabled", "paused"}:
            raise ArtifactValidationError(f"invalid retention remote mode: {remote_mode!r}")
        self.store = store
        self.lease_store = lease_store or SnapshotLeaseStore(store)
        self.remote_mode = remote_mode
        self.remote_confirmation = remote_confirmation
        self.synchronizer = synchronizer
        self.enabled = enabled
        self.now = now or (lambda: datetime.now(UTC))
        self.failure_injector = failure_injector
        self.transaction_path = store.project_state / "retention-transaction.json"

    def preview(self, *, evaluated_at: datetime | None = None) -> RetentionPlan:
        instant = _utc(evaluated_at or self.now())
        snapshot = self.store.snapshot()
        return self._preview_head(
            snapshot.commit_id,
            snapshot.files,
            evaluated_at=instant,
            leased=self.lease_store.active_ticket_ids(),
            include_transaction=True,
        )

    def _preview_head(
        self,
        head: str,
        files: Mapping[str, bytes],
        *,
        evaluated_at: datetime,
        leased: frozenset[str],
        include_transaction: bool,
    ) -> RetentionPlan:
        entries = self.store._tree_entries(head)
        transaction = self._read_transaction() if include_transaction else None
        transaction_ids = set(transaction.get("ticket_ids", [])) if transaction else set()
        canonical: dict[str, RetentionTicket] = {}
        for path in sorted(files):
            if not _is_ticket_path(path):
                continue
            ticket_id = PurePosixPath(path).stem
            content = files[path]
            ticket = self._retention_ticket(
                head,
                ticket_id,
                path,
                content,
                entries[path].oid,
                files,
                leased,
            )
            if ticket_id in transaction_ids:
                reasons = set(ticket.exemptions)
                reasons.add("in_flight_transaction")
                if transaction and transaction.get("last_error"):
                    reasons.add("retryable_verification_failure")
                ticket = dataclasses.replace(ticket, exemptions=tuple(sorted(reasons)))
            if ticket.artifact_id in canonical:
                raise ArtifactValidationError(
                    f"duplicate immutable artifact_id in materialized tickets: {ticket.artifact_id}"
                )
            canonical[ticket.artifact_id] = ticket

        for artifact_id, entry in self._catalog_from_files(files).items():
            if artifact_id in canonical or entry.get("state") == RetentionState.DELETED_TOMBSTONE.value:
                continue
            ticket = self._catalog_ticket(entry)
            ticket_id = str(entry.get("ticket_id") or artifact_id)
            try:
                self._verified_catalog_markdown(head, entry)
            except _MissingHistoricalObject as error:
                raise ArtifactValidationError(
                    f"archive catalog integrity blocker for {ticket_id}: "
                    "required historical objects are unavailable"
                ) from error
            except (ArtifactValidationError, CatalogSemanticError) as error:
                raise ArtifactValidationError(
                    f"archive catalog integrity blocker for {ticket_id}: {error}"
                ) from error
            if any(existing.ticket_id == ticket.ticket_id for existing in canonical.values()):
                raise ArtifactValidationError(
                    f"ticket {ticket.ticket_id} has conflicting materialized and catalog identities"
                )
            canonical[artifact_id] = ticket

        nonterminal = [ticket for ticket in canonical.values() if not _is_terminal(ticket.status)]
        terminal = [ticket for ticket in canonical.values() if _is_terminal(ticket.status)]
        # Python's sort is stable: sorting the immutable identity first and
        # canonical activity second gives descending activity with ascending
        # artifact_id ties, independent of display ID or provider.
        terminal.sort(key=lambda ticket: ticket.artifact_id)
        terminal.sort(key=lambda ticket: ticket.activity_at, reverse=True)
        retained_terminal = terminal[:TERMINAL_RETENTION_LIMIT]
        retained_ids = {ticket.artifact_id for ticket in retained_terminal}
        older_materialized = [
            ticket
            for ticket in terminal
            if ticket.materialized and ticket.artifact_id not in retained_ids
        ]
        exempt = [ticket for ticket in older_materialized if ticket.exemptions]
        candidates = [ticket for ticket in older_materialized if not ticket.exemptions]
        materialize = [
            ticket
            for ticket in (*nonterminal, *retained_terminal)
            if not ticket.materialized
        ]
        return RetentionPlan(
            schema_version=RETENTION_PLAN_SCHEMA_VERSION,
            policy=RETENTION_POLICY,
            limit=TERMINAL_RETENTION_LIMIT,
            project_id=self.store.project_id,
            artifact_head=head,
            evaluated_at=evaluated_at,
            candidates=tuple(candidates),
            retained_terminal=tuple(retained_terminal),
            nonterminal=tuple(sorted(nonterminal, key=lambda ticket: ticket.ticket_id)),
            materialize=tuple(sorted(materialize, key=lambda ticket: ticket.ticket_id)),
            exempt=tuple(exempt),
            ranked_terminal=tuple(terminal),
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
        synchronizer = synchronizer or self.synchronizer
        existing_transaction = self._read_transaction()
        if existing_transaction:
            if existing_transaction.get("event_id") != event_id:
                raise ArtifactConcurrentUpdate(
                    "another retention publication transaction must be recovered first"
                )
            self._validate_remote_transaction(
                synchronizer,
                confirmation=self._transaction_confirmation(existing_transaction),
            )
            with self.lease_store._locked(), self.store._writer_lock():
                return self._resume_archive(existing_transaction, synchronizer)
        prior = self.store._find_event(event_id)
        if prior:
            return ArchiveResult(
                RetentionState.ARCHIVED,
                _prior_result(self.store, event_id, prior[0]),
                plan.candidate_ids,
            )
        if not plan.candidates:
            return ArchiveResult(RetentionState.ARCHIVED, None, ())
        confirmation = self._validate_remote_transaction(synchronizer)
        with self.lease_store._locked(), self.store._writer_lock():
            current = self.store._head()
            if current != plan.artifact_head:
                raise ArtifactConcurrentUpdate("artifact head changed since retention preview")
            refreshed = self.preview(evaluated_at=plan.evaluated_at)
            if _plan_identity(refreshed) != _plan_identity(plan):
                raise ArtifactConcurrentUpdate("retention eligibility changed since preview")
            preflight = synchronizer.sync_confirmed(
                expected_remote_url_sha256=confirmation.remote_url_sha256,
                expected_push_url_sha256=confirmation.push_url_sha256,
            )
            if getattr(getattr(preflight, "state", None), "value", None) != "clean":
                return ArchiveResult(
                    RetentionState.ARCHIVE_PENDING_SYNC,
                    None,
                    refreshed.candidate_ids,
                    recovery=(
                        getattr(preflight, "recovery", None)
                        or "Reconcile the selected GitHub artifact ref and retry."
                    ),
                )
            if (
                getattr(preflight, "local_head", None) != current
                or getattr(preflight, "remote_head", None) != current
                or self.store._head() != current
            ):
                return ArchiveResult(
                    RetentionState.ARCHIVE_PENDING_SYNC,
                    None,
                    refreshed.candidate_ids,
                    recovery=(
                        "Artifact synchronization changed the canonical head; preview the "
                        "terminal candidates again before deletion."
                    ),
                )
            entries = self.store._tree_entries(current)
            catalog = self._catalog(current)
            for ticket in refreshed.candidates:
                self._verify_active_ticket(ticket, entries)
                catalog[ticket.artifact_id] = self._catalog_entry(ticket, entries, plan.evaluated_at)
            operations = [ArchiveIndexWrite(_encode_catalog(catalog))]
            operations.extend(TicketDelete(ticket.ticket_id) for ticket in refreshed.candidates)
            self._inject("before_archive_commit")
            write = self.store.prepare_mutation(
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
            candidate_entries = self.store._tree_entries(write.commit_id)
            proofs = self._archive_proofs(
                write.commit_id,
                refreshed.candidates,
                entries,
                candidate_entries,
            )
            scratch_ref = self._scratch_ref(event_id)
            transaction = {
                "schema_version": RETENTION_TRANSACTION_SCHEMA_VERSION,
                "project_id": self.store.project_id,
                "event_id": event_id,
                "device_id": device_id,
                "actor_type": actor_type,
                "provider": provider,
                "phase": "prepared",
                "base_head": current,
                "candidate_head": write.commit_id,
                "scratch_ref": scratch_ref,
                "ticket_ids": list(refreshed.candidate_ids),
                "proofs": [dataclasses.asdict(proof) for proof in proofs],
                "remote_confirmation": dataclasses.asdict(confirmation),
                "last_error": None,
            }
            self._publish_transaction_scratch(transaction)
            self._inject("after_archive_scratch")
            self._write_transaction(transaction)
            self._inject("after_archive_prepare")
            return self._resume_archive(transaction, synchronizer)

    def recover_archive(self, *, synchronizer: object | None = None) -> ArchiveResult | None:
        """Resume an interrupted publication transaction without a stale plan."""
        self._require_enabled()
        transaction = self._read_transaction()
        if not transaction:
            return None
        synchronizer = synchronizer or self.synchronizer
        self._validate_remote_transaction(
            synchronizer,
            confirmation=self._transaction_confirmation(transaction),
        )
        with self.lease_store._locked(), self.store._writer_lock():
            return self._resume_archive(transaction, synchronizer)

    def recover_from_remote(self, *, synchronizer: object | None = None) -> object:
        """Restore a compliant projection from only the confirmed artifact ref."""
        self._require_enabled()
        synchronizer = synchronizer or self.synchronizer
        confirmation = self._validate_remote_transaction(synchronizer)

        def validate(head: str) -> None:
            self.store._validate_artifact_head(head)
            entries = self.store._tree_entries(head)
            files = {path: self.store._cat_blob(entry.oid) for path, entry in entries.items()}
            plan = self._preview_head(
                head,
                files,
                evaluated_at=_utc(self.now()),
                leased=frozenset(),
                include_transaction=False,
            )
            materialized_ids = {
                PurePosixPath(path).stem for path in files if _is_ticket_path(path)
            }
            expected_ids = set(plan.nonterminal_ids) | set(plan.retained_terminal_ids)
            if plan.candidates or plan.materialize or materialized_ids != expected_ids:
                raise ArtifactValidationError(
                    "remote artifact ref does not materialize every nonterminal ticket and the newest 25 terminal tickets"
                )

        return synchronizer.recover_exact_ref(
            expected_remote_url_sha256=confirmation.remote_url_sha256,
            validate_head=validate,
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
        artifact_head = self._head_required()
        catalog = self._catalog(artifact_head)
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
            ticket_bytes = self._verified_catalog_markdown(artifact_head, entry)
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
        except (ArtifactValidationError, CatalogSemanticError) as error:
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

    def historical_attachment(
        self,
        artifact_id: str,
        filename: str,
        *,
        online: bool = False,
        deepen: Callable[[str], None] | None = None,
    ) -> HistoricalAttachment:
        """Return one verified archive attachment without materializing its ticket."""
        _validate_safe_id(artifact_id, "artifact ID")
        if PurePosixPath(filename).name != filename:
            raise ArtifactValidationError(f"invalid attachment filename: {filename!r}")
        # Reuse the store's ownership/type policy instead of accepting an
        # archive-catalog MIME declaration on trust.
        mime_type = _attachment_mime_for_filename(filename)
        detail = self.historical_detail(artifact_id, online=online, deepen=deepen)
        if detail.availability != HistoryAvailability.AVAILABLE or detail.card is None:
            raise ArtifactValidationError(detail.recovery or "historical ticket is unavailable")
        expected_path = f".orchestrator/attachments/{detail.card.ticket_id}/{filename}"
        matches = [item for item in detail.attachments if item.get("path") == expected_path]
        if len(matches) != 1:
            raise ArtifactValidationError(f"historical attachment {filename!r} was not found")
        item = matches[0]
        if item.get("mime_type") != mime_type:
            raise ArtifactValidationError("historical attachment MIME metadata is inconsistent")
        content = self._verified_historical_blob(
            str(self._catalog(self._head_required())[artifact_id]["source_commit"]),
            expected_path,
            str(item.get("blob", "")),
        )
        self.store._validate_content_for_path(expected_path, content)
        if int(item.get("size", -1)) != len(content):
            raise ArtifactValidationError("historical attachment size metadata is inconsistent")
        return HistoricalAttachment(
            artifact_id=artifact_id,
            ticket_id=detail.card.ticket_id,
            filename=filename,
            mime_type=mime_type,
            content=content,
            blob_id=str(item["blob"]),
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
            ticket_id = self._materialized_ticket_id(artifact_id)
            return ArchiveResult(
                RetentionState.RESTORE_PENDING_SYNC
                if self.remote_mode == "enabled"
                else RetentionState.MATERIALIZED_RECENT,
                _prior_result(self.store, event_id, prior[0]),
                (ticket_id,) if ticket_id else (),
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

    def reopen(
        self,
        artifact_id: str,
        *,
        event_id: str,
        device_id: str,
        actor_type: str = "user",
        provider: str | None = None,
        reopened_at: datetime | None = None,
        online: bool = False,
        deepen: Callable[[str], None] | None = None,
    ) -> ArchiveResult:
        """Make archived terminal work nonterminal and therefore uncapped."""
        self._require_enabled()
        prior = self.store._find_event(event_id)
        if prior:
            ticket_id = self._materialized_ticket_id(artifact_id)
            return ArchiveResult(
                RetentionState.RESTORE_PENDING_SYNC
                if self.remote_mode == "enabled"
                else RetentionState.MATERIALIZED_EXEMPT,
                _prior_result(self.store, event_id, prior[0]),
                (ticket_id,) if ticket_id else (),
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
        instant = _utc(reopened_at or self.now())
        ticket_id = str(entry["ticket_id"])
        markdown = detail.ticket_bytes
        for key, value in (
            ("status", "backlog"),
            ("canceled", "false"),
            ("run_id", "null"),
            ("run_state", "none"),
            ("reopened_at", _format_instant(instant)),
            ("activity_at", _format_instant(instant)),
        ):
            markdown = _set_front_matter_value(markdown, key, value)
        operations: list[object] = [TicketWrite(ticket_id, artifact_id, markdown)]
        source_commit = str(entry["source_commit"])
        for attachment in entry.get("attachments", []):
            path = str(attachment["path"])
            operations.append(AttachmentWrite(
                ticket_id,
                PurePosixPath(path).name,
                str(attachment["mime_type"]),
                self._verified_historical_blob(source_commit, path, str(attachment["blob"])),
            ))
        updated_entry = dict(entry)
        updated_entry.update({
            "state": RetentionState.MATERIALIZED_EXEMPT.value,
            "status": "backlog",
            "activity_at": _format_instant(instant),
            "restored_at": _format_instant(instant),
        })
        catalog[artifact_id] = updated_entry
        operations.append(ArchiveIndexWrite(_encode_catalog(catalog)))
        write = self.store.mutate(ArtifactMutation(
            event_id=event_id,
            actor_type=actor_type,
            device_id=device_id,
            provider=provider,
            expected_base=head,
            operations=tuple(operations),
            summary=f"Reopen Relay ticket {ticket_id}",
        ))
        return ArchiveResult(
            RetentionState.RESTORE_PENDING_SYNC
            if self.remote_mode == "enabled"
            else RetentionState.MATERIALIZED_EXEMPT,
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
        ticket = self._retention_ticket(
            head,
            ticket_id,
            path,
            snapshot.files[path],
            entries[path].oid,
            snapshot.files,
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
            return _canonical_status(_front_matter(snapshot.files[path])) == "done"
        for entry in self._catalog(snapshot.commit_id).values():
            if entry.get("ticket_id") == dependency_id:
                if entry.get("status") != "done":
                    return False
                detail = self.historical_detail(str(entry.get("artifact_id", "")))
                if detail.availability != HistoryAvailability.AVAILABLE:
                    raise DependencyHistoryUnavailable(dependency_id, detail)
                return True
        return False

    def dependency_execution_mode(self, dependency_id: str) -> str | None:
        """Return a dependency's verified execution mode without restoring it."""
        snapshot = self.store.snapshot()
        path = f".orchestrator/{dependency_id}.md"
        if path in snapshot.files:
            return _front_matter(snapshot.files[path]).get("execution_mode", "implementation")
        for entry in self._catalog(snapshot.commit_id).values():
            if entry.get("ticket_id") != dependency_id:
                continue
            detail = self.historical_detail(str(entry.get("artifact_id", "")))
            if detail.availability != HistoryAvailability.AVAILABLE or detail.ticket_bytes is None:
                raise DependencyHistoryUnavailable(dependency_id, detail)
            return _front_matter(detail.ticket_bytes).get("execution_mode", "implementation")
        return None

    def transaction_status(self) -> Mapping[str, object]:
        transaction = self._read_transaction()
        if not transaction:
            return {"state": "idle", "retry_available": False}
        return {
            "state": str(transaction.get("phase") or "pending"),
            "event_id": transaction.get("event_id"),
            "ticket_ids": list(transaction.get("ticket_ids") or []),
            "last_error": transaction.get("last_error"),
            "retry_available": True,
        }

    def _materialized_ticket_id(self, artifact_id: str) -> str | None:
        for path, content in self.store.snapshot().files.items():
            if not _is_ticket_path(path):
                continue
            if _front_matter(content).get("artifact_id") == artifact_id:
                return PurePosixPath(path).stem
        return None

    def storage_metrics(
        self,
        *,
        run_paths: Sequence[Path] = (),
        index_cache_paths: Sequence[Path] = (),
        database_paths: Sequence[Path] = (),
        run_log_paths: Sequence[Path] = (),
        index_paths: Sequence[Path] = (),
        cache_paths: Sequence[Path] = (),
    ) -> StorageMetrics:
        materialized_files = [
            path
            for path in self.store.materialized_path.rglob("*")
            if path.is_file() and not path.is_symlink()
        ] if self.store.materialized_path.exists() else []
        materialized_bytes = sum(path.stat().st_size for path in materialized_files)
        ticket_files = []
        for path in materialized_files:
            if path.parent != self.store.materialized_path or path.suffix != ".md":
                continue
            try:
                if _front_matter(path.read_bytes()).get("artifact_id"):
                    ticket_files.append(path)
            except (OSError, ArtifactValidationError):
                continue
        attachment_root = self.store.materialized_path / "attachments"
        attachment_files = [
            path for path in materialized_files
            if attachment_root in path.parents
        ]
        reachable = 0
        seen: set[str] = set()
        head = self._head_required()
        for line in self.store._git("rev-list", "--objects", head).stdout.splitlines():
            oid = line.split(" ", 1)[0]
            if oid and oid not in seen:
                seen.add(oid)
                reachable += self.store._blob_size(oid)
        database_bytes = sum(_disk_usage(path) for path in database_paths)
        run_log_bytes = sum(_disk_usage(path) for path in run_log_paths)
        index_bytes = sum(_disk_usage(path) for path in index_paths)
        cache_bytes = sum(_disk_usage(path) for path in cache_paths)
        run_bytes = sum(_disk_usage(path) for path in run_paths) + database_bytes + run_log_bytes
        derived_bytes = (
            sum(_disk_usage(path) for path in index_cache_paths) + index_bytes + cache_bytes
        )
        catalog = self._catalog(head)
        plan = self.preview()
        # Reachable artifact history is not reclaimable without a separately
        # reviewed history rewrite. Derived indexes/caches are the only safely
        # reclaimable bytes represented by this view.
        reclaimable = derived_bytes
        return StorageMetrics(
            materialized_worktree_bytes=materialized_bytes,
            materialized_file_count=len(materialized_files),
            materialized_ticket_bytes=sum(path.stat().st_size for path in ticket_files),
            materialized_ticket_count=len(ticket_files),
            materialized_attachment_bytes=sum(path.stat().st_size for path in attachment_files),
            materialized_attachment_count=len(attachment_files),
            retained_terminal_count=len(plan.retained_terminal),
            nonterminal_count=len(plan.nonterminal),
            temporary_overage_count=len(plan.exempt),
            remotely_backed_history_count=sum(
                1 for entry in catalog.values()
                if entry.get("state") == RetentionState.ARCHIVED.value
            ),
            reachable_git_object_bytes=reachable,
            database_bytes=database_bytes,
            run_log_bytes=run_log_bytes,
            index_bytes=index_bytes,
            cache_bytes=cache_bytes,
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
        status = _canonical_status(front)
        dependencies = tuple(sorted(_parse_list(front.get("depends_on", "[]"))))
        exemptions: list[str] = []
        run_state = front.get("run_state", "")
        if run_state in ACTIVE_RUN_STATES:
            exemptions.append(f"live_lease:{run_state}")
        if (
            _parse_bool(front.get("pending_sync", "false"))
            or _parse_bool(front.get("unpublished_conflict", "false"))
        ):
            exemptions.append("unpublished_content")
        if front.get("retention_transaction", "").strip() not in {"", "none", "complete"}:
            exemptions.append("in_flight_transaction")
        if _parse_bool(front.get("retryable_verification_failure", "false")):
            exemptions.append("retryable_verification_failure")
        if ticket_id in leased:
            exemptions.append("live_lease:snapshot")
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

    def _catalog_ticket(self, entry: Mapping[str, object]) -> RetentionTicket:
        required = (
            "artifact_id",
            "ticket_id",
            "status",
            "activity_at",
            "ticket_path",
            "ticket_blob",
            "source_commit",
        )
        missing = [key for key in required if not str(entry.get(key, "")).strip()]
        if missing:
            raise ArtifactValidationError(
                "archive catalog retention metadata is incomplete: " + ", ".join(missing)
            )
        attachments = entry.get("attachments", [])
        if not isinstance(attachments, list) or any(
            not isinstance(item, Mapping) for item in attachments
        ):
            raise ArtifactValidationError("archive catalog attachments must be a list")
        dependencies = entry.get("dependencies", [])
        if not isinstance(dependencies, list):
            raise ArtifactValidationError("archive catalog dependencies must be a list")
        status = str(entry["status"])
        if not _is_terminal(status):
            # Age-policy catalogs could record a canceled card's lane status
            # (for example, backlog) without its separate canceled flag. Read
            # the verified historical blob to migrate that ambiguity without
            # restoring the Markdown projection.
            try:
                historical = self._verified_historical_blob(
                    str(entry["source_commit"]),
                    str(entry["ticket_path"]),
                    str(entry["ticket_blob"]),
                )
            except _MissingHistoricalObject as error:
                raise ArtifactValidationError(
                    f"archive catalog status for {entry['ticket_id']} is ambiguous and its "
                    "historical object is unavailable"
                ) from error
            status = _canonical_status(_front_matter(historical))
        return RetentionTicket(
            ticket_id=str(entry["ticket_id"]),
            artifact_id=str(entry["artifact_id"]),
            title=str(entry.get("title") or entry["ticket_id"]),
            status=status,
            activity_at=_parse_instant(str(entry["activity_at"])),
            path=str(entry["ticket_path"]),
            blob_id=str(entry["ticket_blob"]),
            source_commit=str(entry["source_commit"]),
            dependencies=tuple(sorted(str(value) for value in dependencies)),
            attachment_paths=tuple(sorted(str(item.get("path")) for item in attachments)),
            exemptions=(),
            materialized=False,
        )

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
            "dependencies": list(ticket.dependencies),
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

    def _verified_catalog_markdown(
        self,
        artifact_head: str,
        entry: Mapping[str, object],
    ) -> bytes:
        source_commit = str(entry.get("source_commit") or "")
        if not self._object_exists(source_commit):
            raise _MissingHistoricalObject()
        if self.store._git(
            "merge-base", "--is-ancestor", source_commit, artifact_head,
            allowed_statuses={0, 1, 128},
        ).returncode != 0:
            raise ArtifactValidationError(
                "archive catalog source commit is not reachable from the current artifact head"
            )
        content = self._verified_historical_blob(
            source_commit,
            str(entry.get("ticket_path") or ""),
            str(entry.get("ticket_blob") or ""),
        )
        validate_catalog_ticket_metadata(
            entry,
            content,
            activity_fields=ACTIVITY_FIELDS,
        )
        return content

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

    def _resume_archive(
        self,
        transaction: Mapping[str, object],
        synchronizer: object,
    ) -> ArchiveResult:
        transaction = dict(transaction)
        self._validate_transaction(transaction)
        base_head = str(transaction["base_head"])
        candidate_head = str(transaction["candidate_head"])
        ticket_ids = tuple(str(value) for value in transaction["ticket_ids"])
        phase = str(transaction["phase"])
        proofs = tuple(
            ArtifactRemoteProof(
                source_commit=str(value["source_commit"]),
                path=str(value["path"]),
                blob_id=str(value["blob_id"]),
                sha256=str(value["sha256"]),
            )
            for value in transaction["proofs"]
        )
        if not self._object_exists(candidate_head):
            raise ArtifactValidationError(
                "prepared retention commit is unavailable; active files were retained"
            )
        if self.store._first_parent(candidate_head) != base_head:
            raise ArtifactValidationError("prepared retention commit no longer matches its base")
        self._ensure_transaction_scratch(transaction)

        current = self.store._head()
        if phase == "prepared":
            if current != base_head:
                raise ArtifactConcurrentUpdate(
                    "artifact authority changed before remote archive verification"
                )
            confirmation = self._transaction_confirmation(transaction)
            self._validate_remote_transaction(
                synchronizer,
                confirmation=confirmation,
            )
            result = synchronizer.publish_prepared(
                candidate_head,
                expected_remote_head=base_head,
                proofs=proofs,
                expected_remote_url_sha256=confirmation.remote_url_sha256,
                expected_push_url_sha256=confirmation.push_url_sha256,
            )
            state_value = getattr(getattr(result, "state", None), "value", None)
            if state_value != "clean":
                transaction["last_error"] = (
                    getattr(result, "recovery", None)
                    or "Prepared archive publication could not be independently verified."
                )
                if state_value in {"ahead", "behind", "conflict"} and getattr(
                    result, "remote_head", None
                ):
                    self._discard_prepared_transaction(transaction)
                    return ArchiveResult(
                        RetentionState.ARCHIVE_PENDING_SYNC,
                        None,
                        ticket_ids,
                        recovery=(
                            str(transaction["last_error"])
                            + " The unpublished prepared transaction was discarded; "
                            "synchronize, preview, and retry."
                        ),
                    )
                self._write_transaction(transaction)
                return ArchiveResult(
                    RetentionState.ARCHIVE_PENDING_SYNC,
                    None,
                    ticket_ids,
                    recovery=str(transaction["last_error"]),
                )
            transaction["phase"] = "published"
            transaction["last_error"] = None
            transaction["verified_remote_head"] = getattr(result, "remote_head", None)
            self._write_transaction(transaction)
            self._inject("after_remote_verification")
            phase = "published"

        current = self.store._head()
        if phase == "published":
            if current not in {base_head, candidate_head}:
                raise ArtifactConcurrentUpdate(
                    "artifact authority differs from the verified archive transaction"
                )
            self.store._ensure_materialization_consistent(base_head)
            if current == base_head:
                update = self.store._git(
                    "update-ref",
                    self.store.artifact_ref,
                    candidate_head,
                    base_head,
                    allowed_statuses={0, 128},
                )
                if update.returncode != 0:
                    raise ArtifactConcurrentUpdate(
                        "artifact authority changed during verified archive adoption"
                    )
            self._inject("after_local_ref_update")
            transaction["phase"] = "local_ref_advanced"
            self._write_transaction(transaction)
            phase = "local_ref_advanced"

        if phase == "local_ref_advanced":
            if self.store._head() != candidate_head:
                raise ArtifactConcurrentUpdate(
                    "verified archive commit is no longer the local artifact authority"
                )
            self.store._recover_materialization_transaction()
            self.store._materialize(candidate_head, force=True)
            transaction["phase"] = "materialized"
            self._write_transaction(transaction)
            self._inject("after_archive_materialization")
            phase = "materialized"

        if phase != "materialized":
            raise ArtifactValidationError(f"unsupported retention transaction phase: {phase!r}")
        if self.store._head() != candidate_head:
            raise ArtifactConcurrentUpdate(
                "materialized archive transaction lost canonical authority"
            )
        self.store._recover_materialization_transaction()
        self.store._ensure_materialization_consistent(candidate_head)
        self.store._git(
            "update-ref",
            "-d",
            str(transaction["scratch_ref"]),
            candidate_head,
            allowed_statuses={0, 128},
        )
        self._remove_transaction()
        return ArchiveResult(
            RetentionState.ARCHIVED,
            ArtifactWriteResult(
                event_id=str(transaction["event_id"]),
                commit_id=candidate_head,
                tree_id=self.store._tree_id(candidate_head),
                base_commit=base_head,
                idempotent=False,
            ),
            ticket_ids,
        )

    def _archive_proofs(
        self,
        candidate_head: str,
        tickets: Sequence[RetentionTicket],
        base_entries: Mapping[str, object],
        candidate_entries: Mapping[str, object],
    ) -> tuple[ArtifactRemoteProof, ...]:
        proofs: list[ArtifactRemoteProof] = []
        for ticket in tickets:
            content = self.store._cat_blob(ticket.blob_id)
            proofs.append(
                ArtifactRemoteProof(
                    source_commit=ticket.source_commit,
                    path=ticket.path,
                    blob_id=ticket.blob_id,
                    sha256=hashlib.sha256(content).hexdigest(),
                )
            )
            for path in ticket.attachment_paths:
                entry = base_entries.get(path)
                if entry is None:
                    raise ArtifactValidationError(f"referenced attachment is missing: {path}")
                attachment = self.store._cat_blob(entry.oid)
                proofs.append(
                    ArtifactRemoteProof(
                        source_commit=ticket.source_commit,
                        path=path,
                        blob_id=entry.oid,
                        sha256=hashlib.sha256(attachment).hexdigest(),
                    )
                )
        catalog_path = ".orchestrator/archive-index.jsonl"
        catalog_entry = candidate_entries.get(catalog_path)
        if catalog_entry is None:
            raise ArtifactValidationError("prepared archive commit has no catalog")
        catalog_content = self.store._cat_blob(catalog_entry.oid)
        proofs.append(
            ArtifactRemoteProof(
                source_commit=candidate_head,
                path=catalog_path,
                blob_id=catalog_entry.oid,
                sha256=hashlib.sha256(catalog_content).hexdigest(),
            )
        )
        return tuple(sorted(proofs, key=lambda value: (value.source_commit, value.path)))

    def _validate_remote_transaction(
        self,
        synchronizer: object | None,
        *,
        confirmation: ArchiveRemoteConfirmation | None = None,
    ) -> ArchiveRemoteConfirmation:
        if self.remote_mode != "enabled":
            raise ArtifactValidationError(
                "terminal cleanup remains preview-only until a GitHub remote is selected and confirmed"
            )
        if synchronizer is None or not all(
            hasattr(synchronizer, name)
            for name in (
                "sync_confirmed",
                "publish_prepared",
                "recover_exact_ref",
                "remote_name",
            )
        ):
            raise ArtifactValidationError(
                "remote-enabled retention requires the exact-ref verified synchronizer"
            )
        confirmation = confirmation or self.remote_confirmation
        if (
            confirmation is None
            or confirmation.service != "github"
            or not confirmation.exposure_confirmed
        ):
            raise ArtifactValidationError(
                "GitHub archival exposure has not been explicitly confirmed"
            )
        if confirmation.remote_name != getattr(synchronizer, "remote_name", None):
            raise ArtifactValidationError("confirmed GitHub remote does not match the synchronizer")
        remote_url, push_url = _configured_remote_urls(self.store, confirmation.remote_name)
        remote_digest = hashlib.sha256(remote_url.encode("utf-8")).hexdigest()
        if remote_digest != confirmation.remote_url_sha256:
            raise ArtifactValidationError(
                "the selected GitHub remote URL changed after exposure confirmation"
            )
        push_digest = hashlib.sha256(push_url.encode("utf-8")).hexdigest()
        if push_digest != confirmation.push_url_sha256:
            raise ArtifactValidationError(
                "the selected GitHub push destination changed after exposure confirmation"
            )
        return confirmation

    def _scratch_ref(self, event_id: str) -> str:
        digest = hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:32]
        return f"refs/relay-runner/retention/{self.store.project_id}/{digest}"

    def _transaction_confirmation(
        self,
        transaction: Mapping[str, object],
    ) -> ArchiveRemoteConfirmation:
        value = transaction.get("remote_confirmation")
        if not isinstance(value, Mapping):
            raise ArtifactValidationError("retention transaction has no remote confirmation")
        return ArchiveRemoteConfirmation(
            service=str(value.get("service", "")),
            remote_name=str(value.get("remote_name", "")),
            remote_url_sha256=str(value.get("remote_url_sha256", "")),
            push_url_sha256=str(value.get("push_url_sha256", "")),
            exposure_confirmed=value.get("exposure_confirmed") is True,
        )

    def _ensure_transaction_scratch(self, transaction: Mapping[str, object]) -> None:
        scratch_ref = str(transaction["scratch_ref"])
        candidate_head = str(transaction["candidate_head"])
        found = self.store._git(
            "rev-parse", "--verify", scratch_ref, allowed_statuses={0, 128}
        )
        if found.returncode == 0:
            if found.stdout.strip() != candidate_head:
                raise ArtifactConcurrentUpdate(
                    "retention scratch ref already names another commit"
                )
            return
        update = self.store._git(
            "update-ref",
            scratch_ref,
            candidate_head,
            self.store._zero_oid(),
            allowed_statuses={0, 128},
        )
        if update.returncode != 0:
            raise ArtifactConcurrentUpdate("retention scratch ref changed during recovery")

    def _publish_transaction_scratch(self, transaction: Mapping[str, object]) -> None:
        """Pin a prepared candidate before making its journal durable."""
        if self.transaction_path.exists():
            raise ArtifactConcurrentUpdate(
                "another retention transaction appeared before candidate preparation"
            )
        scratch_ref = str(transaction["scratch_ref"])
        candidate_head = str(transaction["candidate_head"])
        found = self.store._git(
            "rev-parse", "--verify", scratch_ref, allowed_statuses={0, 128}
        )
        previous = (
            found.stdout.strip() if found.returncode == 0 else self.store._zero_oid()
        )
        if previous == candidate_head:
            return
        update = self.store._git(
            "update-ref",
            scratch_ref,
            candidate_head,
            previous,
            allowed_statuses={0, 128},
        )
        if update.returncode != 0:
            raise ArtifactConcurrentUpdate(
                "retention scratch ref changed before journal publication"
            )

    def _discard_prepared_transaction(self, transaction: Mapping[str, object]) -> None:
        if transaction.get("phase") != "prepared" or self.store._head() != transaction.get(
            "base_head"
        ):
            raise ArtifactConcurrentUpdate(
                "only an unpublished prepared retention transaction can be discarded"
            )
        self.store._git(
            "update-ref",
            "-d",
            str(transaction["scratch_ref"]),
            str(transaction["candidate_head"]),
            allowed_statuses={0, 128},
        )
        self._remove_transaction()

    def _read_transaction(self) -> dict[str, object] | None:
        if not self.transaction_path.exists():
            return None
        try:
            value = json.loads(self.transaction_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"retention transaction journal is corrupt: {error}") from error
        if not isinstance(value, dict):
            raise ArtifactValidationError("retention transaction journal is not an object")
        self._validate_transaction(value)
        return value

    def _write_transaction(self, transaction: Mapping[str, object]) -> None:
        self._validate_transaction(transaction)
        self.transaction_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.transaction_path.with_name(
            self.transaction_path.name + f".{uuid.uuid4().hex}.tmp"
        )
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(_canonical_json(transaction) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.transaction_path)
            directory = os.open(self.transaction_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)

    def _remove_transaction(self) -> None:
        self.transaction_path.unlink(missing_ok=True)
        directory = os.open(self.transaction_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def _validate_transaction(self, transaction: Mapping[str, object]) -> None:
        if transaction.get("schema_version") != RETENTION_TRANSACTION_SCHEMA_VERSION:
            raise ArtifactValidationError("retention transaction schema is unsupported")
        if transaction.get("project_id") != self.store.project_id:
            raise ArtifactValidationError("retention transaction belongs to another project")
        required_strings = (
            "event_id",
            "device_id",
            "actor_type",
            "phase",
            "base_head",
            "candidate_head",
            "scratch_ref",
        )
        if any(not isinstance(transaction.get(key), str) or not transaction[key] for key in required_strings):
            raise ArtifactValidationError("retention transaction journal is incomplete")
        if transaction.get("phase") not in {"prepared", "published", "local_ref_advanced", "materialized"}:
            raise ArtifactValidationError("retention transaction phase is invalid")
        if transaction.get("scratch_ref") != self._scratch_ref(str(transaction["event_id"])):
            raise ArtifactValidationError("retention transaction scratch ref is invalid")
        if not isinstance(transaction.get("ticket_ids"), list) or not transaction["ticket_ids"]:
            raise ArtifactValidationError("retention transaction has no ticket identities")
        proofs = transaction.get("proofs")
        if not isinstance(proofs, list) or not proofs or any(not isinstance(value, dict) for value in proofs):
            raise ArtifactValidationError("retention transaction proofs are incomplete")
        confirmation = self._transaction_confirmation(transaction)
        if (
            confirmation.service != "github"
            or not confirmation.exposure_confirmed
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", confirmation.remote_name)
            or not re.fullmatch(r"[0-9a-f]{64}", confirmation.remote_url_sha256)
            or not re.fullmatch(r"[0-9a-f]{64}", confirmation.push_url_sha256)
        ):
            raise ArtifactValidationError("retention transaction remote confirmation is invalid")

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


def _is_github_url(value: str) -> bool:
    repository = r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"
    return bool(
        re.fullmatch(rf"https://github\.com/{repository}", value, re.IGNORECASE)
        or re.fullmatch(rf"ssh://git@github\.com/{repository}", value, re.IGNORECASE)
        or re.fullmatch(rf"git@github\.com:{repository}", value, re.IGNORECASE)
    )


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


def _canonical_status(front: Mapping[str, str]) -> str:
    if _parse_bool(front.get("canceled", "false")):
        return "canceled"
    return front.get("status", "backlog")


def _is_terminal(status: str) -> bool:
    return status.strip().lower() in TERMINAL_STATUSES


def _plan_identity(plan: RetentionPlan) -> tuple[object, ...]:
    return (
        plan.schema_version,
        plan.policy,
        plan.limit,
        plan.candidate_ids,
        plan.retained_terminal_ids,
        plan.nonterminal_ids,
        plan.materialize_ids,
        tuple((ticket.ticket_id, ticket.exemptions) for ticket in plan.exempt),
    )


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
    "ArchiveRemoteConfirmation",
    "ArchiveResult",
    "ArtifactRetentionManager",
    "DependencyHistoryUnavailable",
    "HistoricalCard",
    "HistoricalAttachment",
    "HistoricalDetail",
    "HistoryAvailability",
    "RetentionPlan",
    "RetentionState",
    "RetentionTicket",
    "SnapshotLease",
    "SnapshotLeaseStore",
    "StorageMetrics",
    "confirm_github_remote",
]
