"""Transactional provider-turn lifecycle broker and Swift projection.

The broker shares Relay's durable intent-inbox database.  JSON files are
projections or migration compatibility surfaces; they are never mutated to
decide a lifecycle transition.
"""

from __future__ import annotations

from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from typing import Any, Iterable


SCHEMA_VERSION = 2
PROJECTION_VERSION = 2
OWNERSHIP_FIELDS = (
    "app_session_id",
    "recovery_generation",
    "actor_role",
    "foreground_gate_handle",
)
FOREGROUND_ACTOR_ROLES = frozenset({"foreground_pm", "foreground_manual"})
TERMINAL_STATES = frozenset({
    "cancelled",
    "completed_final",
    "completed_manual",
    "empty",
    "failed",
    "failed_manual",
    "legacy_observation",
    "orphaned",
    "stale",
    "terminated",
})
ALLOWED_TRANSITIONS = {
    "active": TERMINAL_STATES,
}
EFFECT_REVOKED_TURN_STATES = frozenset({"cancelled", "orphaned", "stale", "terminated"})


def _text(value: Any) -> str:
    return str(value or "").strip()


def _integer(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def stable_event_id(kind: str, *parts: Any) -> str:
    material = json.dumps([kind, *parts], sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    return f"{kind}:{digest}"


def _ownership(record: dict[str, Any]) -> dict[str, str] | None:
    values = {field: _text(record.get(field)) for field in OWNERSHIP_FIELDS}
    if values["actor_role"] not in FOREGROUND_ACTOR_ROLES:
        return None
    return values if all(values.values()) else None


def _owner_id(record: dict[str, Any]) -> str | None:
    ownership = _ownership(record)
    if ownership is None:
        return None
    return stable_event_id("owner", *(ownership[field] for field in OWNERSHIP_FIELDS))


def _turn_id(record: dict[str, Any]) -> str | None:
    owner_id = _owner_id(record)
    native_session_id = _text(record.get("session_id"))
    native_turn_id = _text(record.get("turn_id"))
    local_turn_seq = _integer(record.get("local_turn_seq"))
    if owner_id is None or not native_session_id:
        return None
    physical_turn = native_turn_id or (
        f"local:{local_turn_seq}" if local_turn_seq is not None else "session"
    )
    return stable_event_id(
        "turn",
        owner_id,
        _text(record.get("provider_session_id")),
        native_session_id,
        physical_turn,
    )


def ensure_broker_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS provider_turn_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS provider_turn_owners (
            owner_id TEXT PRIMARY KEY,
            app_session_id TEXT NOT NULL,
            recovery_generation TEXT NOT NULL,
            actor_role TEXT NOT NULL,
            foreground_gate_handle TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(app_session_id, recovery_generation, actor_role, foreground_gate_handle)
        );
        CREATE TABLE IF NOT EXISTS provider_turns (
            turn_id TEXT PRIMARY KEY,
            owner_id TEXT NOT NULL REFERENCES provider_turn_owners(owner_id),
            app_session_id TEXT NOT NULL,
            recovery_generation TEXT NOT NULL,
            actor_role TEXT NOT NULL,
            foreground_gate_handle TEXT NOT NULL,
            provider TEXT,
            provider_session_id TEXT,
            native_session_id TEXT NOT NULL,
            native_turn_id TEXT,
            local_turn_seq INTEGER,
            origin TEXT NOT NULL,
            intent_id TEXT,
            command_seq INTEGER,
            command_id TEXT,
            state TEXT NOT NULL,
            release_reason TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS provider_turns_owner_state
            ON provider_turns(owner_id, state, updated_at);
        CREATE INDEX IF NOT EXISTS provider_turns_intent
            ON provider_turns(intent_id, updated_at);
        CREATE INDEX IF NOT EXISTS provider_turns_command
            ON provider_turns(command_seq, command_id, updated_at);
        CREATE TABLE IF NOT EXISTS provider_turn_transitions (
            transition_ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
            event_type TEXT NOT NULL,
            from_state TEXT,
            to_state TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            release_reason TEXT
        );
        CREATE TABLE IF NOT EXISTS provider_turn_effects (
            effect_id TEXT PRIMARY KEY,
            authority_key TEXT NOT NULL UNIQUE,
            turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
            intent_id TEXT,
            effect_kind TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
    )
    connection.execute(
        "INSERT OR REPLACE INTO provider_turn_meta(key, value) VALUES('schema_version', ?)",
        (str(SCHEMA_VERSION),),
    )


def record_intent_events(
    connection: sqlite3.Connection,
    intent_ids: Iterable[str],
    *,
    event_type: str,
    event_scope: str,
    occurred_at: float,
    terminal_state: str | None = None,
    release_reason: str | None = None,
) -> int:
    """Record inbox lifecycle events in the caller's existing transaction."""
    changed = 0
    for intent_id in sorted({_text(value) for value in intent_ids if _text(value)}):
        rows = connection.execute(
            "SELECT turn_id, state FROM provider_turns WHERE intent_id=? ORDER BY updated_at",
            (intent_id,),
        ).fetchall()
        for row in rows:
            turn_id = str(row["turn_id"])
            current_state = str(row["state"])
            next_state = terminal_state or current_state
            if terminal_state is not None:
                allowed = ALLOWED_TRANSITIONS.get(current_state, frozenset())
                if terminal_state not in allowed:
                    continue
            event_id = stable_event_id(event_type, event_scope, turn_id)
            cursor = connection.execute(
                """
                INSERT OR IGNORE INTO provider_turn_transitions(
                    event_id, turn_id, event_type, from_state, to_state,
                    occurred_at, release_reason
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event_id,
                    turn_id,
                    event_type,
                    current_state,
                    next_state,
                    occurred_at,
                    release_reason,
                ),
            )
            if cursor.rowcount != 1:
                continue
            if terminal_state is not None:
                connection.execute(
                    "UPDATE provider_turns SET state=?, release_reason=?, updated_at=? WHERE turn_id=?",
                    (terminal_state, release_reason, occurred_at, turn_id),
                )
            changed += 1
    return changed


@dataclass(frozen=True)
class EffectReservation:
    accepted: bool
    effect_id: str | None = None
    reason: str = ""


class ProviderTurnBroker:
    """SQLite authority for provider turns, ownership, transitions, and effects."""

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        projection_path: str | os.PathLike[str] | None = None,
    ):
        self.path = str(path)
        self.projection_path = str(projection_path) if projection_path is not None else None
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False, timeout=5.0)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA busy_timeout=5000")
        with self._connection:
            self._connection.execute("PRAGMA journal_mode=WAL")
            ensure_broker_schema(self._connection)

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _begin(self) -> None:
        self._connection.execute("BEGIN IMMEDIATE")

    def _finish(self, *, commit: bool) -> None:
        self._connection.commit() if commit else self._connection.rollback()

    def _insert_owner(self, record: dict[str, Any], *, now: float) -> str:
        ownership = _ownership(record)
        owner_id = _owner_id(record)
        if ownership is None or owner_id is None:
            raise ValueError("provider turn requires a complete foreground ownership envelope")
        self._connection.execute(
            """
            INSERT OR IGNORE INTO provider_turn_owners(
                owner_id, app_session_id, recovery_generation, actor_role,
                foreground_gate_handle, created_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            """,
            (
                owner_id,
                ownership["app_session_id"],
                ownership["recovery_generation"],
                ownership["actor_role"],
                ownership["foreground_gate_handle"],
                now,
            ),
        )
        return owner_id

    def activate(
        self,
        record: dict[str, Any],
        *,
        now: float | None = None,
        release_reason: str = "superseded_by_prompt_submit",
    ) -> bool:
        now = time.time() if now is None else now
        turn_id = _turn_id(record)
        if turn_id is None:
            raise ValueError("provider turn requires stable foreground and native identity")
        with self._lock:
            self._begin()
            try:
                owner_id = self._insert_owner(record, now=now)
                existing = self._connection.execute(
                    "SELECT state FROM provider_turns WHERE turn_id=?",
                    (turn_id,),
                ).fetchone()
                if existing is not None:
                    self._finish(commit=True)
                    return False

                active = self._connection.execute(
                    """
                    SELECT turn_id, state FROM provider_turns
                     WHERE owner_id=? AND state='active'
                       AND COALESCE(provider_session_id, '')=?
                    """,
                    (owner_id, _text(record.get("provider_session_id"))),
                ).fetchall()
                for previous in active:
                    previous_id = str(previous["turn_id"])
                    event_id = stable_event_id("supersede", previous_id, turn_id)
                    self._connection.execute(
                        """
                        INSERT OR IGNORE INTO provider_turn_transitions(
                            event_id, turn_id, event_type, from_state, to_state,
                            occurred_at, release_reason
                        ) VALUES(?, ?, 'superseded', 'active', 'orphaned', ?, ?)
                        """,
                        (event_id, previous_id, now, release_reason),
                    )
                    self._connection.execute(
                        """
                        UPDATE provider_turns
                           SET state='orphaned', release_reason=?, updated_at=?
                         WHERE turn_id=? AND state='active'
                        """,
                        (release_reason, now, previous_id),
                    )

                ownership = _ownership(record)
                assert ownership is not None
                self._connection.execute(
                    """
                    INSERT INTO provider_turns(
                        turn_id, owner_id, app_session_id, recovery_generation, actor_role,
                        foreground_gate_handle, provider, provider_session_id,
                        native_session_id, native_turn_id, local_turn_seq, origin,
                        intent_id, command_seq, command_id, state, release_reason,
                        created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', NULL, ?, ?)
                    """,
                    (
                        turn_id,
                        owner_id,
                        ownership["app_session_id"],
                        ownership["recovery_generation"],
                        ownership["actor_role"],
                        ownership["foreground_gate_handle"],
                        _text(record.get("provider")) or None,
                        _text(record.get("provider_session_id")) or None,
                        _text(record.get("session_id")),
                        _text(record.get("turn_id")) or None,
                        _integer(record.get("local_turn_seq")),
                        _text(record.get("origin")) or "relay",
                        _text(record.get("intent_id")) or None,
                        _integer(record.get("relay_command_seq")),
                        _text(record.get("relay_command_id")) or None,
                        float(record.get("created_at") or now),
                        now,
                    ),
                )
                self._connection.execute(
                    """
                    INSERT INTO provider_turn_transitions(
                        event_id, turn_id, event_type, from_state, to_state,
                        occurred_at, release_reason
                    ) VALUES(?, ?, 'prompt_submitted', NULL, 'active', ?, NULL)
                    """,
                    (stable_event_id("activate", turn_id), turn_id, now),
                )
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise
        self.project()
        return True

    def transition(
        self,
        record: dict[str, Any],
        *,
        to_state: str,
        event_type: str,
        release_reason: str,
        now: float | None = None,
    ) -> bool:
        now = time.time() if now is None else now
        turn_id = _turn_id(record)
        if turn_id is None:
            return False
        with self._lock:
            self._begin()
            try:
                row = self._connection.execute(
                    "SELECT state FROM provider_turns WHERE turn_id=?",
                    (turn_id,),
                ).fetchone()
                if row is None:
                    self._finish(commit=True)
                    return False
                current = str(row["state"])
                if to_state not in ALLOWED_TRANSITIONS.get(current, frozenset()):
                    self._finish(commit=True)
                    return False
                event_id = stable_event_id(event_type, turn_id, to_state, release_reason)
                cursor = self._connection.execute(
                    """
                    INSERT OR IGNORE INTO provider_turn_transitions(
                        event_id, turn_id, event_type, from_state, to_state,
                        occurred_at, release_reason
                    ) VALUES(?, ?, ?, ?, ?, ?, ?)
                    """,
                    (event_id, turn_id, event_type, current, to_state, now, release_reason),
                )
                if cursor.rowcount != 1:
                    self._finish(commit=True)
                    return False
                self._connection.execute(
                    "UPDATE provider_turns SET state=?, release_reason=?, updated_at=? WHERE turn_id=?",
                    (to_state, release_reason, now, turn_id),
                )
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise
        self.project()
        return True

    def state_for(self, record: dict[str, Any]) -> str | None:
        turn_id = _turn_id(record)
        if turn_id is None:
            return None
        with self._lock:
            row = self._connection.execute(
                "SELECT state FROM provider_turns WHERE turn_id=?",
                (turn_id,),
            ).fetchone()
        return str(row["state"]) if row is not None else None

    def terminate_owner(
        self,
        ownership: dict[str, Any],
        *,
        provider_session_id: str,
        release_reason: str,
        event_id: str,
        now: float | None = None,
    ) -> int:
        now = time.time() if now is None else now
        owner_id = _owner_id(ownership)
        if owner_id is None or not provider_session_id or not event_id:
            return 0
        changed = 0
        with self._lock:
            self._begin()
            try:
                rows = self._connection.execute(
                    """
                    SELECT turn_id FROM provider_turns
                     WHERE owner_id=? AND provider_session_id=? AND state='active'
                    """,
                    (owner_id, provider_session_id),
                ).fetchall()
                for row in rows:
                    turn_id = str(row["turn_id"])
                    cursor = self._connection.execute(
                        """
                        INSERT OR IGNORE INTO provider_turn_transitions(
                            event_id, turn_id, event_type, from_state, to_state,
                            occurred_at, release_reason
                        ) VALUES(?, ?, 'provider_terminated', 'active', 'terminated', ?, ?)
                        """,
                        (stable_event_id(event_id, turn_id), turn_id, now, release_reason),
                    )
                    if cursor.rowcount != 1:
                        continue
                    self._connection.execute(
                        """
                        UPDATE provider_turns
                           SET state='terminated', release_reason=?, updated_at=?
                         WHERE turn_id=? AND state='active'
                        """,
                        (release_reason, now, turn_id),
                    )
                    changed += 1
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise
        if changed:
            self.project()
        return changed

    def reserve_effect(
        self,
        command: dict[str, Any],
        *,
        effect_kind: str = "authoritative_reply",
        now: float | None = None,
    ) -> EffectReservation:
        now = time.time() if now is None else now
        owner_id = _owner_id(command)
        intent_id = _text(command.get("intent_id"))
        command_seq = _integer(command.get("relay_command_seq"))
        command_id = _text(command.get("relay_command_id"))
        if owner_id is None or (not intent_id and (command_seq is None or not command_id)):
            return EffectReservation(False, reason="ownership_or_command_missing")
        with self._lock:
            self._begin()
            try:
                if intent_id:
                    row = self._connection.execute(
                        """
                        SELECT turn_id, state FROM provider_turns
                         WHERE owner_id=? AND intent_id=?
                         ORDER BY updated_at DESC LIMIT 1
                        """,
                        (owner_id, intent_id),
                    ).fetchone()
                    authority_identity = intent_id
                else:
                    row = self._connection.execute(
                        """
                        SELECT turn_id, state FROM provider_turns
                         WHERE owner_id=? AND command_seq=? AND command_id=?
                         ORDER BY updated_at DESC LIMIT 1
                        """,
                        (owner_id, command_seq, command_id),
                    ).fetchone()
                    authority_identity = f"{command_seq}:{command_id}"
                if row is None:
                    self._finish(commit=True)
                    return EffectReservation(False, reason="turn_missing")
                if str(row["state"]) in EFFECT_REVOKED_TURN_STATES:
                    self._finish(commit=True)
                    return EffectReservation(False, reason="turn_revoked")
                if intent_id and self._intent_cancelled(intent_id):
                    self._finish(commit=True)
                    return EffectReservation(False, reason="turn_revoked")
                turn_id = str(row["turn_id"])
                authority_key = stable_event_id(
                    "authority",
                    owner_id,
                    authority_identity,
                    effect_kind,
                )
                effect_id = stable_event_id("effect", authority_key)
                cursor = self._connection.execute(
                    """
                    INSERT OR IGNORE INTO provider_turn_effects(
                        effect_id, authority_key, turn_id, intent_id, effect_kind,
                        state, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, 'reserved', ?, ?)
                    """,
                    (effect_id, authority_key, turn_id, intent_id or None, effect_kind, now, now),
                )
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise
        if cursor.rowcount != 1:
            return EffectReservation(False, effect_id=effect_id, reason="duplicate")
        return EffectReservation(True, effect_id=effect_id)

    def _intent_cancelled(self, intent_id: str) -> bool:
        table = self._connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='intents'"
        ).fetchone()
        if table is None:
            return False
        row = self._connection.execute(
            "SELECT state FROM intents WHERE intent_id=?",
            (intent_id,),
        ).fetchone()
        return row is not None and str(row["state"]) == "cancelled"

    def authorize_effect_delivery(
        self,
        effect_id: str,
        *,
        now: float | None = None,
    ) -> bool:
        """Linearize revocation against the first external delivery attempt."""
        now = time.time() if now is None else now
        with self._lock:
            self._begin()
            try:
                row = self._connection.execute(
                    """
                    SELECT effects.state AS effect_state,
                           effects.intent_id AS intent_id,
                           turns.state AS turn_state
                      FROM provider_turn_effects AS effects
                      JOIN provider_turns AS turns ON turns.turn_id=effects.turn_id
                     WHERE effects.effect_id=?
                    """,
                    (effect_id,),
                ).fetchone()
                if row is None or str(row["effect_state"]) != "reserved":
                    self._finish(commit=True)
                    return False
                intent_id = _text(row["intent_id"])
                revoked = (
                    str(row["turn_state"]) in EFFECT_REVOKED_TURN_STATES
                    or bool(intent_id and self._intent_cancelled(intent_id))
                )
                self._connection.execute(
                    "UPDATE provider_turn_effects SET state=?, updated_at=? WHERE effect_id=?",
                    ("failed" if revoked else "authorized", now, effect_id),
                )
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise
        return not revoked

    def finish_effect(self, effect_id: str, *, delivered: bool, now: float | None = None) -> None:
        now = time.time() if now is None else now
        with self._lock:
            self._begin()
            try:
                row = self._connection.execute(
                    """
                    SELECT state AS effect_state
                      FROM provider_turn_effects
                     WHERE effect_id=?
                    """,
                    (effect_id,),
                ).fetchone()
                if row is None or str(row["effect_state"]) not in {"reserved", "authorized"}:
                    self._finish(commit=True)
                    return
                authorized = str(row["effect_state"]) == "authorized"
                self._connection.execute(
                    "UPDATE provider_turn_effects SET state=?, updated_at=? WHERE effect_id=?",
                    ("delivered" if delivered and authorized else "failed", now, effect_id),
                )
                self._finish(commit=True)
            except Exception:
                self._finish(commit=False)
                raise

    def project(self) -> None:
        if not self.projection_path:
            return
        projection = Path(self.projection_path)
        projection.parent.mkdir(parents=True, exist_ok=True)
        lock_path = str(projection) + ".lock"
        with open(lock_path, "a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            with self._lock:
                rows = self._connection.execute(
                    """
                    SELECT * FROM provider_turns
                     ORDER BY app_session_id, recovery_generation, created_at, turn_id
                    """
                ).fetchall()
            records: list[dict[str, Any]] = []
            mappings = {
                "native_session_id": "session_id",
                "native_turn_id": "turn_id",
                "command_seq": "relay_command_seq",
                "command_id": "relay_command_id",
            }
            for row in rows:
                record: dict[str, Any] = {}
                for key in (
                    "app_session_id",
                    "recovery_generation",
                    "actor_role",
                    "foreground_gate_handle",
                    "provider",
                    "provider_session_id",
                    "local_turn_seq",
                    "origin",
                    "intent_id",
                    "state",
                    "release_reason",
                    "created_at",
                    "updated_at",
                ):
                    if row[key] is not None:
                        record[key] = row[key]
                for source, destination in mappings.items():
                    if row[source] is not None:
                        record[destination] = row[source]
                records.append(record)
            payload = {
                "schema_version": PROJECTION_VERSION,
                "updated_at": time.time(),
                "records": records,
            }
            tmp = projection.with_name(f"{projection.name}.{os.getpid()}.tmp")
            tmp.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
            os.chmod(tmp, 0o600)
            os.replace(tmp, projection)

    def table_records(self, table: str) -> list[dict[str, Any]]:
        if table not in {
            "provider_turn_owners",
            "provider_turns",
            "provider_turn_transitions",
            "provider_turn_effects",
        }:
            raise ValueError("unsupported provider-turn table")
        with self._lock:
            rows = self._connection.execute(f"SELECT * FROM {table}").fetchall()
        return [dict(row) for row in rows]
