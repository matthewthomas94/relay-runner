//! What the bridge hands the speech service: typed speech intents, stale
//! ones dropped, and the acknowledgement copy (`voice_bridge.py` from
//! `_strip_markdown_for_tts` to `_queue_voice_acknowledgement`, with
//! `build_voice_acknowledgement` and its patterns).

use std::sync::LazyLock;

use relay_intents::pattern::{self, Regex};

use super::ports::{Speech, SpeechText};
use super::settings::settings;
use super::store::{self, read_json_file, relay_command_key};
use super::turns;
use crate::json::{self, Dict, Value};

pub const VOICE_ACKNOWLEDGEMENT_AUTO_DISMISS_SECONDS: f64 = 3.0;

static MD_LINK_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"\[([^\]]+)\]\([^)]+\)", false));
static MD_LINE_PREFIX_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^\s*(?:>+|#+|[-+*]|\d+\.)\s+", false));
static MD_MARKER_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"[*_`]", false));
static WHITESPACE_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"\s+", false));
static SENSITIVE_ACK_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"\b(password|passcode|secret|token|api[_ -]?key|private[_ -]?key|credential|credit card)\b",
        true,
    )
});
static INTENT_ACKNOWLEDGEMENTS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        (r"\b(ack|acknowledg)", "I'll take care of the acknowledgement issue."),
        (
            r"\b(subagent|sub-agent|orchestrator model|worker model|gpt-?5|5\.\d)\b",
            "I'll check the subagent model settings.",
        ),
        (
            r"\b(program board|board|ticket card|work card|pill)\b",
            "I'll update the board behavior.",
        ),
        (r"\b(test|tests|coverage|failing)\b", "I'll check the tests."),
        (
            r"\b(status|state|show|summari[sz]e|check|look at|inspect)\b",
            "I'll check that.",
        ),
        (r"\b(fix|debug|repair|broken|issue|bug)\b", "I'll take care of that issue."),
        (r"\b(add|build|create|implement|make|wire)\b", "I'll build that."),
        (
            r"\b(change|update|swap|replace|refactor|tune|adjust)\b",
            "I'll update that.",
        ),
        (r"\b(remove|delete|clean up)\b", "I'll remove that."),
    ]
    .into_iter()
    .map(|(source, text)| (pattern::compile(source, true), text))
    .collect()
});

/// `_strip_markdown_for_tts`: so the voice never says "asterisk".
pub fn strip_markdown_for_tts(text: &str) -> String {
    let text = MD_LINK_RE.replace_all(text, "$1").into_owned();
    let text = pattern::sub(&MD_LINE_PREFIX_RE, &text, 1);
    pattern::sub(&MD_MARKER_RE, &text, 0)
}

/// `_parse_tts_payload`: plain text, or a JSON line tagged with its Relay
/// command. Returns the text, display text, command seq and command id.
pub fn parse_tts_payload(raw: &str) -> (String, Option<String>, Option<i64>, Option<String>) {
    let text = json::py_strip(raw);
    if text.is_empty() {
        return (String::new(), None, None, None);
    }
    let Some(Value::Dict(payload)) = json::parse(text) else {
        return (text.to_string(), None, None, None);
    };
    if payload.get("text").is_none() {
        return (text.to_string(), None, None, None);
    }
    let command_seq = payload.present("relay_command_seq").and_then(Value::py_int);
    let command_id = payload.truthy("relay_command_id").map(Value::py_str);
    let display_text = payload.present("display_text").map(Value::py_str);
    (payload.string("text"), display_text, command_seq, command_id)
}

/// `_normalize_display_preview`.
pub fn normalize_display_preview(text: Option<&str>) -> String {
    text.unwrap_or("")
        .replace('\n', " ")
        .split(json::py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `_session_key_for_command`: the session a Relay command targeted, from
/// the shared command ledger.
pub fn session_key_for_command(command_seq: Option<i64>, command_id: Option<&str>, state_path: &str) -> String {
    let (Some(seq), Some(id)) = (command_seq, command_id.filter(|id| !id.is_empty())) else {
        return String::new();
    };
    let state = read_json_file(state_path);
    let Some(sessions) = state.get("session_commands").and_then(Value::as_dict) else {
        return String::new();
    };
    for (key, entry) in sessions.iter() {
        if let Some(entry) = entry.as_dict()
            && entry.get("relay_command_id").is_some_and(|value| value.is_str(id))
            && entry
                .get("relay_command_seq")
                .is_some_and(|value| json::py_eq(value, &Value::Int(seq)))
        {
            return key.to_string();
        }
    }
    String::new()
}

/// The keyword arguments of `_queue_tts_text`, with its defaults.
#[derive(Clone, Debug)]
pub struct TtsOptions {
    pub command_path: String,
    pub state_path: String,
    pub allow_pending_command: bool,
    pub preserved_command: Option<Dict>,
    pub source: String,
    pub kind: String,
    pub authoritative: bool,
    pub semantic_brief: Option<String>,
    pub priority: Option<i64>,
    pub dedup_key: Option<String>,
    pub work_disposition: Option<Dict>,
    pub replayable: Option<bool>,
    pub freshness_scope: String,
    pub lifecycle_role: Option<String>,
    pub covered_facts: Option<Vec<String>>,
    pub realization_decision: String,
    pub suppression_reason: Option<String>,
    pub session_key: Option<String>,
}

impl Default for TtsOptions {
    fn default() -> Self {
        Self {
            command_path: settings().cmd_file.clone(),
            state_path: settings().command_state_file.clone(),
            allow_pending_command: false,
            preserved_command: None,
            source: "fallback".to_string(),
            kind: "fallback".to_string(),
            authoritative: false,
            semantic_brief: None,
            priority: None,
            dedup_key: None,
            work_disposition: None,
            replayable: None,
            freshness_scope: "conversation".to_string(),
            lifecycle_role: None,
            covered_facts: None,
            realization_decision: "full".to_string(),
            suppression_reason: None,
            session_key: None,
        }
    }
}

impl TtsOptions {
    /// The speech metadata the messenger's `speak` callback passes through
    /// as `_queue_tts_text` keyword arguments.
    pub fn apply_metadata(&mut self, metadata: &Dict) {
        for (key, value) in metadata.iter() {
            let text = || value.as_str().map(str::to_string);
            match key {
                "source" => self.source = value.py_str(),
                "kind" => self.kind = value.py_str(),
                "authoritative" => self.authoritative = value.truthy(),
                "semantic_brief" => self.semantic_brief = text(),
                "priority" => self.priority = value.py_int(),
                "dedup_key" => self.dedup_key = text(),
                "work_disposition" => self.work_disposition = value.as_dict().cloned(),
                "replayable" => {
                    self.replayable = match value {
                        Value::Null => None,
                        other => Some(other.truthy()),
                    }
                }
                "freshness_scope" => self.freshness_scope = value.py_str(),
                "lifecycle_role" => self.lifecycle_role = text(),
                "covered_facts" => {
                    self.covered_facts = value
                        .as_list()
                        .map(|facts| facts.iter().map(Value::py_str).collect())
                }
                "realization_decision" => self.realization_decision = value.py_str(),
                "suppression_reason" => self.suppression_reason = text(),
                "session_key" => self.session_key = text(),
                "preserved_command" => self.preserved_command = value.as_dict().cloned(),
                "allow_pending_command" => self.allow_pending_command = value.truthy(),
                _ => {}
            }
        }
    }
}

/// A `_queue_tts_text` payload: the spoken text tagged with its command.
pub fn tagged_payload(text: &str, display_text: Option<&str>, command_seq: i64, command_id: &str) -> String {
    let mut payload = Dict::new();
    payload.insert("text", text);
    if let Some(display_text) = display_text {
        payload.insert("display_text", display_text);
    }
    payload.insert("relay_command_seq", command_seq);
    payload.insert("relay_command_id", command_id);
    json::dumps(&Value::Dict(payload))
}

/// `_queue_tts_text`: submit a typed speech intent unless its Relay command
/// is stale. The speech service publishes the waiting preview and arms
/// waiting playback atomically, so neither happens here.
pub fn queue_tts_text(speech: &dyn Speech, raw: &str, options: TtsOptions) -> bool {
    let (text, display_text, command_seq, command_id) = parse_tts_payload(raw);
    let display_preview = normalize_display_preview(display_text.as_deref());
    let mut text = json::py_strip(&strip_markdown_for_tts(json::py_strip(&text))).to_string();
    if text.is_empty() && !display_preview.is_empty() {
        text = json::py_strip(&strip_markdown_for_tts(&display_preview)).to_string();
    }
    if text.is_empty() {
        return false;
    }
    let work_fresh =
        options.freshness_scope == "work" && options.source == "lifecycle" && options.kind == "final";
    if (command_seq.is_some() || command_id.is_some()) && !work_fresh {
        let seq_value = command_seq.map(Value::Int);
        let id_value = command_id.as_deref().map(Value::from);
        let current =
            turns::relay_command_current(seq_value.as_ref(), id_value.as_ref(), &options.state_path);
        let preserved = !current
            && options.preserved_command.as_ref().is_some_and(|preserved| {
                let key = relay_command_key(preserved);
                key.as_ref().map(|(seq, id)| (Some(*seq), Some(id.as_str())))
                    == Some((command_seq, command_id.as_deref()))
                    && turns::relay_command_current_or_preserved(preserved, &options.state_path, "")
            });
        if !current && !preserved {
            eprintln!("[voice_bridge] Dropping TTS because its Relay command was superseded.");
            return false;
        }
    }
    if !options.allow_pending_command && store::exists(&options.command_path) {
        eprintln!("[voice_bridge] Dropping TTS because a newer voice command is pending.");
        return false;
    }
    let mut work_disposition = options.work_disposition.clone();
    if let Some(preserved) = &options.preserved_command {
        if work_disposition.is_none()
            && let Some(disposition) = preserved.get("work_disposition").and_then(Value::as_dict)
        {
            work_disposition = Some(disposition.clone());
        }
        let intent_id = preserved.text("intent_id");
        if !intent_id.is_empty() {
            let mut disposition = work_disposition.unwrap_or_default();
            if disposition.get("intent_id").is_none() {
                disposition.insert("intent_id", intent_id);
            }
            work_disposition = Some(disposition);
        }
    }
    let session_key = match options.session_key.filter(|key| !key.is_empty()) {
        Some(key) => key,
        None => session_key_for_command(command_seq, command_id.as_deref(), &options.state_path),
    };
    let waiting_playback_kind = (options.authoritative
        && matches!(options.kind.as_str(), "final" | "fallback")
        && command_seq.is_some()
        && command_id.is_some())
    .then(|| "final".to_string());
    speech.submit_text(SpeechText {
        text,
        display_text: display_preview,
        semantic_brief: options.semantic_brief,
        command_seq,
        command_id,
        source: options.source,
        kind: options.kind,
        authoritative: options.authoritative,
        priority: options.priority,
        dedup_key: options.dedup_key,
        work_disposition,
        replayable: options.replayable,
        freshness_scope: if work_fresh { "work" } else { "conversation" }.to_string(),
        lifecycle_role: options.lifecycle_role,
        covered_facts: options.covered_facts,
        realization_decision: options.realization_decision,
        suppression_reason: options.suppression_reason,
        session_key,
        waiting_playback_kind,
    })
}

/// `_record_messenger_stage`.
pub fn record_messenger_stage(speech: &dyn Speech, stage: &str, command: &Dict, at: Option<f64>, outcome: &str) {
    let Some((seq, id)) = relay_command_key(command) else {
        return;
    };
    let provider = command.text("provider").to_lowercase();
    speech.record_messenger_stage(
        stage,
        seq,
        &id,
        at,
        (!provider.is_empty()).then_some(provider.as_str()),
        outcome,
    );
}

/// `_queue_messenger_degraded`.
pub fn queue_messenger_degraded(speech: &dyn Speech, command: &Dict, degraded_text: &str) -> bool {
    let Some((seq, id)) = relay_command_key(command) else {
        return false;
    };
    queue_tts_text(
        speech,
        &tagged_payload(degraded_text, None, seq, &id),
        TtsOptions {
            allow_pending_command: true,
            source: "fallback".to_string(),
            kind: "handoff".to_string(),
            authoritative: false,
            semantic_brief: Some("Messenger unavailable; foreground delivery preserved.".to_string()),
            replayable: Some(true),
            lifecycle_role: Some("acknowledgement".to_string()),
            ..TtsOptions::default()
        },
    )
}

fn generic_acknowledgements() -> [&'static str; 4] {
    [
        "",
        "Received. I'll take it from here.",
        "Understood. Working on it.",
        "Okay. I'll handle that.",
    ]
}

/// `_acknowledgement_variant` over `_GENERIC_ACKNOWLEDGEMENTS`.
fn acknowledgement_variant(seed: &str) -> String {
    let options = generic_acknowledgements();
    let sum: usize = seed.bytes().map(usize::from).sum();
    match sum % options.len() {
        0 => settings().voice_acknowledgement.clone(),
        index => options[index].to_string(),
    }
}

/// `_acknowledgement_intent`.
fn acknowledgement_intent(text: Option<&str>) -> Option<&'static str> {
    let text = text.filter(|text| !text.is_empty())?;
    let cleaned = WHITESPACE_RE.replace_all(text, " ");
    let cleaned = json::py_strip(&cleaned);
    if cleaned.is_empty() || cleaned.starts_with("__") || pattern::search(&SENSITIVE_ACK_RE, cleaned) {
        return None;
    }
    INTENT_ACKNOWLEDGEMENTS
        .iter()
        .find(|(pattern, _)| pattern::search(pattern, cleaned))
        .map(|(_, acknowledgement)| *acknowledgement)
}

/// `build_voice_acknowledgement`: concise provider-neutral copy for a user
/// command.
pub fn build_voice_acknowledgement(text: Option<&str>, relay_command: Option<&Dict>) -> String {
    let seq = relay_command
        .and_then(|command| command.get("relay_command_seq"))
        .map(Value::py_str)
        .unwrap_or_default();
    let seed = format!("{}:{seq}", text.unwrap_or(""));
    match acknowledgement_intent(text) {
        Some(intent) => intent.to_string(),
        None => acknowledgement_variant(&seed),
    }
}

/// `acknowledgement_auto_dismiss_seconds`.
pub fn acknowledgement_auto_dismiss_seconds(text: &str) -> f64 {
    let length = json::py_strip(text).chars().count() as f64;
    VOICE_ACKNOWLEDGEMENT_AUTO_DISMISS_SECONDS.max(5.0_f64.min(2.4 + length * 0.025))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_is_stripped_for_speech() {
        assert_eq!(strip_markdown_for_tts("> **Done**: see [the doc](http://x) `now`"), "Done: see the doc now");
        assert_eq!(strip_markdown_for_tts("1. first\n- second"), "first\n- second");
    }

    #[test]
    fn tts_payloads_are_plain_text_or_tagged_json() {
        assert_eq!(parse_tts_payload("  hello  "), ("hello".to_string(), None, None, None));
        assert_eq!(
            parse_tts_payload(r#"{"text": "hi", "display_text": "Hi!", "relay_command_seq": "3", "relay_command_id": "c"}"#),
            ("hi".to_string(), Some("Hi!".to_string()), Some(3), Some("c".to_string()))
        );
        assert_eq!(parse_tts_payload(r#"{"other": 1}"#).0, r#"{"other": 1}"#);
    }

    #[test]
    fn display_previews_collapse_whitespace() {
        assert_eq!(normalize_display_preview(Some(" a\n b  c ")), "a b c");
        assert_eq!(normalize_display_preview(None), "");
    }

    #[test]
    fn acknowledgements_follow_the_intent_and_skip_sensitive_text() {
        assert_eq!(build_voice_acknowledgement(Some("fix the bug"), None), "I'll take care of that issue.");
        assert_eq!(build_voice_acknowledgement(Some("run the tests"), None), "I'll check the tests.");
        let sensitive = build_voice_acknowledgement(Some("fix my password"), None);
        assert_ne!(sensitive, "I'll take care of that issue.");
    }

    #[test]
    fn acknowledgement_dismissal_grows_with_length() {
        assert_eq!(acknowledgement_auto_dismiss_seconds("ok"), 3.0);
        assert_eq!(acknowledgement_auto_dismiss_seconds(&"x".repeat(400)), 5.0);
    }
}
