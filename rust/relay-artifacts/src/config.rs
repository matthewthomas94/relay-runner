//! `services/config.py`: Relay Runner's `config.toml`, with its defaults,
//! `VOICE_TERMINAL_<SECTION>_<KEY>` environment overrides and the in-place
//! migration of legacy values. The result is the same nested table, in the
//! same key order, that `load_config` returns.

use std::path::{Path, PathBuf};

use crate::codex::{CODEX_DEFAULT_FAMILY, CODEX_MESSENGER_DEFAULT_FAMILY};
use crate::codex::{codex_family_for_model, normalize_codex_family};
use crate::toml::{Table, Value};
use crate::{Error, ErrorKind, Result, pystr, toml};

/// Kokoro voices offered in Settings; any other saved voice loads as Puck.
pub const STANDARD_VOICES: [&str; 4] = ["am_puck", "bm_george", "bf_isabella", "af_sky"];
/// Persisted `[stt]` model ids and the macOS major version each needs.
pub const STT_MODELS: [(&str, i32); 3] = [
    ("phonon-2", 15),
    ("parakeet-tdt-v2", 14),
    ("parakeet-tdt-v3", 14),
];
pub const LEGACY_WHISPER_ALIASES: [(&str, &str); 6] = [
    ("tiny.en", "parakeet-tdt-v2"),
    ("base.en", "parakeet-tdt-v2"),
    ("small.en", "parakeet-tdt-v2"),
    ("medium.en", "parakeet-tdt-v2"),
    ("large", "parakeet-tdt-v3"),
    ("large-v3", "parakeet-tdt-v3"),
];
/// RR-416's activation point; matches `STTModelPolicy.phononDefaultActive`.
pub const PHONON_DEFAULT_ACTIVE: bool = true;

const CLAUDE_MODELS: [&str; 6] = [
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
    "haiku",
];

/// `current_macos_major()`: the running macOS major version, or 0.
pub fn current_macos_major() -> i32 {
    let Ok(plist) = std::fs::read_to_string("/System/Library/CoreServices/SystemVersion.plist")
    else {
        return 0;
    };
    let Some(after) = plist.split("<key>ProductVersion</key>").nth(1) else {
        return 0;
    };
    after
        .split_once("<string>")
        .and_then(|(_, rest)| rest.split_once('<'))
        .and_then(|(version, _)| version.split('.').next()?.trim().parse().ok())
        .unwrap_or(0)
}

/// `stt_model_supported`.
pub fn stt_model_supported(model: &str, macos_major: i32) -> bool {
    STT_MODELS
        .iter()
        .any(|(name, required)| *name == model && macos_major >= *required)
}

/// `default_stt_model`: Phonon on macOS 15 and later once active, else
/// Parakeet v2.
pub fn default_stt_model(macos_major: i32, phonon_default_active: bool) -> &'static str {
    if phonon_default_active && stt_model_supported("phonon-2", macos_major) {
        "phonon-2"
    } else {
        "parakeet-tdt-v2"
    }
}

/// `stt_migration_target`: Phonon for an implicit v2 user still eligible
/// for the one-time migration.
pub fn stt_migration_target(
    stt: &Table,
    macos_major: i32,
    phonon_default_active: bool,
) -> Option<&'static str> {
    let migration_unset = match stt.get("phonon_migration") {
        None => true,
        Some(value) => value.as_str() == Some(""),
    };
    (phonon_default_active
        && migration_unset
        && stt.get("model").and_then(Value::as_str) == Some("parakeet-tdt-v2")
        && stt_model_supported("phonon-2", macos_major))
    .then_some("phonon-2")
}

/// `_default_config_path`.
pub fn default_config_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    let base = if cfg!(target_os = "macos") {
        format!("{home}/Library/Application Support")
    } else {
        std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{home}/.config"))
    };
    Path::new(&base).join("relay-runner").join("config.toml")
}

/// A default's type decides how its environment override is read.
enum Default {
    Str(&'static str),
    Bool(bool),
    Int(i64),
    Float(f64),
}

fn defaults(stt_model: &str) -> Vec<(&'static str, Vec<(&'static str, Default)>)> {
    use Default::{Bool, Float, Int, Str};
    let stt_model: &'static str = if stt_model == "phonon-2" {
        "phonon-2"
    } else {
        "parakeet-tdt-v2"
    };
    vec![
        (
            "stt",
            vec![
                ("model", Str(stt_model)),
                ("input_device", Str("default")),
                ("input_mode", Str("caps_lock_toggle")),
                ("push_to_talk_key", Str("")),
                ("vad_sensitivity", Str("medium")),
                (
                    "phonon_migration",
                    Str(if stt_model == "phonon-2" {
                        "completed"
                    } else {
                        ""
                    }),
                ),
                ("phonon_migration_previous_model", Str("")),
            ],
        ),
        (
            "tts",
            vec![
                ("engine", Str("kokoro")),
                ("voice", Str("am_puck")),
                ("rate", Float(1.3)),
                ("auto_play", Bool(false)),
                ("chime", Str("Tink")),
                ("show_notification", Bool(true)),
            ],
        ),
        (
            "controls",
            vec![("play_pause_key", Str("F5")), ("skip_key", Str("Shift+F5"))],
        ),
        (
            "general",
            vec![
                ("provider", Str("codex")),
                ("command", Str("codex")),
                ("terminal", Str("warp")),
                ("auto_start", Bool(false)),
                ("working_directory", Str("")),
                ("bypass_permissions", Bool(true)),
                ("model", Str("sol")),
                ("orchestrator_effort", Str("medium")),
                ("codex_reasoning_effort", Str("default")),
                ("messenger_enabled", Bool(true)),
                ("messenger_model", Str("luna")),
                ("messenger_effort", Str("low")),
                ("subagent_sizing_policy", Str("orchestrator_decides")),
                ("prevent_sleep_while_running", Bool(false)),
            ],
        ),
        (
            "orchestrator",
            vec![
                ("agent", Str("")),
                ("command", Str("")),
                ("port", Int(7634)),
                ("workspace_root", Str("")),
                ("branch_prefix", Str("relay/")),
                ("default_workflow_path", Str("")),
                ("worker_health_check_seconds", Int(600)),
            ],
        ),
        (
            "continuity",
            vec![
                ("enabled", Bool(true)),
                ("max_attempts", Int(4)),
                ("wall_clock_seconds", Int(120)),
                ("stable_health_seconds", Int(60)),
                ("cooldown_seconds", Int(900)),
            ],
        ),
    ]
}

/// `load_config(config_path, macos_major, phonon_default_active)`. Without
/// a path it reads `--config <path>` from the process arguments, then the
/// default location.
pub fn load_config(
    config_path: Option<&Path>,
    macos_major: Option<i32>,
    phonon_default_active: bool,
) -> Result<Table> {
    let path = match config_path {
        Some(path) => path.to_path_buf(),
        None => {
            let arguments: Vec<String> = std::env::args().skip(1).collect();
            arguments
                .iter()
                .position(|argument| argument == "--config")
                .and_then(|index| arguments.get(index + 1))
                .map(PathBuf::from)
                .unwrap_or_else(default_config_path)
        }
    };
    let exists = path.exists();
    let mut config = if exists {
        toml::loads_bytes(&std::fs::read(&path)?)?
    } else {
        Table::new()
    };
    let general_has = |key: &str| {
        config
            .get("general")
            .and_then(Value::as_table)
            .is_some_and(|general| general.contains_key(key))
    };
    let general_had_provider = general_has("provider");
    let general_had_orchestrator_effort = general_has("orchestrator_effort");

    // A missing file gets the fresh-install default Swift bootstraps; an
    // existing file without a model key keeps the legacy Parakeet v2.
    let stt_model = if exists {
        "parakeet-tdt-v2"
    } else {
        default_stt_model(
            macos_major.unwrap_or_else(current_macos_major),
            phonon_default_active,
        )
    };

    for (section, values) in defaults(stt_model) {
        if !config.contains_key(section) {
            config.insert(section, Value::Table(Table::new()));
        }
        let Some(Value::Table(table)) = config.get_mut(section) else {
            return Err(Error::new(
                ErrorKind::Type,
                format!("config section [{section}] is not a table"),
            ));
        };
        for (key, default) in values {
            if table.contains_key(key) {
                continue;
            }
            let variable = format!(
                "VOICE_TERMINAL_{}_{}",
                section.to_uppercase(),
                key.to_uppercase()
            );
            let value = match (std::env::var(&variable), default) {
                (Ok(text), Default::Bool(_)) => {
                    Value::Boolean(matches!(text.to_lowercase().as_str(), "true" | "1" | "yes"))
                }
                (Ok(text), Default::Int(_)) => {
                    Value::Integer(pystr::int(&text).ok_or_else(|| {
                        Error::value(format!(
                            "invalid literal for int() with base 10: {}",
                            pystr::repr(&text)
                        ))
                    })?)
                }
                // A float default is not an int, so its override stays text.
                (Ok(text), _) => Value::String(text),
                (Err(_), Default::Str(text)) => Value::String(text.to_string()),
                (Err(_), Default::Bool(flag)) => Value::Boolean(flag),
                (Err(_), Default::Int(number)) => Value::Integer(number),
                (Err(_), Default::Float(number)) => Value::Float(number),
            };
            table.insert(key, value);
        }
    }
    migrate_config(
        &mut config,
        general_had_provider,
        general_had_orchestrator_effort,
    )?;
    Ok(config)
}

fn section<'c>(config: &'c mut Table, name: &str) -> &'c mut Table {
    match config.get_mut(name) {
        Some(Value::Table(table)) => table,
        _ => unreachable!("load_config created every section as a table"),
    }
}

/// `str(table.get(key, default)).strip().lower()`.
fn text_of(table: &Table, key: &str, default: &str) -> String {
    let text = table
        .get(key)
        .map_or_else(|| default.to_string(), Value::py_str);
    pystr::strip(&text).to_lowercase()
}

fn basename(command: &str) -> &str {
    command.rsplit('/').next().unwrap_or(command)
}

fn orchestrator_efforts(provider: &str, model: &str) -> Vec<&'static str> {
    let explicit = vec!["low", "medium", "high", "xhigh"];
    if provider == "codex" {
        return [explicit, vec!["max", "ultra"]].concat();
    }
    if [
        "claude-fable-5-2",
        "claude-fable-5-1",
        "fable",
        "opus",
        "sonnet",
    ]
    .contains(&model)
    {
        return [explicit, vec!["max"]].concat();
    }
    if model == "haiku" {
        return vec!["low"];
    }
    Vec::new()
}

fn messenger_efforts(provider: &str, model: &str) -> Vec<&'static str> {
    let base = vec!["default", "low", "medium", "high", "xhigh"];
    if provider == "codex" {
        return [base, vec!["max", "ultra"]].concat();
    }
    if [
        "best",
        "claude-fable-5-2",
        "claude-fable-5-1",
        "fable",
        "opus",
        "sonnet",
    ]
    .contains(&model)
    {
        return [base, vec!["max"]].concat();
    }
    vec!["default"]
}

/// `round(value, 1)`: Python rounds the exact binary value, half to even,
/// which is what Rust's fixed-precision formatting does.
fn round_one_decimal(value: f64) -> f64 {
    format!("{value:.1}").parse().expect("a formatted float")
}

/// `_migrate_config`.
fn migrate_config(
    config: &mut Table,
    general_had_provider: bool,
    general_had_orchestrator_effort: bool,
) -> Result<()> {
    // Worker wall-clock deadlines were removed; a legacy value is discarded
    // rather than read as a new limit.
    section(config, "orchestrator").remove("worker_timeout_seconds");

    let tts = section(config, "tts");
    // RR-462 removed custom voices.
    tts.remove("custom_voice_id");
    if matches!(
        tts.get("engine").and_then(Value::as_str),
        Some("say" | "piper")
    ) {
        tts.insert("engine", Value::String("kokoro".to_string()));
    }
    let voice = tts.get("voice").and_then(Value::as_str);
    if !voice.is_some_and(|voice| STANDARD_VOICES.contains(&voice)) {
        tts.insert("voice", Value::String("am_puck".to_string()));
    }
    // A words-per-minute rate (an int above 10) becomes a speed multiplier.
    let rate = match tts.get("rate") {
        Some(Value::Integer(rate)) if *rate > 10 => Some(*rate as f64),
        Some(Value::BigInteger(digits)) if !digits.starts_with('-') => {
            let rate: f64 = digits.parse().expect("decimal digits");
            if rate.is_infinite() {
                return Err(Error::new(
                    ErrorKind::Overflow,
                    "int too large to convert to float",
                ));
            }
            Some(rate)
        }
        _ => None,
    };
    if let Some(rate) = rate {
        let speed = (2.0 - (rate - 100.0) * 1.5 / 200.0).clamp(0.5, 2.0);
        tts.insert("rate", Value::Float(round_one_decimal(speed)));
    }

    // Old Whisper models map to Parakeet; unknown ids stay for Swift to report.
    let stt = section(config, "stt");
    if let Some(model) = stt.get("model").and_then(Value::as_str)
        && let Some((_, replacement)) = LEGACY_WHISPER_ALIASES
            .iter()
            .find(|(alias, _)| *alias == model)
    {
        stt.insert("model", Value::String(replacement.to_string()));
    }

    let general = section(config, "general");
    if !general_had_provider {
        let command = general
            .get("command")
            .map_or_else(|| "codex".to_string(), Value::py_str);
        let name = basename(pystr::strip(&command)).to_lowercase();
        let provider = if name.contains("claude") {
            "claude"
        } else {
            "codex"
        };
        general.insert("provider", Value::String(provider.to_string()));
    }
    let mut provider = text_of(general, "provider", "codex");
    if provider != "codex" && provider != "claude" {
        provider = "codex".to_string();
    }
    general.insert("provider", Value::String(provider.clone()));

    let command = general
        .get("command")
        .map_or_else(String::new, Value::py_str);
    let command = pystr::strip(&command);
    let command_provider = if basename(command).to_lowercase().contains("claude") {
        "claude"
    } else {
        "codex"
    };
    if !command.starts_with('/') || command_provider != provider {
        general.insert("command", Value::String(provider.clone()));
    }

    let model = text_of(
        general,
        "model",
        if provider == "codex" { "sol" } else { "opus" },
    );
    let model = if provider == "codex" {
        normalize_codex_family(&model, CODEX_DEFAULT_FAMILY)
    } else if CLAUDE_MODELS.contains(&model.as_str()) {
        model
    } else {
        "opus".to_string()
    };
    general.insert("model", Value::String(model.clone()));

    let codex_reasoning_effort = text_of(general, "codex_reasoning_effort", "default");
    let raw_orchestrator_effort = if general_had_orchestrator_effort {
        general.get("orchestrator_effort").cloned()
    } else {
        Some(Value::String(codex_reasoning_effort))
    };
    let mut orchestrator_effort = pystr::strip(
        &raw_orchestrator_effort
            .filter(Value::truthy)
            .map_or_else(|| "medium".to_string(), |value| value.py_str()),
    )
    .to_lowercase();
    if orchestrator_effort == "default" {
        orchestrator_effort = "medium".to_string();
    }
    let valid = orchestrator_efforts(&provider, &model);
    if !valid.contains(&orchestrator_effort.as_str()) {
        orchestrator_effort = if valid.contains(&"medium") {
            "medium"
        } else if valid.contains(&"high") {
            "high"
        } else {
            // `min()` of the set; it is never empty for a migrated model.
            valid.iter().min().copied().unwrap_or("medium")
        }
        .to_string();
    }
    general.insert(
        "orchestrator_effort",
        Value::String(orchestrator_effort.clone()),
    );
    let codex_effort = if provider == "codex"
        && orchestrator_efforts("codex", &model).contains(&orchestrator_effort.as_str())
    {
        orchestrator_effort
    } else {
        "default".to_string()
    };
    general.insert("codex_reasoning_effort", Value::String(codex_effort));

    let mut raw_messenger_model = text_of(general, "messenger_model", &model);
    let mut raw_messenger_effort = text_of(general, "messenger_effort", "default");
    // RR-229 wrote the foreground defaults into the messenger settings;
    // those generated pairs go back to the lightweight defaults.
    if provider == "codex"
        && (raw_messenger_model.as_str(), raw_messenger_effort.as_str()) == ("sol", "default")
    {
        (raw_messenger_model, raw_messenger_effort) = ("luna".to_string(), "low".to_string());
    } else if provider == "claude"
        && (raw_messenger_model.as_str(), raw_messenger_effort.as_str()) == ("best", "default")
    {
        (raw_messenger_model, raw_messenger_effort) = ("haiku".to_string(), "default".to_string());
    }
    let (messenger_model, messenger_effort) = if provider == "codex" {
        let messenger_model =
            normalize_codex_family(&raw_messenger_model, CODEX_MESSENGER_DEFAULT_FAMILY);
        let mut effort = if messenger_model != raw_messenger_model
            && codex_family_for_model(&raw_messenger_model).is_none()
        {
            "low".to_string()
        } else {
            raw_messenger_effort
        };
        if !messenger_efforts(&provider, &messenger_model).contains(&effort.as_str()) {
            effort = "low".to_string();
        }
        (messenger_model, effort)
    } else if ![
        "best",
        "claude-fable-5-2",
        "claude-fable-5-1",
        "fable",
        "opus",
        "sonnet",
        "haiku",
    ]
    .contains(&raw_messenger_model.as_str())
    {
        ("haiku".to_string(), "default".to_string())
    } else {
        let effort = if messenger_efforts(&provider, &raw_messenger_model)
            .contains(&raw_messenger_effort.as_str())
        {
            raw_messenger_effort
        } else {
            "default".to_string()
        };
        (raw_messenger_model, effort)
    };
    general.insert("messenger_model", Value::String(messenger_model));
    general.insert("messenger_effort", Value::String(messenger_effort));

    let policy = text_of(general, "subagent_sizing_policy", "orchestrator_decides");
    let policy = if policy == "orchestrator_decides" || policy == "user_default" {
        policy
    } else {
        "orchestrator_decides".to_string()
    };
    general.insert("subagent_sizing_policy", Value::String(policy));
    if general.contains_key("subagent_model") {
        let model = text_of(general, "subagent_model", "balanced");
        let model = if ["fast", "balanced", "strong"].contains(&model.as_str()) {
            model
        } else {
            "balanced".to_string()
        };
        general.insert("subagent_model", Value::String(model));
    }
    if general.contains_key("subagent_effort") {
        let effort = text_of(general, "subagent_effort", "medium");
        let effort = if ["low", "medium", "high", "xhigh"].contains(&effort.as_str()) {
            effort
        } else {
            "medium".to_string()
        };
        general.insert("subagent_effort", Value::String(effort));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(text: &str) -> Table {
        let directory = std::env::temp_dir().join(format!(
            "relay-config-{}-{}",
            std::process::id(),
            text.len()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("config.toml");
        std::fs::write(&path, text).unwrap();
        let config = load_config(Some(&path), Some(15), true).unwrap();
        std::fs::remove_dir_all(&directory).unwrap();
        config
    }

    fn general(config: &Table, key: &str) -> String {
        config
            .get("general")
            .unwrap()
            .as_table()
            .unwrap()
            .get(key)
            .unwrap()
            .py_str()
    }

    #[test]
    fn migrates_legacy_values() {
        let config = load(
            "[general]\ncommand = \"/usr/local/bin/claude\"\nmodel = \"Fable\"\n\
             codex_reasoning_effort = \"high\"\nmessenger_model = \"best\"\n\
             [tts]\nengine = \"say\"\nvoice = \"en_US-amy\"\nrate = 180\n[stt]\nmodel = \"large\"\n",
        );
        assert_eq!(general(&config, "provider"), "claude");
        assert_eq!(general(&config, "command"), "/usr/local/bin/claude");
        assert_eq!(general(&config, "model"), "fable");
        assert_eq!(general(&config, "orchestrator_effort"), "high");
        assert_eq!(general(&config, "codex_reasoning_effort"), "default");
        assert_eq!(general(&config, "messenger_model"), "best");
        assert_eq!(general(&config, "messenger_effort"), "low");
        let tts = config.get("tts").unwrap().as_table().unwrap();
        assert_eq!(tts.get("engine").unwrap().py_str(), "kokoro");
        assert_eq!(tts.get("voice").unwrap().py_str(), "am_puck");
        assert_eq!(tts.get("rate"), Some(&Value::Float(1.4)));
        let stt = config.get("stt").unwrap().as_table().unwrap();
        assert_eq!(stt.get("model").unwrap().py_str(), "parakeet-tdt-v3");
        let keys: Vec<&str> = config.iter().map(|(key, _)| key).collect();
        assert_eq!(
            keys,
            [
                "general",
                "tts",
                "stt",
                "controls",
                "orchestrator",
                "continuity"
            ]
        );
    }

    #[test]
    fn rounds_rates_like_python() {
        // round(x, 1) in Python for these exact binary values.
        assert_eq!(round_one_decimal(0.25), 0.2);
        assert_eq!(round_one_decimal(0.35), 0.3);
        assert_eq!(round_one_decimal(1.25), 1.2);
        assert_eq!(round_one_decimal(1.6375), 1.6);
    }
}
