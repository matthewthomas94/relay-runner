#!/usr/bin/env python3
"""Exact-ref, no-force synchronization for Relay artifact histories."""

from __future__ import annotations

import contextlib
import dataclasses
import enum
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
import tomllib
import uuid
from pathlib import Path
from typing import Callable, Iterator, Mapping, Sequence

from services.artifact_store import (
    ARTIFACT_REF,
    ArtifactConcurrentUpdate,
    ArtifactIdentityError,
    ArtifactMaterializationConflict,
    ArtifactStore,
    ArtifactStoreError,
    ArtifactValidationError,
    _parse_trailers,
    _validate_actor,
    _validate_allowlisted_path,
    _validate_event_id,
)


class ArtifactSyncMode(str, enum.Enum):
    LOCAL_ONLY = "local_only"
    ENABLED = "enabled"
    PAUSED = "paused"


class ArtifactSyncState(str, enum.Enum):
    LOCAL_ONLY = "local_only"
    PAUSED = "paused"
    CLEAN = "clean"
    AHEAD = "ahead"
    BEHIND = "behind"
    SYNCING = "syncing"
    RETRYABLE_OFFLINE = "retryable_offline"
    RETRYABLE_AUTH = "retryable_auth"
    MISSING_REMOTE_REF = "missing_remote_ref"
    PROTECTED_REF = "protected_ref"
    FOREIGN_REF = "foreign_ref"
    LOCAL_AHEAD_BLOCKED = "local_ahead_fail_closed"
    CONFLICT = "conflict"
    FAILED = "failed"


@dataclasses.dataclass(frozen=True)
class ArtifactConflict:
    path: str
    kind: str
    base_oid: str | None
    local_oid: str | None
    remote_oid: str | None
    recovery: str


@dataclasses.dataclass(frozen=True)
class ArtifactConflictReport:
    project_id: str
    merge_base: str
    local_head: str
    remote_head: str
    local_events: tuple[tuple[str, str], ...]
    conflicts: tuple[ArtifactConflict, ...]


@dataclasses.dataclass(frozen=True)
class ArtifactSyncResult:
    state: ArtifactSyncState
    observed_state: ArtifactSyncState
    transitions: tuple[ArtifactSyncState, ...]
    attempts: int
    local_head: str | None
    remote_head: str | None
    recovery: str | None = None
    conflict_report: ArtifactConflictReport | None = None


@dataclasses.dataclass(frozen=True)
class _RemoteSnapshot:
    head: str | None
    quarantine: Path | None
    error_state: ArtifactSyncState | None = None
    recovery: str | None = None


class ArtifactSyncEngine:
    """Synchronizes one explicitly configured artifact ref and nothing else."""

    def __init__(
        self,
        store: ArtifactStore,
        *,
        mode: ArtifactSyncMode,
        remote_name: str | None,
        max_attempts: int = 3,
        base_retry_seconds: float = 0.25,
        sleep: Callable[[float], None] = time.sleep,
        jitter: Callable[[], float] = random.random,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        if mode == ArtifactSyncMode.ENABLED and not remote_name:
            raise ArtifactValidationError(
                "sync requires an explicitly selected existing remote or Local only"
            )
        if mode == ArtifactSyncMode.LOCAL_ONLY and remote_name is not None:
            raise ArtifactValidationError("Local only cannot carry an inferred remote")
        if remote_name is not None and not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", remote_name):
            raise ArtifactValidationError(f"invalid configured remote name: {remote_name!r}")
        self.store = store
        self.mode = mode
        self.remote_name = remote_name
        self.max_attempts = max(1, min(max_attempts, 8))
        self.base_retry_seconds = max(0.0, base_retry_seconds)
        self.sleep = sleep
        self.jitter = jitter
        self.failure_injector = failure_injector
        self.state_path = store.project_state / "sync-state.json"

    def status(self) -> ArtifactSyncResult:
        if self.mode == ArtifactSyncMode.LOCAL_ONLY:
            return self._finish(
                ArtifactSyncState.LOCAL_ONLY,
                ArtifactSyncState.LOCAL_ONLY,
                0,
                self.store._head(),
                None,
                transitions=(ArtifactSyncState.LOCAL_ONLY,),
            )
        if self.mode == ArtifactSyncMode.PAUSED:
            return self._finish(
                ArtifactSyncState.PAUSED,
                ArtifactSyncState.PAUSED,
                0,
                self.store._head(),
                None,
                transitions=(ArtifactSyncState.PAUSED,),
            )
        return self._synchronize(publish=False)

    def sync(self) -> ArtifactSyncResult:
        if self.mode != ArtifactSyncMode.ENABLED:
            return self.status()
        return self._synchronize(publish=True)

    def publish_initial(self, *, confirmed: bool) -> ArtifactSyncResult:
        """Create a missing remote artifact ref only after explicit confirmation."""
        if self.mode != ArtifactSyncMode.ENABLED:
            return self.status()
        local_head = self.store._head()
        if not local_head:
            raise ArtifactValidationError("artifact store is not initialized")
        self._validate_configuration(local_head)
        if not confirmed:
            return self._finish(
                ArtifactSyncState.MISSING_REMOTE_REF,
                ArtifactSyncState.MISSING_REMOTE_REF,
                0,
                local_head,
                None,
                recovery="Confirm the first normal push or choose Local only.",
                transitions=(ArtifactSyncState.MISSING_REMOTE_REF,),
            )
        with self._remote_snapshot() as remote:
            if remote.error_state not in {None, ArtifactSyncState.MISSING_REMOTE_REF}:
                return self._remote_error_result(remote, local_head, attempts=1)
            if remote.head is not None:
                return self.sync()
        blocked = self._validate_local_commits(None, local_head)
        if blocked:
            return self._finish(
                ArtifactSyncState.LOCAL_AHEAD_BLOCKED,
                ArtifactSyncState.AHEAD,
                1,
                local_head,
                None,
                recovery=blocked,
                transitions=(ArtifactSyncState.AHEAD, ArtifactSyncState.LOCAL_AHEAD_BLOCKED),
            )
        push = self._push(local_head)
        if push is not None:
            state, recovery = push
            return self._finish(
                state,
                ArtifactSyncState.AHEAD,
                1,
                local_head,
                None,
                recovery=recovery,
                transitions=(ArtifactSyncState.AHEAD, ArtifactSyncState.SYNCING, state),
            )
        return self._finish(
            ArtifactSyncState.CLEAN,
            ArtifactSyncState.AHEAD,
            1,
            local_head,
            local_head,
            transitions=(ArtifactSyncState.AHEAD, ArtifactSyncState.SYNCING, ArtifactSyncState.CLEAN),
        )

    def resolve_conflict(
        self,
        report: ArtifactConflictReport,
        decisions: Mapping[str, str | bytes],
        *,
        resolution_event_id: str,
        device_id: str,
        actor_type: str = "user",
        provider: str | None = None,
    ) -> ArtifactSyncResult:
        """Publish an explicit three-way resolution as a normal FF commit.

        Decisions are ``local``, ``remote``, ``delete``, or caller-supplied
        merged bytes for every conflicting path.  The resulting commit records
        each reconciled immutable event ID/digest so retries remain idempotent.
        """
        if self.mode != ArtifactSyncMode.ENABLED:
            raise ArtifactValidationError("conflict resolution requires enabled sync")
        _validate_event_id(resolution_event_id, "resolution event ID")
        _validate_event_id(device_id, "device ID")
        _validate_actor(actor_type)
        if provider not in {None, "codex", "claude"}:
            raise ArtifactValidationError(f"unsupported provider metadata: {provider!r}")
        if report.project_id != self.store.project_id:
            raise ArtifactIdentityError("conflict report belongs to another project")
        if any(conflict.kind == "unrelated_history" for conflict in report.conflicts):
            raise ArtifactValidationError(
                "unrelated artifact histories require explicit identity-preserving recovery"
            )
        required = {conflict.path for conflict in report.conflicts}
        if set(decisions) != required:
            missing = sorted(required - set(decisions))
            extra = sorted(set(decisions) - required)
            raise ArtifactValidationError(
                f"resolution must decide every conflict exactly once; missing={missing}, extra={extra}"
            )
        with self.store._writer_lock():
            if self.store._head() != report.local_head:
                raise ArtifactConcurrentUpdate("local artifact head changed since conflict review")
            with self._remote_snapshot() as remote:
                if remote.error_state:
                    return self._remote_error_result(remote, report.local_head, attempts=1)
                if remote.head != report.remote_head:
                    raise ArtifactConcurrentUpdate("remote artifact head changed since conflict review")
            self.store._ensure_materialization_consistent(report.local_head)
            final_entries = self._resolved_entries(report, decisions)
            tree_id = self._write_tree(report.remote_head, final_entries)
            digest = self._resolution_digest(report, decisions)
            message = self._resolution_message(
                report,
                resolution_event_id,
                digest,
                device_id,
                actor_type,
                provider,
            )
            commit_id = self.store._git(
                "commit-tree",
                tree_id,
                "-p",
                report.remote_head,
                input_bytes=message.encode("utf-8"),
            ).stdout.strip()
            update = self.store._git(
                "update-ref",
                self.store.artifact_ref,
                commit_id,
                report.local_head,
                allowed_statuses={0, 128},
            )
            if update.returncode != 0:
                raise ArtifactConcurrentUpdate("local artifact CAS failed during conflict resolution")
            push = self._push(commit_id)
            if push is not None:
                state, recovery = push
                self.store._materialize(commit_id)
                return self._finish(
                    state,
                    ArtifactSyncState.CONFLICT,
                    1,
                    commit_id,
                    report.remote_head,
                    recovery=recovery,
                    transitions=(ArtifactSyncState.CONFLICT, ArtifactSyncState.SYNCING, state),
                )
            self.store._materialize(commit_id)
            return self._finish(
                ArtifactSyncState.CLEAN,
                ArtifactSyncState.CONFLICT,
                1,
                commit_id,
                commit_id,
                transitions=(
                    ArtifactSyncState.CONFLICT,
                    ArtifactSyncState.SYNCING,
                    ArtifactSyncState.CLEAN,
                ),
            )

    def _synchronize(self, *, publish: bool) -> ArtifactSyncResult:
        local_head = self.store._head()
        if not local_head:
            raise ArtifactValidationError("artifact store is not initialized")
        self._validate_configuration(local_head)
        last_result: ArtifactSyncResult | None = None
        for attempt in range(1, self.max_attempts + 1):
            with self.store._writer_lock():
                result = self._sync_once(
                    local_head=self.store._head() or local_head,
                    publish=publish,
                    attempt=attempt,
                )
            last_result = result
            if result.state not in {
                ArtifactSyncState.RETRYABLE_OFFLINE,
                ArtifactSyncState.RETRYABLE_AUTH,
                ArtifactSyncState.AHEAD,
            }:
                return result
            if not publish or attempt >= self.max_attempts:
                return result
            delay = self.base_retry_seconds * (2 ** (attempt - 1))
            delay *= 0.75 + (self.jitter() * 0.5)
            self.sleep(delay)
        assert last_result is not None
        return last_result

    def _sync_once(self, *, local_head: str, publish: bool, attempt: int) -> ArtifactSyncResult:
        with self._remote_snapshot() as remote:
            if remote.error_state:
                return self._remote_error_result(remote, local_head, attempts=attempt)
            assert remote.head is not None
            remote_head = remote.head
            observed = self._relationship(local_head, remote_head)
            transitions = [observed]
            if not publish:
                return self._finish(
                    observed,
                    observed,
                    attempt,
                    local_head,
                    remote_head,
                    transitions=tuple(transitions),
                )
            transitions.append(ArtifactSyncState.SYNCING)

            if observed == ArtifactSyncState.CLEAN:
                candidate = local_head
            elif observed == ArtifactSyncState.BEHIND:
                self.store._ensure_materialization_consistent(local_head)
                update = self.store._git(
                    "update-ref",
                    self.store.artifact_ref,
                    remote_head,
                    local_head,
                    allowed_statuses={0, 128},
                )
                if update.returncode != 0:
                    return self._finish(
                        ArtifactSyncState.AHEAD,
                        observed,
                        attempt,
                        self.store._head(),
                        remote_head,
                        recovery="Local artifact head changed during sync; retry is bounded.",
                        transitions=tuple(transitions + [ArtifactSyncState.AHEAD]),
                    )
                candidate = remote_head
            elif observed == ArtifactSyncState.AHEAD:
                blocked = self._validate_local_commits(remote_head, local_head)
                if blocked:
                    return self._finish(
                        ArtifactSyncState.LOCAL_AHEAD_BLOCKED,
                        observed,
                        attempt,
                        local_head,
                        remote_head,
                        recovery=blocked,
                        transitions=tuple(transitions + [ArtifactSyncState.LOCAL_AHEAD_BLOCKED]),
                    )
                candidate = local_head
            else:
                self.store._ensure_materialization_consistent(local_head)
                replay = self._rebase_unpublished(local_head, remote_head)
                if isinstance(replay, ArtifactConflictReport):
                    return self._finish(
                        ArtifactSyncState.CONFLICT,
                        ArtifactSyncState.CONFLICT,
                        attempt,
                        local_head,
                        remote_head,
                        recovery="Review three-way evidence and explicitly choose local, remote, delete, or merged bytes for every path.",
                        conflict_report=replay,
                        transitions=tuple(transitions + [ArtifactSyncState.CONFLICT]),
                    )
                if isinstance(replay, str) and replay.startswith("blocked:"):
                    return self._finish(
                        ArtifactSyncState.LOCAL_AHEAD_BLOCKED,
                        ArtifactSyncState.AHEAD,
                        attempt,
                        local_head,
                        remote_head,
                        recovery=replay.removeprefix("blocked:"),
                        transitions=tuple(transitions + [ArtifactSyncState.LOCAL_AHEAD_BLOCKED]),
                    )
                candidate = replay

            self._inject("before_push")
            push = self._push(candidate)
            if push is not None:
                state, recovery = push
                retry_state = ArtifactSyncState.AHEAD if state == ArtifactSyncState.AHEAD else state
                return self._finish(
                    retry_state,
                    observed,
                    attempt,
                    self.store._head(),
                    remote_head,
                    recovery=recovery,
                    transitions=tuple(transitions + [retry_state]),
                )
            self.store._materialize(candidate)
            return self._finish(
                ArtifactSyncState.CLEAN,
                observed,
                attempt,
                candidate,
                candidate,
                transitions=tuple(transitions + [ArtifactSyncState.CLEAN]),
            )

    def _rebase_unpublished(
        self,
        local_head: str,
        remote_head: str,
    ) -> str | ArtifactConflictReport:
        merge_base = self._merge_base(local_head, remote_head)
        if not merge_base:
            return self._aggregate_conflict_report(
                local_head,
                remote_head,
                local_head,
                kind_override="unrelated_history",
            )
        blocked = self._validate_local_commits(merge_base, local_head)
        if blocked:
            return "blocked:" + blocked
        local_commits = self._commits_since(merge_base, local_head)
        remote_events = self._event_map(remote_head)
        replay_base = remote_head
        for commit in local_commits:
            trailers = self._trailers(commit)
            event_id = trailers["Relay-Event-ID"]
            digest = trailers["Relay-Event-Digest"]
            if event_id in remote_events:
                if remote_events[event_id] != digest:
                    return self._aggregate_conflict_report(
                        local_head,
                        remote_head,
                        merge_base,
                        kind_override="event_id_collision",
                    )
                continue
            parent = self.store._first_parent(commit)
            assert parent is not None
            parent_entries = self.store._tree_entries(parent)
            commit_entries = self.store._tree_entries(commit)
            replay_entries = self.store._tree_entries(replay_base)
            changes = self._changed_entries(parent_entries, commit_entries)
            conflicts = self._path_conflicts(changes, replay_entries)
            if conflicts:
                return ArtifactConflictReport(
                    project_id=self.store.project_id,
                    merge_base=merge_base,
                    local_head=local_head,
                    remote_head=remote_head,
                    local_events=tuple(
                        (self._trailers(item)["Relay-Event-ID"], self._trailers(item)["Relay-Event-Digest"])
                        for item in local_commits
                    ),
                    conflicts=tuple(conflicts),
                )
            new_entries = dict(replay_entries)
            for path, (_, new_oid) in changes.items():
                if new_oid is None:
                    new_entries.pop(path, None)
                else:
                    new_entries[path] = commit_entries[path]
            tree_id = self._write_tree(replay_base, new_entries)
            message = self.store._git("show", "-s", "--format=%B", commit).stdout
            replay_base = self.store._git(
                "commit-tree",
                tree_id,
                "-p",
                replay_base,
                input_bytes=message.encode("utf-8"),
            ).stdout.strip()

        update = self.store._git(
            "update-ref",
            self.store.artifact_ref,
            replay_base,
            local_head,
            allowed_statuses={0, 128},
        )
        if update.returncode != 0:
            raise ArtifactConcurrentUpdate("local artifact CAS failed during unpublished rebase")
        self.store._materialize(replay_base)
        return replay_base

    def _aggregate_conflict_report(
        self,
        local_head: str,
        remote_head: str,
        merge_base: str,
        *,
        kind_override: str | None = None,
    ) -> ArtifactConflictReport:
        base = self.store._tree_entries(merge_base)
        local = self.store._tree_entries(local_head)
        remote = self.store._tree_entries(remote_head)
        conflicts: list[ArtifactConflict] = []
        for path in sorted(set(base) | set(local) | set(remote)):
            base_oid = base.get(path).oid if path in base else None
            local_oid = local.get(path).oid if path in local else None
            remote_oid = remote.get(path).oid if path in remote else None
            if local_oid in {base_oid, remote_oid} or remote_oid == base_oid:
                continue
            conflicts.append(
                ArtifactConflict(
                    path=path,
                    kind=kind_override or self._conflict_kind(path, base_oid, local_oid, remote_oid),
                    base_oid=base_oid,
                    local_oid=local_oid,
                    remote_oid=remote_oid,
                    recovery="Choose the local bytes, remote bytes, deletion, or reviewed merged bytes.",
                )
            )
        if not conflicts:
            conflicts.append(
                ArtifactConflict(
                    path=".orchestrator/config.toml",
                    kind=kind_override or "history_conflict",
                    base_oid=None,
                    local_oid=None,
                    remote_oid=None,
                    recovery="Inspect the unrelated artifact histories and select an explicit identity-preserving recovery.",
                )
            )
        local_events = []
        for commit in self._commits_since(merge_base, local_head):
            trailers = self._trailers(commit)
            if "Relay-Event-ID" in trailers and "Relay-Event-Digest" in trailers:
                local_events.append((trailers["Relay-Event-ID"], trailers["Relay-Event-Digest"]))
        return ArtifactConflictReport(
            project_id=self.store.project_id,
            merge_base=merge_base,
            local_head=local_head,
            remote_head=remote_head,
            local_events=tuple(local_events),
            conflicts=tuple(conflicts),
        )

    def _resolved_entries(
        self,
        report: ArtifactConflictReport,
        decisions: Mapping[str, str | bytes],
    ) -> dict[str, object]:
        base = self.store._tree_entries(report.merge_base)
        local = self.store._tree_entries(report.local_head)
        remote = self.store._tree_entries(report.remote_head)
        final: dict[str, object] = dict(remote)
        conflict_paths = {conflict.path for conflict in report.conflicts}
        for path in sorted(set(base) | set(local) | set(remote)):
            base_oid = base.get(path).oid if path in base else None
            local_oid = local.get(path).oid if path in local else None
            remote_oid = remote.get(path).oid if path in remote else None
            if local_oid == base_oid or local_oid == remote_oid:
                continue
            if remote_oid == base_oid:
                if path in local:
                    final[path] = local[path]
                else:
                    final.pop(path, None)
                continue
            if path not in conflict_paths:
                continue
            decision = decisions[path]
            if decision == "local":
                if path in local:
                    final[path] = local[path]
                else:
                    final.pop(path, None)
            elif decision == "remote":
                pass
            elif decision == "delete":
                final.pop(path, None)
            elif isinstance(decision, bytes):
                _validate_allowlisted_path(path)
                validated = self.store._validate_content_for_path(path, decision)
                blob = self.store._git(
                    "hash-object", "-w", "--stdin", input_bytes=validated
                ).stdout.strip()
                template = local.get(path) or remote.get(path) or base.get(path)
                if template is None:
                    raise ArtifactValidationError(f"cannot infer artifact mode for merged path {path}")
                final[path] = dataclasses.replace(template, mode="100644", kind="blob", oid=blob)
            else:
                raise ArtifactValidationError(f"invalid resolution for {path}: {decision!r}")
        return final

    def _changed_entries(self, old: Mapping[str, object], new: Mapping[str, object]):
        changes = {}
        for path in set(old) | set(new):
            old_oid = old[path].oid if path in old else None
            new_oid = new[path].oid if path in new else None
            if old_oid != new_oid:
                changes[path] = (old_oid, new_oid)
        return changes

    def _path_conflicts(self, changes, replay_entries) -> list[ArtifactConflict]:
        conflicts = []
        for path, (base_oid, local_oid) in sorted(changes.items()):
            remote_oid = replay_entries[path].oid if path in replay_entries else None
            if remote_oid in {base_oid, local_oid}:
                continue
            conflicts.append(
                ArtifactConflict(
                    path=path,
                    kind=self._conflict_kind(path, base_oid, local_oid, remote_oid),
                    base_oid=base_oid,
                    local_oid=local_oid,
                    remote_oid=remote_oid,
                    recovery="Review the base, local, and remote blob IDs before choosing a result.",
                )
            )
        return conflicts

    def _conflict_kind(
        self,
        path: str,
        base_oid: str | None,
        local_oid: str | None,
        remote_oid: str | None,
    ) -> str:
        if local_oid is None or remote_oid is None:
            return "delete_edit"
        if path == ".orchestrator/config.toml":
            return "config_collision"
        if path.startswith(".orchestrator/attachments/"):
            return "attachment_collision"
        if path.endswith(".md") and base_oid is None:
            return "display_id_collision"
        if path.endswith(".md"):
            return "same_ticket"
        return "artifact_path_collision"

    def _write_tree(self, base_commit: str, entries: Mapping[str, object]) -> str:
        with tempfile.TemporaryDirectory(prefix="relay-sync-index-") as directory:
            env = self.store._git_environment({"GIT_INDEX_FILE": str(Path(directory) / "index")})
            self.store._git("read-tree", "--empty", env=env)
            for path, entry in sorted(entries.items()):
                _validate_allowlisted_path(path)
                if entry.mode != "100644" or entry.kind != "blob":
                    raise ArtifactValidationError(f"resolution contains unsupported entry {path}")
                self.store._git(
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "100644",
                    entry.oid,
                    path,
                    env=env,
                )
            return self.store._git("write-tree", env=env).stdout.strip()

    def _validate_local_commits(self, base: str | None, head: str) -> str | None:
        commits = self._commits_since(base, head)
        for commit in commits:
            trailers = self._trailers(commit)
            if trailers.get("Relay-Project-ID") != self.store.project_id:
                return (
                    f"local artifact commit {commit} is not owned by project {self.store.project_id}; "
                    "inspect it before any publication"
                )
            for key in ("Relay-Event-ID", "Relay-Event-Digest", "Relay-Device-ID", "Relay-Actor-Type"):
                if not trailers.get(key):
                    return f"local artifact commit {commit} lacks required trailer {key}"
        return None

    def _commits_since(self, base: str | None, head: str) -> list[str]:
        revision = f"{base}..{head}" if base else head
        return self.store._git("rev-list", "--reverse", revision).stdout.splitlines()

    def _trailers(self, commit: str) -> dict[str, str]:
        return _parse_trailers(self.store._git("show", "-s", "--format=%B", commit).stdout)

    def _event_map(self, head: str) -> dict[str, str]:
        result = {}
        for commit in self.store._git("rev-list", head).stdout.splitlines():
            trailers = self._trailers(commit)
            event_id = trailers.get("Relay-Event-ID")
            digest = trailers.get("Relay-Event-Digest")
            if event_id and digest:
                result[event_id] = digest
            message = self.store._git("show", "-s", "--format=%B", commit).stdout
            for line in message.splitlines():
                if line.startswith("Relay-Resolved-Event: "):
                    parts = line.removeprefix("Relay-Resolved-Event: ").split(" ", 1)
                    if len(parts) == 2:
                        result[parts[0]] = parts[1]
        return result

    def _relationship(self, local_head: str, remote_head: str) -> ArtifactSyncState:
        if local_head == remote_head:
            return ArtifactSyncState.CLEAN
        if self._is_ancestor(remote_head, local_head):
            return ArtifactSyncState.AHEAD
        if self._is_ancestor(local_head, remote_head):
            return ArtifactSyncState.BEHIND
        return ArtifactSyncState.CONFLICT

    def _is_ancestor(self, ancestor: str, descendant: str) -> bool:
        result = self.store._git(
            "merge-base",
            "--is-ancestor",
            ancestor,
            descendant,
            allowed_statuses={0, 1, 128},
        )
        return result.returncode == 0

    def _merge_base(self, first: str, second: str) -> str | None:
        result = self.store._git(
            "merge-base", first, second, allowed_statuses={0, 1, 128}
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def _validate_configuration(self, head: str) -> None:
        self.store._validate_artifact_head(head)
        content = self.store._git(
            "show", f"{head}:.orchestrator/config.toml"
        ).stdout_bytes
        document = tomllib.loads(content.decode("utf-8"))
        if document.get("remote_sync") != self.mode.value:
            raise ArtifactValidationError(
                f"artifact config mode is {document.get('remote_sync')!r}, not {self.mode.value!r}"
            )
        configured_remote = document.get("remote_name")
        if self.mode == ArtifactSyncMode.ENABLED and configured_remote != self.remote_name:
            raise ArtifactValidationError(
                "sync remote must be selected explicitly in artifact configuration"
            )
        if self.remote_name:
            result = self.store._git(
                "remote", "get-url", self.remote_name, allowed_statuses={0, 2, 128}
            )
            if result.returncode != 0 or not result.stdout.strip():
                raise ArtifactValidationError(
                    f"configured existing remote {self.remote_name!r} is unavailable; Relay will not create it"
                )

    @contextlib.contextmanager
    def _remote_snapshot(self) -> Iterator[_RemoteSnapshot]:
        assert self.remote_name is not None
        remote_url_result = self.store._git(
            "remote", "get-url", self.remote_name, allowed_statuses={0, 2, 128}
        )
        if remote_url_result.returncode != 0:
            yield _RemoteSnapshot(
                None,
                None,
                ArtifactSyncState.FAILED,
                f"Configured remote {self.remote_name!r} no longer exists; select another existing remote or Local only.",
            )
            return
        remote_url = remote_url_result.stdout.strip()
        temporary = Path(tempfile.mkdtemp(prefix="relay-artifact-quarantine-"))
        quarantine = temporary / "remote.git"
        try:
            subprocess.run(
                ["git", "init", "--bare", "--quiet", str(quarantine)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            fetch = subprocess.run(
                [
                    "git",
                    "-C",
                    str(quarantine),
                    "fetch",
                    "--no-tags",
                    "--no-write-fetch-head",
                    "--no-recurse-submodules",
                    remote_url,
                    f"{self.store.artifact_ref}:{self.store.artifact_ref}",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.store._git_environment(),
                check=False,
            )
            if fetch.returncode != 0:
                state, recovery = self.classify_git_failure(
                    fetch.stderr.decode("utf-8", errors="replace"), operation="fetch"
                )
                yield _RemoteSnapshot(None, quarantine, state, recovery)
                return
            remote_head = self._quarantine_git(quarantine, "rev-parse", self.store.artifact_ref)
            try:
                self._validate_quarantine(quarantine, remote_head)
            except ArtifactIdentityError as error:
                yield _RemoteSnapshot(
                    remote_head,
                    quarantine,
                    ArtifactSyncState.FOREIGN_REF,
                    str(error),
                )
                return
            except ArtifactValidationError as error:
                yield _RemoteSnapshot(
                    remote_head,
                    quarantine,
                    ArtifactSyncState.FOREIGN_REF,
                    f"Remote artifact ref failed verification: {error}",
                )
                return
            scratch_ref = f"refs/relay-runner/sync/{self.store.project_id}/{uuid.uuid4().hex}"
            imported = self.store._git(
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                str(quarantine),
                f"{self.store.artifact_ref}:{scratch_ref}",
                allowed_statuses={0, 128},
            )
            if imported.returncode != 0:
                yield _RemoteSnapshot(
                    None,
                    quarantine,
                    ArtifactSyncState.FAILED,
                    "Verified artifact objects could not be imported into the local repository.",
                )
                return
            try:
                imported_head = self.store._git("rev-parse", scratch_ref).stdout.strip()
                if imported_head != remote_head:
                    yield _RemoteSnapshot(
                        None,
                        quarantine,
                        ArtifactSyncState.AHEAD,
                        "Remote artifact ref changed during quarantine; retry is bounded.",
                    )
                    return
                yield _RemoteSnapshot(remote_head, quarantine)
            finally:
                self.store._git(
                    "update-ref", "-d", scratch_ref, allowed_statuses={0, 128}
                )
        finally:
            shutil.rmtree(temporary, ignore_errors=True)

    def _validate_quarantine(self, repository: Path, head: str) -> None:
        history = [
            line.split()
            for line in self._quarantine_git(
                repository, "rev-list", "--reverse", "--parents", head
            ).splitlines()
        ]
        if not history or len(history[0]) != 1:
            raise ArtifactValidationError("remote artifact ref is not orphan-rooted")
        previous = history[0][0]
        for line in history[1:]:
            if len(line) != 2 or line[1] != previous:
                raise ArtifactValidationError("remote artifact history is not linear")
            previous = line[0]
        for line in history:
            output = self._quarantine_git_bytes(
                repository, "ls-tree", "-r", "-z", "--full-tree", line[0]
            )
            for record in output.split(b"\0"):
                if not record:
                    continue
                metadata, raw_path = record.split(b"\t", 1)
                mode, kind, oid = metadata.decode("ascii").split(" ", 2)
                path = raw_path.decode("utf-8")
                _validate_allowlisted_path(path)
                if mode != "100644" or kind != "blob":
                    raise ArtifactValidationError(
                        f"remote artifact contains unsupported {mode} {kind}: {path}"
                    )
                content = self._quarantine_git_bytes(repository, "cat-file", "blob", oid)
                self.store._validate_content_for_path(path, content)
        try:
            config = self._quarantine_git_bytes(
                repository, "show", f"{head}:.orchestrator/config.toml"
            )
        except ArtifactStoreError as error:
            raise ArtifactValidationError("remote artifact config is missing") from error
        document = tomllib.loads(config.decode("utf-8"))
        if document.get("project_id") != self.store.project_id:
            raise ArtifactIdentityError(
                f"remote artifact ref belongs to project {document.get('project_id')!r}"
            )
        if document.get("artifact_ref") != self.store.artifact_ref:
            raise ArtifactValidationError("remote artifact config names another ref")

    def _push(self, local_head: str) -> tuple[ArtifactSyncState, str] | None:
        assert self.remote_name is not None
        push = self.store._git(
            "push",
            "--porcelain",
            self.remote_name,
            f"{local_head}:{self.store.artifact_ref}",
            allowed_statuses={0, 1, 128},
        )
        if push.returncode == 0:
            return None
        return self.classify_git_failure(push.stderr + "\n" + push.stdout, operation="push")

    @staticmethod
    def classify_git_failure(message: str, *, operation: str) -> tuple[ArtifactSyncState, str]:
        lower = message.lower()
        if "couldn't find remote ref" in lower or "remote ref does not exist" in lower:
            return (
                ArtifactSyncState.MISSING_REMOTE_REF,
                "The configured artifact ref is missing. Confirm a first normal push or choose Local only.",
            )
        if any(
            marker in lower
            for marker in (
                "authentication failed",
                "could not read username",
                "permission denied (publickey)",
                "terminal prompts disabled",
            )
        ):
            return (
                ArtifactSyncState.RETRYABLE_AUTH,
                "Authenticate the configured Git remote, then retry; local artifact commits remain ahead.",
            )
        if any(
            marker in lower
            for marker in (
                "could not resolve host",
                "failed to connect",
                "network is unreachable",
                "operation timed out",
                "connection timed out",
            )
        ):
            return (
                ArtifactSyncState.RETRYABLE_OFFLINE,
                "Reconnect to the configured remote and retry; local artifact commits remain available.",
            )
        if any(
            marker in lower
            for marker in (
                "protected branch",
                "protected ref",
                "pre-receive hook declined",
                "deny updating a hidden ref",
                "hook declined",
            )
        ):
            return (
                ArtifactSyncState.PROTECTED_REF,
                "The remote protects the artifact ref. Change its policy explicitly or use Local only; Relay will not force push.",
            )
        if operation == "push" and any(
            marker in lower
            for marker in ("non-fast-forward", "fetch first", "stale info", "rejected")
        ):
            return (
                ArtifactSyncState.AHEAD,
                "The remote advanced during push; refetch and retry without force.",
            )
        return (
            ArtifactSyncState.FAILED,
            "Git artifact synchronization failed without a safe automatic recovery; inspect the configured remote.",
        )

    def _remote_error_result(
        self,
        remote: _RemoteSnapshot,
        local_head: str | None,
        *,
        attempts: int,
    ) -> ArtifactSyncResult:
        assert remote.error_state is not None
        return self._finish(
            remote.error_state,
            ArtifactSyncState.AHEAD if local_head else remote.error_state,
            attempts,
            local_head,
            remote.head,
            recovery=remote.recovery,
            transitions=(ArtifactSyncState.SYNCING, remote.error_state),
        )

    def _finish(
        self,
        state: ArtifactSyncState,
        observed_state: ArtifactSyncState,
        attempts: int,
        local_head: str | None,
        remote_head: str | None,
        *,
        recovery: str | None = None,
        conflict_report: ArtifactConflictReport | None = None,
        transitions: Sequence[ArtifactSyncState],
    ) -> ArtifactSyncResult:
        result = ArtifactSyncResult(
            state=state,
            observed_state=observed_state,
            transitions=tuple(transitions),
            attempts=attempts,
            local_head=local_head,
            remote_head=remote_head,
            recovery=recovery,
            conflict_report=conflict_report,
        )
        self._persist_state(result)
        return result

    def _persist_state(self, result: ArtifactSyncResult) -> None:
        payload = {
            "version": 1,
            "project_id": self.store.project_id,
            "artifact_ref": self.store.artifact_ref,
            "mode": self.mode.value,
            "remote_name": self.remote_name,
            "state": result.state.value,
            "observed_state": result.observed_state.value,
            "transitions": [state.value for state in result.transitions],
            "attempts": result.attempts,
            "local_head": result.local_head,
            "remote_head": result.remote_head,
            "recovery": result.recovery,
            "conflicts": [
                dataclasses.asdict(conflict)
                for conflict in (result.conflict_report.conflicts if result.conflict_report else ())
            ],
            "updated_at": int(time.time()),
        }
        self.store._write_json_atomic(self.state_path, payload)

    def _resolution_digest(
        self,
        report: ArtifactConflictReport,
        decisions: Mapping[str, str | bytes],
    ) -> str:
        serialized = {}
        for path, decision in sorted(decisions.items()):
            serialized[path] = (
                {"sha256": hashlib.sha256(decision).hexdigest(), "bytes": len(decision)}
                if isinstance(decision, bytes)
                else decision
            )
        payload = {
            "merge_base": report.merge_base,
            "local_head": report.local_head,
            "remote_head": report.remote_head,
            "decisions": serialized,
        }
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    def _resolution_message(
        self,
        report: ArtifactConflictReport,
        event_id: str,
        digest: str,
        device_id: str,
        actor_type: str,
        provider: str | None,
    ) -> str:
        lines = [
            "Resolve Relay artifact conflict",
            "",
            f"Relay-Project-ID: {self.store.project_id}",
            f"Relay-Event-ID: {event_id}",
            f"Relay-Event-Digest: {digest}",
            f"Relay-Device-ID: {device_id}",
            f"Relay-Actor-Type: {actor_type}",
        ]
        if provider:
            lines.append(f"Relay-Provider: {provider}")
        lines.extend(
            f"Relay-Resolved-Event: {event_id} {event_digest}"
            for event_id, event_digest in report.local_events
        )
        return "\n".join(lines) + "\n"

    def _inject(self, stage: str) -> None:
        if self.failure_injector:
            self.failure_injector(stage)

    def _quarantine_git(self, repository: Path, *arguments: str) -> str:
        return self._quarantine_git_bytes(repository, *arguments).decode(
            "utf-8", errors="replace"
        ).strip()

    def _quarantine_git_bytes(self, repository: Path, *arguments: str) -> bytes:
        process = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.store._git_environment(),
            check=False,
        )
        if process.returncode != 0:
            raise ArtifactStoreError(
                f"quarantine git {' '.join(arguments)} failed: "
                f"{process.stderr.decode('utf-8', errors='replace').strip()}"
            )
        return process.stdout


__all__ = [
    "ArtifactConflict",
    "ArtifactConflictReport",
    "ArtifactSyncEngine",
    "ArtifactSyncMode",
    "ArtifactSyncResult",
    "ArtifactSyncState",
]
