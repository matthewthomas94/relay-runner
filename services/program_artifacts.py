#!/usr/bin/env python3
"""Project-owned Program records and rebuildable Graphify projections.

RR-270 phase 7 makes the Relay artifact ref the durable authority for
project-scoped Program captures.  Graphify remains a disposable projection.
This module owns the provider-neutral event schema, immutable writes, legacy
Graphify export, and projection ingestion used by both Codex and Claude.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import math
import os
import subprocess
import tomllib
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

try:
    from services.artifact_store import (
        ArtifactConcurrentUpdate,
        ArtifactEventCollision,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ProgramEventWrite,
    )
except ModuleNotFoundError:  # Installed direct-script layout.
    from artifact_store import (  # type: ignore[no-redef]
        ArtifactConcurrentUpdate,
        ArtifactEventCollision,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ProgramEventWrite,
    )

from graphify_core import (
    EDGE_BELONGS_TO,
    EDGE_BLOCKS,
    EDGE_CONTAINS,
    EDGE_RELATED_TO,
    NODE_DECISION,
    NODE_IDEA,
    NODE_PROGRAM_EVENT,
    NODE_PROJECT,
    NODE_RISK,
    NODE_RUN,
    NODE_STATUS,
    NODE_TICKET,
    GraphifyCoreStore,
)


PROGRAM_EVENT_SCHEMA_VERSION = 1
PROGRAM_EXPORT_SCHEMA_VERSION = 1
PROJECT_CAPTURE_KINDS = frozenset(
    {NODE_PROGRAM_EVENT, NODE_DECISION, NODE_RISK, NODE_IDEA, NODE_STATUS}
)
_RECORD_KIND_BY_NODE = {
    NODE_PROGRAM_EVENT: "program_event",
    NODE_DECISION: "decision",
    NODE_RISK: "risk",
    NODE_IDEA: "idea",
    NODE_STATUS: "status",
}
_NODE_KIND_BY_RECORD = {value: key for key, value in _RECORD_KIND_BY_NODE.items()}
_MAX_REPORT_ISSUES = 500


class ProgramArtifactError(RuntimeError):
    pass


class ProgramArtifactMigrationError(ProgramArtifactError):
    def __init__(self, message: str, report: Mapping[str, Any]):
        super().__init__(message)
        self.report = dict(report)


@dataclasses.dataclass(frozen=True)
class ProgramWriteResult:
    event_ids: tuple[str, ...]
    commit_id: str
    writer_event_id: str
    idempotent: bool


def durable_program_event(
    *,
    project_id: str,
    stable_key: str,
    node_kind: str,
    capture_id: str,
    entry_index: int,
    summary: str,
    details: str | None,
    occurred_at: float,
    source: str,
    provider: str | None,
    ticket_id: str | None,
    run_id: int | None,
    event_type: str | None = None,
    risk_type: str | None = None,
    status: str | None = None,
) -> dict[str, Any]:
    """Build the only durable schema accepted for a project capture."""
    if node_kind not in PROJECT_CAPTURE_KINDS:
        raise ProgramArtifactError(f"unsupported durable Program node kind: {node_kind!r}")
    stable_key = _required_text(stable_key, "stable_key")
    capture_id = _required_text(capture_id, "capture_id")
    summary = _required_text(summary, "summary")
    event_id = program_event_id(stable_key)
    attributes: dict[str, Any] = {}
    if node_kind == NODE_PROGRAM_EVENT:
        attributes["event_type"] = _optional_text(event_type) or "note"
    if node_kind == NODE_RISK:
        attributes["risk_type"] = _optional_text(risk_type) or "risk"
    if node_kind == NODE_STATUS:
        attributes["status"] = _optional_text(status) or summary
    return {
        "schema_version": PROGRAM_EVENT_SCHEMA_VERSION,
        "event_id": event_id,
        "project_id": _required_text(project_id, "project_id"),
        "record_kind": _RECORD_KIND_BY_NODE[node_kind],
        "stable_key": stable_key,
        "capture_id": capture_id,
        "entry_index": int(entry_index),
        "summary": summary,
        "details": _optional_text(details),
        "occurred_at": float(occurred_at),
        "capture_source": _required_text(source, "capture_source"),
        "provider": _normalize_provider(provider),
        "evidence": {
            "ticket_id": _optional_text(ticket_id),
            "run_id": _normalize_run_id(run_id),
        },
        "attributes": attributes,
    }


def program_event_id(stable_key: str) -> str:
    digest = hashlib.sha256(_required_text(stable_key, "stable_key").encode("utf-8")).hexdigest()
    return f"program-{digest[:40]}"


def canonical_program_event(document: Mapping[str, Any]) -> bytes:
    _validate_program_event(document)
    return (
        json.dumps(dict(document), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def write_program_events(
    artifact_store: ArtifactStore,
    documents: Iterable[Mapping[str, Any]],
    *,
    writer_event_id: str,
    device_id: str,
    actor_type: str = "pm",
    provider: str | None = None,
) -> ProgramWriteResult:
    """Publish immutable Program events, retrying only a concurrent CAS race."""
    prepared = sorted(
        ((str(document.get("event_id") or ""), canonical_program_event(document)) for document in documents),
        key=lambda item: item[0],
    )
    if not prepared:
        snapshot = artifact_store.snapshot()
        return ProgramWriteResult((), snapshot.commit_id, writer_event_id, True)
    if len({event_id for event_id, _ in prepared}) != len(prepared):
        raise ProgramArtifactError("Program event batch contains duplicate event IDs")

    for attempt in range(2):
        snapshot = artifact_store.snapshot()
        operations: list[ProgramEventWrite] = []
        for event_id, content in prepared:
            path = f".orchestrator/program/events/{event_id}.json"
            existing = snapshot.files.get(path)
            if existing is not None and existing != content:
                raise ArtifactEventCollision(
                    f"immutable Program event {event_id!r} already exists with different content"
                )
            if existing is None:
                operations.append(ProgramEventWrite(event_id, content))
        if not operations:
            return ProgramWriteResult(
                tuple(event_id for event_id, _ in prepared),
                snapshot.commit_id,
                writer_event_id,
                True,
            )
        try:
            result = artifact_store.mutate(
                ArtifactMutation(
                    event_id=writer_event_id,
                    actor_type=actor_type,
                    device_id=device_id,
                    operations=tuple(operations),
                    expected_base=snapshot.commit_id,
                    provider=_normalize_provider(provider),
                    summary=f"Publish {len(operations)} Program artifact event(s)",
                )
            )
            return ProgramWriteResult(
                tuple(event_id for event_id, _ in prepared),
                result.commit_id,
                writer_event_id,
                result.idempotent,
            )
        except ArtifactConcurrentUpdate:
            if attempt:
                raise
    raise AssertionError("unreachable")


def ingest_project_program_events(
    store: GraphifyCoreStore,
    *,
    project: Mapping[str, Any],
    repo_path: str | Path,
) -> int:
    """Project canonical event files into Graphify, failing on any ambiguity."""
    repo = Path(repo_path).expanduser().resolve()
    artifact_project_id, event_files = _program_event_files(repo)
    seen_event_ids: set[str] = set()
    seen_stable_keys: set[str] = set()
    count = 0
    for artifact_path, content in sorted(event_files.items()):
        name = Path(artifact_path).name
        try:
            document = json.loads(content)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProgramArtifactError(f"malformed Program artifact {name}: {error}") from error
        if not isinstance(document, dict):
            raise ProgramArtifactError(f"Program artifact {name} is not an object")
        _validate_program_event(document)
        event_id = str(document["event_id"])
        stable_key = str(document["stable_key"])
        if Path(artifact_path).stem != event_id:
            raise ProgramArtifactError(f"Program artifact filename does not match event_id: {name}")
        if document["project_id"] != artifact_project_id:
            raise ProgramArtifactError(
                f"Program artifact {event_id} belongs to another project: {document['project_id']!r}"
            )
        if event_id in seen_event_ids or stable_key in seen_stable_keys:
            raise ProgramArtifactError(f"duplicate Program artifact identity: {event_id}")
        seen_event_ids.add(event_id)
        seen_stable_keys.add(stable_key)
        _project_program_event(store, project=project, repo=repo, document=document)
        count += 1
    for node in store.nodes(project_id=str(project["id"])):
        if (
            node["kind"] in PROJECT_CAPTURE_KINDS
            and _optional_text(node.get("body", {}).get("durable_event_id"))
            and node["stable_key"] not in seen_stable_keys
        ):
            store.delete_node(node["id"])
    return count


def export_graphify_project_captures(
    graph_store: GraphifyCoreStore,
    artifact_store: ArtifactStore,
    *,
    state_root: str | Path,
    device_id: str,
    provider: str | None = None,
    failure_injector: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Export one project's legacy capture-only nodes with a resumable journal."""
    repo = artifact_store.repo_path
    project = graph_store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{repo}")
    migration_root = Path(state_root).resolve() / "artifacts" / artifact_store.project_id / "program-migration"
    migration_root.mkdir(parents=True, exist_ok=True)
    report_path = migration_root / "report.json"
    journal_path = migration_root / "journal.json"
    backup_path = migration_root / "graphify-pre-export.db"
    manifest_path = migration_root / "pre-export-manifest.json"

    report: dict[str, Any] = {
        "schema_version": PROGRAM_EXPORT_SCHEMA_VERSION,
        "project_id": artifact_store.project_id,
        "repo_path": str(repo),
        "status": "review_required",
        "issues": [],
        "records": 0,
    }
    if project is None:
        _issue(report, "missing_project", "Graphify has no project node for the registered repository")
        _write_json(report_path, report)
        raise ProgramArtifactMigrationError("Program export requires review", report)

    documents: list[dict[str, Any]] = []
    identities: set[tuple[str, int]] = set()
    for node in graph_store.nodes():
        if node["kind"] not in PROJECT_CAPTURE_KINDS:
            continue
        body = node.get("body") if isinstance(node.get("body"), dict) else {}
        evidence = body.get("evidence") if isinstance(body.get("evidence"), dict) else {}
        evidence_repo = _resolved_optional_path(evidence.get("repo_path"))
        belongs = node.get("project_id") == project["id"]
        references_repo = evidence_repo == repo
        if not belongs and not references_repo:
            if node.get("project_id") is None and evidence_repo is None:
                _issue(report, "orphaned_capture", f"{node['id']} has no confirmed project identity")
            continue
        if not belongs or (evidence_repo is not None and evidence_repo != repo):
            _issue(report, "cross_project_capture", f"{node['id']} has conflicting project evidence")
            continue
        try:
            document = _document_from_legacy_node(node, artifact_store.project_id)
        except (ProgramArtifactError, TypeError, ValueError) as error:
            _issue(report, "malformed_capture", f"{node['id']}: {error}")
            continue
        identity = (str(document["capture_id"]), int(document["entry_index"]))
        if identity in identities:
            _issue(report, "duplicate_capture", f"duplicate capture identity {identity[0]}:{identity[1]}")
            continue
        identities.add(identity)
        documents.append(document)

    report["records"] = len(documents)
    manifest = _document_manifest(documents)
    _write_json(manifest_path, manifest)
    report["manifest_sha256"] = _json_digest(manifest)
    _write_json(report_path, report)
    if report["issues"]:
        raise ProgramArtifactMigrationError("Program export requires review", report)

    if graph_store.path != Path(":memory:") and not backup_path.exists():
        graph_store.backup(backup_path)
    journal = _load_json(journal_path)
    prior_manifest = _optional_text(journal.get("manifest_sha256"))
    if prior_manifest is not None and prior_manifest != report["manifest_sha256"]:
        _issue(
            report,
            "event_id_reconciliation_required",
            "capture manifest changed after migration journaling began",
        )
        _write_json(report_path, report)
        raise ProgramArtifactMigrationError(
            "Program captures changed during export; explicit reconciliation is required",
            report,
        )
    journal.update(
        {
            "schema_version": PROGRAM_EXPORT_SCHEMA_VERSION,
            "project_id": artifact_store.project_id,
            "repo_path": str(repo),
            "manifest_sha256": report["manifest_sha256"],
            "backup_path": str(backup_path) if backup_path.exists() else None,
            "stage": "validated",
        }
    )
    _write_json(journal_path, journal)
    _inject(failure_injector, "after_manifest")

    writer_event_id = f"program-export:{report['manifest_sha256'][:40]}"
    try:
        result = write_program_events(
            artifact_store,
            documents,
            writer_event_id=writer_event_id,
            device_id=device_id,
            actor_type="migration",
            provider=provider,
        )
    except (ArtifactValidationError, ArtifactEventCollision, ProgramArtifactError) as error:
        _issue(report, "artifact_validation_failed", str(error))
        journal.update({"stage": "review_required", "error": str(error)})
        _write_json(journal_path, journal)
        _write_json(report_path, report)
        raise ProgramArtifactMigrationError(
            "Program export failed artifact validation; review is required",
            report,
        ) from error
    journal.update({"stage": "exported", "artifact_commit": result.commit_id})
    _write_json(journal_path, journal)
    _inject(failure_injector, "after_artifact_commit")

    actual = _artifact_manifest(artifact_store, documents)
    if actual != manifest:
        report["issues"] = [{"kind": "manifest_mismatch", "detail": "artifact events differ from pre-export manifest"}]
        _write_json(report_path, report)
        raise ProgramArtifactMigrationError("Program export manifest mismatch", report)
    journal.update({"stage": "verified", "post_manifest_sha256": _json_digest(actual)})
    _write_json(journal_path, journal)
    report.update(
        {
            "status": "verified",
            "artifact_commit": result.commit_id,
            "writer_event_id": writer_event_id,
            "idempotent": result.idempotent,
            "post_manifest_sha256": _json_digest(actual),
            "backup_path": str(backup_path) if backup_path.exists() else None,
            "journal_path": str(journal_path),
        }
    )
    _write_json(report_path, report)
    return report


def replace_graphify_with_clean_rebuild(
    *,
    graphify_path: str | Path,
    registry_path: str | Path,
    runs_db_path: str | Path | None,
    expected_capture_manifest: Mapping[str, str],
    backup_path: str | Path,
) -> dict[str, Any]:
    """Build a fresh projection and replace the old database only after proof."""
    graphify = Path(graphify_path)
    backup = Path(backup_path)
    if graphify.exists() and not backup.exists():
        GraphifyCoreStore(graphify).backup(backup)
    temporary = graphify.with_name(f".{graphify.name}.rebuild-{uuid.uuid4().hex}")
    try:
        rebuilt = GraphifyCoreStore(temporary)
        from graphify_ingest import ingest_registered_projects

        counts = ingest_registered_projects(
            rebuilt,
            registry_path=registry_path,
            runs_db_path=runs_db_path,
            index_files=True,
        )
        actual = graph_capture_manifest(rebuilt)
        expected = dict(expected_capture_manifest)
        if actual != expected:
            raise ProgramArtifactError(
                "clean Graphify rebuild did not reproduce the durable capture manifest"
            )
        os.replace(temporary, graphify)
        for suffix in ("-wal", "-shm"):
            Path(str(graphify) + suffix).unlink(missing_ok=True)
        return {"counts": counts, "capture_manifest": actual, "backup_path": str(backup)}
    finally:
        temporary.unlink(missing_ok=True)
        Path(str(temporary) + "-wal").unlink(missing_ok=True)
        Path(str(temporary) + "-shm").unlink(missing_ok=True)


def graph_capture_manifest(store: GraphifyCoreStore) -> dict[str, str]:
    manifest: dict[str, str] = {}
    for node in store.nodes():
        if node["kind"] not in PROJECT_CAPTURE_KINDS:
            continue
        durable_id = _optional_text(node.get("body", {}).get("durable_event_id"))
        if durable_id:
            manifest[durable_id] = _json_digest(
                {
                    "kind": node["kind"],
                    "stable_key": node["stable_key"],
                    "title": node["title"],
                    "body": node["body"],
                }
            )
    return dict(sorted(manifest.items()))


def expected_graph_manifest(documents: Iterable[Mapping[str, Any]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for document in documents:
        projection = _projection_for_document(document)
        result[str(document["event_id"])] = _json_digest(projection)
    return dict(sorted(result.items()))


def _project_program_event(
    store: GraphifyCoreStore,
    *,
    project: Mapping[str, Any],
    repo: Path,
    document: Mapping[str, Any],
) -> None:
    projection = _projection_for_document(document)
    node = store.upsert_node(
        kind=projection["kind"],
        stable_key=projection["stable_key"],
        project_id=str(project["id"]),
        title=projection["title"],
        body=projection["body"],
    )
    edge_body = {"source": "program_artifact", "event_id": document["event_id"]}
    store.upsert_edge(src_id=node["id"], dst_id=str(project["id"]), kind=EDGE_BELONGS_TO, body=edge_body)
    store.upsert_edge(src_id=str(project["id"]), dst_id=node["id"], kind=EDGE_CONTAINS, body=edge_body)
    evidence = document.get("evidence") if isinstance(document.get("evidence"), dict) else {}
    ticket_id = _optional_text(evidence.get("ticket_id"))
    if ticket_id:
        ticket = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{repo}:{ticket_id}")
        if ticket is not None:
            store.upsert_edge(src_id=node["id"], dst_id=ticket["id"], kind=EDGE_RELATED_TO, body=edge_body)
            if node["kind"] == NODE_RISK and projection["body"].get("risk_type") == "blocker":
                store.upsert_edge(src_id=node["id"], dst_id=ticket["id"], kind=EDGE_BLOCKS, body=edge_body)
    run_id = _normalize_run_id(evidence.get("run_id"))
    if run_id is not None:
        run = store.find_node(kind=NODE_RUN, stable_key=f"run:{run_id}")
        if run is not None and run.get("project_id") == project["id"]:
            store.upsert_edge(src_id=node["id"], dst_id=run["id"], kind=EDGE_RELATED_TO, body=edge_body)


def _projection_for_document(document: Mapping[str, Any]) -> dict[str, Any]:
    _validate_program_event(document)
    kind = _NODE_KIND_BY_RECORD[str(document["record_kind"])]
    attributes = document.get("attributes") if isinstance(document.get("attributes"), dict) else {}
    body = {
        "durable_event_id": document["event_id"],
        "artifact_project_id": document["project_id"],
        "schema_version": document["schema_version"],
        "capture_id": document["capture_id"],
        "entry_index": document["entry_index"],
        "capture_source": document["capture_source"],
        "summary": document["summary"],
        "details": document.get("details"),
        "provider_key": document.get("provider"),
        "occurred_at": document["occurred_at"],
        "evidence": document.get("evidence") or {},
    }
    body.update(attributes)
    return {
        "kind": kind,
        "stable_key": document["stable_key"],
        "title": document["summary"],
        "body": body,
    }


def _document_from_legacy_node(node: Mapping[str, Any], project_id: str) -> dict[str, Any]:
    body = node.get("body")
    if not isinstance(body, dict):
        raise ProgramArtifactError("body is not an object")
    capture_id = _required_text(body.get("capture_id"), "capture_id")
    entry_index = int(body.get("entry_index"))
    evidence = body.get("evidence") if isinstance(body.get("evidence"), dict) else {}
    return durable_program_event(
        project_id=project_id,
        stable_key=_required_text(node.get("stable_key"), "stable_key"),
        node_kind=_required_text(node.get("kind"), "kind"),
        capture_id=capture_id,
        entry_index=entry_index,
        summary=_required_text(node.get("title") or body.get("summary"), "summary"),
        details=_optional_text(body.get("details")),
        occurred_at=float(body.get("occurred_at")),
        source=_required_text(body.get("capture_source") or "session_capture", "capture_source"),
        provider=_optional_text(body.get("provider_key")),
        ticket_id=_optional_text(evidence.get("ticket_id")),
        run_id=_normalize_run_id(evidence.get("run_id")),
        event_type=_optional_text(body.get("event_type")),
        risk_type=_optional_text(body.get("risk_type")),
        status=_optional_text(body.get("status")),
    )


def _validate_program_event(document: Mapping[str, Any]) -> None:
    if document.get("schema_version") != PROGRAM_EVENT_SCHEMA_VERSION:
        raise ProgramArtifactError("Program event schema_version is unsupported")
    event_id = _required_text(document.get("event_id"), "event_id")
    if event_id != program_event_id(_required_text(document.get("stable_key"), "stable_key")):
        raise ProgramArtifactError("Program event_id does not match stable_key")
    _required_text(document.get("project_id"), "project_id")
    record_kind = _required_text(document.get("record_kind"), "record_kind")
    if record_kind not in _NODE_KIND_BY_RECORD:
        raise ProgramArtifactError(f"unsupported Program record_kind: {record_kind!r}")
    _required_text(document.get("capture_id"), "capture_id")
    index = document.get("entry_index")
    if not isinstance(index, int) or isinstance(index, bool) or index < 0:
        raise ProgramArtifactError("Program event entry_index must be a non-negative integer")
    _required_text(document.get("summary"), "summary")
    _required_text(document.get("capture_source"), "capture_source")
    occurred_at = document.get("occurred_at")
    if (
        not isinstance(occurred_at, (int, float))
        or isinstance(occurred_at, bool)
        or not math.isfinite(float(occurred_at))
    ):
        raise ProgramArtifactError("Program event occurred_at must be numeric")
    provider = document.get("provider")
    if provider not in {None, "codex", "claude"}:
        raise ProgramArtifactError(f"unsupported provider metadata: {provider!r}")
    evidence = document.get("evidence")
    if not isinstance(evidence, dict) or set(evidence) - {"ticket_id", "run_id"}:
        raise ProgramArtifactError("Program event evidence has unsupported fields")
    attributes = document.get("attributes")
    if not isinstance(attributes, dict) or set(attributes) - {"event_type", "risk_type", "status"}:
        raise ProgramArtifactError("Program event attributes has unsupported fields")
    allowed = {
        "schema_version", "event_id", "project_id", "record_kind", "stable_key",
        "capture_id", "entry_index", "summary", "details", "occurred_at",
        "capture_source", "provider", "evidence", "attributes",
    }
    unknown = set(document) - allowed
    if unknown:
        raise ProgramArtifactError(f"Program event contains unsupported fields: {', '.join(sorted(unknown))}")


def _program_event_files(repo: Path) -> tuple[str, dict[str, bytes]]:
    head = _git(
        repo,
        "rev-parse",
        "--verify",
        "refs/heads/relay/artifacts",
        allowed_failure=True,
    )
    if head is None:
        local_events = repo / ".orchestrator" / "program" / "events"
        local_config = repo / ".orchestrator" / "config.toml"
        artifact_configured = False
        try:
            artifact_configured = (
                tomllib.loads(local_config.read_text(encoding="utf-8")).get("artifact_ref")
                == "refs/heads/relay/artifacts"
            )
        except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
            pass
        if local_events.exists() or artifact_configured:
            raise ProgramArtifactError(
                "configured Program artifact authority is missing refs/heads/relay/artifacts"
            )
        return "", {}

    config = _git_bytes(
        repo,
        "show",
        "refs/heads/relay/artifacts:.orchestrator/config.toml",
    )
    project_id = _artifact_project_id(config)
    listing = _git(
        repo,
        "ls-tree",
        "-r",
        "--name-only",
        "refs/heads/relay/artifacts",
        "--",
        ".orchestrator/program/events",
    ) or ""
    files: dict[str, bytes] = {}
    prefix = ".orchestrator/program/events/"
    for path in listing.splitlines():
        relative = path.removeprefix(prefix)
        if not path.startswith(prefix) or not path.endswith(".json") or "/" in relative:
            raise ProgramArtifactError(f"unsupported Program artifact path: {path}")
        files[path] = _git_bytes(
            repo,
            "show",
            f"refs/heads/relay/artifacts:{path}",
        )
    return project_id, files


def _artifact_project_id(config: bytes) -> str:
    try:
        document = tomllib.loads(config.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ProgramArtifactError(f"Program artifacts have no valid project config: {error}") from error
    return _required_text(document.get("project_id"), "project_id")


def _git(
    repo: Path,
    *arguments: str,
    allowed_failure: bool = False,
) -> str | None:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        if allowed_failure:
            return None
        raise ProgramArtifactError(
            f"Git artifact read failed ({' '.join(arguments)}): {process.stderr.strip()}"
        )
    return process.stdout.strip()


def _git_bytes(repo: Path, *arguments: str) -> bytes:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise ProgramArtifactError(
            f"Git artifact read failed ({' '.join(arguments)}): {detail}"
        )
    return process.stdout


def _document_manifest(documents: Iterable[Mapping[str, Any]]) -> dict[str, str]:
    return {
        str(document["event_id"]): hashlib.sha256(canonical_program_event(document)).hexdigest()
        for document in sorted(documents, key=lambda item: str(item["event_id"]))
    }


def _artifact_manifest(
    artifact_store: ArtifactStore,
    documents: Iterable[Mapping[str, Any]],
) -> dict[str, str]:
    snapshot = artifact_store.snapshot()
    result: dict[str, str] = {}
    for document in documents:
        event_id = str(document["event_id"])
        path = f".orchestrator/program/events/{event_id}.json"
        content = snapshot.files.get(path)
        if content is not None:
            result[event_id] = hashlib.sha256(content).hexdigest()
    return dict(sorted(result.items()))


def _issue(report: dict[str, Any], kind: str, detail: str) -> None:
    issues = report.setdefault("issues", [])
    if len(issues) < _MAX_REPORT_ISSUES:
        issues.append({"kind": kind, "detail": detail})


def _inject(injector: Callable[[str], None] | None, stage: str) -> None:
    if injector is not None:
        injector(stage)


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(dict(value), sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def _json_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _required_text(value: Any, field: str) -> str:
    text = _optional_text(value)
    if not text:
        raise ProgramArtifactError(f"{field} is required")
    return text


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _normalize_provider(value: Any) -> str | None:
    text = str(value or "").strip().lower()
    if not text:
        return None
    if "codex" in text:
        return "codex"
    if "claude" in text:
        return "claude"
    raise ProgramArtifactError(f"unsupported provider metadata: {value!r}")


def _normalize_run_id(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError) as error:
        raise ProgramArtifactError("run_id must be an integer") from error


def _resolved_optional_path(value: Any) -> Path | None:
    text = _optional_text(value)
    return Path(text).expanduser().resolve() if text else None


__all__ = [
    "PROGRAM_EVENT_SCHEMA_VERSION",
    "PROJECT_CAPTURE_KINDS",
    "ProgramArtifactError",
    "ProgramArtifactMigrationError",
    "ProgramWriteResult",
    "canonical_program_event",
    "durable_program_event",
    "expected_graph_manifest",
    "export_graphify_project_captures",
    "graph_capture_manifest",
    "ingest_project_program_events",
    "program_event_id",
    "replace_graphify_with_clean_rebuild",
    "write_program_events",
]
