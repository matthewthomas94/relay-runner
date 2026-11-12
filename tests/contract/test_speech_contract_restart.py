"""Speech service contract: what a restart keeps, and how a session ends.

Section "Restarts" of docs/specs/speech-service-protocol.md. The service
keeps nothing on disk and never outlives its client; a client that wants
queued replies back after a restart proposes them again.
"""

from __future__ import annotations

import os
import socket
import unittest

from speech_contract_support import LONG, LONG_SENTENCES, FakeDevice, SpeechCase, wait_until

IDLE = {"speaking": False, "playing": False, "held": False, "queue_depth": 0, "queue": []}


class RestartTests(SpeechCase):
    """Restarts: "A new service process starts with an empty queue"."""

    def queue_three(self) -> list:
        """Three replies of three commands: the first playing, two queued behind it."""
        self.requests = []
        for number, text in enumerate([LONG, "Second reply.", "Third reply."], start=1):
            command = self.new_command()
            self.requests.append({
                "text": text, "command_seq": command[0], "command_id": command[1], "kind": "final",
                "source": "orchestrator", "authoritative": True, "utterance_id": f"reply-{number}",
                "session_key": f"session-{number}",
            })
            self.assertTrue(self.conn.request("speak", **self.requests[-1])["accepted"])
        self.conn.request("play")
        self.wait_phase("reply-1", "started")
        return [request["utterance_id"] for request in self.requests]

    def restart(self):
        """End the service the hard way and start a new one on the same paths."""
        first_instance = self.box.hello["instance_id"]
        self.box.kill()
        wait_until(self.conn.closed.is_set, message="the old connection to close")
        self.conn = self.box.start()
        self.assertNotEqual(self.box.hello["instance_id"], first_instance)

    def test_restart_with_queued_speech_starts_empty(self):
        """A new process has an empty queue, no replay history and no held state."""
        self.queue_three()
        self.conn.request("pause")
        self.assertTrue(self.status()["held"])

        self.restart()

        self.assertEqual(self.conn.messages[0], {"event": "state", **IDLE})
        self.assertEqual(self.status(), IDLE)
        self.assertEqual(self.conn.request("replay"), {"accepted": False})
        self.assertEqual(self.conn.request("session_playback_states"), {"states": {}})
        self.assertEqual(self.conn.events_named("playback"), [])

    def test_queued_replies_are_accepted_again_and_play_in_order(self):
        """"An intent the old process had accepted is accepted again"."""
        ids = self.queue_three()

        self.restart()
        # The client's part, step 3: the same `speak` requests in queue order.
        # They are ordinary requests, so a reply whose command is no longer
        # fresh is dropped: here only the newest command is the current one.
        accepted = [self.conn.request("speak", **request)["accepted"] for request in self.requests]
        self.assertEqual(accepted, [False, False, True])
        self.assertEqual(self.queue(), ids[2:])

        # A current command that preserves earlier work keeps the older replies.
        self.commands += 1
        self.box.set_command(self.commands, "command-newer", work_disposition={
            "route": "continue_current", "authorization_effect": "preserve", "cancellation_scope": "none",
        })
        accepted = [self.conn.request("speak", **request)["accepted"] for request in self.requests[:2]]
        self.assertEqual(accepted, [True, True])
        self.assertEqual(self.queue(), [ids[2], ids[0], ids[1]])

        self.conn.request("play")
        self.wait_phase(ids[2], "completed")
        # The reply that was cut off starts again from its first sentence.
        self.wait_phase(ids[0], "queued")
        before = len(self.box.playback("chunk_started"))
        self.conn.request("play")
        self.wait_phase(ids[0], "started")
        again = wait_until(lambda: self.box.playback("chunk_started")[before:], message="the reply again")[0]
        self.assertEqual((again["utterance_id"], again["text"]), (ids[0], LONG_SENTENCES[0]))
        self.conn.request("skip")
        self.wait_phase(ids[1], "queued")
        self.conn.request("play")
        self.wait_phase(ids[1], "completed")
        self.assertEqual(self.status(), IDLE)

    def test_accepted_keys_are_forgotten(self):
        """A new process has "no accepted keys": a deduplicated intent is accepted again."""
        command = self.new_command()
        request = {"text": "The answer.", "command_seq": command[0], "command_id": command[1], "kind": "final"}
        self.assertTrue(self.conn.request("speak", **request)["accepted"])
        self.assertFalse(self.conn.request("speak", **request)["accepted"])

        self.restart()

        self.assertTrue(self.conn.request("speak", **request)["accepted"])

    def test_devices_are_forgotten(self):
        """A new process has "no devices": speech is for the Mac until one is attached again."""
        device = self.conn.attach(FakeDevice("device-1"))
        self.speak()
        self.assertEqual(len(device.of("remote_speech")), 1)

        self.restart()
        again = FakeDevice("device-1")
        self.conn.devices[("device-1", "sink")] = again
        utterance_id = self.speak("For the Mac.")
        self.assertEqual(self.queue(), [utterance_id])
        self.assertEqual(self.conn.calls, [])

        self.conn.attach(again)
        self.speak("For the phone.")
        self.assertEqual([frame["text"] for frame in again.of("remote_speech")], ["For the phone."])

    def test_sockets_are_bound_again(self):
        """A new process "binds its sockets again"."""
        self.queue_three()
        self.restart()
        self.assertFalse(os.path.exists(self.box.socket_path), "the new service keeps one connection too")
        utterance_id = self.speak()
        self.box.control("play")
        self.wait_phase(utterance_id, "completed")

    def test_killed_service_is_seen_as_a_closed_connection(self):
        """A client learns of an unasked end through its connection."""
        self.queue_three()
        self.box.kill()
        wait_until(self.conn.closed.is_set, message="the connection to close")
        with self.assertRaises((AssertionError, OSError)):
            self.conn.exchange("status")


class ClientGoneTests(SpeechCase):
    """Restarts: "The service never outlives its client"."""

    def test_service_exits_when_the_connection_ends(self):
        """When the connection ends the service stops speech at once and exits 0."""
        utterance_id = self.speak(LONG)
        self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")

        self.conn.close()

        self.assertEqual(self.box.wait_exit(), 0)
        spoken = self.box.spoken()
        self.assertLess(len(spoken), len(LONG_SENTENCES))
        self.assertFalse(spoken[-1][1], "the reply was not cut off")
        self.assertNotIn("Second reply.", [text for text, _ in spoken])
        self.assertEqual(self.box.playback()[-1]["event"], "output_stopped")
        self.assertFalse(os.path.exists(self.box.control_path))

    def test_service_exits_when_the_connection_ends_inside_a_line(self):
        self.conn.send(b'{"id": 99, "op": "sta')
        self.conn.close()
        self.assertEqual(self.box.wait_exit(), 0)

    def test_service_exits_when_the_client_stops_writing(self):
        """A half-closed connection counts as ended."""
        self.conn.sock.shutdown(socket.SHUT_WR)
        self.assertEqual(self.box.wait_exit(), 0)

    def test_idle_service_exits_when_the_connection_ends(self):
        self.conn.close()
        self.assertEqual(self.box.wait_exit(), 0)
        self.assertFalse(os.path.exists(self.box.control_path))


if __name__ == "__main__":
    unittest.main()
