"""RR-489: one interface to the Python and Rust intent inbox, turn broker and
intent model, so the same scenarios run against both on one database.

``PythonIntents`` calls services/intent_inbox.py, provider_turn_broker.py,
intent_arbitration.py and intent_qualification.py in-process.
``RustIntents`` drives the relay-intents crate through its test driver
(rust/relay-intents/examples/intents_driver.rs), one JSON line per call.
Both take ``call("<object>.<method>", **arguments)``, return JSON-shaped
results and raise ``Refused`` with the Python exception class name where the
implementation refuses.

The driver is ``RELAY_INTENTS_DRIVER`` when set, otherwise the debug build that
``cargo test`` leaves in rust/target/debug/examples. Without either, Rust cases
skip.
"""

from __future__ import annotations

import json
import os
import shlex
import sqlite3
import subprocess
import sys
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "services"))

from intent_arbitration import (  # noqa: E402
    ActiveWork,
    authorization_relationship_for,
    explicit_cancel_requested,
    explicit_replace_requested,
    inferred_resource_claims,
    normalize_voice_work_items,
    resolve_intent_disposition,
    sidecar_eligible,
)
from intent_inbox import IntentInbox, sync_deliverable_state  # noqa: E402
from intent_qualification import (  # noqa: E402
    context_dependent_assent,
    discussion_only_requested,
    dispatch_forbidden,
    foreground_action_requested,
    format_qualification_for_agent,
    mixed_bucket_request,
    qualify_intent,
    whole_turn_resolution_required,
)
from provider_turn_broker import ProviderTurnBroker  # noqa: E402

DEFAULT_DRIVER = REPO / "rust" / "target" / "debug" / "examples" / "intents_driver"

# Columns that hold a wall-clock time; their values differ between runs.
TIME_COLUMNS = frozenset({
    "created_at", "delivered_at", "claimed_at", "acked_at", "cancelled_at",
    "recovered_at", "updated_at", "occurred_at",
})
BROKER_TABLES = (
    "provider_turn_owners",
    "provider_turns",
    "provider_turn_transitions",
    "provider_turn_effects",
)


class Refused(Exception):
    """The implementation refused the call, as Python would raise ``error``."""

    def __init__(self, error: str):
        super().__init__(error)
        self.error = error


def driver_command() -> list | None:
    configured = os.environ.get("RELAY_INTENTS_DRIVER", "").strip()
    if configured:
        return shlex.split(configured)
    if os.access(DEFAULT_DRIVER, os.X_OK):
        return [str(DEFAULT_DRIVER)]
    return None


def _jsonable(value):
    return json.loads(json.dumps(value))


def _error_name(exc: BaseException) -> str:
    if isinstance(exc, ValueError):
        return "ValueError"
    if isinstance(exc, sqlite3.Error):
        return type(exc).__name__
    if isinstance(exc, OSError):
        return type(exc).__name__ if type(exc) in {FileNotFoundError, PermissionError} else "OSError"
    return type(exc).__name__


def _session_key(metadata) -> str:
    if not isinstance(metadata, dict):
        return ""
    return str(metadata.get("voice_target_session_key") or "").strip()


class PythonIntents:
    """The Python modules, called in-process."""

    name = "python"

    def __init__(self):
        self.inbox: IntentInbox | None = None
        self.broker: ProviderTurnBroker | None = None

    def call(self, op: str, **arguments):
        try:
            return _jsonable(self._call(op, arguments))
        except Refused:
            raise
        except Exception as exc:  # noqa: BLE001 - every refusal is compared by class
            raise Refused(_error_name(exc)) from exc

    def close(self) -> None:
        for target in (self.inbox, self.broker):
            if target is not None:
                target.close()
        self.inbox = self.broker = None

    def _call(self, op: str, a: dict):
        group, _, method = op.partition(".")
        if group == "inbox":
            return self._inbox(method, a)
        if group == "broker":
            return self._broker(method, a)
        if group == "model":
            return self._model(method, a)
        raise KeyError(op)

    def _inbox(self, method: str, a: dict):
        if method == "open":
            if self.inbox is not None:
                self.inbox.close()
                self.inbox = None
            self.inbox = IntentInbox(
                a["path"],
                provider_turn_projection_path=a.get("projection_path"),
                hold_recovered_delivery=bool(a.get("hold_recovered_delivery")),
            )
            return None
        if method == "close":
            if self.inbox is not None:
                self.inbox.close()
            self.inbox = None
            return None
        inbox = self.inbox
        if method == "enqueue":
            return inbox.enqueue(a["prompt"], a["metadata"], a["route"])
        if method == "retire_stale_foreground":
            return inbox.retire_stale_foreground(
                a["recovery_generation"],
                command_path=a["command_path"],
                metadata_path=a["metadata_path"],
                before_command_seq=a.get("before_command_seq"),
                session_key=a.get("session_key"),
            )
        if method == "retire_ended_sessions":
            live = set(a.get("live") or [])
            return inbox.retire_ended_sessions(lambda key: key in live)
        if method == "resume_after_recovery":
            return inbox.resume_after_recovery(
                intent_id=a["intent_id"],
                recovery_generation=a["recovery_generation"],
                now=a.get("now"),
            )
        if method == "cancel_pending_before":
            return inbox.cancel_pending_before(a["command_seq"], reason="contract")
        if method == "cancel_scoped":
            return inbox.cancel_scoped(
                a["metadata"],
                command_path=a.get("command_path"),
                metadata_path=a.get("metadata_path"),
            )
        if method == "materialize_next":
            routes = a.get("routes")
            paths_for = None
            if routes is not None:
                def paths_for(metadata):
                    paths = routes.get(_session_key(metadata))
                    return tuple(paths) if paths else None
            return inbox.materialize_next(
                command_path=a["command_path"],
                metadata_path=a["metadata_path"],
                transport=a["transport"],
                paths_for=paths_for,
            )
        if method == "observe_claim":
            return inbox.observe_claim(
                a["claimed"], provider_turn_seen=bool(a.get("provider_turn_seen")), now=a.get("now"),
            )
        if method == "reconcile_terminal_claims":
            return inbox.reconcile_terminal_claims(now=a.get("now"))
        if method == "pending_for_route":
            return inbox.pending_for_route(a["route"])
        if method == "deliverable_commands":
            return inbox.deliverable_commands()
        if method == "source_command_intents":
            return inbox.source_command_intents(a.get("command"))
        if method == "state_snapshot":
            return list(inbox.state_snapshot())
        if method == "records":
            return inbox.records()
        if method == "retire_replaced_claim":
            return inbox.retire_replaced_claim(a["expected"])
        if method == "recovery_blocker":
            return inbox.recovery_blocker()
        if method == "skip_recovery_blocker":
            return inbox.skip_recovery_blocker(a["expected"])
        if method == "cancelled_intent_ids":
            return inbox.cancelled_intent_ids()
        if method == "sync_deliverable_state":
            return sync_deliverable_state(a["state_path"], inbox)
        raise KeyError(method)

    def _broker(self, method: str, a: dict):
        if method == "open":
            if self.broker is not None:
                self.broker.close()
                self.broker = None
            self.broker = ProviderTurnBroker(a["path"], projection_path=a.get("projection_path"))
            return None
        if method == "close":
            if self.broker is not None:
                self.broker.close()
            self.broker = None
            return None
        broker = self.broker
        if method == "activate":
            return broker.activate(
                a["record"], now=a.get("now"),
                release_reason=a.get("release_reason") or "superseded_by_prompt_submit",
            )
        if method == "transition":
            return broker.transition(
                a["record"], to_state=a["to_state"], event_type=a["event_type"],
                release_reason=a["release_reason"], now=a.get("now"), event_id=a.get("event_id"),
            )
        if method == "state_for":
            return broker.state_for(a["record"])
        if method == "terminate_owner":
            return broker.terminate_owner(
                a["ownership"], provider_session_id=a["provider_session_id"],
                release_reason=a["release_reason"], event_id=a["event_id"], now=a.get("now"),
            )
        if method == "reserve_effect":
            reservation = broker.reserve_effect(
                a["command"], effect_kind=a.get("effect_kind") or "authoritative_reply", now=a.get("now"),
            )
            return {
                "accepted": reservation.accepted,
                "effect_id": reservation.effect_id,
                "reason": reservation.reason,
            }
        if method == "authorize_effect_delivery":
            return broker.authorize_effect_delivery(a["effect_id"], now=a.get("now"))
        if method == "finish_effect":
            return broker.finish_effect(a["effect_id"], delivered=bool(a.get("delivered")), now=a.get("now"))
        if method == "project":
            return broker.project()
        if method == "session_records":
            return broker.session_records(a["native_session_id"])
        if method == "table_records":
            return broker.table_records(a["table"])
        raise KeyError(method)

    @staticmethod
    def _disposition(a: dict):
        return resolve_intent_disposition(
            intent_id=a.get("intent_id", ""),
            action_kind=a.get("action_kind", ""),
            action_reason=a.get("action_reason"),
            source_text=a.get("source_text", ""),
            active_work=tuple(
                ActiveWork(work["work_id"], tuple(work.get("resources") or ()), work.get("target"))
                for work in a.get("active_work") or ()
            ),
            requested_resources=a.get("requested_resources") or (),
            cancellation_scope=a.get("cancellation_scope"),
            target_work_ids=a.get("target_work_ids") or (),
        )

    def _model(self, method: str, a: dict):
        text = a.get("text", "")
        if method == "normalize_voice_work_items":
            return [
                item.to_dict()
                for item in normalize_voice_work_items(
                    text, relay_command_seq=a["relay_command_seq"], relay_command_id=a["relay_command_id"],
                )
            ]
        if method == "resolve_intent_disposition":
            return self._disposition(a).to_dict()
        if method == "authorization_relationship_for":
            return authorization_relationship_for(self._disposition(a), fallback=a["fallback"])
        if method == "explicit_replace_requested":
            return explicit_replace_requested(text, action_reason=a.get("action_reason", ""))
        if method == "explicit_cancel_requested":
            return explicit_cancel_requested(text)
        if method == "inferred_resource_claims":
            return list(inferred_resource_claims(text))
        if method == "sidecar_eligible":
            return sidecar_eligible(
                source_text=text,
                active_work=tuple(
                    ActiveWork(work["work_id"], tuple(work.get("resources") or ()), work.get("target"))
                    for work in a.get("active_work") or ()
                ),
                requested_resources=a.get("requested_resources") or (),
                project_mutation=bool(a.get("project_mutation")),
            )
        qualification = lambda: qualify_intent(  # noqa: E731
            text,
            action_kind=a["action_kind"],
            action_reason=a.get("action_reason"),
            command_id=a.get("command_id"),
            command_seq=a.get("command_seq"),
        )
        if method == "qualify_intent":
            return qualification().to_dict()
        if method == "format_qualification_for_agent":
            return format_qualification_for_agent(qualification())
        predicates = {
            "dispatch_forbidden": dispatch_forbidden,
            "foreground_action_requested": foreground_action_requested,
            "discussion_only_requested": discussion_only_requested,
            "context_dependent_assent": context_dependent_assent,
            "mixed_bucket_request": mixed_bucket_request,
            "whole_turn_resolution_required": whole_turn_resolution_required,
        }
        if method in predicates:
            return bool(predicates[method](text))
        raise KeyError(method)


class RustIntents:
    """The relay-intents crate, through its JSON-lines test driver."""

    name = "rust"

    def __init__(self, command: list):
        self._process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._lock = threading.Lock()

    def call(self, op: str, **arguments):
        request = json.dumps({"op": op, **arguments})
        with self._lock:
            self._process.stdin.write(request + "\n")
            self._process.stdin.flush()
            line = self._process.stdout.readline()
        if not line:
            raise RuntimeError(f"intents driver exited: {self._process.stderr.read()}")
        answer = json.loads(line)
        if not answer["ok"]:
            raise Refused(answer["error"])
        return answer["result"]

    def close(self) -> None:
        if self._process.poll() is None:
            self._process.stdin.close()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
        self._process.stdout.close()
        self._process.stderr.close()


def implementation(name: str):
    """A fresh implementation by name; ``None`` for Rust without a driver."""
    if name == "python":
        return PythonIntents()
    command = driver_command()
    return RustIntents(command) if command else None


def normalized(value, *, root: str | None = None):
    """``value`` with wall-clock times and sandbox paths replaced, so two runs
    of one scenario compare equal."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key in TIME_COLUMNS and isinstance(item, (int, float)) and not isinstance(item, bool):
                result[key] = "<time>"
            else:
                result[key] = normalized(item, root=root)
        if str(value.get("event_type") or "") == "inbox_recovered" and "event_id" in value:
            # The scope of a start-up recovery is its time in nanoseconds.
            result["event_id"] = "<startup>"
        return result
    if isinstance(value, list):
        return [normalized(item, root=root) for item in value]
    if isinstance(value, str) and root:
        return value.replace(root, "<root>")
    return value


def database_dump(path: Path) -> dict:
    """Every table and the schema of an inbox database, read-only."""
    if not path.exists():
        return {}
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    try:
        schema = [
            tuple(row)
            for row in connection.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_master "
                "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
            )
        ]
        tables = {}
        for (kind, name, _, _) in schema:
            if kind != "table":
                continue
            order = {
                "intents": "ordinal",
                "provider_turn_transitions": "transition_ordinal",
            }.get(name, "rowid")
            tables[name] = [dict(row) for row in connection.execute(f"SELECT * FROM {name} ORDER BY {order}")]
        return {"schema": schema, "tables": tables}
    finally:
        connection.close()
