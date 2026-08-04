"""Durable proposal state for implementation tickets derived from spike findings."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any


PRIVATE_CONTENT_RE = re.compile(
    r"\b(raw\s+(?:provider\s+)?transcript|chain[- ]of[- ]thought|hidden\s+reasoning|"
    r"scratchpad|system\s+prompt|tool\s+log)\b|"
    r"\b(?:sk|ghp|github_pat)-[A-Za-z0-9_-]{12,}\b|BEGIN [A-Z ]*PRIVATE KEY",
    re.IGNORECASE,
)
FOLLOWUP_KEY_PREFIX = "relay-spike-followup-key:"
PROPOSAL_STATES = frozenset({"draft", "accepted", "rejected"})
PRIORITIES = frozenset({"urgent", "high", "medium", "low"})
EFFORTS = frozenset({"low", "medium", "high", "xhigh", "max"})


def _clean_text(value: Any, field: str, *, multiline: bool = False) -> str:
    raw = str(value or "").strip()
    if not raw:
        raise ValueError(f"{field} is required")
    text = raw if multiline else re.sub(r"\s+", " ", raw)
    if PRIVATE_CONTENT_RE.search(text):
        raise ValueError(f"{field} contains private provider or secret material")
    return text


def _string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list):
        raise ValueError(f"{field} must be a list")
    result = [_clean_text(item, field) for item in value if str(item or "").strip()]
    if not result:
        raise ValueError(f"{field} must be a non-empty list")
    return result


def sanitize_followup_draft(value: Any, *, origin_repo_path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("each follow-up proposal must be an object")
    priority = str(value.get("priority") or "medium").strip().lower()
    if priority not in PRIORITIES:
        raise ValueError(f"invalid follow-up priority: {priority!r}")
    model = _clean_text(value.get("worker_model") or "balanced", "worker_model")
    effort = str(value.get("worker_effort") or "medium").strip().lower()
    if effort not in EFFORTS:
        raise ValueError(f"invalid follow-up worker_effort: {effort!r}")
    if effort == "max" and not model.lower().startswith("claude:"):
        raise ValueError("worker_effort max requires an explicitly Claude-scoped worker_model")
    dependencies = value.get("depends_on")
    if dependencies is None:
        dependencies = []
    if not isinstance(dependencies, list):
        raise ValueError("depends_on must be a list")
    return {
        "title": _clean_text(value.get("title"), "title")[:120],
        "description": _clean_text(value.get("description"), "description", multiline=True),
        "acceptance_criteria": _string_list(value.get("acceptance_criteria"), "acceptance_criteria"),
        "priority": priority,
        "depends_on": [str(item).strip().upper() for item in dependencies if str(item).strip()],
        "worker_model": model,
        "worker_effort": effort,
        "worker_sizing_rationale": _clean_text(
            value.get("worker_sizing_rationale")
            or "Spike follow-up uses balanced sizing until the user refines the implementation scope.",
            "worker_sizing_rationale",
        ),
        "worker_provider_notes": _clean_text(
            value.get("worker_provider_notes")
            or "Codex and Claude must implement the same accepted ticket contract.",
            "worker_provider_notes",
        ),
        "target_repo_path": str(
            Path(value.get("target_repo_path") or origin_repo_path).expanduser().resolve()
        ),
    }


def recommended_next_steps(spike_body: str) -> list[str]:
    match = re.search(
        r"^\*\*Recommended next steps\*\*\s*\n(.*?)(?=^\*\*[^\n]+\*\*\s*$|^## |\Z)",
        spike_body,
        re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    if not match:
        return []
    steps: list[str] = []
    for line in match.group(1).splitlines():
        bullet = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if bullet:
            item = _clean_text(bullet.group(1), "recommended next step")
            if not item.lower().startswith("no follow-up recommended"):
                steps.append(item)
    return steps


def automatic_followup_drafts(spike_body: str, *, origin_repo_path: str) -> list[dict[str, Any]]:
    drafts: list[dict[str, Any]] = []
    for recommendation in recommended_next_steps(spike_body):
        title = recommendation.rstrip(".")
        if len(title) > 76:
            title = title[:73].rstrip() + "..."
        drafts.append(sanitize_followup_draft({
            "title": title,
            "description": recommendation,
            "acceptance_criteria": [
                f"The accepted spike recommendation is implemented: {recommendation}",
                "Focused verification covers the changed behavior.",
                "The run log records the implementation outcome and any remaining uncertainty.",
            ],
            "priority": "medium",
            "depends_on": [],
            "worker_model": "balanced",
            "worker_effort": "medium",
            "worker_sizing_rationale": (
                "Automatically proposed from a completed spike; review and adjust sizing before acceptance."
            ),
            "worker_provider_notes": (
                "Codex uses model_reasoning_effort and Claude uses --effort while preserving the same ticket outcome."
            ),
            "target_repo_path": origin_repo_path,
        }, origin_repo_path=origin_repo_path))
    return drafts


def batch_id(origin_repo_path: str, origin_ticket_id: str, origin_run_id: int) -> str:
    canonical = f"{Path(origin_repo_path).resolve()}\0{origin_ticket_id.upper()}\0{origin_run_id}"
    return "spike-" + hashlib.sha256(canonical.encode()).hexdigest()[:24]


def proposal_id(batch: str, position: int) -> str:
    return "proposal-" + hashlib.sha256(f"{batch}\0{position}".encode()).hexdigest()[:16]


def acceptance_key(batch: str, proposal: str) -> str:
    return hashlib.sha256(f"{batch}\0{proposal}".encode()).hexdigest()


class FollowupProposalStore:
    SCHEMA = """
    CREATE TABLE IF NOT EXISTS batches (
        id TEXT PRIMARY KEY,
        origin_repo_path TEXT NOT NULL,
        origin_ticket_id TEXT NOT NULL,
        origin_run_id INTEGER NOT NULL,
        provider_key TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY,
        batch_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(batch_id, position)
    );
    CREATE INDEX IF NOT EXISTS idx_followup_proposals_batch ON proposals(batch_id, position);
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        with self._conn() as conn:
            conn.executescript(self.SCHEMA)

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def create_or_get(
        self,
        *,
        origin_repo_path: str,
        origin_ticket_id: str,
        origin_run_id: int,
        provider_key: str | None,
        drafts: list[dict[str, Any]],
    ) -> tuple[dict[str, Any], bool]:
        identifier = batch_id(origin_repo_path, origin_ticket_id, origin_run_id)
        now = time.time()
        with self._conn() as conn:
            existing = conn.execute("SELECT 1 FROM batches WHERE id = ?", (identifier,)).fetchone()
            if existing:
                return self._get(conn, identifier), False
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute(
                    "INSERT INTO batches VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (identifier, origin_repo_path, origin_ticket_id, origin_run_id, provider_key, now, now),
                )
                for position, draft in enumerate(drafts):
                    conn.execute(
                        "INSERT INTO proposals VALUES (?, ?, ?, 'draft', ?, NULL, NULL, ?)",
                        (proposal_id(identifier, position), identifier, position,
                         json.dumps(draft, sort_keys=True), now),
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
            return self._get(conn, identifier), True

    def get(self, identifier: str) -> dict[str, Any] | None:
        with self._conn() as conn:
            row = conn.execute("SELECT 1 FROM batches WHERE id = ?", (identifier,)).fetchone()
            return self._get(conn, identifier) if row else None

    def update_draft(self, identifier: str, proposal: str, draft: dict[str, Any]) -> dict[str, Any]:
        now = time.time()
        with self._conn() as conn:
            current = conn.execute(
                "SELECT state FROM proposals WHERE batch_id = ? AND id = ?", (identifier, proposal)
            ).fetchone()
            if current is None:
                raise ValueError(f"follow-up proposal {proposal} not found")
            if current["state"] != "draft":
                raise ValueError(f"follow-up proposal {proposal} is already {current['state']}")
            conn.execute(
                "UPDATE proposals SET draft_json = ?, error = NULL, updated_at = ? WHERE id = ?",
                (json.dumps(draft, sort_keys=True), now, proposal),
            )
            conn.execute("UPDATE batches SET updated_at = ? WHERE id = ?", (now, identifier))
            return self._get(conn, identifier)

    def set_result(
        self,
        identifier: str,
        proposal: str,
        *,
        state: str,
        ticket_id: str | None = None,
        error: str | None = None,
    ) -> dict[str, Any]:
        if state not in PROPOSAL_STATES:
            raise ValueError(f"invalid follow-up proposal state: {state}")
        now = time.time()
        with self._conn() as conn:
            changed = conn.execute(
                "UPDATE proposals SET state = ?, ticket_id = ?, error = ?, updated_at = ? "
                "WHERE batch_id = ? AND id = ?",
                (state, ticket_id, error, now, identifier, proposal),
            ).rowcount
            if not changed:
                raise ValueError(f"follow-up proposal {proposal} not found")
            conn.execute("UPDATE batches SET updated_at = ? WHERE id = ?", (now, identifier))
            return self._get(conn, identifier)

    def set_error(self, identifier: str, proposal: str, error: str) -> dict[str, Any]:
        now = time.time()
        with self._conn() as conn:
            conn.execute(
                "UPDATE proposals SET error = ?, updated_at = ? WHERE batch_id = ? AND id = ?",
                (error, now, identifier, proposal),
            )
            conn.execute("UPDATE batches SET updated_at = ? WHERE id = ?", (now, identifier))
            return self._get(conn, identifier)

    @staticmethod
    def _get(conn: sqlite3.Connection, identifier: str) -> dict[str, Any]:
        batch = conn.execute("SELECT * FROM batches WHERE id = ?", (identifier,)).fetchone()
        if batch is None:
            raise ValueError(f"follow-up batch {identifier} not found")
        payload = dict(batch)
        payload["proposals"] = []
        for row in conn.execute(
            "SELECT * FROM proposals WHERE batch_id = ? ORDER BY position", (identifier,)
        ).fetchall():
            proposal = dict(row)
            proposal["draft"] = json.loads(proposal.pop("draft_json"))
            payload["proposals"].append(proposal)
        return payload
