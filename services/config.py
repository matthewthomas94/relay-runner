"""Shared config loader for Python services. Reads config.toml with env var fallbacks."""

from __future__ import annotations

import os
import sys

# Try tomllib (Python 3.11+), fall back to toml package, fall back to manual parsing
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore


def _parse_toml_simple(text: str) -> dict:
    """Minimal TOML parser for flat sections — fallback when no toml library is available."""
    result: dict = {}
    current_section: dict | None = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section_name = line[1:-1].strip()
            result[section_name] = {}
            current_section = result[section_name]
        elif "=" in line and current_section is not None:
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            # Parse value types
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            elif value == "true":
                value = True  # type: ignore
            elif value == "false":
                value = False  # type: ignore
            else:
                try:
                    value = int(value)  # type: ignore
                except ValueError:
                    try:
                        value = float(value)  # type: ignore
                    except ValueError:
                        pass
            current_section[key] = value
    return result


def _default_config_path() -> str:
    """Default config path: ~/Library/Application Support/relay-runner/config.toml on macOS."""
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(base, "relay-runner", "config.toml")


def load_config(config_path: str | None = None) -> dict:
    """Load config from TOML file. Returns nested dict with defaults."""
    if config_path is None:
        # Check --config CLI arg
        args = sys.argv[1:]
        for i, arg in enumerate(args):
            if arg == "--config" and i + 1 < len(args):
                config_path = args[i + 1]
                break
        if config_path is None:
            config_path = _default_config_path()

    config: dict = {}
    if os.path.exists(config_path):
        with open(config_path, "rb") as f:
            raw = f.read()
        if tomllib is not None:
            config = tomllib.loads(raw.decode("utf-8"))
        else:
            config = _parse_toml_simple(raw.decode("utf-8"))

    # Apply defaults
    defaults = {
        "stt": {
            "model": "parakeet-tdt-v2",
            "input_device": "default",
            "input_mode": "caps_lock_toggle",
            "push_to_talk_key": "",
            "vad_sensitivity": "medium",
        },
        "tts": {
            "engine": "kokoro",
            "voice": "af_bella",
            "rate": 1.0,
            "auto_play": True,
            "chime": "Tink",
            "show_notification": True,
        },
        "controls": {
            "play_pause_key": "F5",
            "skip_key": "Shift+F5",
        },
        "general": {
            "command": "claude",
            "terminal": "warp",
            "auto_start": False,
        },
    }

    for section, values in defaults.items():
        if section not in config:
            config[section] = {}
        for key, default in values.items():
            if key not in config[section]:
                # Check env var override: VOICE_TERMINAL_SECTION_KEY
                env_key = f"VOICE_TERMINAL_{section.upper()}_{key.upper()}"
                env_val = os.environ.get(env_key)
                if env_val is not None:
                    if isinstance(default, bool):
                        config[section][key] = env_val.lower() in ("true", "1", "yes")
                    elif isinstance(default, int):
                        config[section][key] = int(env_val)
                    else:
                        config[section][key] = env_val
                else:
                    config[section][key] = default

    _migrate_config(config)
    return config


def _migrate_config(config: dict):
    """Migrate legacy config values in-place."""
    tts = config.get("tts", {})

    # Migrate say/piper -> kokoro
    if tts.get("engine") in ("say", "piper"):
        tts["engine"] = "kokoro"
        # Map old Piper voice names to Kokoro equivalents
        voice_map = {"Amy": "bf_emma", "Libritts": "af_bella", "Glow-TTS": "af_sarah"}
        tts["voice"] = voice_map.get(tts.get("voice", ""), "af_bella")

    # Migrate WPM rate (int > 10) to speed multiplier (0.5-2.0)
    rate = tts.get("rate", 1.0)
    if isinstance(rate, int) and rate > 10:
        tts["rate"] = round(max(0.5, min(2.0, 2.0 - (rate - 100) * 1.5 / 200)), 1)

    # Migrate old Whisper STT models to Parakeet
    stt = config.get("stt", {})
    if stt.get("model") in ("tiny.en", "base.en", "small.en", "medium.en"):
        stt["model"] = "parakeet-tdt-v2"
    elif stt.get("model") in ("large", "large-v3"):
        stt["model"] = "parakeet-tdt-v3"
