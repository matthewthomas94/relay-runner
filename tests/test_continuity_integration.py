from __future__ import annotations

import json
import hashlib
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.modules.setdefault(
    "numpy",
    SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import orchestrator  # noqa: E402
import relay_completion_hook  # noqa: E402
import voice_bridge  # noqa: E402
from messenger import MessengerRuntime  # noqa: E402
from orchestrator import ContinuityLifecycleAdapter, Daemon  # noqa: E402
from continuity_incidents import opaque_identifier  # noqa: E402
from continuity_recovery import (  # noqa: E402
    CAPABILITY_POLICIES,
    ComponentOwnedRecoveryBroker,
    ProductionRecoveryCapability,
    RecoveryActionRequest,
    RecoveryActionValidation,
    RecoveryExecutionContext,
    production_recovery_owners,
)
from intent_inbox import IntentInbox  # noqa: E402
from voice_bridge import _post_continuity_event  # noqa: E402


FORBIDDEN_FIELDS = (
    "transcript",
    "prompt",
    "repository",
    "credential",
    "screenshot",
    "raw_error",
    "raw-error",
    "provider_output",
)


class _FailingMessengerBackend:
    config = SimpleNamespace(provider="claude")

    def start(self):
        return None

    def ask(self, _prompt, timeout=60.0):
        raise RuntimeError("raw-error-secret provider output")

    def interrupt(self):
        return None

    def shutdown(self):
        return None


class _RestartableMessengerBackend:
    config = SimpleNamespace(provider="codex")

    def __init__(self):
        self.starts = 0
        self.shutdowns = 0

    def start(self):
        self.starts += 1

    def ask(self, _prompt, timeout=60.0):
        return ""

    def interrupt(self):
        return None

    def shutdown(self):
        self.shutdowns += 1


class ContinuityIntegrationTests(unittest.TestCase):
    @staticmethod
    def _recovery_request(capability, component, session, command, **overrides):
        generation = overrides.pop("recovery_generation", "4")
        incident_id = "inc-123456789abc"
        identity = "|".join((
            incident_id,
            str(generation),
            capability,
            component,
            session,
            command or "none",
        ))
        values = {
            "capability": capability,
            "incident_id": incident_id,
            "session_id": session,
            "command_id": command,
            "component": component,
            "provider": "none",
            "recovery_generation": generation,
            "incident_phase": {
                "messenger": "component_liveness",
                "orchestrator": "component_liveness",
                "session": "session_liveness",
                "command": "command_processing",
            }.get(component, "delivery"),
            "process_identity": "continuity-1234567890abcdef1234567890abcdef",
            "attempt": 1,
            "idempotency_key": "recovery_" + hashlib.sha256(identity.encode()).hexdigest()[:24],
            "expected_postcondition": {
                "restart_messenger": "messenger_process_alive",
                "reconnect_ipc": "ipc_connection_restored",
                "restore_session_registration": "session_heartbeat_fresh",
                "release_dead_ownership": "dead_ownership_released",
            }.get(capability, "bridge_process_alive"),
            "incident_observed_at": time.time(),
            "deadline": time.monotonic() + 10,
        }
        values.update(overrides)
        return RecoveryActionRequest(**values)

    @staticmethod
    def _live_validation(request):
        return RecoveryActionValidation(
            validation_token="live_continuity_watch",
            exact_target_owned=True,
            liveness="unhealthy",
            incident_active=True,
            generation_matches=True,
            command_phase="undelivered",
            command_phase_matches=True,
            idempotency_state="new",
            compensation_available=False,
            cooldown_remaining=0,
            expected_postcondition=request.expected_postcondition,
        )

    def test_production_executor_requires_component_acknowledgement(self):
        daemon = Daemon.__new__(Daemon)
        daemon.continuity = SimpleNamespace(
            recovery_health=lambda _request: orchestrator.RecoveryHealthEvidence()
        )
        request = RecoveryActionRequest(
            capability="restart_bridge",
            incident_id="inc-123456789abc",
            session_id=opaque_identifier("session", "native-session"),
            command_id=opaque_identifier("command", "native-command"),
            component="bridge",
            provider="none",
            recovery_generation=4,
            incident_phase="delivery",
            process_identity="continuity-1234567890abcdef1234567890abcdef",
            attempt=1,
            idempotency_key="recovery_123456789012345678901234",
            expected_postcondition="bridge_process_alive",
            incident_observed_at=100,
            deadline=time.monotonic() + 1,
        )
        dispatched = []

        def acknowledge(state, **payload):
            dispatched.append((state, payload))
            Path(payload["reply_path"]).write_text(json.dumps({
                "status": "applied",
                "outcome_code": "component_action_requested",
            }))
            return True

        with patch("orchestrator._notify_state", side_effect=acknowledge):
            outcome = daemon._execute_continuity_recovery_action(
                request,
                self._live_validation(request),
                threading.Event(),
            )

        self.assertEqual(
            (outcome.status, outcome.outcome_code),
            ("applied", "component_action_requested"),
        )
        self.assertEqual(dispatched[0][0], "request")
        self.assertEqual(dispatched[0][1]["component"], "bridge")
        self.assertEqual(
            dispatched[0][1]["expected_postcondition"],
            "bridge_process_alive",
        )
        self.assertEqual(dispatched[0][1]["incident_phase"], "delivery")
        self.assertEqual(dispatched[0][1]["attempt"], 1)
        self.assertEqual(
            dispatched[0][1]["idempotency_key"],
            "recovery_123456789012345678901234",
        )
        self.assertEqual(dispatched[0][1]["command_phase"], "undelivered")
        self.assertEqual(dispatched[0][1]["cooldown_remaining"], 0)

    def test_production_executor_preserves_background_ack_during_poll_sleep(self):
        daemon = Daemon.__new__(Daemon)
        daemon.continuity = SimpleNamespace(
            recovery_health=lambda _request: orchestrator.RecoveryHealthEvidence()
        )
        request = RecoveryActionRequest(
            capability="restart_bridge",
            incident_id="inc-123456789abc",
            session_id=opaque_identifier("session", "native-session"),
            command_id=opaque_identifier("command", "native-command"),
            component="bridge",
            provider="none",
            recovery_generation=4,
            incident_phase="delivery",
            process_identity="continuity-1234567890abcdef1234567890abcdef",
            attempt=1,
            idempotency_key="recovery_abcdefghijklmnopqrstuvwx",
            expected_postcondition="bridge_process_alive",
            incident_observed_at=100,
            deadline=time.monotonic() + 1,
        )
        poll_sleep_started = threading.Event()
        reply_written = threading.Event()
        cancel_event = threading.Event()
        background_errors = []
        background_thread = None

        def write_background_ack(reply_path):
            try:
                if not poll_sleep_started.wait(1):
                    raise TimeoutError("poller did not enter missing-reply sleep")
                Path(reply_path).write_text(json.dumps({
                    "status": "applied",
                    "outcome_code": "component_action_requested",
                }))
            except Exception as error:  # noqa: BLE001 - surfaced in this test thread.
                background_errors.append(error)
            finally:
                reply_written.set()

        def acknowledge(_state, **payload):
            nonlocal background_thread
            background_thread = threading.Thread(
                target=write_background_ack,
                args=(payload["reply_path"],),
            )
            background_thread.start()
            return True

        sleep_calls = 0

        def coordinated_sleep(_seconds):
            nonlocal sleep_calls
            sleep_calls += 1
            if sleep_calls == 1:
                poll_sleep_started.set()
                self.assertTrue(reply_written.wait(1))
            else:
                cancel_event.set()

        with (
            patch("orchestrator._notify_state", side_effect=acknowledge),
            patch("orchestrator.time.sleep", side_effect=coordinated_sleep),
        ):
            outcome = daemon._execute_continuity_recovery_action(
                request,
                self._live_validation(request),
                cancel_event,
            )

        self.assertIsNotNone(background_thread)
        background_thread.join(timeout=1)
        self.assertFalse(background_thread.is_alive())
        self.assertEqual(background_errors, [])
        self.assertEqual(sleep_calls, 1)
        self.assertEqual(
            (outcome.status, outcome.outcome_code),
            ("applied", "component_action_requested"),
        )

    def test_live_recovery_validation_requires_exact_active_owner_and_generation(self):
        adapter = ContinuityLifecycleAdapter(emit=lambda _event: None)
        adapter.observe({
            "source": "provider",
            "event": "process_exit",
            "session_id": "native-session",
            "relay_command_id": "native-command",
            "provider": "codex",
            "recovery_generation": 4,
            "observed_at": 100,
        })
        adapter.sample(observed_at=200)
        adapter.sample(observed_at=201)
        request = RecoveryActionRequest(
            capability="launch_foreground_provider",
            incident_id="inc-123456789abc",
            session_id=opaque_identifier("session", "native-session"),
            command_id=opaque_identifier("command", "native-command"),
            component="foreground_provider",
            provider="codex",
            recovery_generation=4,
            incident_phase="provider_turn",
            process_identity="continuity-1234567890abcdef1234567890abcdef",
            attempt=1,
            idempotency_key="recovery_123456789012345678901234",
            expected_postcondition="provider_process_alive",
            incident_observed_at=100,
            deadline=200,
        )

        live = adapter.recovery_validation(request)
        stale = adapter.recovery_validation(
            RecoveryActionRequest(**{**request.__dict__, "recovery_generation": 5})
        )
        missing_owner = adapter.recovery_validation(
            RecoveryActionRequest(**{
                **request.__dict__,
                "session_id": opaque_identifier("session", "stale-session"),
            })
        )

        self.assertTrue(live.exact_target_owned)
        self.assertTrue(live.generation_matches)
        self.assertEqual(live.liveness, "confirmed_dead")
        self.assertTrue(stale.exact_target_owned)
        self.assertFalse(stale.generation_matches)
        self.assertEqual(stale.liveness, "confirmed_dead")
        self.assertFalse(missing_owner.exact_target_owned)
        self.assertFalse(missing_owner.incident_active)
        self.assertEqual(missing_owner.liveness, "unknown")

    def test_production_provider_and_session_relaunch_resolve_same_generation_for_both_providers(self):
        generation = "12345678-1234-4abc-8def-1234567890ab"
        for provider in ("codex", "claude"):
            for component in ("foreground_provider", "session"):
                with self.subTest(provider=provider, component=component):
                    emitted = []
                    adapter = ContinuityLifecycleAdapter(emit=emitted.append)
                    native_session = f"{provider}-{component}-session"
                    native_command = (
                        f"{provider}-provider-command"
                        if component == "foreground_provider"
                        else None
                    )
                    adapter.observe({
                        "source": "provider" if component == "foreground_provider" else "session",
                        "event": "process_exit",
                        "session_id": native_session,
                        "relay_command_id": native_command,
                        "provider": provider,
                        "recovery_generation": generation,
                        "observed_at": 100,
                    })
                    adapter.sample(observed_at=130)
                    adapter.sample(observed_at=131)
                    self.assertEqual(len(emitted), 1)
                    incident = emitted[0]
                    self.assertEqual(incident["component"], component)
                    self.assertEqual(incident["provider"], provider)
                    self.assertEqual(incident["recovery_generation"], generation)

                    daemon = Daemon.__new__(Daemon)
                    daemon.continuity = adapter
                    capabilities = {
                        capability: ProductionRecoveryCapability(
                            adapter.recovery_validation,
                            daemon._execute_continuity_recovery_action,
                        )
                        for capability in CAPABILITY_POLICIES
                        if capability != "check_processing_health"
                    }
                    broker = ComponentOwnedRecoveryBroker(production_recovery_owners(
                        adapter.recovery_health,
                        capabilities=capabilities,
                    ))
                    dispatched = []

                    def acknowledge(state, **payload):
                        dispatched.append((state, payload))
                        common = {
                            "session_id": native_session,
                            "provider": provider,
                            "recovery_generation": generation,
                        }
                        if component == "foreground_provider":
                            events = (
                                ("turn_started", "turn_progress")
                                if provider == "codex"
                                else ("stream_started", "stream_progress")
                            )
                            for event, observed_at in zip(
                                events,
                                (132, 133),
                            ):
                                adapter.observe({
                                    **common,
                                    "source": "provider",
                                    "event": event,
                                    "relay_command_id": native_command,
                                    "observed_at": observed_at,
                                })
                        else:
                            adapter.observe({
                                **common,
                                "source": "session",
                                "event": "started",
                                "observed_at": 132,
                            })
                        Path(payload["reply_path"]).write_text(json.dumps({
                            "status": "applied",
                            "outcome_code": "component_action_requested",
                        }))
                        return True

                    with patch("orchestrator._notify_state", side_effect=acknowledge):
                        outcome = broker.perform(
                            "launch_foreground_provider",
                            incident=incident,
                            process_identity="continuity-1234567890abcdef1234567890abcdef",
                            recovery_generation=generation,
                            attempt=1,
                            deadline=time.monotonic() + 2,
                            cancel_event=threading.Event(),
                        )

                    self.assertEqual(
                        (outcome.status, outcome.outcome_code),
                        ("applied", "component_action_requested"),
                    )
                    self.assertTrue(outcome.health.objective_restored)
                    self.assertEqual(dispatched[0][0], "request")
                    self.assertEqual(dispatched[0][1]["component"], component)
                    self.assertEqual(
                        dispatched[0][1]["recovery_generation"],
                        generation,
                    )

    def test_bridge_owner_executes_every_supported_non_app_component(self):
        class Messenger:
            def __init__(self):
                self.restarts = 0

            def recover_backend(self):
                self.restarts += 1
                return True

        class DeadThread:
            def is_alive(self):
                return False

        session_key = "project:0123456789abcdef"
        native_command = "native-command"
        session_id = opaque_identifier("session", session_key)
        command_id = opaque_identifier("command", native_command)
        messenger = Messenger()
        session = {
            "session_id": 7,
            "session_key": session_key,
            "repo_path": "/tmp/project",
            "provider": "codex",
            "thread": DeadThread(),
        }
        calls = []

        def request_json(path, payload):
            calls.append((path, payload))
            return {"orchestrator_session": {"id": 7}}

        cases = (
            ("restart_messenger", "messenger", "unhealthy"),
            ("reconnect_ipc", "messenger", "unhealthy"),
            ("reconnect_ipc", "session", "unhealthy"),
            ("restore_session_registration", "session", "unhealthy"),
            ("restore_session_registration", "orchestrator", "unhealthy"),
            ("release_dead_ownership", "session", "confirmed_dead"),
        )
        with tempfile.TemporaryDirectory() as root:
            state_path = Path(root) / "state.json"
            state_path.write_text(json.dumps({
                "relay_command_id": native_command,
                "recovery_generation": 4,
            }))
            for capability, component, liveness in cases:
                with self.subTest(capability=capability, component=component):
                    request = self._recovery_request(
                        capability,
                        component,
                        session_id,
                        command_id,
                    )
                    validation = RecoveryActionValidation(
                        validation_token="live_continuity_watch",
                        exact_target_owned=True,
                        liveness=liveness,
                        incident_active=True,
                        generation_matches=True,
                        command_phase="none",
                        command_phase_matches=True,
                        idempotency_state="new",
                        compensation_available=False,
                        cooldown_remaining=0,
                        expected_postcondition=request.expected_postcondition,
                    )
                    response = voice_bridge._bridge_continuity_recovery_response(
                        RecoveryExecutionContext(request, validation).as_dict(),
                        messenger=messenger,
                        orchestrator_session=session,
                        applied_keys=set(),
                        cooldowns={},
                        recovery_lock=threading.Lock(),
                        state_path=str(state_path),
                        turns_path=str(Path(root) / "turns.json"),
                        request_json=request_json,
                        monotonic=lambda: request.deadline - 1,
                        epoch=lambda: request.incident_observed_at,
                    )
                    self.assertEqual(response["status"], "applied")
        self.assertEqual(messenger.restarts, 2)
        self.assertEqual(len(calls), 4)

    def test_production_messenger_restart_is_provider_neutral_and_refuses_live_work(self):
        backend = _RestartableMessengerBackend()
        runtime = MessengerRuntime(
            backend,
            speak=lambda *_args, **_kwargs: None,
            is_current=lambda *_args: True,
        )
        runtime.start()
        deadline = time.time() + 1
        while backend.starts < 1 and time.time() < deadline:
            time.sleep(0.01)
        self.assertTrue(runtime.recover_backend())
        deadline = time.time() + 1
        while backend.starts < 2 and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual((backend.starts, backend.shutdowns), (2, 1))

        with runtime._lock:
            runtime._active_event = object()
        self.assertFalse(runtime.recover_backend())
        with runtime._lock:
            runtime._active_event = None
        runtime.shutdown()

    def test_uuid_generation_flows_through_real_messenger_state_and_bridge_owner(self):
        generation = "12345678-1234-4abc-8def-1234567890ab"
        stale_generation = "abcdefab-1234-4abc-8def-1234567890ab"
        session_key = "project:0123456789abcdef"
        observed = []
        with tempfile.TemporaryDirectory() as root, patch.dict(
            os.environ,
            {"RELAY_RECOVERY_GENERATION": generation},
        ):
            state_path = Path(root) / "state.json"
            command = voice_bridge._begin_relay_command(
                "private command",
                state_path=str(state_path),
                event_log_path=None,
            )
            self.assertEqual(
                json.loads(state_path.read_text())["recovery_generation"],
                generation,
            )
            command_store = orchestrator.OrchestratorCommandStore(
                Path(root) / "commands.db"
            )
            stored = command_store.record(
                repo_path=root,
                source_text="private command",
                relay_command_seq=command["relay_command_seq"],
                relay_command_id=command["relay_command_id"],
                recovery_generation=generation,
            )
            self.assertEqual(stored["recovery_generation"], generation)

            runtime = MessengerRuntime(
                _FailingMessengerBackend(),
                speak=lambda *_args, **_kwargs: None,
                is_current=lambda *_args: True,
                continuity_observer=observed.append,
                recovery_generation=generation,
            )
            runtime.start()
            runtime.submit_user("private command", command)
            deadline = time.time() + 2
            while not any(event.get("event") == "failed" for event in observed) \
                    and time.time() < deadline:
                time.sleep(0.01)
            runtime.shutdown()
            self.assertEqual(
                {event["recovery_generation"] for event in observed},
                {generation},
            )

            request = self._recovery_request(
                "restart_messenger",
                "messenger",
                opaque_identifier("session", session_key),
                opaque_identifier("command", command["relay_command_id"]),
                recovery_generation=generation,
            )
            validation = RecoveryActionValidation(
                validation_token="live_continuity_watch",
                exact_target_owned=True,
                liveness="unhealthy",
                incident_active=True,
                generation_matches=True,
                command_phase="none",
                command_phase_matches=True,
                idempotency_state="new",
                compensation_available=False,
                cooldown_remaining=0,
                expected_postcondition=request.expected_postcondition,
            )
            common = {
                "messenger": SimpleNamespace(recover_backend=lambda: True),
                "orchestrator_session": {
                    "session_key": session_key,
                    "provider": "codex",
                },
                "applied_keys": set(),
                "cooldowns": {},
                "recovery_lock": threading.Lock(),
                "state_path": str(state_path),
                "turns_path": str(Path(root) / "turns.json"),
                "monotonic": lambda: request.deadline - 1,
                "epoch": lambda: request.incident_observed_at,
            }
            response = voice_bridge._bridge_continuity_recovery_response(
                RecoveryExecutionContext(request, validation).as_dict(),
                **common,
            )
            self.assertEqual(response["status"], "applied")

            state = json.loads(state_path.read_text())
            state["recovery_generation"] = stale_generation
            state_path.write_text(json.dumps(state))
            response = voice_bridge._bridge_continuity_recovery_response(
                RecoveryExecutionContext(request, validation).as_dict(),
                **common,
            )
            self.assertEqual(response["outcome_code"], "stale_recovery_generation")

    def test_bridge_owner_rejects_stale_unrelated_and_live_work_context(self):
        session_key = "project:0123456789abcdef"
        request = self._recovery_request(
            "restart_messenger",
            "messenger",
            opaque_identifier("session", session_key),
            opaque_identifier("command", "native-command"),
        )
        validation = RecoveryActionValidation(
            validation_token="live_continuity_watch",
            exact_target_owned=True,
            liveness="unhealthy",
            incident_active=True,
            generation_matches=True,
            command_phase="none",
            command_phase_matches=True,
            idempotency_state="new",
            compensation_available=False,
            cooldown_remaining=0,
            expected_postcondition=request.expected_postcondition,
        )
        payload = RecoveryExecutionContext(request, validation).as_dict()
        with tempfile.TemporaryDirectory() as root:
            state_path = Path(root) / "state.json"
            state_path.write_text(json.dumps({
                "relay_command_id": "other-command",
                "recovery_generation": 4,
            }))
            common = {
                "messenger": SimpleNamespace(recover_backend=lambda: True),
                "orchestrator_session": {
                    "session_key": session_key,
                    "provider": "codex",
                },
                "applied_keys": set(),
                "cooldowns": {},
                "recovery_lock": threading.Lock(),
                "state_path": str(state_path),
                "turns_path": str(Path(root) / "turns.json"),
                "monotonic": lambda: request.deadline - 1,
                "epoch": lambda: request.incident_observed_at,
            }
            response = voice_bridge._bridge_continuity_recovery_response(
                payload,
                **common,
            )
            self.assertEqual(response["outcome_code"], "unrelated_command_target")

            state_path.write_text(json.dumps({
                "relay_command_id": "native-command",
                "recovery_generation": 5,
            }))
            response = voice_bridge._bridge_continuity_recovery_response(
                payload,
                **common,
            )
            self.assertEqual(response["outcome_code"], "stale_recovery_generation")

            state_path.write_text(json.dumps({
                "relay_command_id": "native-command",
                "recovery_generation": 4,
            }))
            Path(common["turns_path"]).write_text(json.dumps({
                "records": [{
                    "state": "active",
                    "relay_command_seq": 1,
                    "relay_command_id": "native-command",
                }],
            }))
            response = voice_bridge._bridge_continuity_recovery_response(
                payload,
                **common,
            )
            self.assertEqual(response["outcome_code"], "live_work_active")

    def test_capture_loss_handoff_without_command_state_reaches_canonical_tts_once(self):
        session_key = "project:0123456789abcdef"
        generation = "generation-7"
        incident = {
            "incident_id": "inc-123456789abc",
            "session_id": opaque_identifier("session", session_key),
            "command_id": None,
            "component": "speech_capture",
            "phase": "capture",
            "provider": "none",
            "recovery_generation": generation,
            "timing": {"last_observed_at": 100},
            "recovery_objective": {
                "unavailable_capability": (
                    "Relay Runner cannot capture speech for the active voice session."
                ),
                "restored_when": [
                    "capture_progress_observed",
                    "transcription_started",
                ],
            },
        }
        sent = []

        class Socket:
            def sendto(self, data, path):
                sent.append((json.loads(data), path))

            def close(self):
                return None

        daemon = Daemon.__new__(Daemon)
        with patch.object(orchestrator.socket, "socket", return_value=Socket()):
            daemon._publish_continuity_resume(incident, "restored")

        with tempfile.TemporaryDirectory() as root:
            inbox = IntentInbox(Path(root) / "inbox.sqlite3")
            self.addCleanup(inbox.close)
            state_path = Path(root) / "state.json"
            applied_keys = set()
            common = {
                "inbox": inbox,
                "tts_worker": SimpleNamespace(input_queue=object()),
                "orchestrator_session": {
                    "session_key": session_key,
                    "provider": "codex",
                },
                "applied_keys": applied_keys,
                "bridge_generation": generation,
                "state_path": str(state_path),
                "turns_path": str(Path(root) / "turns.json"),
            }
            with (
                patch.dict(os.environ, {"RELAY_RECOVERY_GENERATION": generation}),
                patch.object(voice_bridge, "_queue_tts_text", return_value=True) as queue_text,
                patch.object(voice_bridge, "_notify_state"),
            ):
                first = voice_bridge._bridge_continuity_resume_response(
                    sent[0][0],
                    **common,
                )
                duplicate = voice_bridge._bridge_continuity_resume_response(
                    sent[0][0],
                    **common,
                )

            self.assertFalse(state_path.exists())
            self.assertEqual(first["action"], "ask_repeat")
            self.assertEqual(
                duplicate,
                {"action": "noop", "reason": "handoff_already_applied"},
            )
            queue_text.assert_called_once()

            state_path.write_text(json.dumps({
                "relay_command_id": "newer-command",
                "recovery_generation": "generation-8",
            }))
            newer_incident = {**sent[0][0], "incident_id": "inc-newer-123456"}
            with patch.object(voice_bridge, "_queue_tts_text") as queue_text:
                newer = voice_bridge._bridge_continuity_resume_response(
                    newer_incident,
                    **common,
                )
            self.assertEqual(newer["reason"], "stale_recovery_generation")
            queue_text.assert_not_called()

            state_path.unlink()
            unrelated = {
                **sent[0][0],
                "incident_id": "inc-other-123456",
                "component": "bridge",
                "phase": "delivery",
            }
            with (
                patch.dict(os.environ, {"RELAY_RECOVERY_GENERATION": generation}),
                patch.object(voice_bridge, "_queue_tts_text") as queue_text,
            ):
                liveness = voice_bridge._bridge_continuity_resume_response(
                    unrelated,
                    **common,
                )
            self.assertEqual(liveness["action"], "noop")
            queue_text.assert_not_called()

    def test_daemon_owner_executes_orchestrator_and_command_recovery(self):
        with tempfile.TemporaryDirectory() as root:
            daemon = Daemon.__new__(Daemon)
            daemon.orchestrator_sessions = orchestrator.OrchestratorSessionStore(
                Path(root) / "sessions.db"
            )
            daemon.orchestrator_commands = orchestrator.OrchestratorCommandStore(
                Path(root) / "commands.db"
            )
            session = daemon.orchestrator_sessions.ensure(
                repo_path=str(Path(root) / "repo"),
                provider_key="codex",
                pid=999_999_999,
                state="failed",
            )
            native_command = "native-command"
            daemon.orchestrator_commands.record(
                repo_path=session["repo_path"],
                source_text="private",
                relay_command_seq=1,
                relay_command_id=native_command,
                session_id=int(session["id"]),
                provider_key="codex",
                status="claimed",
            )
            session_id = opaque_identifier("session", session["session_key"])
            command_id = opaque_identifier("command", native_command)

            def validation_for(request):
                return RecoveryActionValidation(
                    validation_token="live_continuity_watch",
                    exact_target_owned=True,
                    liveness="confirmed_dead",
                    incident_active=True,
                    generation_matches=True,
                    command_phase="in_flight" if request.component == "command" else "none",
                    command_phase_matches=True,
                    idempotency_state="new",
                    compensation_available=False,
                    cooldown_remaining=0,
                    expected_postcondition=request.expected_postcondition,
                )

            daemon.continuity = SimpleNamespace(
                recovery_validation=validation_for,
                recovery_health=lambda _request: orchestrator.RecoveryHealthEvidence(),
            )
            command_request = self._recovery_request(
                "release_dead_ownership",
                "command",
                session_id,
                command_id,
            )
            command_result = daemon._execute_continuity_recovery_action(
                command_request,
                validation_for(command_request),
                threading.Event(),
            )
            self.assertEqual(
                (command_result.status, command_result.outcome_code),
                ("applied", "dead_ownership_released"),
            )
            self.assertEqual(
                daemon.orchestrator_commands.get_public(native_command)["status"],
                "delivery_failed",
            )

            daemon.orchestrator_sessions.heartbeat(
                session_id=int(session["id"]), state="failed"
            )
            owner_request = self._recovery_request(
                "release_dead_ownership",
                "orchestrator",
                session_id,
                command_id,
            )
            owner_result = daemon._execute_continuity_recovery_action(
                owner_request,
                validation_for(owner_request),
                threading.Event(),
            )
            self.assertEqual(
                (owner_result.status, owner_result.outcome_code),
                ("applied", "dead_ownership_released"),
            )
            self.assertEqual(
                daemon.orchestrator_sessions.get(int(session["id"]))["state"],
                "stopped",
            )

            live_session = daemon.orchestrator_sessions.ensure(
                repo_path=str(Path(root) / "live-repo"),
                provider_key="codex",
                pid=os.getpid(),
                state="failed",
            )
            reconnect_request = self._recovery_request(
                "reconnect_ipc",
                "orchestrator",
                opaque_identifier("session", live_session["session_key"]),
                command_id,
            )
            reconnect_validation = RecoveryActionValidation(
                **{
                    **validation_for(reconnect_request).__dict__,
                    "liveness": "unhealthy",
                }
            )
            daemon.continuity.recovery_validation = lambda _request: reconnect_validation
            reconnect_result = daemon._execute_continuity_recovery_action(
                reconnect_request,
                reconnect_validation,
                threading.Event(),
            )
            self.assertEqual(
                (reconnect_result.status, reconnect_result.outcome_code),
                ("applied", "ipc_connection_restored"),
            )
            self.assertEqual(
                daemon.orchestrator_sessions.get(int(live_session["id"]))["state"],
                "idle",
            )

    def _bridge_payload(self, provider: str, signal: str, observed_at: float) -> dict:
        posted = []
        _post_continuity_event(
            "provider",
            signal,
            {
                "session_id": "native-session-secret",
                "relay_command_id": "native-command-secret",
                "provider": provider,
                "recovery_generation": 4,
                "transcript": "private transcript",
                "prompt": "private prompt",
                "repository": "/private/repository",
                "credential": "secret-token",
                "screenshot": "private-image",
                "raw_error": "raw-error-secret",
                "provider_output": "private provider output",
            },
            observed_at=observed_at,
            request_json=lambda path, payload: posted.append((path, payload)) or {},
        )
        self.assertEqual(posted[0][0], "/v1/continuity/observation")
        self.assertTrue(set(posted[0][1]).isdisjoint(FORBIDDEN_FIELDS))
        return posted[0][1]

    def test_real_bridge_provider_adapter_emits_same_safe_contract_for_codex_and_claude(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)

        for provider, signal in (("codex", "app_server_timeout"), ("claude", "timeout")):
            for observed_at in (100, 130, 131):
                adapter.observe(self._bridge_payload(provider, signal, observed_at))

        self.assertEqual(len(emitted), 2)
        self.assertEqual({item["provider"] for item in emitted}, {"codex", "claude"})
        self.assertEqual({item["component"] for item in emitted}, {"foreground_provider"})
        serialized = json.dumps(emitted, sort_keys=True)
        for forbidden in (*FORBIDDEN_FIELDS, "native-session-secret", "native-command-secret", "secret-token"):
            self.assertNotIn(forbidden, serialized)

    def test_real_relay_lifecycle_adapter_handles_bridge_messenger_daemon_and_command_events(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        base = {
            "session_id": "relay-session",
            "relay_command_id": "relay-command",
            "provider": "claude",
            "recovery_generation": 2,
        }

        self.assertEqual(adapter.observe({**base, "source": "daemon", "event": "heartbeat", "observed_at": 1}).state, "healthy")
        self.assertEqual(adapter.observe({**base, "source": "command", "event": "accepted", "observed_at": 2}).state, "healthy")
        self.assertEqual(adapter.observe({**base, "source": "bridge", "event": "delivery_failed", "observed_at": 3}).state, "transient")
        self.assertEqual(adapter.observe({**base, "source": "messenger", "event": "failed", "observed_at": 4}).state, "stalled")
        self.assertEqual(adapter.observe({**base, "source": "command", "event": "failed", "observed_at": 5}).state, "stalled")
        self.assertEqual({item["component"] for item in emitted}, {"messenger", "command"})

    def test_messenger_runtime_reports_failure_without_forwarding_raw_error(self):
        observed = []
        runtime = MessengerRuntime(
            _FailingMessengerBackend(),
            speak=lambda *_args, **_kwargs: None,
            is_current=lambda *_args: True,
            continuity_observer=observed.append,
        )
        runtime.start()
        runtime.submit_user("private user transcript", {
            "relay_command_seq": 1,
            "relay_command_id": "command-secret",
        })
        deadline = time.time() + 2
        while not any(event.get("event") == "failed" for event in observed) and time.time() < deadline:
            time.sleep(0.01)
        runtime.shutdown()

        failures = [event for event in observed if event.get("event") == "failed"]
        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0]["provider"], "claude")
        serialized = json.dumps(failures)
        self.assertNotIn("raw-error-secret", serialized)
        self.assertNotIn("private user transcript", serialized)

    def test_periodic_sampler_classifies_one_shot_production_failures_for_both_providers(self):
        provider_incidents = {}
        for provider in ("codex", "claude"):
            emitted = []
            adapter = ContinuityLifecycleAdapter(emit=emitted.append)

            def post(source, event, session_id, command_id=None):
                _post_continuity_event(
                    source,
                    event,
                    {
                        "session_id": session_id,
                        "relay_command_id": command_id,
                        "provider": provider,
                    },
                    observed_at=100,
                    request_json=lambda _path, payload: adapter.observe(payload),
                )

            post("stt", "transcription_failed", f"{provider}-stt")
            post("bridge", "delivery_failed", f"{provider}-bridge", "bridge-command")
            post("provider", "process_exit", f"{provider}-provider", "provider-command")

            daemon = Daemon.__new__(Daemon)
            daemon.workspace_root = Path(ROOT)
            daemon.agent_kind = provider
            daemon.continuity = adapter
            with patch("orchestrator.time.time", return_value=100):
                daemon._observe_command_continuity({
                    "session_id": f"{provider}-command",
                    "relay_command_id": "accepted-command",
                    "provider_key": provider,
                    "repo_path": ROOT,
                }, "accepted")

            for observed_at in (110, 111, 115, 116, 130, 131):
                daemon.sample_continuity(observed_at=observed_at)

            self.assertEqual(
                {item["component"] for item in emitted},
                {"transcription", "bridge", "foreground_provider", "command"},
            )
            self.assertTrue(all(item["timing"]["post_grace_samples"] == 2 for item in emitted))
            provider_incidents[provider] = emitted

        self.assertEqual(len(provider_incidents["codex"]), 4)
        self.assertEqual(len(provider_incidents["claude"]), 4)
        self.assertEqual(
            [item["component"] for item in provider_incidents["codex"]],
            [item["component"] for item in provider_incidents["claude"]],
        )

    def test_periodic_sampler_honors_session_and_completed_command_suppression(self):
        for terminal_event in ("explicit_stop", "update", "reset"):
            emitted = []
            adapter = ContinuityLifecycleAdapter(emit=emitted.append)
            adapter.observe({
                "source": "bridge",
                "event": "delivery_failed",
                "session_id": "suppressed-session",
                "relay_command_id": "suppressed-command",
                "provider": "codex",
                "observed_at": 100,
            })
            adapter.observe({
                "source": "session",
                "event": terminal_event,
                "session_id": "suppressed-session",
                "provider": "codex",
                "observed_at": 101,
            })
            adapter.sample(observed_at=200)
            adapter.sample(observed_at=201)
            self.assertEqual(emitted, [])

        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        for event, observed_at in (("accepted", 100), ("completed", 101)):
            adapter.observe({
                "source": "command",
                "event": event,
                "session_id": "completed-session",
                "relay_command_id": "completed-command",
                "provider": "claude",
                "observed_at": observed_at,
            })
        adapter.sample(observed_at=200)
        adapter.sample(observed_at=201)
        self.assertEqual(emitted, [])

    def test_stt_start_events_arm_real_deadlines_and_progress_clears_them(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        base = {"session_id": "stt-session", "provider": "codex"}

        adapter.observe({**base, "source": "stt", "event": "capture_started", "observed_at": 100})
        adapter.sample(observed_at=105)
        adapter.sample(observed_at=106)
        self.assertEqual([item["component"] for item in emitted], ["speech_capture"])

        emitted.clear()
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        adapter.observe({**base, "source": "stt", "event": "capture_started", "observed_at": 200})
        adapter.observe({**base, "source": "stt", "event": "transcription_started", "observed_at": 201})
        adapter.observe({
            **base,
            "source": "bridge",
            "event": "command_received",
            "relay_command_id": "stt-command",
            "observed_at": 202,
        })
        adapter.sample(observed_at=300)
        adapter.sample(observed_at=301)
        self.assertEqual(emitted, [])

    def test_production_recording_status_does_not_arm_silent_capture_deadline(self):
        emitted = []
        adapter = ContinuityLifecycleAdapter(emit=emitted.append)
        posted = []

        def post(source, event, _metadata=None, **_kwargs):
            posted.append((source, event))
            return adapter.observe({
                "source": source,
                "event": event,
                "session_id": "silent-recording-session",
                "provider": "codex",
                "observed_at": 100,
            })

        with patch.object(voice_bridge, "_post_continuity_event", side_effect=post):
            self.assertTrue(voice_bridge._handle_relay_control_message(
                "__STATUS__:recording...",
                SimpleNamespace(),
            ))

        for observed_at in (105, 106, 130, 131, 300, 301):
            adapter.sample(observed_at=observed_at)

        self.assertEqual(posted, [])
        self.assertEqual(emitted, [])

    def test_production_stt_controls_classify_dropped_capture_and_transcription(self):
        cases = (
            ("capture_failed", "speech_capture"),
            ("transcription_started", "transcription"),
            ("transcription_failed", "transcription"),
        )
        for signal, expected_component in cases:
            with self.subTest(signal=signal):
                emitted = []
                adapter = ContinuityLifecycleAdapter(emit=emitted.append)

                def post(source, event, _metadata=None, **_kwargs):
                    return adapter.observe({
                        "source": source,
                        "event": event,
                        "session_id": f"{signal}-session",
                        "provider": "claude",
                        "observed_at": 100,
                    })

                with patch.object(voice_bridge, "_post_continuity_event", side_effect=post):
                    self.assertTrue(voice_bridge._handle_relay_control_message(
                        f"__CONTINUITY__:{signal}",
                        SimpleNamespace(),
                    ))

                adapter.sample(observed_at=130)
                self.assertEqual(emitted, [])
                adapter.sample(observed_at=131)
                self.assertEqual(
                    [item["component"] for item in emitted],
                    [expected_component],
                )
                self.assertEqual(emitted[0]["provider"], "none")

    def test_codex_and_claude_prompt_hooks_arm_provider_deadlines(self):
        for provider, expected_signal in (("codex", "turn_started"), ("claude", "stream_started")):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                claim_path = root / "claim.json"
                state_path = root / "state.json"
                turns_path = root / "turns.json"
                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"{provider}-command",
                    "source_text": "private command",
                    "agent_prompt": "private prompt",
                    "provider": provider,
                }
                claim_path.write_text(json.dumps(command))
                state_path.write_text(json.dumps(command))
                hook_events = []
                environment = {
                    "RELAY_APP_SESSION_ID": "app-session",
                    "RELAY_RECOVERY_GENERATION": "4",
                    "RELAY_ACTOR_ROLE": "foreground_pm",
                    "RELAY_FOREGROUND_GATE_HANDLE": "gate",
                    "RELAY_RUNNER_PROVIDER": provider,
                }
                with patch.dict(os.environ, environment, clear=False), patch.object(
                    relay_completion_hook,
                    "PROVIDER_TURN_BROKER_MODE",
                    "legacy",
                ):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "UserPromptSubmit",
                            "prompt": "private prompt",
                            "session_id": f"native-{provider}-session",
                        },
                        claim_path=str(claim_path),
                        state_path=str(state_path),
                        turns_path=str(turns_path),
                        write_provider_event=lambda event: hook_events.append(event) or True,
                        now=100,
                    ))

                posted = []
                with patch.object(
                    voice_bridge,
                    "_post_continuity_event",
                    side_effect=lambda source, event, metadata, **_kwargs: posted.append(
                        {**metadata, "source": source, "event": event, "session_id": "project:canonical"}
                    ) or {},
                ):
                    self.assertTrue(voice_bridge._handle_provider_turn_event_control(
                        json.dumps(hook_events[0]),
                        provider_turn_broker=None,
                    ))
                self.assertEqual(posted[0]["event"], expected_signal)

                emitted = []
                adapter = ContinuityLifecycleAdapter(emit=emitted.append)
                adapter.observe(posted[0])
                adapter.sample(observed_at=130)
                adapter.sample(observed_at=131)
                self.assertEqual([item["component"] for item in emitted], ["foreground_provider"])
                self.assertEqual(emitted[0]["provider"], provider)

    def test_codex_and_claude_output_progress_keeps_long_production_turns_healthy(self):
        signals = {
            "codex": ("turn_started", "turn_progress", "turn_completed"),
            "claude": ("stream_started", "stream_progress", "result_success"),
        }
        for provider, expected_signals in signals.items():
            with self.subTest(provider=provider):
                emitted = []
                posted = []
                adapter = ContinuityLifecycleAdapter(emit=emitted.append)

                def post_control(event, observed_at):
                    with patch.object(
                        voice_bridge,
                        "_post_continuity_event",
                        side_effect=lambda source, signal, metadata, **_kwargs: posted.append({
                            **metadata,
                            "source": source,
                            "event": signal,
                            "session_id": "project:canonical",
                            "observed_at": observed_at,
                        }) or adapter.observe(posted[-1]),
                    ):
                        self.assertTrue(voice_bridge._handle_provider_turn_event_control(
                            json.dumps({
                                "event": event,
                                "provider": provider,
                                "relay_command_id": f"{provider}-long-command",
                                "recovery_generation": 4,
                                "observed_at": observed_at,
                            }),
                            provider_turn_broker=None,
                        ))

                post_control("provider_started", 100)
                adapter.sample(observed_at=124)
                post_control("provider_progress", 125)
                adapter.sample(observed_at=149)
                post_control("provider_progress", 150)
                adapter.sample(observed_at=174)
                adapter.observe({
                    "source": "provider",
                    "event": expected_signals[2],
                    "session_id": "project:canonical",
                    "relay_command_id": f"{provider}-long-command",
                    "provider": provider,
                    "recovery_generation": 4,
                    "observed_at": 175,
                })
                adapter.sample(observed_at=250)
                adapter.sample(observed_at=251)

                self.assertEqual(
                    [event["event"] for event in posted],
                    list(expected_signals[:2]) + [expected_signals[1]],
                )
                self.assertEqual(emitted, [])

    def test_bridge_uses_canonical_session_identity_for_stop_update_and_reset(self):
        posted = []
        with patch.object(voice_bridge, "_CONTINUITY_SESSION_NATIVE_ID", "project:canonical"):
            _post_continuity_event(
                "stt",
                "capture_started",
                {"app_session_id": "unrelated-app-session"},
                observed_at=100,
                request_json=lambda _path, payload: posted.append(payload) or {},
            )
        self.assertEqual(posted[0]["session_id"], "project:canonical")

        for terminal_event in ("explicit_stop", "update", "reset"):
            emitted = []
            adapter = ContinuityLifecycleAdapter(emit=emitted.append)
            adapter.observe(posted[0])
            adapter.observe({
                "source": "session",
                "event": terminal_event,
                "session_id": "project:canonical",
                "provider": "codex",
                "observed_at": 101,
            })
            adapter.sample(observed_at=200)
            adapter.sample(observed_at=201)
            self.assertEqual(emitted, [])

    def test_codex_and_claude_terminal_hooks_clear_provider_start_deadlines_even_when_stale(self):
        signals = {"codex": "turn_completed", "claude": "result_success"}
        for provider, expected_signal in signals.items():
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = Path(temp_dir) / "state.json"
                state_path.write_text(json.dumps({
                    "relay_command_seq": 2,
                    "relay_command_id": "newer-command",
                }))
                posted = []
                with patch.object(
                    voice_bridge,
                    "_post_continuity_event",
                    side_effect=lambda source, event, metadata, **_kwargs: posted.append({
                        **metadata,
                        "source": source,
                        "event": event,
                        "session_id": "project:canonical",
                        "observed_at": 101,
                    }) or {},
                ):
                    self.assertFalse(voice_bridge._handle_provider_completion_control(
                        json.dumps({
                            "event": "Stop",
                            "provider": provider,
                            "relay_command_seq": 1,
                            "relay_command_id": f"{provider}-command",
                        }),
                        tts_worker=SimpleNamespace(),
                        messenger=None,
                        state_path=str(state_path),
                    ))
                self.assertEqual(posted[0]["event"], expected_signal)

                emitted = []
                adapter = ContinuityLifecycleAdapter(emit=emitted.append)
                adapter.observe({
                    "source": "provider",
                    "event": "turn_started" if provider == "codex" else "stream_started",
                    "session_id": "project:canonical",
                    "relay_command_id": f"{provider}-command",
                    "provider": provider,
                    "observed_at": 100,
                })
                adapter.observe(posted[0])
                adapter.sample(observed_at=200)
                adapter.sample(observed_at=201)
                self.assertEqual(emitted, [])

    def test_production_terminal_command_paths_clear_accepted_deadlines(self):
        class CommandStore:
            def update_status(self, command_id, **fields):
                return {**command, "relay_command_id": command_id, **fields}

        cases = {
            "stale": None,
            "direct_clarification": SimpleNamespace(kind="update_ticket", ticket_id="RR-1"),
            "canceled": SimpleNamespace(kind="control", ticket_id=None),
            "completed": SimpleNamespace(kind="create_ticket", ticket_id=None),
        }
        for label, action in cases.items():
            with self.subTest(path=label):
                emitted = []
                adapter = ContinuityLifecycleAdapter(emit=emitted.append)
                daemon = Daemon.__new__(Daemon)
                daemon.workspace_root = Path(ROOT)
                daemon.agent_kind = "codex"
                daemon.continuity = adapter
                daemon.orchestrator_commands = CommandStore()
                daemon._heartbeat_command_session = lambda *_args, **_kwargs: None
                daemon._notify_command_outcome = lambda *_args, **_kwargs: None
                daemon._author_ticket_for_command = lambda *_args, **_kwargs: {"status": "authored"}
                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"{label}-command",
                    "intent_id": f"{label}-command",
                    "session_id": "project:canonical",
                    "provider_key": "codex",
                    "repo_path": ROOT,
                    "source_text": "private command",
                    "lifecycle_state": "cancelled" if label == "canceled" else "accepted",
                }
                with patch("orchestrator.time.time", return_value=100):
                    daemon._observe_command_continuity(command, "accepted")
                with patch("orchestrator._relay_command_current", return_value=label != "stale"), patch(
                    "orchestrator.authorization_exists",
                    return_value=False,
                ), patch("orchestrator.resolve_command_action", return_value=action):
                    daemon._process_orchestrator_command(command)
                adapter.sample(observed_at=200)
                adapter.sample(observed_at=201)
                self.assertEqual(emitted, [])


if __name__ == "__main__":
    unittest.main()
