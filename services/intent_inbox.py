"""Durable ordered inbox in front of Relay's legacy ready-file transport."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from typing import Any

from continuity_incidents import normalize_recovery_generation
from provider_turn_broker import (
    ProviderTurnBroker,
    ensure_broker_schema,
    record_intent_events,
)


SCHEMA_VERSION = 5


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

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        provider_turn_projection_path: str | os.PathLike[str] | None = None,
        hold_recovered_delivery: bool = False,
    ):
        self.path = str(path)
        self.provider_turn_projection_path = (
            str(provider_turn_projection_path)
            if provider_turn_projection_path is not None
            else None
        )
        self.provider_turn_events_enabled = self.provider_turn_projection_path is not None
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
                    within_turn_order INTEGER NOT NULL DEFAULT 1,
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
                    recovered_at REAL,
                    recovery_generation TEXT NOT NULL DEFAULT '0',
                    recovery_decision TEXT
                );
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
            if "within_turn_order" not in columns:
                self._connection.execute(
                    "ALTER TABLE intents ADD COLUMN within_turn_order INTEGER NOT NULL DEFAULT 1"
                )
            if "recovery_generation" not in columns:
                self._connection.execute(
                    "ALTER TABLE intents ADD COLUMN recovery_generation TEXT NOT NULL DEFAULT '0'"
                )
                for row in self._connection.execute(
                    "SELECT intent_id, metadata_json FROM intents"
                ).fetchall():
                    try:
                        metadata = json.loads(row["metadata_json"])
                        if not isinstance(metadata, dict):
                            continue
                        generation = normalize_recovery_generation(
                            metadata.get("recovery_generation")
                        )
                    except (json.JSONDecodeError, TypeError, ValueError):
                        continue
                    self._connection.execute(
                        "UPDATE intents SET recovery_generation=? WHERE intent_id=?",
                        (generation, str(row["intent_id"])),
                    )
            if "recovery_decision" not in columns:
                self._connection.execute(
                    "ALTER TABLE intents ADD COLUMN recovery_decision TEXT"
                )
            self._connection.execute("DROP INDEX IF EXISTS intents_command_key")
            self._connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS intents_command_item_key "
                "ON intents(command_seq, command_id, within_turn_order)"
            )
            self._connection.execute(
                "INSERT OR REPLACE INTO inbox_meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            recovered = (
                self._connection.execute(
                    "SELECT intent_id FROM intents "
                    "WHERE state IN ('delivered', 'claimed') "
                    "OR (? = 1 AND state='pending')",
                    (int(hold_recovered_delivery),),
                ).fetchall()
                if self.provider_turn_events_enabled
                else []
            )
            if self.provider_turn_events_enabled:
                ensure_broker_schema(self._connection)
            self._connection.execute(
                """
                UPDATE intents
                   SET state=CASE
                       WHEN state IN ('pending', 'delivered') THEN ?
                       ELSE 'review_required'
                   END,
                       recovered_at=?,
                       recovery_decision=CASE
                           WHEN state IN ('pending', 'delivered') THEN 'resume_exact'
                           ELSE 'foreground_review'
                       END
                 WHERE state IN ('delivered', 'claimed')
                    OR (? = 1 AND state='pending')
                """,
                (
                    "recovery_pending" if hold_recovered_delivery else "pending",
                    time.time(),
                    int(hold_recovered_delivery),
                ),
            )
            if self.provider_turn_events_enabled:
                record_intent_events(
                    self._connection,
                    (str(row["intent_id"]) for row in recovered),
                    event_type="inbox_recovered",
                    event_scope=f"startup:{time.time_ns()}",
                    occurred_at=time.time(),
                )
        self._project_provider_turns()

    def _project_provider_turns(self) -> None:
        if not self.provider_turn_projection_path:
            return
        broker = ProviderTurnBroker(
            self.path,
            projection_path=self.provider_turn_projection_path,
        )
        try:
            broker.project()
        finally:
            broker.close()

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
        recovery_generation = normalize_recovery_generation(
            stored.get("recovery_generation") or "0"
        )
        work_item = stored.get("voice_work_item")
        if not isinstance(work_item, dict):
            work_item = {}
        try:
            within_turn_order = max(
                1,
                int(stored.get("within_turn_order") or work_item.get("within_turn_order") or 1),
            )
        except (TypeError, ValueError):
            within_turn_order = 1
        stored["within_turn_order"] = within_turn_order
        lifecycle_state = str(
            stored.get("lifecycle_state") or work_item.get("lifecycle_state") or "recognized"
        )
        initial_state = "cancelled" if lifecycle_state in {"cancelled", "abandoned"} else "pending"
        now = time.time()
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT OR IGNORE INTO intents(
                    intent_id, command_seq, command_id, within_turn_order, prompt, metadata_json,
                    route, state, delivery_id, claim_id, ack_id, created_at,
                    recovery_generation
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    intent_id,
                    key[0],
                    key[1],
                    within_turn_order,
                    prompt,
                    json.dumps(stored, sort_keys=True),
                    route,
                    initial_state,
                    delivery_id,
                    claim_id,
                    ack_id,
                    now,
                    recovery_generation,
                ),
            )
        return stored

    def resume_after_recovery(
        self,
        *,
        intent_id: str,
        recovery_generation: str,
        now: float | None = None,
    ) -> bool:
        """Release only an exact unclaimed intent once for its original generation."""
        try:
            generation = normalize_recovery_generation(recovery_generation)
        except ValueError:
            return False
        now = time.time() if now is None else now
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT state, recovery_generation, recovery_decision "
                "FROM intents WHERE intent_id=?",
                (intent_id,),
            ).fetchone()
            if row is None or str(row["recovery_generation"]) != generation:
                return False
            if str(row["recovery_decision"] or "") == f"resumed:{generation}":
                return False
            if str(row["state"]) not in {"pending", "delivered", "recovery_pending"}:
                return False
            self._connection.execute(
                "UPDATE intents SET state='pending', recovered_at=?, recovery_decision=? "
                "WHERE intent_id=? AND state IN ('pending', 'delivered', 'recovery_pending')",
                (now, f"resumed:{generation}", intent_id),
            )
        return True

    def cancel_pending_before(self, command_seq: int, *, reason: str) -> int:
        del reason  # The route is diagnostic; private transcript text is never logged here.
        now = time.time()
        with self._lock, self._connection:
            rows = self._connection.execute(
                """
                SELECT intent_id FROM intents
                 WHERE command_seq < ?
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending')
                """,
                (int(command_seq),),
            ).fetchall()
            cursor = self._connection.execute(
                """
                UPDATE intents
                   SET state='cancelled', cancelled_at=?
                 WHERE command_seq < ?
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending')
                """,
                (now, int(command_seq)),
            )
            if self.provider_turn_events_enabled:
                record_intent_events(
                    self._connection,
                    (str(row["intent_id"]) for row in rows),
                    event_type="intent_cancelled",
                    event_scope=f"before:{int(command_seq)}",
                    occurred_at=now,
                    terminal_state="cancelled",
                    release_reason="intent_cancelled_before_newer_command",
                )
            cancelled = int(cursor.rowcount)
        self._project_provider_turns()
        return cancelled

    @staticmethod
    def _cancellation_fields(metadata: dict[str, Any]) -> tuple[str, list[str], str | None]:
        item = metadata.get("voice_work_item")
        if not isinstance(item, dict):
            item = {}
        disposition = metadata.get("work_disposition")
        if not isinstance(disposition, dict):
            disposition = {}
        scope = str(
            metadata.get("cancellation_scope")
            or item.get("cancellation_scope")
            or disposition.get("cancellation_scope")
            or "none"
        )
        target_ids = metadata.get("target_intent_ids") or item.get("target_intent_ids") or []
        if not isinstance(target_ids, list):
            target_ids = []
        target = metadata.get("target") or item.get("target") or metadata.get("ticket_id")
        return scope, [str(value) for value in target_ids if str(value)], str(target) if target else None

    @staticmethod
    def _row_matches_target(row: sqlite3.Row, target: str | None) -> bool:
        if not target:
            return False
        target_text = target.strip().lower()
        if not target_text:
            return False
        try:
            metadata = json.loads(row["metadata_json"])
        except (json.JSONDecodeError, TypeError):
            return False
        item = metadata.get("voice_work_item")
        if not isinstance(item, dict):
            item = {}
        candidates = {
            str(metadata.get("ticket_id") or "").strip().lower(),
            str(metadata.get("target") or "").strip().lower(),
            str(item.get("target") or "").strip().lower(),
        }
        if target_text in candidates:
            return True
        source = str(item.get("source_text") or metadata.get("source_text") or "").lower()
        return target_text in source

    def cancel_scoped(
        self,
        metadata: dict[str, Any],
        *,
        command_path: str | None = None,
        metadata_path: str | None = None,
    ) -> list[str]:
        """Cancel only the resolved item/ticket and release its ready-file lease."""
        scope, target_ids, target = self._cancellation_fields(metadata)
        if scope not in {"item", "ticket", "all_work"}:
            return []
        with self._lock, self._connection:
            rows = self._connection.execute(
                """
                SELECT * FROM intents
                 WHERE state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending', 'acked')
                 ORDER BY command_seq DESC, within_turn_order DESC, ordinal DESC
                """
            ).fetchall()
            if scope == "all_work":
                matched = list(rows)
            elif target_ids:
                wanted = set(target_ids)
                matched = [row for row in rows if str(row["intent_id"]) in wanted]
            else:
                matched = [row for row in rows if self._row_matches_target(row, target)]
                if scope == "item":
                    matched = matched[:1]
            if not matched:
                return []
            matched_ids = [str(row["intent_id"]) for row in matched]
            placeholders = ",".join("?" for _ in matched_ids)
            self._connection.execute(
                f"UPDATE intents SET state='cancelled', cancelled_at=? "
                f"WHERE intent_id IN ({placeholders})",
                (time.time(), *matched_ids),
            )
            if self.provider_turn_events_enabled:
                record_intent_events(
                    self._connection,
                    matched_ids,
                    event_type="intent_cancelled",
                    event_scope=str(metadata.get("intent_id") or metadata.get("relay_command_id") or "scoped"),
                    occurred_at=time.time(),
                    terminal_state="cancelled",
                    release_reason=f"intent_{scope}_cancelled",
                )

        if command_path and metadata_path and os.path.exists(metadata_path):
            leased = {}
            try:
                leased = json.loads(Path(metadata_path).read_text())
            except (OSError, json.JSONDecodeError, TypeError):
                pass
            if str(leased.get("intent_id") or "") in set(matched_ids):
                for path in (command_path, metadata_path):
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
        self._project_provider_turns()
        return matched_ids

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
        materialized: dict[str, Any] | None = None
        with self._lock, self._connection:
            unacked = self._connection.execute(
                """
                SELECT ordinal
                  FROM intents
                 WHERE route != 'run_sidecar'
                   AND state IN ('delivered', 'claimed', 'review_required')
                 ORDER BY command_seq, within_turn_order, ordinal
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
                 ORDER BY command_seq, within_turn_order, ordinal
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
            projection_changed = self.provider_turn_events_enabled and bool(record_intent_events(
                    self._connection,
                    [str(row["intent_id"])],
                    event_type="intent_delivered",
                    event_scope=str(row["delivery_id"]),
                    occurred_at=time.time(),
                ))
            materialized = metadata
        if projection_changed:
            self._project_provider_turns()
        return materialized

    def observe_claim(
        self,
        claimed: dict[str, Any],
        *,
        provider_turn_seen: bool,
        now: float | None = None,
    ) -> bool:
        key = _key(claimed)
        if key is None:
            return False
        intent_id = str(claimed.get("intent_id") or "").strip()
        now = time.time() if now is None else now
        observed = False
        projection_changed = False
        with self._lock, self._connection:
            if intent_id:
                row = self._connection.execute(
                    "SELECT state, claim_id, ack_id, intent_id FROM intents WHERE intent_id=?",
                    (intent_id,),
                ).fetchone()
            else:
                row = self._connection.execute(
                    "SELECT state, claim_id, ack_id, intent_id FROM intents "
                    "WHERE command_seq=? AND command_id=? "
                    "ORDER BY within_turn_order, ordinal LIMIT 1",
                    key,
                ).fetchone()
            if row is None:
                return False
            state = str(row["state"])
            resolved_intent_id = str(row["intent_id"])
            claim_id = str(claimed.get("intent_claim_id") or row["claim_id"] or f"claim:{key[0]}:{key[1]}")
            ack_id = str(claimed.get("intent_ack_id") or row["ack_id"] or f"ack:{key[0]}:{key[1]}")
            if state in {"delivered", "pending"}:
                self._connection.execute(
                    """
                    UPDATE intents
                       SET state='claimed', claim_id=?, ack_id=?, claimed_at=?
                     WHERE intent_id=?
                    """,
                    (claim_id, ack_id, now, resolved_intent_id),
                )
                if self.provider_turn_events_enabled:
                    projection_changed = bool(record_intent_events(
                        self._connection,
                        [resolved_intent_id],
                        event_type="intent_claimed",
                        event_scope=claim_id,
                        occurred_at=now,
                    )) or projection_changed
                state = "claimed"
            if provider_turn_seen and state == "claimed":
                self._connection.execute(
                    """
                    UPDATE intents SET state='acked', ack_id=?, acked_at=?
                     WHERE intent_id=?
                    """,
                    (ack_id, now, resolved_intent_id),
                )
                if self.provider_turn_events_enabled:
                    projection_changed = bool(record_intent_events(
                        self._connection,
                        [resolved_intent_id],
                        event_type="intent_acknowledged",
                        event_scope=ack_id,
                        occurred_at=now,
                    )) or projection_changed
            observed = True
        if projection_changed:
            self._project_provider_turns()
        return observed

    def pending_for_route(self, route: str) -> list[dict[str, Any]]:
        """Return durable work owned by a non-mailbox execution lane."""
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT prompt, metadata_json
                  FROM intents
                 WHERE state='pending' AND route=?
                 ORDER BY command_seq, within_turn_order, ordinal
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
        return self.state_snapshot()[1]

    def source_command_intents(self, command: dict[str, Any] | None) -> list[dict[str, Any]]:
        """Return privacy-safe lifecycle state for every sibling in one source turn."""
        key = _key(command)
        if key is None:
            return []
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT command_seq, command_id, within_turn_order, intent_id, route, state
                  FROM intents
                 WHERE command_seq=? AND command_id=?
                 ORDER BY within_turn_order, ordinal
                """,
                key,
            ).fetchall()
        return [
            {
                "relay_command_seq": int(row["command_seq"]),
                "relay_command_id": str(row["command_id"]),
                "within_turn_order": int(row["within_turn_order"]),
                "intent_id": str(row["intent_id"]),
                "route": str(row["route"]),
                "state": str(row["state"]),
            }
            for row in rows
        ]

    def state_snapshot(self) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        """Return the latest durable command and deliverable queue from one snapshot."""
        with self._lock:
            latest = self._connection.execute(
                """
                SELECT metadata_json
                  FROM intents
                 ORDER BY command_seq DESC, within_turn_order DESC, ordinal DESC
                 LIMIT 1
                """
            ).fetchone()
            rows = self._connection.execute(
                """
                SELECT command_seq, command_id, within_turn_order, intent_id, route, state
                  FROM intents
                 WHERE state IN ('pending', 'delivered', 'claimed')
                 ORDER BY command_seq, within_turn_order, ordinal
                """
            ).fetchall()
        latest_command = json.loads(latest["metadata_json"]) if latest is not None else None
        deliverable = [
            {
                "relay_command_seq": int(row["command_seq"]),
                "relay_command_id": str(row["command_id"]),
                "within_turn_order": int(row["within_turn_order"]),
                "intent_id": str(row["intent_id"]),
                "route": str(row["route"]),
                "state": str(row["state"]),
            }
            for row in rows
        ]
        return latest_command, deliverable

    def records(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM intents ORDER BY command_seq, within_turn_order, ordinal"
            ).fetchall()
        return [dict(row) for row in rows]

    def cancelled_intent_ids(self) -> list[str]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT intent_id FROM intents WHERE state='cancelled' "
                "ORDER BY command_seq, within_turn_order, ordinal"
            ).fetchall()
        return [str(row["intent_id"]) for row in rows]


def sync_deliverable_state(state_path: str, inbox: IntentInbox) -> None:
    latest_command, deliverable = inbox.state_snapshot()
    try:
        payload = json.loads(Path(state_path).read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    current_key = _key(payload)
    latest_key = _key(latest_command)
    if latest_key is not None:
        if current_key is None or current_key[0] < latest_key[0]:
            payload.update(latest_command or {})
        elif current_key == latest_key:
            payload = {**(latest_command or {}), **payload}
    payload["intent_inbox_version"] = SCHEMA_VERSION
    payload["deliverable_commands"] = deliverable
    payload["cancelled_intent_ids"] = inbox.cancelled_intent_ids()
    payload["source_command_intents"] = inbox.source_command_intents(payload)
    tmp = state_path + ".tmp"
    Path(tmp).write_text(json.dumps(payload, sort_keys=True))
    os.replace(tmp, state_path)
