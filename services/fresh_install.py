#!/usr/bin/env python3
"""Supported Relay Runner reinstall and recoverable state-reset workflow.

Normal app replacement treats Application Support as immutable input and proves
that registered repositories and Relay state are unchanged.  A deliberate reset
is a separate, explicit operation: after quiescence confirmation it moves only
the Relay-owned state root to Trash and writes recovery evidence inside the moved
directory.  Registered repositories are never edited, removed, or rewritten.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping


RESET_ACTIVE_STATES = frozenset(
    {
        "Claimed", "Running", "SpikeResultReady", "AwaitingReview",
        "Reviewing", "MergeConflict", "IntegrationBlocked", "Succeeded",
    }
)


class FreshInstallError(RuntimeError):
    def __init__(self, message: str, *, recovery: str):
        super().__init__(message)
        self.recovery = recovery


class FreshInstallInjectedFailure(FreshInstallError):
    pass


@dataclasses.dataclass(frozen=True)
class FreshInstallPreview:
    action: str
    state_root: str
    state_manifest_sha256: str
    state_files: int
    registered_repositories: tuple[Mapping[str, Any], ...]
    active_run_ids: tuple[int, ...]
    source_app: str | None = None
    destination_app: str | None = None


@dataclasses.dataclass(frozen=True)
class FreshInstallResult:
    action: str
    state_preserved: bool
    repositories_preserved: bool
    destination_app: str | None = None
    recovery_manifest: str | None = None
    trashed_state: str | None = None
    replaced_app_backup: str | None = None


class FreshInstallCoordinator:
    def __init__(
        self,
        *,
        state_root: str | os.PathLike[str],
        trash_root: str | os.PathLike[str] | None = None,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        self.state_root = Path(state_root).expanduser().resolve()
        self.trash_root = (
            Path(trash_root).expanduser().resolve()
            if trash_root is not None
            else Path.home().joinpath(".Trash").resolve()
        )
        self.failure_injector = failure_injector
        self._validate_owned_state_root()

    def preview_reinstall(
        self,
        *,
        source_app: str | os.PathLike[str],
        destination_app: str | os.PathLike[str] = "/Applications/Relay Runner.app",
    ) -> FreshInstallPreview:
        source = Path(source_app).expanduser().resolve()
        destination = Path(destination_app).expanduser().resolve()
        self._validate_app_bundle(source)
        state = self._state_manifest()
        return FreshInstallPreview(
            action="reinstall",
            state_root=str(self.state_root),
            state_manifest_sha256=_json_digest(state),
            state_files=len(state),
            registered_repositories=tuple(self._registered_repository_snapshots()),
            active_run_ids=tuple(self._active_run_ids()),
            source_app=str(source),
            destination_app=str(destination),
        )

    def reinstall(
        self,
        *,
        source_app: str | os.PathLike[str],
        destination_app: str | os.PathLike[str] = "/Applications/Relay Runner.app",
        execute: bool,
    ) -> FreshInstallResult:
        if not execute:
            raise FreshInstallError(
                "Reinstall execution was not explicitly confirmed.",
                recovery="Review preview_reinstall output, then rerun with --execute.",
            )
        preview = self.preview_reinstall(source_app=source_app, destination_app=destination_app)
        state_before = self._state_manifest()
        repos_before = list(preview.registered_repositories)
        source = Path(preview.source_app or "")
        destination = Path(preview.destination_app or "")
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.parent / f".{destination.name}.relay-install-{uuid.uuid4().hex}"
        backup: Path | None = None
        try:
            shutil.copytree(source, temporary, symlinks=True)
            if self._bundle_manifest(temporary) != self._bundle_manifest(source):
                raise FreshInstallError(
                    "Copied app bundle failed byte-level verification.",
                    recovery="Keep the installed app unchanged and rebuild a valid source bundle.",
                )
            self._inject("before_app_replacement")
            if destination.exists() or destination.is_symlink():
                self.trash_root.mkdir(parents=True, exist_ok=True)
                backup = self.trash_root / (
                    f"Relay Runner.app-before-reinstall-{_timestamp()}-{uuid.uuid4().hex[:8]}"
                )
                os.replace(destination, backup)
            os.replace(temporary, destination)
            self._inject("after_app_replacement")
            if self._bundle_manifest(destination) != self._bundle_manifest(source):
                raise FreshInstallError(
                    "Installed app bundle differs from the reviewed source bundle.",
                    recovery="Restore the recoverable prior app and retry the install.",
                )
            self._verify_preserved(state_before, repos_before)
        except Exception:
            if temporary.exists() and temporary.is_dir() and not temporary.is_symlink():
                shutil.rmtree(temporary)
            if backup is not None and backup.exists():
                if destination.exists() or destination.is_symlink():
                    failed = self.trash_root / (
                        f"Relay Runner.app-failed-reinstall-{_timestamp()}-{uuid.uuid4().hex[:8]}"
                    )
                    os.replace(destination, failed)
                os.replace(backup, destination)
            raise
        return FreshInstallResult(
            action="reinstall",
            state_preserved=True,
            repositories_preserved=True,
            destination_app=str(destination),
            replaced_app_backup=str(backup) if backup else None,
        )

    def preview_reset(self) -> FreshInstallPreview:
        state = self._state_manifest()
        return FreshInstallPreview(
            action="reset_state",
            state_root=str(self.state_root),
            state_manifest_sha256=_json_digest(state),
            state_files=len(state),
            registered_repositories=tuple(self._registered_repository_snapshots()),
            active_run_ids=tuple(self._active_run_ids()),
        )

    def reset_state(
        self,
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
    ) -> FreshInstallResult:
        if not execute or not confirm_daemon_stopped:
            raise FreshInstallError(
                "State reset requires --execute and explicit confirmation that Relay writers are stopped.",
                recovery="Stop the app/daemon, review preview_reset, then confirm the deliberate reset.",
            )
        preview = self.preview_reset()
        if preview.active_run_ids:
            raise FreshInstallError(
                "State reset refused active or review-blocking runs: "
                + ", ".join(map(str, preview.active_run_ids)),
                recovery="Drain, finish, cancel, or reconcile every listed run before reset.",
            )
        if not self.state_root.is_dir() or self.state_root.is_symlink():
            raise FreshInstallError(
                "Relay state root is absent or is not a normal directory.",
                recovery="Nothing was moved; verify the configured Relay-owned state path.",
            )
        repositories_before = list(preview.registered_repositories)
        self.trash_root.mkdir(parents=True, exist_ok=True)
        destination = self.trash_root / (
            f"relay-runner-state-{_timestamp()}-{uuid.uuid4().hex[:8]}"
        )
        manifest_path = destination.with_name(destination.name + ".reset-recovery.json")
        manifest = {
            "schema_version": 1,
            "action": "reset_state",
            "moved_at": _timestamp(),
            "original_state_root": str(self.state_root),
            "trashed_state": str(destination),
            "state_manifest_sha256": preview.state_manifest_sha256,
            "registered_repositories": repositories_before,
            "restore_requires_daemon_stopped": True,
            "repositories_must_not_be_mutated": True,
        }
        try:
            _write_json_atomic(manifest_path, manifest)
        except OSError as error:
            raise FreshInstallError(
                f"Could not persist reset recovery journal: {error}",
                recovery="Nothing was moved; repair available storage and retry the deliberate reset.",
            ) from error
        self._inject("before_state_move")
        os.replace(self.state_root, destination)
        self._inject("after_state_move")
        self._verify_repositories(repositories_before)
        return FreshInstallResult(
            action="reset_state",
            state_preserved=True,
            repositories_preserved=True,
            recovery_manifest=str(manifest_path),
            trashed_state=str(destination),
        )

    @staticmethod
    def restore_reset(
        recovery_manifest: str | os.PathLike[str],
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
    ) -> FreshInstallResult:
        if not execute or not confirm_daemon_stopped:
            raise FreshInstallError(
                "State restore requires --execute and explicit confirmation that Relay writers are stopped.",
                recovery="Stop the app/daemon and rerun the recorded restore.",
            )
        path = Path(recovery_manifest).expanduser().resolve()
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise FreshInstallError(
                f"Reset recovery manifest is invalid: {error}",
                recovery="Select the reset-recovery.json inside the moved Trash directory.",
            ) from error
        moved = Path(str(document.get("trashed_state") or "")).resolve()
        target = Path(str(document.get("original_state_root") or "")).resolve()
        if path != moved.with_name(moved.name + ".reset-recovery.json") or not moved.is_dir() or moved.is_symlink():
            raise FreshInstallError(
                "Moved state directory no longer matches its recovery manifest.",
                recovery="Locate the exact recorded Trash directory; do not merge ambiguous state.",
            )
        if target.exists():
            if target.is_dir() and not target.is_symlink() and not any(target.iterdir()):
                target.rmdir()
            else:
                raise FreshInstallError(
                    "Relay created new non-empty state after reset; automatic restore would overwrite it.",
                    recovery="Stop writers and explicitly reconcile or move the new state first.",
                )
        repositories = document.get("registered_repositories")
        if not isinstance(repositories, list):
            raise FreshInstallError(
                "Recovery manifest has no repository safety evidence.",
                recovery="Restore the original untampered recovery manifest.",
            )
        _verify_repository_snapshots(repositories)
        target.parent.mkdir(parents=True, exist_ok=True)
        os.replace(moved, target)
        _verify_repository_snapshots(repositories)
        return FreshInstallResult(
            action="restore_state",
            state_preserved=True,
            repositories_preserved=True,
            recovery_manifest=str(path),
            trashed_state=None,
        )

    def _state_manifest(self) -> dict[str, dict[str, Any]]:
        if not self.state_root.exists():
            return {}
        if self.state_root.is_symlink() or not self.state_root.is_dir():
            raise FreshInstallError(
                "Relay state root is not a normal directory.",
                recovery="Repair the owned state path before reinstall/reset.",
            )
        return _tree_manifest(self.state_root)

    def _registered_repository_snapshots(self) -> list[dict[str, Any]]:
        registry = self.state_root / "projects/registry-v2.json"
        try:
            document = json.loads(registry.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        result = []
        for record in document.get("projects", []):
            if not isinstance(record, dict):
                continue
            raw = str(record.get("last_resolved_path") or "").strip()
            if not raw:
                continue
            repo = Path(raw).expanduser().resolve()
            if not repo.is_dir():
                result.append({
                    "project_id": record.get("project_id"),
                    "repo_path": str(repo),
                    "available": False,
                })
                continue
            result.append(_repository_snapshot(repo, project_id=record.get("project_id")))
        return result

    def _active_run_ids(self) -> list[int]:
        path = self.state_root / "runs.db"
        if not path.exists():
            path = self.state_root / "orchestrator/runs.db"
        if not path.exists():
            return []
        try:
            connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            try:
                rows = connection.execute("SELECT id, state FROM runs ORDER BY id").fetchall()
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise FreshInstallError(
                f"Runs ledger cannot prove reset quiescence: {error}",
                recovery="Repair/restore runs.db before deliberate state reset.",
            ) from error
        return [int(row[0]) for row in rows if row[1] in RESET_ACTIVE_STATES]

    def _verify_preserved(
        self,
        state_before: Mapping[str, Any],
        repositories_before: list[Mapping[str, Any]],
    ) -> None:
        if self._state_manifest() != dict(state_before):
            raise FreshInstallError(
                "Normal reinstall changed Relay Application Support.",
                recovery="Restore the state backup and reject this install artifact.",
            )
        self._verify_repositories(repositories_before)

    @staticmethod
    def _verify_repositories(snapshots: list[Mapping[str, Any]]) -> None:
        _verify_repository_snapshots(snapshots)

    @staticmethod
    def _bundle_manifest(path: Path) -> dict[str, dict[str, Any]]:
        return _tree_manifest(path)

    @staticmethod
    def _validate_app_bundle(path: Path) -> None:
        if path.is_symlink() or not path.is_dir() or path.suffix != ".app":
            raise FreshInstallError(
                f"Reviewed source is not a normal .app bundle: {path}",
                recovery="Build or select a verified Relay Runner.app bundle.",
            )
        if not (path / "Contents/Info.plist").is_file():
            raise FreshInstallError(
                "Source app bundle has no Contents/Info.plist.",
                recovery="Rebuild the complete app bundle before install.",
            )

    def _validate_owned_state_root(self) -> None:
        forbidden = {Path("/"), Path.home().resolve(), self.trash_root}
        if self.state_root in forbidden or len(self.state_root.parts) < 3:
            raise FreshInstallError(
                f"Refusing unsafe Relay state root: {self.state_root}",
                recovery="Use the exact Relay-owned Application Support directory.",
            )
        if self.state_root.name != "relay-runner":
            raise FreshInstallError(
                f"State root is not Relay-owned by name: {self.state_root}",
                recovery="Use .../Application Support/relay-runner (or an equivalent test fixture name).",
            )

    def _inject(self, stage: str) -> None:
        if self.failure_injector is None:
            return
        try:
            self.failure_injector(stage)
        except Exception as error:
            raise FreshInstallInjectedFailure(
                f"Injected fresh-install interruption at {stage}: {error}",
                recovery="Use the recorded app/state backup; never modify registered repositories.",
            ) from error


def _tree_manifest(root: Path) -> dict[str, dict[str, Any]]:
    result = {}
    for directory, directory_names, filenames in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in sorted(directory_names):
            child = base / name
            if child.is_symlink():
                relative = child.relative_to(root).as_posix()
                result[relative] = {
                    "kind": "symlink",
                    "target": os.readlink(child),
                }
        for name in sorted(filenames):
            path = base / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[relative] = {"kind": "symlink", "target": os.readlink(path)}
            elif path.is_file():
                content = path.read_bytes()
                result[relative] = {
                    "kind": "file",
                    "bytes": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                }
            else:
                raise FreshInstallError(
                    f"Unsupported special file in managed tree: {path}",
                    recovery="Remove/review the special file before install or reset.",
                )
    return dict(sorted(result.items()))


def _repository_snapshot(repo: Path, *, project_id: Any) -> dict[str, Any]:
    def git(*arguments: str, allowed: set[int] = {0}) -> bytes:
        process = subprocess.run(
            ["git", "-C", str(repo), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"},
            check=False,
        )
        if process.returncode not in allowed:
            raise FreshInstallError(
                f"Could not snapshot registered repository {repo}: git {' '.join(arguments)} failed",
                recovery="Restore repository access before reinstall/reset.",
            )
        return process.stdout

    head = git("rev-parse", "--verify", "HEAD").decode().strip()
    refs = git("for-each-ref", "--format=%(refname)%00%(objectname)")
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    index = git("ls-files", "--stage", "-z")
    orchestrator = _tree_manifest(repo / ".orchestrator") if (repo / ".orchestrator").is_dir() else {}
    return {
        "project_id": project_id,
        "repo_path": str(repo),
        "available": True,
        "head": head,
        "refs_sha256": hashlib.sha256(refs).hexdigest(),
        "status_sha256": hashlib.sha256(status).hexdigest(),
        "index_sha256": hashlib.sha256(index).hexdigest(),
        "orchestrator_sha256": _json_digest(orchestrator),
    }


def _verify_repository_snapshots(snapshots: list[Mapping[str, Any]]) -> None:
    for expected in snapshots:
        if not expected.get("available"):
            continue
        repo = Path(str(expected.get("repo_path") or "")).resolve()
        actual = _repository_snapshot(repo, project_id=expected.get("project_id"))
        if actual != dict(expected):
            raise FreshInstallError(
                f"Registered repository changed during app-state operation: {repo}",
                recovery="Stop and restore/reconcile the repository from the recorded snapshot.",
            )


def _write_json_atomic(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(dict(value), sort_keys=True, indent=2) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        if temporary.exists() and temporary.is_file() and not temporary.is_symlink():
            temporary.unlink()
        raise


def _json_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def _timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime())


__all__ = [
    "FreshInstallCoordinator",
    "FreshInstallError",
    "FreshInstallInjectedFailure",
    "FreshInstallPreview",
    "FreshInstallResult",
    "RESET_ACTIVE_STATES",
]
