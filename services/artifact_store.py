#!/usr/bin/env python3
"""Project-owned Relay artifact Git store.

The store deliberately uses Git plumbing with a private index.  It never
checks out the artifact ref, changes the source branch, stages a source path,
or edits a configured remote.  One typed mutation becomes one CAS-published
commit on ``refs/heads/relay/artifacts`` and is then materialized into the
repo-root ``.orchestrator`` projection.
"""

from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import hashlib
import json
import mimetypes
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import tomllib
import uuid
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Iterator, Mapping, Sequence


ARTIFACT_REF = "refs/heads/relay/artifacts"
TICKET_MAX_BYTES = 256 * 1024
ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024
ATTACHMENT_TICKET_MAX_BYTES = 25 * 1024 * 1024
DEFAULT_PROJECT_WARNING_BYTES = 250 * 1024 * 1024
PROGRAM_EVENT_MAX_BYTES = 256 * 1024

_IDENTITY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
_TICKET_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
_EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
_ARTIFACT_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,160}$")
_TRAILER_RE = re.compile(r"^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$")
_FORBIDDEN_JSON_KEYS = {
    "hidden_reasoning",
    "raw_audio",
    "raw_log",
    "raw_logs",
    "raw_transcript",
    "sensitive_transcript",
    "session_trace",
    "shell_trace",
    "tool_output",
}
_SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(rb"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{20,}"),
)
_FORBIDDEN_TEXT_MARKERS = (
    re.compile(rb"(?im)^\s*(?:raw_transcript|hidden_reasoning|session_trace|shell_trace)\s*:"),
    re.compile(rb"(?i)<\s*(?:raw[_-]transcript|hidden[_-]reasoning|session[_-]trace)\s*>"),
    re.compile(rb"(?im)^\s*-----BEGIN RAW (?:TRANSCRIPT|SESSION TRACE)-----\s*$"),
)

_global_locks_guard = threading.Lock()
_global_locks: dict[str, threading.RLock] = {}


class ArtifactStoreError(RuntimeError):
    """Base fail-closed artifact error."""


class ArtifactStoreDisabled(ArtifactStoreError):
    pass


class ArtifactValidationError(ArtifactStoreError):
    pass


class ArtifactIdentityError(ArtifactStoreError):
    pass


class ArtifactConcurrentUpdate(ArtifactStoreError):
    pass


class ArtifactEventCollision(ArtifactStoreError):
    pass


class ArtifactMaterializationConflict(ArtifactStoreError):
    pass


class ArtifactInjectedFailure(ArtifactStoreError):
    pass


@dataclasses.dataclass(frozen=True)
class TicketWrite:
    ticket_id: str
    artifact_id: str
    markdown: bytes


@dataclasses.dataclass(frozen=True)
class TicketDelete:
    ticket_id: str


@dataclasses.dataclass(frozen=True)
class AttachmentWrite:
    ticket_id: str
    filename: str
    mime_type: str
    content: bytes


@dataclasses.dataclass(frozen=True)
class AttachmentDelete:
    ticket_id: str
    filename: str


@dataclasses.dataclass(frozen=True)
class ConfigWrite:
    content: bytes


@dataclasses.dataclass(frozen=True)
class ArchiveIndexWrite:
    content: bytes


@dataclasses.dataclass(frozen=True)
class ProgramEventWrite:
    event_id: str
    content: bytes


ArtifactOperation = (
    TicketWrite
    | TicketDelete
    | AttachmentWrite
    | AttachmentDelete
    | ConfigWrite
    | ArchiveIndexWrite
    | ProgramEventWrite
)


@dataclasses.dataclass(frozen=True)
class ArtifactMutation:
    event_id: str
    actor_type: str
    device_id: str
    operations: tuple[ArtifactOperation, ...]
    expected_base: str | None = None
    provider: str | None = None
    summary: str = "Relay artifact mutation"


@dataclasses.dataclass(frozen=True)
class ArtifactWriteResult:
    event_id: str
    commit_id: str
    tree_id: str
    base_commit: str | None
    idempotent: bool
    warnings: tuple[str, ...] = ()


@dataclasses.dataclass(frozen=True)
class ArtifactSnapshot:
    project_id: str
    commit_id: str
    tree_id: str
    files: Mapping[str, bytes]


@dataclasses.dataclass(frozen=True)
class _TreeEntry:
    mode: str
    kind: str
    oid: str
    path: str


class ArtifactStore:
    """Serialized per-project writer for the orphan artifact ref."""

    def __init__(
        self,
        repo_path: str | os.PathLike[str],
        project_id: str,
        state_root: str | os.PathLike[str],
        *,
        enabled: bool = False,
        artifact_ref: str = ARTIFACT_REF,
        project_warning_bytes: int = DEFAULT_PROJECT_WARNING_BYTES,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        self.repo_path = Path(repo_path).resolve()
        self.project_id = _validate_identity(project_id, "project ID")
        self.state_root = Path(state_root).resolve()
        self.enabled = enabled
        if artifact_ref != ARTIFACT_REF:
            raise ArtifactValidationError(
                f"unsupported artifact ref {artifact_ref!r}; expected {ARTIFACT_REF}"
            )
        self.artifact_ref = artifact_ref
        self.project_warning_bytes = project_warning_bytes
        self.failure_injector = failure_injector
        self.project_state = self.state_root / "artifacts" / self.project_id
        self.lock_path = self.state_root / "locks" / f"{self.project_id}.lock"
        self.metadata_path = self.project_state / "materialization.json"
        self.journal_path = self.project_state / "materialization-journal.json"
        self.history_verification_path = self.project_state / "history-verification.json"
        self.materialized_path = self.repo_path / ".orchestrator"

    def initialize(self, *, device_id: str, actor_type: str = "system") -> ArtifactWriteResult:
        """Create an orphan artifact ref or adopt a verified existing one."""
        self._require_enabled()
        _validate_actor(actor_type)
        _validate_event_id(device_id, "device ID")
        with self._writer_lock():
            self._verify_repository()
            self._recover_materialization_transaction()
            head = self._head()
            if head:
                self._validate_artifact_head(head)
                self._ensure_materialization_consistent(head)
                self._materialize(head)
                return ArtifactWriteResult(
                    event_id=f"initialize:{self.project_id}",
                    commit_id=head,
                    tree_id=self._tree_id(head),
                    base_commit=head,
                    idempotent=True,
                )

            if self.materialized_path.exists() or self.materialized_path.is_symlink():
                raise ArtifactMaterializationConflict(
                    "cannot initialize over an existing .orchestrator tree; "
                    "use the journaled legacy migration"
                )
            config = self._render_initial_config()
            event = ArtifactMutation(
                event_id=f"initialize:{self.project_id}",
                actor_type=actor_type,
                device_id=device_id,
                operations=(ConfigWrite(config),),
                expected_base=None,
                summary="Initialize Relay artifact store",
            )
            return self._commit_mutation(event, current_head=None)

    def mutate(self, mutation: ArtifactMutation) -> ArtifactWriteResult:
        self._require_enabled()
        self._validate_mutation_envelope(mutation)
        with self._writer_lock():
            self._verify_repository()
            self._recover_materialization_transaction()
            head = self._head()
            if not head:
                raise ArtifactValidationError("artifact store is not initialized")
            self._validate_artifact_head(head)

            digest = self._mutation_digest(mutation)
            prior = self._find_event(mutation.event_id)
            if prior:
                prior_commit, prior_digest = prior
                if prior_digest != digest:
                    raise ArtifactEventCollision(
                        f"event ID {mutation.event_id!r} was already committed with different content"
                    )
                self._materialize(head)
                return ArtifactWriteResult(
                    event_id=mutation.event_id,
                    commit_id=prior_commit,
                    tree_id=self._tree_id(prior_commit),
                    base_commit=self._first_parent(prior_commit),
                    idempotent=True,
                )

            if mutation.expected_base is not None and mutation.expected_base != head:
                raise ArtifactConcurrentUpdate(
                    f"artifact base changed: expected {mutation.expected_base}, found {head}"
                )
            self._ensure_materialization_consistent(head)
            return self._commit_mutation(mutation, current_head=head, digest=digest)

    def recover(self) -> str:
        """Reconstruct the projection from the canonical ref after interruption."""
        self._require_enabled()
        with self._writer_lock():
            self._verify_repository()
            self._recover_materialization_transaction()
            head = self._head()
            if not head:
                raise ArtifactValidationError("artifact store is not initialized")
            self._validate_artifact_head(head)
            self._materialize(head, force=True)
            return head

    def snapshot(self, *, provider: str | None = None) -> ArtifactSnapshot:
        """Return provider-neutral bytes from one immutable artifact head."""
        del provider  # Provider identity cannot affect artifact contents.
        self._require_enabled()
        with self._writer_lock():
            head = self._head()
            if not head:
                raise ArtifactValidationError("artifact store is not initialized")
            self._validate_artifact_head(head)
            entries = self._tree_entries(head)
            return ArtifactSnapshot(
                project_id=self.project_id,
                commit_id=head,
                tree_id=self._tree_id(head),
                files={entry.path: self._cat_blob(entry.oid) for entry in entries.values()},
            )

    def _commit_mutation(
        self,
        mutation: ArtifactMutation,
        *,
        current_head: str | None,
        digest: str | None = None,
    ) -> ArtifactWriteResult:
        digest = digest or self._mutation_digest(mutation)
        entries = self._tree_entries(current_head) if current_head else {}
        prepared, warnings = self._prepare_operations(mutation.operations, entries)

        self._inject("before_commit")
        with tempfile.TemporaryDirectory(prefix="relay-artifact-index-") as temporary:
            index_path = Path(temporary) / "index"
            env = self._git_environment({"GIT_INDEX_FILE": str(index_path)})
            if current_head:
                self._git("read-tree", current_head, env=env)
            else:
                self._git("read-tree", "--empty", env=env)

            for action, path, content in prepared:
                if action == "delete":
                    self._git(
                        "update-index",
                        "--force-remove",
                        "--",
                        path,
                        env=env,
                    )
                    continue
                assert content is not None
                blob = self._git("hash-object", "-w", "--stdin", input_bytes=content).stdout.strip()
                self._git(
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "100644",
                    blob,
                    path,
                    env=env,
                )

            tree_id = self._git("write-tree", env=env).stdout.strip()
            message = self._commit_message(mutation, digest)
            args = ["commit-tree", tree_id]
            if current_head:
                args.extend(["-p", current_head])
            commit_id = self._git(*args, input_bytes=message.encode("utf-8")).stdout.strip()

        self._inject("during_cas")
        expected = current_head or self._zero_oid()
        update = self._git(
            "update-ref",
            self.artifact_ref,
            commit_id,
            expected,
            allowed_statuses={0, 128},
        )
        if update.returncode != 0:
            found = self._head()
            raise ArtifactConcurrentUpdate(
                f"artifact ref CAS failed: expected {expected}, found {found or 'missing'}"
            )

        self._inject("after_ref_update")
        self._materialize(commit_id)
        return ArtifactWriteResult(
            event_id=mutation.event_id,
            commit_id=commit_id,
            tree_id=tree_id,
            base_commit=current_head,
            idempotent=False,
            warnings=tuple(warnings),
        )

    def _prepare_operations(
        self,
        operations: Sequence[ArtifactOperation],
        entries: Mapping[str, _TreeEntry],
    ) -> tuple[list[tuple[str, str, bytes | None]], list[str]]:
        if not operations:
            raise ArtifactValidationError("an artifact event must contain at least one operation")
        prepared: list[tuple[str, str, bytes | None]] = []
        projected_sizes = {
            path: self._blob_size(entry.oid)
            for path, entry in entries.items()
            if _is_attachment_path(path)
        }
        seen_paths: set[str] = set()

        for operation in operations:
            if isinstance(operation, TicketWrite):
                ticket_id = _validate_ticket_id(operation.ticket_id)
                artifact_id = _validate_artifact_id(operation.artifact_id)
                content = _prepare_ticket_markdown(ticket_id, artifact_id, operation.markdown)
                _reject_secrets(content, f"ticket {ticket_id}")
                if len(content) > TICKET_MAX_BYTES:
                    raise ArtifactValidationError(
                        f"ticket {ticket_id} is {len(content)} bytes; limit is {TICKET_MAX_BYTES}"
                    )
                path = f".orchestrator/{ticket_id}.md"
                prepared.append(("write", path, content))
            elif isinstance(operation, TicketDelete):
                ticket_id = _validate_ticket_id(operation.ticket_id)
                path = f".orchestrator/{ticket_id}.md"
                prepared.append(("delete", path, None))
                attachment_prefix = f".orchestrator/attachments/{ticket_id}/"
                for existing_path in sorted(entries):
                    if existing_path.startswith(attachment_prefix):
                        prepared.append(("delete", existing_path, None))
                        projected_sizes.pop(existing_path, None)
            elif isinstance(operation, AttachmentWrite):
                ticket_id = _validate_ticket_id(operation.ticket_id)
                filename = _validate_filename(operation.filename)
                content = operation.content
                _validate_attachment(filename, operation.mime_type, content)
                path = f".orchestrator/attachments/{ticket_id}/{filename}"
                projected_sizes[path] = len(content)
                prepared.append(("write", path, content))
            elif isinstance(operation, AttachmentDelete):
                ticket_id = _validate_ticket_id(operation.ticket_id)
                filename = _validate_filename(operation.filename)
                path = f".orchestrator/attachments/{ticket_id}/{filename}"
                projected_sizes.pop(path, None)
                prepared.append(("delete", path, None))
            elif isinstance(operation, ConfigWrite):
                self._validate_config(operation.content)
                _reject_secrets(operation.content, "artifact config")
                prepared.append(("write", ".orchestrator/config.toml", operation.content))
            elif isinstance(operation, ArchiveIndexWrite):
                _validate_archive_index(operation.content)
                _reject_secrets(operation.content, "archive index")
                prepared.append(("write", ".orchestrator/archive-index.jsonl", operation.content))
            elif isinstance(operation, ProgramEventWrite):
                event_id = _validate_event_id(operation.event_id, "Program event ID")
                content = self._prepare_program_event(event_id, operation.content)
                prepared.append(
                    ("write", f".orchestrator/program/events/{event_id}.json", content)
                )
            else:  # pragma: no cover - protects callers bypassing type checking.
                raise ArtifactValidationError(f"unsupported typed operation: {type(operation)!r}")

        for action, path, _ in prepared:
            _validate_allowlisted_path(path)
            if path in seen_paths:
                raise ArtifactValidationError(f"event modifies artifact path more than once: {path}")
            seen_paths.add(path)

        ticket_totals: dict[str, int] = {}
        for path, size in projected_sizes.items():
            ticket_id = path.split("/", 3)[2]
            ticket_totals[ticket_id] = ticket_totals.get(ticket_id, 0) + size
        for ticket_id, total in ticket_totals.items():
            if total > ATTACHMENT_TICKET_MAX_BYTES:
                raise ArtifactValidationError(
                    f"attachments for {ticket_id} total {total} bytes; "
                    f"limit is {ATTACHMENT_TICKET_MAX_BYTES}"
                )

        project_total = sum(projected_sizes.values())
        warnings: list[str] = []
        if project_total > self.project_warning_bytes:
            warnings.append(
                f"project attachment total {project_total} exceeds warning budget "
                f"{self.project_warning_bytes}"
            )
        return prepared, warnings

    def _prepare_program_event(self, event_id: str, content: bytes) -> bytes:
        if len(content) > PROGRAM_EVENT_MAX_BYTES:
            raise ArtifactValidationError(
                f"Program event is {len(content)} bytes; limit is {PROGRAM_EVENT_MAX_BYTES}"
            )
        try:
            payload = json.loads(content)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ArtifactValidationError(f"Program event is not valid UTF-8 JSON: {error}") from error
        if not isinstance(payload, dict):
            raise ArtifactValidationError("Program event must be a JSON object")
        if payload.get("event_id") != event_id:
            raise ArtifactValidationError("Program event_id does not match its typed operation")
        if payload.get("project_id") != self.project_id:
            raise ArtifactIdentityError("Program event project_id does not match the store")
        forbidden = _find_forbidden_keys(payload)
        if forbidden:
            raise ArtifactValidationError(
                f"Program event contains prohibited Git content: {', '.join(sorted(forbidden))}"
            )
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        encoded = (canonical + "\n").encode("utf-8")
        _reject_secrets(encoded, f"Program event {event_id}")
        return encoded

    def _validate_mutation_envelope(self, mutation: ArtifactMutation) -> None:
        _validate_event_id(mutation.event_id, "event ID")
        _validate_event_id(mutation.device_id, "device ID")
        _validate_actor(mutation.actor_type)
        if mutation.provider not in {None, "codex", "claude"}:
            raise ArtifactValidationError(f"unsupported provider metadata: {mutation.provider!r}")
        if mutation.expected_base is not None and not re.fullmatch(
            r"(?:[0-9a-f]{40}|[0-9a-f]{64})", mutation.expected_base
        ):
            raise ArtifactValidationError("expected_base must be a full Git object ID")
        if "\n" in mutation.summary or "\r" in mutation.summary:
            raise ArtifactValidationError("commit summary must be one line")

    def _mutation_digest(self, mutation: ArtifactMutation) -> str:
        payload: list[dict[str, object]] = []
        for operation in mutation.operations:
            item: dict[str, object] = {"type": type(operation).__name__}
            for field in dataclasses.fields(operation):
                value = getattr(operation, field.name)
                item[field.name] = (
                    {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}
                    if isinstance(value, bytes)
                    else value
                )
            payload.append(item)
        envelope = {
            "actor_type": mutation.actor_type,
            "device_id": mutation.device_id,
            "event_id": mutation.event_id,
            "operations": payload,
            "provider": mutation.provider,
        }
        encoded = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def _commit_message(self, mutation: ArtifactMutation, digest: str) -> str:
        summary = mutation.summary.strip() or "Relay artifact mutation"
        lines = [
            summary,
            "",
            f"Relay-Project-ID: {self.project_id}",
            f"Relay-Event-ID: {mutation.event_id}",
            f"Relay-Event-Digest: {digest}",
            f"Relay-Device-ID: {mutation.device_id}",
            f"Relay-Actor-Type: {mutation.actor_type}",
        ]
        if mutation.provider:
            lines.append(f"Relay-Provider: {mutation.provider}")
        return "\n".join(lines) + "\n"

    def _find_event(self, event_id: str) -> tuple[str, str] | None:
        if not self._head():
            return None
        output = self._git(
            "log",
            "--format=%H%x1f%B%x1e",
            self.artifact_ref,
        ).stdout
        for record in output.split("\x1e"):
            if "\x1f" not in record:
                continue
            commit_id, body = record.strip().split("\x1f", 1)
            trailers = _parse_trailers(body)
            if trailers.get("Relay-Event-ID") == event_id:
                digest = trailers.get("Relay-Event-Digest")
                if not digest:
                    raise ArtifactValidationError(
                        f"existing event {event_id!r} lacks its immutable digest"
                    )
                return commit_id, digest
        return None

    def _validate_artifact_head(self, head: str) -> None:
        cached_head: str | None = None
        try:
            cache = json.loads(self.history_verification_path.read_text(encoding="utf-8"))
            if cache.get("project_id") == self.project_id:
                candidate = cache.get("commit_id")
                if isinstance(candidate, str):
                    ancestor = self._git(
                        "merge-base",
                        "--is-ancestor",
                        candidate,
                        head,
                        allowed_statuses={0, 1, 128},
                    )
                    if ancestor.returncode == 0:
                        cached_head = candidate
        except (OSError, json.JSONDecodeError, AttributeError):
            pass

        if cached_head:
            history = [
                line.split()
                for line in self._git(
                    "rev-list", "--reverse", "--parents", f"{cached_head}..{head}"
                ).stdout.splitlines()
            ]
            expected_parent = cached_head
            for line in history:
                if len(line) != 2 or line[1] != expected_parent:
                    raise ArtifactValidationError(
                        "artifact history must remain a linear descendant of its verified head"
                    )
                expected_parent = line[0]
        else:
            history = [
                line.split()
                for line in self._git("rev-list", "--reverse", "--parents", head).stdout.splitlines()
            ]
            if not history or len(history[0]) != 1:
                raise ArtifactValidationError(
                    "artifact ref is not orphan-rooted; source history must never be reachable from it"
                )
            expected_parent = history[0][0]
            for line in history[1:]:
                if len(line) != 2 or line[1] != expected_parent:
                    raise ArtifactValidationError(
                        "artifact history must be linear and cannot contain merge parents"
                    )
                expected_parent = line[0]

        for line in history:
            for entry in self._tree_entries(line[0]).values():
                _validate_allowlisted_path(entry.path)
                if entry.mode != "100644" or entry.kind != "blob":
                    raise ArtifactValidationError(
                        f"artifact tree contains unsupported {entry.mode} {entry.kind}: {entry.path}"
                    )
        entries = self._tree_entries(head)
        config_entry = entries.get(".orchestrator/config.toml")
        if not config_entry:
            raise ArtifactValidationError("artifact tree has no .orchestrator/config.toml")
        self._validate_config(self._cat_blob(config_entry.oid))
        self._write_json_atomic(
            self.history_verification_path,
            {"version": 1, "project_id": self.project_id, "commit_id": head},
        )

    def _validate_config(self, content: bytes) -> None:
        try:
            document = tomllib.loads(content.decode("utf-8"))
        except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
            raise ArtifactValidationError(f"artifact config is invalid TOML: {error}") from error
        if document.get("schema_version") != 2:
            raise ArtifactValidationError("artifact config schema_version must be 2")
        if document.get("project_id") != self.project_id:
            raise ArtifactIdentityError(
                f"artifact ref belongs to project {document.get('project_id')!r}, "
                f"not {self.project_id!r}"
            )
        if document.get("artifact_ref") != self.artifact_ref:
            raise ArtifactValidationError("artifact config uses an unexpected artifact_ref")
        if document.get("remote_sync") not in {"local_only", "enabled", "paused"}:
            raise ArtifactValidationError("artifact config remote_sync is invalid")

    def _render_initial_config(self) -> bytes:
        prefix = re.sub(r"[^A-Za-z0-9]", "", self.repo_path.name).upper()[:3] or "RR"
        return (
            "schema_version = 2\n"
            f'project_id = "{self.project_id}"\n'
            f'prefix = "{prefix}"\n'
            f'artifact_ref = "{self.artifact_ref}"\n'
            'remote_sync = "local_only"\n'
            "next_id = 1\n"
        ).encode("utf-8")

    def _ensure_materialization_consistent(self, head: str) -> None:
        metadata = self._read_metadata()
        target_exists = self.materialized_path.exists() or self.materialized_path.is_symlink()
        if not metadata:
            if target_exists:
                raise ArtifactMaterializationConflict(
                    "existing .orchestrator has no verified artifact base; use explicit import or migration"
                )
            return
        if not target_exists:
            self._materialize(head, force=True)
            return
        expected = metadata.get("sha256")
        actual = self._materialized_sha256()
        manually_changed = actual != expected
        ref_changed = metadata.get("commit_id") != head
        if manually_changed and ref_changed:
            raise ArtifactMaterializationConflict(
                "materialized files and artifact ref both changed from their shared base"
            )
        if manually_changed:
            raise ArtifactMaterializationConflict(
                "materialized .orchestrator was edited manually; use explicit Save/import"
            )
        if ref_changed:
            self._materialize(head, force=True)

    def _materialize(self, head: str, *, force: bool = False) -> None:
        if not force:
            metadata = self._read_metadata()
            if metadata and metadata.get("commit_id") == head:
                if self.materialized_path.exists() and self._materialized_sha256() == metadata.get("sha256"):
                    return
        entries = self._tree_entries(head)
        self._validate_artifact_head(head)
        temp_root = self.repo_path / f".relay-materialization-{uuid.uuid4().hex}"
        backup_root = self.repo_path / f".relay-materialization-backup-{uuid.uuid4().hex}"
        journal = {
            "version": 1,
            "head": head,
            "temp": str(temp_root),
            "backup": str(backup_root),
            "target": str(self.materialized_path),
        }
        self.project_state.mkdir(parents=True, exist_ok=True)
        self._write_json_atomic(self.journal_path, journal)
        try:
            temp_root.mkdir(mode=0o700)
            for entry in entries.values():
                relative = PurePosixPath(entry.path).relative_to(".orchestrator")
                destination = temp_root.joinpath(*relative.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(self._cat_blob(entry.oid))
                os.chmod(destination, 0o600)
            self._inject("during_materialization")
            if self.materialized_path.is_symlink():
                raise ArtifactMaterializationConflict(".orchestrator materialization target is a symlink")
            if self.materialized_path.exists():
                os.replace(self.materialized_path, backup_root)
            os.replace(temp_root, self.materialized_path)
            self._install_local_exclude()
            metadata = {
                "version": 1,
                "project_id": self.project_id,
                "artifact_ref": self.artifact_ref,
                "commit_id": head,
                "tree_id": self._tree_id(head),
                "file_blobs": {path: entry.oid for path, entry in sorted(entries.items())},
                "sha256": self._materialized_sha256(),
                "materialized_at": int(time.time()),
            }
            self._write_json_atomic(self.metadata_path, metadata)
            if backup_root.exists():
                shutil.rmtree(backup_root)
            self.journal_path.unlink(missing_ok=True)
        except Exception:
            # The journal makes the remaining paths recoverable on restart.
            raise

    def _recover_materialization_transaction(self) -> None:
        if not self.journal_path.exists():
            return
        try:
            journal = json.loads(self.journal_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            journal = {}
        temporary = self._journal_owned_path(journal.get("temp"))
        backup = self._journal_owned_path(journal.get("backup"))
        if temporary and temporary.is_dir() and not temporary.is_symlink():
            shutil.rmtree(temporary)
        if (
            backup
            and backup.is_dir()
            and not backup.is_symlink()
            and not self.materialized_path.exists()
            and not self.materialized_path.is_symlink()
        ):
            os.replace(backup, self.materialized_path)
        self.journal_path.unlink(missing_ok=True)
        head = self._head()
        if head:
            self._materialize(head, force=True)
        if backup and backup.is_dir() and not backup.is_symlink():
            shutil.rmtree(backup)

    def _journal_owned_path(self, raw_value: object) -> Path | None:
        if not isinstance(raw_value, str):
            return None
        path = Path(raw_value)
        if path.parent != self.repo_path or not path.name.startswith(".relay-materialization-"):
            return None
        return path

    def _materialized_sha256(self) -> dict[str, str]:
        root = self.materialized_path
        if root.is_symlink():
            raise ArtifactMaterializationConflict(".orchestrator materialization target is a symlink")
        result: dict[str, str] = {}
        if not root.exists():
            return result
        for directory, directory_names, filenames in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            for name in list(directory_names):
                child = directory_path / name
                if child.is_symlink():
                    raise ArtifactMaterializationConflict(
                        f"materialized tree contains a symlink directory: {child}"
                    )
            for name in filenames:
                path = directory_path / name
                if path.is_symlink() or not path.is_file():
                    raise ArtifactMaterializationConflict(
                        f"materialized tree contains a non-regular file: {path}"
                    )
                relative = path.relative_to(root).as_posix()
                result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        return dict(sorted(result.items()))

    def _install_local_exclude(self) -> None:
        exclude_path = Path(
            self._git("rev-parse", "--git-path", "info/exclude").stdout.strip()
        )
        if not exclude_path.is_absolute():
            exclude_path = self.repo_path / exclude_path
        exclude_path.parent.mkdir(parents=True, exist_ok=True)
        existing = exclude_path.read_text(encoding="utf-8") if exclude_path.exists() else ""
        pattern = "/.orchestrator/"
        if pattern in {line.strip() for line in existing.splitlines()}:
            return
        content = existing
        if content and not content.endswith("\n"):
            content += "\n"
        content += pattern + "\n"
        temporary = exclude_path.with_name(exclude_path.name + f".relay-{uuid.uuid4().hex}.tmp")
        temporary.write_text(content, encoding="utf-8")
        os.replace(temporary, exclude_path)

    def _read_metadata(self) -> dict[str, object] | None:
        try:
            value = json.loads(self.metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(value, dict) or value.get("project_id") != self.project_id:
            return None
        return value

    def _write_json_atomic(self, path: Path, payload: Mapping[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
        temporary.write_text(
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)

    def _tree_entries(self, commit: str | None) -> dict[str, _TreeEntry]:
        if not commit:
            return {}
        output = self._git("ls-tree", "-r", "-z", "--full-tree", commit).stdout_bytes
        result: dict[str, _TreeEntry] = {}
        for record in output.split(b"\0"):
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, oid = metadata.decode("ascii").split(" ", 2)
            path = raw_path.decode("utf-8")
            result[path] = _TreeEntry(mode=mode, kind=kind, oid=oid, path=path)
        return result

    def _cat_blob(self, oid: str) -> bytes:
        return self._git("cat-file", "blob", oid).stdout_bytes

    def _blob_size(self, oid: str) -> int:
        return int(self._git("cat-file", "-s", oid).stdout.strip())

    def _tree_id(self, commit: str) -> str:
        return self._git("rev-parse", f"{commit}^{{tree}}").stdout.strip()

    def _zero_oid(self) -> str:
        object_format = self._git("rev-parse", "--show-object-format").stdout.strip()
        return "0" * (64 if object_format == "sha256" else 40)

    def _first_parent(self, commit: str) -> str | None:
        value = self._git(
            "rev-parse",
            "--verify",
            f"{commit}^",
            allowed_statuses={0, 128},
        )
        return value.stdout.strip() if value.returncode == 0 else None

    def _head(self) -> str | None:
        result = self._git(
            "rev-parse",
            "--verify",
            self.artifact_ref,
            allowed_statuses={0, 128},
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def _verify_repository(self) -> None:
        if not self.repo_path.is_dir():
            raise ArtifactValidationError(f"repository is unavailable: {self.repo_path}")
        inside = self._git(
            "rev-parse",
            "--is-inside-work-tree",
            allowed_statuses={0, 128},
        )
        if inside.returncode != 0 or inside.stdout.strip() != "true":
            raise ArtifactValidationError(f"not a Git worktree: {self.repo_path}")
        bare = self._git("rev-parse", "--is-bare-repository").stdout.strip()
        if bare == "true":
            raise ArtifactValidationError("bare repositories cannot materialize Relay artifacts")

    @contextlib.contextmanager
    def _writer_lock(self) -> Iterator[None]:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        key = str(self.lock_path)
        with _global_locks_guard:
            process_lock = _global_locks.setdefault(key, threading.RLock())
        with process_lock:
            with self.lock_path.open("a+b") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _require_enabled(self) -> None:
        if not self.enabled:
            raise ArtifactStoreDisabled(
                "project artifact store is opt-in and is disabled for this project"
            )

    def _inject(self, stage: str) -> None:
        if self.failure_injector:
            self.failure_injector(stage)

    def _git_environment(self, additions: Mapping[str, str] | None = None) -> dict[str, str]:
        env = dict(os.environ)
        for key in (
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_DIR",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_WORK_TREE",
        ):
            env.pop(key, None)
        env.update(
            {
                "GIT_AUTHOR_NAME": "Relay Runner",
                "GIT_AUTHOR_EMAIL": "relay-runner@localhost",
                "GIT_COMMITTER_NAME": "Relay Runner",
                "GIT_COMMITTER_EMAIL": "relay-runner@localhost",
                "LC_ALL": "C",
            }
        )
        if additions:
            env.update(additions)
        return env

    def _git(
        self,
        *arguments: str,
        env: Mapping[str, str] | None = None,
        input_bytes: bytes | None = None,
        allowed_statuses: set[int] = {0},
    ) -> "_GitResult":
        process = subprocess.run(
            ["git", "-C", str(self.repo_path), *arguments],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(env) if env is not None else self._git_environment(),
            check=False,
        )
        result = _GitResult(process.returncode, process.stdout, process.stderr)
        if process.returncode not in allowed_statuses:
            command = " ".join(arguments)
            raise ArtifactStoreError(
                f"git {command} failed ({process.returncode}): {result.stderr.strip()}"
            )
        return result


@dataclasses.dataclass(frozen=True)
class _GitResult:
    returncode: int
    stdout_bytes: bytes
    stderr_bytes: bytes

    @property
    def stdout(self) -> str:
        return self.stdout_bytes.decode("utf-8", errors="replace")

    @property
    def stderr(self) -> str:
        return self.stderr_bytes.decode("utf-8", errors="replace")


def _validate_identity(value: str, label: str) -> str:
    if not _IDENTITY_RE.fullmatch(value):
        raise ArtifactValidationError(f"invalid {label}: {value!r}")
    return value


def _validate_ticket_id(value: str) -> str:
    if not _TICKET_ID_RE.fullmatch(value) or value in {"config", "archive-index"}:
        raise ArtifactValidationError(f"invalid ticket ID: {value!r}")
    return value


def _validate_artifact_id(value: str) -> str:
    if not _ARTIFACT_ID_RE.fullmatch(value):
        raise ArtifactValidationError(f"invalid immutable artifact ID: {value!r}")
    return value


def _validate_event_id(value: str, label: str) -> str:
    if not _EVENT_ID_RE.fullmatch(value):
        raise ArtifactValidationError(f"invalid {label}: {value!r}")
    return value


def _validate_actor(value: str) -> str:
    allowed = {"migration", "pm", "reviewer", "system", "user", "worker"}
    if value not in allowed:
        raise ArtifactValidationError(f"invalid provider-neutral actor type: {value!r}")
    return value


def _validate_filename(value: str) -> str:
    if (
        not value
        or value in {".", ".."}
        or len(value.encode("utf-8")) > 255
        or PurePosixPath(value).name != value
        or "\\" in value
        or any(ord(character) < 32 for character in value)
    ):
        raise ArtifactValidationError(f"invalid attachment filename: {value!r}")
    return value


def _validate_allowlisted_path(path: str) -> None:
    pure = PurePosixPath(path)
    if pure.is_absolute() or ".." in pure.parts or "." in pure.parts:
        raise ArtifactValidationError(f"artifact path traversal is prohibited: {path!r}")
    if path in {
        ".orchestrator/config.toml",
        ".orchestrator/archive-index.jsonl",
    }:
        return
    parts = pure.parts
    if len(parts) == 2 and parts[0] == ".orchestrator" and parts[1].endswith(".md"):
        _validate_ticket_id(parts[1][:-3])
        return
    if len(parts) == 4 and parts[:2] == (".orchestrator", "attachments"):
        _validate_ticket_id(parts[2])
        _validate_filename(parts[3])
        return
    if (
        len(parts) == 4
        and parts[:3] == (".orchestrator", "program", "events")
        and parts[3].endswith(".json")
    ):
        _validate_event_id(parts[3][:-5], "Program event ID")
        return
    raise ArtifactValidationError(f"artifact path is not allowlisted: {path!r}")


def _is_attachment_path(path: str) -> bool:
    return path.startswith(".orchestrator/attachments/")


def _prepare_ticket_markdown(ticket_id: str, artifact_id: str, content: bytes) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ArtifactValidationError(f"ticket {ticket_id} is not UTF-8") from error
    if "\x00" in text:
        raise ArtifactValidationError(f"ticket {ticket_id} contains NUL bytes")
    if any(pattern.search(content) for pattern in _FORBIDDEN_TEXT_MARKERS):
        raise ArtifactValidationError(
            f"ticket {ticket_id} contains an explicit raw transcript, trace, or hidden-reasoning marker"
        )
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ArtifactValidationError(f"ticket {ticket_id} must have YAML front matter")
    try:
        closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as error:
        raise ArtifactValidationError(f"ticket {ticket_id} front matter is not closed") from error
    id_index: int | None = None
    artifact_index: int | None = None
    for index in range(1, closing):
        key, separator, raw_value = lines[index].partition(":")
        if not separator:
            continue
        key = key.strip()
        value = raw_value.strip().strip("\"'")
        if key == "id":
            if value != ticket_id:
                raise ArtifactValidationError(
                    f"ticket front-matter ID {value!r} does not match {ticket_id!r}"
                )
            id_index = index
        elif key == "artifact_id":
            if value != artifact_id:
                raise ArtifactIdentityError(
                    f"ticket immutable artifact_id {value!r} does not match {artifact_id!r}"
                )
            artifact_index = index
    if id_index is None:
        raise ArtifactValidationError(f"ticket {ticket_id} has no front-matter id")
    if artifact_index is None:
        lines.insert(id_index + 1, f"artifact_id: {artifact_id}")
    return ("\n".join(lines).rstrip("\n") + "\n").encode("utf-8")


def _validate_attachment(filename: str, mime_type: str, content: bytes) -> None:
    if len(content) > ATTACHMENT_MAX_BYTES:
        raise ArtifactValidationError(
            f"attachment {filename!r} is {len(content)} bytes; limit is {ATTACHMENT_MAX_BYTES}"
        )
    allowed: dict[str, tuple[tuple[str, ...], Callable[[bytes], bool]]] = {
        "image/png": ((".png",), lambda data: data.startswith(b"\x89PNG\r\n\x1a\n")),
        "image/jpeg": ((".jpg", ".jpeg"), lambda data: data.startswith(b"\xff\xd8\xff")),
        "image/gif": ((".gif",), lambda data: data.startswith((b"GIF87a", b"GIF89a"))),
        "image/webp": ((".webp",), lambda data: len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP"),
        "application/pdf": ((".pdf",), lambda data: data.startswith(b"%PDF-")),
    }
    policy = allowed.get(mime_type.lower())
    if not policy:
        guessed = mimetypes.guess_type(filename)[0] or "unknown"
        raise ArtifactValidationError(
            f"attachment MIME {mime_type!r} is unsupported (filename suggests {guessed}); "
            "raw audio, archives, executables, and large binaries stay outside Git"
        )
    extensions, signature_matches = policy
    if Path(filename).suffix.lower() not in extensions:
        raise ArtifactValidationError(
            f"attachment filename {filename!r} does not match MIME {mime_type!r}"
        )
    if not signature_matches(content):
        raise ArtifactValidationError(
            f"attachment {filename!r} bytes do not match declared MIME {mime_type!r}"
        )


def _validate_archive_index(content: bytes) -> None:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ArtifactValidationError("archive index is not UTF-8") from error
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise ArtifactValidationError(
                f"archive index line {line_number} is invalid JSON: {error}"
            ) from error
        if not isinstance(value, dict):
            raise ArtifactValidationError(f"archive index line {line_number} is not an object")
        forbidden = _find_forbidden_keys(value)
        if forbidden:
            raise ArtifactValidationError(
                f"archive index line {line_number} contains prohibited Git content: "
                f"{', '.join(sorted(forbidden))}"
            )


def _reject_secrets(content: bytes, label: str) -> None:
    for pattern in _SECRET_PATTERNS:
        if pattern.search(content):
            raise ArtifactValidationError(
                f"{label} appears to contain a credential or private key; Git commit refused"
            )


def _find_forbidden_keys(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).strip().lower()
            if normalized in _FORBIDDEN_JSON_KEYS:
                found.add(normalized)
            found.update(_find_forbidden_keys(child))
    elif isinstance(value, list):
        for child in value:
            found.update(_find_forbidden_keys(child))
    return found


def _parse_trailers(message: str) -> dict[str, str]:
    trailers: dict[str, str] = {}
    for line in message.splitlines():
        match = _TRAILER_RE.match(line)
        if match:
            trailers[match.group(1)] = match.group(2)
    return trailers


__all__ = [
    "ARTIFACT_REF",
    "ArchiveIndexWrite",
    "ArtifactConcurrentUpdate",
    "ArtifactEventCollision",
    "ArtifactIdentityError",
    "ArtifactInjectedFailure",
    "ArtifactMaterializationConflict",
    "ArtifactMutation",
    "ArtifactSnapshot",
    "ArtifactStore",
    "ArtifactStoreDisabled",
    "ArtifactStoreError",
    "ArtifactValidationError",
    "ArtifactWriteResult",
    "AttachmentDelete",
    "AttachmentWrite",
    "ConfigWrite",
    "ProgramEventWrite",
    "TicketDelete",
    "TicketWrite",
]
