from __future__ import annotations

import json
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
from continuity_recovery import RecoveryActionRequest  # noqa: E402
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


class ContinuityIntegrationTests(unittest.TestCase):
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
