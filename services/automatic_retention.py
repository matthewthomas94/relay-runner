"""Background terminal retention using the existing verified archive transaction."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

try:
    from services.toml_compat import tomllib
    from services.artifact_migration import ArtifactMigrationCoordinator, legacy_ticket_content
    from services.artifact_rollout import ArtifactRolloutStore
    from services.artifact_retention import (
        ArchiveRemoteConfirmation, ArtifactRetentionManager, confirm_github_remote,
    )
    from services.artifact_store import ArtifactMutation, ArtifactStore, ArtifactValidationError, ConfigWrite
    from services.artifact_sync import ArtifactSyncEngine, ArtifactSyncMode
    from services.tickets import parse as parse_ticket
except ModuleNotFoundError:
    from toml_compat import tomllib
    from artifact_migration import ArtifactMigrationCoordinator, legacy_ticket_content
    from artifact_rollout import ArtifactRolloutStore
    from artifact_retention import (
        ArchiveRemoteConfirmation, ArtifactRetentionManager, confirm_github_remote,
    )
    from artifact_store import ArtifactMutation, ArtifactStore, ArtifactValidationError, ConfigWrite
    from artifact_sync import ArtifactSyncEngine, ArtifactSyncMode
    from tickets import parse as parse_ticket


def retention_registry_revision(registry_path: Path) -> str | None:
    """Watch project selections/registrations, ignoring routine access timestamps."""
    try:
        document = json.loads(registry_path.read_text())
    except (OSError, ValueError):
        return None
    projects = [{key: record.get(key) for key in (
        "project_id", "last_resolved_path", "availability", "remote",
    )} for record in document.get("projects", [])]
    return json.dumps([document.get("active_project_id"), projects], sort_keys=True)


def prepare_project_retention(
    repo: Path, state_root: Path, *, registry_path: Path, rollout: ArtifactRolloutStore,
) -> dict | None:
    """Enable housekeeping for a registered project only when cleanup is due.

    Registration, creation and opening all persist registry-v2. Missing remote
    access is retried on later sweeps; a small or empty legacy board is untouched.
    None means the canonical lifecycle is ready for the normal archive sweep.
    """
    repo = repo.resolve()
    registry = json.loads(registry_path.read_text())
    records = [record for record in registry.get("projects", [])
               if record.get("availability") == "available"
               and Path(record.get("last_resolved_path", "")).resolve() == repo]
    if registry.get("schema_version") != 2 or len(records) != 1:
        raise ArtifactValidationError("Automatic archival requires one available registered project.")
    record = records[0]
    project_id = record["project_id"]
    root = repo / ".orchestrator"
    config_path = root / "config.toml"
    if not config_path.exists() and not list(root.glob("*.md")):
        return {"state": "clean", "ticket_ids": [], "retained": 0}
    config = tomllib.loads(config_path.read_text())
    if config.get("project_id", project_id) != project_id:
        raise ArtifactValidationError("The archive belongs to another registered project.")
    remote = record.get("remote") or {}
    if (config.get("automatic_retention") is False
            or config.get("remote_sync") == "paused" or remote.get("mode") == "paused"):
        return {"state": "disabled", "ticket_ids": []}
    # Automatic housekeeping is the product default. Explicit project opt-outs
    # and the existing write/sync kill switches still take precedence.
    decision = rollout.decision(project_id, project_kind="existing", configured_opt_in=True)
    if not decision.artifact_writes_enabled or not decision.artifact_sync_enabled:
        return {"state": "disabled", "ticket_ids": [], "recovery": decision.reason_code}
    if config.get("automatic_retention") is True:
        return None

    terminal_count = 0
    for path in root.glob("*.md"):
        ticket = parse_ticket(legacy_ticket_content(path.read_bytes()).decode("utf-8"))
        terminal_count += ticket["status"] == "done" or ticket["canceled"]
    if terminal_count <= 25:
        return {"state": "clean", "ticket_ids": [], "retained": terminal_count}

    store = ArtifactStore(repo, project_id, state_root, enabled=True)
    selected = config.get("remote_name") or remote.get("remoteName") or remote.get("remote_name")
    names = store._git("remote").stdout.splitlines()
    if not selected and "origin" in names:
        selected = "origin"
    if not selected:
        candidates = []
        for name in names:
            try:
                confirm_github_remote(store, name, exposure_confirmed=True)
            except ArtifactValidationError:
                continue
            candidates.append(name)
        if len(candidates) == 1:
            selected = candidates[0]
        elif len(candidates) > 1:
            raise ArtifactValidationError("Choose a GitHub backup remote; multiple destinations are available.")
    if not selected:
        return {"state": "waiting_for_remote", "ticket_ids": [], "recovery": (
            "Completed tickets are waiting for an existing GitHub backup remote."
        )}
    confirm_github_remote(store, selected, exposure_confirmed=True)
    migration = ArtifactMigrationCoordinator(
        repo, project_id, state_root, registry_path=registry_path,
        runs_db_path=state_root / "orchestrator/runs.db",
        graphify_path=state_root / "orchestrator/graphify.db", remote_name=selected,
    )
    journal = json.loads(migration.journal_path.read_text()) if migration.journal_path.exists() else {}
    if config.get("artifact_lifecycle") != "enabled" or journal.get("stage", "complete") != "complete":
        migration.migrate(confirm_source_cleanup=True, confirm_first_push=True)
    enable_automatic_retention(store, selected)
    return None


def automatic_confirmation(store: ArtifactStore, config: dict) -> ArchiveRemoteConfirmation | None:
    """Reuse the project's durable authorization, bound to both remote URLs."""
    if config.get("automatic_retention") is not True or config.get("remote_sync") != "enabled":
        return None
    confirmation = confirm_github_remote(
        store, str(config.get("remote_name") or ""), exposure_confirmed=True,
    )
    if (
        confirmation.remote_url_sha256 != config.get("archive_remote_url_sha256")
        or confirmation.push_url_sha256 != config.get("archive_push_url_sha256")
    ):
        raise ArtifactValidationError(
            "Automatic archival paused because the GitHub destination changed. "
            "Run relay-ticket-history enable with the intended remote to resume."
        )
    return confirmation


def _configure(store: ArtifactStore, values: dict) -> None:
    snapshot = store.snapshot()
    path = ".orchestrator/config.toml"
    original = snapshot.files[path].decode("utf-8")
    content = original
    for key, value in values.items():
        line = f"{key} = {json.dumps(value)}"
        content, count = re.subn(rf"(?m)^{key}\s*=[^\n]*", lambda _: line, content)
        if not count:
            content = content.rstrip() + "\n" + line + "\n"
    if content != original:
        store.mutate(ArtifactMutation(
            event_id="automatic-retention:enable:" + hashlib.sha256(
                (snapshot.commit_id + content).encode()
            ).hexdigest()[:32],
            actor_type="user", device_id="retention-setup", expected_base=snapshot.commit_id,
            operations=(ConfigWrite(content.encode()),),
            summary="Enable automatic archival of older completed tickets",
        ))


def enable_automatic_retention(store: ArtifactStore, remote_name: str) -> dict:
    """Bind future background batches to this project's existing destination."""
    confirmation = confirm_github_remote(store, remote_name, exposure_confirmed=True)
    _configure(store, {
        "remote_sync": "enabled",
        "remote_name": remote_name,
        "archive_remote_url_sha256": confirmation.remote_url_sha256,
        "archive_push_url_sha256": confirmation.push_url_sha256,
    })
    engine = ArtifactSyncEngine(store, mode=ArtifactSyncMode.ENABLED, remote_name=remote_name)
    # Mark setup complete only after publication. An offline first attempt can
    # therefore repeat setup automatically, including creation of a missing ref.
    result = engine.publish_initial(confirmed=True)
    if result.state.value != "clean":
        raise ArtifactValidationError(result.recovery or f"Archive setup is {result.state.value}")
    _configure(store, {"automatic_retention": True})
    return {"enabled": True, "remote_name": remote_name, "limit": 25}


def sweep_automatic_retention(store: ArtifactStore, *, lease_store=None) -> dict:
    """Run once on startup and periodically; every phase is safe to retry."""
    config = tomllib.loads(store.snapshot().files[".orchestrator/config.toml"].decode())
    confirmation = automatic_confirmation(store, config)
    if confirmation is None:
        return {"state": "disabled", "ticket_ids": []}
    engine = ArtifactSyncEngine(
        store, mode=ArtifactSyncMode.ENABLED, remote_name=confirmation.remote_name,
    )
    manager = ArtifactRetentionManager(
        store, lease_store=lease_store, remote_mode="enabled",
        remote_confirmation=confirmation, synchronizer=engine, enabled=True,
    )
    if manager.transaction_status().get("retry_available"):
        result = manager.recover_archive(synchronizer=engine)
        if result is None:  # Another confirmed caller finished recovery first.
            return {"state": "clean", "ticket_ids": []}
    else:
        synced = engine.sync_confirmed(
            expected_remote_url_sha256=confirmation.remote_url_sha256,
            expected_push_url_sha256=confirmation.push_url_sha256,
        )
        if synced.state.value != "clean":
            return {"state": synced.state.value, "ticket_ids": [], "recovery": synced.recovery}
        plan = manager.preview()
        if not plan.candidates and not plan.materialize:
            return {"state": "clean", "ticket_ids": [], "retained": len(plan.retained_terminal)}
        result = manager.archive(
            plan, event_id=f"automatic-retention:{plan.artifact_head}",
            device_id="retention-daemon", synchronizer=engine,
        )
    return {
        "state": result.state.value, "ticket_ids": list(result.ticket_ids),
        "recovery": result.recovery,
    }
