//! `services/config.py`'s `load_config`: the app's `config.toml` with its
//! defaults, `VOICE_TERMINAL_<SECTION>_<KEY>` fallbacks and migrations.
//!
//! The file is read as `tomllib` reads it (`config/toml.rs`); the Python
//! module's hand-rolled fallback parser only ran on Pythons without
//! `tomllib`. A failure is named by the exception `load_config` would have
//! raised, where the Python bridge would have stopped at start-up.

mod toml;

use std::fs;
use std::path::Path;

use super::settings::basename;
use crate::json::{Dict, Value, py_int_from_str, py_strip};
use crate::messenger::catalog;
use crate::support::{Failure, env_optional, env_or};

/// `STANDARD_VOICES`: the Kokoro voices Settings offers; any other saved
/// voice loads as Puck.
pub const STANDARD_VOICES: [&str; 4] = ["am_puck", "bm_george", "bf_isabella", "af_sky"];

/// `STT_MODELS`: each persisted `[stt]` model and its minimum macOS major
/// version, as `STTModelPolicy` in Swift has them.
const STT_MODELS: [(&str, i64); 3] = [
    ("phonon-2", 15),
    ("parakeet-tdt-v2", 14),
    ("parakeet-tdt-v3", 14),
];

const LEGACY_WHISPER_ALIASES: [(&str, &str); 6] = [
    ("tiny.en", "parakeet-tdt-v2"),
    ("base.en", "parakeet-tdt-v2"),
    ("small.en", "parakeet-tdt-v2"),
    ("medium.en", "parakeet-tdt-v2"),
    ("large", "parakeet-tdt-v3"),
    ("large-v3", "parakeet-tdt-v3"),
];

/// `PHONON_DEFAULT_ACTIVE`: must match `STTModelPolicy.phononDefaultActive`.
pub const PHONON_DEFAULT_ACTIVE: bool = true;

const CODEX_DEFAULT_FAMILY: &str = "sol";
const CLAUDE_MODELS: [&str; 6] = [
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
    "haiku",
];
/// The Claude models whose effort goes up to `max`.
const CLAUDE_MAX_EFFORT_MODELS: [&str; 5] = [
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
];
const CODEX_ORCHESTRATOR_EFFORTS: [&str; 6] = ["low", "medium", "high", "xhigh", "max", "ultra"];
const CLAUDE_ORCHESTRATOR_EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
const CODEX_MESSENGER_EFFORTS: [&str; 7] =
    ["default", "low", "medium", "high", "xhigh", "max", "ultra"];
const CLAUDE_MESSENGER_EFFORTS: [&str; 6] = ["default", "low", "medium", "high", "xhigh", "max"];

/// `current_macos_major()`: the running macOS major version, or 0 when it
/// cannot be read.
pub fn current_macos_major() -> i64 {
    #[cfg(target_os = "macos")]
    {
        let mut buffer = [0u8; 64];
        let mut length = buffer.len();
        // SAFETY: the name is NUL-terminated and `length` is the buffer's size.
        let status = unsafe {
            libc::sysctlbyname(
                c"kern.osproductversion".as_ptr(),
                buffer.as_mut_ptr().cast(),
                &mut length,
                std::ptr::null_mut(),
                0,
            )
        };
        if status == 0 {
            let release = String::from_utf8_lossy(&buffer[..length]);
            let release = release.trim_end_matches('\0');
            return py_int_from_str(release.split('.').next().unwrap_or("")).unwrap_or(0);
        }
    }
    0
}

/// `stt_model_supported(model, macos_major)`.
fn stt_model_supported(model: &str, macos_major: i64) -> bool {
    STT_MODELS
        .iter()
        .any(|(known, required)| *known == model && macos_major >= *required)
}

/// `default_stt_model(macos_major, phonon_default_active)`: Phonon on macOS
/// 15 and later once active, else Parakeet v2.
fn default_stt_model(macos_major: i64, phonon_default_active: bool) -> &'static str {
    if phonon_default_active && stt_model_supported("phonon-2", macos_major) {
        "phonon-2"
    } else {
        "parakeet-tdt-v2"
    }
}

/// `_default_config_path()`: `~/Library/Application Support/relay-runner/
/// config.toml` on macOS.
pub fn default_config_path() -> String {
    let home = || env_or("HOME", "").trim_end_matches('/').to_string();
    let base = if cfg!(target_os = "macos") {
        format!("{}/Library/Application Support", home())
    } else {
        env_optional("XDG_CONFIG_HOME").unwrap_or_else(|| format!("{}/.config", home()))
    };
    if base.is_empty() || base.ends_with('/') {
        format!("{base}relay-runner/config.toml")
    } else {
        format!("{base}/relay-runner/config.toml")
    }
}

/// `load_config(config_path)`. With no path it reads `--config <path>` from
/// the process arguments, else the default location. Returns the nested
/// sections (`general`, `tts`, `stt`, ...) as Python's loader does, or the
/// exception it would have raised: an `OSError` kind, `UnicodeDecodeError`,
/// `TOMLDecodeError`, `TypeError` for a section that is not a table, or
/// `ValueError` for an unreadable integer fallback.
pub fn load_config(config_path: Option<&str>) -> Result<Dict, Failure> {
    let path = match config_path {
        Some(path) => path.to_string(),
        None => {
            let arguments: Vec<String> = std::env::args_os()
                .skip(1)
                .map(|argument| argument.to_string_lossy().into_owned())
                .collect();
            arguments
                .windows(2)
                .find(|pair| pair[0] == "--config")
                .map(|pair| pair[1].clone())
                .unwrap_or_else(default_config_path)
        }
    };
    load_config_from(&path, None, PHONON_DEFAULT_ACTIVE, &env_optional)
}

/// `load_config(config_path, macos_major, phonon_default_active)` reading
/// the fallbacks through `environment`.
fn load_config_from(
    path: &str,
    macos_major: Option<i64>,
    phonon_default_active: bool,
    environment: &dyn Fn(&str) -> Option<String>,
) -> Result<Dict, Failure> {
    let config_exists = Path::new(path).exists();
    let mut config = if config_exists {
        let text = String::from_utf8(fs::read(path)?).map_err(|_| Failure("UnicodeDecodeError"))?;
        toml::loads(&text).map_err(|_| Failure("TOMLDecodeError"))?
    } else {
        Dict::new()
    };

    let general_has = |key: &str| {
        config
            .get("general")
            .and_then(Value::as_dict)
            .is_some_and(|general| general.get(key).is_some())
    };
    let general_had_provider = general_has("provider");
    let general_had_orchestrator_effort = general_has("orchestrator_effort");

    // Missing file: the fresh-install default Swift bootstraps. An existing
    // file without a model key: the legacy Parakeet v2 default.
    let stt_model = if config_exists {
        "parakeet-tdt-v2"
    } else {
        default_stt_model(
            macos_major.unwrap_or_else(current_macos_major),
            phonon_default_active,
        )
    };

    for (section, values) in defaults(stt_model) {
        let mut table = match config.get(section) {
            None => Dict::new(),
            Some(Value::Dict(table)) => table.clone(),
            Some(_) => return Err(Failure("TypeError")),
        };
        for (key, default) in values {
            if table.get(key).is_some() {
                continue;
            }
            let variable = format!(
                "VOICE_TERMINAL_{}_{}",
                section.to_uppercase(),
                key.to_uppercase()
            );
            let value = match (environment(&variable), default) {
                (None, default) => default,
                (Some(text), Value::Bool(_)) => {
                    Value::Bool(matches!(text.to_lowercase().as_str(), "true" | "1" | "yes"))
                }
                (Some(text), Value::Int(_)) => {
                    Value::Int(py_int_from_str(&text).ok_or(Failure("ValueError"))?)
                }
                (Some(text), _) => Value::Str(text),
            };
            table.insert(key, value);
        }
        config.insert(section, table);
    }

    migrate(
        &mut config,
        general_had_provider,
        general_had_orchestrator_effort,
    );
    Ok(config)
}

/// The `defaults` table of `load_config`, section by section.
fn defaults(stt_model: &str) -> Vec<(&'static str, Vec<(&'static str, Value)>)> {
    let phonon_migration = if stt_model == "phonon-2" {
        "completed"
    } else {
        ""
    };
    vec![
        (
            "stt",
            vec![
                ("model", stt_model.into()),
                ("input_device", "default".into()),
                ("input_mode", "caps_lock_toggle".into()),
                ("push_to_talk_key", "".into()),
                ("vad_sensitivity", "medium".into()),
                ("phonon_migration", phonon_migration.into()),
                ("phonon_migration_previous_model", "".into()),
            ],
        ),
        (
            "tts",
            vec![
                ("engine", "kokoro".into()),
                ("voice", "am_puck".into()),
                ("rate", 1.3.into()),
                ("auto_play", false.into()),
                ("chime", "Tink".into()),
                ("show_notification", true.into()),
            ],
        ),
        (
            "controls",
            vec![
                ("play_pause_key", "F5".into()),
                ("skip_key", "Shift+F5".into()),
            ],
        ),
        (
            "general",
            vec![
                ("provider", "codex".into()),
                ("command", "codex".into()),
                ("terminal", "warp".into()),
                ("auto_start", false.into()),
                ("working_directory", "".into()),
                ("bypass_permissions", true.into()),
                ("model", "sol".into()),
                ("orchestrator_effort", "medium".into()),
                ("codex_reasoning_effort", "default".into()),
                ("messenger_enabled", true.into()),
                ("messenger_model", "luna".into()),
                ("messenger_effort", "low".into()),
                ("subagent_sizing_policy", "orchestrator_decides".into()),
                ("prevent_sleep_while_running", false.into()),
            ],
        ),
        (
            "orchestrator",
            vec![
                ("agent", "".into()),
                ("command", "".into()),
                ("port", 7634i64.into()),
                ("workspace_root", "".into()),
                ("branch_prefix", "relay/".into()),
                ("default_workflow_path", "".into()),
                ("worker_health_check_seconds", 600i64.into()),
            ],
        ),
        (
            "continuity",
            vec![
                ("enabled", true.into()),
                ("max_attempts", 4i64.into()),
                ("wall_clock_seconds", 120i64.into()),
                ("stable_health_seconds", 60i64.into()),
                ("cooldown_seconds", 900i64.into()),
            ],
        ),
    ]
}

/// `str(d.get(key, default)).strip()`.
fn stripped(dict: &Dict, key: &str, default: &str) -> String {
    let text = dict
        .get(key)
        .map_or_else(|| default.to_string(), Value::py_str);
    py_strip(&text).to_string()
}

/// `str(d.get(key, default)).strip().lower()`.
fn lowered(dict: &Dict, key: &str, default: &str) -> String {
    stripped(dict, key, default).to_lowercase()
}

/// The section `name` of the loaded config, to change and put back.
fn section(config: &Dict, name: &str) -> Dict {
    config
        .get(name)
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default()
}

/// `round(value, 1)`: formatting rounds the exact binary value half to
/// even, as Python does.
fn round_one_place(value: f64) -> f64 {
    format!("{value:.1}").parse().unwrap_or(value)
}

fn provider_for_command(command: &str) -> &'static str {
    if basename(command).to_lowercase().contains("claude") {
        "claude"
    } else {
        "codex"
    }
}

fn valid_orchestrator_efforts(provider: &str, model: &str) -> &'static [&'static str] {
    if provider == "codex" {
        &CODEX_ORCHESTRATOR_EFFORTS
    } else if CLAUDE_MAX_EFFORT_MODELS.contains(&model) {
        &CLAUDE_ORCHESTRATOR_EFFORTS
    } else if model == "haiku" {
        &["low"]
    } else {
        &[]
    }
}

fn valid_messenger_efforts(provider: &str, model: &str) -> &'static [&'static str] {
    if provider == "codex" {
        &CODEX_MESSENGER_EFFORTS
    } else if model == "best" || CLAUDE_MAX_EFFORT_MODELS.contains(&model) {
        &CLAUDE_MESSENGER_EFFORTS
    } else {
        &["default"]
    }
}

/// `_migrate_config`: legacy values migrated in place.
fn migrate(config: &mut Dict, general_had_provider: bool, general_had_orchestrator_effort: bool) {
    let mut orchestrator = section(config, "orchestrator");
    // Worker wall-clock deadlines were removed; an old value is discarded
    // rather than read as a new limit.
    orchestrator.remove("worker_timeout_seconds");
    config.insert("orchestrator", orchestrator);

    let mut tts = section(config, "tts");
    // RR-462 removed custom voices; speech keeps the built-in voice.
    tts.remove("custom_voice_id");
    if tts
        .get("engine")
        .is_some_and(|engine| engine.is_str("say") || engine.is_str("piper"))
    {
        tts.insert("engine", "kokoro");
    }
    let standard_voice = tts
        .get("voice")
        .and_then(Value::as_str)
        .is_some_and(|voice| STANDARD_VOICES.contains(&voice));
    if !standard_voice {
        tts.insert("voice", "am_puck");
    }
    // A WPM rate (an integer above 10) becomes a speed multiplier.
    if let Some(&Value::Int(rate)) = tts.get("rate")
        && rate > 10
    {
        let speed = 2.0 - (rate - 100) as f64 * 1.5 / 200.0;
        tts.insert("rate", round_one_place(speed.clamp(0.5, 2.0)));
    }
    config.insert("tts", tts);

    // Whisper models become Parakeet; unknown ids stay verbatim so the Swift
    // resolver can report them.
    let mut stt = section(config, "stt");
    let replacement = stt.get("model").and_then(Value::as_str).and_then(|model| {
        LEGACY_WHISPER_ALIASES
            .iter()
            .find(|(alias, _)| *alias == model)
            .map(|(_, target)| *target)
    });
    if let Some(target) = replacement {
        stt.insert("model", target);
    }
    config.insert("stt", stt);

    let mut general = section(config, "general");
    migrate_general(
        &mut general,
        general_had_provider,
        general_had_orchestrator_effort,
    );
    config.insert("general", general);
}

fn migrate_general(
    general: &mut Dict,
    general_had_provider: bool,
    general_had_orchestrator_effort: bool,
) {
    if !general_had_provider {
        let provider = provider_for_command(&stripped(general, "command", "codex"));
        general.insert("provider", provider);
    }

    let mut provider = lowered(general, "provider", "codex");
    if provider != "codex" && provider != "claude" {
        provider = "codex".to_string();
    }
    general.insert("provider", provider.as_str());

    let command = stripped(general, "command", "");
    if !command.starts_with('/') || provider_for_command(&command) != provider {
        general.insert("command", provider.as_str());
    }

    let default_model = if provider == "codex" { "sol" } else { "opus" };
    let raw_model = lowered(general, "model", default_model);
    let model = if provider == "codex" {
        catalog::normalize_codex_family(&raw_model, CODEX_DEFAULT_FAMILY)
    } else if CLAUDE_MODELS.contains(&raw_model.as_str()) {
        raw_model
    } else {
        "opus".to_string()
    };
    general.insert("model", model.as_str());

    let codex_reasoning_effort = lowered(general, "codex_reasoning_effort", "default");
    let raw_orchestrator_effort = if general_had_orchestrator_effort {
        general.get("orchestrator_effort").cloned()
    } else {
        Some(Value::Str(codex_reasoning_effort))
    };
    let mut orchestrator_effort = match raw_orchestrator_effort {
        Some(value) if value.truthy() => py_strip(&value.py_str()).to_lowercase(),
        _ => "medium".to_string(),
    };
    if orchestrator_effort == "default" {
        orchestrator_effort = "medium".to_string();
    }
    let valid = valid_orchestrator_efforts(&provider, &model);
    if !valid.contains(&orchestrator_effort.as_str()) {
        orchestrator_effort = if valid.contains(&"medium") {
            "medium"
        } else if valid.contains(&"high") {
            "high"
        } else {
            valid.iter().copied().min().unwrap_or("medium")
        }
        .to_string();
    }
    general.insert("orchestrator_effort", orchestrator_effort.as_str());
    let codex_effort = provider == "codex"
        && valid_orchestrator_efforts("codex", &model).contains(&orchestrator_effort.as_str());
    general.insert(
        "codex_reasoning_effort",
        if codex_effort {
            orchestrator_effort.as_str()
        } else {
            "default"
        },
    );

    let mut raw_messenger_model = lowered(general, "messenger_model", &model);
    let mut raw_messenger_effort = lowered(general, "messenger_effort", "default");
    // RR-229 persisted the foreground defaults into the messenger settings;
    // those generated pairs go back to the lightweight defaults.
    if provider == "codex"
        && (raw_messenger_model.as_str(), raw_messenger_effort.as_str()) == ("sol", "default")
    {
        (raw_messenger_model, raw_messenger_effort) = ("luna".into(), "low".into());
    } else if provider == "claude"
        && (raw_messenger_model.as_str(), raw_messenger_effort.as_str()) == ("best", "default")
    {
        (raw_messenger_model, raw_messenger_effort) = ("haiku".into(), "default".into());
    }
    let (messenger_model, messenger_effort) = if provider == "codex" {
        let model = catalog::normalize_codex_family(
            &raw_messenger_model,
            catalog::CODEX_MESSENGER_DEFAULT_FAMILY,
        );
        let mut effort = if model != raw_messenger_model
            && catalog::codex_family_for_model(&raw_messenger_model).is_none()
        {
            "low".to_string()
        } else {
            raw_messenger_effort
        };
        if !valid_messenger_efforts(&provider, &model).contains(&effort.as_str()) {
            effort = "low".to_string();
        }
        (model, effort)
    } else if raw_messenger_model != "best"
        && !CLAUDE_MODELS.contains(&raw_messenger_model.as_str())
    {
        ("haiku".to_string(), "default".to_string())
    } else {
        let mut effort = raw_messenger_effort;
        if !valid_messenger_efforts(&provider, &raw_messenger_model).contains(&effort.as_str()) {
            effort = "default".to_string();
        }
        (raw_messenger_model, effort)
    };
    general.insert("messenger_model", messenger_model);
    general.insert("messenger_effort", messenger_effort);

    let policy = lowered(general, "subagent_sizing_policy", "orchestrator_decides");
    general.insert(
        "subagent_sizing_policy",
        if policy == "orchestrator_decides" || policy == "user_default" {
            policy.as_str()
        } else {
            "orchestrator_decides"
        },
    );
    if general.get("subagent_model").is_some() {
        let model = lowered(general, "subagent_model", "balanced");
        let valid = ["fast", "balanced", "strong"].contains(&model.as_str());
        general.insert(
            "subagent_model",
            if valid { model.as_str() } else { "balanced" },
        );
    }
    if general.get("subagent_effort").is_some() {
        let effort = lowered(general, "subagent_effort", "medium");
        let valid = ["low", "medium", "high", "xhigh"].contains(&effort.as_str());
        general.insert(
            "subagent_effort",
            if valid { effort.as_str() } else { "medium" },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::dumps;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_FILE: AtomicUsize = AtomicUsize::new(0);

    /// `load_config` on a file holding `text` (no file for `None`), with
    /// `environment` as the only variables.
    fn load_with(
        text: Option<&str>,
        macos_major: i64,
        phonon_default_active: bool,
        environment: &[(&str, &str)],
    ) -> Result<Dict, Failure> {
        let folder = std::env::temp_dir().join(format!(
            "relay-rs-config-{}-{}",
            std::process::id(),
            NEXT_FILE.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("config.toml");
        if let Some(text) = text {
            fs::write(&path, text).unwrap();
        }
        let lookup = |name: &str| {
            environment
                .iter()
                .find(|(variable, _)| *variable == name)
                .map(|(_, value)| value.to_string())
        };
        let config = load_config_from(
            &path.to_string_lossy(),
            Some(macos_major),
            phonon_default_active,
            &lookup,
        );
        let _ = fs::remove_dir_all(&folder);
        config
    }

    fn load(text: &str) -> Dict {
        load_with(Some(text), 26, true, &[]).unwrap()
    }

    fn get<'a>(config: &'a Dict, section: &str, key: &str) -> Option<&'a Value> {
        config
            .get(section)
            .and_then(Value::as_dict)
            .and_then(|s| s.get(key))
    }

    fn text(config: &Dict, section: &str, key: &str) -> String {
        get(config, section, key)
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("{section}.{key} is not text"))
            .to_string()
    }

    fn flag(config: &Dict, section: &str, key: &str) -> bool {
        match get(config, section, key) {
            Some(Value::Bool(flag)) => *flag,
            other => panic!("{section}.{key} is {other:?}"),
        }
    }

    fn number(config: &Dict, section: &str, key: &str) -> f64 {
        get(config, section, key)
            .and_then(Value::py_float)
            .unwrap_or_else(|| panic!("{section}.{key} is not a number"))
    }

    // The expected text is `json.dumps(load_config(path, macos_major=15))`
    // from services/config.py on Python 3.14.
    #[test]
    fn whole_configs_match_python() {
        let missing = load_with(None, 15, true, &[]).unwrap();
        assert_eq!(
            dumps(&Value::Dict(missing)),
            concat!(
                r#"{"stt": {"model": "phonon-2", "input_device": "default", "input_mode": "caps_lock_toggle", "push_to_talk_key": "", "vad_sensitivity": "medium", "phonon_migration": "completed", "phonon_migration_previous_model": ""}, "#,
                r#""tts": {"engine": "kokoro", "voice": "am_puck", "rate": 1.3, "auto_play": false, "chime": "Tink", "show_notification": true}, "#,
                r#""controls": {"play_pause_key": "F5", "skip_key": "Shift+F5"}, "#,
                r#""general": {"provider": "codex", "command": "codex", "terminal": "warp", "auto_start": false, "working_directory": "", "bypass_permissions": true, "model": "sol", "orchestrator_effort": "medium", "codex_reasoning_effort": "medium", "messenger_enabled": true, "messenger_model": "luna", "messenger_effort": "low", "subagent_sizing_policy": "orchestrator_decides", "prevent_sleep_while_running": false}, "#,
                r#""orchestrator": {"agent": "", "command": "", "port": 7634, "workspace_root": "", "branch_prefix": "relay/", "default_workflow_path": "", "worker_health_check_seconds": 600}, "#,
                r#""continuity": {"enabled": true, "max_attempts": 4, "wall_clock_seconds": 120, "stable_health_seconds": 60, "cooldown_seconds": 900}}"#
            )
        );
        let legacy = load_with(
            Some(concat!(
                "[awareness]\nscreen_glow = true\n",
                "[general]\ncommand = \"/opt/homebrew/bin/claude\"\nmodel = \"Best\"\n",
                "codex_reasoning_effort = \"high\"\nmessenger_model = \"best\"\n",
                "messenger_effort = \"default\"\nsubagent_model = \"huge\"\n",
                "[tts]\nengine = \"piper\"\nvoice = \"en_US-amy\"\nrate = 200\n",
                "[stt]\nmodel = \"large\"\n",
                "[orchestrator]\nworker_timeout_seconds = 30\nport = 9000\n",
            )),
            15,
            true,
            &[("VOICE_TERMINAL_CONTINUITY_MAX_ATTEMPTS", " 7 ")],
        )
        .unwrap();
        assert_eq!(
            dumps(&Value::Dict(legacy)),
            concat!(
                r#"{"awareness": {"screen_glow": true}, "#,
                r#""general": {"command": "/opt/homebrew/bin/claude", "model": "opus", "codex_reasoning_effort": "default", "messenger_model": "haiku", "messenger_effort": "default", "subagent_model": "balanced", "provider": "claude", "terminal": "warp", "auto_start": false, "working_directory": "", "bypass_permissions": true, "orchestrator_effort": "high", "messenger_enabled": true, "subagent_sizing_policy": "orchestrator_decides", "prevent_sleep_while_running": false}, "#,
                r#""tts": {"engine": "kokoro", "voice": "am_puck", "rate": 1.2, "auto_play": false, "chime": "Tink", "show_notification": true}, "#,
                r#""stt": {"model": "parakeet-tdt-v3", "input_device": "default", "input_mode": "caps_lock_toggle", "push_to_talk_key": "", "vad_sensitivity": "medium", "phonon_migration": "", "phonon_migration_previous_model": ""}, "#,
                r#""orchestrator": {"port": 9000, "agent": "", "command": "", "workspace_root": "", "branch_prefix": "relay/", "default_workflow_path": "", "worker_health_check_seconds": 600}, "#,
                r#""controls": {"play_pause_key": "F5", "skip_key": "Shift+F5"}, "#,
                r#""continuity": {"enabled": true, "max_attempts": 7, "wall_clock_seconds": 120, "stable_health_seconds": 60, "cooldown_seconds": 900}}"#
            )
        );
    }

    #[test]
    fn a_missing_key_comes_from_the_environment() {
        let file = "[general]\nprovider = \"claude\"\n[tts]\nauto_play = false\n";
        let variables = [
            ("VOICE_TERMINAL_GENERAL_MESSENGER_ENABLED", "false"),
            ("VOICE_TERMINAL_TTS_AUTO_PLAY", "true"),
            ("VOICE_TERMINAL_TTS_SHOW_NOTIFICATION", "nope"),
            ("VOICE_TERMINAL_ORCHESTRATOR_PORT", "8_000"),
            ("VOICE_TERMINAL_TTS_RATE", "1.5"),
            ("VOICE_TERMINAL_STT_INPUT_MODE", "push_to_talk"),
        ];
        let config = load_with(Some(file), 26, true, &variables).unwrap();
        assert!(!flag(&config, "general", "messenger_enabled"));
        // A key the file has is never overridden.
        assert!(!flag(&config, "tts", "auto_play"));
        assert!(!flag(&config, "tts", "show_notification"));
        assert!(matches!(
            get(&config, "orchestrator", "port"),
            Some(Value::Int(8000))
        ));
        // Only bool and int defaults are converted; a float stays text.
        assert_eq!(text(&config, "tts", "rate"), "1.5");
        assert_eq!(text(&config, "stt", "input_mode"), "push_to_talk");
        assert!(matches!(
            load_with(
                Some(file),
                26,
                true,
                &[("VOICE_TERMINAL_ORCHESTRATOR_PORT", "x")]
            ),
            Err(Failure("ValueError"))
        ));
    }

    #[test]
    fn unreadable_files_fail_as_python_raises() {
        assert!(matches!(
            load_with(Some("[general\n"), 26, true, &[]),
            Err(Failure("TOMLDecodeError"))
        ));
        assert!(matches!(
            load_with(Some("general = 1\n"), 26, true, &[]),
            Err(Failure("TypeError"))
        ));
        let folder =
            std::env::temp_dir().join(format!("relay-rs-config-bytes-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("config.toml");
        fs::write(&path, b"a = \"\xff\"\n").unwrap();
        let result = load_config_from(&path.to_string_lossy(), Some(26), true, &|_| None);
        let _ = fs::remove_dir_all(&folder);
        assert!(matches!(result, Err(Failure("UnicodeDecodeError"))));
    }

    #[test]
    fn codex_suffixed_models_migrate_to_families() {
        for (model, family) in [
            ("gpt-5.6-sol", "sol"),
            ("gpt-5.6-terra", "terra"),
            ("gpt-5.6-luna", "luna"),
        ] {
            let config = load(&format!(
                "[general]\nprovider = \"codex\"\nmodel = \"{model}\"\n"
            ));
            assert_eq!(text(&config, "general", "provider"), "codex");
            assert_eq!(text(&config, "general", "model"), family);
        }
    }

    #[test]
    fn codex_gpt56_preview_model_resets_for_claude() {
        let config = load("[general]\nprovider = \"claude\"\nmodel = \"gpt-5.6-sol\"\n");
        assert_eq!(text(&config, "general", "provider"), "claude");
        assert_eq!(text(&config, "general", "model"), "opus");
    }

    #[test]
    fn load_config_defaults_codex_reasoning_effort() {
        let config = load_with(None, 26, true, &[]).unwrap();
        assert_eq!(text(&config, "tts", "voice"), "am_puck");
        assert_eq!(number(&config, "tts", "rate"), 1.3);
        assert_eq!(text(&config, "general", "codex_reasoning_effort"), "medium");
        assert_eq!(text(&config, "general", "orchestrator_effort"), "medium");
        assert_eq!(
            text(&config, "general", "subagent_sizing_policy"),
            "orchestrator_decides"
        );
        assert!(get(&config, "general", "subagent_model").is_none());
        assert!(get(&config, "general", "subagent_effort").is_none());
        assert!(flag(&config, "general", "messenger_enabled"));
        assert_eq!(text(&config, "general", "messenger_model"), "luna");
        assert_eq!(text(&config, "general", "messenger_effort"), "low");
        assert!(!flag(&config, "general", "prevent_sleep_while_running"));
        assert_eq!(
            number(&config, "orchestrator", "worker_health_check_seconds"),
            600.0
        );
        assert!(get(&config, "orchestrator", "worker_timeout_seconds").is_none());
    }

    #[test]
    fn legacy_custom_voice_id_loads_and_is_dropped() {
        let config = load("[tts]\nvoice = \"bm_george\"\ncustom_voice_id = \"x\"\n");
        assert_eq!(text(&config, "tts", "voice"), "bm_george");
        assert!(get(&config, "tts", "custom_voice_id").is_none());
    }

    #[test]
    fn claude_orchestrator_defaults_to_explicit_opus_and_medium() {
        let config = load("[general]\nprovider = \"claude\"\n");
        assert_eq!(text(&config, "general", "model"), "opus");
        assert_eq!(text(&config, "general", "orchestrator_effort"), "medium");
        assert_eq!(text(&config, "general", "messenger_model"), "haiku");
        assert_eq!(text(&config, "general", "messenger_effort"), "default");
    }

    #[test]
    fn worker_agent_follows_general_provider_and_drops_other_provider_command() {
        let config = load(
            "[general]\nprovider = \"claude\"\n\
             command = \"/Applications/ChatGPT.app/Contents/Resources/codex\"\n",
        );
        assert_eq!(text(&config, "orchestrator", "agent"), "");
        assert_eq!(text(&config, "general", "command"), "claude");
    }

    #[test]
    fn custom_absolute_command_for_selected_provider_is_kept() {
        for (provider, command) in [
            (
                "codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
            ),
            ("claude", "/opt/homebrew/bin/claude"),
        ] {
            let config = load(&format!(
                "[general]\nprovider = \"{provider}\"\ncommand = \"{command}\"\n"
            ));
            assert_eq!(text(&config, "general", "command"), command);
        }
        // Without a provider, the command's name chooses it.
        let config = load("[general]\ncommand = \"/opt/homebrew/bin/Claude\"\n");
        assert_eq!(text(&config, "general", "provider"), "claude");
    }

    #[test]
    fn legacy_orchestrator_values_migrate_without_resetting_explicit_values() {
        for (provider, model, effort, expected_model, expected_effort) in [
            ("claude", "best", "default", "opus", "medium"),
            ("codex", "sol", "high", "sol", "high"),
        ] {
            let config = load(&format!(
                "[general]\nprovider = \"{provider}\"\nmodel = \"{model}\"\n\
                 orchestrator_effort = \"{effort}\"\n"
            ));
            assert_eq!(text(&config, "general", "model"), expected_model);
            assert_eq!(
                text(&config, "general", "orchestrator_effort"),
                expected_effort
            );
        }
    }

    #[test]
    fn tts_values_load_with_their_defaults() {
        let config = load("\n    [general]\n    prevent_sleep_while_running = true\n");
        assert!(flag(&config, "general", "prevent_sleep_while_running"));

        let config = load("\n    [tts]\n    voice = \"bf_isabella\"\n    auto_play = true\n");
        assert_eq!(text(&config, "tts", "voice"), "bf_isabella");
        assert!(flag(&config, "tts", "auto_play"));
        assert_eq!(number(&config, "tts", "rate"), 1.3);

        let config = load("[tts]\nvoice = \"af_bella\"\n");
        assert_eq!(text(&config, "tts", "voice"), "am_puck");

        let config = load("[tts]\nrate = 1.1\n");
        assert_eq!(number(&config, "tts", "rate"), 1.1);
    }

    #[test]
    fn a_words_per_minute_rate_becomes_a_multiplier() {
        let rate = |value: &str| number(&load(&format!("[tts]\nrate = {value}\n")), "tts", "rate");
        // round(1.25, 1) is 1.2 in Python: the tie goes to even.
        assert_eq!(rate("200"), 1.2);
        assert_eq!(rate("160"), 1.6);
        assert_eq!(rate("50"), 2.0);
        assert_eq!(rate("900"), 0.5);
        assert!(matches!(
            get(&load("[tts]\nrate = 10\n"), "tts", "rate"),
            Some(Value::Int(10))
        ));
        assert!(
            matches!(get(&load("[tts]\nrate = 200.0\n"), "tts", "rate"), Some(Value::Float(r)) if *r == 200.0)
        );
    }

    #[test]
    fn codex_reasoning_effort_normalizes() {
        let config = load(
            "[general]\nprovider = \"codex\"\ncommand = \"codex\"\nmodel = \"gpt-5.5\"\n\
             codex_reasoning_effort = \" XHIGH \"\n",
        );
        assert_eq!(text(&config, "general", "provider"), "codex");
        assert_eq!(text(&config, "general", "orchestrator_effort"), "xhigh");
        assert_eq!(text(&config, "general", "codex_reasoning_effort"), "xhigh");
    }

    #[test]
    fn model_specific_claude_orchestrator_effort_max_is_allowed() {
        let config = load(
            "[general]\nprovider = \"claude\"\ncommand = \"claude\"\nmodel = \"fable\"\n\
             orchestrator_effort = \"max\"\n",
        );
        assert_eq!(text(&config, "general", "model"), "fable");
        assert_eq!(text(&config, "general", "orchestrator_effort"), "max");
        assert_eq!(
            text(&config, "general", "codex_reasoning_effort"),
            "default"
        );
    }

    #[test]
    fn unknown_codex_orchestrator_effort_is_rejected() {
        let config = load(
            "[general]\nprovider = \"codex\"\ncommand = \"codex\"\n\
             orchestrator_effort = \"banana\"\ncodex_reasoning_effort = \"high\"\n",
        );
        assert_eq!(text(&config, "general", "orchestrator_effort"), "medium");
        assert_eq!(text(&config, "general", "codex_reasoning_effort"), "medium");
    }

    #[test]
    fn rr150_model_effort_matrix_applies() {
        for (provider, model, effort, expected_model, expected_effort) in [
            ("codex", "sol", "ultra", "sol", "ultra"),
            ("codex", "terra", "max", "terra", "max"),
            ("codex", "luna", "max", "luna", "max"),
            ("codex", "luna", "ultra", "luna", "ultra"),
            ("codex", "gpt-5.5", "xhigh", "sol", "xhigh"),
            ("codex", "gpt-6.1-terra", "max", "terra", "max"),
            ("codex", "gpt-5.3-codex-spark", "xhigh", "sol", "xhigh"),
            ("codex", "default", "low", "sol", "low"),
            ("claude", "best", "max", "opus", "max"),
            ("claude", "fable", "xhigh", "fable", "xhigh"),
            (
                "claude",
                "claude-fable-5-2",
                "max",
                "claude-fable-5-2",
                "max",
            ),
            ("claude", "opus", "max", "opus", "max"),
            ("claude", "sonnet", "max", "sonnet", "max"),
            ("claude", "sonnet", "xhigh", "sonnet", "xhigh"),
            ("claude", "haiku", "low", "haiku", "low"),
            ("claude", "haiku", "high", "haiku", "low"),
            ("claude", "default", "low", "opus", "low"),
        ] {
            let config = load(&format!(
                "[general]\nprovider = \"{provider}\"\ncommand = \"{provider}\"\n\
                 model = \"{model}\"\norchestrator_effort = \"{effort}\"\n"
            ));
            assert_eq!(text(&config, "general", "model"), expected_model, "{model}");
            assert_eq!(
                text(&config, "general", "orchestrator_effort"),
                expected_effort,
                "{model} {effort}"
            );
        }
    }

    #[test]
    fn subagent_defaults_normalize() {
        let config = load(
            "[general]\nsubagent_sizing_policy = \"user_default\"\n\
             subagent_model = \" STRONG \"\nsubagent_effort = \" XHIGH \"\n",
        );
        assert_eq!(
            text(&config, "general", "subagent_sizing_policy"),
            "user_default"
        );
        assert_eq!(text(&config, "general", "subagent_model"), "strong");
        assert_eq!(text(&config, "general", "subagent_effort"), "xhigh");
    }

    #[test]
    fn messenger_settings_follow_the_provider() {
        let config = load(
            "[general]\nprovider = \"claude\"\ncommand = \"claude\"\nmessenger_enabled = false\n\
             messenger_model = \"sonnet\"\nmessenger_effort = \"low\"\n",
        );
        assert!(!flag(&config, "general", "messenger_enabled"));
        assert_eq!(text(&config, "general", "messenger_model"), "sonnet");
        assert_eq!(text(&config, "general", "messenger_effort"), "low");

        let config = load(
            "[general]\nprovider = \"codex\"\ncommand = \"codex\"\n\
             messenger_model = \"haiku\"\nmessenger_effort = \"ultra\"\n",
        );
        assert_eq!(text(&config, "general", "messenger_model"), "luna");
        assert_eq!(text(&config, "general", "messenger_effort"), "low");

        for (provider, model, effort, expected_model, expected_effort) in [
            ("codex", "sol", "default", "luna", "low"),
            ("claude", "best", "default", "haiku", "default"),
            ("codex", "gpt-6-astra", "ultra", "astra", "ultra"),
            ("claude", "best", "max", "best", "max"),
            ("claude", "haiku", "high", "haiku", "default"),
        ] {
            let config = load(&format!(
                "[general]\nprovider = \"{provider}\"\nmessenger_model = \"{model}\"\n\
                 messenger_effort = \"{effort}\"\n"
            ));
            assert_eq!(text(&config, "general", "messenger_model"), expected_model);
            assert_eq!(
                text(&config, "general", "messenger_effort"),
                expected_effort
            );
        }
    }

    #[test]
    fn fresh_stt_default_is_os_aware_and_active() {
        let stt = |major: i64, active: bool| {
            let config = load_with(None, major, active, &[]).unwrap();
            (
                text(&config, "stt", "model"),
                text(&config, "stt", "phonon_migration"),
            )
        };
        assert_eq!(stt(14, true), ("parakeet-tdt-v2".into(), "".into()));
        assert_eq!(stt(15, true), ("phonon-2".into(), "completed".into()));
        assert_eq!(stt(15, false), ("parakeet-tdt-v2".into(), "".into()));
    }

    #[test]
    fn existing_stt_models_aliases_and_unknown_ids_load_verbatim() {
        for (raw, expected) in [
            ("parakeet-tdt-v2", "parakeet-tdt-v2"),
            ("parakeet-tdt-v3", "parakeet-tdt-v3"),
            ("phonon-2", "phonon-2"),
            ("medium.en", "parakeet-tdt-v2"),
            ("tiny.en", "parakeet-tdt-v2"),
            ("large-v3", "parakeet-tdt-v3"),
            ("whisper-xl", "whisper-xl"),
        ] {
            let config =
                load_with(Some(&format!("[stt]\nmodel = \"{raw}\"\n")), 15, true, &[]).unwrap();
            assert_eq!(text(&config, "stt", "model"), expected);
            assert_eq!(text(&config, "stt", "phonon_migration"), "");
        }
        // An existing file without a model key keeps the legacy v2 default.
        let config = load_with(Some("[stt]\nvad_sensitivity = \"low\"\n"), 15, true, &[]).unwrap();
        assert_eq!(text(&config, "stt", "model"), "parakeet-tdt-v2");

        let config = load(
            "[stt]\nmodel = \"parakeet-tdt-v2\"\nphonon_migration = \"rolled_back\"\n\
             phonon_migration_previous_model = \"parakeet-tdt-v2\"\n",
        );
        assert_eq!(text(&config, "stt", "phonon_migration"), "rolled_back");
        assert_eq!(
            text(&config, "stt", "phonon_migration_previous_model"),
            "parakeet-tdt-v2"
        );
    }

    #[test]
    fn stt_os_support_matches_swift() {
        assert!(!stt_model_supported("phonon-2", 14));
        assert!(stt_model_supported("phonon-2", 15));
        assert!(stt_model_supported("parakeet-tdt-v2", 14));
        assert!(stt_model_supported("parakeet-tdt-v3", 14));
        assert!(!stt_model_supported("whisper-xl", 26));
        assert_eq!(default_stt_model(14, true), "parakeet-tdt-v2");
        assert_eq!(default_stt_model(15, true), "phonon-2");
        assert_eq!(default_stt_model(26, false), "parakeet-tdt-v2");
    }

    #[test]
    fn this_mac_reports_its_major_version() {
        if cfg!(target_os = "macos") {
            assert!(current_macos_major() >= 11);
        }
        assert!(default_config_path().ends_with("/relay-runner/config.toml"));
    }
}
