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

static MD_LINK_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"\[([^\]]+)\]\([^)]+\)", false));
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
        (
            r"\b(ack|acknowledg)",
            "I'll take care of the acknowledgement issue.",
        ),
        (
            r"\b(subagent|sub-agent|orchestrator model|worker model|gpt-?5|5\.\d)\b",
            "I'll check the subagent model settings.",
        ),
        (
            r"\b(program board|board|ticket card|work card|pill)\b",
            "I'll update the board behavior.",
        ),
        (
            r"\b(test|tests|coverage|failing)\b",
            "I'll check the tests.",
        ),
        (
            r"\b(status|state|show|summari[sz]e|check|look at|inspect)\b",
            "I'll check that.",
        ),
        (
            r"\b(fix|debug|repair|broken|issue|bug)\b",
            "I'll take care of that issue.",
        ),
        (
            r"\b(add|build|create|implement|make|wire)\b",
            "I'll build that.",
        ),
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

/// A web address: with a scheme, starting `www.`, or a bare domain with a
/// common top-level domain followed by a path.
static URL_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r#"\b[a-z][a-z0-9+.-]*://[^\s<>"'`]+|\bwww\.[^\s<>"'`]+|(?<![\w/.@-])(?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|ai|app|co|so|sh|me|gov|edu|uk|us|xyz|tech|cloud|ly)/[^\s<>"'`]*"#,
        true,
    )
});
/// A token with a slash in it. Rooted paths (`/`, `~/`, `./`, `../`) may
/// continue across a space while the next word still leads to a `/`, as in
/// `Application Support/`; `path_last_component` decides whether a relative
/// one is a path or prose such as "and/or".
static PATH_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"(?<![\w.~/:@-])(?:(?:~|\.{1,2})?/[\w.@+%-]+(?: [\w.@+%-]+(?=/))*(?:/[\w.@+%-]+(?: [\w.@+%-]+(?=/))*)*/?|[\w.@+%-]+(?:/[\w.@+%-]+)+/?)",
        false,
    )
});
static UUID_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", true));
/// Numbers joined by dashes, such as a Relay command id; dates are kept by
/// `remove_dash_id`.
static DASH_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?<![\w.])\d+(?:-\d+)+\b(?![.]\d)", false));
static HEX_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?<![\w.])[0-9a-f]{7,64}\b(?![.]\d)", true));
static LONG_NUMBER_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?<![\w.,])\d{10,}\b(?![.,]\d)", false));
/// Where an id was removed (`REMOVED`), with the spacing, dash or brackets
/// it leaves behind.
static REMOVED_BRACKETS_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile("[(\\[][ \t]*\u{1}[ \t]*[)\\]]", false));
static REMOVED_DASH_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile("-?\u{1}-?", false));
static REMOVED_BEFORE_PUNCTUATION_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile("[ \t]*\u{1}[ \t\u{1}]*(?=[.,;:!?)\\]\n]|\\z)", false));
static REMOVED_AT_LINE_START_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile("(?:^|(?<=\n))[ \t]*\u{1}[ \t\u{1}]*", false));
static REMOVED_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile("[ \t]*\u{1}[ \t\u{1}]*", false));

/// Marks text removed by `speakable_text` until the spacing is tidied.
const REMOVED: &str = "\u{1}";
/// Punctuation that ends a sentence rather than a URL or path.
const TRAILING_PUNCTUATION: &[char] = &['.', ',', ';', ':', '!', '?', ')', ']', '\'', '"'];

/// Every match of `pattern` in `text`, replaced by `rewrite` of it.
fn rewrite_matches(pattern: &Regex, text: &str, rewrite: impl Fn(&str) -> String) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for found in pattern.find_iter(text).map_while(Result::ok) {
        out.push_str(&text[last..found.start()]);
        out.push_str(&rewrite(found.as_str()));
        last = found.end();
    }
    out.push_str(&text[last..]);
    out
}

/// Splits sentence punctuation off the end of a URL or path.
fn split_trailing_punctuation(token: &str) -> (&str, &str) {
    let mut end = token.len();
    for (index, character) in token.char_indices().rev() {
        let unbalanced_paren = character == ')' && token[..index].contains('(');
        if !TRAILING_PUNCTUATION.contains(&character) || unbalanced_paren {
            break;
        }
        end = index;
    }
    token.split_at(end)
}

/// The site a URL names; a GitHub pull request or issue by its number.
fn speak_url(token: &str) -> String {
    let (url, trailing) = split_trailing_punctuation(token);
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let (authority, path) = rest
        .find(['/', '?', '#'])
        .map_or((rest, ""), |at| rest.split_at(at));
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host).to_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host).to_string();
    if host == "github.com" {
        let path = path.split(['?', '#']).next().unwrap_or("");
        let segments: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
        if let [_, _, kind, number, ..] = segments.as_slice()
            && !number.is_empty()
            && number.bytes().all(|byte| byte.is_ascii_digit())
        {
            match *kind {
                "pull" | "pulls" => return format!("pull request {number} on GitHub{trailing}"),
                "issues" => return format!("issue {number} on GitHub{trailing}"),
                _ => {}
            }
        }
    }
    if host.is_empty() {
        return token.to_string();
    }
    format!("{host}{trailing}")
}

/// A path's file or folder name; a slash in prose ("and/or", "24/7") as it
/// was. A relative token counts as a path when it has a file extension, or
/// three or more parts with a digit, dash, dot or underscore in them, or
/// four or more parts.
fn path_last_component(token: &str) -> String {
    let (path, trailing) = split_trailing_punctuation(token);
    let rooted = path.starts_with('/')
        || path.starts_with("~/")
        || path.starts_with("./")
        || path.starts_with("../");
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    let Some(last) = parts.last().copied() else {
        return token.to_string();
    };
    if !rooted {
        let starts_with_word = path
            .chars()
            .next()
            .is_some_and(|first| first.is_alphabetic() || first == '_');
        let has_extension = last.rsplit_once('.').is_some_and(|(stem, extension)| {
            !stem.is_empty()
                && (1..=6).contains(&extension.len())
                && extension.starts_with(|first: char| first.is_ascii_alphabetic())
                && extension.chars().all(|c| c.is_ascii_alphanumeric())
        });
        let marked = path
            .chars()
            .any(|c| c.is_ascii_digit() || matches!(c, '-' | '_' | '.'));
        let path_like = has_extension || (parts.len() >= 3 && marked) || parts.len() >= 4;
        if !starts_with_word || !path_like {
            return token.to_string();
        }
    }
    format!("{last}{trailing}")
}

/// Dash-joined numbers with a run of six or more digits, such as a command
/// id; dates and phone-length numbers stay.
fn remove_dash_id(token: &str) -> String {
    if token.split('-').any(|group| group.len() >= 6) {
        REMOVED.to_string()
    } else {
        token.to_string()
    }
}

/// Hex with both a digit and a letter, such as a commit hash; hex-letter
/// words ("defaced") and plain numbers stay.
fn remove_hex(token: &str) -> String {
    let digit = token.bytes().any(|byte| byte.is_ascii_digit());
    let letter = token.bytes().any(|byte| byte.is_ascii_alphabetic());
    if digit && letter {
        REMOVED.to_string()
    } else {
        token.to_string()
    }
}

/// What the voice says for `text`, after `strip_markdown_for_tts`: URLs
/// become their site (a GitHub pull request or issue its number), file and
/// folder paths their last component, and commit hashes, UUIDs and long or
/// dash-joined ids are dropped, so structured text is never read out
/// verbatim. Ordinary speech (versions, times, decimals, dates, "e.g.",
/// "and/or") is left alone. The notch shows the original text.
pub fn speakable_text(text: &str) -> String {
    let spoken = rewrite_matches(&URL_RE, text, speak_url);
    let spoken = rewrite_matches(&PATH_RE, &spoken, path_last_component);
    let spoken = rewrite_matches(&UUID_RE, &spoken, |_| REMOVED.to_string());
    let spoken = rewrite_matches(&DASH_ID_RE, &spoken, remove_dash_id);
    let spoken = rewrite_matches(&HEX_RE, &spoken, remove_hex);
    let spoken = rewrite_matches(&LONG_NUMBER_RE, &spoken, |_| REMOVED.to_string());
    if !spoken.contains(REMOVED) {
        return spoken;
    }
    let spoken = REMOVED_BRACKETS_RE
        .replace_all(&spoken, REMOVED)
        .into_owned();
    let spoken = REMOVED_DASH_RE.replace_all(&spoken, REMOVED).into_owned();
    let spoken = pattern::sub(&REMOVED_BEFORE_PUNCTUATION_RE, &spoken, 0);
    let spoken = pattern::sub(&REMOVED_AT_LINE_START_RE, &spoken, 0);
    REMOVED_RE.replace_all(&spoken, " ").into_owned()
}

/// What `queue_tts_text` speaks for a reply: markdown stripped, then made
/// speakable. Falls back to the stripped text when nothing speakable is
/// left, so a reply that is only an id is still delivered.
fn spoken_text(text: &str) -> (String, String) {
    let stripped = json::py_strip(&strip_markdown_for_tts(json::py_strip(text))).to_string();
    let spoken = json::py_strip(&speakable_text(&stripped)).to_string();
    if spoken.is_empty() {
        return (stripped.clone(), stripped);
    }
    (spoken, stripped)
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
    (
        payload.string("text"),
        display_text,
        command_seq,
        command_id,
    )
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
pub fn session_key_for_command(
    command_seq: Option<i64>,
    command_id: Option<&str>,
    state_path: &str,
) -> String {
    let (Some(seq), Some(id)) = (command_seq, command_id.filter(|id| !id.is_empty())) else {
        return String::new();
    };
    let state = read_json_file(state_path);
    let Some(sessions) = state.get("session_commands").and_then(Value::as_dict) else {
        return String::new();
    };
    for (key, entry) in sessions.iter() {
        if let Some(entry) = entry.as_dict()
            && entry
                .get("relay_command_id")
                .is_some_and(|value| value.is_str(id))
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
pub fn tagged_payload(
    text: &str,
    display_text: Option<&str>,
    command_seq: i64,
    command_id: &str,
) -> String {
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
    let mut display_preview = normalize_display_preview(display_text.as_deref());
    let (mut text, mut stripped) = spoken_text(&text);
    if text.is_empty() && !display_preview.is_empty() {
        (text, stripped) = spoken_text(&display_preview);
    }
    if text.is_empty() {
        return false;
    }
    // The speech service shows the spoken text when there is no display
    // text; keep showing what was written, not what is said.
    if display_preview.is_empty() && text != stripped {
        display_preview = stripped;
    }
    let work_fresh = options.freshness_scope == "work"
        && options.source == "lifecycle"
        && options.kind == "final";
    if (command_seq.is_some() || command_id.is_some()) && !work_fresh {
        let seq_value = command_seq.map(Value::Int);
        let id_value = command_id.as_deref().map(Value::from);
        let current = turns::relay_command_current(
            seq_value.as_ref(),
            id_value.as_ref(),
            &options.state_path,
        );
        let preserved = !current
            && options.preserved_command.as_ref().is_some_and(|preserved| {
                let key = relay_command_key(preserved);
                key.as_ref()
                    .map(|(seq, id)| (Some(*seq), Some(id.as_str())))
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
pub fn record_messenger_stage(
    speech: &dyn Speech,
    stage: &str,
    command: &Dict,
    at: Option<f64>,
    outcome: &str,
) {
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
            semantic_brief: Some(
                "Messenger unavailable; foreground delivery preserved.".to_string(),
            ),
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
    if cleaned.is_empty()
        || cleaned.starts_with("__")
        || pattern::search(&SENSITIVE_ACK_RE, cleaned)
    {
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
        assert_eq!(
            strip_markdown_for_tts("> **Done**: see [the doc](http://x) `now`"),
            "Done: see the doc now"
        );
        assert_eq!(
            strip_markdown_for_tts("1. first\n- second"),
            "first\n- second"
        );
    }

    /// RR-529: structured text is said by what it refers to.
    #[test]
    fn speakable_text_says_structured_text_in_plain_words() {
        for (written, spoken) in [
            // The Description's table.
            (
                "Edit /Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Settings/SettingsWindow.swift now.",
                "Edit SettingsWindow.swift now.",
            ),
            (
                "Opened https://github.com/matthewthomas94/relay-runner/pull/61.",
                "Opened pull request 61 on GitHub.",
            ),
            (
                "Merged the merge commit d63527b6.",
                "Merged the merge commit.",
            ),
            (
                "Command 11130-1795570645559451000-64 is done.",
                "Command is done.",
            ),
            (
                "Saved in ~/Library/Application Support/relay-runner/general-tasks today.",
                "Saved in general-tasks today.",
            ),
            // URLs.
            (
                "See github.com/matthewthomas94/relay-runner/issues/42, then reply.",
                "See issue 42 on GitHub, then reply.",
            ),
            (
                "Read https://docs.example.com/guide/start?x=1 first.",
                "Read docs.example.com first.",
            ),
            (
                "Visit www.apple.com/mac for details.",
                "Visit apple.com for details.",
            ),
            (
                "It runs on http://localhost:3000/board.",
                "It runs on localhost.",
            ),
            // Paths.
            ("Wrote ~/notes/today.md.", "Wrote today.md."),
            ("Logs are in /tmp/relay", "Logs are in relay"),
            (
                "Changed rust/relay-rs/src/bridge/speech.rs and tests.",
                "Changed speech.rs and tests.",
            ),
            ("Changed src/main.rs.", "Changed main.rs."),
            (
                "Changed SettingsWindow.swift.",
                "Changed SettingsWindow.swift.",
            ),
            // Ids.
            (
                "Run 6f1c2d3e-9a8b-4c7d-8e6f-5a4b3c2d1e0f failed.",
                "Run failed.",
            ),
            (
                "The artifact ticket-66eefb27a56eca95357c9e6b9357b5ec51c13d12 moved.",
                "The artifact ticket moved.",
            ),
            (
                "Merged (commit 4314ff90) into main.",
                "Merged (commit) into main.",
            ),
            ("Merged (4314ff90) into main.", "Merged into main."),
            ("d63527b6 merged.", "merged."),
            ("Token count 12345678901 reached.", "Token count reached."),
        ] {
            assert_eq!(speakable_text(written), spoken, "{written}");
        }
    }

    /// RR-529: ordinary speech is left alone.
    #[test]
    fn speakable_text_leaves_ordinary_speech_alone() {
        for text in [
            "Released 0.8.0 at 10:28 with 3.5 times the speed.",
            "Use a short reply, e.g. one sentence.",
            "Pick a branch and/or a tag, then turn it on/off.",
            "It shipped on 2026-11-25 and runs 24/7.",
            "RR-529 is in review; run 412 passed 1,234 tests.",
            "It was defaced, not effaced.",
            "Open the Settings/General tab.",
            "Version v0.8.1 (122) shipped.",
            "Call 555-123-4567.",
            "See github.com for details.",
        ] {
            assert_eq!(speakable_text(text), text);
        }
    }

    /// RR-529: the voice says the speakable text, the notch shows what was
    /// written.
    #[test]
    fn queued_speech_is_speakable_and_keeps_its_display_text() {
        let folder =
            std::env::temp_dir().join(format!("relay-rs-speakable-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        let options = || TtsOptions {
            command_path: folder
                .join("voice_cmd_ready")
                .to_string_lossy()
                .into_owned(),
            state_path: folder.join("state.json").to_string_lossy().into_owned(),
            ..TtsOptions::default()
        };
        let speech = Recorded::default();
        let written = "Opened https://github.com/o/r/pull/7 for `src/main.rs`.";
        assert!(queue_tts_text(&speech, written, options()));
        let payload = r#"{"text": "Merged d63527b6.", "display_text": "Merged **d63527b6**."}"#;
        assert!(queue_tts_text(&speech, payload, options()));
        assert!(queue_tts_text(
            &speech,
            "11130-1795570645559451000-64",
            options()
        ));
        let sent = speech.0.lock().unwrap().clone();
        assert_eq!(sent[0].text, "Opened pull request 7 on GitHub for main.rs.");
        assert_eq!(
            sent[0].display_text,
            "Opened https://github.com/o/r/pull/7 for src/main.rs."
        );
        assert_eq!(sent[1].text, "Merged.");
        assert_eq!(sent[1].display_text, "Merged **d63527b6**.");
        // Nothing speakable left: delivered as written rather than dropped.
        assert_eq!(sent[2].text, "11130-1795570645559451000-64");
        assert_eq!(sent[2].display_text, "");
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn tts_payloads_are_plain_text_or_tagged_json() {
        assert_eq!(
            parse_tts_payload("  hello  "),
            ("hello".to_string(), None, None, None)
        );
        assert_eq!(
            parse_tts_payload(
                r#"{"text": "hi", "display_text": "Hi!", "relay_command_seq": "3", "relay_command_id": "c"}"#
            ),
            (
                "hi".to_string(),
                Some("Hi!".to_string()),
                Some(3),
                Some("c".to_string())
            )
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
        assert_eq!(
            build_voice_acknowledgement(Some("fix the bug"), None),
            "I'll take care of that issue."
        );
        assert_eq!(
            build_voice_acknowledgement(Some("run the tests"), None),
            "I'll check the tests."
        );
        let sensitive = build_voice_acknowledgement(Some("fix my password"), None);
        assert_ne!(sensitive, "I'll take care of that issue.");
    }

    /// Records what the bridge hands the speech service.
    #[derive(Default)]
    struct Recorded(std::sync::Mutex<Vec<SpeechText>>);

    impl Speech for Recorded {
        fn submit_text(&self, request: SpeechText) -> bool {
            self.0.lock().unwrap().push(request);
            true
        }
        fn stop_playback(&self, _: &str) {}
        fn skip(&self, _: &str) {}
        fn playing(&self) -> bool {
            false
        }
        fn play_or_replay(&self) -> bool {
            false
        }
        fn note_play_control(&self, _: Option<f64>, _: f64) {}
        fn note_visual_acknowledgement(&self, _: f64, _: f64) {}
        fn replay(&self) -> bool {
            false
        }
        fn new_turn(&self, _: i64, _: &str) {}
        fn reload_config(&self) {}
        fn control_session(&self, _: &str, _: &str, _: &str) -> bool {
            false
        }
        fn session_playback_states(&self, _: &str) -> Dict {
            Dict::new()
        }
        fn queue_depth(&self) -> i64 {
            0
        }
        fn record_messenger_stage(
            &self,
            _: &str,
            _: i64,
            _: &str,
            _: Option<f64>,
            _: Option<&str>,
            _: &str,
        ) {
        }
        fn record_missing_outcome(&self, _: i64, _: &str, _: &str, _: &[String]) -> bool {
            false
        }
        fn shutdown(&self) {}
        fn played_coverage(&self, _: i64, _: &str) -> Vec<Dict> {
            Vec::new()
        }
        fn record_realization(&self, _: i64, _: &str, _: &str, _: &str, _: &str) {}
        fn attach_remote_sink(
            &self,
            _: std::sync::Arc<dyn super::super::speech_client::RemoteDevice>,
        ) {
        }
        fn detach_remote_sink(&self, _: &str, _: &str) {}
        fn attach_remote_mirror(
            &self,
            _: std::sync::Arc<dyn super::super::speech_client::RemoteDevice>,
        ) {
        }
        fn detach_remote_mirror(&self, _: &str) {}
        fn remote_ack(&self, _: &str, _: i64, _: bool) -> bool {
            false
        }
    }

    /// RR-520: messenger and lifecycle speech carry only a command seq/id; the
    /// bridge finds the session in the ledger and sends its key, which the
    /// speech service turns into that session's agent voice
    /// (`relay-speech/src/agents.rs`).
    #[test]
    fn speech_with_only_a_command_names_its_ledger_session() {
        let folder =
            std::env::temp_dir().join(format!("relay-rs-speech-ledger-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        let state_path = folder.join("voice_command_state.json");
        std::fs::write(
            &state_path,
            r#"{"relay_command_seq": 8, "relay_command_id": "cmd-8", "session_commands": {
                "transport-george": {"relay_command_seq": 7, "relay_command_id": "cmd-7"},
                "transport-sky": {"relay_command_seq": 8, "relay_command_id": "cmd-8"}}}"#,
        )
        .unwrap();
        let speech = Recorded::default();
        for (source, kind) in [("messenger", "handoff"), ("lifecycle", "progress")] {
            assert!(queue_tts_text(
                &speech,
                &tagged_payload("On it.", None, 8, "cmd-8"),
                TtsOptions {
                    command_path: folder
                        .join("voice_cmd_ready")
                        .to_string_lossy()
                        .into_owned(),
                    state_path: state_path.to_string_lossy().into_owned(),
                    source: source.to_string(),
                    kind: kind.to_string(),
                    ..TtsOptions::default()
                },
            ));
        }
        let sent = speech.0.lock().unwrap().clone();
        assert_eq!(sent.len(), 2);
        for request in &sent {
            assert_eq!(request.session_key, "transport-sky");
            assert_eq!(
                (request.command_seq, request.command_id.as_deref()),
                (Some(8), Some("cmd-8"))
            );
        }
        assert_eq!(sent[0].source, "messenger");
        assert_eq!(sent[1].source, "lifecycle");
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn acknowledgement_dismissal_grows_with_length() {
        assert_eq!(acknowledgement_auto_dismiss_seconds("ok"), 3.0);
        assert_eq!(acknowledgement_auto_dismiss_seconds(&"x".repeat(400)), 5.0);
    }
}
