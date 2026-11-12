"""Speech service contract: speech for a Relay Remote device.

Section "Relay Remote" of docs/specs/speech-service-protocol.md. The device
session lives in the client, so the suite plays the client: it attaches fake
devices and answers the calls the service makes on them.
"""

from __future__ import annotations

import base64
import unittest

from speech_contract_support import LONG, LONG_SENTENCES, FakeDevice, SpeechCase, wait_until

THREE = "One sentence. Then another. And a third."


def audio_of(device: FakeDevice, seq: int) -> list:
    return [frame for frame in device.of("remote_speech_audio") if frame["seq"] == seq]


class RemoteSinkTests(SpeechCase):
    """`remote_attach` as `sink`: the device is the speech output."""

    def setUp(self):
        super().setUp()
        self.device = self.conn.attach(FakeDevice("device-1"))

    def wait_audio(self, seq: int) -> list:
        """Every audio part of a frame, once its last part arrived."""
        wait_until(
            lambda: any(part["last"] for part in audio_of(self.device, seq)),
            message="the last audio part",
        )
        return audio_of(self.device, seq)

    def test_reply_goes_to_the_device_instead_of_the_speaker(self):
        """Remote synthesis: an accepted `speak` is sent as `remote_speech`."""
        command = self.new_command()
        utterance_id = self.speak(THREE, command=command)

        speech = self.device.of("remote_speech")
        self.assertEqual(len(speech), 1)
        self.assertEqual(speech[0]["device_id"], "device-1")
        self.assertEqual(speech[0]["role"], "sink")
        self.assertEqual(speech[0]["kind"], "final")
        self.assertEqual(speech[0]["source"], "orchestrator")
        self.assertEqual(speech[0]["text"], THREE)
        self.assertEqual(speech[0]["relay_command_seq"], command[0])
        self.assertIs(speech[0]["audio"], True)

        # Not queued for the Mac: no playback events, and nothing to play.
        state = self.status()
        self.assertEqual(state["queue"], [])
        self.assertFalse(state["speaking"])
        self.assertEqual(state["queue_depth"], 1, "an unacknowledged frame counts as unheard")
        self.wait_audio(speech[0]["seq"])
        self.assertEqual(self.phases(utterance_id), [])
        self.assertEqual(self.box.playback("chunk_started"), [])
        self.assertEqual(self.box.playback("output_started"), [])
        sent = self.box.logged("remote_speech_sent")
        self.assertEqual([record["utterance_id"] for record in sent], [utterance_id])
        self.assertEqual(sent[0]["remote_seq"], speech[0]["seq"])

    def test_call_is_made_before_the_speak_is_answered(self):
        """Ordering 5: a call is made from inside the request that needs it."""
        self.speak()
        kinds = [
            "call:" + message["op"] if "call" in message else "response"
            for message in self.conn.messages
            if "event" not in message
        ]
        # hello, remote_attach, then the speak: its calls come before its response.
        self.assertEqual(kinds[:2], ["response", "response"])
        self.assertEqual(kinds[2:5], ["call:remote_routable", "call:remote_speech", "response"])

    def test_audio_is_streamed_sentence_by_sentence(self):
        """Remote synthesis: AAC parts numbered from 0, `parts` and `last` on the final one."""
        self.speak(THREE)
        seq = self.device.of("remote_speech")[0]["seq"]

        parts = self.wait_audio(seq)

        self.assertGreaterEqual(len(parts), 3, "one part or more per sentence")
        self.assertEqual([part["part"] for part in parts], list(range(len(parts))))
        self.assertEqual([part["last"] for part in parts], [False] * (len(parts) - 1) + [True])
        # The total is known only once the last sentence is encoded.
        totals = [part["parts"] for part in parts]
        self.assertEqual(totals[0], 0)
        self.assertEqual(totals[-1], len(parts))
        self.assertTrue(all(total in (0, len(parts)) for total in totals))
        for part in parts:
            self.assertEqual(part["format"], "aac")
            self.assertEqual(part["sample_rate"], 24000)
            self.assertEqual(part["device_id"], "device-1")
            self.assertEqual(part["role"], "sink")
            data = base64.b64decode(part["data"], validate=True)
            # Every sentence starts with an ADTS frame header.
            self.assertEqual(data[0], 0xFF)
            self.assertEqual(data[1] & 0xF0, 0xF0)
        # Rendered sentence by sentence, in order.
        self.assertEqual(
            [record["text"] for record in self.box.playback("synthesized")],
            ["One sentence.", "Then another.", "And a third."],
        )
        self.assertEqual(self.box.logged("remote_first_audio")[0]["remote_seq"], seq)

    def test_played_ack_counts_the_reply_as_heard(self):
        """`remote_ack` with `played: true`."""
        command = self.new_command()
        utterance_id = self.speak(command=command)
        seq = self.device.of("remote_speech")[0]["seq"]

        known = self.conn.request("remote_ack", device_id="device-1", seq=seq, played=True)["known"]

        self.assertTrue(known)
        self.assertEqual(self.status()["queue_depth"], 0)
        coverage = self.conn.request(
            "played_coverage", command_seq=command[0], command_id=command[1]
        )["coverage"]
        self.assertEqual([item["utterance_id"] for item in coverage], [utterance_id])
        played = [record for record in self.box.logged("played") if record["utterance_id"] == utterance_id]
        self.assertEqual(played[0]["remote_seq"], seq)
        # The same frame is acknowledged once.
        self.assertFalse(self.conn.request("remote_ack", device_id="device-1", seq=seq, played=True)["known"])

    def test_received_ack_does_not_count_as_heard(self):
        """`remote_ack` with `played: false` is receipt only."""
        command = self.new_command()
        self.speak(command=command)
        seq = self.device.of("remote_speech")[0]["seq"]

        self.assertTrue(self.conn.request("remote_ack", device_id="device-1", seq=seq, played=False)["known"])

        coverage = self.conn.request(
            "played_coverage", command_seq=command[0], command_id=command[1]
        )["coverage"]
        self.assertEqual(coverage, [])
        self.assertEqual(len(self.box.logged("remote_received")), 1)

    def test_ack_for_an_unknown_frame_is_not_known(self):
        self.assertFalse(self.conn.request("remote_ack", device_id="device-1", seq=99, played=True)["known"])
        self.assertFalse(self.conn.request("remote_ack", device_id="device-2", seq=1, played=True)["known"])

    def test_ack_stops_the_remaining_audio(self):
        """Remote synthesis: a `remote_ack` for the frame stops the remaining audio."""
        self.speak(LONG)
        seq = self.device.of("remote_speech")[0]["seq"]
        wait_until(lambda: audio_of(self.device, seq), message="the first audio part")

        self.conn.request("remote_ack", device_id="device-1", seq=seq, played=True)

        sent = len(audio_of(self.device, seq))
        self.assertStays(
            lambda: len(audio_of(self.device, seq)) <= sent + 1, 0.4, "audio went on after the ack"
        )
        self.assertLess(len(audio_of(self.device, seq)), len(LONG_SENTENCES))
        self.assertFalse(any(part["last"] for part in audio_of(self.device, seq)))

    def test_skip_sends_one_speech_control(self):
        """`remote_speech_control`: the device is told to drop what it has."""
        self.speak(LONG)
        seq = self.device.of("remote_speech")[0]["seq"]
        wait_until(lambda: audio_of(self.device, seq), message="the first audio part")

        self.conn.request("skip")

        controls = self.device.of("remote_speech_control")
        self.assertEqual(len(controls), 1)
        self.assertEqual((controls[0]["action"], controls[0]["reason"]), ("skip", "user_stop"))
        self.assertEqual(controls[0]["role"], "sink")
        # The control covers the frame, so its audio stops too.
        sent = len(audio_of(self.device, seq))
        self.assertStays(
            lambda: len(audio_of(self.device, seq)) <= sent + 1, 0.4, "audio went on after the skip"
        )
        # Nothing is left to stop, so a second skip sends nothing.
        self.conn.request("skip")
        self.assertEqual(len(self.device.of("remote_speech_control")), 1)

    def test_pause_sends_a_stop(self):
        self.speak()
        self.conn.request("pause")
        controls = self.device.of("remote_speech_control")
        self.assertEqual(
            [(control["action"], control["reason"]) for control in controls],
            [("stop", "speech_only_barge_in")],
        )

    def test_stop_with_nothing_outstanding_sends_no_control(self):
        self.speak()
        seq = self.device.of("remote_speech")[0]["seq"]
        self.conn.request("remote_ack", device_id="device-1", seq=seq, played=True)
        self.conn.request("skip")
        self.conn.request("pause")
        self.assertEqual(self.device.of("remote_speech_control"), [])

    def test_detach_returns_unacknowledged_replies_to_the_mac_queue(self):
        """`remote_detach`: "Replies a sink had not acknowledged return to the Mac queue"."""
        first = self.speak("First reply.")
        second = self.speak("Second reply.")
        handoff = self.speak("Looking into it.", kind="handoff", source="messenger", authoritative=False)
        heard = self.device.of("remote_speech")[0]["seq"]
        self.conn.request("remote_ack", device_id="device-1", seq=heard, played=True)

        self.conn.request("remote_detach", device_id="device-1", role="sink", reason="remote_mode_off")

        # Only the unacknowledged reply returns; a handoff is not a reply.
        self.assertEqual(self.queue(), [second])
        self.wait_phase(second, "queued")
        self.assertNotIn(first, self.queue())
        self.assertEqual(self.phases(handoff), [])
        detached = self.box.logged("remote_sink_detached")
        self.assertEqual([(record["device_id"], record["reason"]) for record in detached],
                         [("device-1", "remote_mode_off")])
        self.conn.request("play")
        self.wait_phase(second, "completed")
        self.assertEqual(self.box.spoken(), [("Second reply.", True)])

        # With no sink, speech is for the Mac again.
        calls = len(self.conn.calls)
        third = self.speak("Third reply.")
        self.assertEqual(self.queue(), [third])
        self.assertEqual(len(self.conn.calls), calls)

    def test_sink_that_is_not_routable_is_detached(self):
        """`remote_routable`: "A sink that is not routable is detached"."""
        self.device.routable = False

        utterance_id = self.speak()

        self.assertEqual(self.queue(), [utterance_id])
        self.assertEqual(self.device.of("remote_speech"), [])
        detached = self.box.logged("remote_sink_detached")
        self.assertEqual(detached[0]["reason"], "replay_window_expired")
        # It stays detached: the next reply asks nothing of it.
        self.device.routable = True
        calls = len(self.conn.calls)
        self.speak("Second reply.")
        self.assertEqual(len(self.conn.calls), calls)

    def test_unanswered_routable_call_counts_as_not_routable(self):
        self.device.refuse.add("remote_routable")
        utterance_id = self.speak()
        self.assertEqual(self.queue(), [utterance_id])

    def test_failed_speech_call_refuses_the_speak(self):
        """`remote_speech`: a failed reply means `speak` answers `accepted: false`."""
        self.device.refuse.add("remote_speech")

        refused = self.propose()

        self.assertFalse(refused["accepted"])
        self.assertEqual(self.status()["queue_depth"], 0)
        self.assertEqual(len(self.box.logged("remote_failed")), 1)
        # It was never accepted, so it may be proposed again.
        self.device.refuse.clear()
        self.assertTrue(self.propose(command=(self.commands, f"command-{self.commands}"))["accepted"])

    def test_newest_sink_takes_the_speech(self):
        """Two sinks: the device attached last is the output."""
        newer = self.conn.attach(FakeDevice("device-2"))
        self.speak()
        self.assertEqual(len(newer.of("remote_speech")), 1)
        self.assertEqual(self.device.of("remote_speech"), [])

    def test_replay_is_sent_to_the_device(self):
        """A reply sent to the device joins the replay history."""
        self.speak("Reply for the phone.")
        self.assertTrue(self.conn.request("replay")["accepted"])
        speech = self.device.of("remote_speech")
        self.assertEqual([frame["text"] for frame in speech], ["Reply for the phone."] * 2)
        self.assertEqual(self.status()["queue"], [])

    def test_dedup_applies_to_remote_speech(self):
        command = self.new_command()
        self.assertTrue(self.propose(command=command)["accepted"])
        self.assertFalse(self.propose(command=command)["accepted"])
        self.assertEqual(len(self.device.of("remote_speech")), 1)


class RemoteMirrorTests(SpeechCase):
    """`remote_attach` as `mirror`: the Mac speaks, the device shows the text."""

    def test_mirror_is_sent_the_text_of_what_the_mac_speaks(self):
        device = self.conn.attach(FakeDevice("device-1"), role="mirror")
        command = self.new_command()

        utterance_id = self.speak("Reply for the Mac.", command=command)

        self.assertEqual(self.queue(), [utterance_id])
        speech = wait_until(lambda: device.of("remote_speech"), message="the mirrored text")
        self.assertEqual(len(speech), 1)
        self.assertEqual(speech[0]["role"], "mirror")
        self.assertEqual(speech[0]["text"], "Reply for the Mac.")
        self.assertEqual(speech[0]["spoken_by"], "mac")
        self.assertEqual(speech[0]["kind"], "final")
        self.assertEqual(speech[0]["relay_command_seq"], command[0])
        self.assertNotIn("audio", speech[0])
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        self.assertEqual(self.box.spoken(), [("Reply for the Mac.", True)])
        self.assertEqual(device.of("remote_speech_audio"), [])
        self.assertEqual([call["op"] for call in self.conn.calls], ["remote_speech"])

    def test_mirror_that_fails_never_stops_mac_speech(self):
        device = self.conn.attach(FakeDevice("device-1"), role="mirror")
        device.refuse.add("remote_speech")
        utterance_id = self.speak()
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")

    def test_detached_mirror_is_sent_nothing(self):
        device = self.conn.attach(FakeDevice("device-1"), role="mirror")
        self.conn.request("remote_detach", device_id="device-1", role="mirror")
        self.speak()
        self.assertEqual(device.frames, [])
        self.assertEqual(self.conn.calls, [])

    def test_attaching_as_sink_ends_the_mirror_role(self):
        """`remote_attach`: "Attaching a device as `sink` ends its `mirror` role"."""
        mirror = self.conn.attach(FakeDevice("device-1"), role="mirror")
        sink = self.conn.attach(FakeDevice("device-1"), role="sink")

        self.speak()

        self.assertEqual(len(sink.of("remote_speech")), 1)
        self.assertEqual(mirror.frames, [])
        self.assertEqual({call["role"] for call in self.conn.calls}, {"sink"})


class RemoteRequestTests(SpeechCase):
    """Relay Remote requests name a device and a role."""

    def test_device_id_and_role_are_checked(self):
        for params in ({}, {"device_id": ""}, {"device_id": "device-1", "role": "speaker"}):
            with self.subTest(params=params):
                response = self.conn.exchange("remote_attach", **params)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "invalid_request")
        response = self.conn.exchange("remote_ack", device_id="device-1", played=True)
        self.assertEqual(response["error"]["code"], "invalid_request")

    def test_role_defaults_to_sink(self):
        device = FakeDevice("device-1")
        self.conn.devices[("device-1", "sink")] = device
        self.conn.request("remote_attach", device_id="device-1")
        self.speak()
        self.assertEqual(len(device.of("remote_speech")), 1)

    def test_detaching_an_unknown_device_does_nothing(self):
        self.conn.request("remote_detach", device_id="device-9", role="sink")
        self.conn.request("remote_detach", device_id="device-9", role="mirror")
        self.assertEqual(self.box.logged("remote_sink_detached"), [])


if __name__ == "__main__":
    unittest.main()
