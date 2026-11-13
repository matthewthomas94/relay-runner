//! The `[tts]` keys speech reads from `config.toml`, with the defaults and
//! migrations of `services/config.py`: `voice`, `rate`, `chime`, `auto_play`.
//!
//! Only `[tts]` is read, so this is a small line-based reader rather than a
//! TOML library: strings, booleans and numbers under table headers, skipping
//! multi-line strings and arrays. Anything it cannot read keeps the default.

use std::path::{Path, PathBuf};

/// `STANDARD_VOICES` in services/config.py.
pub const STANDARD_VOICES: [&str; 4] = ["am_puck", "bm_george", "bf_isabella", "af_sky"];
pub const DEFAULT_VOICE: &str = "am_puck";
pub const DEFAULT_RATE: f64 = 1.3;
pub const DEFAULT_CHIME: &str = "Tink";

#[derive(Clone, Debug, PartialEq)]
pub struct TtsConfig {
    pub voice: String,
    pub rate: f64,
    /// The chime's file, resolved like `_resolve_chime`.
    pub chime: PathBuf,
    pub auto_play: bool,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            voice: DEFAULT_VOICE.to_string(),
            rate: DEFAULT_RATE,
            chime: resolve_chime(DEFAULT_CHIME),
            auto_play: false,
        }
    }
}

/// `~/Library/Application Support/relay-runner`, from `HOME` as Python's
/// `expanduser` reads it. The audio lease and the default config live here.
pub fn support_root() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/relay-runner")
}

pub fn default_config_path() -> PathBuf {
    support_root().join("config.toml")
}

fn resolve_chime(name: &str) -> PathBuf {
    if name.starts_with('/') {
        PathBuf::from(name)
    } else {
        PathBuf::from(format!("/System/Library/Sounds/{name}.aiff"))
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Value {
    Text(String),
    Bool(bool),
    Integer(i64),
    Float(f64),
}

/// Read `[tts]` from `path`; a missing or unreadable file gives the defaults.
pub fn load(path: &Path) -> TtsConfig {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(_) => TtsConfig::default(),
    }
}

pub fn parse(text: &str) -> TtsConfig {
    let mut config = TtsConfig::default();
    for (key, value) in tts_entries(text) {
        match (key.as_str(), value) {
            ("voice", Value::Text(voice)) => config.voice = voice,
            // `float(cfg.get("rate", 1.3))`, after the WPM migration below.
            ("rate", Value::Integer(rate)) if rate > 10 => {
                let migrated = (2.0 - (rate as f64 - 100.0) * 1.5 / 200.0).clamp(0.5, 2.0);
                config.rate = (migrated * 10.0).round() / 10.0;
            }
            ("rate", Value::Integer(rate)) => config.rate = rate as f64,
            ("rate", Value::Float(rate)) => config.rate = rate,
            ("rate", Value::Text(rate)) => {
                if let Ok(rate) = rate.trim().parse::<f64>() {
                    config.rate = rate;
                }
            }
            ("chime", Value::Text(chime)) => config.chime = resolve_chime(&chime),
            ("auto_play", Value::Bool(auto_play)) => config.auto_play = auto_play,
            ("auto_play", Value::Integer(auto_play)) => config.auto_play = auto_play != 0,
            _ => {}
        }
    }
    // Voices outside the standard set (including old Piper names) -> Puck.
    if !STANDARD_VOICES.contains(&config.voice.as_str()) {
        config.voice = DEFAULT_VOICE.to_string();
    }
    if !config.rate.is_finite() {
        config.rate = DEFAULT_RATE;
    }
    config
}

/// Every `key = value` directly under `[tts]`, in file order.
fn tts_entries(text: &str) -> Vec<(String, Value)> {
    let mut entries = Vec::new();
    let mut table = String::new();
    let mut lines = text.lines();
    while let Some(line) = lines.next() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            let header = line.trim_start_matches('[');
            let header = header.split(']').next().unwrap_or("");
            table = header
                .trim()
                .trim_matches('"')
                .trim_matches('\'')
                .to_string();
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        // Skip what spans lines: multi-line strings and arrays.
        for (open, close) in [("\"\"\"", "\"\"\""), ("'''", "'''")] {
            if let Some(rest) = value.strip_prefix(open)
                && !rest.contains(close)
            {
                for next in lines.by_ref() {
                    if next.contains(close) {
                        break;
                    }
                }
            }
        }
        if value.starts_with('[') && !brackets_balance(value) {
            let mut depth = bracket_depth(value);
            for next in lines.by_ref() {
                depth += bracket_depth(next);
                if depth <= 0 {
                    break;
                }
            }
        }
        if table != "tts" {
            continue;
        }
        let key = key.trim().trim_matches('"').trim_matches('\'').to_string();
        if let Some(value) = parse_value(value) {
            entries.push((key, value));
        }
    }
    entries
}

fn bracket_depth(text: &str) -> i64 {
    text.chars().fold(0, |depth, c| match c {
        '[' => depth + 1,
        ']' => depth - 1,
        _ => depth,
    })
}

fn brackets_balance(text: &str) -> bool {
    bracket_depth(text) <= 0
}

fn parse_value(value: &str) -> Option<Value> {
    if let Some(rest) = value.strip_prefix('"') {
        return basic_string(rest).map(Value::Text);
    }
    if let Some(rest) = value.strip_prefix('\'') {
        return rest
            .split_once('\'')
            .map(|(text, _)| Value::Text(text.to_string()));
    }
    let bare = value.split('#').next().unwrap_or("").trim();
    match bare {
        "true" => return Some(Value::Bool(true)),
        "false" => return Some(Value::Bool(false)),
        _ => {}
    }
    let digits = bare.replace('_', "");
    if let Ok(integer) = digits.parse::<i64>() {
        return Some(Value::Integer(integer));
    }
    digits.parse::<f64>().ok().map(Value::Float)
}

/// A TOML basic string after its opening quote, up to the closing one.
fn basic_string(rest: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                'b' => out.push('\u{8}'),
                'f' => out.push('\u{c}'),
                'u' => out.push(hex_char(&mut chars, 4)?),
                'U' => out.push(hex_char(&mut chars, 8)?),
                other => out.push(other),
            },
            other => out.push(other),
        }
    }
    None
}

fn hex_char(chars: &mut std::str::Chars<'_>, digits: usize) -> Option<char> {
    let hex: String = chars.by_ref().take(digits).collect();
    char::from_u32(u32::from_str_radix(&hex, 16).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_keys_keep_the_python_defaults() {
        let config = parse("[general]\nprovider = \"claude\"\n");
        assert_eq!(config, TtsConfig::default());
        assert_eq!(
            config.chime,
            PathBuf::from("/System/Library/Sounds/Tink.aiff")
        );
    }

    #[test]
    fn reads_the_tts_table_only() {
        let config = parse(
            "voice = \"bm_george\"\n[tts]\nvoice = \"bf_isabella\" # comment\nrate = 1.5\n\
             auto_play = true\nchime = \"/tmp/ding.aiff\"\n[stt]\nvoice = \"af_sky\"\n",
        );
        assert_eq!(config.voice, "bf_isabella");
        assert_eq!(config.rate, 1.5);
        assert!(config.auto_play);
        assert_eq!(config.chime, PathBuf::from("/tmp/ding.aiff"));
    }

    #[test]
    fn migrates_like_config_py() {
        // An unknown voice becomes Puck; a words-per-minute rate a multiplier.
        let config = parse("[tts]\nvoice = \"en_US-amy\"\nrate = 180\n");
        assert_eq!(config.voice, "am_puck");
        assert_eq!(config.rate, 1.4);
        assert_eq!(parse("[tts]\nrate = 2\n").rate, 2.0);
        assert_eq!(
            parse("[tts]\nchime = 'Glass'\n").chime,
            PathBuf::from("/System/Library/Sounds/Glass.aiff")
        );
    }

    #[test]
    fn skips_values_that_span_lines() {
        let config = parse(
            "[general]\nnotes = \"\"\"\n[tts]\nvoice = \"af_sky\"\n\"\"\"\nlist = [\n  \"a\",\n]\n\
             [tts]\nvoice = \"bm_george\"\n",
        );
        assert_eq!(config.voice, "bm_george");
    }
}
