from __future__ import annotations

import os
import queue
import json
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import tts_worker  # noqa: E402
from tts_worker import TTSWorker  # noqa: E402


class ImmediateThread:
    def __init__(self, target, args=(), kwargs=None, daemon=None):
        self.target = target
        self.args = args
        self.kwargs = kwargs or {}

    def start(self):
        self.target(*self.args, **self.kwargs)


class IdleThread:
    def __init__(self, target, args=(), kwargs=None, daemon=None):
        self.target = target
        self.args = args
        self.kwargs = kwargs or {}

    def start(self):
        return None


class TTSWorkerReplayTests(unittest.TestCase):
    def setUp(self):
        # Exercise notification payloads without reaching the running app's
        # overlay or control sockets. Individual tests can provide stricter fakes.
        socket_patch = patch.object(tts_worker.socket, "socket")
        self.socket_factory = socket_patch.start()
        self.addCleanup(socket_patch.stop)

    def test_waiting_preview_uses_isolated_socket(self):
        tts_worker.publish_waiting_preview(
            "current response", {"utterance_id": "new"},
        )

        self.socket_factory.assert_called_once_with(
            tts_worker.socket.AF_UNIX, tts_worker.socket.SOCK_DGRAM,
        )
        transport = self.socket_factory.return_value
        transport.sendto.assert_called_once()
        payload, destination = transport.sendto.call_args.args
        self.assertEqual(destination, tts_worker.VOICE_STATE_SOCK)
        self.assertEqual(json.loads(payload)["state"], "message_waiting")
        self.assertEqual(json.loads(payload)["text"], "current response")
        transport.close.assert_called_once()

    def make_worker(self):
        worker = TTSWorker.__new__(TTSWorker)
        worker.input_queue = queue.Queue()
        worker._pending_text = ""
        worker._pending_display_text = ""
        worker._pending_speech_intent = None
        worker._current_speech_intent = None
        worker._speech_eligibility = None
        worker._speech_observer = None
        worker._lock = threading.Lock()
        worker._play_request_lock = threading.RLock()
        worker._playing = False
        worker._paused = False
        worker._current_proc = None
        worker._chime_proc = None
        worker._playback_generation = 0
        worker._last_wav = None
        worker._last_unheard_text = ""
        worker._last_unheard_display_text = ""
        worker._last_response_text = ""
        worker._last_response_display_text = ""
        worker._current_spoken_text = ""
        worker._current_display_text = ""
        worker._rate = 1.0
        worker._auto_play = False
        worker.played_texts = []
        worker.played_displays = []
        worker.played_intents = []
        worker.played_wavs = []
        def play_text(text, *, display_text=None, speech_intent=None):
            worker.played_texts.append(text)
            worker.played_displays.append(display_text)
            worker.played_intents.append(speech_intent)
        worker._play_text = play_text
        worker._play_wav = lambda wav, _generation: worker.played_wavs.append(wav)
        worker._play_chime = lambda: None
        worker._start_speculation = lambda text: None
        worker._cancel_speculation = lambda: None
        return worker

    def make_chunk_worker(self):
        worker = self.make_worker()
        del worker._start_speculation
        worker._kokoro = object()
        worker._spec_lock = threading.Lock()
        worker._spec_cond = threading.Condition(worker._spec_lock)
        worker._spec_text = ""
        worker._spec_wav = None
        worker._spec_done = False
        worker._playback_generation = 1
        worker._playing = True
        return worker

    def temp_wav(self):
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def test_auto_play_coordinated_intent_skips_empty_queue_debounce(self):
        worker = self.make_worker()
        worker._auto_play = True
        worker._shutdown = False
        worker.input_queue.put({
            "text": "The semantic response is ready.",
            "_speech_intent": {"utterance_id": "current"},
        })
        chimes = []
        worker._play_chime = lambda: chimes.append("chime")
        get_calls = 0
        original_get = worker.input_queue.get

        def counted_get(*args, **kwargs):
            nonlocal get_calls
            get_calls += 1
            return original_get(*args, **kwargs)

        def play():
            worker._shutdown = True
            worker.played_texts.append(worker._pending_text)

        worker.input_queue.get = counted_get
        worker.play = play

        worker._collect_loop()

        self.assertEqual(worker.played_texts, ["The semantic response is ready."])
        self.assertEqual(get_calls, 1)
        self.assertEqual(chimes, [])

    def test_manual_queue_keeps_coordinated_intent_pending(self):
        worker = self.make_worker()
        worker._auto_play = False
        worker._shutdown = False
        worker.input_queue.put({
            "text": "Wait for the user's Option press.",
            "_speech_intent": {"utterance_id": "current"},
        })
        chimes = []
        worker._play_chime = lambda: chimes.append("chime")
        original_get = worker.input_queue.get

        def get_once(*args, **kwargs):
            worker._shutdown = True
            return original_get(*args, **kwargs)

        worker.input_queue.get = get_once

        worker._collect_loop()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker._pending_text, "Wait for the user's Option press.")
        self.assertEqual(chimes, ["chime"])

    def test_replay_uses_pending_text_before_last_wav(self):
        worker = self.make_worker()
        worker._pending_text = "latest unheard"
        worker._last_wav = self.temp_wav()

        worker.replay()

        self.assertEqual(worker.played_texts, ["latest unheard"])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._pending_text, "")

    def test_skip_preserves_pending_text_for_replay(self):
        worker = self.make_worker()
        worker._pending_text = "canceled latest"
        worker._last_wav = self.temp_wav()

        worker.skip()
        worker.replay()

        self.assertEqual(worker.played_texts, ["canceled latest"])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._last_unheard_text, "")

    def test_replay_falls_back_to_last_wav_without_unheard_text(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()
        worker._last_response_text = "Previously spoken reply"

        with (
            patch.object(tts_worker.threading, "Thread", ImmediateThread),
            patch.object(tts_worker, "_notify_state") as notify_state,
        ):
            worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [worker._last_wav])
        notify_state.assert_any_call("preparing", text="Previously spoken reply")

    def test_replay_without_transcript_uses_last_wav_only(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()

        with (
            patch.object(tts_worker.threading, "Thread", ImmediateThread),
            patch.object(tts_worker, "_notify_state") as notify_state,
        ):
            worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [worker._last_wav])
        notify_state.assert_not_called()

    def test_playing_new_pending_text_clears_stale_unheard_text(self):
        worker = self.make_worker()
        worker._last_unheard_text = "older canceled"
        worker._pending_text = "fresh pending"

        worker.play()

        self.assertEqual(worker.played_texts, ["fresh pending"])
        self.assertEqual(worker._last_unheard_text, "")

    def test_play_without_pending_text_does_not_replay_stale_audio(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()

        worker.play()

        self.assertEqual(worker.played_wavs, [])

    def test_play_or_replay_without_pending_text_replays_last_audio(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()

        with patch.object(tts_worker.threading, "Thread", ImmediateThread):
            self.assertTrue(worker.play_or_replay())

        self.assertEqual(worker.played_wavs, [worker._last_wav])

    def test_play_drains_ineligible_items_until_it_claims_current_speech(self):
        worker = self.make_worker()
        events = []
        worker._last_wav = self.temp_wav()
        worker._speech_eligibility = lambda payload: payload["utterance_id"] == "new"
        worker._speech_observer = lambda state, payload: events.append(
            (state, payload["utterance_id"])
        )
        worker.input_queue.put({
            "text": "stale response",
            "_speech_intent": {"utterance_id": "old"},
        })
        worker.input_queue.put({
            "text": "current response",
            "_speech_intent": {"utterance_id": "new"},
        })

        worker.play()

        self.assertEqual(worker.played_texts, ["current response"])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker.played_intents, [{"utterance_id": "new"}])
        self.assertEqual(events, [("cancelled", "old"), ("queued", "new")])

    def test_play_and_replay_do_not_start_while_a_plan_is_active(self):
        worker = self.make_worker()
        worker._playing = True
        worker._pending_text = "next result"
        worker._last_wav = self.temp_wav()

        worker.play()
        worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._pending_text, "next result")

    def test_playback_waits_for_chime_cancellation(self):
        worker = self.make_worker()
        order = []

        class FakeChime:
            def poll(self):
                return None

            def terminate(self):
                order.append("chime-terminate")

            def wait(self, timeout=None):
                order.append("chime-wait")

        worker._chime_proc = FakeChime()

        worker._begin_playback()
        order.append("playback-started" if worker._playing else "not-started")

        self.assertEqual(order, ["chime-terminate", "chime-wait", "playback-started"])

    def test_chime_preview_and_speculation_are_published_before_play_can_claim(self):
        worker = self.make_worker()
        chime_started = threading.Event()
        play_attempted = threading.Event()
        played_during_chime = []
        order = []

        def play_chime():
            order.append("chime")
            chime_started.set()
            self.assertTrue(play_attempted.wait(1.0))
            played_during_chime.append(bool(worker.played_texts))

        def start_speculation(text):
            order.append(("speculation", text))

        worker._play_chime = play_chime
        worker._start_speculation = start_speculation
        original_play_text = worker._play_text

        def play_text(text, **kwargs):
            order.append(("play", text))
            original_play_text(text, **kwargs)

        worker._play_text = play_text

        with patch.object(
            tts_worker,
            "publish_waiting_preview",
            side_effect=lambda text, _intent=None: order.append(("preview", text)),
        ):
            collector = threading.Thread(
                target=worker._handle_collected_chunk,
                args=("Ready response.",),
            )
            collector.start()
            self.assertTrue(chime_started.wait(1.0))

            def request_play():
                play_attempted.set()
                worker.play()

            player = threading.Thread(target=request_play)
            player.start()
            collector.join(timeout=1.0)
            player.join(timeout=1.0)

        self.assertFalse(collector.is_alive())
        self.assertFalse(player.is_alive())
        self.assertEqual(played_during_chime, [False])
        self.assertEqual(
            order,
            [
                "chime",
                ("preview", "Ready response."),
                ("speculation", "Ready response."),
                ("play", "Ready response."),
            ],
        )

    def test_duplicate_play_during_speculative_readiness_starts_one_plan(self):
        worker = self.make_worker()
        del worker._play_text
        worker._kokoro = object()
        worker._pending_text = "Ready response."
        worker._spec_lock = threading.Lock()
        worker._spec_cond = threading.Condition(worker._spec_lock)
        worker._spec_text = "Ready response."
        worker._spec_wav = None
        worker._spec_done = False

        with (
            patch.object(tts_worker.threading, "Thread", IdleThread),
            patch.object(tts_worker, "_notify_state"),
        ):
            worker.play()
            worker.play()

        self.assertTrue(worker._playing)
        self.assertEqual(worker._playback_generation, 1)
        self.assertEqual(worker._pending_text, "")

    def test_stop_observes_process_exit_before_cancellation(self):
        worker = self.make_worker()
        order = []
        intent = {"utterance_id": "speech-1"}

        class FakePlayer:
            def poll(self):
                return None

            def terminate(self):
                order.append("player-terminate")

            def wait(self, timeout=None):
                order.append("player-wait")

        worker._playing = True
        worker._current_proc = FakePlayer()
        worker._current_speech_intent = intent
        worker._speech_observer = lambda state, payload: order.append(state)
        worker._speech_eligibility = None
        worker._chime_proc = None

        worker.stop_playback()

        self.assertEqual(order, ["player-terminate", "player-wait", "cancelled"])
        self.assertIsNone(worker._current_proc)

    def test_stop_lifecycle_is_same_in_queue_and_auto_modes(self):
        for auto_play in (False, True):
            with self.subTest(auto_play=auto_play):
                worker = self.make_worker()
                intent = {"utterance_id": "speech-1"}
                events = []
                worker._auto_play = auto_play
                worker._playing = True
                worker._current_speech_intent = intent
                worker._speech_observer = lambda state, payload: events.append(
                    (state, payload["utterance_id"])
                )

                worker.stop_playback()

                self.assertFalse(worker._playing)
                self.assertEqual(events, [("cancelled", "speech-1")])

    def test_stopped_generation_reports_one_terminal_lifecycle(self):
        worker = self.make_worker()
        intent = {"utterance_id": "speech-1"}
        events = []

        worker._playing = True
        worker._playback_generation = 1
        worker._current_speech_intent = intent
        worker._speech_observer = lambda state, payload: events.append(
            (state, payload["utterance_id"])
        )

        worker.stop_playback()
        worker._finish_playback(1, speech_intent=intent)

        self.assertEqual(events, [("cancelled", "speech-1")])

    def test_late_stopped_generation_cannot_clear_new_playback_owner(self):
        worker = self.make_worker()
        old_intent = {"utterance_id": "speech-1"}
        new_intent = {"utterance_id": "speech-2"}
        new_proc = object()

        worker._playing = True
        worker._playback_generation = 3
        worker._current_speech_intent = new_intent
        worker._current_proc = new_proc

        worker._finish_playback(1, speech_intent=old_intent)

        self.assertTrue(worker._playing)
        self.assertIs(worker._current_proc, new_proc)
        self.assertEqual(worker._current_speech_intent, new_intent)

    def test_collected_chunks_refresh_waiting_preview_before_playback(self):
        worker = self.make_worker()
        speculations = []
        chimes = []
        worker._start_speculation = lambda text: speculations.append(text)
        worker._play_chime = lambda: chimes.append(True)

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._handle_collected_chunk("First part.")
            worker._handle_collected_chunk("Second part.")

        self.assertEqual(
            [(call.args[0], call.kwargs["text"]) for call in notify_state.call_args_list],
            [
                ("message_waiting", "First part."),
                ("message_waiting", "First part. Second part."),
            ],
        )
        self.assertEqual(speculations, ["First part.", "First part. Second part."])
        self.assertEqual(chimes, [True])
        self.assertEqual(worker._last_response_text, "First part. Second part.")

    def test_display_text_is_retained_separately_from_spoken_queue_text(self):
        worker = self.make_worker()
        worker._start_speculation = lambda text: None

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._handle_collected_chunk({
                "text": "Short spoken result.",
                "display_text": "Authoritative **provider** result.",
            })

        notify_state.assert_called_once_with(
            "message_waiting",
            text="Authoritative **provider** result.",
        )
        self.assertEqual(worker._pending_text, "Short spoken result.")
        self.assertEqual(worker._pending_display_text, "Authoritative **provider** result.")

        worker.play()

        self.assertEqual(worker.played_texts, ["Short spoken result."])
        self.assertEqual(worker.played_displays, ["Authoritative **provider** result."])

    def test_speech_presentation_identity_is_published_without_response_metadata(self):
        worker = self.make_worker()
        worker._start_speculation = lambda text: None
        speech_intent = {
            "utterance_id": "replay-2",
            "original_utterance_id": "original-1",
            "replay_of": "original-1",
            "command_seq": 7,
            "command_id": "command-7",
        }

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._handle_collected_chunk({
                "text": "Private response text.",
                "display_text": "Visible response.",
                "_speech_intent": speech_intent,
            })
            worker._last_response_display_text = "Visible response."
            worker.publish_replay_retained(speech_intent, stop_reason="user_stop")

        waiting = notify_state.call_args_list[0]
        self.assertEqual(waiting.args, ("message_waiting",))
        self.assertEqual(waiting.kwargs["presentation_mode"], "explicit_replay")
        self.assertEqual(waiting.kwargs["original_utterance_id"], "original-1")
        self.assertNotIn("spoken_text", waiting.kwargs)
        retained = notify_state.call_args_list[-1]
        self.assertEqual(retained.args, ("replay_retained",))
        self.assertEqual(retained.kwargs["presentation_mode"], "retained_replay")
        self.assertEqual(retained.kwargs["stop_reason"], "user_stop")

    def test_speaking_event_keeps_active_intent_body_when_new_preview_is_queued(self):
        worker = self.make_worker()
        del worker._play_text
        first_intent = {
            "utterance_id": "speech-1",
            "original_utterance_id": "speech-1",
            "command_seq": 1,
            "command_id": "command-1",
        }
        second_intent = {
            "utterance_id": "speech-2",
            "original_utterance_id": "speech-2",
            "command_seq": 2,
            "command_id": "command-2",
        }

        with (
            patch.object(tts_worker.threading, "Thread", IdleThread),
            patch.object(tts_worker, "_notify_state"),
        ):
            worker._play_text(
                "First spoken response.",
                display_text="Complete first display response.",
                speech_intent=first_intent,
            )
            worker._handle_collected_chunk({
                "text": "Second spoken response.",
                "display_text": "bounded final",
                "_speech_intent": second_intent,
            })

        class FakeProc:
            def wait(self):
                return 0

        with (
            patch.object(tts_worker.subprocess, "Popen", return_value=FakeProc()),
            patch.object(tts_worker, "_notify_state") as notify_state,
        ):
            worker._play_wav_blocking("/tmp/first.wav")

        notify_state.assert_called_once_with(
            "speaking",
            text="Complete first display response.",
            utterance_id="speech-1",
            original_utterance_id="speech-1",
            replay_of=None,
            presentation_mode="new_delivery",
            stop_reason=None,
            relay_command_seq=1,
            relay_command_id="command-1",
        )

    def test_sentence_chunks_preserve_sentence_boundaries_and_tail(self):
        chunks = tts_worker._sentence_chunks(" First sentence. Second? Tail without punctuation ")

        self.assertEqual(chunks, ["First sentence.", "Second?", "Tail without punctuation"])

    def test_tutorial_state_events_are_tagged_for_app_side_isolation(self):
        sent = []

        class FakeSocket:
            def sendto(self, data, path):
                sent.append((json.loads(data), path))

            def close(self):
                pass

        with (
            patch.object(tts_worker, "TUTORIAL_TTS_MODE", True),
            patch.object(tts_worker.socket, "socket", return_value=FakeSocket()),
        ):
            tts_worker._notify_state("message_waiting", text="Hello, how are you?")

        self.assertEqual(
            sent,
            [(
                {
                    "source": "tts",
                    "state": "message_waiting",
                    "tutorial": True,
                    "text": "Hello, how are you?",
                },
                tts_worker.VOICE_STATE_SOCK,
            )],
        )

    def test_tutorial_voice_loading_never_downloads_a_model(self):
        worker = TTSWorker.__new__(TTSWorker)
        worker._kokoro = None

        with (
            patch.object(tts_worker, "TUTORIAL_TTS_MODE", True),
            patch.object(tts_worker, "_find_kokoro_model", return_value=None),
            patch.object(tts_worker, "_download_kokoro_model") as download,
        ):
            worker._load_voice()

        download.assert_not_called()

    def test_standalone_tutorial_controls_are_latched_in_stdin_order(self):
        pending = queue.Queue()
        worker = types.SimpleNamespace()

        tts_worker._handle_standalone_line(worker, pending, "Hello, how are you?")
        tts_worker._handle_standalone_line(worker, pending, "__PLAY__")
        tts_worker._handle_standalone_line(worker, pending, "__REPLAY__")
        tts_worker._handle_standalone_line(worker, pending, "__CANCEL__")

        self.assertEqual(pending.get_nowait(), "Hello, how are you?")
        self.assertEqual(pending.get_nowait(), {"_tutorial_control": "play"})
        self.assertEqual(pending.get_nowait(), {"_tutorial_control": "replay"})
        self.assertEqual(pending.get_nowait(), {"_tutorial_control": "skip"})

    def test_tutorial_reply_is_collected_before_its_play_control(self):
        worker = TTSWorker.__new__(TTSWorker)
        events = []
        worker._handle_collected_chunk = lambda text: events.append(("reply", text))
        worker._handle_command = lambda command: events.append(("control", command))

        worker._handle_collected_item("Hello, how are you?")
        worker._handle_collected_item({"_tutorial_control": "play"})

        self.assertEqual(
            events,
            [
                ("reply", "Hello, how are you?"),
                ("control", "play"),
            ],
        )

    def test_start_speculation_targets_first_sentence_chunk(self):
        worker = self.make_chunk_worker()
        synthesized = []
        worker._synthesize_to_wav = lambda text: synthesized.append(text) or self.temp_wav()

        with patch.object(tts_worker.threading, "Thread", ImmediateThread):
            worker._start_speculation("First sentence. Second sentence.")

        self.assertEqual(synthesized, ["First sentence."])
        self.assertEqual(worker._spec_text, "First sentence.")
        self.assertTrue(worker._spec_done)

    def test_chunked_playback_synthesizes_next_chunk_while_current_plays(self):
        worker = self.make_chunk_worker()
        synthesized = []
        played = []
        wav_text = {}
        second_synthesis_started = threading.Event()
        ahead_ready_during_first_play = []
        combined_wav = self.temp_wav()

        def synthesize(text):
            synthesized.append(text)
            if text == "Second sentence.":
                second_synthesis_started.set()
            wav = self.temp_wav()
            wav_text[wav] = text
            return wav

        def play(wav):
            text = wav_text[wav]
            played.append(text)
            if text == "First sentence.":
                ahead_ready_during_first_play.append(second_synthesis_started.wait(1.0))

        worker._synthesize_to_wav = synthesize
        worker._play_wav_blocking = play
        worker._combine_wavs = lambda wavs: combined_wav

        with patch.object(tts_worker, "_notify_state", lambda *args, **kwargs: None):
            worker._speak_chunks(["First sentence.", "Second sentence."], 1)

        self.assertEqual(synthesized, ["First sentence.", "Second sentence."])
        self.assertEqual(played, ["First sentence.", "Second sentence."])
        self.assertEqual(ahead_ready_during_first_play, [True])
        self.assertEqual(worker._last_wav, combined_wav)
        self.assertFalse(worker._playing)

    def test_stop_during_chunk_prevents_later_chunks_from_playing(self):
        worker = self.make_chunk_worker()
        played = []
        wav_text = {}

        def synthesize(text):
            wav = self.temp_wav()
            wav_text[wav] = text
            return wav

        def play(wav):
            text = wav_text[wav]
            played.append(text)
            if text == "First sentence.":
                worker.stop_playback()

        worker._synthesize_to_wav = synthesize
        worker._play_wav_blocking = play

        with patch.object(tts_worker, "_notify_state", lambda *args, **kwargs: None):
            worker._speak_chunks(["First sentence.", "Second sentence."], 1)

        self.assertEqual(played, ["First sentence."])
        self.assertFalse(worker._playing)

    def test_play_wav_blocking_uses_default_rate_multiplier_for_afplay(self):
        worker = self.make_worker()
        worker._rate = 1.3

        class FakeProc:
            def wait(self):
                return 0

        with (
            patch.object(tts_worker, "_notify_state"),
            patch.object(tts_worker.subprocess, "Popen", return_value=FakeProc()) as popen,
        ):
            worker._play_wav_blocking("/tmp/test.wav")

        popen.assert_called_once()
        self.assertEqual(
            popen.call_args.args[0],
            ["afplay", "/tmp/test.wav", "-r", "1.3"],
        )

    def test_preparing_and_afplay_start_are_observed_for_correlated_speech(self):
        worker = self.make_worker()
        del worker._play_text
        intent = {"utterance_id": "speech-1"}
        events = []
        worker._speech_observer = lambda state, payload: events.append(
            (state, payload["utterance_id"])
        )

        with (
            patch.object(tts_worker.threading, "Thread", IdleThread),
            patch.object(tts_worker, "_notify_state"),
        ):
            worker._play_text("Ready.", speech_intent=intent)

        class FakeProc:
            def wait(self):
                return 0

        with (
            patch.object(tts_worker, "_notify_state"),
            patch.object(tts_worker.subprocess, "Popen", return_value=FakeProc()),
        ):
            worker._play_wav_blocking("/tmp/test.wav")

        self.assertEqual(events, [("preparing", "speech-1"), ("afplay_started", "speech-1")])

    def test_missing_voice_model_surfaces_explicit_failure_state(self):
        worker = self.make_chunk_worker()
        worker._kokoro = None
        intent = {"utterance_id": "speech-1"}
        worker._current_speech_intent = intent
        worker._last_response_display_text = "Visible result."
        events = []
        worker._speech_observer = lambda state, payload: events.append(state)

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._speak_chunks(["Visible result."], 1, intent)

        self.assertEqual(notify_state.call_args.args, ("failed",))
        self.assertEqual(notify_state.call_args.kwargs["text"], "Visible result.")
        self.assertEqual(notify_state.call_args.kwargs["utterance_id"], "speech-1")
        self.assertEqual(events, ["failed"])

    def test_failed_first_wav_synthesis_surfaces_explicit_failure_state(self):
        worker = self.make_chunk_worker()
        intent = {"utterance_id": "speech-1"}
        worker._current_speech_intent = intent
        worker._last_response_display_text = "Visible result."
        worker._synthesize_to_wav = lambda _text: None
        events = []
        worker._speech_observer = lambda state, payload: events.append(state)

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._speak_chunks(["Visible result."], 1, intent)

        self.assertEqual(notify_state.call_args.args, ("failed",))
        self.assertEqual(notify_state.call_args.kwargs["text"], "Visible result.")
        self.assertEqual(notify_state.call_args.kwargs["utterance_id"], "speech-1")
        self.assertEqual(events, ["failed"])

    def test_worker_init_defaults_rate_to_one_point_three_when_missing(self):
        with (
            patch.object(tts_worker, "load_config", return_value={"tts": {"voice": "bf_emma"}}),
            patch.object(TTSWorker, "_load_voice", lambda self: None),
            patch.object(tts_worker.threading, "Thread", IdleThread),
        ):
            worker = TTSWorker(queue.Queue())

        self.assertEqual(worker._voice, "bf_emma")
        self.assertEqual(worker._rate, 1.3)


if __name__ == "__main__":
    unittest.main()
