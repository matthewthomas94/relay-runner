"""Background terminal retention using the existing verified archive transaction."""

from __future__ import annotations

import hashlib
import json
import re

try:
    from services.toml_compat import tomllib
    from services.artifact_retention import (
        ArchiveRemoteConfirmation, ArtifactRetentionManager, confirm_github_remote,
    )
    from services.artifact_store import ArtifactMutation, ArtifactStore, ArtifactValidationError, ConfigWrite
    from services.artifact_sync import ArtifactSyncEngine, ArtifactSyncMode
except ModuleNotFoundError:
    from toml_compat import tomllib
    from artifact_retention import (
        ArchiveRemoteConfirmation, ArtifactRetentionManager, confirm_github_remote,
    )
    from artifact_store import ArtifactMutation, ArtifactStore, ArtifactValidationError, ConfigWrite
    from artifact_sync import ArtifactSyncEngine, ArtifactSyncMode


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


def enable_automatic_retention(store: ArtifactStore, remote_name: str) -> dict:
    """An agent's explicit enable action authorizes future background batches."""
    confirmation = confirm_github_remote(store, remote_name, exposure_confirmed=True)
    snapshot = store.snapshot()
    path = ".orchestrator/config.toml"
    original = snapshot.files[path].decode("utf-8")
    values = {
        "remote_sync": "enabled",
        "remote_name": remote_name,
        "automatic_retention": True,
        "archive_remote_url_sha256": confirmation.remote_url_sha256,
        "archive_push_url_sha256": confirmation.push_url_sha256,
    }
    content = original
    for key, value in values.items():
        content = re.sub(rf"(?m)^{key}\s*=.*\n?", "", content)
    content = content.rstrip() + "\n" + "".join(
        f"{key} = {json.dumps(value)}\n" for key, value in values.items()
    )
    if content != original:
        store.mutate(ArtifactMutation(
            event_id="automatic-retention:enable:" + hashlib.sha256(
                (snapshot.commit_id + content).encode()
            ).hexdigest()[:32],
            actor_type="user", device_id="retention-setup", expected_base=snapshot.commit_id,
            operations=(ConfigWrite(content.encode()),),
            summary="Enable automatic archival of older completed tickets",
        ))
    engine = ArtifactSyncEngine(store, mode=ArtifactSyncMode.ENABLED, remote_name=remote_name)
    # The explicit setup action also permits the first artifact-only publication.
    result = engine.publish_initial(confirmed=True)
    if result.state.value != "clean":
        raise ArtifactValidationError(result.recovery or f"Archive setup is {result.state.value}")
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
