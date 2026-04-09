"""Shared config loader for Python services. Reads config.toml with env var fallbacks."""

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
    """Default config path: ~/Library/Application Support/voice-terminal/config.toml on macOS."""
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(base, "voice-terminal", "config.toml")


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
            "model": "base.en",
            "input_device": "default",
            "input_mode": "always_on",
            "push_to_talk_key": "",
            "vad_sensitivity": "medium",
        },
        "tts": {
            "engine": "say",
            "voice": "Samantha",
            "rate": 185,
            "chime": "Tink",
            "show_notification": True,
        },
        "controls": {
            "play_pause_key": "F5",
            "skip_key": "Shift+F5",
        },
        "general": {
            "command": "claude",
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

    return config
