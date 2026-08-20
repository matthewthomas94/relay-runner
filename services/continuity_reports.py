"""Privacy-safe unresolved continuity reports and reviewable fix proposals."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Mapping

from continuity_agent import sanitize_incident_bundle
from followup_tickets import PRIVATE_CONTENT_RE


UNRESOLVED_RESULTS = frozenset({
    "authorization_required",
    "canceled",
    "circuit_open",
    "provider_failed",
})


def _clean(value: Any, field: str) -> str:
    text = re.sub(r"\s+", " ", str(value or "").strip())
    if not text:
        raise ValueError(f"{field} is required")
    if PRIVATE_CONTENT_RE.search(text):
        raise ValueError(f"{field} contains private provider or secret material")
    return text


def _default_proposal(incident: Mapping[str, object]) -> dict[str, Any]:
    component = str(incident["component"])
    provider = str(incident["provider"])
    provider_scope = " for both Codex and Claude" if provider != "none" else ""
    return {
        "title": f"Prevent recurring {component.replace('_', ' ')} continuity failure"[:120],
        "description": (
            f"Diagnose and permanently correct the sanitized {component} continuity "
            f"failure represented by incident {incident['incident_id']}{provider_scope}."
        ),
        "acceptance_criteria": [
            "The underlying continuity defect is reproduced with privacy-safe evidence.",
            "The permanent fix preserves exact command, reply, and speech ownership.",
            "Focused Codex and Claude regression coverage passes.",
        ],
        "priority": "high",
        "depends_on": [],
        "worker_model": "strong",
        "worker_effort": "high",
        "worker_sizing_rationale": (
            "Continuity defects cross process recovery, command identity, and speech safety."
        ),
        "worker_provider_notes": (
            "Codex and Claude must preserve the same recovery and no-duplicate guarantees."
        ),
    }


def sanitize_proposal(value: Mapping[str, object]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ValueError("continuity proposal must be an object")
    criteria = value.get("acceptance_criteria")
    dependencies = value.get("depends_on", [])
    if not isinstance(criteria, list) or not criteria:
        raise ValueError("acceptance_criteria must be a non-empty list")
    if not isinstance(dependencies, list):
        raise ValueError("depends_on must be a list")
    priority = str(value.get("priority") or "high").strip().lower()
    if priority not in {"urgent", "high", "medium", "low"}:
        raise ValueError("invalid continuity proposal priority")
    effort = str(value.get("worker_effort") or "high").strip().lower()
    if effort not in {"low", "medium", "high", "xhigh", "max"}:
        raise ValueError("invalid continuity proposal effort")
    model = _clean(value.get("worker_model") or "strong", "worker_model")
    if effort == "max" and not model.lower().startswith("claude:"):
        raise ValueError("worker_effort max requires an explicitly Claude-scoped model")
    return {
        "title": _clean(value.get("title"), "title")[:120],
        "description": _clean(value.get("description"), "description"),
        "acceptance_criteria": [_clean(item, "acceptance_criteria") for item in criteria],
        "priority": priority,
        "depends_on": [str(item).strip().upper() for item in dependencies if str(item).strip()],
        "worker_model": model,
        "worker_effort": effort,
        "worker_sizing_rationale": _clean(
            value.get("worker_sizing_rationale"), "worker_sizing_rationale"
        ),
        "worker_provider_notes": _clean(
            value.get("worker_provider_notes"), "worker_provider_notes"
        ),
    }


def build_report(incident: Mapping[str, object], final_result: str) -> dict[str, Any]:
    sanitized = sanitize_incident_bundle(incident)
    redaction_count = len(set(incident) - set(sanitized))
    result = str(final_result or "").strip().lower()
    if result not in UNRESOLVED_RESULTS:
        raise ValueError("continuity report requires an unresolved recovery result")
    report_id = "continuity-report-" + hashlib.sha256(
        f"{sanitized['incident_id']}\0{sanitized['recovery_generation']}".encode()
    ).hexdigest()[:20]
    recurrence = "high" if sanitized["classification"] == "recurring" else "unknown"
    return {
        "schema_version": 1,
        "report_id": report_id,
        "status": "unresolved",
        "incident": sanitized,
        "recovery_result": result,
        "likely_cause_category": f"{sanitized['component']}_unavailable",
        "cause_confidence": "unconfirmed",
        "recurrence_likelihood": recurrence,
        "risks": ["voice_processing_continuity_unavailable"],
        "unresolved_questions": [
            "Which component-owned defect prevented stable recovery?",
        ],
        "redaction_count": redaction_count,
    }


class ContinuityReportStore:
    SCHEMA = """
    CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY,
        incident_id TEXT NOT NULL UNIQUE,
        state TEXT NOT NULL,
        report_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY,
        report_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(report_id, position)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_proposals_report
        ON proposals(report_id, position);
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        with self._conn() as connection:
            connection.executescript(self.SCHEMA)
            connection.execute(
                "UPDATE proposals SET state = 'draft', error = ? WHERE state = 'accepting'",
                ("acceptance interrupted; review again",),
            )

    @contextmanager
    def _conn(self):
        with self._lock:
            connection = sqlite3.connect(str(self.path), isolation_level=None)
            connection.row_factory = sqlite3.Row
            try:
                yield connection
            finally:
                connection.close()

    def record_unresolved(
        self,
        incident: Mapping[str, object],
        final_result: str,
        *,
        proposals: list[Mapping[str, object]] | None = None,
    ) -> tuple[dict[str, Any], bool]:
        report = build_report(incident, final_result)
        drafts = [
            sanitize_proposal(item)
            for item in (proposals or [_default_proposal(report["incident"])])
        ]
        now = time.time()
        with self._conn() as connection:
            existing = connection.execute(
                "SELECT 1 FROM reports WHERE id = ?", (report["report_id"],)
            ).fetchone()
            if existing:
                return self._get(connection, report["report_id"]), False
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    "INSERT INTO reports VALUES (?, ?, 'unresolved', ?, ?, ?)",
                    (
                        report["report_id"], report["incident"]["incident_id"],
                        json.dumps(report, sort_keys=True), now, now,
                    ),
                )
                for position, draft in enumerate(drafts):
                    proposal_id = "continuity-proposal-" + hashlib.sha256(
                        f"{report['report_id']}\0{position}".encode()
                    ).hexdigest()[:16]
                    connection.execute(
                        "INSERT INTO proposals VALUES (?, ?, ?, 'draft', ?, NULL, NULL, ?)",
                        (
                            proposal_id, report["report_id"], position,
                            json.dumps(draft, sort_keys=True), now,
                        ),
                    )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
            return self._get(connection, report["report_id"]), True

    def get(self, report_id: str) -> dict[str, Any] | None:
        with self._conn() as connection:
            exists = connection.execute(
                "SELECT 1 FROM reports WHERE id = ?", (report_id,)
            ).fetchone()
            return self._get(connection, report_id) if exists else None

    def update_draft(
        self, report_id: str, proposal_id: str, updates: Mapping[str, object]
    ) -> dict[str, Any]:
        with self._conn() as connection:
            row = self._proposal(connection, report_id, proposal_id)
            if row["state"] != "draft":
                raise ValueError(f"continuity proposal is already {row['state']}")
            draft = sanitize_proposal({**json.loads(row["draft_json"]), **dict(updates)})
            now = time.time()
            connection.execute(
                "UPDATE proposals SET draft_json = ?, error = NULL, updated_at = ? WHERE id = ?",
                (json.dumps(draft, sort_keys=True), now, proposal_id),
            )
            connection.execute("UPDATE reports SET updated_at = ? WHERE id = ?", (now, report_id))
            return self._get(connection, report_id)

    def claim_acceptance(self, report_id: str, proposal_id: str) -> dict[str, Any] | None:
        with self._conn() as connection:
            row = self._proposal(connection, report_id, proposal_id)
            if row["state"] == "accepted":
                return None
            if row["state"] != "draft":
                raise ValueError(f"continuity proposal is already {row['state']}")
            changed = connection.execute(
                "UPDATE proposals SET state = 'accepting', error = NULL, updated_at = ? "
                "WHERE id = ? AND state = 'draft'",
                (time.time(), proposal_id),
            ).rowcount
            if changed != 1:
                raise ValueError("continuity proposal acceptance raced another review")
            return json.loads(row["draft_json"])

    def finish_acceptance(
        self,
        report_id: str,
        proposal_id: str,
        *,
        ticket_id: str | None = None,
        error: str | None = None,
    ) -> dict[str, Any]:
        state = "accepted" if ticket_id else "draft"
        with self._conn() as connection:
            self._proposal(connection, report_id, proposal_id)
            now = time.time()
            connection.execute(
                "UPDATE proposals SET state = ?, ticket_id = ?, error = ?, updated_at = ? "
                "WHERE id = ?",
                (state, ticket_id, error, now, proposal_id),
            )
            connection.execute("UPDATE reports SET updated_at = ? WHERE id = ?", (now, report_id))
            return self._get(connection, report_id)

    def reject(self, report_id: str, proposal_id: str) -> dict[str, Any]:
        with self._conn() as connection:
            row = self._proposal(connection, report_id, proposal_id)
            if row["state"] != "draft":
                raise ValueError(f"continuity proposal is already {row['state']}")
            now = time.time()
            connection.execute(
                "UPDATE proposals SET state = 'rejected', updated_at = ? WHERE id = ?",
                (now, proposal_id),
            )
            connection.execute("UPDATE reports SET updated_at = ? WHERE id = ?", (now, report_id))
            return self._get(connection, report_id)

    @staticmethod
    def _proposal(connection: sqlite3.Connection, report_id: str, proposal_id: str):
        row = connection.execute(
            "SELECT * FROM proposals WHERE report_id = ? AND id = ?",
            (report_id, proposal_id),
        ).fetchone()
        if row is None:
            raise ValueError(f"continuity proposal {proposal_id} not found")
        return row

    @staticmethod
    def _get(connection: sqlite3.Connection, report_id: str) -> dict[str, Any]:
        row = connection.execute("SELECT * FROM reports WHERE id = ?", (report_id,)).fetchone()
        if row is None:
            raise ValueError(f"continuity report {report_id} not found")
        payload = json.loads(row["report_json"])
        payload["created_at"] = row["created_at"]
        payload["updated_at"] = row["updated_at"]
        payload["proposals"] = []
        for proposal in connection.execute(
            "SELECT * FROM proposals WHERE report_id = ? ORDER BY position", (report_id,)
        ).fetchall():
            item = dict(proposal)
            item["draft"] = json.loads(item.pop("draft_json"))
            payload["proposals"].append(item)
        return payload
