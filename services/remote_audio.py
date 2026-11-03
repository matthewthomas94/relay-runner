"""Relay Remote audio in the Mac's voice (RR-457).

A synthesised sentence becomes AAC-LC in ADTS framing, cut into base64 parts
small enough for one `speech_audio` frame. ADTS needs no container index, so the
parts of every sentence of a reply concatenate into one stream the phone can
decode as it arrives.
"""

from __future__ import annotations

import base64
import os
import subprocess
import tempfile
from dataclasses import dataclass

try:
    from services.relay_remote_protocol import MAX_AUDIO_DATA_BYTES
except ImportError:  # pragma: no cover - run from inside services/
    from relay_remote_protocol import MAX_AUDIO_DATA_BYTES

AFCONVERT = "/usr/bin/afconvert"
AUDIO_FORMAT = "aac"
# Kokoro and the custom voice runtime both render 24 kHz mono.
SAMPLE_RATE = 24000
# Constant bit rate: measured about 6.3 KB/s of ADTS on Kokoro speech.
BIT_RATE = 48000
ENCODE_TIMEOUT = 15.0
# Raw bytes whose base64 is exactly MAX_AUDIO_DATA_BYTES.
_RAW_PART_BYTES = MAX_AUDIO_DATA_BYTES // 4 * 3


class EncodingError(Exception):
    pass


@dataclass(frozen=True)
class AudioPart:
    """One `speech_audio` frame's worth of a reply, without its seq."""

    part: int
    parts: int
    last: bool
    data: str
    format: str = AUDIO_FORMAT
    sample_rate: int = SAMPLE_RATE


def encoder_available() -> bool:
    return os.access(AFCONVERT, os.X_OK)


def encode(wav_path: str) -> bytes:
    """Encode a WAV file to AAC-LC ADTS at SAMPLE_RATE and BIT_RATE."""
    with tempfile.TemporaryDirectory(prefix="relay-remote-audio-") as folder:
        output = os.path.join(folder, "speech.aac")
        try:
            result = subprocess.run(
                [AFCONVERT, "-f", "adts", "-d", f"aac@{SAMPLE_RATE}", "-b", str(BIT_RATE), "-s", "0",
                 wav_path, output],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=ENCODE_TIMEOUT,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise EncodingError("encoder_unavailable") from exc
        if result.returncode != 0 or not os.path.isfile(output):
            raise EncodingError("encoding_failed")
        with open(output, "rb") as handle:
            data = handle.read()
    if not data:
        raise EncodingError("encoding_failed")
    return data


def split(data: bytes) -> list[str]:
    """Consecutive base64 slices, each at most MAX_AUDIO_DATA_BYTES."""
    return [
        base64.b64encode(data[start:start + _RAW_PART_BYTES]).decode("ascii")
        for start in range(0, len(data), _RAW_PART_BYTES)
    ]
