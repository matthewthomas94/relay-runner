from __future__ import annotations

import array
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import custom_voice as cv
from config import load_config
from voice_audio_lease import VoiceAudioLease


def wav(path, seconds=5):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(24000)
        out.writeframes(array.array("h", [1000, -1000] * int(12000 * seconds)).tobytes())
    return path


class CustomVoiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.profile_id = "a" * 32
        self.runtime_id = "b" * 64

    def profile(self, *, draft=False):
        folder = self.root / ".drafts" / self.profile_id if draft else self.root / self.profile_id
        folder.mkdir(parents=True)
        reference = wav(folder / "reference.wav")
        manifest = {"schema_version": 1, "id": self.profile_id, "sample_rate": 24000,
                    "content_hash": hashlib.sha256(reference.read_bytes()).hexdigest(), "runtime_id": self.runtime_id,
                    "name": "Test voice", "duration": 5, "affirmation_version": 1,
                    "affirmation_at": "test", "created_at": "test", "base_voice": "bm_george"}
        (folder / "manifest.json").write_text(json.dumps(manifest))
        return cv.load_profile(self.profile_id, self.root, draft=draft)

    def runtime(self):
        values = {"schema_version": 1, "python": sys.executable,
                  "kokoclone_root": str(self.root / "upstream"), "torch_home": str(self.root / "torch")}
        files = {}
        for key in ("kanade_config", "kanade_weights", "vocos_config", "vocos_weights"):
            path = self.root / key
            path.write_bytes(b"asset")
            values[key] = str(path)
            files[key] = path
        files["cloner"] = self.root / "upstream/core/cloner.py"
        files["chunked_convert"] = self.root / "upstream/core/chunked_convert.py"
        files["wavlm"] = self.root / "torch/hub/checkpoints/wavlm_base_plus.pth"
        for path in files.values():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"asset")
        values["sha256"] = {key: hashlib.sha256(path.read_bytes()).hexdigest() for key, path in files.items()}
        path = self.root / "runtime.json"
        path.write_text(json.dumps(values))
        return cv.load_runtime(path)

    def test_standard_config_compatible_and_custom_id_round_trips(self):
        config = self.root / "config.toml"
        self.assertEqual(load_config(str(config))["tts"]["custom_voice_id"], "")
        config.write_text('[tts]\nvoice = "bf_isabella"\ncustom_voice_id = "' + self.profile_id + '"\n')
        loaded = load_config(str(config))["tts"]
        self.assertEqual(loaded["voice"], "bf_isabella")
        self.assertEqual(loaded["custom_voice_id"], self.profile_id)

    def test_profile_hash_and_draft_resolution(self):
        profile = self.profile(draft=True)
        self.assertEqual(profile.id, self.profile_id)
        self.assertEqual(cv.validate_wav(profile.reference, reference=True), (120000, 24000))
        with self.assertRaises(cv.CustomVoiceError):
            cv.load_profile(self.profile_id, self.root)

    def test_profile_rejects_traversal_and_symlinks(self):
        for profile_id in ("../secret", "/tmp/a", "a" * 31, "A" * 32):
            with self.assertRaises(cv.CustomVoiceError):
                cv.load_profile(profile_id, self.root)
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / self.profile_id).symlink_to(outside, target_is_directory=True)
        with self.assertRaises(cv.CustomVoiceError):
            cv.load_profile(self.profile_id, self.root)

    def test_profile_requires_affirmation_and_exact_audio_duration(self):
        profile = self.profile()
        path = profile.reference.parent / "manifest.json"
        original = json.loads(path.read_text())
        for change in ({"affirmation_version": 0}, {"duration": 8}, {"name": ""}):
            path.write_text(json.dumps({**original, **change}))
            with self.assertRaisesRegex(cv.CustomVoiceError, "invalid_profile"):
                cv.load_profile(profile.id, self.root)

    def test_modified_reference_and_manifest_symlink_rejected(self):
        profile = self.profile()
        profile.reference.write_bytes(b"bad")
        with self.assertRaisesRegex(cv.CustomVoiceError, "reference_changed"):
            cv.load_profile(profile.id, self.root)
        manifest = profile.reference.parent / "manifest.json"
        manifest.unlink()
        manifest.symlink_to(self.root / "other.json")
        with self.assertRaises(cv.CustomVoiceError):
            cv.load_profile(profile.id, self.root)

    def test_audio_rejects_silence_truncation_and_oversize(self):
        path = wav(self.root / "reference.wav")
        data = path.read_bytes()
        path.write_bytes(data[:44] + b"\0" * (len(data) - 44))
        with self.assertRaises(cv.CustomVoiceError):
            cv.validate_wav(path)
        path.write_bytes(data[:-20])
        with self.assertRaises(cv.CustomVoiceError):
            cv.validate_wav(path)
        path.write_bytes(b"x" * 3_000_001)
        with self.assertRaises(cv.CustomVoiceError):
            cv.validate_wav(path)

    def test_runtime_pins_assets_and_rejects_changed_weight(self):
        runtime = self.runtime()
        self.assertEqual(cv.load_runtime(runtime.path, verify_assets=True).fingerprint, runtime.fingerprint)
        Path(runtime.values["kanade_weights"]).write_bytes(b"different")
        with self.assertRaisesRegex(cv.CustomVoiceError, "runtime_asset_changed"):
            cv.load_runtime(runtime.path, verify_assets=True)

    def test_standard_import_never_loads_optional_packages(self):
        result = subprocess.run([sys.executable, "-c", "import custom_voice, sys; assert 'torch' not in sys.modules; assert 'kanade_tokenizer' not in sys.modules"],
                                env={**os.environ, "PYTHONPATH": str(Path(cv.__file__).parent)}, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def fake_process(self, root, behavior="success"):
        # A real OS child exercises deadlines, EOF, cancellation and pipe ownership.
        code = """
import json, sys, pathlib, shutil, time
root = pathlib.Path(sys.argv[1]); behavior = sys.argv[2]
for line in sys.stdin:
    request = json.loads(line); job = request.pop('job')
    if behavior == 'timeout': time.sleep(10)
    if behavior == 'crash': sys.exit(3)
    shutil.copyfile(root / '.jobs' / job / 'source.wav', root / '.jobs' / job / 'output.wav')
    if behavior == 'stale': request['generation'] += 1
    if behavior == 'invalid': (root / '.jobs' / job / 'output.wav').write_bytes(b'bad')
    print(json.dumps(dict(request, ok=True)), flush=True)
"""
        process = subprocess.Popen([sys.executable, "-u", "-c", code, str(root), behavior],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
        self.addCleanup(cv.ConversionClient._terminate, process)
        return process

    def conversion(self, behavior="success", cancelled=lambda: False):
        profile = self.profile()
        runtime = cv.RuntimeManifest(self.root / "runtime.json", self.runtime_id, {})
        client = cv.ConversionClient(root=self.root, chunk_timeout=0.15)
        process = self.fake_process(self.root, behavior)
        client._process = process
        source = wav(self.root / "source.wav", 0.5)
        output = self.root / "output.wav"
        with patch.object(client, "_start", return_value=process):
            try:
                client.convert(source, output, profile, runtime, utterance_id="intent", generation=7, cancelled=cancelled)
            finally:
                client.close()
        return output

    def test_matching_conversion_returns_private_valid_wav_and_cleans_scratch(self):
        output = self.conversion()
        self.assertEqual(cv.validate_wav(output), (12000, 24000))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list((self.root / ".jobs").iterdir()), [])

    def test_stale_identity_rejected(self):
        with self.assertRaisesRegex(cv.CustomVoiceError, "stale_runtime_response"):
            self.conversion("stale")
        self.assertFalse((self.root / "output.wav").exists())

    def test_invalid_output_rejected(self):
        with self.assertRaises(cv.CustomVoiceError):
            self.conversion("invalid")

    def test_crash_resolves_without_hanging(self):
        with self.assertRaisesRegex(cv.CustomVoiceError, "runtime_exited"):
            self.conversion("crash")

    def test_timeout_is_bounded_and_cleans_job(self):
        start = time.monotonic()
        with self.assertRaisesRegex(cv.CustomVoiceError, "conversion_timeout"):
            self.conversion("timeout")
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual(list((self.root / ".jobs").iterdir()), [])

    def test_cancel_during_conversion_never_returns_output(self):
        event = threading.Event()
        timer = threading.Timer(0.06, event.set)
        timer.start()
        self.addCleanup(timer.cancel)
        with self.assertRaises(cv.ConversionCancelled):
            self.conversion("timeout", cancelled=event.is_set)
        self.assertFalse((self.root / "output.wav").exists())

    def test_preview_and_session_cannot_own_audio_together(self):
        with VoiceAudioLease(root=self.root):
            with self.assertRaisesRegex(cv.CustomVoiceError, "audio_busy"):
                VoiceAudioLease(root=self.root, timeout=0.01)
        VoiceAudioLease(root=self.root).close()

    def test_startup_timeout_and_cancellation_terminate_loading_process(self):
        profile = self.profile()
        runtime = cv.RuntimeManifest(self.root / "runtime.json", self.runtime_id,
                                     {"python": sys.executable, "torch_home": str(self.root)})
        source = wav(self.root / "source.wav", 0.5)
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                client = cv.ConversionClient(root=self.root, load_timeout=0.15)
                process = self.fake_process(self.root)  # Waits for input, never sends ready.
                event = threading.Event()
                timer = threading.Timer(0.04 if cancel else 10, event.set)
                timer.start()
                try:
                    with patch.object(cv.subprocess, "Popen", return_value=process):
                        expected = cv.ConversionCancelled if cancel else cv.CustomVoiceError
                        with self.assertRaises(expected):
                            client.convert(source, self.root / "output.wav", profile, runtime,
                                           utterance_id="loading", generation=1, cancelled=event.is_set)
                    self.assertIsNotNone(process.poll())
                    self.assertIsNone(client._process)
                    self.assertFalse((self.root / "output.wav").exists())
                finally:
                    timer.cancel()
                    client.close()


class CustomVoicePlaybackTests(unittest.TestCase):
    def setUp(self):
        try:
            import numpy
        except ImportError:
            import types
            sys.modules.setdefault("numpy", types.SimpleNamespace())
        import tts_worker
        self.tts = tts_worker
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        from unittest.mock import MagicMock
        with patch.object(tts_worker.TTSWorker, "_load_voice"), patch.object(tts_worker.threading, "Thread"), patch.object(tts_worker, "load_config", return_value={"tts": {"voice": "bf_emma", "custom_voice_id": "a" * 32}}):
            self.worker = tts_worker.TTSWorker(queue.Queue(), start_control_socket=False)
        self.worker._kokoro = object()
        self.worker._converter = MagicMock()
        self.worker._playing = True
        self.worker._playback_generation = 1
        self.intent = {"utterance_id": "voice-intent", "command_seq": 2, "command_id": "command"}
        self.worker._current_speech_intent = self.intent
        self.generated = []
        self.played = []
        self.events = []
        self.worker._speech_observer = lambda state, _intent: self.events.append(state)
        self.worker._synthesize_to_wav = self.synthesize
        self.worker._play_wav_blocking = lambda path, **_kwargs: self.played.append(Path(path).read_text())
        for target in ("_notify_state", "load_profile", "load_runtime"):
            mock = patch.object(tts_worker, target)
            mock.start()
            self.addCleanup(mock.stop)

    def synthesize(self, text):
        selection = self.worker._render_local.selection
        self.generated.append((text, selection.voice))
        path = self.root / f"generated-{len(self.generated)}.wav"
        path.write_text(f"{text}:{selection.voice}")
        return str(path)

    def run_chunks(self):
        self.worker._speak_chunks(["One.", "Two.", "Three."], 1, self.intent)

    def test_mid_utterance_fallback_only_replaces_unplayed_text_and_stays_george(self):
        attempts = []
        def convert(source, output, *_args, **_kwargs):
            attempts.append(source.read_text())
            if len(attempts) == 2:
                raise cv.CustomVoiceError("conversion_failed")
            output.write_text(source.read_text() + ":converted")
        self.worker._converter.convert.side_effect = convert
        self.worker._combine_wavs = lambda paths: str(self.root / "combined.wav")
        self.run_chunks()
        self.assertEqual(self.played, ["One.:bf_emma:converted", "Two.:bm_george", "Three.:bm_george"])
        self.assertEqual(len(attempts), 2)
        self.assertIn("completed", self.events)

    def test_cancelled_conversion_never_falls_back_or_plays(self):
        self.worker._converter.convert.side_effect = cv.ConversionCancelled("cancelled")
        self.run_chunks()
        self.assertEqual(self.played, [])
        self.assertEqual(self.generated, [("One.", "bf_emma")])
        self.assertIn("cancelled", self.events)

    def test_invalid_fallback_resolves_failed_presentation(self):
        self.worker._converter.convert.side_effect = cv.CustomVoiceError("conversion_failed")
        self.worker._synthesize_to_wav = lambda _text: None
        self.run_chunks()
        self.assertIn("failed", self.events)
        self.assertFalse(self.worker._playing)

    def test_selection_change_discards_late_conversion(self):
        def convert(_source, output, *_args, **_kwargs):
            output.write_text("late")
            self.worker._selection_epoch += 1
        self.worker._converter.convert.side_effect = convert
        self.run_chunks()
        self.assertEqual(self.played, [])
        self.assertIn("cancelled", self.events)

    def test_custom_mode_does_not_start_parallel_speculative_converter(self):
        self.worker._start_speculation("Unheard response.")
        self.worker._converter.convert.assert_not_called()
        self.assertEqual(self.generated, [])


if __name__ == "__main__":
    unittest.main()
