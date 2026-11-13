//! Speech intents, the twin of `SpeechIntent` in `services/speech_coordinator.py`,
//! and the Python-compatible reading of request fields.

use serde_json::Value;

use crate::support::{self, Json};

pub const SPEECH_SOURCES: [&str; 5] = [
    "messenger",
    "orchestrator",
    "lifecycle",
    "completion",
    "fallback",
];
pub const SPEECH_KINDS: [&str; 6] = [
    "handoff",
    "progress",
    "clarification",
    "final",
    "fallback",
    "control",
];
pub const FRESHNESS_SCOPES: [&str; 2] = ["conversation", "work"];
pub const LIFECYCLE_ROLES: [&str; 8] = [
    "acknowledgement",
    "progress",
    "result",
    "failure",
    "blocker",
    "decision",
    "conversation",
    "control",
];
pub const REALIZATION_DECISIONS: [&str; 3] = ["full", "delta", "suppress"];

pub fn is_final_kind(kind: &str) -> bool {
    matches!(kind, "final" | "fallback")
}

/// RR-464: replies the queue keeps until they are played or skipped.
pub fn is_queued_reply_kind(kind: &str) -> bool {
    matches!(kind, "clarification" | "final" | "fallback")
}

pub fn is_superseding_kind(kind: &str) -> bool {
    is_queued_reply_kind(kind)
}

/// RR-460: real finals that may replace a provisional fallback outcome.
pub fn is_real_final_source(source: &str) -> bool {
    matches!(source, "completion" | "orchestrator")
}

pub type CommandKey = (i64, String);

#[derive(Clone, Debug, PartialEq)]
pub struct SpeechIntent {
    pub command_seq: Option<i64>,
    pub command_id: Option<String>,
    pub utterance_id: String,
    pub dedup_key: String,
    pub source: String,
    pub kind: String,
    pub authoritative: bool,
    pub priority: i64,
    pub display_text: String,
    pub semantic_brief: String,
    pub spoken_text: String,
    pub created_at: f64,
    pub expires_at: Option<f64>,
    pub freshness_scope: String,
    pub replacement_policy: String,
    pub work_disposition: Option<Json>,
    pub replayable: bool,
    pub lifecycle_role: String,
    pub covered_facts: Vec<String>,
    pub realization_decision: String,
    pub suppression_reason: String,
    pub original_utterance_id: String,
    pub replay_of: Option<String>,
    pub session_key: String,
}

impl SpeechIntent {
    pub fn command_key(&self) -> Option<CommandKey> {
        match (self.command_seq, &self.command_id) {
            (Some(seq), Some(id)) if !id.is_empty() => Some((seq, id.clone())),
            _ => None,
        }
    }

    /// A provisional outcome a late real final may still replace (RR-460).
    pub fn is_fallback_outcome(&self) -> bool {
        is_final_kind(&self.kind) && (self.kind == "fallback" || self.source == "fallback")
    }

    pub fn presentation_mode(&self) -> &'static str {
        if self.replay_of.is_some() {
            "explicit_replay"
        } else {
            "new_delivery"
        }
    }

    pub fn expired(&self) -> bool {
        self.expires_at
            .is_some_and(|expires_at| support::now() >= expires_at)
    }
}

/// What `SpeechIntent.build` takes; `None` means the default.
#[derive(Clone, Debug, Default)]
pub struct IntentSpec {
    pub spoken_text: String,
    pub display_text: Option<String>,
    pub semantic_brief: Option<String>,
    pub command_seq: Option<i64>,
    pub command_id: Option<String>,
    pub source: Option<String>,
    pub kind: Option<String>,
    pub authoritative: bool,
    pub priority: Option<i64>,
    pub dedup_key: Option<String>,
    pub utterance_id: Option<String>,
    pub expires_at: Option<f64>,
    pub freshness_scope: Option<String>,
    pub work_disposition: Option<Json>,
    pub replayable: Option<bool>,
    pub lifecycle_role: Option<String>,
    pub covered_facts: Vec<String>,
    pub realization_decision: Option<String>,
    pub suppression_reason: Option<String>,
    pub session_key: Option<String>,
}

fn default_priority(kind: &str, authoritative: bool) -> i64 {
    let base = match kind {
        "handoff" => 20,
        "progress" => 10,
        "clarification" => 80,
        "final" => 70,
        "fallback" => 60,
        "control" => 100,
        _ => 10,
    };
    base + if authoritative { 5 } else { 0 }
}

fn default_lifecycle_role(kind: &str) -> &'static str {
    match kind {
        "handoff" => "acknowledgement",
        "progress" => "progress",
        "clarification" => "decision",
        "final" | "fallback" => "result",
        "control" => "control",
        _ => "conversation",
    }
}

/// `_stable_digest`: the first 24 hex digits of the SHA-256 of the values
/// joined by U+001F.
fn stable_digest(values: &[&str]) -> String {
    let joined = values.join("\u{1f}");
    crate::sha256::hex_digest(joined.as_bytes())[..24].to_string()
}

fn trimmed(value: Option<&str>) -> String {
    value.unwrap_or("").trim().to_string()
}

pub fn build(spec: IntentSpec) -> SpeechIntent {
    let source = spec
        .source
        .filter(|source| SPEECH_SOURCES.contains(&source.as_str()))
        .unwrap_or_else(|| "fallback".into());
    let kind = spec
        .kind
        .filter(|kind| SPEECH_KINDS.contains(&kind.as_str()))
        .unwrap_or_else(|| "fallback".into());
    let spoken = spec.spoken_text.trim().to_string();
    let display = Some(trimmed(spec.display_text.as_deref()))
        .filter(|display| !display.is_empty())
        .unwrap_or_else(|| spoken.clone());
    let brief = spec
        .semantic_brief
        .filter(|brief| !brief.is_empty())
        .unwrap_or_else(|| {
            if display.is_empty() {
                spoken.clone()
            } else {
                display.clone()
            }
        })
        .trim()
        .to_string();
    let command_id = spec.command_id.filter(|id| !id.is_empty());
    let has_command = spec.command_seq.is_some() && command_id.is_some();
    let python = |value: &Option<String>| value.clone().unwrap_or_else(|| "None".into());
    let seq_text = spec
        .command_seq
        .map_or_else(|| "None".to_string(), |seq| seq.to_string());
    // RR-460: a fallback keeps its own slot so the real final is never
    // deduplicated against it; two real finals still share one.
    let outcome_prefix = if kind == "fallback" || source == "fallback" {
        "outcome-fallback"
    } else {
        "outcome"
    };
    let dedup_key = spec
        .dedup_key
        .filter(|key| !key.is_empty())
        .unwrap_or_else(|| {
            if is_final_kind(&kind) && has_command {
                format!("{outcome_prefix}:{seq_text}:{}", python(&command_id))
            } else {
                format!(
                    "{source}:{kind}:{seq_text}:{}:{}",
                    python(&command_id),
                    stable_digest(&[&brief, &spoken])
                )
            }
        });
    let mut scope = spec
        .freshness_scope
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if scope.is_empty() {
        scope = "conversation".into();
    }
    if !FRESHNESS_SCOPES.contains(&scope.as_str())
        || (scope == "work" && (source != "lifecycle" || kind != "final"))
    {
        scope = "conversation".into();
    }
    let mut role = spec
        .lifecycle_role
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if role.is_empty() || !LIFECYCLE_ROLES.contains(&role.as_str()) {
        role = default_lifecycle_role(&kind).into();
    }
    let mut decision = spec
        .realization_decision
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if !REALIZATION_DECISIONS.contains(&decision.as_str()) {
        decision = "full".into();
    }
    let utterance_id = spec
        .utterance_id
        .filter(|id| !id.is_empty())
        .unwrap_or_else(support_uuid);
    let facts = spec
        .covered_facts
        .iter()
        .map(|fact| fact.trim().to_string())
        .filter(|fact| !fact.is_empty())
        .collect();
    SpeechIntent {
        command_seq: spec.command_seq,
        command_id,
        utterance_id: utterance_id.clone(),
        dedup_key,
        priority: spec
            .priority
            .unwrap_or_else(|| default_priority(&kind, spec.authoritative)),
        replayable: spec.replayable.unwrap_or(kind == "final"),
        source,
        kind,
        authoritative: spec.authoritative,
        display_text: display,
        semantic_brief: brief,
        spoken_text: spoken,
        created_at: support::now(),
        expires_at: spec.expires_at,
        freshness_scope: scope,
        replacement_policy: "semantic".into(),
        work_disposition: spec.work_disposition,
        lifecycle_role: role,
        covered_facts: facts,
        realization_decision: decision,
        suppression_reason: trimmed(spec.suppression_reason.as_deref()),
        original_utterance_id: utterance_id,
        replay_of: None,
        session_key: trimmed(spec.session_key.as_deref()),
    }
}

/// `str(uuid.uuid4())`.
pub fn support_uuid() -> String {
    let mut bytes = [0u8; 16];
    random_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// `uuid.uuid4().hex`.
pub fn uuid_hex() -> String {
    support_uuid().replace('-', "")
}

pub fn random_bytes(buffer: &mut [u8]) {
    for chunk in buffer.chunks_mut(256) {
        // SAFETY: getentropy fills at most 256 bytes of a valid buffer.
        let status = unsafe { libc::getentropy(chunk.as_mut_ptr().cast(), chunk.len()) };
        assert_eq!(status, 0, "getentropy failed");
    }
}

/// A request field that is malformed: the request fails with `invalid_request`.
#[derive(Debug)]
pub struct Malformed;

/// Python's truthiness of a JSON value.
pub fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|value| value != 0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
    }
}

/// `str(value)` for a JSON value, as Python prints it.
pub fn py_str(value: &Value) -> String {
    match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(number) => {
            if number.is_f64() {
                let value = number.as_f64().unwrap_or_default();
                if value.fract() == 0.0 && value.abs() < 1e16 {
                    format!("{value:.1}")
                } else {
                    value.to_string()
                }
            } else {
                number.to_string()
            }
        }
        Value::String(text) => text.clone(),
        other => support::python_dumps(other),
    }
}

/// `str(value or "")`.
pub fn py_str_or_empty(value: Option<&Value>) -> String {
    if truthy(value) {
        py_str(value.unwrap_or(&Value::Null))
    } else {
        String::new()
    }
}

/// `int(value)`: integers, whole or truncated floats, booleans and digit strings.
pub fn py_int(value: &Value) -> Result<i64, Malformed> {
    match value {
        Value::Bool(flag) => Ok(i64::from(*flag)),
        Value::Number(number) => number
            .as_i64()
            .or_else(|| {
                number
                    .as_f64()
                    .filter(|value| value.is_finite())
                    .map(|value| value.trunc() as i64)
            })
            .ok_or(Malformed),
        Value::String(text) => text.trim().replace('_', "").parse().map_err(|_| Malformed),
        _ => Err(Malformed),
    }
}

/// `float(value)`.
pub fn py_float(value: &Value) -> Result<f64, Malformed> {
    match value {
        Value::Bool(flag) => Ok(f64::from(u8::from(*flag))),
        Value::Number(number) => number.as_f64().ok_or(Malformed),
        Value::String(text) => {
            let text = text.trim().to_lowercase();
            match text.as_str() {
                "nan" | "inf" | "infinity" | "-inf" | "-infinity" | "+inf" => Err(Malformed),
                _ => text.replace('_', "").parse().map_err(|_| Malformed),
            }
        }
        _ => Err(Malformed),
    }
}

fn optional<'a>(request: &'a Json, name: &str) -> Option<&'a Value> {
    request.get(name).filter(|value| !value.is_null())
}

/// The intent a `speak` request proposes, read as `SpeechIntent.build` reads it.
pub fn spec_from_request(request: &Json) -> Result<IntentSpec, Malformed> {
    let text = |name: &str| optional(request, name).map(|value| py_str_or_empty(Some(value)));
    let work_disposition = match optional(request, "work_disposition") {
        Some(Value::Object(map)) if !map.is_empty() => Some(map.clone()),
        Some(value) if truthy(Some(value)) => return Err(Malformed),
        _ => None,
    };
    let covered_facts = match optional(request, "covered_facts") {
        None => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| py_str_or_empty(Some(item)))
            .collect(),
        Some(Value::String(text)) => text.chars().map(String::from).collect(),
        Some(_) => return Err(Malformed),
    };
    Ok(IntentSpec {
        spoken_text: py_str_or_empty(request.get("text")),
        display_text: text("display_text"),
        semantic_brief: text("semantic_brief"),
        command_seq: optional(request, "command_seq").map(py_int).transpose()?,
        command_id: optional(request, "command_id")
            .filter(|value| truthy(Some(value)))
            .map(py_str),
        source: optional(request, "source").map(py_str),
        kind: optional(request, "kind").map(py_str),
        authoritative: truthy(request.get("authoritative")),
        priority: optional(request, "priority").map(py_int).transpose()?,
        dedup_key: optional(request, "dedup_key")
            .filter(|value| truthy(Some(value)))
            .map(py_str),
        utterance_id: optional(request, "utterance_id")
            .filter(|value| truthy(Some(value)))
            .map(py_str),
        expires_at: optional(request, "expires_at").map(py_float).transpose()?,
        freshness_scope: text("freshness_scope"),
        work_disposition,
        replayable: optional(request, "replayable").map(|value| truthy(Some(value))),
        lifecycle_role: text("lifecycle_role"),
        covered_facts,
        realization_decision: text("realization_decision"),
        suppression_reason: text("suppression_reason"),
        session_key: text("session_key"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(text: &str) -> IntentSpec {
        IntentSpec {
            spoken_text: text.into(),
            ..Default::default()
        }
    }

    #[test]
    fn defaults_follow_the_kind() {
        let intent = build(spec("  Hello.  "));
        assert_eq!(
            (intent.source.as_str(), intent.kind.as_str()),
            ("fallback", "fallback")
        );
        assert_eq!(intent.spoken_text, "Hello.");
        assert_eq!(intent.display_text, "Hello.");
        assert_eq!(intent.priority, 60);
        assert!(!intent.replayable);
        assert_eq!(intent.lifecycle_role, "result");
        assert_eq!(intent.original_utterance_id, intent.utterance_id);
        assert_eq!(intent.freshness_scope, "conversation");

        let final_reply = build(IntentSpec {
            kind: Some("final".into()),
            authoritative: true,
            ..spec("Done.")
        });
        assert_eq!(final_reply.priority, 75);
        assert!(final_reply.replayable);
    }

    #[test]
    fn dedup_keys_match_python() {
        let command = |kind: &str, source: &str| IntentSpec {
            command_seq: Some(3),
            command_id: Some("command-3".into()),
            kind: Some(kind.into()),
            source: Some(source.into()),
            ..spec("Done.")
        };
        assert_eq!(
            build(command("final", "orchestrator")).dedup_key,
            "outcome:3:command-3"
        );
        assert_eq!(
            build(command("final", "fallback")).dedup_key,
            "outcome-fallback:3:command-3"
        );
        assert_eq!(
            build(command("fallback", "messenger")).dedup_key,
            "outcome-fallback:3:command-3"
        );
        // hashlib.sha256("Done.\x1fDone.").hexdigest()[:24]
        assert_eq!(
            build(command("progress", "messenger")).dedup_key,
            format!(
                "messenger:progress:3:command-3:{}",
                stable_digest(&["Done.", "Done."])
            )
        );
        assert_eq!(
            build(spec("Hi.")).dedup_key,
            format!(
                "fallback:fallback:None:None:{}",
                stable_digest(&["Hi.", "Hi."])
            )
        );
    }

    #[test]
    fn work_scope_needs_a_lifecycle_final() {
        let work = |kind: &str, source: &str| {
            build(IntentSpec {
                freshness_scope: Some("WORK".into()),
                kind: Some(kind.into()),
                source: Some(source.into()),
                ..spec("x")
            })
            .freshness_scope
        };
        assert_eq!(work("final", "lifecycle"), "work");
        assert_eq!(work("final", "orchestrator"), "conversation");
        assert_eq!(work("progress", "lifecycle"), "conversation");
    }

    #[test]
    fn request_fields_are_read_like_python() {
        let request = |text: &str| serde_json::from_str::<Json>(text).unwrap();
        let spec = spec_from_request(&request(
            r#"{"text": "Hi.", "command_seq": "4", "command_id": 7, "priority": 9.7, "expires_at": "12.5",
                "authoritative": 1, "covered_facts": ["a", " ", 3], "kind": null, "work_disposition": {}}"#,
        ))
        .unwrap();
        assert_eq!(spec.command_seq, Some(4));
        assert_eq!(spec.command_id.as_deref(), Some("7"));
        assert_eq!(spec.priority, Some(9));
        assert_eq!(spec.expires_at, Some(12.5));
        assert!(spec.authoritative);
        assert_eq!(spec.covered_facts, ["a", " ", "3"]);
        assert!(spec.kind.is_none() && spec.work_disposition.is_none());
        for bad in [
            r#"{"text": "x", "work_disposition": "preserve"}"#,
            r#"{"text": "x", "covered_facts": 5}"#,
            r#"{"text": "x", "expires_at": "tomorrow"}"#,
            r#"{"text": "x", "priority": "high"}"#,
            r#"{"text": "x", "command_seq": "soon"}"#,
        ] {
            assert!(spec_from_request(&request(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn uuids_have_the_python_shape() {
        let id = support_uuid();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert_eq!(uuid_hex().len(), 32);
        assert_ne!(support_uuid(), support_uuid());
    }
}
