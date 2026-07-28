"""Durable ordered inbox in front of Relay's legacy ready-file transport."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from typing import Any


SCHEMA_VERSION = 3


def _key(payload: dict[str, Any] | None) -> tuple[int, str] | None:
    if not isinstance(payload, dict):
        return None
    try:
        seq = int(payload.get("relay_command_seq"))
    except (TypeError, ValueError):
        return None
    command_id = str(payload.get("relay_command_id") or "").strip()
    return (seq, command_id) if command_id else None


class IntentInbox:
    """SQLite-backed FIFO with stable intent, delivery, claim, and ack identity."""

    def __init__(self, path: str | os.PathLike[str]):
        self.path = str(path)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._connection:
            self._connection.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS inbox_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS intents (
                    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                    intent_id TEXT NOT NULL UNIQUE,
                    command_seq INTEGER NOT NULL,
                    command_id TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    route TEXT NOT NULL,
                    state TEXT NOT NULL,
                    delivery_id TEXT NOT NULL UNIQUE,
                    claim_id TEXT,
                    ack_id TEXT,
                    created_at REAL NOT NULL,
                    delivered_at REAL,
                    claimed_at REAL,
                    acked_at REAL,
                    cancelled_at REAL,
                    transport TEXT,
                    lease_attempts INTEGER NOT NULL DEFAULT 0,
                    recovered_at REAL
                );
                CREATE UNIQUE INDEX IF NOT EXISTS intents_command_key
                    ON intents(command_seq, command_id);
                """
            )
            columns = {
                str(row["name"])
                for row in self._connection.execute("PRAGMA table_info(intents)").fetchall()
            }
            if "ack_id" not in columns:
                self._connection.execute("ALTER TABLE intents ADD COLUMN ack_id TEXT")
            if "lease_attempts" not in columns:
                self._connection.execute(
                    "ALTER TABLE intents ADD COLUMN lease_attempts INTEGER NOT NULL DEFAULT 0"
                )
            if "recovered_at" not in columns:
                self._connection.execute("ALTER TABLE intents ADD COLUMN recovered_at REAL")
            self._connection.execute(
                "INSERT OR REPLACE INTO inbox_meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            self._connection.execute(
                """
                UPDATE intents
                   SET state='pending', recovered_at=?
                 WHERE state IN ('delivered', 'claimed')
                """,
                (time.time(),),
            )

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def enqueue(self, prompt: str, metadata: dict[str, Any], route: str) -> dict[str, Any]:
        key = _key(metadata)
        intent_id = str(metadata.get("intent_id") or metadata.get("relay_command_id") or "").strip()
        if key is None or not intent_id:
            raise ValueError("intent inbox requires stable command and intent identity")
        delivery_id = str(metadata.get("intent_delivery_id") or f"delivery:{intent_id}")
        claim_id = str(metadata.get("intent_claim_id") or f"claim:{intent_id}")
        ack_id = str(metadata.get("intent_ack_id") or f"ack:{intent_id}")
        stored = dict(metadata)
        stored["intent_id"] = intent_id
        stored["intent_delivery_id"] = delivery_id
        stored["intent_claim_id"] = claim_id
        stored["intent_ack_id"] = ack_id
        stored["intent_inbox_version"] = SCHEMA_VERSION
        now = time.time()
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT OR IGNORE INTO intents(
                    intent_id, command_seq, command_id, prompt, metadata_json,
                    route, state, delivery_id, claim_id, ack_id, created_at
                ) VALUES(?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
                """,
                (
                    intent_id,
                    key[0],
                    key[1],
                    prompt,
                    json.dumps(stored, sort_keys=True),
                    route,
                    delivery_id,
                    claim_id,
                    ack_id,
                    now,
                ),
            )
        return stored

    def cancel_pending_before(self, command_seq: int, *, reason: str) -> int:
        del reason  # The route is diagnostic; private transcript text is never logged here.
        now = time.time()
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                UPDATE intents
                   SET state='cancelled', cancelled_at=?
                 WHERE command_seq < ?
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed')
                """,
                (now, int(command_seq)),
            )
            return int(cursor.rowcount)

    def materialize_next(
        self,
        *,
        command_path: str,
        metadata_path: str,
        transport: str,
    ) -> dict[str, Any] | None:
        """Atomically lease the oldest pending intent into the compatibility mailbox."""
        if os.path.exists(command_path) or os.path.exists(metadata_path):
            return None
        with self._lock, self._connection:
            unacked = self._connection.execute(
                """
                SELECT ordinal
                  FROM intents
                 WHERE route != 'run_sidecar'
                   AND state IN ('delivered', 'claimed')
                 ORDER BY ordinal
                 LIMIT 1
                """
            ).fetchone()
            if unacked is not None:
                return None
            row = self._connection.execute(
                """
                SELECT *
                  FROM intents
                 WHERE state='pending' AND route != 'run_sidecar'
                 ORDER BY ordinal
                 LIMIT 1
                """
            ).fetchone()
            if row is None:
                return None
            metadata = json.loads(row["metadata_json"])
            metadata["intent_delivery_id"] = row["delivery_id"]
            command_tmp = command_path + ".tmp"
            metadata_tmp = metadata_path + ".tmp"
            Path(metadata_tmp).write_text(json.dumps(metadata, sort_keys=True))
            Path(command_tmp).write_text(str(row["prompt"]))
            os.replace(metadata_tmp, metadata_path)
            os.replace(command_tmp, command_path)
            self._connection.execute(
                """
                UPDATE intents
                   SET state='delivered', delivered_at=?, transport=?,
                       lease_attempts=lease_attempts + 1
                 WHERE ordinal=? AND state='pending'
                """,
                (time.time(), transport, int(row["ordinal"])),
            )
            return metadata

    def observe_claim(self, claimed: dict[str, Any], *, provider_turn_seen: bool) -> bool:
        key = _key(claimed)
        if key is None:
            return False
        now = time.time()
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT state, claim_id, ack_id FROM intents WHERE command_seq=? AND command_id=?",
                key,
            ).fetchone()
            if row is None:
                return False
            state = str(row["state"])
            claim_id = str(claimed.get("intent_claim_id") or row["claim_id"] or f"claim:{key[0]}:{key[1]}")
            ack_id = str(claimed.get("intent_ack_id") or row["ack_id"] or f"ack:{key[0]}:{key[1]}")
            if state in {"delivered", "pending"}:
                self._connection.execute(
                    """
                    UPDATE intents
                       SET state='claimed', claim_id=?, ack_id=?, claimed_at=?
                     WHERE command_seq=? AND command_id=?
                    """,
                    (claim_id, ack_id, now, key[0], key[1]),
                )
                state = "claimed"
            if provider_turn_seen and state == "claimed":
                self._connection.execute(
                    """
                    UPDATE intents SET state='acked', ack_id=?, acked_at=?
                     WHERE command_seq=? AND command_id=?
                    """,
                    (ack_id, now, key[0], key[1]),
                )
            return True

    def pending_for_route(self, route: str) -> list[dict[str, Any]]:
        """Return durable work owned by a non-mailbox execution lane."""
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT prompt, metadata_json
                  FROM intents
                 WHERE state='pending' AND route=?
                 ORDER BY ordinal
                """,
                (str(route),),
            ).fetchall()
        return [
            {
                "prompt": str(row["prompt"]),
                "metadata": json.loads(row["metadata_json"]),
            }
            for row in rows
        ]

    def deliverable_commands(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT command_seq, command_id, intent_id, route, state
                  FROM intents
                 WHERE state IN ('pending', 'delivered', 'claimed')
                 ORDER BY ordinal
                """
            ).fetchall()
        return [
            {
                "relay_command_seq": int(row["command_seq"]),
                "relay_command_id": str(row["command_id"]),
                "intent_id": str(row["intent_id"]),
                "route": str(row["route"]),
                "state": str(row["state"]),
            }
            for row in rows
        ]

    def records(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM intents ORDER BY ordinal"
            ).fetchall()
        return [dict(row) for row in rows]


def sync_deliverable_state(state_path: str, inbox: IntentInbox) -> None:
    try:
        payload = json.loads(Path(state_path).read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    payload["intent_inbox_version"] = SCHEMA_VERSION
    payload["deliverable_commands"] = inbox.deliverable_commands()
    tmp = state_path + ".tmp"
    Path(tmp).write_text(json.dumps(payload, sort_keys=True))
    os.replace(tmp, state_path)
