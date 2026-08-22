"""Single production gateway for Relay speech proposal, playback, and replay."""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import queue
import socket
import threading
import time
import uuid
from typing import Any, Callable


SPEECH_SOURCES = frozenset({"messenger", "orchestrator", "lifecycle", "completion", "fallback"})
SPEECH_KINDS = frozenset({
    "handoff",
    "progress",
    "clarification",
    "final",
    "fallback",
    "control",
})
FINAL_KINDS = frozenset({"final", "fallback"})
SUPERSEDING_KINDS = frozenset({"clarification", "final", "fallback"})
FRESHNESS_SCOPES = frozenset({"conversation", "work"})
LIFECYCLE_ROLES = frozenset({
    "acknowledgement",
    "progress",
    "result",
    "failure",
    "blocker",
    "decision",
    "conversation",
    "control",
})
REALIZATION_DECISIONS = frozenset({"full", "delta", "suppress"})
REPLAY_HISTORY_LIMIT = 32
REPLAY_RETAINING_STOP_REASONS = frozenset({"user_stop"})


def _stable_digest(*values: object) -> str:
    content = "\x1f".join(str(value or "") for value in values)
    return hashlib.sha256(content.encode("utf-8", errors="replace")).hexdigest()[:24]


@dataclass(frozen=True)
class SpeechIntent:
    command_seq: int | None
    command_id: str | None
    utterance_id: str
    dedup_key: str
    source: str
    kind: str
    authoritative: bool
    priority: int
    display_text: str
    semantic_brief: str
    spoken_text: str
    created_at: float
    expires_at: float | None = None
    freshness_scope: str = "conversation"
    replacement_policy: str = "semantic"
    work_disposition: dict[str, Any] | None = None
    replayable: bool = False
    lifecycle_role: str = "conversation"
    covered_facts: tuple[str, ...] = ()
    realization_decision: str = "full"
    suppression_reason: str = ""
    original_utterance_id: str = ""
    replay_of: str | None = None

    @property
    def command_key(self) -> tuple[int, str] | None:
        if self.command_seq is None or not self.command_id:
            return None
        return int(self.command_seq), str(self.command_id)

    @property
    def presentation_mode(self) -> str:
        return "explicit_replay" if self.replay_of else "new_delivery"

    def to_worker_payload(self) -> dict[str, Any]:
        return {
            "text": self.spoken_text,
            "display_text": self.display_text,
            "_speech_intent": asdict(self),
        }

    @classmethod
    def build(
        cls,
        *,
        spoken_text: str,
        display_text: str | None = None,
        semantic_brief: str | None = None,
        command_seq: int | None = None,
        command_id: str | None = None,
        source: str = "fallback",
        kind: str = "fallback",
        authoritative: bool = False,
        priority: int | None = None,
        dedup_key: str | None = None,
        utterance_id: str | None = None,
        created_at: float | None = None,
        expires_at: float | None = None,
        freshness_scope: str = "conversation",
        replacement_policy: str = "semantic",
        work_disposition: dict[str, Any] | None = None,
        replayable: bool | None = None,
        lifecycle_role: str | None = None,
        covered_facts: list[str] | tuple[str, ...] | None = None,
        realization_decision: str = "full",
        suppression_reason: str | None = None,
        original_utterance_id: str | None = None,
        replay_of: str | None = None,
    ) -> "SpeechIntent":
        source = source if source in SPEECH_SOURCES else "fallback"
        kind = kind if kind in SPEECH_KINDS else "fallback"
        spoken = str(spoken_text or "").strip()
        display = str(display_text or "").strip()
        brief = str(semantic_brief or display or spoken).strip()
        stable_key = dedup_key or (
            f"outcome:{command_seq}:{command_id}"
            if kind in FINAL_KINDS and command_seq is not None and command_id
            else f"{source}:{kind}:{command_seq}:{command_id}:{_stable_digest(brief, spoken)}"
        )
        scope = str(freshness_scope or "conversation").strip().lower()
        if (
            scope not in FRESHNESS_SCOPES
            or (scope == "work" and (source != "lifecycle" or kind != "final"))
        ):
            scope = "conversation"
        role = str(lifecycle_role or _default_lifecycle_role(kind)).strip().lower()
        if role not in LIFECYCLE_ROLES:
            role = _default_lifecycle_role(kind)
        decision = str(realization_decision or "full").strip().lower()
        if decision not in REALIZATION_DECISIONS:
            decision = "full"
        facts = tuple(
            fact
            for fact in (str(value or "").strip() for value in (covered_facts or ()))
            if fact
        )
        resolved_utterance_id = utterance_id or str(uuid.uuid4())
        return cls(
            command_seq=int(command_seq) if command_seq is not None else None,
            command_id=str(command_id) if command_id else None,
            utterance_id=resolved_utterance_id,
            dedup_key=stable_key,
            source=source,
            kind=kind,
            authoritative=bool(authoritative),
            priority=int(priority if priority is not None else _default_priority(kind, authoritative)),
            display_text=display,
            semantic_brief=brief,
            spoken_text=spoken,
            created_at=time.time() if created_at is None else float(created_at),
            expires_at=float(expires_at) if expires_at is not None else None,
            freshness_scope=scope,
            replacement_policy=replacement_policy,
            work_disposition=work_disposition,
            replayable=(kind == "final") if replayable is None else bool(replayable),
            lifecycle_role=role,
            covered_facts=facts,
            realization_decision=decision,
            suppression_reason=str(suppression_reason or "").strip(),
            original_utterance_id=(
                str(original_utterance_id or "").strip() or resolved_utterance_id
            ),
            replay_of=str(replay_of) if replay_of else None,
        )


def _default_priority(kind: str, authoritative: bool) -> int:
    base = {
        "handoff": 20,
        "progress": 10,
        "clarification": 80,
        "final": 70,
        "fallback": 60,
        "control": 100,
    }.get(kind, 10)
    return base + (5 if authoritative else 0)


def _default_lifecycle_role(kind: str) -> str:
    return {
        "handoff": "acknowledgement",
        "progress": "progress",
        "clarification": "decision",
        "final": "result",
        "fallback": "result",
        "control": "control",
    }.get(kind, "conversation")


class CoordinatorInputQueue:
    """Queue-shaped adapter; producers cannot reach the executor queue directly."""

    def __init__(self, coordinator: "SpeechCoordinator"):
        self._coordinator = coordinator

    def put(self, item, block: bool = True, timeout: float | None = None) -> bool:
        del block, timeout
        if isinstance(item, SpeechIntent):
            return self._coordinator.submit(item)
        if isinstance(item, dict):
            spec = item.get("_speech_intent_spec")
            return self.submit_text(
                str(item.get("text") or ""),
                display_text=item.get("display_text"),
                **(spec if isinstance(spec, dict) else {}),
            )
        return self.submit_text(str(item or ""))

    def submit_text(self, text: str, **metadata) -> bool:
        return self._coordinator.submit(SpeechIntent.build(spoken_text=text, **metadata))

    def empty(self) -> bool:
        return not self._coordinator.has_pending_speech


class SpeechCoordinator:
    """Arbitrates typed speech intents before committing one plan to TTS."""

    def __init__(
        self,
        worker,
        *,
        is_current: Callable[[int, str], bool],
        event_log_path: str | os.PathLike[str] | None = None,
        control_socket_path: str | None = None,
    ):
        self.worker = worker
        self.input_queue = CoordinatorInputQueue(self)
        self._is_current = is_current
        self._event_log_path = str(event_log_path) if event_log_path else None
        self._lock = threading.RLock()
        self._accepted_keys: set[str] = set()
        self._intents: dict[str, SpeechIntent] = {}
        self._committed_id: str | None = None
        self._playing_id: str | None = None
        self._backlog: list[SpeechIntent] = []
        self._replayable_history: list[SpeechIntent] = []
        self._stopped_attempt_reasons: dict[str, str] = {}
        self._played_coverage: dict[tuple[int, str], list[dict[str, Any]]] = {}
        self._waiting_preview: tuple[tuple[int, str], str] | None = None
        self._play_requested = False
        self._play_dispatched_id: str | None = None
        self._play_timing: dict[str, Any] | None = None
        self._utterance_timings: dict[str, dict[str, Any]] = {}
        self._intent_committed_at: dict[str, float] = {}
        self._speech_stopped = False
        self._shutdown = threading.Event()
        self._control_socket_path = control_socket_path
        self._control_thread: threading.Thread | None = None
        if hasattr(worker, "set_speech_callbacks"):
            worker.set_speech_callbacks(
                eligibility=self._eligible_for_worker,
                observer=self._observe_worker,
            )
        if control_socket_path:
            self._control_thread = threading.Thread(
                target=self._control_loop,
                name="speech-coordinator-control",
                daemon=True,
            )
            self._control_thread.start()

    @property
    def has_pending_speech(self) -> bool:
        with self._lock:
            return bool(self._committed_id or self._playing_id or self._backlog)

    def played_coverage(self, command_seq: int, command_id: str) -> tuple[dict[str, Any], ...]:
        """Return bounded semantic coverage from speech that finished playing."""
        key = (int(command_seq), str(command_id))
        with self._lock:
            return tuple(dict(item) for item in self._played_coverage.get(key, ()))

    def record_realization(
        self,
        command_seq: int,
        command_id: str,
        *,
        lifecycle_role: str,
        decision: str,
        reason: str,
    ) -> None:
        """Record a synthesis decision without retaining reply text."""
        self._write_diagnostic({
            "event": "realization",
            "at": time.time(),
            "relay_command_seq": int(command_seq),
            "relay_command_id": str(command_id),
            "lifecycle_role": lifecycle_role,
            "realization_decision": decision,
            "suppression_reason": reason,
        })

    def submit(self, intent: SpeechIntent) -> bool:
        started = time.perf_counter()
        self._diagnostic("proposed", intent)
        if not intent.spoken_text or not self._fresh(intent):
            self._diagnostic("expired", intent, latency_ms=_elapsed_ms(started))
            return False

        replace_committed = False
        commit_now = False
        with self._lock:
            if intent.dedup_key in self._accepted_keys:
                self._diagnostic("deduplicated", intent, latency_ms=_elapsed_ms(started))
                return False

            current = self._intent_for(self._playing_id or self._committed_id)
            if current is not None and self._newer_command(intent, current):
                replace_committed = True
                self._backlog.clear()
            elif current is not None and self._supersedes(intent, current):
                if self._playing_id:
                    self._drop_obsolete_backlog(intent)
                    self._backlog.append(intent)
                    self._accept_locked(intent)
                    self._diagnostic("accepted", intent, latency_ms=_elapsed_ms(started))
                    return True
                replace_committed = True
            elif current is not None:
                self._drop_obsolete_backlog(intent)
                self._backlog.append(intent)
                self._accept_locked(intent)
                self._diagnostic("accepted", intent, latency_ms=_elapsed_ms(started))
                return True
            else:
                commit_now = True

            self._accept_locked(intent)
            self._intent_committed_at[intent.utterance_id] = time.time()
            if len(self._intent_committed_at) > 512:
                oldest = next(iter(self._intent_committed_at))
                self._intent_committed_at.pop(oldest, None)
            if replace_committed:
                old = self._intent_for(self._committed_id)
                self._committed_id = intent.utterance_id
                if old is not None:
                    if self._play_dispatched_id == old.utterance_id:
                        self._play_dispatched_id = None
                    self._diagnostic("replaced", old, replaced_by=intent.utterance_id)
            elif commit_now:
                self._committed_id = intent.utterance_id

        if replace_committed:
            self.worker.skip()
        self.worker.input_queue.put(intent.to_worker_payload())
        self._dispatch_requested_play()
        self._diagnostic("accepted", intent, latency_ms=_elapsed_ms(started))
        return True

    def arm_waiting_playback(
        self,
        command_seq: int,
        command_id: str,
        *,
        kind: str = "final",
    ) -> None:
        """Bind the next play gesture to speech backing an imminent preview."""
        target = (int(command_seq), str(command_id))
        with self._lock:
            previous = self._waiting_preview
            self._waiting_preview = (target, kind)
            if self._play_timing is not None and previous != self._waiting_preview:
                self._play_timing["relay_command_seq"] = target[0]
                self._play_timing["relay_command_id"] = target[1]
                self._play_timing["kind"] = kind
            dispatched = self._intent_for(self._play_dispatched_id)
            if dispatched is not None and not self._matches_waiting_preview(dispatched):
                self._play_dispatched_id = None

    def note_play_control(
        self,
        *,
        option_detected_at: float | None = None,
        fifo_received_at: float | None = None,
    ) -> None:
        """Capture privacy-safe shortcut timing before play mutates coordinator state."""
        received_at = float(fifo_received_at or time.time())
        detected_at = float(option_detected_at or received_at)
        with self._lock:
            if self._play_requested and self._play_timing is not None:
                self._write_diagnostic({
                    "event": "duplicate_play_control",
                    "at": received_at,
                    "play_request_id": self._play_timing.get("play_request_id"),
                    "relay_command_seq": self._play_timing.get("relay_command_seq"),
                    "relay_command_id": self._play_timing.get("relay_command_id"),
                    "option_to_fifo_ms": _duration_ms(detected_at, received_at),
                })
                return
            target = self._waiting_preview
            intent = self._intent_for(self._committed_id)
            command_key = target[0] if target is not None else (intent.command_key if intent else None)
            self._play_timing = {
                "play_request_id": str(uuid.uuid4()),
                "option_detected_at": detected_at,
                "fifo_received_at": received_at,
                "relay_command_seq": command_key[0] if command_key else None,
                "relay_command_id": command_key[1] if command_key else None,
                "kind": target[1] if target is not None else (intent.kind if intent else None),
            }
            fields = {
                "play_request_id": self._play_timing["play_request_id"],
                "relay_command_seq": self._play_timing["relay_command_seq"],
                "relay_command_id": self._play_timing["relay_command_id"],
            }
            self._write_diagnostic({"event": "option_detected", "at": detected_at, **fields})
            self._write_diagnostic({
                "event": "fifo_play_received",
                "at": received_at,
                "option_to_fifo_ms": _duration_ms(detected_at, received_at),
                **fields,
            })

    def note_visual_acknowledgement(
        self,
        *,
        option_detected_at: float,
        acknowledged_at: float,
    ) -> None:
        with self._lock:
            timing = self._play_timing
            self._write_diagnostic({
                "event": "visual_play_acknowledged",
                "at": acknowledged_at,
                "play_request_id": timing.get("play_request_id") if timing else None,
                "relay_command_seq": timing.get("relay_command_seq") if timing else None,
                "relay_command_id": timing.get("relay_command_id") if timing else None,
                "option_to_ack_ms": _duration_ms(option_detected_at, acknowledged_at),
            })

    def new_turn(self, command_seq: int, command_id: str) -> None:
        """Suppress stale speech without revoking accepted background work."""
        stale_ids: list[str] = []
        invalidated_replay: SpeechIntent | None = None
        command_key = (int(command_seq), str(command_id))
        with self._lock:
            self._speech_stopped = False
            self._clear_play_request_locked()
            for intent_id in [self._committed_id, self._playing_id]:
                intent = self._intent_for(intent_id)
                if (
                    intent is not None
                    and intent.freshness_scope != "work"
                    and intent.command_key != command_key
                ):
                    stale_ids.append(intent.utterance_id)
            self._backlog = [
                intent
                for intent in self._backlog
                if (
                    intent.freshness_scope == "work"
                    or intent.command_key == command_key
                )
            ]
            stale_replay = [
                intent
                for intent in self._replayable_history
                if intent.freshness_scope != "work" and intent.command_key != command_key
            ]
            if stale_replay:
                invalidated_replay = stale_replay[-1]
                stale_replay_ids = {intent.utterance_id for intent in stale_replay}
                self._replayable_history = [
                    intent
                    for intent in self._replayable_history
                    if intent.utterance_id not in stale_replay_ids
                ]
            if self._committed_id in stale_ids:
                self._committed_id = None
        if stale_ids:
            self.worker.skip()
            for intent_id in stale_ids:
                intent = self._intent_for(intent_id)
                if intent is not None:
                    self._diagnostic("interrupted", intent, reason="newer_command")
        if invalidated_replay is not None:
            self._publish_replay_invalidated(invalidated_replay, reason="newer_command")

    def stop(self) -> None:
        """Barge-in retires speech plans only; it does not alter work authorization."""
        stale: list[SpeechIntent] = []
        invalidated_replay: SpeechIntent | None = None
        with self._lock:
            self._speech_stopped = True
            self._clear_play_request_locked()
            stale = [
                intent
                for intent in (
                    self._intent_for(self._committed_id),
                    self._intent_for(self._playing_id),
                    *self._backlog,
                )
                if intent is not None
            ]
            self._committed_id = None
            self._playing_id = None
            self._backlog.clear()
            for intent in stale:
                self._stopped_attempt_reasons.pop(intent.utterance_id, None)
            stale_original_ids = {intent.original_utterance_id for intent in stale}
            invalidated_replay = next(
                (
                    intent
                    for intent in reversed(self._replayable_history)
                    if intent.original_utterance_id in stale_original_ids
                ),
                None,
            )
            self._replayable_history = [
                intent
                for intent in self._replayable_history
                if intent.original_utterance_id not in stale_original_ids
            ]
        self.worker.stop_playback()
        for intent in stale:
            self._diagnostic("interrupted", intent, reason="speech_only_barge_in")
        if invalidated_replay is not None:
            self._publish_replay_invalidated(
                invalidated_replay,
                reason="speech_only_barge_in",
            )

    def stop_playback(self, *, reason: str = "user_stop") -> None:
        """Stop one active attempt without revoking its replay eligibility."""
        normalized_reason = str(reason or "user_stop").strip() or "user_stop"
        invalidated_replay: SpeechIntent | None = None
        with self._lock:
            intent = self._intent_for(self._playing_id)
            if intent is not None:
                self._stopped_attempt_reasons[intent.utterance_id] = normalized_reason
                self._clear_play_request_locked()
                if normalized_reason not in REPLAY_RETAINING_STOP_REASONS:
                    self._speech_stopped = True
                    original_id = intent.original_utterance_id
                    invalidated_replay = next(
                        (
                            retained
                            for retained in reversed(self._replayable_history)
                            if retained.original_utterance_id == original_id
                        ),
                        None,
                    )
                    self._replayable_history = [
                        retained
                        for retained in self._replayable_history
                        if retained.original_utterance_id != original_id
                    ]
        if intent is None:
            self.stop()
            return
        self.worker.stop_playback(reason=normalized_reason)
        if invalidated_replay is not None:
            self._publish_replay_invalidated(
                invalidated_replay,
                reason=normalized_reason,
            )

    def skip(self) -> None:
        with self._lock:
            if self._playing_id is not None:
                stop_active_attempt = True
            else:
                stop_active_attempt = False
        if stop_active_attempt:
            self.stop_playback(reason="user_stop")
            return
        invalidated_replay: SpeechIntent | None = None
        with self._lock:
            self._clear_play_request_locked()
            stale = [
                intent
                for intent in (
                    self._intent_for(self._committed_id),
                    self._intent_for(self._playing_id),
                    *self._backlog,
                )
                if intent is not None
            ]
            self._committed_id = None
            self._backlog.clear()
            invalidated_replay = next(
                (
                    intent
                    for intent in reversed(self._replayable_history)
                    if self._fresh(intent)
                ),
                None,
            )
            if invalidated_replay is not None:
                original_id = invalidated_replay.original_utterance_id
                self._replayable_history = [
                    intent
                    for intent in self._replayable_history
                    if intent.original_utterance_id != original_id
                ]
        self.worker.skip()
        for intent in stale:
            self._diagnostic("interrupted", intent, reason="skip")
        if invalidated_replay is not None:
            self._publish_replay_invalidated(invalidated_replay, reason="cancelled")

    def play(self) -> None:
        with self._lock:
            if self._playing_id:
                return
            if not self._committed_id and self._waiting_preview is None:
                return
            self._speech_stopped = False
            self._play_requested = True
            timing = self._play_timing
            if timing is not None and "latched_at" not in timing:
                timing["latched_at"] = time.time()
                self._write_diagnostic({
                    "event": "retained_play_latched",
                    "at": timing["latched_at"],
                    "play_request_id": timing.get("play_request_id"),
                    "relay_command_seq": timing.get("relay_command_seq"),
                    "relay_command_id": timing.get("relay_command_id"),
                    "option_to_latch_ms": _duration_ms(
                        timing.get("option_detected_at"), timing["latched_at"]
                    ),
                })
        self._dispatch_requested_play()

    def play_or_replay(self) -> bool:
        """Play pending speech, or replay the last completed current message."""
        with self._lock:
            if self._playing_id:
                return True
            should_replay = not self._committed_id and self._waiting_preview is None
        if should_replay:
            return self.replay()
        self.play()
        return True

    def replay(self) -> bool:
        with self._lock:
            history = tuple(self._replayable_history)
            timing = dict(self._play_timing) if self._play_timing is not None else None
        previous = next((intent for intent in reversed(history) if self._fresh(intent)), None)
        if previous is None:
            latest = history[-1] if history else None
            self._write_diagnostic({
                "event": "replay_rejected",
                "at": time.time(),
                "reason": "no_fresh_target" if history else "no_completed_target",
                "play_request_id": timing.get("play_request_id") if timing else None,
                "utterance_id": latest.utterance_id if latest else None,
                "relay_command_seq": latest.command_seq if latest else None,
                "relay_command_id": latest.command_id if latest else None,
            })
            return False
        replay = replace(
            previous,
            utterance_id=str(uuid.uuid4()),
            dedup_key=f"replay:{previous.utterance_id}:{uuid.uuid4()}",
            created_at=time.time(),
            replacement_policy="replay",
            original_utterance_id=previous.original_utterance_id,
            replay_of=previous.original_utterance_id,
        )
        with self._lock:
            self._waiting_preview = None
            self._play_requested = True
        accepted = self.submit(replay)
        if accepted:
            self._diagnostic("replayed", replay, replay_of=replay.replay_of)
        else:
            with self._lock:
                self._play_requested = False
        return accepted

    def reload_config(self) -> None:
        self.worker.reload_config()

    def shutdown(self) -> None:
        self._shutdown.set()
        self.stop()
        self.worker.shutdown()
        thread = self._control_thread
        if thread and thread is not threading.current_thread():
            thread.join(timeout=1)

    def _accept_locked(self, intent: SpeechIntent) -> None:
        self._accepted_keys.add(intent.dedup_key)
        self._intents[intent.utterance_id] = intent
        if len(self._accepted_keys) > 512:
            self._accepted_keys = set(list(self._accepted_keys)[-256:])

    def _intent_for(self, intent_id: str | None) -> SpeechIntent | None:
        return self._intents.get(intent_id) if intent_id else None

    def _matches_waiting_preview(self, intent: SpeechIntent) -> bool:
        target = self._waiting_preview
        if target is None:
            return True
        command_key, kind = target
        if intent.command_key != command_key:
            return False
        if kind in FINAL_KINDS:
            return intent.kind in FINAL_KINDS
        return intent.kind == kind

    def _dispatch_requested_play(self) -> None:
        should_play = False
        with self._lock:
            intent = self._intent_for(self._committed_id)
            if (
                self._play_requested
                and self._playing_id is None
                and intent is not None
                and self._matches_waiting_preview(intent)
                and self._play_dispatched_id != intent.utterance_id
            ):
                self._play_dispatched_id = intent.utterance_id
                if self._play_timing is not None:
                    timing = dict(self._play_timing)
                    timing["relay_command_seq"] = intent.command_seq
                    timing["relay_command_id"] = intent.command_id
                    timing["utterance_id"] = intent.utterance_id
                    committed_at = self._intent_committed_at.get(intent.utterance_id, time.time())
                    timing["intent_committed_at"] = committed_at
                    self._utterance_timings[intent.utterance_id] = timing
                    self._write_diagnostic({
                        "event": "intent_committed",
                        "at": committed_at,
                        "play_request_id": timing.get("play_request_id"),
                        "utterance_id": intent.utterance_id,
                        "relay_command_seq": intent.command_seq,
                        "relay_command_id": intent.command_id,
                        "option_to_intent_commit_ms": _duration_ms(
                            timing.get("option_detected_at"), committed_at
                        ),
                    })
                    if len(self._utterance_timings) > 64:
                        oldest = next(iter(self._utterance_timings))
                        self._utterance_timings.pop(oldest, None)
                should_play = True
        if should_play:
            self.worker.play()

    def _clear_play_request_locked(self, *, preserve_timing: bool = False) -> None:
        self._waiting_preview = None
        self._play_requested = False
        self._play_dispatched_id = None
        if not preserve_timing:
            self._play_timing = None

    def _fresh(self, intent: SpeechIntent) -> bool:
        if intent.expires_at is not None and time.time() >= intent.expires_at:
            return False
        if intent.freshness_scope == "work":
            return True
        key = intent.command_key
        return key is None or self._is_current(key[0], key[1])

    def _eligible_for_worker(self, payload: dict[str, Any]) -> bool:
        intent_id = str(payload.get("utterance_id") or "")
        with self._lock:
            intent = self._intent_for(intent_id)
            accepted = (
                not self._speech_stopped
                and intent_id in {self._committed_id, self._playing_id}
                and self._matches_waiting_preview(intent)
            )
        return bool(intent and accepted and self._fresh(intent))

    def _observe_worker(self, state: str, payload: dict[str, Any]) -> None:
        intent_id = str(payload.get("utterance_id") or "")
        observed_at = float(payload.get("_event_at") or time.time())
        next_intent: SpeechIntent | None = None
        retained_after_stop = False
        stop_reason: str | None = None
        with self._lock:
            intent = self._intent_for(intent_id)
            if intent is None:
                return
            if state == "started":
                self._playing_id = intent_id
                if self._committed_id == intent_id:
                    self._committed_id = None
                if self._matches_waiting_preview(intent):
                    self._clear_play_request_locked(preserve_timing=True)
            elif state in {"completed", "cancelled", "failed"}:
                stop_reason = self._stopped_attempt_reasons.pop(intent_id, None)
                stopped_attempt = (
                    state == "cancelled"
                    and stop_reason in REPLAY_RETAINING_STOP_REASONS
                )
                if self._play_dispatched_id == intent_id:
                    self._play_dispatched_id = None
                if self._playing_id == intent_id:
                    self._playing_id = None
                if self._committed_id == intent_id:
                    self._committed_id = None
                retained_after_stop = stopped_attempt and self._retain_replayable_locked(intent)
                if state == "completed":
                    self._retain_replayable_locked(intent)
                if state == "completed":
                    self._record_played_coverage_locked(intent)
                if (
                    not stopped_attempt
                    and not self._committed_id
                    and not self._playing_id
                    and not self._speech_stopped
                ):
                    next_intent = self._next_eligible_locked()
                    if next_intent is not None:
                        self._committed_id = next_intent.utterance_id
        stage_event = {
            "preparing": "tts_preparing",
            "wav_ready": "first_wav_ready",
            "afplay_started": "afplay_started",
        }.get(state)
        timing = self._utterance_timings.get(intent_id)
        if stage_event is not None:
            self._diagnostic(
                stage_event,
                intent,
                at=observed_at,
                play_request_id=timing.get("play_request_id") if timing else None,
                option_to_stage_ms=_duration_ms(
                    timing.get("option_detected_at") if timing else None,
                    observed_at,
                ),
            )
        else:
            self._diagnostic(
                (
                    "played" if state == "completed"
                    else "stopped" if retained_after_stop
                    else state
                ),
                intent,
                at=observed_at,
                stop_reason=stop_reason,
            )
        if next_intent is not None:
            self.worker.input_queue.put(next_intent.to_worker_payload())
        if retained_after_stop and next_intent is None:
            publish_retained = getattr(self.worker, "publish_replay_retained", None)
            if callable(publish_retained):
                publish_retained(
                    intent.to_worker_payload()["_speech_intent"],
                    stop_reason=stop_reason,
                )
        if state in {"completed", "cancelled", "failed"}:
            self._utterance_timings.pop(intent_id, None)
            self._intent_committed_at.pop(intent_id, None)
    def _retain_replayable_locked(self, intent: SpeechIntent) -> bool:
        if not intent.replayable or not self._fresh(intent):
            return False
        if not any(
            retained.utterance_id == intent.utterance_id
            for retained in self._replayable_history
        ):
            self._replayable_history.append(intent)
            if len(self._replayable_history) > REPLAY_HISTORY_LIMIT:
                del self._replayable_history[:-REPLAY_HISTORY_LIMIT]
        return True

    def _publish_replay_invalidated(self, intent: SpeechIntent, *, reason: str) -> None:
        publish_invalidated = getattr(self.worker, "publish_replay_invalidated", None)
        if callable(publish_invalidated):
            publish_invalidated(
                intent.to_worker_payload()["_speech_intent"],
                reason=reason,
            )
        self._diagnostic("replay_invalidated", intent, reason=reason)

    def _next_eligible_locked(self) -> SpeechIntent | None:
        while self._backlog:
            candidate = self._backlog.pop(0)
            if self._fresh(candidate):
                return candidate
            self._diagnostic("expired", candidate)
        return None

    def _record_played_coverage_locked(self, intent: SpeechIntent) -> None:
        key = intent.command_key
        if key is None or intent.replacement_policy == "replay":
            return
        facts = intent.covered_facts or (intent.semantic_brief or intent.spoken_text,)
        entry = {
            "utterance_id": intent.utterance_id,
            "lifecycle_role": intent.lifecycle_role,
            "covered_facts": tuple(facts),
            "spoken_text": intent.spoken_text,
        }
        coverage = self._played_coverage.setdefault(key, [])
        signature = (entry["lifecycle_role"], entry["covered_facts"], entry["spoken_text"])
        if not any(
            (item["lifecycle_role"], item["covered_facts"], item["spoken_text"]) == signature
            for item in coverage
        ):
            coverage.append(entry)
        if len(coverage) > 8:
            del coverage[:-8]
        if len(self._played_coverage) > 64:
            for old_key in list(self._played_coverage)[:-32]:
                self._played_coverage.pop(old_key, None)

    @staticmethod
    def _newer_command(incoming: SpeechIntent, current: SpeechIntent) -> bool:
        if incoming.command_seq is None or current.command_seq is None:
            return False
        return incoming.command_seq > current.command_seq

    @staticmethod
    def _supersedes(incoming: SpeechIntent, current: SpeechIntent) -> bool:
        if incoming.command_key != current.command_key:
            return incoming.priority > current.priority
        if incoming.kind in SUPERSEDING_KINDS and current.kind in {"handoff", "progress"}:
            return True
        return incoming.priority > current.priority and current.kind != "handoff"

    def _drop_obsolete_backlog(self, incoming: SpeechIntent) -> None:
        if incoming.kind not in SUPERSEDING_KINDS:
            return
        kept: list[SpeechIntent] = []
        for queued in self._backlog:
            obsolete = (
                queued.command_key == incoming.command_key
                and queued.kind in {"handoff", "progress"}
            )
            if obsolete:
                self._diagnostic("replaced", queued, replaced_by=incoming.utterance_id)
            else:
                kept.append(queued)
        self._backlog = kept

    def _control_loop(self) -> None:
        path = str(self._control_socket_path)
        try:
            os.unlink(path)
        except OSError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(path)
        sock.settimeout(0.5)
        try:
            while not self._shutdown.is_set():
                try:
                    command = sock.recvfrom(256)[0].decode("utf-8", errors="replace").strip().lower()
                except socket.timeout:
                    continue
                if command == "play":
                    self.play()
                elif command == "replay":
                    self.replay()
                elif command in {"skip", "cancel"}:
                    self.skip()
                elif command in {"pause", "stop"}:
                    self.stop()
                elif command == "toggle":
                    self.play()
        finally:
            sock.close()
            try:
                os.unlink(path)
            except OSError:
                pass

    def _diagnostic(self, event: str, intent: SpeechIntent, **fields: Any) -> None:
        path = self._event_log_path
        if not path:
            return
        record = {
            "event": event,
            "at": time.time(),
            "utterance_id": intent.utterance_id,
            "dedup_key": intent.dedup_key,
            "relay_command_seq": intent.command_seq,
            "relay_command_id": intent.command_id,
            "source": intent.source,
            "kind": intent.kind,
            "authoritative": intent.authoritative,
            "replayable": intent.replayable,
            "freshness_scope": intent.freshness_scope,
            "replacement_policy": intent.replacement_policy,
            "original_utterance_id": intent.original_utterance_id,
            "replay_of": intent.replay_of,
            "presentation_mode": intent.presentation_mode,
            "lifecycle_role": intent.lifecycle_role,
            "realization_decision": intent.realization_decision,
            "suppression_reason": intent.suppression_reason,
            **fields,
        }
        self._write_diagnostic(record)

    def _write_diagnostic(self, record: dict[str, Any]) -> None:
        if not self._event_log_path:
            return
        try:
            target = Path(self._event_log_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("a") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")
        except OSError:
            pass


def _elapsed_ms(started: float) -> float:
    return round((time.perf_counter() - started) * 1000, 3)


def _duration_ms(started: object, ended: object) -> float | None:
    try:
        return round((float(ended) - float(started)) * 1000, 3)
    except (TypeError, ValueError):
        return None
