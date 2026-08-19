#!/usr/bin/env python3
"""Guarded legacy ``.orchestrator`` migration and rollback.

RR-270 phase 8 deliberately treats migration as a small transaction coordinator,
not as a file-copy convenience.  The legacy tree is inspected without writes,
captured in a private journal, bootstrapped through ArtifactStore's typed writer,
removed from the source branch with a private Git index, and then rematerialized
from the orphan artifact ref.  Every state-changing step is idempotent and the
journal is the rollback authority.
"""

from __future__ import annotations

import contextlib
import dataclasses
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
try:
    from services.toml_compat import tomllib
except ModuleNotFoundError:
    from toml_compat import tomllib
import uuid
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Iterator, Mapping, Sequence
from urllib.parse import urlsplit, urlunsplit

try:
    from services.artifact_retention import ArtifactRetentionManager
    from services.artifact_store import (
        ARTIFACT_REF,
        ArchiveIndexWrite,
        ArtifactMutation,
        ArtifactStore,
        ArtifactStoreError,
        AttachmentWrite,
        ConfigWrite,
        ProgramEventWrite,
        TICKET_MAX_BYTES,
        TicketWrite,
        _attachment_mime_for_filename,
        _reject_secrets,
        _ticket_front_matter_value,
        _validate_archive_index,
        _validate_attachment,
    )
    from services.graphify_core import GraphifyCoreStore
    from services.program_artifacts import (
        ProgramArtifactMigrationError,
        expected_graph_manifest,
        export_graphify_project_captures,
        replace_graphify_with_clean_rebuild,
    )
    from services.tickets import TicketParseError, parse as parse_ticket
except ModuleNotFoundError:  # Installed direct-script layout.
    from artifact_retention import ArtifactRetentionManager  # type: ignore[no-redef]
    from artifact_store import (  # type: ignore[no-redef]
        ARTIFACT_REF,
        ArchiveIndexWrite,
        ArtifactMutation,
        ArtifactStore,
        ArtifactStoreError,
        AttachmentWrite,
        ConfigWrite,
        ProgramEventWrite,
        TICKET_MAX_BYTES,
        TicketWrite,
        _attachment_mime_for_filename,
        _reject_secrets,
        _ticket_front_matter_value,
        _validate_archive_index,
        _validate_attachment,
    )
    from graphify_core import GraphifyCoreStore  # type: ignore[no-redef]
    from program_artifacts import (  # type: ignore[no-redef]
        ProgramArtifactMigrationError,
        expected_graph_manifest,
        export_graphify_project_captures,
        replace_graphify_with_clean_rebuild,
    )
    from tickets import TicketParseError, parse as parse_ticket  # type: ignore[no-redef]


MIGRATION_SCHEMA_VERSION = 1
ACTIVE_RUN_STATES = frozenset(
    {
        "Claimed",
        "Running",
        "SpikeResultReady",
        "AwaitingReview",
        "Reviewing",
        "MergeConflict",
        "IntegrationBlocked",
        "Succeeded",
    }
)
_LEGACY_CONFIG_KEYS = frozenset({"prefix", "next_id"})
_REMOTE_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
_HEX_OID_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


class ArtifactMigrationError(RuntimeError):
    """Base migration error carrying a public recovery action."""

    def __init__(self, message: str, *, recovery: str, report: Mapping[str, Any] | None = None):
        super().__init__(message)
        self.recovery = recovery
        self.report = dict(report or {})


class ArtifactMigrationBlocked(ArtifactMigrationError):
    pass


class ArtifactMigrationReconciliationRequired(ArtifactMigrationError):
    pass


class ArtifactMigrationInjectedFailure(ArtifactMigrationError):
    pass


@dataclasses.dataclass(frozen=True)
class MigrationPreview:
    project_id: str
    repo_path: str
    common_directory: str
    source_branch: str
    default_branch: str
    source_head: str
    manifest: Mapping[str, Any]
    manifest_digest: str
    registry_record: Mapping[str, Any]
    git: Mapping[str, Any]
    run_references: tuple[Mapping[str, Any], ...]
    program_references: tuple[Mapping[str, Any], ...]
    remote: Mapping[str, Any]
    blockers: tuple[Mapping[str, str], ...] = ()

    @property
    def can_migrate(self) -> bool:
        return not self.blockers

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class MigrationResult:
    project_id: str
    stage: str
    artifact_commit: str
    source_commit: str | None
    manifest_digest: str
    remote_result: Mapping[str, Any]
    retention_preview: Mapping[str, Any]
    journal_path: str
    idempotent: bool


@dataclasses.dataclass(frozen=True)
class RollbackResult:
    project_id: str
    stage: str
    artifact_ref_retained: bool
    source_commit: str | None
    journal_path: str
    idempotent: bool


class ArtifactMigrationCoordinator:
    """One-project, journaled phase-8 migration coordinator."""

    def __init__(
        self,
        repo_path: str | os.PathLike[str],
        project_id: str,
        state_root: str | os.PathLike[str],
        *,
        registry_path: str | os.PathLike[str],
        runs_db_path: str | os.PathLike[str] | None = None,
        graphify_path: str | os.PathLike[str] | None = None,
        device_id: str = "migration-device",
        provider: str | None = None,
        failure_injector: Callable[[str], None] | None = None,
        remote_timeout_seconds: float = 15.0,
    ) -> None:
        self.repo = Path(repo_path).expanduser().resolve()
        self.project_id = project_id
        self.state_root = Path(state_root).expanduser().resolve()
        self.registry_path = Path(registry_path).expanduser().resolve()
        self.runs_db_path = (
            Path(runs_db_path).expanduser().resolve() if runs_db_path is not None else None
        )
        self.graphify_path = (
            Path(graphify_path).expanduser().resolve() if graphify_path is not None else None
        )
        self.device_id = device_id
        self.provider = provider
        self.failure_injector = failure_injector
        self.remote_timeout_seconds = max(1.0, float(remote_timeout_seconds))
        self.store = ArtifactStore(
            self.repo,
            project_id,
            self.state_root,
            enabled=True,
        )
        self.migration_root = self.store.project_state / "legacy-migration"
        self.journal_path = self.migration_root / "journal.json"
        self.preview_path = self.migration_root / "preflight.json"
        self.registry_backup_path = self.migration_root / "registry-v2.before.json"
        self.legacy_backup_path = self.migration_root / "legacy-tree"
        self.graphify_backup_path = self.migration_root / "graphify.before.db"
        self.graphify_rebuild_backup_path = self.migration_root / "graphify.pre-rebuild.db"

    # ------------------------------------------------------------------
    # Public workflow
    # ------------------------------------------------------------------

    def preview(self) -> MigrationPreview:
        """Perform the complete phase-8 preflight without writing any state."""
        blockers: list[dict[str, str]] = []
        git_state: dict[str, Any] = {}
        manifest: dict[str, Any] = {}
        registry_record: dict[str, Any] = {}
        run_references: tuple[Mapping[str, Any], ...] = ()
        program_references: tuple[Mapping[str, Any], ...] = ()
        remote: dict[str, Any] = {"mode": "local_only", "name": None, "state": "not_configured"}
        common_directory = ""
        source_branch = ""
        default_branch = ""
        source_head = ""

        try:
            source_head = self._git_text("rev-parse", "--verify", "HEAD")
            source_branch = self._git_text("symbolic-ref", "--quiet", "--short", "HEAD")
            common_directory = self._absolute_git_path(
                self._git_text("rev-parse", "--path-format=absolute", "--git-common-dir")
            )
            if self._git_text("rev-parse", "--is-bare-repository") == "true":
                self._block(
                    blockers,
                    "bare_repository",
                    "The selected project is a bare repository.",
                    "Select a normal registered worktree and rerun preflight.",
                )
            default_branch = self._default_branch(source_branch)
            git_state = self._git_state(source_branch=source_branch, source_head=source_head)
        except (ArtifactMigrationError, subprocess.SubprocessError, OSError) as error:
            self._block(
                blockers,
                "git_identity",
                str(error),
                "Repair the repository identity or select the correct registered worktree.",
            )

        try:
            registry_record = self._registry_record(common_directory=common_directory)
            remote = self._remote_preflight(registry_record)
        except ArtifactMigrationError as error:
            self._block(blockers, "registry_identity", str(error), error.recovery)

        try:
            manifest = self._legacy_manifest()
        except ArtifactMigrationError as error:
            self._block(blockers, "legacy_tree", str(error), error.recovery)

        try:
            run_references = self._run_references()
            active = [row for row in run_references if row.get("state") in ACTIVE_RUN_STATES]
            if active:
                ids = ", ".join(str(row.get("id")) for row in active)
                self._block(
                    blockers,
                    "active_runs",
                    f"Project has active or review-blocking runs: {ids}.",
                    "Drain, finish, cancel, or explicitly reconcile those runs before migration.",
                )
        except ArtifactMigrationError as error:
            self._block(blockers, "run_ledger", str(error), error.recovery)

        try:
            program_references = self._program_references()
        except ArtifactMigrationError as error:
            self._block(blockers, "program_store", str(error), error.recovery)

        if manifest and source_head:
            local_ref = self._optional_git_text("rev-parse", "--verify", ARTIFACT_REF)
            if local_ref:
                journal = self._load_journal()
                expected = str(journal.get("artifact_commit") or "")
                expected_manifest = str(journal.get("manifest_digest") or "")
                digest = _json_digest(manifest)
                if local_ref != expected or digest != expected_manifest:
                    self._block(
                        blockers,
                        "unexpected_artifact_ref",
                        f"{ARTIFACT_REF} already exists at {local_ref} without a matching migration journal.",
                        "Stop and reconcile the existing artifact identity/history; do not overwrite the ref.",
                    )

        manifest_digest = _json_digest(manifest) if manifest else ""
        return MigrationPreview(
            project_id=self.project_id,
            repo_path=str(self.repo),
            common_directory=common_directory,
            source_branch=source_branch,
            default_branch=default_branch,
            source_head=source_head,
            manifest=manifest,
            manifest_digest=manifest_digest,
            registry_record=registry_record,
            git=git_state,
            run_references=run_references,
            program_references=program_references,
            remote=remote,
            blockers=tuple(blockers),
        )

    def migrate(
        self,
        *,
        confirm_source_cleanup: bool,
        confirm_first_push: bool = False,
    ) -> MigrationResult:
        """Run or resume migration; source cutover always needs explicit confirmation."""
        if not confirm_source_cleanup:
            raise ArtifactMigrationBlocked(
                "Source cleanup was not explicitly confirmed; no migration write was made.",
                recovery="Review the preflight manifest and rerun with source cleanup confirmed.",
            )
        with self.store._writer_lock():
            journal = self._load_journal()
            if journal.get("stage") == "complete":
                return self._result_from_journal(journal, idempotent=True)
            if journal.get("stage") == "rolled_back":
                raise ArtifactMigrationBlocked(
                    "This migration journal is rolled back.",
                    recovery="Start a new explicitly reviewed migration after resolving the rollback state.",
                    report=journal,
                )

            if not journal:
                preview = self.preview()
                if not preview.can_migrate:
                    raise ArtifactMigrationBlocked(
                        "Migration preflight found blockers.",
                        recovery="Resolve every reported blocker, then rerun the read-only preflight.",
                        report=preview.as_dict(),
                    )
                journal = self._begin_journal(preview)
                self._inject("after_preflight_journal")
            else:
                self._validate_resume_identity(journal)

            self._ensure_backups(journal)
            stage = str(journal.get("stage") or "preflight_recorded")
            if stage == "preflight_recorded":
                journal = self._bootstrap(journal, confirm_first_push=confirm_first_push)
                self._inject("after_artifact_bootstrap")

            stage = str(journal.get("stage"))
            if stage == "bootstrap_verified":
                journal = self._finish_remote(journal, confirm_first_push=confirm_first_push)
                self._inject("after_remote")

            stage = str(journal.get("stage"))
            if stage == "remote_verified":
                journal = self._source_cutover(journal)
                self._inject("after_source_commit")

            stage = str(journal.get("stage"))
            if stage == "source_cutover":
                current_head = self.store.recover()
                journal["artifact_commit"] = current_head
                journal["stage"] = "materialized"
                self._write_journal(journal)
                self._inject("after_materialize")

            stage = str(journal.get("stage"))
            if stage == "materialized":
                journal = self._migrate_program_and_rebuild(journal)
                self._inject("after_program_export")

            stage = str(journal.get("stage"))
            if stage == "program_rebuilt":
                journal["retention_preview"] = self._retention_preview()
                journal["artifact_commit"] = self.store.snapshot().commit_id
                journal["stage"] = "retention_previewed"
                self._write_journal(journal)

            if journal.get("stage") == "retention_previewed":
                if journal.get("remote_result", {}).get("mode") == "enabled":
                    journal["remote_result"] = self._push_current_artifact(journal)
                journal["completed_at"] = _now_iso()
                journal["rollback"] = self._rollback_instructions(journal)
                journal["stage"] = "complete"
                self._inject("before_complete")
                self._write_journal(journal)

            return self._result_from_journal(journal, idempotent=False)

    def rollback(self) -> RollbackResult:
        """Roll back writer ownership while retaining all artifact history."""
        with self.store._writer_lock():
            journal = self._load_journal()
            if not journal:
                raise ArtifactMigrationBlocked(
                    "No migration journal exists for this project.",
                    recovery="Run migration preflight first; there is no recorded rollback authority.",
                )
            if journal.get("stage") == "rolled_back":
                return RollbackResult(
                    self.project_id,
                    "rolled_back",
                    True,
                    journal.get("rollback_source_commit"),
                    str(self.journal_path),
                    True,
                )
            self._validate_resume_identity(journal, allow_legacy_materialization=True)
            source_commit: str | None = None
            cutover_happened = bool(journal.get("source_commit"))
            if cutover_happened:
                expected_artifact = str(journal.get("artifact_commit") or "")
                current_artifact = self._optional_git_text("rev-parse", "--verify", ARTIFACT_REF)
                if current_artifact != expected_artifact:
                    self._reconciliation(
                        "Artifact history advanced after migration; rollback cannot choose between writes.",
                        "Reconcile immutable Relay event IDs, then record the chosen artifact head explicitly.",
                        journal,
                    )
                if not self.legacy_backup_path.is_dir():
                    raise ArtifactMigrationBlocked(
                        "The recorded legacy-tree backup is missing.",
                        recovery="Restore the exact journal backup before attempting rollback.",
                        report=journal,
                    )
                source_commit = self._restore_source_commit(journal)
                self._restore_legacy_materialization()
                self._remove_local_exclude()
                self.store.metadata_path.unlink(missing_ok=True)
                self.store.journal_path.unlink(missing_ok=True)
            self._restore_registry_backup()
            journal.update(
                {
                    "stage": "rolled_back",
                    "rolled_back_at": _now_iso(),
                    "rollback_source_commit": source_commit,
                    "artifact_ref_retained": True,
                    "remote_ref_retained": True,
                }
            )
            self._write_journal(journal)
            return RollbackResult(
                self.project_id,
                "rolled_back",
                True,
                source_commit,
                str(self.journal_path),
                False,
            )

    # ------------------------------------------------------------------
    # Preflight
    # ------------------------------------------------------------------

    def _registry_record(self, *, common_directory: str) -> dict[str, Any]:
        try:
            document = json.loads(self.registry_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ArtifactMigrationBlocked(
                f"Registry-v2 cannot be read: {error}",
                recovery="Restore a valid registry-v2 primary or backup before migration.",
            ) from error
        if not isinstance(document, dict) or document.get("schema_version") != 2:
            raise ArtifactMigrationBlocked(
                "Migration requires registry-v2 schema 2.",
                recovery="Complete RR-281 registry migration and re-confirm this project first.",
            )
        matches = [
            record
            for record in document.get("projects", [])
            if isinstance(record, dict) and record.get("project_id") == self.project_id
        ]
        if len(matches) != 1:
            raise ArtifactMigrationBlocked(
                f"Registry-v2 has {len(matches)} records for project {self.project_id!r}.",
                recovery="Resolve the missing or duplicate immutable project identity.",
            )
        record = dict(matches[0])
        if record.get("availability") != "available":
            raise ArtifactMigrationBlocked(
                f"Registered project availability is {record.get('availability')!r}.",
                recovery="Locate/regrant the project and confirm it is available before migration.",
            )
        resolved = str(record.get("last_resolved_path") or "").strip()
        if not resolved or Path(resolved).expanduser().resolve() != self.repo:
            raise ArtifactMigrationBlocked(
                "Registry-v2 resolved path does not identify the selected repository.",
                recovery="Re-resolve the registered project path and reconfirm project scope.",
            )
        fingerprint = str(record.get("git_common_directory_fingerprint") or "")
        if not fingerprint.startswith("git-common-v1:") or not common_directory:
            raise ArtifactMigrationBlocked(
                "Registry-v2 has no confirmed Git common-directory identity.",
                recovery="Re-register the project to refresh its common-directory fingerprint.",
            )
        remote = record.get("remote")
        if not isinstance(remote, dict):
            raise ArtifactMigrationBlocked(
                "Registry-v2 remote metadata is missing.",
                recovery="Choose local-only or an explicit existing remote in Workspace.",
            )
        artifact_ref = remote.get("artifactRef", remote.get("artifact_ref"))
        if artifact_ref != ARTIFACT_REF:
            raise ArtifactMigrationBlocked(
                f"Registry-v2 selects unsupported artifact ref {artifact_ref!r}.",
                recovery=f"Set the project artifact ref to {ARTIFACT_REF}.",
            )
        return record

    def _legacy_manifest(self) -> dict[str, Any]:
        root = self.repo / ".orchestrator"
        if root.is_symlink() or not root.is_dir():
            raise ArtifactMigrationBlocked(
                "Legacy .orchestrator must be a normal directory.",
                recovery="Replace unsupported symlink/non-directory input with the reviewed legacy tree.",
            )
        files: dict[str, dict[str, Any]] = {}
        contents: dict[str, bytes] = {}
        for directory, directory_names, filenames in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            for name in directory_names:
                child = directory_path / name
                if child.is_symlink():
                    raise ArtifactMigrationBlocked(
                        f"Unsupported symlink directory: {child.relative_to(self.repo)}",
                        recovery="Replace the symlink with reviewed regular artifact files.",
                    )
            for name in filenames:
                path = directory_path / name
                relative = path.relative_to(self.repo).as_posix()
                if path.is_symlink() or not path.is_file():
                    raise ArtifactMigrationBlocked(
                        f"Unsupported non-regular legacy path: {relative}",
                        recovery="Replace symlinks/submodules/special files with reviewed regular files.",
                    )
                self._validate_legacy_path(relative)
                content = path.read_bytes()
                stat = path.stat()
                files[relative] = {
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "bytes": len(content),
                    "mtime_ns": int(stat.st_mtime_ns),
                    "tracked": False,
                }
                contents[relative] = content
        if ".orchestrator/config.toml" not in contents:
            raise ArtifactMigrationBlocked(
                "Legacy tree has no config.toml.",
                recovery="Restore a valid legacy config with prefix and next_id.",
            )

        tracked = self._tracked_orchestrator_entries()
        for path, mode in tracked.items():
            if mode != "100644":
                raise ArtifactMigrationBlocked(
                    f"Tracked legacy path has unsupported Git mode {mode}: {path}",
                    recovery="Replace symlink/gitlink modes with reviewed regular files before migration.",
                )
            if path in files:
                files[path]["tracked"] = True

        try:
            config = tomllib.loads(contents[".orchestrator/config.toml"].decode("utf-8"))
        except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
            raise ArtifactMigrationBlocked(
                f"Legacy config is malformed: {error}",
                recovery="Repair config.toml without discarding prefix/next_id evidence.",
            ) from error
        unknown = set(config) - _LEGACY_CONFIG_KEYS
        if unknown:
            raise ArtifactMigrationBlocked(
                "Legacy config contains ambiguous fields: " + ", ".join(sorted(unknown)),
                recovery="Review those fields and reconcile any prior artifact rollout before migration.",
            )
        prefix = str(config.get("prefix") or "").strip()
        next_id = config.get("next_id")
        if not prefix or not prefix.isalnum() or not isinstance(next_id, int) or isinstance(next_id, bool) or next_id <= 0:
            raise ArtifactMigrationBlocked(
                "Legacy config requires an alphanumeric prefix and positive integer next_id.",
                recovery="Repair config.toml using the last verified ticket allocation state.",
            )

        ticket_ids: set[str] = set()
        dependencies: dict[str, list[str]] = {}
        referenced_attachments: dict[str, list[str]] = {}
        projected: dict[str, dict[str, Any]] = {}
        for relative, content in sorted(contents.items()):
            pure = PurePosixPath(relative)
            if len(pure.parts) != 2 or pure.suffix != ".md":
                continue
            ticket_id = pure.stem
            try:
                ticket = parse_ticket(content.decode("utf-8"))
            except (UnicodeDecodeError, TicketParseError, ValueError) as error:
                raise ArtifactMigrationBlocked(
                    f"Malformed ticket {relative}: {error}",
                    recovery="Repair the ticket frontmatter/body and rerun preflight.",
                ) from error
            if ticket["id"] != ticket_id or ticket_id in ticket_ids:
                raise ArtifactMigrationBlocked(
                    f"Ticket identity does not match its unique filename: {relative}",
                    recovery="Resolve duplicate/mismatched ticket IDs without inventing provenance.",
                )
            ticket_ids.add(ticket_id)
            dependencies[ticket_id] = list(ticket["depends_on"])
            references = self._attachment_references(ticket["body"])
            referenced_attachments[ticket_id] = references
            for reference in references:
                expected = f".orchestrator/{reference}"
                if expected not in contents:
                    raise ArtifactMigrationBlocked(
                        f"Ticket {ticket_id} references missing attachment {reference}.",
                        recovery="Restore the referenced bytes or remove the reviewed broken reference.",
                    )
                parts = PurePosixPath(reference).parts
                if len(parts) != 3 or parts[1] != ticket_id:
                    raise ArtifactMigrationBlocked(
                        f"Ticket {ticket_id} references attachment outside its owned directory: {reference}",
                        recovery="Move the attachment under attachments/<ticket-id>/ and update the ticket.",
                    )
            activity = _front_value(content, "activity_at") or _mtime_iso(files[relative]["mtime_ns"])
            artifact_id = _ticket_front_matter_value(content, "artifact_id") or _artifact_id(
                self.project_id, ticket_id
            )
            migrated = _set_frontmatter_defaults(
                content,
                ticket_id=ticket_id,
                artifact_id=artifact_id,
                activity_at=activity,
            )
            projected[relative] = {
                "source_sha256": files[relative]["sha256"],
                "artifact_sha256": hashlib.sha256(migrated).hexdigest(),
                "artifact_id": artifact_id,
                "activity_at": activity,
            }
            if len(migrated) > TICKET_MAX_BYTES:
                raise ArtifactMigrationBlocked(
                    f"Ticket {ticket_id} exceeds the artifact size limit after identity anchors.",
                    recovery="Refine or split the ticket without discarding durable evidence.",
                )
            try:
                _reject_secrets(migrated, f"ticket {ticket_id}")
            except ArtifactStoreError as error:
                raise ArtifactMigrationBlocked(
                    f"Ticket {ticket_id} failed the artifact privacy gate: {error}",
                    recovery="Remove/rotate the sensitive value before any Git artifact bootstrap.",
                ) from error

        for relative in contents:
            pure = PurePosixPath(relative)
            if len(pure.parts) == 4 and pure.parts[:2] == (".orchestrator", "attachments"):
                owner = pure.parts[2]
                if owner not in ticket_ids:
                    raise ArtifactMigrationBlocked(
                        f"Attachment has no owning ticket: {relative}",
                        recovery="Restore its ticket or remove the reviewed orphan attachment.",
                    )
                try:
                    mime_type = _attachment_mime_for_filename(pure.name)
                    _validate_attachment(pure.name, mime_type, contents[relative])
                except ArtifactStoreError as error:
                    raise ArtifactMigrationBlocked(
                        f"Unsupported attachment {relative}: {error}",
                        recovery="Move unsupported/private/oversized data outside Relay artifact storage.",
                    ) from error

        if ".orchestrator/archive-index.jsonl" in contents:
            try:
                _validate_archive_index(contents[".orchestrator/archive-index.jsonl"])
            except ArtifactStoreError as error:
                raise ArtifactMigrationBlocked(
                    f"Legacy archive catalog is invalid: {error}",
                    recovery="Repair the catalog from verified historical evidence before migration.",
                ) from error
        for relative, content in contents.items():
            pure = PurePosixPath(relative)
            if len(pure.parts) == 4 and pure.parts[:3] == (".orchestrator", "program", "events"):
                try:
                    self.store._prepare_program_event(pure.stem, content)
                except ArtifactStoreError as error:
                    raise ArtifactMigrationBlocked(
                        f"Legacy Program event {relative} is invalid: {error}",
                        recovery="Reconcile the durable Program event identity/privacy fields.",
                    ) from error

        config_bytes = self._artifact_config(prefix, int(next_id), remote_mode="local_only")
        projected[".orchestrator/config.toml"] = {
            "source_sha256": files[".orchestrator/config.toml"]["sha256"],
            "artifact_sha256": hashlib.sha256(config_bytes).hexdigest(),
        }
        if ".orchestrator/archive-index.jsonl" not in contents:
            projected[".orchestrator/archive-index.jsonl"] = {
                "source_sha256": None,
                "artifact_sha256": hashlib.sha256(b"").hexdigest(),
                "catalog_anchor": True,
            }
        return {
            "schema_version": MIGRATION_SCHEMA_VERSION,
            "project_id": self.project_id,
            "files": dict(sorted(files.items())),
            "tickets": sorted(ticket_ids),
            "dependencies": dict(sorted(dependencies.items())),
            "referenced_attachments": dict(sorted(referenced_attachments.items())),
            "projected": dict(sorted(projected.items())),
            "legacy_config": {"prefix": prefix, "next_id": int(next_id)},
            "source_tree_sha256": _file_manifest_digest(files),
        }

    def _validate_legacy_path(self, relative: str) -> None:
        pure = PurePosixPath(relative)
        allowed = relative in {
            ".orchestrator/config.toml",
            ".orchestrator/archive-index.jsonl",
        }
        allowed = allowed or (
            len(pure.parts) == 2
            and pure.parts[0] == ".orchestrator"
            and pure.suffix == ".md"
        )
        allowed = allowed or (
            len(pure.parts) == 4
            and pure.parts[:2] == (".orchestrator", "attachments")
        )
        allowed = allowed or (
            len(pure.parts) == 4
            and pure.parts[:3] == (".orchestrator", "program", "events")
            and pure.suffix == ".json"
        )
        if not allowed:
            raise ArtifactMigrationBlocked(
                f"Legacy path is outside the artifact allowlist: {relative}",
                recovery="Classify and relocate the file before migration; do not silently drop it.",
            )

    def _run_references(self) -> tuple[Mapping[str, Any], ...]:
        if self.runs_db_path is None or not self.runs_db_path.exists():
            return ()
        uri = f"file:{self.runs_db_path}?mode=ro"
        try:
            connection = sqlite3.connect(uri, uri=True)
            connection.row_factory = sqlite3.Row
            try:
                table = connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='runs'"
                ).fetchone()
                if table is None:
                    raise sqlite3.DatabaseError("runs table is missing")
                rows = connection.execute(
                    "SELECT * FROM runs WHERE repo_path = ? ORDER BY id", (str(self.repo),)
                ).fetchall()
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise ArtifactMigrationBlocked(
                f"Runs ledger cannot prove quiescence: {error}",
                recovery="Repair or restore runs.db, then verify no active/review-blocking run remains.",
            ) from error
        safe_fields = (
            "id", "ticket_id", "state", "attempt", "started_at", "ended_at",
            "activity_at", "provider_key", "execution_mode",
        )
        return tuple({field: row[field] for field in safe_fields if field in row.keys()} for row in rows)

    def _program_references(self) -> tuple[Mapping[str, Any], ...]:
        if self.graphify_path is None or not self.graphify_path.exists():
            return ()
        uri = f"file:{self.graphify_path}?mode=ro"
        try:
            connection = sqlite3.connect(uri, uri=True)
            connection.row_factory = sqlite3.Row
            try:
                project = connection.execute(
                    "SELECT id FROM graph_nodes WHERE kind='Project' AND stable_key=?",
                    (f"repo:{self.repo}",),
                ).fetchone()
                if project is None:
                    return ()
                rows = connection.execute(
                    "SELECT id, kind, stable_key, body_json FROM graph_nodes "
                    "WHERE project_id=? AND kind IN ('ProgramEvent','Decision','Risk','Idea','Status') "
                    "ORDER BY kind, stable_key",
                    (project["id"],),
                ).fetchall()
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise ArtifactMigrationBlocked(
                f"Graphify project records cannot be inspected: {error}",
                recovery="Restore the Graphify backup or explicitly rebuild it before migration.",
            ) from error
        result = []
        for row in rows:
            result.append(
                {
                    "id": row["id"],
                    "kind": row["kind"],
                    "stable_key": row["stable_key"],
                    "body_sha256": hashlib.sha256(str(row["body_json"]).encode()).hexdigest(),
                }
            )
        return tuple(result)

    def _remote_preflight(self, registry_record: Mapping[str, Any]) -> dict[str, Any]:
        metadata = registry_record.get("remote")
        assert isinstance(metadata, dict)
        mode = str(metadata.get("mode") or "local_only")
        name = metadata.get("remoteName", metadata.get("remote_name"))
        if mode == "local_only" or not name:
            return {"mode": "local_only", "name": None, "state": "not_configured"}
        name = str(name)
        if not _REMOTE_NAME_RE.fullmatch(name):
            raise ArtifactMigrationBlocked(
                f"Configured remote name is invalid: {name!r}",
                recovery="Choose an existing safe Git remote name.",
            )
        remotes = {entry["name"]: entry for entry in self._remote_records()}
        if name not in remotes:
            raise ArtifactMigrationBlocked(
                f"Configured artifact remote {name!r} does not exist.",
                recovery="Restore that remote or switch the project to local-only before migration.",
            )
        output = self._run_git(
            "ls-remote", "--refs", name, ARTIFACT_REF,
            timeout=self.remote_timeout_seconds,
            allowed_statuses={0},
        ).stdout.decode("utf-8", errors="replace").strip()
        if not output:
            state = "ref_absent"
            oid = None
        else:
            fields = output.split()
            if len(fields) != 2 or fields[1] != ARTIFACT_REF or not _HEX_OID_RE.fullmatch(fields[0]):
                raise ArtifactMigrationBlocked(
                    "Remote artifact discovery returned an ambiguous result.",
                    recovery="Inspect the remote ref manually and resolve it before migration.",
                )
            state = "ref_present"
            oid = fields[0]
        return {
            "mode": mode,
            "name": name,
            "state": state,
            "oid": oid,
            "locator": remotes[name]["locator"],
            "url_sha256": remotes[name]["url_sha256"],
        }

    # ------------------------------------------------------------------
    # Mutation stages
    # ------------------------------------------------------------------

    def _begin_journal(self, preview: MigrationPreview) -> dict[str, Any]:
        self.migration_root.mkdir(parents=True, exist_ok=True)
        journal = {
            "schema_version": MIGRATION_SCHEMA_VERSION,
            "project_id": self.project_id,
            "repo_path": str(self.repo),
            "stage": "preflight_recorded",
            "started_at": _now_iso(),
            "manifest": preview.manifest,
            "manifest_digest": preview.manifest_digest,
            "source_branch": preview.source_branch,
            "default_branch": preview.default_branch,
            "source_head_before": preview.source_head,
            "common_directory": preview.common_directory,
            "git_before": preview.git,
            "registry_record": preview.registry_record,
            "run_references": list(preview.run_references),
            "program_references": list(preview.program_references),
            "remote_preflight": preview.remote,
            "rollback": {
                "before_cutover": "Retain the orphan artifact ref, restore registry backup, and keep the legacy writer authoritative.",
                "after_cutover": "Freeze writers, reconcile event IDs if the artifact head advanced, then restore the exact legacy backup in a new source commit.",
            },
        }
        self._write_json(self.preview_path, preview.as_dict())
        self._write_journal(journal)
        return journal

    def _ensure_backups(self, journal: dict[str, Any]) -> None:
        if not self.registry_backup_path.exists():
            self.registry_backup_path.parent.mkdir(parents=True, exist_ok=True)
            self.registry_backup_path.write_bytes(self.registry_path.read_bytes())
            os.chmod(self.registry_backup_path, 0o600)
        if not self.legacy_backup_path.exists():
            temporary = self.legacy_backup_path.with_name(
                self.legacy_backup_path.name + f".{uuid.uuid4().hex}.tmp"
            )
            self._copy_regular_tree(self.repo / ".orchestrator", temporary)
            os.replace(temporary, self.legacy_backup_path)
        backup_manifest = self._directory_manifest(self.legacy_backup_path, prefix=".orchestrator")
        if _file_manifest_digest(backup_manifest) != journal["manifest"]["source_tree_sha256"]:
            raise ArtifactMigrationBlocked(
                "The recoverable legacy backup does not match the preflight manifest.",
                recovery="Restore or recreate the exact backup before any cutover write.",
                report=journal,
            )
        journal["registry_backup"] = str(self.registry_backup_path)
        journal["legacy_backup"] = str(self.legacy_backup_path)
        self._write_journal(journal)

    def _bootstrap(self, journal: dict[str, Any], *, confirm_first_push: bool) -> dict[str, Any]:
        remote = journal.get("remote_preflight") or {}
        remote_enabled = bool(
            remote.get("name")
            and (
                remote.get("state") == "ref_present"
                or (remote.get("state") == "ref_absent" and confirm_first_push)
            )
        )
        operations, projected_hashes = self._bootstrap_operations(
            journal["manifest"], remote_mode="enabled" if remote_enabled else "local_only"
        )
        if remote.get("state") == "ref_present":
            remote_snapshot = self._inspect_remote_artifact(str(remote["name"]))
            self._verify_projected_hashes(remote_snapshot["files"], projected_hashes)
            self._run_git(
                "fetch", "--no-tags", str(remote["name"]), f"{ARTIFACT_REF}:{ARTIFACT_REF}",
                timeout=self.remote_timeout_seconds,
            )
            artifact_commit = self._git_text("rev-parse", "--verify", ARTIFACT_REF)
            adopted = True
        else:
            mutation = ArtifactMutation(
                event_id=f"migration-bootstrap:{journal['manifest_digest'][:32]}",
                actor_type="migration",
                device_id=self.device_id,
                provider=self.provider,
                expected_base=None,
                operations=tuple(operations),
                summary="Bootstrap reviewed legacy Relay artifacts",
            )
            try:
                write = self.store.bootstrap_legacy(mutation)
            except ArtifactStoreError as error:
                raise ArtifactMigrationBlocked(
                    f"Artifact bootstrap failed validation: {error}",
                    recovery="Correct the exact reported legacy content; do not bypass the typed writer.",
                    report=journal,
                ) from error
            artifact_commit = write.commit_id
            adopted = write.idempotent
        snapshot = self.store.snapshot()
        self._verify_projected_hashes(snapshot.files, projected_hashes)
        journal.update(
            {
                "stage": "bootstrap_verified",
                "artifact_commit": artifact_commit,
                "artifact_tree": snapshot.tree_id,
                "artifact_file_hashes": dict(sorted(projected_hashes.items())),
                "artifact_adopted": adopted,
                "remote_mode": "enabled" if remote_enabled else "local_only",
            }
        )
        self._write_journal(journal)
        return journal

    def _finish_remote(self, journal: dict[str, Any], *, confirm_first_push: bool) -> dict[str, Any]:
        remote = journal.get("remote_preflight") or {}
        if journal.get("remote_mode") != "enabled":
            result = {
                "mode": "local_only",
                "state": "not_pushed",
                "reason": "No verified existing ref or explicitly confirmed first normal push.",
            }
        elif remote.get("state") == "ref_present":
            result = {
                "mode": "enabled",
                "state": "adopted_verified_ref",
                "remote": remote.get("name"),
                "commit": journal.get("artifact_commit"),
            }
        else:
            if not confirm_first_push:
                raise ArtifactMigrationBlocked(
                    "The first artifact push was not explicitly confirmed.",
                    recovery="Keep local-only, or rerun with a reviewed first normal push confirmation.",
                    report=journal,
                )
            result = self._push_current_artifact(journal, initial=True)
        self._write_registry_mode(str(result["mode"]), remote.get("name"))
        journal["remote_result"] = result
        journal["stage"] = "remote_verified"
        self._write_journal(journal)
        return journal

    def _source_cutover(self, journal: dict[str, Any]) -> dict[str, Any]:
        self._revalidate_unrelated_source(journal)
        expected_head = str(journal["source_head_before"])
        current_head = self._git_text("rev-parse", "--verify", "HEAD")
        if current_head != expected_head:
            self._reconciliation(
                f"Source HEAD changed after preflight: expected {expected_head}, found {current_head}.",
                "Review the new source commit and restart migration with a fresh manifest.",
                journal,
            )
        tracked_paths = sorted(
            path for path, meta in journal["manifest"]["files"].items() if meta.get("tracked")
        )
        if tracked_paths:
            source_commit = self._commit_source_without_orchestrator(
                parent=expected_head,
                branch=str(journal["source_branch"]),
                paths=tracked_paths,
                manifest_digest=str(journal["manifest_digest"]),
            )
        else:
            source_commit = expected_head
        journal["source_commit"] = source_commit
        journal["source_cleanup_paths"] = tracked_paths
        journal["stage"] = "source_cutover"
        self._write_journal(journal)
        self._verify_unrelated_source_after_cutover(journal)
        return journal

    def _migrate_program_and_rebuild(self, journal: dict[str, Any]) -> dict[str, Any]:
        report: dict[str, Any] = {"exported": 0, "rebuild": None}
        expected_manifest: dict[str, str] = {}
        if self.graphify_path is not None:
            graph = GraphifyCoreStore(self.graphify_path)
            if journal.get("program_references"):
                try:
                    export = export_graphify_project_captures(
                        graph,
                        self.store,
                        state_root=self.state_root,
                        device_id=self.device_id,
                        provider=self.provider,
                    )
                except ProgramArtifactMigrationError as error:
                    raise ArtifactMigrationBlocked(
                        f"Program capture export requires review: {error}",
                        recovery="Resolve every Program ownership issue in the export report.",
                        report=error.report,
                    ) from error
                report["exported"] = int(export.get("records") or 0)
                report["export"] = export
            documents = []
            for path, content in self.store.snapshot().files.items():
                if path.startswith(".orchestrator/program/events/"):
                    documents.append(json.loads(content))
            expected_manifest = expected_graph_manifest(documents)
            report["rebuild"] = replace_graphify_with_clean_rebuild(
                graphify_path=self.graphify_path,
                registry_path=self.registry_path,
                runs_db_path=self.runs_db_path,
                expected_capture_manifest=expected_manifest,
                backup_path=self.graphify_rebuild_backup_path,
            )
        journal["program_migration"] = report
        journal["program_manifest"] = expected_manifest
        journal["artifact_commit"] = self.store.snapshot().commit_id
        journal["stage"] = "program_rebuilt"
        self._write_journal(journal)
        return journal

    def _retention_preview(self) -> dict[str, Any]:
        plan = ArtifactRetentionManager(self.store, enabled=False).preview()
        return {
            "schema_version": plan.schema_version,
            "policy": plan.policy,
            "limit": plan.limit,
            "artifact_head": plan.artifact_head,
            "evaluated_at": plan.evaluated_at.isoformat(),
            "candidate_ids": list(plan.candidate_ids),
            "ranked_terminal_ids": [ticket.ticket_id for ticket in plan.ranked_terminal],
            "retained_terminal_ids": list(plan.retained_terminal_ids),
            "nonterminal_ids": list(plan.nonterminal_ids),
            "materialize_ids": list(plan.materialize_ids),
            "temporary_overage": {
                ticket.ticket_id: list(ticket.exemptions) for ticket in plan.exempt
            },
            "candidate_count": len(plan.candidates),
            "retained_terminal_count": len(plan.retained_terminal),
            "nonterminal_count": len(plan.nonterminal),
            "temporary_overage_count": len(plan.exempt),
            "transaction_state": "preview",
            "rollback": {
                "artifact_head": plan.artifact_head,
                "materialized_ticket_ids": sorted(
                    ticket.ticket_id
                    for ticket in (*plan.nonterminal, *plan.ranked_terminal)
                    if ticket.materialized
                ),
            },
            "committed": False,
        }

    # ------------------------------------------------------------------
    # Git and rollback mechanics
    # ------------------------------------------------------------------

    def _commit_source_without_orchestrator(
        self,
        *,
        parent: str,
        branch: str,
        paths: Sequence[str],
        manifest_digest: str,
    ) -> str:
        with tempfile.TemporaryDirectory(prefix="relay-migration-index-") as temporary:
            index = Path(temporary) / "index"
            env = self._git_environment({"GIT_INDEX_FILE": str(index)})
            self._run_git("read-tree", parent, env=env)
            self._run_git(
                "update-index", "-z", "--force-remove", "--stdin",
                env=env,
                input_bytes=b"\0".join(path.encode() for path in paths) + b"\0",
            )
            tree = self._run_git("write-tree", env=env).stdout.decode().strip()
            message = (
                "Stop tracking Relay artifact materialization\n\n"
                f"Relay-Migration-Project-ID: {self.project_id}\n"
                f"Relay-Migration-Manifest: {manifest_digest}\n"
                f"Relay-Artifact-Commit: {self.store.snapshot().commit_id}\n"
            ).encode()
            commit = self._run_git("commit-tree", tree, "-p", parent, input_bytes=message).stdout.decode().strip()
        branch_ref = f"refs/heads/{branch}"
        self._run_git("update-ref", branch_ref, commit, parent)
        self._run_git(
            "update-index", "-z", "--force-remove", "--stdin",
            input_bytes=b"\0".join(path.encode() for path in paths) + b"\0",
        )
        return commit

    def _restore_source_commit(self, journal: Mapping[str, Any]) -> str:
        parent = self._git_text("rev-parse", "--verify", "HEAD")
        branch = self._git_text("symbolic-ref", "--quiet", "--short", "HEAD")
        if branch != journal.get("source_branch"):
            self._reconciliation(
                f"Rollback is on branch {branch!r}, not recorded branch {journal.get('source_branch')!r}.",
                "Return to the recorded source branch or explicitly review a different rollback target.",
                journal,
            )
        backup_files = self._backup_bytes()
        with tempfile.TemporaryDirectory(prefix="relay-rollback-index-") as temporary:
            index = Path(temporary) / "index"
            env = self._git_environment({"GIT_INDEX_FILE": str(index)})
            self._run_git("read-tree", parent, env=env)
            for relative, content in sorted(backup_files.items()):
                path = f".orchestrator/{relative}"
                oid = self._run_git("hash-object", "-w", "--stdin", input_bytes=content).stdout.decode().strip()
                self._run_git(
                    "update-index", "--add", "--cacheinfo", "100644", oid, path, env=env
                )
            tree = self._run_git("write-tree", env=env).stdout.decode().strip()
            message = (
                "Restore legacy Relay ticket authority\n\n"
                f"Relay-Migration-Project-ID: {self.project_id}\n"
                f"Relay-Migration-Rollback: {journal['manifest_digest']}\n"
                "Relay-Artifact-Ref-Retained: true\n"
            ).encode()
            commit = self._run_git("commit-tree", tree, "-p", parent, input_bytes=message).stdout.decode().strip()
        self._run_git("update-ref", f"refs/heads/{branch}", commit, parent)
        for relative, content in sorted(backup_files.items()):
            path = f".orchestrator/{relative}"
            oid = self._run_git("hash-object", "-w", "--stdin", input_bytes=content).stdout.decode().strip()
            self._run_git("update-index", "--add", "--cacheinfo", "100644", oid, path)
        return commit

    def _restore_legacy_materialization(self) -> None:
        target = self.repo / ".orchestrator"
        temporary = self.repo / f".relay-legacy-rollback-{uuid.uuid4().hex}"
        self._copy_regular_tree(self.legacy_backup_path, temporary)
        displaced = self.migration_root / f"artifact-materialization-before-rollback-{int(time.time())}"
        if target.exists():
            os.replace(target, displaced)
        os.replace(temporary, target)

    def _remove_local_exclude(self) -> None:
        raw = self._git_text("rev-parse", "--git-path", "info/exclude")
        path = Path(raw)
        if not path.is_absolute():
            path = self.repo / path
        try:
            original = path.read_text(encoding="utf-8")
        except OSError:
            return
        lines = [line for line in original.splitlines() if line.strip() != "/.orchestrator/"]
        rendered = "\n".join(lines)
        if original.endswith("\n") and rendered:
            rendered += "\n"
        temporary = path.with_name(path.name + f".relay-{uuid.uuid4().hex}.tmp")
        temporary.write_text(rendered, encoding="utf-8")
        os.replace(temporary, path)

    # ------------------------------------------------------------------
    # Artifact projection and remote verification
    # ------------------------------------------------------------------

    def _bootstrap_operations(
        self, manifest: Mapping[str, Any], *, remote_mode: str
    ) -> tuple[list[Any], dict[str, str]]:
        source = self._backup_bytes()
        legacy = manifest["legacy_config"]
        config = self._artifact_config(
            str(legacy["prefix"]), int(legacy["next_id"]), remote_mode=remote_mode
        )
        operations: list[Any] = [ConfigWrite(config)]
        projected: dict[str, str] = {
            ".orchestrator/config.toml": hashlib.sha256(config).hexdigest()
        }
        archive_seen = False
        for relative, content in sorted(source.items()):
            path = f".orchestrator/{relative}"
            pure = PurePosixPath(path)
            if path == ".orchestrator/config.toml":
                continue
            if path == ".orchestrator/archive-index.jsonl":
                operations.append(ArchiveIndexWrite(content))
                projected[path] = hashlib.sha256(content).hexdigest()
                archive_seen = True
            elif len(pure.parts) == 2 and pure.suffix == ".md":
                ticket_id = pure.stem
                artifact_id = _ticket_front_matter_value(content, "artifact_id") or _artifact_id(
                    self.project_id, ticket_id
                )
                activity = _front_value(content, "activity_at")
                if activity is None:
                    activity = manifest["projected"][path]["activity_at"]
                migrated = _set_frontmatter_defaults(
                    content,
                    ticket_id=ticket_id,
                    artifact_id=artifact_id,
                    activity_at=activity,
                )
                operations.append(TicketWrite(ticket_id, artifact_id, migrated))
                projected[path] = hashlib.sha256(migrated).hexdigest()
            elif len(pure.parts) == 4 and pure.parts[:2] == (".orchestrator", "attachments"):
                mime = _attachment_mime_for_filename(pure.name)
                operations.append(AttachmentWrite(pure.parts[2], pure.name, mime, content))
                projected[path] = hashlib.sha256(content).hexdigest()
            elif len(pure.parts) == 4 and pure.parts[:3] == (".orchestrator", "program", "events"):
                event_id = pure.stem
                operations.append(ProgramEventWrite(event_id, content))
                canonical = (json.dumps(json.loads(content), sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
                projected[path] = hashlib.sha256(canonical).hexdigest()
        if not archive_seen:
            operations.append(ArchiveIndexWrite(b""))
            projected[".orchestrator/archive-index.jsonl"] = hashlib.sha256(b"").hexdigest()
        return operations, projected

    def _artifact_config(self, prefix: str, next_id: int, *, remote_mode: str) -> bytes:
        if remote_mode not in {"local_only", "enabled"}:
            raise ValueError(f"invalid migration remote mode: {remote_mode}")
        return (
            "schema_version = 2\n"
            f"project_id = {json.dumps(self.project_id)}\n"
            f"prefix = {json.dumps(prefix)}\n"
            f"artifact_ref = {json.dumps(ARTIFACT_REF)}\n"
            f"remote_sync = {json.dumps(remote_mode)}\n"
            'artifact_lifecycle = "enabled"\n'
            f"next_id = {next_id}\n"
        ).encode()

    def _verify_projected_hashes(
        self, files: Mapping[str, bytes], expected: Mapping[str, str]
    ) -> None:
        actual = {path: hashlib.sha256(content).hexdigest() for path, content in files.items()}
        if actual != dict(expected):
            missing = sorted(set(expected) - set(actual))
            extra = sorted(set(actual) - set(expected))
            changed = sorted(path for path in set(actual) & set(expected) if actual[path] != expected[path])
            raise ArtifactMigrationBlocked(
                "Artifact bootstrap failed byte-level round-trip verification.",
                recovery="Stop before source cleanup and review missing/extra/changed manifest paths.",
                report={"missing": missing, "extra": extra, "changed": changed},
            )

    def _inspect_remote_artifact(self, remote_name: str) -> dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="relay-remote-inspect-") as temporary:
            git_dir = Path(temporary) / "inspect.git"
            subprocess.run(["git", "init", "--bare", "--quiet", str(git_dir)], check=True)
            process = subprocess.run(
                [
                    "git", f"--git-dir={git_dir}", "fetch", "--no-tags",
                    str(self._remote_url(remote_name)),
                    f"{ARTIFACT_REF}:refs/heads/inspect",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.remote_timeout_seconds,
                check=False,
            )
            if process.returncode != 0:
                raise ArtifactMigrationBlocked(
                    "The configured remote artifact ref could not be inspected.",
                    recovery="Restore network/auth access or switch to explicit local-only migration.",
                )
            listing = subprocess.run(
                ["git", f"--git-dir={git_dir}", "ls-tree", "-r", "--name-only", "refs/heads/inspect"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            ).stdout.decode().splitlines()
            files = {}
            for path in listing:
                files[path] = subprocess.run(
                    ["git", f"--git-dir={git_dir}", "show", f"refs/heads/inspect:{path}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=True,
                ).stdout
            config = tomllib.loads(files.get(".orchestrator/config.toml", b"").decode())
            if config.get("project_id") != self.project_id:
                raise ArtifactMigrationBlocked(
                    f"Remote artifact ref belongs to project {config.get('project_id')!r}.",
                    recovery="Choose the correct remote/ref or explicitly reconcile the foreign identity.",
                )
            return {"files": files}

    def _push_current_artifact(
        self, journal: Mapping[str, Any], *, initial: bool = False
    ) -> dict[str, Any]:
        remote = journal.get("remote_preflight") or {}
        name = str(remote.get("name") or "")
        if not name:
            raise ArtifactMigrationBlocked(
                "Remote publication was requested without a selected remote.",
                recovery="Select a remote or remain local-only.",
                report=journal,
            )
        head = self.store.snapshot().commit_id
        result = self._run_git(
            "push", name, f"{head}:{ARTIFACT_REF}",
            timeout=self.remote_timeout_seconds,
            allowed_statuses={0, 1, 128},
        )
        if result.returncode != 0:
            raise ArtifactMigrationBlocked(
                "Normal artifact push was rejected; no force path was attempted.",
                recovery="Fetch/inspect the remote race or repair auth, then resume safely.",
                report={"remote": name, "stderr": _bounded_public_error(result.stderr)},
            )
        return {
            "mode": "enabled",
            "state": "first_push_verified" if initial else "pushed_current_head",
            "remote": name,
            "commit": head,
            "force": False,
            "source_ref_published": False,
        }

    # ------------------------------------------------------------------
    # State consistency helpers
    # ------------------------------------------------------------------

    def _validate_resume_identity(
        self, journal: Mapping[str, Any], *, allow_legacy_materialization: bool = False
    ) -> None:
        if (
            journal.get("schema_version") != MIGRATION_SCHEMA_VERSION
            or journal.get("project_id") != self.project_id
            or Path(str(journal.get("repo_path") or "")).resolve() != self.repo
        ):
            self._reconciliation(
                "Migration journal identity does not match this project.",
                "Select the recorded project/journal; never transplant migration state.",
                journal,
            )
        manifest = journal.get("manifest")
        if not isinstance(manifest, dict) or _json_digest(manifest) != journal.get("manifest_digest"):
            self._reconciliation(
                "Migration journal manifest is missing or tampered.",
                "Restore the immutable preflight journal/backup before resuming.",
                journal,
            )
        artifact_commit = str(journal.get("artifact_commit") or "")
        if artifact_commit:
            current = self._optional_git_text("rev-parse", "--verify", ARTIFACT_REF)
            if current != artifact_commit and journal.get("stage") not in {
                "materialized", "program_rebuilt", "retention_previewed", "complete"
            }:
                self._reconciliation(
                    f"Artifact ref changed during migration: expected {artifact_commit}, found {current}.",
                    "Reconcile immutable event IDs before resuming.",
                    journal,
                )
        if not allow_legacy_materialization and journal.get("source_commit"):
            current_source = self._git_text("rev-parse", "--verify", "HEAD")
            if current_source != journal.get("source_commit"):
                self._reconciliation(
                    "Source HEAD changed after migration cutover.",
                    "Review the new source history before resuming or rolling back.",
                    journal,
                )

    def _revalidate_unrelated_source(self, journal: Mapping[str, Any]) -> None:
        before = journal.get("git_before") or {}
        current = self._git_state(
            source_branch=str(journal["source_branch"]),
            source_head=self._git_text("rev-parse", "--verify", "HEAD"),
        )
        for field in ("unrelated_index_sha256", "unrelated_status_sha256", "remotes_sha256"):
            if current.get(field) != before.get(field):
                self._reconciliation(
                    f"Unrelated source state changed after preflight ({field}).",
                    "Review the unrelated source/index/remote change and restart with a fresh preflight.",
                    journal,
                )

    def _verify_unrelated_source_after_cutover(self, journal: Mapping[str, Any]) -> None:
        before = journal.get("git_before") or {}
        current = self._git_state(
            source_branch=str(journal["source_branch"]),
            source_head=self._git_text("rev-parse", "--verify", "HEAD"),
        )
        for field in ("unrelated_index_sha256", "unrelated_status_sha256", "remotes_sha256"):
            if current.get(field) != before.get(field):
                self._reconciliation(
                    f"Source cleanup changed unrelated state ({field}).",
                    "Stop before further writes and restore/reconcile using the journal.",
                    journal,
                )

    def _git_state(self, *, source_branch: str, source_head: str) -> dict[str, Any]:
        status = self._run_git("status", "--porcelain=v1", "-z", "--untracked-files=all").stdout
        unrelated_status = b"\0".join(
            record for record in status.split(b"\0") if record and b".orchestrator" not in record
        )
        index = self._run_git("ls-files", "--stage", "-z").stdout
        unrelated_index = b"\0".join(
            record for record in index.split(b"\0") if record and b"\t.orchestrator/" not in record
        )
        refs = self._ref_records()
        return {
            "source_branch": source_branch,
            "source_head": source_head,
            "status_sha256": hashlib.sha256(status).hexdigest(),
            "unrelated_status_sha256": hashlib.sha256(unrelated_status).hexdigest(),
            "index_sha256": hashlib.sha256(index).hexdigest(),
            "unrelated_index_sha256": hashlib.sha256(unrelated_index).hexdigest(),
            "refs": refs,
            "refs_sha256": _json_digest(refs),
            "remotes": self._remote_records(),
            "remotes_sha256": _json_digest(self._remote_records()),
        }

    def _tracked_orchestrator_entries(self) -> dict[str, str]:
        raw = self._run_git("ls-files", "--stage", "-z", "--", ".orchestrator").stdout
        result: dict[str, str] = {}
        for record in raw.split(b"\0"):
            if not record:
                continue
            metadata, separator, path = record.partition(b"\t")
            if not separator:
                continue
            fields = metadata.decode().split()
            result[path.decode()] = fields[0]
        return result

    def _ref_records(self) -> list[dict[str, str]]:
        output = self._run_git(
            "for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes"
        ).stdout.decode("utf-8", errors="replace")
        records = []
        for line in output.splitlines():
            ref, separator, oid = line.partition("\0")
            if separator:
                records.append({"ref": ref, "oid": oid})
        return records

    def _remote_records(self) -> list[dict[str, str]]:
        names = self._git_text("remote").splitlines()
        result = []
        for name in sorted(filter(None, names)):
            url = self._git_text("remote", "get-url", name)
            result.append(
                {
                    "name": name,
                    "locator": _safe_remote_locator(url),
                    "url_sha256": hashlib.sha256(url.encode()).hexdigest(),
                }
            )
        return result

    def _remote_url(self, remote_name: str) -> str:
        return self._git_text("remote", "get-url", remote_name)

    def _default_branch(self, source_branch: str) -> str:
        for remote in self._git_text("remote").splitlines():
            candidate = self._optional_git_text(
                "symbolic-ref", "--quiet", "--short", f"refs/remotes/{remote}/HEAD"
            )
            if candidate and "/" in candidate:
                return candidate.split("/", 1)[1]
        return source_branch

    def _write_registry_mode(self, mode: str, remote_name: object) -> None:
        document = json.loads(self.registry_path.read_text(encoding="utf-8"))
        matches = 0
        for record in document.get("projects", []):
            if not isinstance(record, dict) or record.get("project_id") != self.project_id:
                continue
            matches += 1
            remote = record.setdefault("remote", {})
            remote["mode"] = mode
            if "artifactRef" in remote:
                remote["artifactRef"] = ARTIFACT_REF
                remote["remoteName"] = remote_name if mode == "enabled" else None
            else:
                remote["artifact_ref"] = ARTIFACT_REF
                remote["remote_name"] = remote_name if mode == "enabled" else None
            record["updated_at"] = _now_iso()
        if matches != 1:
            raise ArtifactMigrationBlocked(
                "Registry identity changed after preflight.",
                recovery="Restore the registry backup and rerun preflight.",
            )
        self._write_json(self.registry_path, document)

    def _restore_registry_backup(self) -> None:
        if not self.registry_backup_path.exists():
            return
        temporary = self.registry_path.with_name(self.registry_path.name + f".{uuid.uuid4().hex}.tmp")
        temporary.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_bytes(self.registry_backup_path.read_bytes())
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.registry_path)

    # ------------------------------------------------------------------
    # Files, journal, and process helpers
    # ------------------------------------------------------------------

    def _backup_bytes(self) -> dict[str, bytes]:
        if not self.legacy_backup_path.is_dir():
            raise ArtifactMigrationBlocked(
                "Legacy backup is unavailable.",
                recovery="Restore the exact backup recorded by the journal.",
            )
        result = {}
        for path in sorted(self.legacy_backup_path.rglob("*")):
            if path.is_file() and not path.is_symlink():
                result[path.relative_to(self.legacy_backup_path).as_posix()] = path.read_bytes()
        return result

    def _copy_regular_tree(self, source: Path, destination: Path) -> None:
        if destination.exists():
            raise ArtifactMigrationBlocked(
                f"Migration temporary path already exists: {destination}",
                recovery="Review and remove only that recorded temporary path before resuming.",
            )
        destination.mkdir(parents=True, mode=0o700)
        for directory, directory_names, filenames in os.walk(source, followlinks=False):
            directory_path = Path(directory)
            relative_directory = directory_path.relative_to(source)
            target_directory = destination / relative_directory
            target_directory.mkdir(parents=True, exist_ok=True)
            for name in directory_names:
                if (directory_path / name).is_symlink():
                    raise ArtifactMigrationBlocked(
                        "Backup refused a symlinked legacy directory.",
                        recovery="Repair the legacy tree and restart preflight.",
                    )
            for name in filenames:
                path = directory_path / name
                if path.is_symlink() or not path.is_file():
                    raise ArtifactMigrationBlocked(
                        "Backup refused a non-regular legacy file.",
                        recovery="Repair the legacy tree and restart preflight.",
                    )
                target = target_directory / name
                target.write_bytes(path.read_bytes())
                os.chmod(target, 0o600)

    def _directory_manifest(self, root: Path, *, prefix: str) -> dict[str, dict[str, Any]]:
        result = {}
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            content = path.read_bytes()
            relative = f"{prefix}/{path.relative_to(root).as_posix()}"
            original = self._load_journal().get("manifest", {}).get("files", {}).get(relative, {})
            result[relative] = {
                "sha256": hashlib.sha256(content).hexdigest(),
                "bytes": len(content),
                "mtime_ns": original.get("mtime_ns", 0),
                "tracked": original.get("tracked", False),
            }
        return result

    def _attachment_references(self, body: str) -> list[str]:
        lines = body.splitlines()
        inside = False
        found: list[str] = []
        for line in lines:
            stripped = line.strip()
            lower = stripped.lower()
            if lower == "## attachments" or lower.startswith("## attachments "):
                inside = True
                continue
            if inside and stripped.startswith("#"):
                break
            if not inside:
                continue
            start = stripped.find("](")
            if start < 0:
                continue
            end = stripped.find(")", start + 2)
            if end < 0:
                continue
            destination = stripped[start + 2 : end]
            if destination.startswith("attachments/") and destination not in found:
                found.append(destination)
        return found

    def _load_journal(self) -> dict[str, Any]:
        try:
            value = json.loads(self.journal_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def _write_journal(self, journal: Mapping[str, Any]) -> None:
        self._write_json(self.journal_path, journal)

    def _write_json(self, path: Path, value: Mapping[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
        temporary.write_text(json.dumps(dict(value), sort_keys=True, indent=2) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)

    def _result_from_journal(self, journal: Mapping[str, Any], *, idempotent: bool) -> MigrationResult:
        return MigrationResult(
            project_id=self.project_id,
            stage=str(journal["stage"]),
            artifact_commit=str(journal["artifact_commit"]),
            source_commit=str(journal["source_commit"]) if journal.get("source_commit") else None,
            manifest_digest=str(journal["manifest_digest"]),
            remote_result=dict(journal.get("remote_result") or {}),
            retention_preview=dict(journal.get("retention_preview") or {}),
            journal_path=str(self.journal_path),
            idempotent=idempotent,
        )

    def _rollback_instructions(self, journal: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "journal": str(self.journal_path),
            "legacy_backup": str(self.legacy_backup_path),
            "registry_backup": str(self.registry_backup_path),
            "source_commit": journal.get("source_commit"),
            "artifact_commit": journal.get("artifact_commit"),
            "artifact_ref_retained": True,
            "remote_ref_retained": True,
            "command": f"relay-artifact-migrate rollback --repo {self.repo} --project-id {self.project_id}",
            "event_reconciliation": "Required if artifact head or legacy materialization advanced after cutover.",
        }

    def _inject(self, stage: str) -> None:
        if self.failure_injector is None:
            return
        try:
            self.failure_injector(stage)
        except ArtifactMigrationInjectedFailure:
            raise
        except Exception as error:
            raise ArtifactMigrationInjectedFailure(
                f"Injected migration interruption at {stage}: {error}",
                recovery="Resume with the same journal; do not delete refs or backups.",
                report={"stage": stage},
            ) from error

    def _reconciliation(
        self, message: str, recovery: str, report: Mapping[str, Any]
    ) -> None:
        raise ArtifactMigrationReconciliationRequired(message, recovery=recovery, report=report)

    @staticmethod
    def _block(
        blockers: list[dict[str, str]], kind: str, detail: str, recovery: str
    ) -> None:
        blockers.append({"kind": kind, "detail": detail, "recovery": recovery})

    def _absolute_git_path(self, raw: str) -> str:
        path = Path(raw)
        if not path.is_absolute():
            path = self.repo / path
        return str(path.resolve())

    def _git_environment(self, additions: Mapping[str, str] | None = None) -> dict[str, str]:
        env = dict(os.environ)
        for key in (
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_DIR",
            "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_WORK_TREE",
        ):
            env.pop(key, None)
        env.update(
            {
                "GIT_AUTHOR_NAME": "Relay Runner",
                "GIT_AUTHOR_EMAIL": "relay-runner@localhost",
                "GIT_COMMITTER_NAME": "Relay Runner",
                "GIT_COMMITTER_EMAIL": "relay-runner@localhost",
                "LC_ALL": "C",
                "GIT_OPTIONAL_LOCKS": "0",
            }
        )
        if additions:
            env.update(additions)
        return env

    def _run_git(
        self,
        *arguments: str,
        env: Mapping[str, str] | None = None,
        input_bytes: bytes | None = None,
        timeout: float | None = None,
        allowed_statuses: set[int] = {0},
    ) -> "_GitResult":
        try:
            process = subprocess.run(
                ["git", "-C", str(self.repo), *arguments],
                input=input_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=dict(env) if env is not None else self._git_environment(),
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise ArtifactMigrationBlocked(
                f"Git {' '.join(arguments)} timed out.",
                recovery="Restore responsive local/remote access, then rerun preflight.",
            ) from error
        result = _GitResult(process.returncode, process.stdout, process.stderr)
        if process.returncode not in allowed_statuses:
            raise ArtifactMigrationBlocked(
                f"Git {' '.join(arguments)} failed: {_bounded_public_error(result.stderr)}",
                recovery="Repair the exact Git condition and rerun the journaled step.",
            )
        return result

    def _git_text(self, *arguments: str) -> str:
        return self._run_git(*arguments).stdout.decode("utf-8", errors="replace").strip()

    def _optional_git_text(self, *arguments: str) -> str | None:
        result = self._run_git(*arguments, allowed_statuses={0, 1, 128})
        if result.returncode != 0:
            return None
        value = result.stdout.decode("utf-8", errors="replace").strip()
        return value or None


@dataclasses.dataclass(frozen=True)
class _GitResult:
    returncode: int
    stdout: bytes
    stderr: bytes


def _artifact_id(project_id: str, ticket_id: str) -> str:
    digest = hashlib.sha256(f"{project_id}:{ticket_id}".encode()).hexdigest()
    return f"ticket-{digest[:40]}"


def _front_value(content: bytes, key: str) -> str | None:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        field, separator, value = line.partition(":")
        if separator and field.strip() == key:
            return value.strip().strip("\"'") or None
    return None


def _set_frontmatter_defaults(
    content: bytes, *, ticket_id: str, artifact_id: str, activity_at: str
) -> bytes:
    text = content.decode("utf-8")
    lines = text.splitlines()
    closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    id_index = next(
        index
        for index in range(1, closing)
        if lines[index].partition(":")[0].strip() == "id"
    )
    insert_at = id_index + 1
    if _front_value(content, "artifact_id") is None:
        lines.insert(insert_at, f"artifact_id: {artifact_id}")
        closing += 1
        insert_at += 1
    if _front_value(content, "activity_at") is None:
        lines.insert(insert_at, f"activity_at: {activity_at}")
    return ("\n".join(lines).rstrip("\n") + "\n").encode("utf-8")


def _mtime_iso(mtime_ns: int) -> str:
    instant = datetime.fromtimestamp(mtime_ns / 1_000_000_000, tz=UTC)
    return instant.isoformat(timespec="microseconds").replace("+00:00", "Z")


def _now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _json_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def _file_manifest_digest(files: Mapping[str, Mapping[str, Any]]) -> str:
    evidence = {
        path: {
            "sha256": meta["sha256"],
            "bytes": meta["bytes"],
            "mtime_ns": meta["mtime_ns"],
            "tracked": bool(meta["tracked"]),
        }
        for path, meta in sorted(files.items())
    }
    return _json_digest(evidence)


def _safe_remote_locator(url: str) -> str:
    if "://" not in url:
        if "@" in url and ":" in url:
            host_path = url.split("@", 1)[1]
            return "ssh://" + host_path
        return "local-path:" + str(Path(url).expanduser())
    parsed = urlsplit(url)
    host = parsed.hostname or ""
    port = f":{parsed.port}" if parsed.port else ""
    path = parsed.path
    return urlunsplit((parsed.scheme, host + port, path, "", ""))


def _bounded_public_error(stderr: bytes) -> str:
    text = stderr.decode("utf-8", errors="replace").strip().replace("\n", " ")
    text = re.sub(r"(?i)(https?://)[^/@\s]+@", r"\1", text)
    return text[:500] or "unknown Git error"


__all__ = [
    "ACTIVE_RUN_STATES",
    "ArtifactMigrationBlocked",
    "ArtifactMigrationCoordinator",
    "ArtifactMigrationError",
    "ArtifactMigrationInjectedFailure",
    "ArtifactMigrationReconciliationRequired",
    "MigrationPreview",
    "MigrationResult",
    "RollbackResult",
]
