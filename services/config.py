"""Shared config loader for Python services. Reads config.toml with env var fallbacks."""

from __future__ import annotations

import os
import sys

from codex_model_catalog import (
    CODEX_FAMILIES,
    CODEX_MESSENGER_DEFAULT_FAMILY,
    normalize_codex_family,
)

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

    general_had_provider = (
        isinstance(config.get("general"), dict)
        and "provider" in config.get("general", {})
    )
    general_had_orchestrator_effort = (
        isinstance(config.get("general"), dict)
        and "orchestrator_effort" in config.get("general", {})
    )

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
            "voice": "bm_george",
            "rate": 1.3,
            "auto_play": False,
            "chime": "Tink",
            "show_notification": True,
        },
        "controls": {
            "play_pause_key": "F5",
            "skip_key": "Shift+F5",
        },
        "general": {
            "provider": "codex",
            "command": "codex",
            "terminal": "warp",
            "auto_start": False,
            "working_directory": "",
            "bypass_permissions": True,
            "model": "sol",
            "orchestrator_effort": "xhigh",
            "codex_reasoning_effort": "default",
            "messenger_enabled": True,
            "messenger_model": "luna",
            "messenger_effort": "low",
            "subagent_sizing_policy": "orchestrator_decides",
            "prevent_sleep_while_running": False,
        },
        "orchestrator": {
            "agent": "codex",
            "command": "",
            "port": 7634,
            "workspace_root": "",
            "branch_prefix": "relay/",
            "default_workflow_path": "",
            "worker_health_check_seconds": 600,
        },
        "continuity": {
            "enabled": True,
            "max_attempts": 4,
            "wall_clock_seconds": 120,
            "stable_health_seconds": 60,
            "cooldown_seconds": 900,
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

    _migrate_config(
        config,
        general_had_provider=general_had_provider,
        general_had_orchestrator_effort=general_had_orchestrator_effort,
    )
    return config


def _migrate_config(
    config: dict,
    general_had_provider: bool = True,
    general_had_orchestrator_effort: bool = True,
):
    """Migrate legacy config values in-place."""
    orchestrator = config.get("orchestrator", {})
    # Worker wall-clock deadlines were removed. Keep old config files safe by
    # discarding the legacy value rather than interpreting it as a new limit.
    orchestrator.pop("worker_timeout_seconds", None)

    tts = config.get("tts", {})

    # Migrate say/piper -> kokoro
    if tts.get("engine") in ("say", "piper"):
        tts["engine"] = "kokoro"
        # Map old Piper voice names to Kokoro equivalents
        voice_map = {"Amy": "bf_emma", "Libritts": "af_bella", "Glow-TTS": "af_sarah"}
        tts["voice"] = voice_map.get(tts.get("voice", ""), "af_bella")

    # Migrate WPM rate (int > 10) to speed multiplier (0.5-2.0)
    rate = tts.get("rate", 1.3)
    if isinstance(rate, int) and rate > 10:
        tts["rate"] = round(max(0.5, min(2.0, 2.0 - (rate - 100) * 1.5 / 200)), 1)

    # Migrate old Whisper STT models to Parakeet
    stt = config.get("stt", {})
    if stt.get("model") in ("tiny.en", "base.en", "small.en", "medium.en"):
        stt["model"] = "parakeet-tdt-v2"
    elif stt.get("model") in ("large", "large-v3"):
        stt["model"] = "parakeet-tdt-v3"

    general = config.get("general", {})
    if not general_had_provider:
        command = str(general.get("command", "codex")).strip()
        name = os.path.basename(command).lower()
        general["provider"] = "claude" if "claude" in name else "codex"

    provider = str(general.get("provider", "codex")).strip().lower()
    if provider not in ("codex", "claude"):
        provider = "codex"
    general["provider"] = provider

    command = str(general.get("command", ""))
    if not command.strip().startswith("/"):
        general["command"] = provider

    valid_models = {
        "codex": CODEX_FAMILIES,
        "claude": {"fable", "opus", "sonnet", "haiku"},
    }
    model = str(general.get("model", "sol" if provider == "codex" else "opus")).strip().lower()
    if provider == "codex":
        general["model"] = normalize_codex_family(model)
    else:
        general["model"] = model if model in valid_models[provider] else "opus"

    explicit_reasoning_efforts = {"low", "medium", "high", "xhigh"}

    def valid_orchestrator_efforts(provider_name: str, model_name: str) -> set[str]:
        if provider_name == "codex":
            return explicit_reasoning_efforts | {"max", "ultra"}
        if model_name in {"fable", "opus"}:
            return explicit_reasoning_efforts | {"max"}
        if model_name == "sonnet":
            return {"low", "medium", "high", "max"}
        if model_name == "haiku":
            return {"low"}
        return set()

    def valid_messenger_efforts(provider_name: str, model_name: str) -> set[str]:
        base = {"default", "low", "medium", "high", "xhigh"}
        if provider_name == "codex":
            return base | {"max", "ultra"}
        if model_name in {"best", "fable", "opus"}:
            return base | {"max"}
        if model_name == "sonnet":
            return {"default", "low", "medium", "high", "max"}
        return {"default"}

    def default_orchestrator_effort(provider_name: str, model_name: str) -> str:
        valid_efforts = valid_orchestrator_efforts(provider_name, model_name)
        if "xhigh" in valid_efforts:
            return "xhigh"
        if "high" in valid_efforts:
            return "high"
        return min(valid_efforts)

    codex_reasoning_effort = (
        str(general.get("codex_reasoning_effort", "default")).strip().lower()
    )
    raw_orchestrator_effort = (
        general.get("orchestrator_effort")
        if general_had_orchestrator_effort
        else codex_reasoning_effort
    )
    orchestrator_effort = str(raw_orchestrator_effort or "xhigh").strip().lower()
    if orchestrator_effort == "default":
        orchestrator_effort = "xhigh"
    if orchestrator_effort not in valid_orchestrator_efforts(provider, general["model"]):
        orchestrator_effort = default_orchestrator_effort(provider, general["model"])
    general["orchestrator_effort"] = orchestrator_effort
    codex_efforts_for_model = valid_orchestrator_efforts("codex", general["model"])
    general["codex_reasoning_effort"] = (
        orchestrator_effort
        if provider == "codex" and orchestrator_effort in codex_efforts_for_model
        else "default"
    )

    raw_messenger_model = str(general.get("messenger_model", general["model"])).strip().lower()
    raw_messenger_effort = str(general.get("messenger_effort", "default")).strip().lower()
    # RR-229 persisted the foreground defaults into Messenger configuration,
    # turning the lightweight lane into Sol/Best at their default effort. Those
    # generated pairs were never exposed in Settings, so migrate them back to
    # the provider-specific lightweight defaults.
    if provider == "codex" and (raw_messenger_model, raw_messenger_effort) == ("sol", "default"):
        raw_messenger_model, raw_messenger_effort = "luna", "low"
    elif provider == "claude" and (raw_messenger_model, raw_messenger_effort) == ("best", "default"):
        raw_messenger_model, raw_messenger_effort = "haiku", "default"
    messenger_model = raw_messenger_model
    if provider == "codex":
        messenger_model = normalize_codex_family(
            messenger_model,
            default_family=CODEX_MESSENGER_DEFAULT_FAMILY,
        )
        messenger_effort = (
            "low"
            if messenger_model != raw_messenger_model
            else raw_messenger_effort
        )
        if messenger_effort not in valid_messenger_efforts(provider, messenger_model):
            messenger_effort = "low"
    elif messenger_model not in {"best", "fable", "opus", "sonnet", "haiku"}:
        messenger_model = "haiku"
        messenger_effort = "default"
    else:
        messenger_effort = raw_messenger_effort
        effective_messenger_model = messenger_model
        if messenger_effort not in valid_messenger_efforts(provider, effective_messenger_model):
            messenger_effort = "default"
    general["messenger_model"] = messenger_model
    general["messenger_effort"] = messenger_effort

    policy = str(general.get("subagent_sizing_policy", "orchestrator_decides")).strip().lower()
    general["subagent_sizing_policy"] = (
        policy if policy in {"orchestrator_decides", "user_default"} else "orchestrator_decides"
    )
    if "subagent_model" in general:
        subagent_model = str(general.get("subagent_model", "balanced")).strip().lower()
        general["subagent_model"] = (
            subagent_model if subagent_model in {"fast", "balanced", "strong"} else "balanced"
        )
    if "subagent_effort" in general:
        subagent_effort = str(general.get("subagent_effort", "medium")).strip().lower()
        general["subagent_effort"] = (
            subagent_effort if subagent_effort in {"low", "medium", "high", "xhigh"} else "medium"
        )
