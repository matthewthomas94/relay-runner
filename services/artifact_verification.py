#!/usr/bin/env python3
"""RR-289 disposable two-device and signed-installed verification gates."""

from __future__ import annotations

import dataclasses
import hashlib
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

try:
    from services.artifact_rollout import privacy_safe_report_digest
    from services.artifact_store import (
        ARTIFACT_REF,
        ArtifactConcurrentUpdate,
        ArtifactMaterializationConflict,
        ArtifactMutation,
        ArtifactStore,
        AttachmentWrite,
        ConfigWrite,
        TicketWrite,
    )
    from services.artifact_sync import ArtifactSyncEngine, ArtifactSyncMode, ArtifactSyncState
except ModuleNotFoundError:  # Installed direct-script layout.
    from artifact_rollout import privacy_safe_report_digest  # type: ignore[no-redef]
    from artifact_store import (  # type: ignore[no-redef]
        ARTIFACT_REF,
        ArtifactConcurrentUpdate,
        ArtifactMaterializationConflict,
        ArtifactMutation,
        ArtifactStore,
        AttachmentWrite,
        ConfigWrite,
        TicketWrite,
    )
    from artifact_sync import (  # type: ignore[no-redef]
        ArtifactSyncEngine,
        ArtifactSyncMode,
        ArtifactSyncState,
    )


VERIFICATION_SCHEMA_VERSION = 1
INSTALLED_EVIDENCE_SCHEMA_VERSION = 1

INSTALLED_SCENARIOS = frozenset(
    {
        "empty_workspace",
        "add_project",
        "create_project",
        "remove_project",
        "filesystem_grant",
        "filesystem_revocation",
        "moved_project",
        "offline_project",
        "explicit_session_scope",
        "archive_history_restore",
        "conflict_ui",
        "fresh_install",
        "reset_recovery",
        "mounted_workspace",
        "dirty_source_isolation",
    }
)

PROVIDER_DIFFERENCE_IDS = frozenset(
    {"authentication", "effort_flag", "executable_discovery", "model_name"}
)

# This manifest makes the complete RR-270 matrix reviewable and prevents later
# test renames from silently shrinking the gate.  The harness below supplements
# these unit/integration tests with real two-clone Git operations.
SOURCE_MATRIX: Mapping[str, tuple[str, ...]] = {
    "terminal_count_and_exemptions": (
        "tests/test_artifact_retention.py",
        "test_mixed_terminal_pool_uses_one_25_ticket_limit",
        "test_terminal_overage_has_only_bounded_exact_reasons",
        "test_hundreds_of_terminal_tickets_keep_exactly_newest_25",
    ),
    "archive_restore_dependencies": (
        "tests/test_artifact_retention.py",
        "test_historical_search_detail_restore_and_dependency_resolution",
    ),
    "remote_archive_transaction": (
        "tests/test_artifact_retention.py",
        "test_archive_failures_preserve_or_recover_projection_from_canonical_ref",
        "test_crash_after_push_is_resolved_by_refetch_without_local_loss",
        "test_remote_archive_failure_never_advances_local_authority",
        "test_remote_race_discards_only_unpublished_candidate_for_safe_replan",
        "test_unconfirmed_non_github_pushurl_never_publishes",
        "test_push_destination_is_revalidated_immediately_before_publication",
        "test_fresh_recovery_materializes_nonterminal_and_newest_25_only",
    ),
    "prepared_publication_and_exact_ref_recovery": (
        "tests/test_artifact_sync.py",
        "test_prepared_publication_refetches_proofs_before_local_ref_moves",
        "test_fresh_device_recovers_only_exact_remote_artifact_ref",
        "test_second_device_recovery_preserves_manual_materialization_edits",
    ),
    "sync_conflicts_and_source_isolation": (
        "tests/test_artifact_sync.py",
        "test_two_devices_rebase_unrelated_offline_events_and_preserve_source_state",
        "test_conflict_taxonomy_covers_display_config_attachment_and_delete_edit",
    ),
    "allowlist_and_privacy": (
        "tests/test_artifact_store.py",
        "test_security_allowlist_rejects_traversal_cross_ticket_raw_audio_secrets_and_traces",
    ),
    "registry_recovery": (
        "tests/RelayRunnerTests/ProjectRegistryV2Tests.swift",
        "testAtomicStoreRecoversCorruptPrimaryFromLastKnownGoodBackup",
        "testAvailabilitySurfacesStaleMissingOfflineAndMovedStatesWithoutChangingIdentity",
    ),
    "migration_and_rollback": (
        "tests/test_artifact_migration.py",
        "test_interruption_after_bootstrap_resumes_without_duplicate_commit",
        "test_rollback_after_cutover_restores_exact_legacy_tree_in_new_commit_and_retains_ref",
    ),
    "fresh_install_and_reset": (
        "tests/test_fresh_install.py",
        "test_normal_reinstall_requires_execute_and_preserves_all_state_and_registered_repositories",
        "test_deliberate_reset_moves_only_owned_state_to_trash_and_restore_is_exact",
    ),
    "lifecycle_review_failure": (
        "tests/test_artifact_lifecycle.py",
        "test_done_cannot_publish_before_source_merge",
        "test_failure_retry_cancel_merge_conflict_and_restart_leases_are_idempotent",
    ),
    "provider_parity": (
        "tests/test_artifact_lifecycle.py",
        "test_outcomes_are_bounded_private_and_provider_neutral",
    ),
}


class ArtifactVerificationError(RuntimeError):
    def __init__(self, message: str, *, code: str, recovery: str):
        super().__init__(message)
        self.code = code
        self.recovery = recovery


class _InjectedCrash(RuntimeError):
    pass


class _RecordingArtifactStore(ArtifactStore):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.git_commands: list[tuple[str, ...]] = []

    def _git(self, *arguments: str, **kwargs: Any):  # type: ignore[override]
        self.git_commands.append(tuple(arguments))
        return super()._git(*arguments, **kwargs)


@dataclasses.dataclass
class _Device:
    name: str
    repo: Path
    state: Path
    store: _RecordingArtifactStore


@dataclasses.dataclass(frozen=True)
class InstalledBundleIdentity:
    version: str
    build_number: str
    bundle_identifier: str
    bundle_sha256: str
    signer_team_id: str
    developer_id_signed: bool
    code_signature_valid: bool
    installed_in_applications: bool

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


class RR289SourceVerificationHarness:
    """Run real two-clone artifact operations without touching user repos/remotes."""

    def __init__(self, *, git_binary: str = "git") -> None:
        self.git_binary = git_binary

    def run(self) -> dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="relay-rr289-") as temporary:
            root = Path(temporary)
            scenarios: dict[str, Mapping[str, Any]] = {}
            scenarios["unrelated_offline_edits"] = self._unrelated_offline(root / "offline")
            for kind in ("same_ticket", "config_collision", "attachment_collision"):
                scenarios[kind] = self._conflict_fixture(root / f"conflict-{kind}", kind)
            scenarios["push_race"] = self._push_race(root / "push-race")
            scenarios["writer_restart_recovery"] = self._writer_restart_recovery(
                root / "writer-recovery"
            )
            scenarios["provider_parity"] = self._provider_parity(root / "provider-parity")
            source_root = Path(__file__).resolve().parents[1]
            source_matrix = self.source_matrix_status(source_root)
            report: dict[str, Any] = {
                "schema_version": VERIFICATION_SCHEMA_VERSION,
                "status": "passed",
                "harness": "disposable_two_device_remote",
                "device_count": 2,
                "scenarios": scenarios,
                "failure_classification": {
                    "registry_corruption": "covered_by_source_matrix",
                    "writer_crash": "passed",
                    "cas_conflict": "passed",
                    "materialization_conflict": "passed",
                    "daemon_restart": "passed",
                    "authentication": self._classify("Authentication failed", "fetch"),
                    "offline": self._classify("Could not resolve host example.invalid", "fetch"),
                    "push_race": "passed",
                    "missing_objects": "covered_by_source_matrix",
                    "interrupted_migration": "covered_by_source_matrix",
                    "review_merge_failure": "covered_by_source_matrix",
                    "rollback": "covered_by_source_matrix",
                    "recursive_retry": "bounded",
                },
                "source_matrix": source_matrix,
                "privacy": {
                    "contains_paths": False,
                    "contains_raw_logs": False,
                    "contains_transcripts": False,
                    "contains_hidden_reasoning": False,
                },
            }
            report["report_sha256"] = privacy_safe_report_digest(report)
            return report

    @staticmethod
    def audit_source_matrix(repo_root: Path) -> dict[str, str]:
        result: dict[str, str] = {}
        for scenario, references in SOURCE_MATRIX.items():
            relative, *needles = references
            path = repo_root / relative
            if not path.is_file():
                raise ArtifactVerificationError(
                    f"RR-270 source matrix file is missing: {relative}",
                    code="source_matrix_missing",
                    recovery="Restore the named test file and rerun the full source suites.",
                )
            content = path.read_text(encoding="utf-8")
            missing = [needle for needle in needles if needle not in content]
            if missing:
                raise ArtifactVerificationError(
                    f"RR-270 source matrix coverage changed for {scenario}.",
                    code="source_matrix_changed",
                    recovery="Review and update the named scenario with equivalent or stronger tests.",
                )
            result[scenario] = "present"
        return result

    @staticmethod
    def source_matrix_status(root: Path) -> dict[str, str]:
        if (root / "tests").is_dir():
            return RR289SourceVerificationHarness.audit_source_matrix(root)
        return {
            scenario: "external_source_report_required"
            for scenario in SOURCE_MATRIX
        }

    def _unrelated_offline(self, root: Path) -> dict[str, Any]:
        fixture = self._make_fixture(root)
        self._write_ticket(fixture["a"], "base-ticket", "RR-1", "Base")
        self._engine(fixture["a"]).sync()
        self._engine(fixture["b"]).sync()
        self._write_ticket(fixture["a"], "offline-a", "RR-2", "Device A")
        self._write_ticket(fixture["b"], "offline-b", "RR-3", "Device B")
        self._make_dirty_source(fixture["b"].repo)
        before = self._source_snapshot(fixture["b"].repo)
        source_remote_before = self._git(root / "remote.git", "rev-parse", "refs/heads/main")
        first = self._engine(fixture["a"]).sync()
        second = self._engine(fixture["b"]).sync()
        after = self._source_snapshot(fixture["b"].repo)
        source_remote_after = self._git(root / "remote.git", "rev-parse", "refs/heads/main")
        files = fixture["b"].store.snapshot().files
        self._require(first.state == ArtifactSyncState.CLEAN, "device A did not publish cleanly")
        self._require(second.state == ArtifactSyncState.CLEAN, "device B did not rebase cleanly")
        self._require(
            second.observed_state == ArtifactSyncState.CONFLICT,
            "offline divergence was not observed before unrelated replay",
        )
        self._require(before == after, "artifact synchronization changed dirty source state")
        self._require(
            source_remote_before == source_remote_after,
            "artifact synchronization changed the remote source branch",
        )
        self._require(
            {".orchestrator/RR-2.md", ".orchestrator/RR-3.md"}.issubset(files),
            "unrelated offline ticket events did not both survive",
        )
        self._audit_push_commands(fixture.values())
        return {
            "outcome": "passed",
            "observed_state": second.observed_state.value,
            "final_state": second.state.value,
            "source_state_unchanged": True,
            "remote_source_ref_unchanged": True,
            "both_events_present": True,
        }

    def _conflict_fixture(self, root: Path, kind: str) -> dict[str, Any]:
        fixture = self._make_fixture(root)
        a, b = fixture["a"], fixture["b"]
        if kind == "same_ticket":
            self._write_ticket(a, "shared-base", "RR-4", "Shared")
            self._engine(a).sync()
            self._engine(b).sync()
            a.store.mutate(self._ticket_mutation(a, "edit-a", "RR-4", "From A"))
            b.store.mutate(self._ticket_mutation(b, "edit-b", "RR-4", "From B"))
        elif kind == "config_collision":
            self._write_config_next_id(a, "config-a", 20)
            self._write_config_next_id(b, "config-b", 30)
        elif kind == "attachment_collision":
            for device, event, marker in ((a, "attachment-a", b"A"), (b, "attachment-b", b"B")):
                device.store.mutate(self._mutation(
                    device,
                    event,
                    AttachmentWrite(
                        "RR-5",
                        "same.png",
                        "image/png",
                        b"\x89PNG\r\n\x1a\n" + marker,
                    ),
                ))
        else:  # pragma: no cover - internal closed set.
            raise AssertionError(kind)
        before = self._source_snapshot(b.repo)
        self._engine(a).sync()
        remote_before = self._git(root / "remote.git", "rev-parse", ARTIFACT_REF)
        result = self._engine(b).sync()
        remote_after = self._git(root / "remote.git", "rev-parse", ARTIFACT_REF)
        self._require(result.state == ArtifactSyncState.CONFLICT, f"{kind} did not stop")
        self._require(result.conflict_report is not None, f"{kind} lacks three-way evidence")
        found = {item.kind for item in result.conflict_report.conflicts}
        self._require(kind in found, f"{kind} evidence was classified as {sorted(found)}")
        self._require(remote_before == remote_after, f"{kind} published without resolution")
        self._require(before == self._source_snapshot(b.repo), f"{kind} changed source state")
        self._audit_push_commands(fixture.values())
        return {
            "outcome": "passed",
            "state": result.state.value,
            "conflict_kind": kind,
            "three_way_evidence": True,
            "publication_stopped": True,
            "source_state_unchanged": True,
        }

    def _push_race(self, root: Path) -> dict[str, Any]:
        fixture = self._make_fixture(root)
        a, b = fixture["a"], fixture["b"]
        self._write_ticket(b, "race-b", "RR-6", "Device B")
        injected = False

        def advance(stage: str) -> None:
            nonlocal injected
            if stage == "before_push" and not injected:
                injected = True
                self._write_ticket(a, "race-a", "RR-7", "Device A")
                self._engine(a).sync()

        result = self._engine(b, failure_injector=advance, max_attempts=3).sync()
        self._require(result.state == ArtifactSyncState.CLEAN, "push race did not recover")
        self._require(result.attempts == 2, "push race did not use one bounded retry")
        messages = self._git(b.repo, "log", "--format=%B", ARTIFACT_REF)
        self._require(messages.count("Relay-Event-ID: race-b") == 1, "push race duplicated event")
        self._audit_push_commands(fixture.values())
        return {
            "outcome": "passed",
            "attempts": result.attempts,
            "event_count": 1,
            "force_push": False,
        }

    def _writer_restart_recovery(self, root: Path) -> dict[str, Any]:
        root.mkdir(parents=True)
        repo = root / "repo"
        repo.mkdir()
        self._git(repo, "init", "--initial-branch=main", "--quiet")
        (repo / "source.txt").write_text("source\n", encoding="utf-8")
        self._commit_source(repo, "source")
        state = root / "state"
        store = _RecordingArtifactStore(repo, "project-recovery", state, enabled=True)
        store.initialize(device_id="recovery-device")
        crashed = False

        def fail_after_ref(stage: str) -> None:
            nonlocal crashed
            if stage == "after_ref_update" and not crashed:
                crashed = True
                raise _InjectedCrash("injected after-ref crash")

        store.failure_injector = fail_after_ref
        mutation = ArtifactMutation(
            event_id="recover-ticket",
            actor_type="pm",
            device_id="recovery-device",
            provider="codex",
            expected_base=store._head(),
            operations=(TicketWrite(
                "RR-8", "artifact-RR-8", self._ticket_bytes("RR-8", "Recover", "artifact-RR-8")
            ),),
        )
        try:
            store.mutate(mutation)
        except _InjectedCrash:
            pass
        else:
            self._require(False, "writer failure injection did not fire")
        restarted = _RecordingArtifactStore(repo, "project-recovery", state, enabled=True)
        recovered_head = restarted.recover()
        retry = restarted.mutate(mutation)
        self._require(retry.idempotent, "writer restart duplicated its immutable event")
        self._require(retry.commit_id == recovered_head, "recovered event points to another commit")

        stale = restarted._head()
        self._write_ticket(
            _Device("restart", repo, state, restarted), "advance-head", "RR-9", "Advance"
        )
        try:
            restarted.mutate(ArtifactMutation(
                event_id="stale-cas",
                actor_type="pm",
                device_id="recovery-device",
                expected_base=stale,
                operations=(TicketWrite(
                    "RR-10", "artifact-RR-10", self._ticket_bytes("RR-10", "Stale", "artifact-RR-10")
                ),),
            ))
        except ArtifactConcurrentUpdate:
            cas_stopped = True
        else:
            cas_stopped = False
        self._require(cas_stopped, "stale artifact CAS did not stop")

        config_path = repo / ".orchestrator/config.toml"
        original = config_path.read_bytes()
        config_path.write_bytes(original + b"# unreviewed divergence\n")
        try:
            restarted.mutate(ArtifactMutation(
                event_id="materialization-conflict",
                actor_type="pm",
                device_id="recovery-device",
                expected_base=restarted._head(),
                operations=(TicketWrite(
                    "RR-11", "artifact-RR-11", self._ticket_bytes("RR-11", "Blocked", "artifact-RR-11")
                ),),
            ))
        except ArtifactMaterializationConflict:
            materialization_stopped = True
        else:
            materialization_stopped = False
        self._require(materialization_stopped, "materialization divergence did not stop")
        restarted.recover()
        self._require(config_path.read_bytes() == original, "forced recovery did not restore canonical bytes")
        return {
            "outcome": "passed",
            "after_ref_restart": "recovered",
            "event_idempotent": True,
            "stale_cas": "stopped",
            "materialization_divergence": "stopped_then_recovered",
        }

    def _provider_parity(self, root: Path) -> dict[str, Any]:
        hashes = {}
        for provider in ("codex", "claude"):
            repo = root / provider / "repo"
            repo.mkdir(parents=True)
            self._git(repo, "init", "--initial-branch=main", "--quiet")
            (repo / "source.txt").write_text("same source\n", encoding="utf-8")
            self._commit_source(repo, "source")
            store = _RecordingArtifactStore(
                repo,
                "provider-project",
                root / provider / "state",
                enabled=True,
            )
            store.initialize(device_id="provider-device")
            store.mutate(ArtifactMutation(
                event_id="provider-equivalent",
                actor_type="pm",
                device_id="provider-device",
                provider=provider,
                expected_base=store._head(),
                operations=(TicketWrite(
                    "RR-12",
                    "artifact-RR-12",
                    self._ticket_bytes("RR-12", "Provider neutral", "artifact-RR-12"),
                ),),
            ))
            snapshot = store.snapshot(provider=provider)
            hashes[provider] = self._files_digest(snapshot.files)
        self._require(hashes["codex"] == hashes["claude"], "provider snapshots differ")
        return {
            "outcome": "passed",
            "providers": ["codex", "claude"],
            "snapshot_sha256": hashes["codex"],
            "intentional_differences": sorted(PROVIDER_DIFFERENCE_IDS),
        }

    def _make_fixture(self, root: Path) -> dict[str, _Device]:
        root.mkdir(parents=True)
        remote = root / "remote.git"
        self._git(None, "init", "--bare", "--quiet", str(remote))
        self._git(remote, "symbolic-ref", "HEAD", "refs/heads/main")
        repo_a = root / "device-a"
        repo_a.mkdir()
        self._git(repo_a, "init", "--initial-branch=main", "--quiet")
        (repo_a / "source.txt").write_text("source\n", encoding="utf-8")
        self._commit_source(repo_a, "source root")
        self._git(repo_a, "remote", "add", "origin", str(remote))
        self._git(repo_a, "push", "-q", "-u", "origin", "main")
        a = _Device(
            "a",
            repo_a,
            root / "state-a",
            _RecordingArtifactStore(repo_a, "project-two-device", root / "state-a", enabled=True),
        )
        initialized = a.store.initialize(device_id="device-a")
        self._enable_remote(a, initialized.commit_id)
        self._engine(a).publish_initial(confirmed=True)
        repo_b = root / "device-b"
        self._git(None, "clone", "-q", str(remote), str(repo_b))
        self._git(
            repo_b,
            "fetch",
            "-q",
            "--no-tags",
            "origin",
            f"{ARTIFACT_REF}:{ARTIFACT_REF}",
        )
        b = _Device(
            "b",
            repo_b,
            root / "state-b",
            _RecordingArtifactStore(repo_b, "project-two-device", root / "state-b", enabled=True),
        )
        b.store.initialize(device_id="device-b")
        return {"a": a, "b": b}

    def _enable_remote(self, device: _Device, expected_base: str) -> None:
        content = device.store.snapshot().files[".orchestrator/config.toml"].decode("utf-8")
        content = self._replace_config(content, "remote_sync", 'remote_sync = "enabled"')
        content = self._replace_config(content, "remote_name", 'remote_name = "origin"')
        device.store.mutate(ArtifactMutation(
            event_id=f"enable-{device.name}",
            actor_type="user",
            device_id=f"device-{device.name}",
            expected_base=expected_base,
            operations=(ConfigWrite(content.encode("utf-8")),),
        ))

    def _engine(self, device: _Device, **kwargs: Any) -> ArtifactSyncEngine:
        return ArtifactSyncEngine(
            device.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
            **kwargs,
        )

    def _write_ticket(self, device: _Device, event_id: str, ticket_id: str, title: str) -> str:
        return device.store.mutate(
            self._ticket_mutation(device, event_id, ticket_id, title)
        ).commit_id

    def _ticket_mutation(
        self,
        device: _Device,
        event_id: str,
        ticket_id: str,
        title: str,
    ) -> ArtifactMutation:
        artifact_id = f"artifact-{ticket_id}"
        return self._mutation(
            device,
            event_id,
            TicketWrite(ticket_id, artifact_id, self._ticket_bytes(ticket_id, title, artifact_id)),
        )

    def _write_config_next_id(self, device: _Device, event_id: str, next_id: int) -> None:
        content = device.store.snapshot().files[".orchestrator/config.toml"].decode("utf-8")
        content = re.sub(r"(?m)^next_id\s*=.*$", f"next_id = {next_id}", content)
        device.store.mutate(self._mutation(device, event_id, ConfigWrite(content.encode("utf-8"))))

    @staticmethod
    def _mutation(device: _Device, event_id: str, *operations: object) -> ArtifactMutation:
        return ArtifactMutation(
            event_id=event_id,
            actor_type="pm",
            device_id=f"device-{device.name}",
            provider="codex" if device.name == "a" else "claude",
            expected_base=device.store._head(),
            operations=tuple(operations),
            summary=event_id,
        )

    @staticmethod
    def _ticket_bytes(ticket_id: str, title: str, artifact_id: str) -> bytes:
        return (
            f"---\nid: {ticket_id}\nartifact_id: {artifact_id}\n"
            f"title: {title}\nstatus: backlog\n---\n\n"
            f"## Description\n\n{title}\n"
        ).encode("utf-8")

    def _make_dirty_source(self, repo: Path) -> None:
        (repo / "ahead.txt").write_text("ahead\n", encoding="utf-8")
        self._commit_source(repo, "local ahead")
        (repo / "source.txt").write_text("unstaged\n", encoding="utf-8")
        (repo / "staged.txt").write_text("staged\n", encoding="utf-8")
        self._git(repo, "add", "staged.txt")
        (repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")

    def _source_snapshot(self, repo: Path) -> Mapping[str, Any]:
        index = Path(self._git(repo, "rev-parse", "--git-path", "index"))
        if not index.is_absolute():
            index = repo / index
        refs = [
            line
            for line in self._git(repo, "show-ref", allowed={0, 1}).splitlines()
            if not line.endswith(f" {ARTIFACT_REF}")
            and "/relay/artifacts" not in line
            and "refs/relay-runner/sync/" not in line
        ]
        files = {}
        for path in repo.rglob("*"):
            if path.is_file() and ".git" not in path.parts and ".orchestrator" not in path.parts:
                files[path.relative_to(repo).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        return {
            "head": self._git(repo, "rev-parse", "HEAD"),
            "status": self._git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
            "refs": sorted(refs),
            "remotes_sha256": hashlib.sha256(
                self._git(repo, "remote", "-v").encode("utf-8")
            ).hexdigest(),
            "index": hashlib.sha256(index.read_bytes()).hexdigest(),
            "files": dict(sorted(files.items())),
        }

    def _audit_push_commands(self, devices: Sequence[_Device] | Any) -> None:
        pushes = []
        for device in devices:
            pushes.extend(command for command in device.store.git_commands if command and command[0] == "push")
        self._require(bool(pushes), "two-device harness observed no artifact pushes")
        for command in pushes:
            self._require(
                not any(
                    argument in {"-f", "--force", "--force-with-lease", "--mirror", "--all", "--delete"}
                    or argument.startswith("--force=")
                    for argument in command
                ),
                "artifact publication exposed a destructive push option",
            )
            refspecs = [argument for argument in command if ":" in argument and not argument.startswith("--")]
            self._require(len(refspecs) == 1, "artifact push did not use one exact refspec")
            self._require(
                refspecs[0].split(":", 1)[1] == ARTIFACT_REF,
                "artifact push targeted a non-artifact ref",
            )

    def _commit_source(self, repo: Path, message: str) -> None:
        self._git(repo, "add", "-A")
        self._git(
            repo,
            "-c",
            "user.name=Relay Verification",
            "-c",
            "user.email=relay-verification@example.invalid",
            "commit",
            "-q",
            "-m",
            message,
        )

    def _git(
        self,
        repo: Path | None,
        *arguments: str,
        allowed: set[int] = {0},
    ) -> str:
        command = [self.git_binary]
        if repo is not None:
            command.extend(["-C", str(repo)])
        command.extend(arguments)
        process = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env={**os.environ, "LC_ALL": "C"},
        )
        if process.returncode not in allowed:
            raise ArtifactVerificationError(
                f"Disposable Git fixture failed during {arguments[0] if arguments else 'operation'}.",
                code="disposable_git_failure",
                recovery="Verify local Git availability and rerun the disposable RR-289 harness.",
            )
        return process.stdout.decode("utf-8", errors="replace").strip()

    @staticmethod
    def _replace_config(content: str, key: str, replacement: str) -> str:
        lines = content.splitlines()
        for index, line in enumerate(lines):
            if line.strip().startswith(f"{key} ="):
                lines[index] = replacement
                break
        else:
            lines.append(replacement)
        return "\n".join(lines) + "\n"

    @staticmethod
    def _files_digest(files: Mapping[str, bytes]) -> str:
        digest = hashlib.sha256()
        for path, content in sorted(files.items()):
            digest.update(path.encode("utf-8") + b"\0")
            digest.update(hashlib.sha256(content).digest())
        return digest.hexdigest()

    @staticmethod
    def _classify(message: str, operation: str) -> str:
        state, recovery = ArtifactSyncEngine.classify_git_failure(message, operation=operation)
        if not recovery:
            raise ArtifactVerificationError(
                "Failure classification omitted recovery guidance.",
                code="missing_recovery_guidance",
                recovery="Restore bounded user-safe recovery text.",
            )
        return state.value

    @staticmethod
    def _require(condition: bool, message: str) -> None:
        if not condition:
            raise ArtifactVerificationError(
                message,
                code="source_harness_failed",
                recovery="Keep rollout cohorts gated, inspect the disposable fixture, and rerun after repair.",
            )


class SignedInstalledAppGate:
    """Verify bundle identity and evaluate bounded two-device manual evidence."""

    def __init__(
        self,
        *,
        runner: Callable[[Sequence[str]], subprocess.CompletedProcess[bytes]] | None = None,
    ) -> None:
        self.runner = runner or self._run

    def inspect(
        self,
        app_path: str | os.PathLike[str],
        *,
        require_applications: bool = True,
    ) -> InstalledBundleIdentity:
        app = Path(app_path).expanduser().resolve()
        expected = Path("/Applications/Relay Runner.app").resolve()
        installed = app == expected
        if require_applications and not installed:
            raise ArtifactVerificationError(
                "Signed installed verification requires /Applications/Relay Runner.app.",
                code="app_not_installed",
                recovery="Use the preserving fresh-install workflow, then rerun against the installed app.",
            )
        info_path = app / "Contents/Info.plist"
        try:
            info = plistlib.loads(info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise ArtifactVerificationError(
                "Installed Relay Runner Info.plist is missing or invalid.",
                code="invalid_installed_bundle",
                recovery="Rebuild and reinstall the reviewed bundle.",
            ) from error
        verify = self.runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        details = self.runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
        detail_text = (details.stdout + details.stderr).decode("utf-8", errors="replace")
        team_match = re.search(r"(?m)^TeamIdentifier=([^\s]+)$", detail_text)
        signature_match = re.search(r"(?m)^Signature=([^\n]+)$", detail_text)
        authorities = re.findall(r"(?m)^Authority=([^\n]+)$", detail_text)
        team = team_match.group(1) if team_match else ""
        signature = signature_match.group(1).strip().lower() if signature_match else ""
        developer_signed = (
            bool(team and team.lower() not in {"not set", "none"})
            and signature != "adhoc"
            and any(
                authority.strip() == "Developer ID Application"
                or authority.strip().startswith("Developer ID Application:")
                for authority in authorities
            )
        )
        identity = InstalledBundleIdentity(
            version=str(info.get("CFBundleShortVersionString") or ""),
            build_number=str(info.get("CFBundleVersion") or ""),
            bundle_identifier=str(info.get("CFBundleIdentifier") or ""),
            bundle_sha256=self._bundle_digest(app),
            signer_team_id=team,
            developer_id_signed=developer_signed,
            code_signature_valid=verify.returncode == 0 and details.returncode == 0,
            installed_in_applications=installed,
        )
        if identity.bundle_identifier != "com.relayrunner.app":
            raise ArtifactVerificationError(
                "Installed app has an unexpected bundle identifier.",
                code="installed_bundle_identity_mismatch",
                recovery="Install the reviewed Relay Runner bundle and retry.",
            )
        if not identity.code_signature_valid or not identity.developer_id_signed:
            raise ArtifactVerificationError(
                "Installed app is not validly Developer ID signed.",
                code="signed_installed_build_required",
                recovery="Build with SIGN_IDENTITY, install the signed app, and rerun the installed gate.",
            )
        return identity

    def evaluate(
        self,
        identity: InstalledBundleIdentity,
        evidence: Mapping[str, Any],
    ) -> dict[str, Any]:
        self._validate_evidence_shape(evidence)
        blockers: list[str] = []
        bundle = evidence["bundle"]
        expected_bundle = {
            "version": identity.version,
            "build_number": identity.build_number,
            "bundle_identifier": identity.bundle_identifier,
            "bundle_sha256": identity.bundle_sha256,
            "signer_team_id": identity.signer_team_id,
        }
        if bundle != expected_bundle:
            blockers.append("bundle_identity_mismatch")
        devices = evidence["devices"]
        identifiers = {item["device_id_sha256"] for item in devices}
        if len(identifiers) < 2:
            blockers.append("two_distinct_devices_required")
        covered_scenarios = {
            scenario
            for item in devices
            for scenario, outcome in item["scenarios"].items()
            if outcome == "passed"
        }
        missing_scenarios = sorted(INSTALLED_SCENARIOS - covered_scenarios)
        if missing_scenarios:
            blockers.extend(f"scenario_missing:{item}" for item in missing_scenarios)
        providers = {
            provider
            for item in devices
            for provider, outcome in item["providers"].items()
            if outcome == "passed"
        }
        if providers != {"codex", "claude"}:
            blockers.append("installed_provider_parity_required")
        differences = set(evidence["intentional_provider_differences"])
        if differences != PROVIDER_DIFFERENCE_IDS:
            blockers.append("provider_difference_record_incomplete")
        report: dict[str, Any] = {
            "schema_version": VERIFICATION_SCHEMA_VERSION,
            "status": "passed" if not blockers else "verification_blocked",
            "bundle": identity.as_dict(),
            "device_count": len(identifiers),
            "scenario_count": len(covered_scenarios),
            "providers": sorted(providers),
            "intentional_provider_differences": sorted(differences),
            "blocker_codes": blockers,
            "resume_condition": (
                None
                if not blockers
                else "Install the exact Developer ID signed build on two devices and record every missing mounted Workspace and provider scenario in one bounded evidence manifest."
            ),
        }
        report["report_sha256"] = privacy_safe_report_digest(report)
        return report

    @staticmethod
    def evidence_template(identity: InstalledBundleIdentity) -> dict[str, Any]:
        return {
            "schema_version": INSTALLED_EVIDENCE_SCHEMA_VERSION,
            "bundle": {
                "version": identity.version,
                "build_number": identity.build_number,
                "bundle_identifier": identity.bundle_identifier,
                "bundle_sha256": identity.bundle_sha256,
                "signer_team_id": identity.signer_team_id,
            },
            "devices": [],
            "intentional_provider_differences": sorted(PROVIDER_DIFFERENCE_IDS),
        }

    def _validate_evidence_shape(self, evidence: Mapping[str, Any]) -> None:
        allowed = {
            "schema_version",
            "bundle",
            "devices",
            "intentional_provider_differences",
        }
        if set(evidence) != allowed or evidence.get("schema_version") != INSTALLED_EVIDENCE_SCHEMA_VERSION:
            raise ArtifactVerificationError(
                "Installed evidence manifest has an unsupported shape.",
                code="invalid_installed_evidence",
                recovery="Regenerate the bounded schema-1 template from the exact installed app.",
            )
        bundle = evidence.get("bundle")
        if not isinstance(bundle, dict) or set(bundle) != {
            "version", "build_number", "bundle_identifier", "bundle_sha256", "signer_team_id"
        }:
            raise ArtifactVerificationError(
                "Installed evidence bundle identity is incomplete.",
                code="invalid_installed_evidence",
                recovery="Regenerate the template from the exact installed app.",
            )
        devices = evidence.get("devices")
        if not isinstance(devices, list) or len(devices) > 8:
            raise ArtifactVerificationError(
                "Installed evidence must contain at most eight bounded device records.",
                code="invalid_installed_evidence",
                recovery="Record two reviewed device summaries without logs, paths, or transcripts.",
            )
        for item in devices:
            if not isinstance(item, dict) or set(item) != {
                "device_id_sha256", "os_version", "scenarios", "providers", "evidence_sha256"
            }:
                raise ArtifactVerificationError(
                    "Installed device evidence has an unsupported field.",
                    code="invalid_installed_evidence",
                    recovery="Use the documented bounded device record only.",
                )
            for key in ("device_id_sha256", "evidence_sha256"):
                if not isinstance(item[key], str) or not re.fullmatch(r"[0-9a-f]{64}", item[key]):
                    raise ArtifactVerificationError(
                        "Installed device evidence hash is invalid.",
                        code="invalid_installed_evidence",
                        recovery="Record lowercase SHA-256 hashes, never raw device IDs or logs.",
                    )
            if not isinstance(item["os_version"], str) or not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9_.-]{0,31}", item["os_version"]
            ):
                raise ArtifactVerificationError(
                    "Installed device OS version is invalid.",
                    code="invalid_installed_evidence",
                    recovery="Record only the bounded OS version identifier.",
                )
            scenarios = item["scenarios"]
            providers = item["providers"]
            if (
                not isinstance(scenarios, dict)
                or not set(scenarios).issubset(INSTALLED_SCENARIOS)
                or any(value not in {"passed", "failed"} for value in scenarios.values())
                or not isinstance(providers, dict)
                or not set(providers).issubset({"codex", "claude"})
                or any(value not in {"passed", "failed"} for value in providers.values())
            ):
                raise ArtifactVerificationError(
                    "Installed scenario/provider outcomes are invalid.",
                    code="invalid_installed_evidence",
                    recovery="Use only documented scenario IDs with explicit passed or failed outcomes.",
                )
        differences = evidence.get("intentional_provider_differences")
        if (
            not isinstance(differences, list)
            or not set(differences).issubset(PROVIDER_DIFFERENCE_IDS)
        ):
            raise ArtifactVerificationError(
                "Installed provider differences are invalid.",
                code="invalid_installed_evidence",
                recovery="Document only the reviewed auth, executable, model, and effort differences.",
            )
        privacy_safe_report_digest(evidence)

    @staticmethod
    def _bundle_digest(app: Path) -> str:
        digest = hashlib.sha256()
        for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix()):
            relative = path.relative_to(app).as_posix()
            digest.update(relative.encode("utf-8") + b"\0")
            if path.is_symlink():
                digest.update(b"link\0" + os.readlink(path).encode("utf-8"))
            elif path.is_file():
                file_digest = hashlib.sha256()
                with path.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        file_digest.update(chunk)
                digest.update(b"file\0" + file_digest.digest())
            elif path.is_dir():
                digest.update(b"dir\0")
            else:
                raise ArtifactVerificationError(
                    "Installed bundle contains an unsupported filesystem entry.",
                    code="invalid_installed_bundle",
                    recovery="Rebuild the signed app from the reviewed packaging script.",
                )
        return digest.hexdigest()

    @staticmethod
    def _run(command: Sequence[str]) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
