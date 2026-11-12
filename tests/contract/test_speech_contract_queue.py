"""Speech service contract: what `speak` accepts and where it queues.

Sections "Queue rules" and "Freshness" of
docs/specs/speech-service-protocol.md.
"""

from __future__ import annotations

import time
import unittest

from speech_contract_support import LONG, LONG_SENTENCES, SHORT, SpeechCase, wait_until

PRESERVE = {
    "route": "continue_current",
    "authorization_effect": "preserve",
    "cancellation_scope": "none",
}
HANDOFF = {"kind": "handoff", "source": "messenger", "authoritative": False}
FALLBACK = {"kind": "fallback", "source": "fallback", "authoritative": False}


class QueueOrderTests(SpeechCase):
    """Queue rules: one queue, played from the head."""

    def test_replies_play_in_the_order_they_were_accepted(self):
        """An accepted intent goes to the back; the head waits for `play`."""
        texts = ["First reply.", "Second reply.", "Third reply."]
        ids = [self.speak(text) for text in texts]

        state = self.status()
        self.assertEqual([item["original_utterance_id"] for item in state["queue"]], ids)
        self.assertEqual(state["queue_depth"], 3)
        self.assertTrue(state["speaking"])
        self.assertFalse(state["playing"])
        # Only the head is published as waiting.
        self.wait_phase(ids[0], "queued")
        self.assertEqual(self.phases(ids[0]), ["queued"])
        self.assertEqual(self.phases(ids[1]), [])

        for position, utterance_id in enumerate(ids):
            self.wait_phase(utterance_id, "queued")
            self.assertStays(lambda: not self.status()["playing"], 0.15, "the head played without play")
            self.conn.request("play")
            self.wait_phase(utterance_id, "completed")
            self.assertEqual(self.queue(), ids[position + 1:])

        self.assertEqual(self.box.spoken(), [(text, True) for text in texts])
        self.assertEqual(self.status()["queue_depth"], 0)

    def test_play_with_nothing_queued_does_nothing(self):
        """`play`: "Plays the reply waiting at the head of the queue"."""
        self.conn.request("play")
        utterance_id = self.speak()
        self.wait_phase(utterance_id, "queued")
        self.assertStays(lambda: self.phases(utterance_id) == ["queued"], 0.2, "an earlier play was kept")

    def test_empty_text_is_refused(self):
        """`speak` answers `accepted: false` when `text` is empty."""
        for text in ("", "   "):
            self.assertFalse(self.propose(text)["accepted"])
        self.assertEqual(self.queue(), [])

    def test_expired_intent_is_refused(self):
        """`speak` answers `accepted: false` when `expires_at` has passed."""
        self.assertFalse(self.propose(expires_at=time.time() - 1)["accepted"])
        self.assertTrue(self.propose(expires_at=time.time() + 60)["accepted"])

    def test_dedup_key_is_accepted_once(self):
        """`speak` answers `accepted: false` when its `dedup_key` was accepted before."""
        first = self.propose("One.", dedup_key="note-1", kind="progress", source="lifecycle")
        again = self.propose("One again.", dedup_key="note-1", kind="progress", source="lifecycle")
        self.assertTrue(first["accepted"])
        self.assertFalse(again["accepted"])

    def test_a_command_has_one_real_final_and_one_fallback(self):
        """`dedup_key`: "a command has one real final and one fallback"."""
        command = self.new_command()
        self.assertTrue(self.propose("Stand-in.", command=command, **FALLBACK)["accepted"])
        self.assertFalse(self.propose("Second stand-in.", command=command, **FALLBACK)["accepted"])
        self.assertTrue(self.propose("The answer.", command=command)["accepted"])
        self.assertFalse(self.propose("Another answer.", command=command)["accepted"])

    def test_fallback_after_the_real_final_is_refused(self):
        """A fallback for a command whose real final was accepted is refused."""
        command = self.new_command()
        final = self.speak("The answer.", command=command)
        self.assertFalse(self.propose("Stand-in.", command=command, **FALLBACK)["accepted"])
        self.assertEqual(self.queue(), [final])

    def test_utterance_id_is_the_one_proposed(self):
        """`utterance_id`: "The identity used in events and state datagrams"."""
        result = self.propose(utterance_id="utterance-chosen-by-client")
        self.assertEqual(result, {"accepted": True, "utterance_id": "utterance-chosen-by-client"})
        self.assertEqual(self.queue(), ["utterance-chosen-by-client"])
        waiting = wait_until(
            lambda: [d for d in self.box.datagrams if d.get("state") == "message_waiting"],
            message="the waiting datagram",
        )[0]
        self.assertEqual(waiting["utterance_id"], "utterance-chosen-by-client")


class SupersedeAndReplaceTests(SpeechCase):
    """Queue rules: Supersede, Replace and Newer command."""

    def test_reply_supersedes_its_commands_waiting_handoff(self):
        """Supersede: a reply replaces the same command's handoff that has not started."""
        command = self.new_command()
        handoff = self.speak("Looking into it.", command=command, **HANDOFF)
        self.wait_phase(handoff, "queued")
        final = self.speak("Here is the answer.", command=command)

        self.assertEqual(self.queue(), [final])
        ended = self.wait_phase(handoff, "cancelled")
        self.assertIsNone(ended["requeued_as"])
        self.conn.request("play")
        self.wait_phase(final, "completed")
        self.assertEqual(self.box.spoken(), [("Here is the answer.", True)])

    def test_reply_supersedes_its_commands_handoff_wherever_it_is_queued(self):
        """Supersede: "wherever it is queued", here behind another command's reply."""
        earlier = self.speak("Earlier reply.")
        command = self.new_command()
        handoff = self.speak("Looking into it.", command=command, **HANDOFF)
        progress = self.speak("Still working.", command=command, kind="progress", source="lifecycle")
        self.assertEqual(self.queue(), [earlier, handoff, progress])

        final = self.speak("Here is the answer.", command=command)

        self.assertEqual(self.queue(), [earlier, final])
        # They never reached the head, so they have no playback events.
        self.assertEqual(self.phases(handoff) + self.phases(progress), [])

    def test_handoff_that_started_is_not_superseded(self):
        """Supersede applies only to speech "that has not started"."""
        command = self.new_command()
        handoff = self.speak(LONG, command=command, **HANDOFF)
        self.conn.request("play")
        self.wait_phase(handoff, "started")

        final = self.speak("Here is the answer.", command=command)

        self.assertEqual(self.queue(), [handoff, final])
        self.assertStays(lambda: self.status()["playing"], 0.2, "the handoff was cut off")
        self.assertNotIn("cancelled", self.phases(handoff))

    def test_another_commands_reply_is_not_superseded(self):
        """Supersede is for "the same command's" speech only."""
        earlier = self.speak("Earlier reply.")
        self.wait_phase(earlier, "queued")
        later = self.speak("Later reply.")
        self.assertEqual(self.queue(), [earlier, later])
        self.assertEqual(self.phases(earlier), ["queued"])

    def test_real_final_replaces_the_waiting_fallback(self):
        """Replace: an authoritative final replaces the same command's fallback outcome."""
        command = self.new_command()
        fallback = self.speak("I could not confirm the result.", command=command, **FALLBACK)
        self.wait_phase(fallback, "queued")

        final = self.speak("The build passed.", command=command)

        self.assertEqual(self.queue(), [final])
        self.wait_phase(fallback, "cancelled")
        self.conn.request("play")
        self.wait_phase(final, "completed")
        self.assertEqual(self.box.spoken(), [("The build passed.", True)])

    def test_real_final_replaces_the_fallback_while_it_plays(self):
        """Replace: "even while that fallback is playing"."""
        command = self.new_command()
        fallback = self.speak(LONG, command=command, **FALLBACK)
        self.conn.request("play")
        self.wait_phase(fallback, "started")

        final = self.speak("The build passed.", command=command)

        ended = self.wait_phase(fallback, "cancelled")
        self.assertIsNone(ended["requeued_as"])
        self.assertEqual(self.queue(), [final])
        self.wait_phase(final, "queued")
        self.assertLess(len(self.box.spoken()), len(LONG_SENTENCES))

    def test_real_final_replaces_a_fallback_queued_behind_another_reply(self):
        """Replace applies to a fallback anywhere in the queue."""
        earlier = self.speak("Earlier reply.")
        command = self.new_command()
        self.speak("I could not confirm the result.", command=command, **FALLBACK)
        final = self.speak("The build passed.", command=command)
        self.assertEqual(self.queue(), [earlier, final])

    def test_unauthoritative_final_does_not_replace_the_fallback(self):
        """Replace needs an authoritative `final` from `completion` or `orchestrator`."""
        command = self.new_command()
        fallback = self.speak("I could not confirm the result.", command=command, **FALLBACK)
        guess = self.speak("Probably done.", command=command, source="messenger", authoritative=False)
        self.assertEqual(self.queue(), [fallback, guess])

    def test_newer_command_stops_the_older_handoff_at_the_head(self):
        """Newer command: its speech stops the older command's handoff at the head."""
        handoff = self.speak("Looking into it.", **HANDOFF)
        self.wait_phase(handoff, "queued")

        newer = self.speak("Looking into the next thing.", **HANDOFF)

        self.wait_phase(handoff, "cancelled")
        self.assertEqual(self.queue(), [newer])
        self.wait_phase(newer, "queued")

    def test_newer_command_never_removes_a_reply(self):
        """Newer command: "A reply is never removed by a newer command"."""
        reply = self.speak("Earlier reply.")
        self.wait_phase(reply, "queued")
        newer = self.speak("Looking into the next thing.", **HANDOFF)
        self.assertEqual(self.queue(), [reply, newer])
        self.assertEqual(self.phases(reply), ["queued"])


class QueueCapTests(SpeechCase):
    """Queue rules: the 50-item cap."""

    def test_the_fifty_first_item_is_refused(self):
        """`speak` answers `accepted: false` when the queue already holds 50 items."""
        ids = [self.speak(f"Reply {number}.") for number in range(50)]
        self.assertEqual(self.status()["queue_depth"], 50)

        refused = self.propose("One too many.")

        self.assertFalse(refused["accepted"])
        self.assertEqual(self.queue(), ids)
        full = self.box.logged("queue_full")
        self.assertEqual([record["utterance_id"] for record in full], [refused["utterance_id"]])
        self.assertEqual(full[0]["limit"], 50)

        # A refused intent was never accepted, so it may be proposed again
        # once the queue has room.
        self.conn.request("play")
        self.wait_phase(ids[0], "completed")
        again = self.propose("One too many.", utterance_id=refused["utterance_id"])
        self.assertTrue(again["accepted"])
        self.assertEqual(self.queue(), ids[1:] + [refused["utterance_id"]])


class FreshnessTests(SpeechCase):
    """Freshness: which commands may still speak."""

    def test_speech_of_an_older_command_is_refused(self):
        """An intent is stale when its command is not the current command."""
        older = self.new_command()
        self.new_command()
        for fields in (HANDOFF, {"kind": "progress", "source": "lifecycle"}, {}, FALLBACK):
            with self.subTest(fields=fields):
                self.assertFalse(self.propose(command=older, **fields)["accepted"])
        self.assertEqual(self.queue(), [])
        self.assertEqual(len(self.box.logged("expired")), 4)

    def test_no_command_state_names_no_current_command(self):
        """"an unreadable or missing file names none"."""
        self.assertFalse(self.propose(command=(1, "command-1"))["accepted"])
        self.box.command_state.write_text("{not json")
        self.assertFalse(self.propose(command=(1, "command-1"))["accepted"])
        self.box.set_command(1, "command-1")
        self.assertTrue(self.propose(command=(1, "command-1"))["accepted"])

    def test_command_must_match_by_seq_and_id(self):
        """The file's `relay_command_seq` and `relay_command_id` name the current command."""
        self.box.set_command(7, "command-7")
        self.assertFalse(self.propose(command=(7, "another-id"))["accepted"])
        self.assertFalse(self.propose(command=(8, "command-7"))["accepted"])
        self.assertTrue(self.propose(command=(7, "command-7"))["accepted"])

    def test_intent_without_a_command_is_fresh(self):
        """An intent is fresh when "it has no `command_seq` and `command_id`"."""
        self.new_command()
        result = self.conn.request("speak", text="A stored reply.", dedup_key="stored-1")
        self.assertTrue(result["accepted"])

    def test_work_scoped_lifecycle_final_outlives_its_command(self):
        """A `lifecycle` `final` with `freshness_scope: "work"` is fresh."""
        older = self.new_command()
        self.new_command()
        fields = {"source": "lifecycle", "authoritative": False}
        self.assertTrue(self.propose("The worker finished.", command=older, freshness_scope="work", **fields)["accepted"])
        # The scope is honoured for a lifecycle final only.
        self.assertFalse(self.propose(
            "Still working.", command=older, freshness_scope="work", kind="progress", source="lifecycle",
        )["accepted"])

    def test_authoritative_final_of_a_preserved_command_is_fresh(self):
        """Preserved: the current command is newer and continues the older one's work."""
        older = self.new_command()
        self.commands += 1
        self.box.set_command(self.commands, "command-newer", work_disposition=PRESERVE)

        handoff = self.propose(command=older, **HANDOFF)
        unauthoritative = self.propose(command=older, source="messenger", authoritative=False)
        final = self.propose("The earlier work is done.", command=older, work_disposition={"intent_id": "intent-1"})

        self.assertFalse(handoff["accepted"], "only a final or fallback is preserved")
        self.assertFalse(unauthoritative["accepted"], "only an authoritative outcome is preserved")
        self.assertTrue(final["accepted"])

    def test_preserved_needs_the_whole_disposition(self):
        """Preserved needs `route`, `authorization_effect` and no cancellation scope."""
        older = self.new_command()
        for changed in (
            {"route": "replace_current"},
            {"authorization_effect": "revoke"},
            {"cancellation_scope": "all_work"},
        ):
            with self.subTest(changed=changed):
                self.commands += 1
                self.box.set_command(
                    self.commands, f"command-{self.commands}", work_disposition={**PRESERVE, **changed}
                )
                self.assertFalse(self.propose(command=older)["accepted"])
        without_scope = {key: value for key, value in PRESERVE.items() if key != "cancellation_scope"}
        self.commands += 1
        self.box.set_command(self.commands, f"command-{self.commands}", work_disposition=without_scope)
        self.assertTrue(self.propose(command=older)["accepted"])

    def test_cancelled_intent_is_not_preserved(self):
        """Preserved excludes an `intent_id` listed in `cancelled_intent_ids`."""
        older = self.new_command()
        self.commands += 1
        self.box.set_command(
            self.commands, "command-newer", work_disposition=PRESERVE, cancelled_intent_ids=["intent-1"],
        )
        cancelled = self.propose(command=older, work_disposition={"intent_id": "intent-1"})
        kept = self.propose(command=older, work_disposition={"intent_id": "intent-2"})
        self.assertFalse(cancelled["accepted"])
        self.assertTrue(kept["accepted"])

    def test_accepted_reply_stays_fresh_after_a_newer_command(self):
        """An intent is fresh when "it is a reply that was already accepted"."""
        reply = self.speak("Earlier reply.")
        self.new_command()
        self.conn.request("play")
        self.wait_phase(reply, "completed")
        self.assertEqual(self.box.spoken(), [("Earlier reply.", True)])

    def test_stale_handoff_is_dropped_when_it_reaches_the_head(self):
        """Freshness is checked "when it reaches the head of the queue"."""
        command = self.new_command()
        reply = self.speak("The answer.", command=command)
        note = self.speak("One more note.", command=command, kind="progress", source="lifecycle")
        self.assertEqual(self.queue(), [reply, note])
        self.new_command()

        self.conn.request("play")
        self.wait_phase(reply, "completed")

        self.wait_idle()
        self.assertEqual(self.queue(), [])
        self.assertEqual(self.phases(note), [])
        self.assertEqual([record["utterance_id"] for record in self.box.logged("expired")], [note])
        self.assertEqual(self.box.spoken(), [("The answer.", True)])

    def test_stale_handoff_stops_between_sentences(self):
        """Freshness is checked "before each sentence is played"."""
        handoff = self.speak(LONG, **HANDOFF)
        self.conn.request("play")
        self.wait_phase(handoff, "started")

        self.new_command()

        ended = self.wait_phase(handoff, "cancelled")
        self.assertIsNone(ended["requeued_as"])
        self.wait_idle()
        spoken = self.box.spoken()
        self.assertLess(len(spoken), len(LONG_SENTENCES))
        # The sentence that was playing is finished, not cut off.
        self.assertTrue(all(completed for _, completed in spoken))

    def test_stale_waiting_handoff_is_not_played(self):
        """Freshness is checked again when `play` asks for the head."""
        handoff = self.speak("Looking into it.", **HANDOFF)
        self.wait_phase(handoff, "queued")
        self.new_command()

        self.conn.request("play")

        self.wait_phase(handoff, "cancelled")
        self.wait_idle()
        self.assertEqual(self.box.spoken(), [])


if __name__ == "__main__":
    unittest.main()
