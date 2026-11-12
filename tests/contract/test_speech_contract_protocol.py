"""Speech service contract: the process, the wire and the surfaces it owns.

Sections "Process", "Transport", "Ordering", "Session", "Diagnostics",
"Surfaces the service owns" and "Test mode" of
docs/specs/speech-service-protocol.md.
"""

from __future__ import annotations

import fcntl
import json
import os
import shlex
import signal
import stat
import subprocess
import time
import unittest

from speech_contract_support import (
    LONG,
    LONG_SENTENCES,
    MS_PER_CHAR,
    PROTOCOL_VERSION,
    SHORT,
    WAIT_SECONDS,
    Connection,
    Sandbox,
    SpeechCase,
    wait_until,
)

MAX_LINE_BYTES = 1024 * 1024
IDLE = {"speaking": False, "playing": False, "held": False, "queue_depth": 0, "queue": []}


def process_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


class ProcessTests(unittest.TestCase):
    """Process: the socket, the one connection and how the service ends."""

    def setUp(self):
        self.box = Sandbox(self)

    def test_socket_is_private_and_removed_once_the_client_connected(self):
        """The socket is the owner's only; after accepting, its path is removed."""
        self.box.spawn()
        wait_until(lambda: os.path.exists(self.box.socket_path), message="the service socket")
        mode = os.stat(self.box.socket_path).st_mode
        self.assertTrue(stat.S_ISSOCK(mode))
        self.assertEqual(stat.S_IMODE(mode), 0o600)

        conn = self.box.connect()
        conn.hello()

        wait_until(lambda: not os.path.exists(self.box.socket_path), message="the socket path to go")
        # One connection for its whole life: nobody else can reach the service.
        with self.assertRaises(OSError):
            Connection(self.box.socket_path)
        self.assertIsNone(self.box.process.poll())

    def test_leftover_file_at_the_socket_path_is_replaced(self):
        """The service "removes a leftover file at that path"."""
        with open(self.box.socket_path, "w") as leftover:
            leftover.write("stale")
        conn = self.box.start()
        self.assertEqual(conn.request("status"), IDLE)

    def test_exits_1_when_it_cannot_listen(self):
        """Status 1 "when it cannot listen on the socket path"."""
        self.box.socket_path = str(self.box.root / "missing-folder" / "speech.sock")
        self.box.spawn()
        self.assertEqual(self.box.wait_exit(), 1)
        self.assertTrue(self.box.stderr().strip(), "the reason goes to stderr")

    def test_socket_defaults_to_the_environment_variable(self):
        """`--socket` "defaults to `RELAY_SPEECH_SERVICE_SOCK`"."""
        command = [argument for argument in self.box.command() if argument not in ("--socket", self.box.socket_path)]
        self.box.command = lambda: command
        self.box.spawn(RELAY_SPEECH_SERVICE_SOCK=self.box.socket_path)
        self.assertEqual(self.box.connect().hello()["protocol"], PROTOCOL_VERSION)

    def test_signals_end_the_service_with_status_0(self):
        """Exit 0 on `SIGTERM` or `SIGINT`, after stopping speech and releasing its sockets."""
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name):
                box = Sandbox(self)
                conn = box.start()
                box.set_command(1, "command-1")
                conn.request("speak", text=LONG, command_seq=1, command_id="command-1", kind="final")
                conn.request("play")
                conn.wait_event("playback", phase="started")
                self.assertTrue(os.path.exists(box.control_path))

                box.process.send_signal(signum)

                self.assertEqual(box.wait_exit(), 0)
                self.assertFalse(os.path.exists(box.control_path))
                self.assertFalse(box.spoken()[-1][1], "the reply was not cut off")
                self.assertEqual(len(box.playback("output_stopped")), len(box.playback("output_started")))
                wait_until(conn.closed.is_set, message="the connection to close")

    def test_signal_before_a_client_connects_ends_the_service(self):
        self.box.spawn()
        wait_until(lambda: os.path.exists(self.box.socket_path), message="the service socket")
        self.box.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.box.wait_exit(), 0)
        self.assertFalse(os.path.exists(self.box.socket_path))

    def test_exits_when_its_parent_exits(self):
        """Exit "when its parent process exits", here before any client connected."""
        # The shell starts the service, waits for its socket and exits, which
        # leaves the service without the parent that started it.
        script = (
            f"{shlex.join(self.box.command())} </dev/null >/dev/null 2>&1 & pid=$!\n"
            f"while [ ! -S {shlex.quote(self.box.socket_path)} ]; do sleep 0.02; done\n"
            "echo $pid\n"
        )
        launcher = subprocess.run(
            ["/bin/sh", "-c", script], env=self.box.env(), capture_output=True, text=True, timeout=WAIT_SECONDS,
        )
        pid = int(launcher.stdout)
        self.addCleanup(lambda: process_gone(pid) or os.kill(pid, signal.SIGKILL))

        wait_until(lambda: process_gone(pid), message="the orphaned service to exit")
        self.assertFalse(os.path.exists(self.box.socket_path))

    def test_stdout_is_unused(self):
        conn = self.box.start()
        self.box.set_command(1, "command-1")
        conn.request("speak", text=SHORT, command_seq=1, command_id="command-1", kind="final")
        conn.request("play")
        conn.wait_event("playback", phase="completed")
        conn.request("shutdown")
        self.assertEqual(self.box.wait_exit(), 0)
        self.assertEqual(self.box.stdout_path.read_bytes(), b"")


class TransportTests(SpeechCase):
    """Transport: requests, responses and the errors of a bad line."""

    def setUp(self):
        self.box = Sandbox(self)
        self.box.spawn()
        self.conn = self.box.connect()
        self.commands = 0

    def error_code(self, op: str, **params) -> str:
        response = self.conn.exchange(op, **params)
        self.assertFalse(response["ok"])
        self.assertNotIn("result", response)
        self.assertIsInstance(response["error"]["message"], str)
        return response["error"]["code"]

    def test_hello_is_required_first(self):
        """Every request except `hello` fails with `hello_required` until `hello` succeeded."""
        for op in ("status", "speak", "play", "shutdown", "no_such_op"):
            with self.subTest(op=op):
                self.assertEqual(self.error_code(op), "hello_required")
        # Nothing is sent to a client that has not said hello.
        self.assertEqual(self.conn.events, [])
        self.assertIsNone(self.box.process.poll(), "a refused shutdown ended the service")

        self.conn.hello()
        self.assertEqual(self.conn.request("status"), IDLE)

    def test_hello_names_the_service(self):
        """`hello`: `protocol`, `service`, `instance_id`, `pid`, `test_mode`."""
        hello = self.conn.hello()
        self.assertEqual(hello["protocol"], PROTOCOL_VERSION)
        self.assertIsInstance(hello["service"], str)
        self.assertTrue(hello["service"])
        self.assertIsInstance(hello["instance_id"], str)
        self.assertTrue(hello["instance_id"])
        self.assertIsInstance(hello["pid"], int)
        self.assertIs(hello["test_mode"], True)

    def test_another_protocol_version_is_refused(self):
        """`hello`: `protocol` "must be `1`"."""
        for version in (PROTOCOL_VERSION + 1, 0, "1", None):
            with self.subTest(version=version):
                self.assertEqual(self.error_code("hello", protocol=version), "unsupported_protocol")
        self.assertEqual(self.error_code("status"), "hello_required")
        self.assertEqual(self.conn.hello()["protocol"], PROTOCOL_VERSION)

    def test_unknown_request_is_refused(self):
        self.conn.hello()
        self.assertEqual(self.error_code("no_such_op"), "unknown_op")
        self.assertEqual(self.conn.request("status"), IDLE)

    def test_missing_or_malformed_field_is_an_invalid_request(self):
        """`invalid_request`: "a required field is missing or has the wrong type"."""
        self.conn.hello()
        for op, params in (
            ("new_turn", {}),
            ("new_turn", {"command_seq": "soon", "command_id": "command-1"}),
            ("arm_waiting_playback", {"command_seq": 1}),
            ("played_coverage", {"command_id": "command-1"}),
            ("note_visual_acknowledgement", {"option_detected_at": 1.0}),
            ("record_realization", {"command_id": "command-1"}),
            ("record_missing_outcome", {"reason": "no_reply"}),
        ):
            with self.subTest(op=op, params=params):
                self.assertEqual(self.error_code(op, **params), "invalid_request")
        self.assertEqual(self.conn.request("status"), IDLE)

    def test_error_messages_never_contain_reply_text(self):
        """"Error messages never contain reply text"."""
        self.conn.hello()
        secret = "The password is tangerine."
        response = self.conn.exchange("speak", text=secret, command_seq="soon", command_id="command-1")
        self.assertFalse(response["ok"])
        self.assertNotIn("tangerine", json.dumps(response))
        self.assertNotIn("tangerine", self.box.stderr())

    def test_request_id_is_echoed(self):
        """A request id is a number or a string; the response carries the same."""
        self.conn.hello()
        for request_id in ("request-a", 7, 0, "7"):
            with self.subTest(request_id=request_id):
                response = self.conn.exchange("status", request_id=request_id)
                self.assertEqual(response, {"id": request_id, "ok": True, "result": IDLE})

    def test_unknown_fields_are_ignored(self):
        self.conn.hello()
        self.box.set_command(1, "command-1")
        result = self.conn.request(
            "speak", text=SHORT, command_seq=1, command_id="command-1", kind="final", added_in_a_later_version=[1, 2],
        )
        self.assertTrue(result["accepted"])
        self.assertEqual(self.conn.request("status", verbose=True)["queue_depth"], 1)

    def test_null_means_the_default(self):
        """Intent fields: "`null` and absent mean the default"."""
        self.conn.hello()
        result = self.conn.request(
            "speak", text=SHORT, command_seq=None, command_id=None, kind=None, source=None,
            display_text=None, priority=None, dedup_key=None, utterance_id=None, expires_at=None,
            session_key=None, replayable=None, work_disposition=None, waiting_playback_kind=None,
        )
        self.assertTrue(result["accepted"])
        self.assertTrue(result["utterance_id"])
        queued = self.conn.wait_event("playback", phase="queued")
        self.assertEqual((queued["kind"], queued["source"], queued["session_key"]), ("fallback", "fallback", ""))

    def test_line_that_is_not_a_message_is_reported_and_skipped(self):
        """`invalid_message`: the line is skipped and the connection stays open."""
        self.conn.hello()
        for count, line in enumerate(
            (b"this is not json\n", b"[1, 2, 3]\n", b'"text"\n', b'{"op": "status"}\n', b'{"id": 4}\n', b"\n"),
            start=1,
        ):
            self.conn.send(line)
            wait_until(
                lambda: len(self.conn.events_named("error", code="invalid_message")) == count,
                message=f"the error for {line!r}",
            )
        self.assertEqual(self.conn.request("status"), IDLE)

    def test_bad_line_before_hello_is_reported(self):
        self.conn.send(b"this is not json\n")
        self.assertEqual(self.conn.wait_event("error"), {"event": "error", "code": "invalid_message"})
        self.assertEqual(self.conn.hello()["protocol"], PROTOCOL_VERSION)

    def test_line_over_the_limit_is_skipped(self):
        """"A line is at most 1 MiB"; a longer one produces `line_too_long`."""
        self.conn.hello()
        request = json.dumps({"id": "long", "op": "speak", "text": "x" * (2 * MAX_LINE_BYTES)})
        self.conn.send(request.encode("utf-8") + b"\n")
        self.assertEqual(self.conn.wait_event("error"), {"event": "error", "code": "line_too_long"})
        self.assertEqual(self.conn.request("status"), IDLE, "the long request was applied")

    def test_line_at_the_limit_is_accepted(self):
        self.conn.hello()
        padding = MAX_LINE_BYTES - len(json.dumps({"id": "full", "op": "status", "padding": ""})) - 1
        line = json.dumps({"id": "full", "op": "status", "padding": "x" * padding}).encode("utf-8") + b"\n"
        self.assertEqual(len(line), MAX_LINE_BYTES)
        self.conn.send(line)
        wait_until(lambda: [m for m in self.conn.responses() if m["id"] == "full"], message="the response")
        self.assertEqual(self.conn.events_named("error"), [])

    def test_reply_to_no_call_is_ignored(self):
        self.conn.hello()
        self.conn.send({"reply": 99, "ok": True, "result": {}})
        self.assertEqual(self.conn.request("status"), IDLE)
        self.assertEqual(self.conn.events_named("error"), [])


class OrderingTests(SpeechCase):
    """Ordering: what a client may rely on between messages."""

    def test_responses_come_in_request_order(self):
        """Ordering 1: one response per request, in request order."""
        self.box.set_command(1, "command-1")
        requests = []
        for number in range(40):
            requests.append({"id": f"speak-{number}", "op": "speak", "text": f"Reply {number}.",
                             "dedup_key": f"reply-{number}"})
            requests.append({"id": f"status-{number}", "op": "status"})
        self.conn.send(b"".join(json.dumps(request).encode("utf-8") + b"\n" for request in requests))

        responses = wait_until(
            lambda: len(self.conn.responses()) == len(requests) + 1 and self.conn.responses(),
            message="every response",
        )[1:]

        self.assertEqual([response["id"] for response in responses], [request["id"] for request in requests])
        # Applied one at a time: each status sees exactly the speaks before it.
        depths = [response["result"]["queue_depth"] for response in responses if response["id"].startswith("status")]
        self.assertEqual(depths, list(range(1, 41)))

    def test_first_state_comes_before_the_hello_response(self):
        """Ordering 2: "The first `state` event is sent before the response to `hello`"."""
        self.assertEqual(self.conn.messages[0], {"event": "state", **IDLE})
        self.assertEqual(self.conn.messages[1]["result"], self.box.hello)

    def test_state_comes_before_the_response_of_the_request_that_changed_it(self):
        """Ordering 2: a `state` event precedes that request's response."""
        utterance_id = self.speak()
        speak_at = next(
            index for index, message in enumerate(self.conn.messages)
            if message.get("result", {}).get("utterance_id") == utterance_id
        )
        state = self.conn.messages[speak_at - 1]
        self.assertEqual(state.get("event"), "state", self.conn.messages)
        self.assertEqual(state["queue"], [{"utterance_id": utterance_id, "original_utterance_id": utterance_id}])

        self.wait_phase(utterance_id, "queued")
        before = len(self.conn.messages)
        self.conn.request("pause")
        self.assertEqual(self.conn.messages[before]["event"], "state")
        self.assertTrue(self.conn.messages[before]["held"])
        self.assertIn("id", self.conn.messages[before + 1])

    def test_state_is_sent_only_when_it_changed(self):
        """Ordering 3: "snapshots sent only when the snapshot changed"."""
        self.speak()
        before = len(self.conn.events_named("state"))
        for _ in range(5):
            self.conn.request("status")
            self.conn.request("session_playback_states")
        time.sleep(0.5)
        states = self.conn.events_named("state")
        self.assertEqual(len(states), before)
        for earlier, later in zip(states, states[1:]):
            self.assertNotEqual(earlier, later)

    def test_status_is_the_last_state_sent(self):
        """`status` returns the `state` snapshot."""
        self.speak(LONG)
        self.conn.request("play")
        self.conn.wait_event("playback", phase="started")
        wait_until(
            lambda: {key: value for key, value in self.conn.events_named("state")[-1].items() if key != "event"}
            == self.status(),
            message="the state event to match status",
        )

    def test_change_made_by_no_request_is_reported(self):
        """Ordering 3: a datagram on the control socket is reported "within a fraction of a second"."""
        utterance_id = self.speak(LONG)
        self.box.control("play")
        playing = wait_until(
            lambda: [state for state in self.conn.events_named("state") if state["playing"]],
            timeout=2.0,
            message="the state event for the control socket's play",
        )[0]
        self.assertEqual(playing["queue"][0]["utterance_id"], utterance_id)

    def test_playback_events_of_different_utterances_keep_their_order(self):
        """Ordering 4: lifecycle order per utterance, time order across utterances."""
        first = self.speak("First reply.")
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "completed")
        self.wait_phase(second, "queued")
        events = [(event["utterance_id"], event["phase"]) for event in self.conn.events_named("playback")]
        self.assertEqual(events[-2:], [(first, "completed"), (second, "queued")])
        self.assertEqual(events[0], (first, "queued"))


class SessionRequestTests(SpeechCase):
    """Session: `status`, `reload_config` and `shutdown`."""

    def test_reload_config_changes_the_rate_and_restarts_the_reply(self):
        """`reload_config`: a changed rate stops the playback; the reply returns to the head."""
        utterance_id = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.box.configure(rate=2.0)

        self.conn.request("reload_config")

        ended = self.wait_phase(utterance_id, "cancelled")
        requeued = ended["requeued_as"]
        self.assertTrue(requeued)
        self.wait_phase(requeued, "queued")
        self.assertEqual(self.queue(), [utterance_id])
        self.assertFalse(self.status()["held"])
        before = len(self.box.playback("chunk_started"))
        self.conn.request("play")
        self.wait_phase(requeued, "started")
        again = wait_until(lambda: self.box.playback("chunk_started")[before:], message="the reply again")[0]
        self.assertEqual((again["text"], again["rate"]), (LONG_SENTENCES[0], 2.0))

    def test_reload_config_without_a_change_leaves_the_reply_playing(self):
        utterance_id = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.conn.request("reload_config")
        self.assertStays(lambda: self.status()["playing"], 0.2, "the reply stopped")

    def test_reload_config_turns_auto_play_on(self):
        """`reload_config` re-reads `auto_play`."""
        self.box.configure(auto_play=True)
        self.conn.request("reload_config")
        utterance_id = self.speak()
        self.wait_phase(utterance_id, "completed")

    def test_shutdown_stops_speech_answers_and_exits(self):
        """`shutdown`: "Stops speech, answers, then exits 0"."""
        utterance_id = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")

        self.assertEqual(self.conn.exchange("shutdown", request_id="bye"), {"id": "bye", "ok": True, "result": {}})

        self.assertEqual(self.box.wait_exit(), 0)
        wait_until(self.conn.closed.is_set, message="the connection to close")
        self.assertFalse(self.box.spoken()[-1][1], "the reply was not cut off")
        self.assertLess(len(self.box.spoken()), len(LONG_SENTENCES))
        self.assertFalse(os.path.exists(self.box.control_path))
        self.assertFalse(os.path.exists(self.box.socket_path))
        # The overlay is told the reply is no longer speaking.
        wait_until(lambda: self.box.datagrams[-1]["state"] == "idle", message="the idle datagram")


class DiagnosticsTests(SpeechCase):
    """Diagnostics: coverage and the records a client adds to the event log."""

    def test_played_coverage_lists_what_finished_playing(self):
        command = self.new_command()
        params = {"command_seq": command[0], "command_id": command[1]}
        handoff = self.speak(
            "Looking into the build.", command=command, kind="handoff", source="messenger",
            authoritative=False, covered_facts=["build is being checked"],
        )
        self.assertEqual(self.conn.request("played_coverage", **params), {"coverage": []})
        self.conn.request("play")
        self.wait_phase(handoff, "completed")
        final = self.speak("The build passed.", command=command)
        self.conn.request("play")
        self.wait_phase(final, "completed")

        coverage = self.conn.request("played_coverage", **params)["coverage"]

        self.assertEqual(coverage, [
            {
                "utterance_id": handoff,
                "lifecycle_role": "acknowledgement",
                "covered_facts": ["build is being checked"],
                "spoken_text": "Looking into the build.",
            },
            {
                "utterance_id": final,
                "lifecycle_role": "result",
                "covered_facts": ["The build passed."],
                "spoken_text": "The build passed.",
            },
        ])
        other = self.conn.request("played_coverage", command_seq=99, command_id="command-99")
        self.assertEqual(other, {"coverage": []})

    def test_stopped_reply_is_not_covered(self):
        command = self.new_command()
        utterance_id = self.speak(LONG, command=command)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.conn.request("skip")
        self.wait_phase(utterance_id, "cancelled")
        coverage = self.conn.request("played_coverage", command_seq=command[0], command_id=command[1])
        self.assertEqual(coverage, {"coverage": []})

    def test_play_gesture_timing_is_recorded(self):
        """`note_play_control` and `note_visual_acknowledgement`."""
        command = self.new_command()
        self.speak(command=command)
        now = time.time()

        self.conn.request("note_play_control", option_detected_at=now - 0.05, fifo_received_at=now)
        self.conn.request("note_visual_acknowledgement", option_detected_at=now - 0.05, acknowledged_at=now + 0.01)

        detected = self.box.logged("option_detected")[0]
        received = self.box.logged("fifo_play_received")[0]
        acknowledged = self.box.logged("visual_play_acknowledged")[0]
        self.assertEqual(detected["at"], now - 0.05)
        self.assertEqual((detected["relay_command_seq"], detected["relay_command_id"]), command)
        self.assertAlmostEqual(received["option_to_fifo_ms"], 50, delta=1)
        self.assertEqual(received["play_request_id"], detected["play_request_id"])
        self.assertEqual(acknowledged["play_request_id"], detected["play_request_id"])
        self.assertAlmostEqual(acknowledged["option_to_ack_ms"], 60, delta=1)

    def test_note_play_control_needs_no_fields(self):
        self.conn.request("note_play_control")
        self.assertEqual(len(self.box.logged("fifo_play_received")), 1)

    def test_realization_is_recorded(self):
        self.conn.request(
            "record_realization", command_seq=3, command_id="command-3",
            lifecycle_role="progress", decision="suppress", reason="already_covered",
        )
        record = self.box.logged("realization")[0]
        self.assertEqual(
            {key: record[key] for key in (
                "relay_command_seq", "relay_command_id", "lifecycle_role",
                "realization_decision", "suppression_reason",
            )},
            {
                "relay_command_seq": 3, "relay_command_id": "command-3", "lifecycle_role": "progress",
                "realization_decision": "suppress", "suppression_reason": "already_covered",
            },
        )

    def test_messenger_stage_is_recorded(self):
        self.conn.request(
            "record_messenger_stage", stage="messenger_submitted", command_seq=3, command_id="command-3",
            at=1700000000.5, provider="Claude",
        )
        self.conn.request(
            "record_messenger_stage", stage="messenger_failed", command_seq=3, command_id="command-3",
            provider="another", outcome="timeout",
        )
        submitted = self.box.logged("messenger_submitted")[0]
        failed = self.box.logged("messenger_failed")[0]
        self.assertEqual((submitted["at"], submitted["provider"], submitted["outcome"]), (1700000000.5, "claude", "ok"))
        self.assertEqual((failed["provider"], failed["outcome"]), (None, "timeout"))
        self.assertEqual((failed["relay_command_seq"], failed["relay_command_id"]), (3, "command-3"))

    def test_missing_outcome_is_recorded_once_per_command(self):
        """`record_missing_outcome`: `recorded` is `false` the second time."""
        params = {"command_seq": 3, "command_id": "command-3", "reason": "turn_ended"}
        first = self.conn.request("record_missing_outcome", signals=["stop_hook", "idle", "stop_hook"], **params)
        second = self.conn.request("record_missing_outcome", **params)
        self.assertEqual((first, second), ({"recorded": True}, {"recorded": False}))
        records = self.box.logged("missing_outcome")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["reason"], "turn_ended")
        self.assertEqual(records[0]["signals"], ["idle", "stop_hook"])

    def test_missing_outcome_is_not_recorded_for_a_command_with_a_reply(self):
        """`record_missing_outcome`: `false` "when the command has an accepted reply"."""
        command = self.new_command()
        self.speak(command=command)
        result = self.conn.request(
            "record_missing_outcome", command_seq=command[0], command_id=command[1], reason="turn_ended",
        )
        self.assertEqual(result, {"recorded": False})
        self.assertEqual(self.box.logged("missing_outcome"), [])


class OwnedSurfaceTests(SpeechCase):
    """Surfaces the service owns: control socket, state datagrams, event log, audio lease."""

    def test_control_socket_plays_pauses_skips_and_replays(self):
        """`TTS_CONTROL_SOCK`: `play`, `toggle`, `replay`, `skip`, `cancel`, `pause`, `stop`."""
        first = self.speak(LONG)
        self.box.control("play")
        self.wait_phase(first, "started")

        self.box.control("pause")
        requeued = self.wait_phase(first, "cancelled")["requeued_as"]
        wait_until(lambda: self.status()["held"], message="the queue to be held")

        self.box.control("toggle")
        self.wait_phase(requeued, "started")

        self.box.control("stop")
        again = self.wait_phase(requeued, "cancelled")["requeued_as"]
        wait_until(lambda: self.status()["held"], message="the queue to be held")

        self.box.control("PLAY\n")
        self.wait_phase(again, "started")
        self.box.control("skip")
        self.assertEqual(self.wait_phase(again, "cancelled")["stop_reason"], "user_stop")
        self.wait_idle()

        self.box.control("replay")
        replay = self.conn.wait_event("playback", phase="started", replay_of=first)
        self.box.control("cancel")
        self.wait_phase(replay["utterance_id"], "cancelled")
        self.wait_idle()

        self.box.control("no-such-command")
        self.assertStays(lambda: not self.status()["speaking"], 0.2)

    def test_state_datagrams_follow_a_reply(self):
        """State datagrams: `message_waiting`, `preparing`, `speaking`, `idle`."""
        command = self.new_command()
        utterance_id = self.speak(
            "Reply as spoken.", command=command, display_text="Reply as shown.", session_key="session-a",
        )
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        wait_until(lambda: self.box.datagrams and self.box.datagrams[-1]["state"] == "idle", message="idle")

        datagrams = list(self.box.datagrams)
        self.assertEqual(
            [datagram["state"] for datagram in datagrams], ["message_waiting", "preparing", "speaking", "idle"]
        )
        for datagram in datagrams:
            self.assertEqual(datagram["source"], "tts")
            self.assertEqual(datagram["utterance_id"], utterance_id)
            self.assertEqual(datagram["original_utterance_id"], utterance_id)
            self.assertEqual(datagram["relay_command_seq"], command[0])
            self.assertEqual(datagram["relay_command_id"], command[1])
            self.assertEqual(datagram["session_key"], "session-a")
        # The overlay shows the display text, never the spoken one.
        self.assertEqual([datagram.get("text") for datagram in datagrams[:3]], ["Reply as shown."] * 3)

    def test_skipped_waiting_reply_ends_with_idle(self):
        """State datagrams: the overlay is told when a waiting reply is dismissed."""
        utterance_id = self.speak()
        self.wait_phase(utterance_id, "queued")
        self.conn.request("skip")
        self.wait_phase(utterance_id, "cancelled")
        wait_until(lambda: self.box.datagrams[-1]["state"] == "idle", message="the idle datagram")
        self.assertEqual([d["state"] for d in self.box.datagrams][0], "message_waiting")

    def test_long_text_is_shortened_to_fit_a_datagram(self):
        """"A datagram is at most 2048 bytes; longer text is shortened"."""
        text = " ".join(["A long reply that goes on."] * 200)
        self.speak(text)
        waiting = wait_until(
            lambda: [d for d in self.box.datagrams if d["state"] == "message_waiting"],
            message="the waiting datagram",
        )[0]
        self.assertTrue(waiting["text"].endswith("…"))
        self.assertTrue(text.startswith(waiting["text"][:-1]))
        self.assertLessEqual(len(json.dumps(waiting).encode("utf-8")), 2048)
        self.assertGreater(len(waiting["text"]), 1000)

    def test_event_log_records_every_stage_without_reply_text(self):
        """`SPEECH_EVENT_LOG`: one record per proposal, decision and stage; never reply text."""
        command = self.new_command()
        utterance_id = self.speak("The password is tangerine.", command=command, display_text="Shown tangerine.")
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        self.propose("Tangerine again.", command=command)
        self.conn.request("read_out", text="Read tangerine aloud.")
        self.wait_idle()

        mine = [record for record in self.box.logged() if record.get("utterance_id") == utterance_id]
        events = [record["event"] for record in mine]
        self.assertEqual(events[0], "proposed")
        # The decision and the worker's stages are written by different threads.
        self.assertCountEqual(events[1:4], ["tts_enqueued", "accepted", "queued"])
        self.assertEqual(events[4:], ["tts_preparing", "first_wav_ready", "started", "afplay_started", "played"])
        for record in mine:
            self.assertEqual((record["relay_command_seq"], record["relay_command_id"]), command)
            self.assertEqual((record["kind"], record["source"]), ("final", "orchestrator"))
            self.assertIsInstance(record["at"], float)
        self.assertEqual(len(self.box.logged("deduplicated")), 1)
        self.assertNotIn("tangerine", self.box.event_log.read_text().lower())

    def test_audio_lease_is_held_while_audio_plays(self):
        """`voice-audio.lock` "is held with `flock` while audio plays"."""
        utterance_id = self.speak(LONG)
        self.assertFalse(self.lease_is_held(), "the lease was taken before audio played")
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")

        wait_until(self.lease_is_held, timeout=2.0, message="the lease to be held")

        self.conn.request("skip")
        self.wait_phase(utterance_id, "cancelled")
        wait_until(lambda: not self.lease_is_held(), message="the lease to be released")

    def lease_is_held(self) -> bool:
        try:
            fd = os.open(self.box.lease_path, os.O_RDWR)
        except FileNotFoundError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        finally:
            os.close(fd)
        return False

    def test_busy_audio_lease_fails_the_reply(self):
        """Another holder of the lease, such as a Settings voice preview, is never talked over."""
        self.box.lease_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.box.lease_path, os.O_CREAT | os.O_RDWR, 0o600)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        utterance_id = self.speak()

        self.conn.request("play")

        self.wait_phase(utterance_id, "failed")
        self.assertEqual(
            self.conn.wait_event("error", code="playback_failed"),
            {"event": "error", "code": "playback_failed", "utterance_id": utterance_id},
        )
        self.assertEqual(self.box.playback("chunk_finished"), [])
        wait_until(lambda: self.box.datagrams[-1]["state"] == "failed", message="the failed datagram")


class TestModeTests(SpeechCase):
    """Test mode: deterministic silence and a playback log instead of a device."""

    def test_silence_lasts_a_fixed_time_per_character(self):
        text = "A sentence of exactly forty characters.."
        self.assertEqual(len(text), 40)
        utterance_id = self.speak(f"{text} Hi.")
        started = time.monotonic()
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        elapsed = time.monotonic() - started

        seconds = {record["text"]: record["seconds"] for record in self.box.playback("synthesized")}
        self.assertAlmostEqual(seconds[text], 40 * MS_PER_CHAR / 1000)
        self.assertAlmostEqual(seconds["Hi."], 0.02, msg="a sentence renders at least 20 ms")
        self.assertGreaterEqual(elapsed, 40 * MS_PER_CHAR / 1000)

    def test_playback_log_records_what_reached_the_output(self):
        utterance_id = self.speak("One sentence. Then another.")
        self.wait_phase(utterance_id, "queued")
        self.assertEqual(len(self.box.playback("chime")), 1, "a waiting reply chimes")
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")

        records = self.box.playback()
        for record in records:
            self.assertIsInstance(record["at"], float)
        started = self.box.playback("chunk_started")
        self.assertEqual([record["text"] for record in started], ["One sentence.", "Then another."])
        for record in started:
            self.assertEqual(record["utterance_id"], utterance_id)
            self.assertEqual(record["rate"], 1.0)
            self.assertGreater(record["seconds"], 0)
        self.assertEqual(
            [(record["text"], record["utterance_id"], record["completed"])
             for record in self.box.playback("chunk_finished")],
            [("One sentence.", utterance_id, True), ("Then another.", utterance_id, True)],
        )
        output = self.box.playback("output_started")
        self.assertEqual([(record["sample_rate"], record["rate"]) for record in output], [(24000, 1.0)])
        # Replies are synthesised ahead of play.
        events = [record["event"] for record in records]
        self.assertLess(events.index("synthesized"), events.index("chunk_started"))

    def test_real_mode_is_not_selected_by_another_value(self):
        """Only `RELAY_SPEECH_TEST_MODE=1` selects the test mode."""
        self.assertIs(self.box.hello["test_mode"], True)


if __name__ == "__main__":
    unittest.main()
