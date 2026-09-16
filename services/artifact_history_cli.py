"""Agent-facing setup, search and retrieval of completed Relay tickets."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote, urlparse

try:
    from services.artifact_migration import ArtifactMigrationCoordinator
    from services.artifact_retention import ArtifactRetentionManager, confirm_github_remote
    from services.artifact_rollout import ArtifactRolloutStore
    from services.artifact_store import ArtifactStore, ArtifactValidationError
    from services.automatic_retention import enable_automatic_retention, sweep_automatic_retention
    from services.toml_compat import tomllib
except ModuleNotFoundError:
    from artifact_migration import ArtifactMigrationCoordinator
    from artifact_retention import ArtifactRetentionManager, confirm_github_remote
    from artifact_rollout import ArtifactRolloutStore
    from artifact_store import ArtifactStore, ArtifactValidationError
    from automatic_retention import enable_automatic_retention, sweep_automatic_retention
    from toml_compat import tomllib


def project_store(repo: Path, state: Path) -> ArtifactStore:
    config = tomllib.loads((repo / ".orchestrator/config.toml").read_text())
    if config.get("artifact_lifecycle") != "enabled":
        raise ArtifactValidationError(
            "No local archive exists yet. Relay sets it up automatically when more than "
            "25 completed tickets need cleanup and a GitHub remote is available. "
            "Use --remote <name> to read history already stored on GitHub."
        )
    return ArtifactStore(repo, config["project_id"], state, enabled=True)


@contextlib.contextmanager
def remote_store(repo: Path, remote_name: str):
    """A fresh agent can read GitHub history without migrating its checkout.

    Fetch into a disposable bare repository, including the historical objects
    referenced by the catalog. No source refs, index or ticket files are changed.
    """
    environment = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    def git(directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args], check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=60,
        ).stdout.strip()
    url = git(repo, "remote", "get-url", remote_name)
    with tempfile.TemporaryDirectory(prefix="relay-history-reader-") as temporary:
        root = Path(temporary)
        git(root, "init", "--bare", "-q")
        ref = "refs/heads/relay/artifacts"
        git(root, "fetch", "--no-tags", "--no-recurse-submodules", url, f"{ref}:{ref}")
        config = tomllib.loads(git(root, "show", f"{ref}:.orchestrator/config.toml"))
        git(root, "remote", "add", config["remote_name"], url)
        store = ArtifactStore(root, config["project_id"], root / "reader-state", enabled=True)
        store.snapshot()  # Validate project identity, path allowlist and artifact history.
        yield store


def enable(repo: Path, state: Path, remote_name: str) -> dict:
    registry = state / "projects/registry-v2.json"
    records = json.loads(registry.read_text())["projects"]
    matches = [r for r in records if r.get("availability") == "available"
               and Path(r.get("last_resolved_path", "")).resolve() == repo]
    if len(matches) != 1:
        raise ArtifactValidationError("Select one available registered project before enabling archival.")
    project_id = matches[0]["project_id"]
    decision = ArtifactRolloutStore(state).decision(
        project_id, project_kind="existing", configured_opt_in=True,
    )
    if not decision.artifact_writes_enabled or not decision.artifact_sync_enabled:
        raise ArtifactValidationError(f"Artifact rollout is paused: {decision.reason_code}")
    config = tomllib.loads((repo / ".orchestrator/config.toml").read_text())
    if config.get("artifact_lifecycle") != "enabled":
        # Validate the chosen destination before the journaled source cutover.
        confirm_github_remote(ArtifactStore(repo, project_id, state), remote_name, exposure_confirmed=True)
        ArtifactMigrationCoordinator(
            repo, project_id, state, registry_path=registry,
            runs_db_path=state / "orchestrator/runs.db",
            graphify_path=state / "orchestrator/graphify.db",
            remote_name=remote_name,
        ).migrate(confirm_source_cleanup=True, confirm_first_push=True)
    store = project_store(repo, state)
    if store.project_id != project_id:
        raise ArtifactValidationError("The archive belongs to another registered project.")
    result = enable_automatic_retention(store, remote_name)
    result["cleanup"] = sweep_automatic_retention(store)
    return result


def github_repository_url(store: ArtifactStore) -> str:
    config = tomllib.loads(store.snapshot().files[".orchestrator/config.toml"].decode())
    remote = store._git("remote", "get-url", config["remote_name"]).stdout.strip()
    repository = remote.split(":", 1)[1] if remote.startswith("git@github.com:") else urlparse(remote).path
    repository = repository.strip("/").removesuffix(".git")
    return f"https://github.com/{repository}"


def github_record_url(repository_url: str, entry: dict) -> str:
    return (f"{repository_url}/blob/{entry['source_commit']}/"
            f".orchestrator/{quote(entry['ticket_id'], safe='')}.md")


def search(store: ArtifactStore, query: str, *, full_text: bool = False) -> list[dict]:
    manager = ArtifactRetentionManager(store, enabled=True)
    catalog = manager._catalog(manager._head_required())
    cards = manager.historical_search("" if full_text else query)
    repository_url = github_repository_url(store)
    result = []
    for card in cards:
        if full_text:
            detail = manager.historical_detail(card.artifact_id)
            haystack = f"{card.ticket_id} {card.title} " + (detail.ticket_bytes or b"").decode("utf-8")
            if query.casefold() not in haystack.casefold():
                continue
        result.append({
            "ticket_id": card.ticket_id, "artifact_id": card.artifact_id,
            "title": card.title, "status": card.status,
            "activity_at": card.activity_at.isoformat(),
            "github_url": github_record_url(repository_url, catalog[card.artifact_id]),
        })
    return result


def show(store: ArtifactStore, ticket_id: str) -> dict:
    manager = ArtifactRetentionManager(store, enabled=True)
    catalog = manager._catalog(manager._head_required())
    matches = [entry for key, entry in catalog.items()
               if key == ticket_id or entry.get("ticket_id") == ticket_id]
    if len(matches) != 1:
        raise ArtifactValidationError(f"No unique archived ticket matches {ticket_id!r}.")
    entry = matches[0]
    detail = manager.historical_detail(entry["artifact_id"])
    return {
        "ticket_id": entry["ticket_id"], "availability": detail.availability.value,
        "markdown": detail.ticket_bytes.decode("utf-8") if detail.ticket_bytes is not None else None,
        "attachments": list(detail.attachments), "recovery": detail.recovery,
        "github_url": github_record_url(github_repository_url(store), entry), "materialized": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "sweep", "search", "show"))
    parser.add_argument("query", nargs="?", default="")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--state-root", type=Path, default=Path.home() / "Library/Application Support/relay-runner")
    parser.add_argument("--remote", help="Existing GitHub remote for setup or disposable remote-only history reads")
    parser.add_argument("--full-text", action="store_true", help="Also search verified archived ticket bodies")
    args = parser.parse_args()
    repo, state = args.repo.expanduser().resolve(), args.state_root.expanduser().resolve()
    try:
        if args.action == "enable":
            if not args.remote:
                parser.error("enable requires --remote")
            result = enable(repo, state, args.remote)
        else:
            if args.action == "sweep":
                store = project_store(repo, state)
                decision = ArtifactRolloutStore(state).decision(
                    store.project_id, project_kind="existing", configured_opt_in=True,
                )
                if not decision.artifact_writes_enabled or not decision.artifact_sync_enabled:
                    raise ArtifactValidationError(f"Artifact rollout is paused: {decision.reason_code}")
                result = sweep_automatic_retention(store)
            else:
                context = (remote_store(repo, args.remote) if args.remote
                           else contextlib.nullcontext(project_store(repo, state)))
                with context as store:
                    result = (search(store, args.query, full_text=args.full_text)
                              if args.action == "search" else show(store, args.query))
        print(json.dumps(result, indent=2))
        return 0
    except subprocess.SubprocessError:
        print(json.dumps({"error": "Archive retrieval failed. Check connectivity and the selected GitHub remote."}))
        return 1
    except (ValueError, RuntimeError, OSError) as error:
        print(json.dumps({"error": str(error), "recovery": getattr(error, "recovery", None)}, indent=2))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
