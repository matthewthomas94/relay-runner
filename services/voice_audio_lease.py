"""Cross-process exclusion between Settings audio and response playback."""
import fcntl
import os
import time
from pathlib import Path

from config import _default_config_path


class VoiceAudioError(Exception):
    """Only privacy-safe, typed error codes leave speech rendering and playback."""


def support_root() -> Path:
    return Path(_default_config_path()).parent


class VoiceAudioLease:
    def __init__(self, cancelled=lambda: False, *, root=None, timeout=2):
        self.fd = None
        root = root or support_root()
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(root / "voice-audio.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + timeout
        try:
            while True:
                if cancelled():
                    raise VoiceAudioError("cancelled")
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.fd = fd
                    return
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise VoiceAudioError("audio_busy")
                    time.sleep(0.025)
        except Exception:
            os.close(fd)
            raise

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
