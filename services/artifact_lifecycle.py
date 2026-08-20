#!/usr/bin/env python3
"""Artifact-writer ownership for Relay worker and reviewer lifecycle."""

from __future__ import annotations

import base64
import dataclasses
import enum
import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
try:
    from services.toml_compat import tomllib
except ModuleNotFoundError:
    from toml_compat import tomllib
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence

try:
    from services.artifact_retention import ArtifactRetentionManager, SnapshotLeaseStore
    from services.artifact_store import (
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        TicketWrite,
        _find_forbidden_keys,
        _reject_secrets,
    )
except ModuleNotFoundError:  # Direct services/*.py execution.
    from artifact_retention import (  # type: ignore[no-redef]
        ArtifactRetentionManager,
        SnapshotLeaseStore,
    )
    from artifact_store import (  # type: ignore[no-redef]
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        TicketWrite,
        _find_forbidden_keys,
        _reject_secrets,
    )


UTC = timezone.utc
OUTCOME_SCHEMA_VERSION = 1
SNAPSHOT_SCHEMA_VERSION = 1
MAX_SUMMARY_BYTES = 4 * 1024
MAX_VERIFICATION_BYTES = 8 * 1024
MAX_CHANGED_PATHS = 500
MAX_LOCAL_LOG_BYTES = 2 * 1024 * 1024
TERMINAL_RUN_STATES = {
    "Canceled",
    "Failed",
    "Merged",
    "VerificationBlocked",
    "SpikeCompleted",
}
LIVE_RUN_STATES = {
    "Claimed",
    "Running",
    "AwaitingReview",
    "Reviewing",
    "Succeeded",
    "MergeConflict",
    "IntegrationBlocked",
}

_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
_OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
_outcome_locks_guard = threading.Lock()
_outcome_locks: dict[str, threading.RLock] = {}


class WorkerOutcomeStatus(str, enum.Enum):
    COMPLETED = "completed"
    VERIFICATION_BLOCKED = "verification_blocked"


@dataclasses.dataclass(frozen=True)
class StructuredWorkerOutcome:
    schema_version: int
    project_id: str
    ticket_id: str
    run_id: int
    provider: str
    status: WorkerOutcomeStatus
    summary: str
    changed_paths: tuple[str, ...]
    verification: tuple[str, ...]
    source_commit: str
    verification_blocker: str | None = None
    verification_resume: str | None = None


@dataclasses.dataclass(frozen=True)
class ArtifactWorkerSnapshot:
    project_id: str
    ticket_id: str
    artifact_id: str
    artifact_head: str
    run_id: int
    provider: str
    lease_id: str
    manifest_path: Path
    files: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class LifecycleWriteResult:
    event_id: str
    commit_id: str
    promoted_ticket_ids: tuple[str, ...] = ()
    idempotent: bool = False


@dataclasses.dataclass(frozen=True)
class ScopeValidation:
    project_id: str
    repository_path: str
    registry_schema_version: int


class ArtifactLifecycleCoordinator:
    """One project lifecycle facade over the canonical artifact writer."""

    def __init__(
        self,
        store: ArtifactStore,
        *,
        registry_path: Path,
        device_id: str,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.store = store
        self.registry_path = Path(registry_path)
        self.device_id = _safe_id(device_id, "device ID")
        self.now = now or (lambda: datetime.now(UTC))
        self.leases = SnapshotLeaseStore(store)
        self.lifecycle_root = store.project_state / "lifecycle"
        self.outcome_root = self.lifecycle_root / "outcomes"
        self.snapshot_proof_root = self.lifecycle_root / "snapshot-proofs"

    @classmethod
    def is_enabled(cls, store: ArtifactStore) -> bool:
        snapshot = store.snapshot()
        config = tomllib.loads(snapshot.files[".orchestrator/config.toml"].decode("utf-8"))
        return config.get("artifact_lifecycle", "legacy") == "enabled"

    def validate_scope(
        self,
        encoded_token: str | None,
        *,
        internally_confirmed_project_id: str | None = None,
    ) -> ScopeValidation:
        """Validate the UI/MCP scope token or a daemon-owned same-project continuation."""
        if internally_confirmed_project_id is not None:
            if internally_confirmed_project_id != self.store.project_id:
                raise ArtifactValidationError("internal lifecycle scope belongs to another project")
            record, schema = self._registry_record()
            return ScopeValidation(self.store.project_id, str(record["last_resolved_path"]), schema)
        if not encoded_token:
            raise ArtifactValidationError(
                "artifact lifecycle dispatch requires a confirmed project scope token"
            )
        try:
            token = json.loads(base64.b64decode(encoded_token, validate=True))
        except (ValueError, json.JSONDecodeError) as error:
            raise ArtifactValidationError("confirmed project scope token is malformed") from error
        if not isinstance(token, dict) or token.get("version") != 1:
            raise ArtifactValidationError("confirmed project scope token version is invalid")
        record, schema = self._registry_record()
        expected = {
            "projectID": self.store.project_id,
            "repositoryPath": str(self.store.repo_path),
            "gitCommonDirectoryFingerprint": record.get("git_common_directory_fingerprint"),
            "registrySchemaVersion": schema,
        }
        for key, value in expected.items():
            if token.get(key) != value:
                raise ArtifactValidationError(f"confirmed project scope token has stale {key}")
        token_updated = token.get("registryRecordUpdatedAt")
        record_updated = _registry_timestamp(record.get("updated_at"))
        if not isinstance(token_updated, (int, float)) or abs(float(token_updated) - record_updated) > 0.000001:
            raise ArtifactValidationError("confirmed project scope token is stale")
        return ScopeValidation(self.store.project_id, str(self.store.repo_path), schema)

    def claim_and_materialize(
        self,
        *,
        ticket_id: str,
        run_id: int,
        provider: str,
        workspace_path: Path,
    ) -> ArtifactWorkerSnapshot:
        self._validate_provider(provider)
        ticket_id = _safe_id(ticket_id, "ticket ID")
        if run_id <= 0:
            raise ArtifactValidationError("run ID must be positive")
        event_id = f"lifecycle:run:{run_id}:claim"
        prior = self.store._find_event(event_id)
        snapshot = self.store.snapshot()
        ticket_path = f".orchestrator/{ticket_id}.md"
        ticket_bytes = snapshot.files.get(ticket_path)
        if ticket_bytes is None:
            raise ArtifactValidationError(f"ticket {ticket_id} is not materialized")
        fields, _body = _split_ticket(ticket_bytes)
        status = fields.get("status", "backlog")
        if prior is None and status not in {"backlog", "ready"}:
            raise ArtifactValidationError(
                f"ticket {ticket_id} is {status!r}, not dispatchable through artifact lifecycle"
            )
        if prior is not None and (
            status != "in_progress" or fields.get("run_id") != str(run_id)
        ):
            raise ArtifactValidationError(
                f"idempotent claim for run {run_id} no longer matches canonical ticket state"
            )
        if _truthy(fields.get("canceled", "false")):
            raise ArtifactValidationError(f"ticket {ticket_id} is canceled")
        artifact_id = fields.get("artifact_id")
        if not artifact_id:
            raise ArtifactValidationError(f"ticket {ticket_id} has no immutable artifact_id")
        instant = _format_instant(self.now())
        claimed = _rewrite_ticket(
            ticket_bytes,
            {
                "status": "in_progress",
                "run_id": str(run_id),
                "run_state": "claimed",
                "claimed_at": instant,
                "activity_at": instant,
            },
        )
        if prior is None:
            self.store.mutate(
                ArtifactMutation(
                    event_id=event_id,
                    actor_type="system",
                    device_id=self.device_id,
                    provider=provider,
                    expected_base=snapshot.commit_id,
                    operations=(TicketWrite(ticket_id, artifact_id, claimed),),
                    summary=f"Claim {ticket_id} for run {run_id}",
                )
            )
        claimed_snapshot = self.store.snapshot(provider=provider)
        lease_id = f"run:{run_id}:worker"
        attachment_paths = tuple(
            sorted(
                path
                for path in claimed_snapshot.files
                if path.startswith(f".orchestrator/attachments/{ticket_id}/")
            )
        )
        self.leases.acquire(
            lease_id=lease_id,
            ticket_id=ticket_id,
            artifact_id=artifact_id,
            artifact_head=claimed_snapshot.commit_id,
            run_id=str(run_id),
            role="worker",
            provider=provider,
            attachment_paths=attachment_paths,
            now=self.now(),
        )
        try:
            manifest_path, files = self._materialize_snapshot(
                claimed_snapshot.files,
                artifact_head=claimed_snapshot.commit_id,
                ticket_id=ticket_id,
                artifact_id=artifact_id,
                run_id=run_id,
                provider=provider,
                workspace_path=Path(workspace_path),
            )
            self._write_snapshot_proof(
                run_id=run_id,
                artifact_head=claimed_snapshot.commit_id,
                manifest=manifest_path.read_bytes(),
            )
        except Exception:
            self._release_if_active(lease_id, "snapshot materialization failed")
            self._remove_snapshot_proof(run_id)
            raise
        return ArtifactWorkerSnapshot(
            project_id=self.store.project_id,
            ticket_id=ticket_id,
            artifact_id=artifact_id,
            artifact_head=claimed_snapshot.commit_id,
            run_id=run_id,
            provider=provider,
            lease_id=lease_id,
            manifest_path=manifest_path,
            files=files,
        )

    def update_worker_sizing(
        self,
        *,
        ticket_id: str,
        provider: str,
        fields: Mapping[str, object],
    ) -> LifecycleWriteResult:
        self._validate_provider(provider)
        allowed = (
            "worker_model",
            "worker_effort",
            "worker_sizing_rationale",
            "worker_provider_notes",
        )
        updates = {
            key: _bounded_text(fields.get(key), key, MAX_SUMMARY_BYTES)
            for key in allowed
        }
        digest = hashlib.sha256(_canonical_json(updates).encode("utf-8")).hexdigest()[:24]
        event_id = f"lifecycle:sizing:{ticket_id}:{digest}"
        prior = self._prior_event(event_id)
        if prior is not None:
            return prior
        snapshot = self.store.snapshot()
        path = f".orchestrator/{ticket_id}.md"
        content = snapshot.files.get(path)
        if content is None:
            raise ArtifactValidationError(f"canonical ticket {ticket_id} is missing")
        ticket_fields, _ = _split_ticket(content)
        artifact_id = ticket_fields.get("artifact_id")
        if not artifact_id:
            raise ArtifactValidationError(f"ticket {ticket_id} has no immutable artifact_id")
        write = self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type="system",
                device_id=self.device_id,
                provider=provider,
                expected_base=snapshot.commit_id,
                operations=(TicketWrite(ticket_id, artifact_id, _rewrite_ticket(content, updates)),),
                summary=f"Apply worker sizing to {ticket_id}",
            )
        )
        return LifecycleWriteResult(event_id, write.commit_id, idempotent=write.idempotent)

    def submit_outcome(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        payload: Mapping[str, object],
    ) -> StructuredWorkerOutcome:
        outcome = self._validate_outcome(run_id, ticket_id, provider, payload)
        lease = self._lease_for_run(run_id, "worker")
        if lease.ticket_id != ticket_id or lease.provider != provider:
            raise ArtifactValidationError("worker outcome does not match its snapshot lease")
        encoded = _canonical_json(_outcome_json(outcome)).encode("utf-8") + b"\n"
        path = self._outcome_path(run_id)
        lock = _outcome_lock(path)
        with lock:
            if path.exists():
                existing = path.read_bytes()
                if existing != encoded:
                    raise ArtifactValidationError(
                        f"run {run_id} already submitted a different immutable outcome"
                    )
                return outcome
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
            temporary.write_bytes(encoded)
            os.replace(temporary, path)
        return outcome

    def outcome(self, run_id: int) -> StructuredWorkerOutcome | None:
        path = self._outcome_path(run_id)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"run {run_id} outcome store is corrupt: {error}") from error
        return self._validate_outcome(
            run_id,
            str(payload.get("ticket_id") or ""),
            str(payload.get("provider") or ""),
            payload,
        )

    def validate_worker_completion(
        self,
        *,
        workspace_path: Path,
        ticket_id: str,
        run_id: int,
        provider: str,
        start_head: str | None,
    ) -> tuple[str | None, str]:
        outcome = self.outcome(run_id)
        if outcome is None:
            return None, "worker did not submit a structured outcome"
        if outcome.ticket_id != ticket_id or outcome.provider != provider:
            return None, "structured outcome ownership does not match the run"
        try:
            self._validate_materialized_snapshot(
                workspace_path=Path(workspace_path),
                ticket_id=ticket_id,
                run_id=run_id,
                provider=provider,
                start_head=start_head,
            )
        except ArtifactValidationError as error:
            return None, str(error)
        current_head = _git_text(workspace_path, "rev-parse", "HEAD")
        if not current_head or current_head != outcome.source_commit:
            return None, "structured outcome source_commit does not match worker HEAD"
        if start_head is None or current_head == start_head:
            return None, "worker made no source commit"
        changed = tuple(
            sorted(
                line
                for line in _git_text(
                    workspace_path, "diff", "--name-only", f"{start_head}..{current_head}"
                ).splitlines()
                if line
            )
        )
        forbidden = [path for path in changed if _is_lifecycle_path(path)]
        if forbidden:
            return None, "worker source branch contains lifecycle paths: " + ", ".join(forbidden)
        if changed != outcome.changed_paths:
            return None, "structured outcome changed_paths do not match committed source diff"
        dirty = []
        for line in _git_text(
            workspace_path, "status", "--porcelain=v1", "--untracked-files=all"
        ).splitlines():
            path = line[3:] if len(line) > 3 else line
            if not _is_lifecycle_path(path):
                dirty.append(line)
        if dirty:
            return None, "worker left uncommitted source changes"
        if outcome.status == WorkerOutcomeStatus.VERIFICATION_BLOCKED:
            return outcome.status.value, (
                f"verification blocked: {outcome.verification_blocker}; "
                f"resume: {outcome.verification_resume}"
            )
        return outcome.status.value, "structured worker outcome accepted"

    def begin_review(self, *, run_id: int, provider: str) -> None:
        outcome = self.outcome(run_id)
        if outcome is None:
            raise ArtifactValidationError(f"run {run_id} has no structured outcome to review")
        if any(
            lease.lease_id == f"run:{run_id}:reviewer"
            for lease in self.leases.active()
        ):
            return
        worker = self._lease_for_run(run_id, "worker")
        self.leases.acquire(
            lease_id=f"run:{run_id}:reviewer",
            ticket_id=worker.ticket_id,
            artifact_id=worker.artifact_id,
            artifact_head=worker.artifact_head,
            run_id=str(run_id),
            role="reviewer",
            provider=provider,
            attachment_paths=worker.attachment_paths,
            now=self.now(),
        )
        self._release_if_active(worker.lease_id, "worker outcome accepted for review")

    def record_failure(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        reason: str,
        canceled: bool = False,
        retry: bool = False,
    ) -> LifecycleWriteResult:
        reason = _bounded_text(reason, "failure reason", MAX_SUMMARY_BYTES)
        target_status = "ready" if retry else "backlog"
        run_state = "canceled" if canceled else "retry_requested" if retry else "failed"
        event_suffix = "canceled" if canceled else "retry" if retry else "failed"
        result = self._update_ticket_event(
            run_id=run_id,
            ticket_id=ticket_id,
            provider=provider,
            event_id=f"lifecycle:run:{run_id}:{event_suffix}",
            status=target_status,
            run_state=run_state,
            clear_run_id=True,
            log_summary=f"{run_state.replace('_', ' ')}: {reason}",
        )
        self._release_run_leases(run_id, run_state)
        return result

    def record_merge_conflict(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        reason: str,
    ) -> LifecycleWriteResult:
        return self._update_ticket_event(
            run_id=run_id,
            ticket_id=ticket_id,
            provider=provider,
            event_id=f"lifecycle:run:{run_id}:merge-conflict",
            status="in_progress",
            run_state="merge_conflict",
            clear_run_id=False,
            log_summary="merge conflict: " + _bounded_text(reason, "merge conflict", MAX_SUMMARY_BYTES),
        )

    def publish_merge_success(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        merged_source_commit: str,
    ) -> LifecycleWriteResult:
        event_id = f"lifecycle:run:{run_id}:merge"
        prior = self._prior_event(event_id)
        if prior is not None:
            self._release_run_leases(run_id, "merged")
            return prior
        outcome = self.outcome(run_id)
        if outcome is None:
            raise ArtifactValidationError(f"run {run_id} has no structured outcome")
        if outcome.ticket_id != ticket_id or outcome.provider != provider:
            raise ArtifactValidationError("merged outcome ownership does not match the run")
        if not _OID_RE.fullmatch(merged_source_commit):
            raise ArtifactValidationError("merged source commit is not a full Git object ID")
        source_head = _git_text(self.store.repo_path, "rev-parse", "HEAD")
        if source_head != merged_source_commit:
            raise ArtifactValidationError(
                "canonical done publication requires the reviewed source merge at repository HEAD"
            )
        if not _git_is_ancestor(
            self.store.repo_path, outcome.source_commit, merged_source_commit
        ):
            raise ArtifactValidationError(
                "reviewed worker source commit is not reachable from the merged source HEAD"
            )
        snapshot = self.store.snapshot()
        path = f".orchestrator/{ticket_id}.md"
        ticket_bytes = snapshot.files.get(path)
        if ticket_bytes is None:
            raise ArtifactValidationError(f"canonical ticket {ticket_id} is missing")
        fields, _ = _split_ticket(ticket_bytes)
        if fields.get("status") != "in_progress" or fields.get("run_id") != str(run_id):
            raise ArtifactValidationError(
                f"canonical ticket {ticket_id} no longer belongs to run {run_id}"
            )
        artifact_id = fields.get("artifact_id")
        if not artifact_id:
            raise ArtifactValidationError(f"ticket {ticket_id} has no immutable artifact_id")
        instant = _format_instant(self.now())
        status = (
            "verification_blocked"
            if outcome.status == WorkerOutcomeStatus.VERIFICATION_BLOCKED
            else "done"
        )
        updates: dict[str, str | None] = {
            "status": status,
            "run_id": str(run_id),
            "run_state": "verification_blocked" if status == "verification_blocked" else "merged",
            "merge_outcome_at": instant,
            "activity_at": instant,
            "verification_blocker": outcome.verification_blocker,
            "verification_resume": outcome.verification_resume,
        }
        log = self._run_summary(outcome, merged_source_commit)
        finished = _append_run_log(_rewrite_ticket(ticket_bytes, updates), run_id, log)
        operations: list[TicketWrite] = [TicketWrite(ticket_id, artifact_id, finished)]
        promoted: list[str] = []
        if status == "done":
            statuses = self._status_map(snapshot.files)
            statuses[ticket_id] = "done"
            manager = ArtifactRetentionManager(
                self.store,
                lease_store=self.leases,
                enabled=True,
            )
            for candidate_path in sorted(snapshot.files):
                if not _is_ticket_path(candidate_path) or candidate_path == path:
                    continue
                content = snapshot.files[candidate_path]
                candidate_fields, _ = _split_ticket(content)
                if candidate_fields.get("status") != "backlog":
                    continue
                dependencies = _parse_list(candidate_fields.get("depends_on", "[]"))
                if not dependencies or not self._dependencies_allow_automatic_promotion(
                    dependencies,
                    statuses=statuses,
                    manager=manager,
                ):
                    continue
                candidate_id = PurePosixPath(candidate_path).stem
                candidate_artifact_id = candidate_fields.get("artifact_id")
                if not candidate_artifact_id:
                    raise ArtifactValidationError(
                        f"dependent ticket {candidate_id} has no immutable artifact_id"
                    )
                advanced = _rewrite_ticket(
                    content,
                    {
                        "status": "ready",
                        "run_state": "dependency_ready",
                        "dependency_updated_at": instant,
                        "activity_at": instant,
                    },
                )
                operations.append(TicketWrite(candidate_id, candidate_artifact_id, advanced))
                statuses[candidate_id] = "ready"
                promoted.append(candidate_id)
        result = self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type="reviewer",
                device_id=self.device_id,
                provider=provider,
                expected_base=snapshot.commit_id,
                operations=tuple(operations),
                summary=f"Publish reviewed outcome for {ticket_id} run {run_id}",
            )
        )
        self._release_run_leases(run_id, status)
        return LifecycleWriteResult(
            event_id=event_id,
            commit_id=result.commit_id,
            promoted_ticket_ids=tuple(promoted),
            idempotent=result.idempotent,
        )

    def promote_unblocked_dependents(self) -> tuple[str, ...]:
        """Promote artifact-backed backlog tickets through the canonical writer."""
        snapshot = self.store.snapshot()
        statuses = self._status_map(snapshot.files)
        manager = ArtifactRetentionManager(
            self.store,
            lease_store=self.leases,
            enabled=True,
        )
        instant = _format_instant(self.now())
        operations: list[TicketWrite] = []
        promoted: list[str] = []
        for candidate_path in sorted(snapshot.files):
            if not _is_ticket_path(candidate_path):
                continue
            content = snapshot.files[candidate_path]
            fields, _ = _split_ticket(content)
            if fields.get("status") != "backlog":
                continue
            dependencies = _parse_list(fields.get("depends_on", "[]"))
            if not dependencies or not self._dependencies_allow_automatic_promotion(
                dependencies,
                statuses=statuses,
                manager=manager,
            ):
                continue
            ticket_id = PurePosixPath(candidate_path).stem
            artifact_id = fields.get("artifact_id")
            if not artifact_id:
                raise ArtifactValidationError(
                    f"dependent ticket {ticket_id} has no immutable artifact_id"
                )
            advanced = _rewrite_ticket(
                content,
                {
                    "status": "ready",
                    "run_state": "dependency_ready",
                    "dependency_updated_at": instant,
                    "activity_at": instant,
                },
            )
            operations.append(TicketWrite(ticket_id, artifact_id, advanced))
            statuses[ticket_id] = "ready"
            promoted.append(ticket_id)
        if not operations:
            return ()
        self.store.mutate(
            ArtifactMutation(
                event_id=f"lifecycle:dependency-sweep:{snapshot.commit_id}",
                actor_type="pm",
                device_id=self.device_id,
                expected_base=snapshot.commit_id,
                operations=tuple(operations),
                summary="Promote artifact-backed dependency-ready tickets",
            )
        )
        return tuple(promoted)

    def _dependencies_allow_automatic_promotion(
        self,
        dependencies: Sequence[str],
        *,
        statuses: Mapping[str, str],
        manager: ArtifactRetentionManager,
    ) -> bool:
        for dependency_id in dependencies:
            if statuses.get(dependency_id) != "done" and not manager.dependency_satisfied(
                dependency_id
            ):
                return False
            if manager.dependency_execution_mode(dependency_id) == "spike":
                return False
        return True

    def resume_verification(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        reason: str,
    ) -> LifecycleWriteResult:
        reason = _bounded_text(reason, "verification resume reason", MAX_SUMMARY_BYTES)
        event_id = f"lifecycle:run:{run_id}:verification-resume"
        prior = self._prior_event(event_id)
        if prior is not None:
            return prior
        snapshot = self.store.snapshot()
        ticket_path = f".orchestrator/{ticket_id}.md"
        content = snapshot.files.get(ticket_path)
        if content is None:
            raise ArtifactValidationError(f"canonical ticket {ticket_id} is missing")
        fields, _ = _split_ticket(content)
        if fields.get("status") != "verification_blocked":
            raise ArtifactValidationError(
                f"ticket {ticket_id} is not verification blocked"
            )
        if fields.get("run_id") != str(run_id):
            raise ArtifactValidationError(
                f"ticket {ticket_id} does not belong to verification-blocked run {run_id}"
            )
        return self._update_ticket_event(
            run_id=run_id,
            ticket_id=ticket_id,
            provider=provider,
            event_id=event_id,
            status="ready",
            run_state="verification_resumed",
            clear_run_id=True,
            log_summary=f"verification resumed: {reason}",
            clear_verification=True,
        )

    def recover_leases(self, run_state: Callable[[int], str | None]) -> tuple[str, ...]:
        released: list[str] = []
        for lease in self.leases.active():
            try:
                run_id = int(lease.run_id)
            except ValueError:
                continue
            state = run_state(run_id)
            if state in TERMINAL_RUN_STATES or state is None:
                self.leases.release(
                    lease.lease_id,
                    terminal_reason=f"daemon recovery observed terminal run state {state or 'missing'}",
                    now=self.now(),
                )
                released.append(lease.lease_id)
                if not any(
                    active.run_id == lease.run_id
                    for active in self.leases.active()
                ):
                    self._remove_snapshot_proof(run_id)
            elif state in LIVE_RUN_STATES:
                continue
        return tuple(released)

    def cap_local_log(self, path: Path, *, max_bytes: int = MAX_LOCAL_LOG_BYTES) -> int:
        try:
            size = path.stat().st_size
        except OSError:
            return 0
        if size <= max_bytes:
            return size
        with path.open("rb") as handle:
            handle.seek(-max_bytes, os.SEEK_END)
            tail = handle.read()
        temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
        temporary.write_bytes(tail)
        os.replace(temporary, path)
        return len(tail)

    @staticmethod
    def cleanup_snapshot(workspace_path: Path) -> None:
        destination = Path(workspace_path) / ".orchestrator"
        _make_writable(destination)
        shutil.rmtree(destination, ignore_errors=True)

    def _validate_materialized_snapshot(
        self,
        *,
        workspace_path: Path,
        ticket_id: str,
        run_id: int,
        provider: str,
        start_head: str | None,
    ) -> None:
        root = workspace_path / ".orchestrator"
        manifest_path = root / ".artifact-snapshot.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"immutable worker snapshot manifest is unavailable: {error}") from error
        if not isinstance(manifest, dict) or manifest.get("schema_version") != SNAPSHOT_SCHEMA_VERSION:
            raise ArtifactValidationError("immutable worker snapshot manifest is invalid")
        expected_identity = {
            "project_id": self.store.project_id,
            "ticket_id": ticket_id,
            "run_id": run_id,
            "provider": provider,
        }
        if any(manifest.get(key) != value for key, value in expected_identity.items()):
            raise ArtifactValidationError("immutable worker snapshot identity changed")
        if not start_head or manifest.get("source_start_head") != start_head:
            raise ArtifactValidationError("immutable worker snapshot source base changed")
        lease = self._lease_for_run(run_id, "worker")
        if manifest.get("artifact_head") != lease.artifact_head:
            raise ArtifactValidationError("immutable worker snapshot artifact head changed")
        proof_path = self._snapshot_proof_path(run_id)
        try:
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"immutable worker snapshot proof is unavailable: {error}") from error
        if (
            not isinstance(proof, dict)
            or proof.get("run_id") != run_id
            or proof.get("artifact_head") != lease.artifact_head
            or proof.get("manifest_sha256")
            != hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        ):
            raise ArtifactValidationError("immutable worker snapshot manifest changed")
        declared = manifest.get("files")
        if not isinstance(declared, dict) or not declared:
            raise ArtifactValidationError("immutable worker snapshot has no file manifest")
        actual_paths: set[str] = set()
        for path in root.rglob("*"):
            if path.is_dir():
                continue
            if path.is_symlink() or not path.is_file():
                raise ArtifactValidationError("immutable worker snapshot contains a non-regular file")
            relative = ".orchestrator/" + path.relative_to(root).as_posix()
            if relative != ".orchestrator/.artifact-snapshot.json":
                actual_paths.add(relative)
        if actual_paths != set(declared):
            raise ArtifactValidationError("immutable worker snapshot file set changed")
        for relative, metadata in declared.items():
            if not isinstance(relative, str) or not isinstance(metadata, dict):
                raise ArtifactValidationError("immutable worker snapshot file metadata is invalid")
            target = workspace_path / relative
            try:
                content = target.read_bytes()
            except OSError as error:
                raise ArtifactValidationError(
                    f"immutable worker snapshot file is unavailable: {relative}"
                ) from error
            if (
                metadata.get("bytes") != len(content)
                or metadata.get("sha256") != hashlib.sha256(content).hexdigest()
            ):
                raise ArtifactValidationError(
                    f"immutable worker snapshot file changed: {relative}"
                )

    def _materialize_snapshot(
        self,
        files: Mapping[str, bytes],
        *,
        artifact_head: str,
        ticket_id: str,
        artifact_id: str,
        run_id: int,
        provider: str,
        workspace_path: Path,
    ) -> tuple[Path, tuple[str, ...]]:
        tracked = _git_text(workspace_path, "ls-files", "--", ".orchestrator", ".relay")
        if tracked:
            raise ArtifactValidationError(
                "artifact lifecycle requires reviewed source cleanup; source branch still tracks lifecycle paths"
            )
        destination = workspace_path / ".orchestrator"
        if destination.exists() or destination.is_symlink():
            raise ArtifactValidationError("worker snapshot destination already exists")
        ticket_path = f".orchestrator/{ticket_id}.md"
        selected: dict[str, bytes] = {ticket_path: files[ticket_path]}
        for path, content in files.items():
            if path.startswith(f".orchestrator/attachments/{ticket_id}/"):
                selected[path] = content
        fields, _ = _split_ticket(files[ticket_path])
        catalog = _catalog(files)
        dependency_summaries = []
        for dependency_id in _parse_list(fields.get("depends_on", "[]")):
            dependency_path = f".orchestrator/{dependency_id}.md"
            if dependency_path in files:
                dep_fields, _ = _split_ticket(files[dependency_path])
                dependency_summaries.append(
                    {
                        "ticket_id": dependency_id,
                        "artifact_id": dep_fields.get("artifact_id"),
                        "title": dep_fields.get("title", dependency_id),
                        "status": dep_fields.get("status", "unknown"),
                        "activity_at": dep_fields.get("activity_at"),
                        "archived": False,
                    }
                )
                continue
            archived = next(
                (entry for entry in catalog.values() if entry.get("ticket_id") == dependency_id),
                None,
            )
            if archived is None:
                raise ArtifactValidationError(
                    f"required dependency {dependency_id} is absent from artifact snapshot and catalog"
                )
            dependency_summaries.append(
                {
                    "ticket_id": dependency_id,
                    "artifact_id": archived.get("artifact_id"),
                    "title": archived.get("title", dependency_id),
                    "status": archived.get("status", "unknown"),
                    "activity_at": archived.get("activity_at"),
                    "archived": True,
                }
            )
        for summary in dependency_summaries:
            path = f".orchestrator/dependencies/{summary['ticket_id']}.json"
            selected[path] = (_canonical_json(summary) + "\n").encode("utf-8")
        manifest = {
            "schema_version": SNAPSHOT_SCHEMA_VERSION,
            "project_id": self.store.project_id,
            "ticket_id": ticket_id,
            "artifact_id": artifact_id,
            "artifact_head": artifact_head,
            "run_id": run_id,
            "provider": provider,
            "source_start_head": _git_text(workspace_path, "rev-parse", "HEAD"),
            "files": {
                path: {
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "bytes": len(content),
                }
                for path, content in sorted(selected.items())
            },
        }
        manifest_path_relative = ".orchestrator/.artifact-snapshot.json"
        selected[manifest_path_relative] = (_canonical_json(manifest) + "\n").encode("utf-8")
        try:
            for relative, content in sorted(selected.items()):
                target = workspace_path / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                temporary = target.with_name(target.name + f".{uuid.uuid4().hex}.tmp")
                temporary.write_bytes(content)
                os.replace(temporary, target)
                target.chmod(0o444)
            for directory in sorted(
                (path for path in destination.rglob("*") if path.is_dir()),
                key=lambda path: len(path.parts),
                reverse=True,
            ):
                directory.chmod(0o555)
            destination.chmod(0o555)
        except OSError as error:
            _make_writable(destination)
            shutil.rmtree(destination, ignore_errors=True)
            raise ArtifactValidationError(f"could not materialize immutable worker snapshot: {error}") from error
        return workspace_path / manifest_path_relative, tuple(sorted(selected))

    def _validate_outcome(
        self,
        run_id: int,
        ticket_id: str,
        provider: str,
        payload: Mapping[str, object],
    ) -> StructuredWorkerOutcome:
        if run_id <= 0:
            raise ArtifactValidationError("outcome run ID must be positive")
        ticket_id = _safe_id(ticket_id, "ticket ID")
        self._validate_provider(provider)
        forbidden = _find_forbidden_keys(payload)
        if forbidden:
            raise ArtifactValidationError(
                "structured outcome contains prohibited Git content: " + ", ".join(sorted(forbidden))
            )
        allowed_keys = {
            "schema_version",
            "project_id",
            "ticket_id",
            "run_id",
            "provider",
            "status",
            "summary",
            "changed_paths",
            "verification",
            "source_commit",
            "verification_blocker",
            "verification_resume",
        }
        extra_keys = sorted(set(payload) - allowed_keys)
        if extra_keys:
            raise ArtifactValidationError(
                "structured outcome contains unknown fields: " + ", ".join(extra_keys)
            )
        if payload.get("schema_version", OUTCOME_SCHEMA_VERSION) != OUTCOME_SCHEMA_VERSION:
            raise ArtifactValidationError("structured outcome schema version is invalid")
        if payload.get("run_id", run_id) != run_id or payload.get("ticket_id", ticket_id) != ticket_id:
            raise ArtifactValidationError("structured outcome identity does not match its endpoint")
        if payload.get("project_id", self.store.project_id) != self.store.project_id:
            raise ArtifactValidationError("structured outcome belongs to another project")
        if payload.get("provider", provider) != provider:
            raise ArtifactValidationError("structured outcome provider does not match the run")
        try:
            status = WorkerOutcomeStatus(str(payload.get("status") or ""))
        except ValueError as error:
            raise ArtifactValidationError("structured outcome status is invalid") from error
        summary = _bounded_text(payload.get("summary"), "outcome summary", MAX_SUMMARY_BYTES)
        raw_verification = payload.get("verification")
        if not isinstance(raw_verification, list):
            raise ArtifactValidationError("structured outcome verification must be a list")
        verification = tuple(
            _bounded_text(item, "verification item", MAX_VERIFICATION_BYTES)
            for item in raw_verification
        )
        if sum(len(item.encode("utf-8")) for item in verification) > MAX_VERIFICATION_BYTES:
            raise ArtifactValidationError("structured outcome verification exceeds its total bound")
        raw_paths = payload.get("changed_paths")
        if not isinstance(raw_paths, list) or not raw_paths or len(raw_paths) > MAX_CHANGED_PATHS:
            raise ArtifactValidationError("structured outcome changed_paths is empty or exceeds its bound")
        changed_paths = tuple(sorted({_validate_source_path(item) for item in raw_paths}))
        if len(changed_paths) != len(raw_paths):
            raise ArtifactValidationError("structured outcome changed_paths contains duplicates")
        source_commit = str(payload.get("source_commit") or "")
        if not _OID_RE.fullmatch(source_commit):
            raise ArtifactValidationError("structured outcome source_commit is invalid")
        blocker = _optional_bounded(payload.get("verification_blocker"), MAX_SUMMARY_BYTES)
        resume = _optional_bounded(payload.get("verification_resume"), MAX_SUMMARY_BYTES)
        if status == WorkerOutcomeStatus.VERIFICATION_BLOCKED and (not blocker or not resume):
            raise ArtifactValidationError(
                "verification-blocked outcome requires blocker and explicit resume condition"
            )
        if status == WorkerOutcomeStatus.COMPLETED and (blocker or resume):
            raise ArtifactValidationError("completed outcome cannot carry verification blocker metadata")
        encoded = _canonical_json(payload).encode("utf-8")
        _reject_secrets(encoded, "structured worker outcome")
        return StructuredWorkerOutcome(
            schema_version=OUTCOME_SCHEMA_VERSION,
            project_id=self.store.project_id,
            ticket_id=ticket_id,
            run_id=run_id,
            provider=provider,
            status=status,
            summary=summary,
            changed_paths=changed_paths,
            verification=verification,
            source_commit=source_commit,
            verification_blocker=blocker,
            verification_resume=resume,
        )

    def _update_ticket_event(
        self,
        *,
        run_id: int,
        ticket_id: str,
        provider: str,
        event_id: str,
        status: str,
        run_state: str,
        clear_run_id: bool,
        log_summary: str,
        clear_verification: bool = False,
    ) -> LifecycleWriteResult:
        self._validate_provider(provider)
        prior = self._prior_event(event_id)
        if prior is not None:
            return prior
        snapshot = self.store.snapshot()
        path = f".orchestrator/{ticket_id}.md"
        content = snapshot.files.get(path)
        if content is None:
            raise ArtifactValidationError(f"canonical ticket {ticket_id} is missing")
        fields, _ = _split_ticket(content)
        current_run_id = fields.get("run_id", "").strip().lower()
        if current_run_id != str(run_id):
            unclaimed_failure = (
                run_state == "failed"
                and current_run_id in {"", "null"}
                and fields.get("status") in {"backlog", "ready"}
            )
            if not unclaimed_failure:
                raise ArtifactValidationError(
                    f"canonical ticket {ticket_id} no longer belongs to run {run_id}"
                )
        artifact_id = fields.get("artifact_id")
        if not artifact_id:
            raise ArtifactValidationError(f"ticket {ticket_id} has no immutable artifact_id")
        instant = _format_instant(self.now())
        updates: dict[str, str | None] = {
            "status": status,
            "run_id": None if clear_run_id else str(run_id),
            "run_state": run_state,
            "run_outcome_at": instant,
            "activity_at": instant,
        }
        if clear_verification:
            updates["verification_blocker"] = None
            updates["verification_resume"] = None
        updated = _append_run_log(
            _rewrite_ticket(content, updates),
            run_id,
            _bounded_text(log_summary, "run summary", MAX_SUMMARY_BYTES),
        )
        write = self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type="system",
                device_id=self.device_id,
                provider=provider,
                expected_base=snapshot.commit_id,
                operations=(TicketWrite(ticket_id, artifact_id, updated),),
                summary=f"Record {run_state} for {ticket_id} run {run_id}",
            )
        )
        return LifecycleWriteResult(event_id, write.commit_id, idempotent=write.idempotent)

    def _prior_event(self, event_id: str) -> LifecycleWriteResult | None:
        prior = self.store._find_event(event_id)
        if prior is None:
            return None
        return LifecycleWriteResult(
            event_id=event_id,
            commit_id=prior[0],
            idempotent=True,
        )

    def _run_summary(self, outcome: StructuredWorkerOutcome, merged_source_commit: str) -> str:
        verification = "; ".join(outcome.verification) if outcome.verification else "No verification recorded."
        return _bounded_text(
            f"reviewed source merge {merged_source_commit}: {outcome.summary} Verification: {verification}",
            "run summary",
            MAX_SUMMARY_BYTES,
        )

    def _status_map(self, files: Mapping[str, bytes]) -> dict[str, str]:
        statuses = {}
        for path, content in files.items():
            if _is_ticket_path(path):
                fields, _ = _split_ticket(content)
                statuses[PurePosixPath(path).stem] = fields.get("status", "backlog")
        for entry in _catalog(files).values():
            statuses.setdefault(str(entry.get("ticket_id")), str(entry.get("status", "")))
        return statuses

    def _registry_record(self) -> tuple[Mapping[str, object], int]:
        try:
            document = json.loads(self.registry_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"confirmed project registry is unavailable: {error}") from error
        schema = document.get("schema_version")
        if schema != 2:
            raise ArtifactValidationError("confirmed project registry schema is invalid")
        matches = [
            item for item in document.get("projects", [])
            if isinstance(item, dict) and item.get("project_id") == self.store.project_id
        ]
        if len(matches) != 1:
            raise ArtifactValidationError("project is missing or duplicated in registry-v2")
        record = matches[0]
        if record.get("availability") != "available":
            raise ArtifactValidationError(
                f"confirmed project is unavailable: {record.get('availability')!r}"
            )
        if Path(str(record.get("last_resolved_path") or "")).resolve() != self.store.repo_path:
            raise ArtifactValidationError("registered project path does not match artifact repository")
        return record, schema

    def _lease_for_run(self, run_id: int, role: str):
        lease_id = f"run:{run_id}:{role}"
        matches = [lease for lease in self.leases.active() if lease.lease_id == lease_id]
        if len(matches) != 1:
            raise ArtifactValidationError(f"run {run_id} has no active {role} snapshot lease")
        return matches[0]

    def _release_if_active(self, lease_id: str, reason: str) -> None:
        if any(lease.lease_id == lease_id for lease in self.leases.active()):
            self.leases.release(lease_id, terminal_reason=reason, now=self.now())

    def _release_run_leases(self, run_id: int, reason: str) -> None:
        for role in ("worker", "reviewer"):
            self._release_if_active(f"run:{run_id}:{role}", reason)
        self._remove_snapshot_proof(run_id)

    def _outcome_path(self, run_id: int) -> Path:
        return self.outcome_root / f"run-{run_id}.json"

    def _snapshot_proof_path(self, run_id: int) -> Path:
        return self.snapshot_proof_root / f"run-{run_id}.json"

    def _write_snapshot_proof(
        self,
        *,
        run_id: int,
        artifact_head: str,
        manifest: bytes,
    ) -> None:
        payload = (_canonical_json({
            "run_id": run_id,
            "artifact_head": artifact_head,
            "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
        }) + "\n").encode("utf-8")
        path = self._snapshot_proof_path(run_id)
        with _outcome_lock(path):
            if path.exists():
                if path.read_bytes() != payload:
                    raise ArtifactValidationError(
                        f"run {run_id} already has a different immutable snapshot proof"
                    )
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
            temporary.write_bytes(payload)
            os.replace(temporary, path)

    def _remove_snapshot_proof(self, run_id: int) -> None:
        self._snapshot_proof_path(run_id).unlink(missing_ok=True)

    @staticmethod
    def _validate_provider(provider: str) -> None:
        if provider not in {"codex", "claude"}:
            raise ArtifactValidationError(f"unsupported worker provider: {provider!r}")


def _outcome_json(outcome: StructuredWorkerOutcome) -> dict[str, object]:
    return {
        "schema_version": outcome.schema_version,
        "project_id": outcome.project_id,
        "ticket_id": outcome.ticket_id,
        "run_id": outcome.run_id,
        "provider": outcome.provider,
        "status": outcome.status.value,
        "summary": outcome.summary,
        "changed_paths": list(outcome.changed_paths),
        "verification": list(outcome.verification),
        "source_commit": outcome.source_commit,
        "verification_blocker": outcome.verification_blocker,
        "verification_resume": outcome.verification_resume,
    }


def _split_ticket(content: bytes) -> tuple[dict[str, str], list[str]]:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ArtifactValidationError("ticket is not UTF-8") from error
    if not lines or lines[0].strip() != "---":
        raise ArtifactValidationError("ticket has no YAML front matter")
    fields: dict[str, str] = {}
    closing = None
    for index, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            closing = index
            break
        key, separator, value = line.partition(":")
        if separator:
            fields[key.strip()] = value.strip().strip("\"'")
    if closing is None:
        raise ArtifactValidationError("ticket front matter is not closed")
    return fields, lines[closing + 1 :]


def _rewrite_ticket(content: bytes, updates: Mapping[str, str | None]) -> bytes:
    lines = content.decode("utf-8").splitlines()
    closing = next(
        (index for index, line in enumerate(lines[1:], 1) if line.strip() == "---"),
        None,
    )
    if closing is None:
        raise ArtifactValidationError("ticket front matter is not closed")
    rewritten = [lines[0]]
    handled: set[str] = set()
    for line in lines[1:closing]:
        key, separator, _ = line.partition(":")
        normalized = key.strip() if separator else ""
        if normalized in updates:
            handled.add(normalized)
            value = updates[normalized]
            if value is not None:
                rewritten.append(f"{normalized}: {value}")
        else:
            rewritten.append(line)
    for key, value in updates.items():
        if key not in handled and value is not None:
            rewritten.append(f"{key}: {value}")
    rewritten.extend(lines[closing:])
    return ("\n".join(rewritten).rstrip("\n") + "\n").encode("utf-8")


def _append_run_log(content: bytes, run_id: int, summary: str) -> bytes:
    text = content.decode("utf-8").rstrip()
    entry = f"- **Run {run_id}** — {summary}"
    if "## Run log" in text:
        text += "\n" + entry
    else:
        text += "\n\n## Run log\n\n" + entry
    return (text + "\n").encode("utf-8")


def _catalog(files: Mapping[str, bytes]) -> dict[str, dict[str, object]]:
    result = {}
    for line in files.get(".orchestrator/archive-index.jsonl", b"").decode("utf-8").splitlines():
        if line.strip():
            entry = json.loads(line)
            if isinstance(entry, dict) and isinstance(entry.get("artifact_id"), str):
                result[str(entry["artifact_id"])] = entry
    return result


def _is_ticket_path(path: str) -> bool:
    return (
        path.startswith(".orchestrator/")
        and path.endswith(".md")
        and "/" not in path.removeprefix(".orchestrator/")
    )


def _is_lifecycle_path(path: str) -> bool:
    normalized = path.replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized == ".orchestrator" or normalized.startswith(".orchestrator/") or normalized == ".relay" or normalized.startswith(".relay/")


def _validate_source_path(value: object) -> str:
    path = str(value or "").replace("\\", "/").strip()
    pure = PurePosixPath(path)
    if (
        not path
        or pure.is_absolute()
        or ".." in pure.parts
        or any(ord(character) < 32 for character in path)
        or _is_lifecycle_path(path)
    ):
        raise ArtifactValidationError(f"invalid source changed path: {path!r}")
    return path


def _parse_list(value: str) -> tuple[str, ...]:
    value = value.strip()
    if not value or value == "[]":
        return ()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    return tuple(
        item.strip().strip("\"'")
        for item in value.split(",")
        if item.strip().strip("\"'")
    )


def _safe_id(value: str, label: str) -> str:
    if not _ID_RE.fullmatch(value):
        raise ArtifactValidationError(f"invalid {label}: {value!r}")
    return value


def _bounded_text(value: object, label: str, maximum: int) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if not text:
        raise ArtifactValidationError(f"{label} is required")
    if len(text.encode("utf-8")) > maximum:
        raise ArtifactValidationError(f"{label} exceeds {maximum} bytes")
    _reject_secrets(text.encode("utf-8"), label)
    lowered = text.lower()
    if any(marker in lowered for marker in ("hidden reasoning", "raw transcript", "raw log", "tool output")):
        raise ArtifactValidationError(f"{label} contains prohibited private runtime content")
    return text


def _optional_bounded(value: object, maximum: int) -> str | None:
    if value is None or not str(value).strip():
        return None
    return _bounded_text(value, "optional outcome field", maximum)


def _canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _format_instant(value: datetime) -> str:
    if value.tzinfo is None:
        raise ArtifactValidationError("lifecycle timestamp must be timezone-aware")
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _registry_timestamp(value: object) -> float:
    if not isinstance(value, str):
        raise ArtifactValidationError("registry record has no updated_at timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ArtifactValidationError("registry updated_at timestamp is invalid") from error
    if parsed.tzinfo is None:
        raise ArtifactValidationError("registry updated_at timestamp has no offset")
    return round(parsed.timestamp(), 6)


def _truthy(value: str) -> bool:
    return value.lower() in {"true", "yes", "1"}


def _git_text(repo: Path, *arguments: str) -> str:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise ArtifactValidationError(
            f"git {' '.join(arguments)} failed: {process.stderr.decode(errors='replace').strip()}"
        )
    return process.stdout.decode("utf-8", errors="replace").strip()


def _git_is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    process = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return process.returncode == 0


def _make_writable(path: Path) -> None:
    if not path.exists() or path.is_symlink():
        return
    for root, directories, filenames in os.walk(path):
        root_path = Path(root)
        root_path.chmod(root_path.stat().st_mode | 0o700)
        for name in [*directories, *filenames]:
            child = root_path / name
            if not child.is_symlink():
                child.chmod(child.stat().st_mode | 0o700)


def _outcome_lock(path: Path) -> threading.RLock:
    key = str(path)
    with _outcome_locks_guard:
        return _outcome_locks.setdefault(key, threading.RLock())


__all__ = [
    "ArtifactLifecycleCoordinator",
    "ArtifactWorkerSnapshot",
    "LifecycleWriteResult",
    "ScopeValidation",
    "StructuredWorkerOutcome",
    "WorkerOutcomeStatus",
]
