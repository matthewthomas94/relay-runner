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
import plistlib
import shutil
import sqlite3
import subprocess
import sys
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

PROFILE_RELAY_OWNED = "relay-owned"
PROFILE_VOICE_MODELS = "voice-models"
PROFILE_PROVIDER_INTEGRATIONS = "provider-integrations"
RESET_PROFILES = (
    PROFILE_RELAY_OWNED,
    PROFILE_VOICE_MODELS,
    PROFILE_PROVIDER_INTEGRATIONS,
)

UNRESETTABLE_MACHINE_STATE = (
    "TCC permissions",
    "Keychain credentials",
    "notification authorization",
    "Gatekeeper and quarantine decisions",
    "shared dependency caches",
)

RELAY_TEMPORARY_ARTIFACTS = (
    "relay_actions.sock",
    "relay_board_now.txt",
    "relay_board_prev.txt",
    "relay_intent_inbox.sqlite3",
    "relay_orchestrator.port",
    "relay_speech_events.jsonl",
    "relay_terminal_manual_submission.json",
    "relay_terminal_delivery_events.jsonl",
    "relay_tutorial_tts_control.sock",
    "tts_control.sock",
    "tts_debug.log",
    "tts_in.fifo",
    "voice_bridge.cwd",
    "voice_bridge.provider",
    "voice_bridge.sock",
    "voice_bridge_heartbeat",
    "voice_bridge_heartbeat.pid",
    "voice_bridge_launch.command",
    "voice_bridge_stop_requested",
    "voice_cmd_claimed.json",
    "voice_cmd_manual_ack.json",
    "voice_cmd_ready",
    "voice_cmd_ready.meta",
    "voice_command_authorizations.json",
    "voice_command_state.json",
    "voice_in.fifo",
    "voice_provider_session_id",
    "voice_provider_turns.json",
    "voice_provider_turns_v2.json",
    "voice_state.sock",
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
    profile: str | None = None
    reset_resources: tuple[Mapping[str, Any], ...] = ()
    machine_state_not_reset: tuple[str, ...] = ()


@dataclasses.dataclass(frozen=True)
class FreshInstallResult:
    action: str
    state_preserved: bool
    repositories_preserved: bool
    destination_app: str | None = None
    recovery_manifest: str | None = None
    trashed_state: str | None = None
    replaced_app_backup: str | None = None
    profile: str | None = None
    evidence_path: str | None = None


class FreshInstallCoordinator:
    def __init__(
        self,
        *,
        state_root: str | os.PathLike[str],
        trash_root: str | os.PathLike[str] | None = None,
        home_root: str | os.PathLike[str] | None = None,
        temporary_root: str | os.PathLike[str] = "/tmp",
        active_process_detector: Callable[[], list[str]] | None = None,
        failure_injector: Callable[[str], None] | None = None,
    ) -> None:
        self.state_root = Path(state_root).expanduser().resolve()
        self.trash_root = (
            Path(trash_root).expanduser().resolve()
            if trash_root is not None
            else Path.home().joinpath(".Trash").resolve()
        )
        self.home_root = (
            Path(home_root).expanduser().resolve()
            if home_root is not None
            else Path.home().resolve()
        )
        self.temporary_root = Path(temporary_root).expanduser().resolve()
        self.active_process_detector = active_process_detector
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
        """Compatibility preview for the Relay-owned profile."""
        return self.preview_profile(PROFILE_RELAY_OWNED)

    def preview_profile(self, profile: str) -> FreshInstallPreview:
        resources = self._profile_resources(profile)
        state = self._state_manifest()
        return FreshInstallPreview(
            action="reset_profile",
            state_root=str(self.state_root),
            state_manifest_sha256=_json_digest(state),
            state_files=len(state),
            registered_repositories=tuple(self._registered_repository_snapshots()),
            active_run_ids=tuple(self._active_run_ids()),
            profile=profile,
            reset_resources=tuple(
                {
                    "name": name,
                    "path": str(path),
                    "present": path.exists() or path.is_symlink(),
                    "manifest_sha256": _resource_digest(path),
                }
                for name, path in resources
            ),
            machine_state_not_reset=UNRESETTABLE_MACHINE_STATE,
        )

    def reset_state(
        self,
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: str | None = None,
    ) -> FreshInstallResult:
        """Compatibility reset for callers that only need Relay-owned state."""
        return self.reset_profile(
            PROFILE_RELAY_OWNED,
            execute=execute,
            confirm_daemon_stopped=confirm_daemon_stopped,
            confirm_profile=confirm_profile,
        )

    def reset_profile(
        self,
        profile: str,
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: str | None,
    ) -> FreshInstallResult:
        if not execute or not confirm_daemon_stopped or confirm_profile != profile:
            raise FreshInstallError(
                "Profile reset requires --execute, --confirm-daemon-stopped, and "
                f"--confirm-profile {profile}.",
                recovery="Stop Relay writers, review the profile preview, then repeat its exact profile name.",
            )
        preview = self.preview_profile(profile)
        if preview.active_run_ids:
            raise FreshInstallError(
                "Profile reset refused active or review-blocking runs: "
                + ", ".join(map(str, preview.active_run_ids)),
                recovery="Drain, finish, cancel, or reconcile every listed run before reset.",
            )
        active_processes = self._active_relay_processes()
        if active_processes:
            raise FreshInstallError(
                "Profile reset refused active Relay processes: " + ", ".join(active_processes),
                recovery="Quit Relay Runner and its bridge, daemon, and TTS workers before retrying.",
            )
        repositories_before = list(preview.registered_repositories)
        self.trash_root.mkdir(parents=True, exist_ok=True)
        destination = self.trash_root / f"relay-runner-{profile}-{_timestamp()}-{uuid.uuid4().hex[:8]}"
        destination.mkdir(mode=0o700)
        manifest_path = destination / "reset-recovery.json"
        manifest: dict[str, Any] = {
            "schema_version": 3,
            "action": "reset_profile",
            "profile": profile,
            "moved_at": _timestamp(),
            "resources": [],
            "registered_repositories": repositories_before,
            "restore_requires_daemon_stopped": True,
            "repositories_must_not_be_mutated": True,
            "machine_state_not_reset": list(UNRESETTABLE_MACHINE_STATE),
        }
        try:
            _write_json_atomic(manifest_path, manifest)
        except OSError as error:
            destination.rmdir()
            raise FreshInstallError(
                f"Could not persist reset recovery journal: {error}",
                recovery="Nothing was moved; repair available storage and retry the deliberate reset.",
            ) from error
        moved: list[dict[str, str]] = []
        try:
            self._inject("before_profile_move")
            for index, (name, source) in enumerate(self._profile_resources(profile)):
                if not (source.exists() or source.is_symlink()):
                    continue
                target = destination / f"{index:02d}-{name}"
                resource = {"name": name, "original_path": str(source), "trashed_path": str(target)}
                manifest["resources"].append(resource)
                _write_json_atomic(manifest_path, manifest)
                os.replace(source, target)
                moved.append(resource)
                self._inject(f"after_profile_move:{name}")
        except Exception:
            self._restore_moved_resources(moved)
            if manifest_path.is_file() and not manifest_path.is_symlink():
                manifest_path.unlink()
            if destination.exists() and not any(destination.iterdir()):
                destination.rmdir()
            raise
        self._inject("after_profile_move")
        self._verify_repositories(repositories_before)
        return FreshInstallResult(
            action="reset_profile",
            state_preserved=True,
            repositories_preserved=True,
            recovery_manifest=str(manifest_path),
            trashed_state=str(destination),
            profile=profile,
        )

    @staticmethod
    def restore_profile(
        recovery_manifest: str | os.PathLike[str],
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: str | None,
        state_root: str | os.PathLike[str] | None = None,
        home_root: str | os.PathLike[str] | None = None,
        temporary_root: str | os.PathLike[str] = "/tmp",
        trash_root: str | os.PathLike[str] | None = None,
    ) -> FreshInstallResult:
        if not execute or not confirm_daemon_stopped:
            raise FreshInstallError(
                "Profile restore requires --execute and --confirm-daemon-stopped.",
                recovery="Stop Relay writers and rerun the recorded restore.",
            )
        path, document = _read_recovery_manifest(recovery_manifest)
        profile = str(document.get("profile") or "")
        resources = document.get("resources")
        if document.get("action") != "reset_profile" or profile not in RESET_PROFILES or confirm_profile != profile:
            raise FreshInstallError(
                "Profile recovery manifest or confirmation does not match a supported profile.",
                recovery="Use the exact reset-recovery.json and repeat its profile name.",
            )
        if not isinstance(resources, list) or not resources:
            raise FreshInstallError(
                "Profile recovery manifest has no recoverable resource inventory.",
                recovery="Restore the original untampered recovery manifest.",
            )
        expected_home = Path(home_root).expanduser().resolve() if home_root is not None else Path.home().resolve()
        expected_state = (
            Path(state_root).expanduser().resolve()
            if state_root is not None
            else expected_home / "Library/Application Support/relay-runner"
        )
        expected_temporary = Path(temporary_root).expanduser().resolve()
        expected_trash = (
            Path(trash_root).expanduser().resolve()
            if trash_root is not None
            else expected_home / ".Trash"
        )
        expected_resources = _profile_resources(
            profile,
            state_root=expected_state,
            home_root=expected_home,
            temporary_root=expected_temporary,
        )
        _validate_profile_recovery_resources(
            path,
            profile=profile,
            resources=resources,
            expected_resources=expected_resources,
            trash_root=expected_trash,
        )
        for item in resources:
            source = Path(str(item["trashed_path"]))
            target = Path(str(item["original_path"]))
            if not (source.exists() or source.is_symlink()) or target.exists() or target.is_symlink():
                raise FreshInstallError(
                    "Automatic profile restore would overwrite state or use an ambiguous backup.",
                    recovery="Move new state aside only after review, then use the original recovery manifest.",
                )
        snapshots = document.get("registered_repositories")
        if not isinstance(snapshots, list):
            raise FreshInstallError(
                "Recovery manifest has no repository safety evidence.",
                recovery="Restore the original untampered recovery manifest.",
            )
        _verify_repository_snapshots(snapshots)
        for item in resources:
            source = Path(str(item["trashed_path"]))
            target = Path(str(item["original_path"]))
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source, target)
        _verify_repository_snapshots(snapshots)
        return FreshInstallResult(
            action="restore_profile",
            state_preserved=True,
            repositories_preserved=True,
            recovery_manifest=str(path),
            profile=profile,
        )

    @staticmethod
    def restore_reset(
        recovery_manifest: str | os.PathLike[str],
        *,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: str | None = None,
        state_root: str | os.PathLike[str] | None = None,
        home_root: str | os.PathLike[str] | None = None,
        temporary_root: str | os.PathLike[str] = "/tmp",
        trash_root: str | os.PathLike[str] | None = None,
    ) -> FreshInstallResult:
        if not execute or not confirm_daemon_stopped:
            raise FreshInstallError(
                "State restore requires --execute and explicit confirmation that Relay writers are stopped.",
                recovery="Stop the app/daemon and rerun the recorded restore.",
            )
        path, document = _read_recovery_manifest(recovery_manifest)
        if document.get("action") == "reset_profile":
            return FreshInstallCoordinator.restore_profile(
                path,
                execute=execute,
                confirm_daemon_stopped=confirm_daemon_stopped,
                confirm_profile=confirm_profile,
                state_root=state_root,
                home_root=home_root,
                temporary_root=temporary_root,
                trash_root=trash_root,
            )
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

    def _profile_resources(self, profile: str) -> list[tuple[str, Path]]:
        return _profile_resources(
            profile,
            state_root=self.state_root,
            home_root=self.home_root,
            temporary_root=self.temporary_root,
        )

    def _active_relay_processes(self) -> list[str]:
        if self.active_process_detector is not None:
            return self.active_process_detector()
        try:
            process = subprocess.run(
                ["ps", "-axo", "pid=,ppid=,command="],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
        except OSError as error:
            raise FreshInstallError(
                f"Cannot inspect Relay processes: {error}",
                recovery="Restore process inspection access before retrying the profile reset.",
            ) from error
        if process.returncode != 0:
            raise FreshInstallError(
                "Cannot inspect Relay processes; refusing to move reset-profile state.",
                recovery="Restore process inspection access before retrying the profile reset.",
            )
        processes: dict[int, tuple[int, str]] = {}
        for line in process.stdout.splitlines():
            if not line.strip():
                continue
            try:
                pid_text, parent_text, command = line.strip().split(maxsplit=2)
                processes[int(pid_text)] = (int(parent_text), command)
            except ValueError as error:
                raise FreshInstallError(
                    "Cannot inspect Relay processes; refusing to move reset-profile state.",
                    recovery="Restore process inspection access before retrying the profile reset.",
                ) from error
        lineage = {os.getpid()}
        parent = processes.get(os.getpid(), (None, ""))[0]
        while parent is not None and parent not in lineage:
            lineage.add(parent)
            parent = processes.get(parent, (None, ""))[0]
        markers = ("relay-runner", "voice_bridge.py", "orchestrator.py", "tts_worker.py")
        installer_markers = ("fresh_install_cli.py", "relay-runner-fresh-install")
        return [
            f"{pid} {parent} {command}"
            for pid, (parent, command) in processes.items()
            if any(marker in command for marker in markers)
            and not (pid in lineage and any(marker in command for marker in installer_markers))
        ]

    @staticmethod
    def _restore_moved_resources(moved: list[dict[str, str]]) -> None:
        for item in reversed(moved):
            source = Path(item["trashed_path"])
            target = Path(item["original_path"])
            if (source.exists() or source.is_symlink()) and not (target.exists() or target.is_symlink()):
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(source, target)

    def capture_evidence(
        self,
        output: str | os.PathLike[str],
        *,
        installer_context: str,
        startup_outcome: str,
        source_app: str | os.PathLike[str] | None = None,
        incident_bundle: str | os.PathLike[str] | None = None,
    ) -> FreshInstallResult:
        app_evidence: dict[str, Any] | None = None
        if source_app is not None:
            app = Path(source_app).expanduser().resolve()
            self._validate_app_bundle(app)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            app_evidence = {
                "bundle_name": app.name,
                "bundle_identifier": info.get("CFBundleIdentifier"),
                "short_version": info.get("CFBundleShortVersionString"),
                "build_version": info.get("CFBundleVersion"),
                "bundle_manifest_sha256": _json_digest(self._bundle_manifest(app)),
            }
        incident_evidence: dict[str, Any] | None = None
        if incident_bundle is not None:
            bundle = Path(incident_bundle).expanduser().resolve()
            if not bundle.is_file():
                raise FreshInstallError(
                    "Incident/support bundle must be a file.",
                    recovery="Create the bundle first, then record only its filename and checksum.",
                )
            content = bundle.read_bytes()
            incident_evidence = {
                "filename": bundle.name,
                "bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
        destination = Path(output).expanduser().resolve()
        _write_json_atomic(destination, {
            "schema_version": 1,
            "captured_at": _timestamp(),
            "installer_context": installer_context,
            "runtime_version": sys.version.split()[0],
            "startup_outcome": startup_outcome,
            "app": app_evidence,
            "incident_support_bundle": incident_evidence,
            "source_content_captured": False,
        })
        return FreshInstallResult(
            action="capture_evidence",
            state_preserved=True,
            repositories_preserved=True,
            evidence_path=str(destination),
        )

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


def _resource_digest(path: Path) -> str | None:
    if not (path.exists() or path.is_symlink()):
        return None
    if path.is_symlink():
        value: Mapping[str, Any] = {"kind": "symlink", "target": os.readlink(path)}
    elif path.is_file():
        content = path.read_bytes()
        value = {"kind": "file", "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
    elif path.is_dir():
        value = _tree_manifest(path)
    else:
        raise FreshInstallError(
            f"Unsupported special file in managed profile: {path}",
            recovery="Remove/review the special file before a profile reset.",
        )
    return _json_digest(value)


def _profile_resources(
    profile: str,
    *,
    state_root: Path,
    home_root: Path,
    temporary_root: Path,
) -> list[tuple[str, Path]]:
    if profile == PROFILE_RELAY_OWNED:
        resources = [
            ("application-support", state_root),
            ("preferences", home_root / "Library/Preferences/com.relayrunner.app.plist"),
            ("cache", home_root / "Library/Caches/com.relayrunner.app"),
            ("orchestrator-launch-agent", home_root / "Library/LaunchAgents/com.relay.orchestrator.plist"),
        ]
        resources.extend(
            (f"temporary-{name}", temporary_root / name)
            for name in RELAY_TEMPORARY_ARTIFACTS
        )
        return resources
    if profile == PROFILE_VOICE_MODELS:
        return [
            ("kokoro-model", home_root / ".local/share/kokoro/kokoro-v1.0.onnx"),
            ("kokoro-voices", home_root / ".local/share/kokoro/voices-v1.0.bin"),
        ]
    if profile == PROFILE_PROVIDER_INTEGRATIONS:
        return [
            ("codex-relay-bridge-skill", home_root / ".codex/skills/relay-bridge"),
            ("codex-relay-stop-skill", home_root / ".codex/skills/relay-stop"),
            ("codex-relay-dispatch-skill", home_root / ".codex/skills/relay-dispatch"),
            ("codex-relay-workflow-skill", home_root / ".codex/skills/relay-workflow"),
            ("claude-relay-bridge-command", home_root / ".claude/commands/relay-bridge.md"),
            ("claude-relay-stop-command", home_root / ".claude/commands/relay-stop.md"),
            ("claude-relay-dispatch-command", home_root / ".claude/commands/relay-dispatch.md"),
            ("claude-relay-workflow-command", home_root / ".claude/commands/relay-workflow.md"),
        ]
    raise FreshInstallError(
        f"Unknown reset profile: {profile}",
        recovery="Choose relay-owned, voice-models, or provider-integrations.",
    )


def _validate_profile_recovery_resources(
    manifest_path: Path,
    *,
    profile: str,
    resources: list[Any],
    expected_resources: list[tuple[str, Path]],
    trash_root: Path,
) -> None:
    backup_root = manifest_path.parent
    if (
        manifest_path.name != "reset-recovery.json"
        or backup_root.parent != trash_root
        or not backup_root.name.startswith(f"relay-runner-{profile}-")
        or backup_root.is_symlink()
    ):
        raise FreshInstallError(
            "Profile recovery manifest is not in the expected Relay Trash backup location.",
            recovery="Use the original reset-recovery.json inside its Relay profile backup directory.",
        )
    expected = {
        name: (path.resolve(), backup_root / f"{index:02d}-{name}")
        for index, (name, path) in enumerate(expected_resources)
    }
    seen: set[str] = set()
    for item in resources:
        if not isinstance(item, dict):
            raise FreshInstallError(
                "Profile recovery manifest has an invalid resource inventory.",
                recovery="Restore the original untampered recovery manifest.",
            )
        name = item.get("name")
        if not isinstance(name, str) or name in seen or name not in expected:
            raise FreshInstallError(
                "Profile recovery manifest has a resource outside the declared profile allowlist.",
                recovery="Restore the original untampered recovery manifest.",
            )
        seen.add(name)
        expected_target, expected_backup = expected[name]
        backup_resource = item.get("trashed_path")
        original_resource = item.get("original_path")
        if (
            not isinstance(backup_resource, str)
            or not isinstance(original_resource, str)
            or backup_resource != str(expected_backup)
            or original_resource != str(expected_target)
        ):
            raise FreshInstallError(
                "Profile recovery manifest resource paths do not match the declared profile allowlist.",
                recovery="Restore the original untampered recovery manifest.",
            )


def _read_recovery_manifest(recovery_manifest: str | os.PathLike[str]) -> tuple[Path, Mapping[str, Any]]:
    candidate = Path(recovery_manifest).expanduser().absolute()
    if candidate.is_symlink():
        raise FreshInstallError(
            "Reset recovery manifest must not be a symlink.",
            recovery="Use the original reset-recovery.json inside the Relay Trash backup directory.",
        )
    path = candidate
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FreshInstallError(
            f"Reset recovery manifest is invalid: {error}",
            recovery="Select the reset-recovery.json inside the moved Trash directory.",
        ) from error
    if not isinstance(document, dict):
        raise FreshInstallError(
            "Reset recovery manifest is not an object.",
            recovery="Select the original reset-recovery.json.",
        )
    return path, document


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

    head = git("rev-parse", "--verify", "HEAD", allowed={0, 128}).decode().strip()
    head_ref = None
    if not head:
        head_ref = git("symbolic-ref", "--quiet", "HEAD").decode().strip()
    refs = git("for-each-ref", "--format=%(refname)%00%(objectname)")
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    index = git("ls-files", "--stage", "-z")
    orchestrator = _tree_manifest(repo / ".orchestrator") if (repo / ".orchestrator").is_dir() else {}
    return {
        "project_id": project_id,
        "repo_path": str(repo),
        "available": True,
        "head": head or None,
        "head_ref": head_ref,
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
    "PROFILE_PROVIDER_INTEGRATIONS",
    "PROFILE_RELAY_OWNED",
    "PROFILE_VOICE_MODELS",
    "RESET_PROFILES",
    "RESET_ACTIVE_STATES",
]
