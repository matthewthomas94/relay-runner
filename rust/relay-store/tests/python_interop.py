"""The Python half of relay-store's interop test (tests/python_interop.rs).

    python3 python_interop.py <services dir> <data root> <phase>

Opens the daemon's databases under <data root> with the Python stores in
<services dir>, the same files the Rust stores open, and runs one phase:

- fresh: create every database, so the Rust test can compare schemas.
- read:  print the result of a fixed set of store reads as sorted JSON. The
         Rust test makes the same reads and compares the text.
- write: write through every Python store, over rows the Rust stores wrote.
- index: write the board index to <data root>/runs.python.json.

The identities (repositories, tickets, commands) match the Rust test's.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SERVICES, DATA_ROOT, PHASE = sys.argv[1:4]
sys.path.insert(0, SERVICES)

from continuity_incidents import opaque_identifier  # noqa: E402
from continuity_reports import ContinuityReportStore, sanitize_proposal  # noqa: E402,F401
from followup_tickets import FollowupProposalStore, batch_id  # noqa: E402
from general_work import GeneralWorkStore  # noqa: E402
from graphify_core import GraphifyCoreStore  # noqa: E402
from orchestrator import (  # noqa: E402
    MessengerOutcomeStore,
    OrchestratorCommandStore,
    OrchestratorSessionStore,
    QueueDrainStore,
    RunsStore,
)
from personal_file_storage import GitHubFiles, PersonalFileStorage  # noqa: E402
from personal_notes import PersonalNoteManager  # noqa: E402

DATA = Path(DATA_ROOT)
STATE = DATA.parent
REPO_A = str(STATE / "repo-a")
REPO_B = str(STATE / "repo-b")


def stores(index_path=None):
    return {
        "runs": RunsStore(DATA / "runs.db", index_path=index_path),
        "drains": QueueDrainStore(DATA / "queue_drains.db"),
        "sessions": OrchestratorSessionStore(DATA / "orchestrator_sessions.db"),
        "commands": OrchestratorCommandStore(DATA / "orchestrator_commands.db"),
        "outcomes": MessengerOutcomeStore(DATA / "messenger_outcomes.db"),
        "followups": FollowupProposalStore(DATA / "followup_proposals.db"),
        "continuity": ContinuityReportStore(DATA / "continuity_reports.db"),
        "graph": GraphifyCoreStore(DATA / "graphify.db"),
        "general": GeneralWorkStore(STATE),
        "personal": PersonalFileStorage(STATE, github=GitHubFiles(executable="/nonexistent/gh")),
    }


def fresh() -> None:
    opened = stores()
    PersonalNoteManager(opened["personal"], "interop")


def read() -> None:
    s = stores()
    runs, drains, commands = s["runs"], s["drains"], s["commands"]
    outcomes, graph, general, personal = s["outcomes"], s["graph"], s["general"], s["personal"]
    listing = general.list(limit=100)

    def catalog(sql, *args):
        return [dict(row) for row in personal.db.execute(sql, args).fetchall()]

    reads = {
        "runs.list": runs.list(limit=100),
        "runs.list.state": runs.list(state="Running", limit=10),
        "runs.get.1": runs.get(1),
        "runs.find_active.RT-2": runs.find_active("RT-2", REPO_A),
        "runs.find_awaiting_merge.RT-1": runs.find_awaiting_merge("RT-1", REPO_A),
        "runs.next_attempt.RT-1": runs.next_attempt("RT-1", REPO_A),
        "runs.recent.RT-3": runs.recent_for_ticket("RT-3", REPO_A, limit=10),
        "runs.active_count": runs.active_count(),
        "runs.list_for_repo.a": runs.list_for_repo(REPO_A),
        "runs.replacements": runs.reconciled_replacements(
            historical_run_id=50, ticket_id="RT-3", repo_path=REPO_A),
        "drains.list": drains.list(include_terminal=True, limit=20),
        "drains.live": drains.list(limit=20),
        "drains.active.a": drains.active_for_repo(REPO_A),
        "drains.active_paths": sorted(drains.active_repo_paths()),
        "sessions.get.1": s["sessions"].get(1),
        "sessions.get.2": s["sessions"].get(2),
        "commands.private.7.1": commands.get_private("cmd-7", intent_id="cmd-7:1"),
        "commands.public.7": commands.get_public("cmd-7"),
        "commands.pending": commands.pending(),
        "commands.recoverable": commands.recoverable(),
        "commands.opaque": commands.find_by_opaque_command_id(opaque_identifier("command", "cmd-7")),
        "outcomes.all": outcomes.pending(limit=100),
        "outcomes.session": outcomes.pending(
            repo_path=REPO_B, limit=100, session_key="session-a", live_session_keys=["session-b"]),
        "followups.a": s["followups"].get(batch_id(REPO_A, "RT-9", 1)),
        "followups.b": s["followups"].get(batch_id(REPO_B, "PY-9", 2)),
        "continuity": s["continuity"].get("continuity-report-rr496"),
        "graph.nodes": graph.nodes(),
        "graph.edges": graph.edges(),
        "graph.neighbors": graph.neighbors("project:a"),
        "graph.tickets.claude": graph.tickets_by_state(provider="claude"),
        "graph.blocked": graph.blocked_work(),
        "graph.manifests": graph.file_manifests(include_deleted=True),
        "graph.search": graph.search_files("relay"),
        "general.list": listing,
        "general.get": [general.get(task["id"]) for task in listing["tasks"]],
        "catalog.state": personal._get("state"),
        "catalog.python": personal._get("python"),
        "catalog.files": catalog("SELECT * FROM files ORDER BY artifact_id"),
        "catalog.versions": catalog("SELECT * FROM versions ORDER BY artifact_id, sha256"),
        "catalog.notes": [
            [json.loads(row["entry"]), bool(row["deleted"])]
            for row in personal.db.execute("SELECT * FROM personal_notes ORDER BY artifact_id")
        ],
        "catalog.note_events": catalog("SELECT * FROM personal_note_events ORDER BY event_id"),
    }
    print(json.dumps(reads, sort_keys=True))


def write() -> None:
    s = stores()
    Path(REPO_B).mkdir(parents=True, exist_ok=True)
    runs = s["runs"]
    run_id = runs.insert(
        ticket_id="PY-1", repo_path=str(Path(REPO_B).resolve()), workspace_path="/ws/py-1",
        branch="relay/py-1", state="Claimed", provider_key="codex", model_alias="gpt",
        worker_model="balanced", worker_effort="medium",
        worker_sizing_rationale="Python wrote this run.", worker_provider_notes="none",
    )
    runs.set_activity(run_id, "Python activity")
    runs.update(run_id, state="Merged", exit_code=0, ended=True, last_error=None)

    drains = s["drains"]
    drain, _ = drains.ensure_active(
        repo_path=REPO_B, target_branch="main", provider_key="codex", observed_ticket_ids=["py-1"])
    drains.update_items(drain["id"], [{"ticket_id": "py-1", "state": "done", "run_id": run_id,
                                       "reason": "source ticket is done"}])
    drains.cancel(drain["id"], reason="Python canceled it.")
    rust_drain = drains.active_for_repo(REPO_A)
    drains.update_items(rust_drain["id"], [{
        "ticket_id": "RT-1", "state": "waiting", "run_id": 1, "reason": "Python reclassified it",
        "next_action_at": 12.5, "unresolved_dependencies": ["RT-0"],
    }])

    sessions = s["sessions"]
    sessions.ensure(repo_path=REPO_B, provider_key="codex", model_alias="gpt", effort="high",
                    source="python")
    sessions.heartbeat(repo_path=REPO_A, state="reviewing")

    commands = s["commands"]
    commands.record(repo_path=REPO_B, source_text="python command", relay_command_seq="8",
                    relay_command_id="cmd-8", within_turn_order="2", provider_key="codex",
                    recovery_generation=3, context="a\n\n  b  ")
    commands.update_status("cmd-7", intent_id="cmd-7:1", status="handled", outcome="python")

    outcomes = s["outcomes"]
    outcomes.record(repo_path=REPO_B, provider_key="codex", payload={
        "text": "PY-1 merged", "trace_event": {
            "kind": "run-merged", "message": "PY-1 merged", "ticket_id": "py-1",
            "run_id": run_id, "source": "orchestrator"}})
    outcomes.mark_delivered(1)
    outcomes.record_attempt(2)

    followups = s["followups"]
    batch = followups.get(batch_id(REPO_A, "RT-9", 1))
    proposal = batch["proposals"][0]
    followups.update_draft(batch["id"], proposal["id"], {**proposal["draft"], "title": "Python edit"})
    created, _ = followups.create_or_get(
        origin_repo_path=REPO_B, origin_ticket_id="PY-9", origin_run_id=2, provider_key="codex",
        drafts=[{"title": "Python follow-up", "priority": "low"}])
    followups.set_result(created["id"], created["proposals"][0]["id"], state="rejected")

    continuity = s["continuity"]
    report = continuity.get("continuity-report-rr496")
    continuity.update_draft(report["report_id"], report["proposals"][0]["id"],
                            {"title": "Python continuity edit"})
    continuity.reject(report["report_id"], report["proposals"][1]["id"])

    graph = s["graph"]
    with graph.transaction():
        graph.upsert_node(kind="Project", stable_key="b", project_id="project:b", title="B",
                          node_id="project:b", body={"provider_key": "codex"})
        graph.upsert_node(kind="Ticket", stable_key="b:PY-1", project_id="project:b",
                          title="PY-1", body={"status": "awaiting_merge"})
        graph.upsert_edge(src_id="ticket:b:PY-1", dst_id="project:b", kind="belongs_to",
                          body={"by": "python"})
        graph.upsert_file_index(
            project_id="project:b", rel_path="docs/relay.md", language="markdown",
            size_bytes=5, mtime_ns=None,
            chunks=[{"text": "relay runner python", "start_line": 1, "end_line": 2}])
    graph.mark_missing_files_deleted(project_id="project:a", seen_rel_paths=set())

    general = s["general"]
    general.create(title="Python task", description="Written by Python.",
                   acceptance_criteria=["It reads back in Rust."], request_id="py-request")

    personal = s["personal"]
    with personal.lock:
        personal._set("python", {"wrote": True, "n": 2})
        personal.db.commit()
    personal.put("doc-2", "documents/b.md", b"python", metadata={"by": "python"}, active=True)
    personal.pin("doc-1", True)
    manager = PersonalNoteManager(personal, "interop")
    with personal.lock:
        personal.db.execute("UPDATE personal_notes SET deleted=1 WHERE artifact_id=?", ("note-1",))
        personal.db.execute("INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                            ("event-py", "digest-py", "note-1", "revision-py"))
        personal.db.commit()
    del manager


def index() -> None:
    stores(index_path=DATA / "runs.python.json")["runs"].write_index()


{"fresh": fresh, "read": read, "write": write, "index": index}[PHASE]()
