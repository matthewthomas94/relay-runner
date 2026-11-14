//! The project note document and note index contract of
//! `services/note_contract.py`, as far as the artifact store uses it: every
//! commit re-renders note Markdown into its canonical form and checks the
//! typed note index against the materialized notes.

use std::sync::LazyLock;

use fancy_regex::Regex;
use relay_intents::json::{self, Dict, Value};

use crate::{Error, ErrorKind, Result, isotime, pystr};

pub const NOTE_SCHEMA_VERSION: i64 = 1;
pub const NOTE_INDEX_SCHEMA_VERSION: i64 = 1;
pub const NOTE_MAX_BYTES: usize = 8 * 1024 * 1024;
pub const NOTE_RECORDING_STATES: [&str; 3] = ["recording", "paused", "completed"];
pub const NOTE_CHECKPOINT_REASONS: [&str; 5] =
    ["checkpoint", "pause", "resume", "complete", "manual"];

const SEGMENT_MARKER: &str = "<!-- relay-note-segment ";
static SEGMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^<!-- relay-note-segment (\{.*\}) -->$").expect("segment pattern")
});

fn contract(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::NoteContract, message)
}

fn all_chars(text: &str, allowed: impl Fn(char) -> bool) -> bool {
    text.chars().all(allowed)
}

fn safe_id_char(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | ':' | '-')
}

/// `_SAFE_ID_RE.fullmatch`.
pub fn is_safe_id(text: &str) -> bool {
    (1..=160).contains(&text.len()) && all_chars(text, safe_id_char)
}

/// `_ARTIFACT_ID_RE.fullmatch`.
pub fn is_artifact_id(text: &str) -> bool {
    (8..=160).contains(&text.len()) && all_chars(text, safe_id_char)
}

fn is_lower_hex(text: &str) -> bool {
    all_chars(text, |c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

/// `_OBJECT_ID_RE.fullmatch`: a SHA-1 or SHA-256 Git object id.
pub fn is_object_id(text: &str) -> bool {
    matches!(text.len(), 40 | 64) && is_lower_hex(text)
}

/// `_DIGEST_RE.fullmatch`: a SHA-256 hex digest.
pub fn is_digest(text: &str) -> bool {
    text.len() == 64 && is_lower_hex(text)
}

/// `validate_note_id`: `<prefix>-N<number>` without zero padding.
pub fn validate_note_id(value: &str) -> Result<(String, u64)> {
    let parsed = value.rsplit_once("-N").and_then(|(prefix, number)| {
        let valid = !prefix.is_empty()
            && prefix.chars().all(|c| c.is_ascii_alphanumeric())
            && number.starts_with(|c: char| ('1'..='9').contains(&c))
            && number.chars().all(|c| c.is_ascii_digit());
        valid.then(|| (prefix.to_string(), number.parse::<u64>().ok()))
    });
    match parsed {
        Some((prefix, Some(number))) => Ok((prefix, number)),
        // A number too large for u64 still has Python's valid form.
        Some((prefix, None)) => Ok((prefix, u64::MAX)),
        None => Err(contract(format!(
            "invalid unpadded note ID: {}",
            pystr::repr(value)
        ))),
    }
}

/// `validate_timestamp`: what `datetime.fromisoformat` reads, with an offset.
pub fn validate_timestamp(value: &str, label: &str) -> Result<()> {
    match isotime::fromisoformat(&value.replace('Z', "+00:00")) {
        Err(_) => Err(contract(format!(
            "{label} is not RFC 3339: {}",
            pystr::repr(value)
        ))),
        Ok(parsed) if parsed.offset_us.is_none() => {
            Err(contract(format!("{label} must include a UTC offset")))
        }
        Ok(_) => Ok(()),
    }
}

/// `str(value.get(key) or "")` on a JSON object.
fn text_field(value: &Dict, key: &str) -> String {
    value.string(key)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteIdentity {
    pub note_id: String,
    pub artifact_id: String,
    pub project_id: String,
    pub created_at: String,
    pub capture_started_at: String,
}

impl NoteIdentity {
    fn new(
        note_id: String,
        artifact_id: String,
        project_id: String,
        created_at: String,
        capture_started_at: String,
    ) -> Result<Self> {
        validate_note_id(&note_id)?;
        if !is_artifact_id(&artifact_id) {
            return Err(contract("note immutable artifact_id is invalid"));
        }
        if !is_safe_id(&project_id) {
            return Err(contract("note project_id is invalid"));
        }
        validate_timestamp(&created_at, "note created_at")?;
        validate_timestamp(&capture_started_at, "note capture_started_at")?;
        Ok(Self {
            note_id,
            artifact_id,
            project_id,
            created_at,
            capture_started_at,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteSegment {
    pub segment_id: String,
    pub captured_at: String,
    pub text: String,
    pub start_ms: Option<i64>,
    pub end_ms: Option<i64>,
    pub speaker: Option<String>,
}

/// `_optional_nonnegative_int`. Python also takes an integer beyond `i64`;
/// no recorder writes one.
fn optional_nonnegative_int(value: Option<&Value>, label: &str) -> Result<Option<i64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Int(number)) if *number >= 0 => Ok(Some(*number)),
        Some(_) => Err(contract(format!("{label} must be a nonnegative integer"))),
    }
}

impl NoteSegment {
    /// `NoteSegment.from_mapping`.
    pub fn from_mapping(value: &Dict) -> Result<Self> {
        let start_ms = optional_nonnegative_int(value.get("start_ms"), "segment start_ms")?;
        let end_ms = optional_nonnegative_int(value.get("end_ms"), "segment end_ms")?;
        if let (Some(start), Some(end)) = (start_ms, end_ms)
            && end < start
        {
            return Err(contract("segment end_ms cannot precede start_ms"));
        }
        let speaker = value
            .present("speaker")
            .map(|speaker| pystr::strip(&speaker.py_str()).to_string());
        if let Some(speaker) = &speaker
            && (speaker.is_empty()
                || speaker.len() > 160
                || speaker.contains("-->")
                || speaker.chars().any(|c| (c as u32) < 32))
        {
            return Err(contract("segment speaker must be 1 to 160 UTF-8 bytes"));
        }
        let text = text_field(value, "text")
            .trim_end_matches(pystr::is_space)
            .to_string();
        if pystr::strip(&text).is_empty() {
            return Err(contract("segment text is required"));
        }
        if text.contains(SEGMENT_MARKER) {
            return Err(contract(
                "segment text contains reserved Relay note metadata",
            ));
        }
        let segment = Self {
            segment_id: text_field(value, "segment_id"),
            captured_at: text_field(value, "captured_at"),
            text,
            start_ms,
            end_ms,
            speaker,
        };
        if !is_safe_id(&segment.segment_id) {
            return Err(contract("segment_id is invalid"));
        }
        validate_timestamp(&segment.captured_at, "segment captured_at")?;
        Ok(segment)
    }

    /// `NoteSegment.metadata()`, the JSON in the segment's HTML comment.
    pub fn metadata(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("captured_at", self.captured_at.as_str());
        value.insert("segment_id", self.segment_id.as_str());
        if let Some(start) = self.start_ms {
            value.insert("start_ms", start);
        }
        if let Some(end) = self.end_ms {
            value.insert("end_ms", end);
        }
        if let Some(speaker) = &self.speaker {
            value.insert("speaker", speaker.as_str());
        }
        value
    }

    fn as_dict(&self) -> Dict {
        let mut value = self.metadata();
        value.insert("text", self.text.as_str());
        value
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteUpdate {
    pub captured_at: String,
    pub recording_state: String,
    pub checkpoint_reason: String,
    pub segments: Vec<NoteSegment>,
    pub capture_ended_at: Option<String>,
}

impl NoteUpdate {
    /// `NoteUpdate.from_values`.
    pub fn from_values(
        captured_at: &str,
        recording_state: &str,
        checkpoint_reason: &str,
        raw_segments: &[Dict],
        capture_ended_at: Option<&str>,
    ) -> Result<Self> {
        validate_timestamp(captured_at, "note captured_at")?;
        if !NOTE_RECORDING_STATES.contains(&recording_state) {
            return Err(contract("note recording_state is invalid"));
        }
        if !NOTE_CHECKPOINT_REASONS.contains(&checkpoint_reason) {
            return Err(contract("note checkpoint_reason is invalid"));
        }
        if let Some(ended) = capture_ended_at {
            validate_timestamp(ended, "note capture_ended_at")?;
        }
        if (recording_state == "completed") != capture_ended_at.is_some() {
            return Err(contract(
                "capture_ended_at is required exactly when recording_state is completed",
            ));
        }
        let mut segments: Vec<NoteSegment> = Vec::new();
        for raw in raw_segments {
            let segment = NoteSegment::from_mapping(raw)?;
            if segments
                .iter()
                .any(|seen| seen.segment_id == segment.segment_id)
            {
                return Err(contract(format!(
                    "duplicate note segment_id: {}",
                    segment.segment_id
                )));
            }
            segments.push(segment);
        }
        Ok(Self {
            captured_at: captured_at.to_string(),
            recording_state: recording_state.to_string(),
            checkpoint_reason: checkpoint_reason.to_string(),
            segments,
            capture_ended_at: capture_ended_at.map(str::to_string),
        })
    }
}

#[derive(Clone, Debug)]
pub struct NoteDocument {
    pub identity: NoteIdentity,
    pub update: NoteUpdate,
    pub metadata: Option<Dict>,
    /// A JSON escape named a lone surrogate. Python reads the document, but
    /// cannot encode it as UTF-8 again, so rendering it fails.
    pub(crate) lone_surrogate: bool,
}

/// Python 3.14's `TypeError` for an unhashable value tested against a set.
pub(crate) fn unhashable(type_name: &str) -> Error {
    Error::new(
        ErrorKind::Type,
        format!("cannot use '{type_name}' as a set element (unhashable type: '{type_name}')"),
    )
}

/// Python's `value not in {...}` for a JSON value against strings. A list
/// or object is unhashable: Python raises `TypeError`.
fn in_set(value: Option<&Value>, allowed: &[&str]) -> Result<bool> {
    match value {
        Some(Value::List(_)) => Err(unhashable("list")),
        Some(Value::Dict(_)) => Err(unhashable("dict")),
        Some(Value::Str(text)) => Ok(allowed.contains(&text.as_str())),
        _ => Ok(false),
    }
}

/// `validate_note_metadata`. Parsing wraps its `NoteContractError` and
/// `TypeError` refusals in `NoteContractError("invalid note metadata")`, as
/// Python does.
pub fn validate_note_metadata(value: &Value) -> Result<Dict> {
    check_note_metadata(value, &[])
}

/// `validate_note_metadata` over JSON whose `surrogates` strings held a lone
/// surrogate: measuring one of those as UTF-8 fails, as `str.encode` does.
fn check_note_metadata(value: &Value, surrogates: &[String]) -> Result<Dict> {
    let Some(metadata) = value.as_dict() else {
        return Err(contract("note metadata must be an object"));
    };
    if !in_set(metadata.get("origin"), &["generated", "manual"])? {
        return Err(contract("note metadata origin is invalid"));
    }
    if !in_set(
        metadata.get("state"),
        &["pending", "ready", "failed", "empty"],
    )? {
        return Err(contract("note metadata state is invalid"));
    }
    for key in ["source_sha256", "generated_source_sha256"] {
        if let Some(digest) = metadata.present(key)
            && !is_digest(&digest.py_str())
        {
            return Err(contract("note metadata source digest is invalid"));
        }
    }
    for (key, limit) in [
        ("title", 240),
        ("summary", 4000),
        ("model", 160),
        ("error_code", 80),
    ] {
        if let Some(field) = metadata.present(key) {
            if let Some(text) = field.as_str()
                && !pystr::strip(text).is_empty()
                && surrogates.iter().any(|tainted| tainted == text)
            {
                return Err(Error::value(
                    "'utf-8' codec can't encode character: surrogates not allowed",
                ));
            }
            let valid = field.as_str().is_some_and(|text| {
                !pystr::strip(text).is_empty()
                    && text.len() <= limit
                    && !text.chars().any(|c| (c as u32) < 32 && c != '\n')
            });
            if !valid {
                return Err(contract(format!("note metadata {key} is invalid")));
            }
        }
    }
    if metadata
        .get("state")
        .is_some_and(|state| state.is_str("ready"))
        && !(metadata.truthy("title").is_some() && metadata.truthy("summary").is_some())
    {
        return Err(contract("ready note metadata requires title and summary"));
    }
    match metadata.get("provider") {
        None | Some(Value::Null) => {}
        provider => {
            if !in_set(provider, &["codex", "claude"])? {
                return Err(contract("note metadata provider is invalid"));
            }
        }
    }
    if let Some(generated) = metadata.present("generated_at") {
        // Python calls `.replace` on the value: anything but a string fails.
        let Some(generated) = generated.as_str() else {
            return Err(Error::new(
                ErrorKind::Attribute,
                format!(
                    "'{}' object has no attribute 'replace'",
                    pystr::type_name(generated)
                ),
            ));
        };
        validate_timestamp(generated, "note metadata generated_at")?;
    }
    Ok(metadata.clone())
}

/// `render_note_document`: the canonical Markdown of a note.
pub fn render_note_document(document: &NoteDocument) -> Result<Vec<u8>> {
    if document.lone_surrogate {
        return Err(Error::value(
            "'utf-8' codec can't encode character: surrogates not allowed",
        ));
    }
    let identity = &document.identity;
    let update = &document.update;
    let mut fields = vec![
        "---".to_string(),
        format!("note_schema_version: {NOTE_SCHEMA_VERSION}"),
        format!("id: {}", identity.note_id),
        format!("artifact_id: {}", identity.artifact_id),
        format!("project_id: {}", identity.project_id),
        format!("created_at: {}", identity.created_at),
        format!("capture_started_at: {}", identity.capture_started_at),
        format!("updated_at: {}", update.captured_at),
        format!("recording_state: {}", update.recording_state),
        format!("checkpoint_reason: {}", update.checkpoint_reason),
        format!("segment_count: {}", update.segments.len()),
    ];
    if let Some(ended) = &update.capture_ended_at {
        fields.push(format!("capture_ended_at: {ended}"));
    }
    if let Some(metadata) = &document.metadata {
        let metadata = validate_note_metadata(&Value::Dict(metadata.clone()))?;
        fields.push(format!(
            "note_metadata: {}",
            json::dumps_unicode(&Value::Dict(metadata))
        ));
    }
    fields.extend(["---", "", "## Transcript", ""].map(str::to_string));
    for segment in &update.segments {
        let metadata = json::dumps_compact_sorted_unicode(&Value::Dict(segment.metadata()));
        fields.push(format!("{SEGMENT_MARKER}{metadata} -->"));
        fields.push(segment.text.clone());
        fields.push(String::new());
    }
    Ok(pystr::join_lines_with_final_newline(&fields).into_bytes())
}

/// `_split_front_matter`.
fn split_front_matter(text: &str) -> Result<(Vec<(String, String)>, String)> {
    let lines = pystr::splitlines(text);
    if lines.is_empty() || pystr::strip(lines[0]) != "---" {
        return Err(contract("note Markdown must have YAML front matter"));
    }
    let closing = lines[1..]
        .iter()
        .position(|line| pystr::strip(line) == "---")
        .map(|index| index + 1)
        .ok_or_else(|| contract("note Markdown front matter is not closed"))?;
    let mut front: Vec<(String, String)> = Vec::new();
    for line in &lines[1..closing] {
        let (key, found, value) = pystr::partition(line, ":");
        if found {
            let key = pystr::strip(key).to_string();
            let value = pystr::strip_quotes(pystr::strip(value)).to_string();
            match front.iter_mut().find(|(name, _)| *name == key) {
                Some(entry) => entry.1 = value,
                None => front.push((key, value)),
            }
        }
    }
    let body = lines[closing + 1..]
        .join("\n")
        .trim_matches('\n')
        .to_string();
    Ok((front, body))
}

fn front_get<'f>(front: &'f [(String, String)], key: &str) -> Option<&'f str> {
    front
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_str())
}

/// `_parse_segments`.
fn parse_segments(body: &str, lone_surrogate: &mut bool) -> Result<Vec<NoteSegment>> {
    let header = "## Transcript";
    let Some(rest) = body.strip_prefix(header) else {
        return Err(contract("note Markdown has no Transcript section"));
    };
    let transcript = rest.trim_matches('\n');
    if transcript.is_empty() {
        return Ok(Vec::new());
    }
    let matches: Vec<fancy_regex::Captures<'_, str>> = SEGMENT
        .captures_iter(transcript)
        .map_while(std::result::Result::ok)
        .collect();
    let outside = |end: usize| !pystr::strip(&transcript[..end]).is_empty();
    match matches.first() {
        Some(first) if !outside(first.get(0).expect("group 0").start()) => {}
        _ => {
            return Err(contract(
                "note transcript contains content outside typed segments",
            ));
        }
    }
    let mut segments = Vec::new();
    for (index, found) in matches.iter().enumerate() {
        let whole = found.get(0).expect("group 0");
        let end = matches.get(index + 1).map_or(transcript.len(), |next| {
            next.get(0).expect("group 0").start()
        });
        let raw_text = transcript[whole.end()..end].trim_matches('\n');
        let metadata = json::parse(&found[1])
            .ok_or_else(|| contract("note segment metadata is invalid JSON: Expecting value"))?;
        *lone_surrogate |= json::parse_strict(&found[1]).is_none();
        let Value::Dict(mut metadata) = metadata else {
            return Err(contract("note segment metadata must be an object"));
        };
        metadata.insert("text", raw_text);
        segments.push(NoteSegment::from_mapping(&metadata)?);
    }
    Ok(segments)
}

/// `parse_note_document`.
pub fn parse_note_document(content: &[u8]) -> Result<NoteDocument> {
    let text = std::str::from_utf8(content).map_err(|_| contract("note Markdown is not UTF-8"))?;
    if text.contains('\0') {
        return Err(contract("note Markdown contains NUL bytes"));
    }
    let (front, body) = split_front_matter(text)?;
    let get = |key: &str| front_get(&front, key);
    let schema = pystr::int(get("note_schema_version").unwrap_or(""))
        .ok_or_else(|| contract("note_schema_version is invalid"))?;
    if schema != NOTE_SCHEMA_VERSION {
        return Err(contract(format!(
            "unsupported note_schema_version {schema}; expected {NOTE_SCHEMA_VERSION}"
        )));
    }
    let owned = |key: &str| get(key).unwrap_or("").to_string();
    let identity = NoteIdentity::new(
        owned("id"),
        owned("artifact_id"),
        owned("project_id"),
        owned("created_at"),
        owned("capture_started_at"),
    )?;
    let mut lone_surrogate = false;
    let segments = parse_segments(&body, &mut lone_surrogate)?;
    let segment_count = pystr::int(get("segment_count").unwrap_or(""))
        .ok_or_else(|| contract("note segment_count is invalid"))?;
    if usize::try_from(segment_count).ok() != Some(segments.len()) {
        return Err(contract(
            "note segment_count does not match transcript segments",
        ));
    }
    let raw_segments: Vec<Dict> = segments.iter().map(NoteSegment::as_dict).collect();
    let update = NoteUpdate::from_values(
        get("updated_at").unwrap_or(""),
        get("recording_state").unwrap_or(""),
        get("checkpoint_reason").unwrap_or(""),
        &raw_segments,
        get("capture_ended_at"),
    )?;
    let metadata = match get("note_metadata") {
        None => None,
        Some(raw) => {
            let invalid = || contract("invalid note metadata");
            let (value, surrogates) = json::parse_reporting(raw).ok_or_else(invalid)?;
            lone_surrogate |= !surrogates.is_empty();
            // Python wraps ValueError (a failed UTF-8 encode among them) and
            // TypeError; an AttributeError escapes.
            match check_note_metadata(&value, &surrogates) {
                Ok(metadata) => Some(metadata),
                Err(error)
                    if matches!(
                        error.kind,
                        ErrorKind::NoteContract | ErrorKind::Type | ErrorKind::Value
                    ) =>
                {
                    return Err(invalid());
                }
                Err(error) => return Err(error),
            }
        }
    };
    Ok(NoteDocument {
        identity,
        update,
        metadata,
        lone_surrogate,
    })
}

/// `decode_note_index`: the typed index entries by immutable artifact id, in
/// file order.
pub fn decode_note_index(content: &[u8], project_id: &str) -> Result<Vec<(String, Dict)>> {
    let text = std::str::from_utf8(content).map_err(|_| contract("note index is not UTF-8"))?;
    let mut entries: Vec<(String, Dict)> = Vec::new();
    let mut note_ids: Vec<String> = Vec::new();
    for (index, line) in pystr::splitlines(text).into_iter().enumerate() {
        let line_number = index + 1;
        if pystr::strip(line).is_empty() {
            continue;
        }
        let value = json::parse(line)
            .ok_or_else(|| contract(format!("note index line {line_number} is invalid JSON")))?;
        let Value::Dict(value) = value else {
            return Err(contract(format!(
                "note index line {line_number} is not an object"
            )));
        };
        validate_index_entry(&value, project_id, line_number)?;
        let artifact_id = value.string("artifact_id");
        let note_id = value.string("note_id");
        if entries.iter().any(|(id, _)| *id == artifact_id) || note_ids.contains(&note_id) {
            return Err(contract(
                "note index has duplicate note or artifact identity",
            ));
        }
        entries.push((artifact_id, value));
        note_ids.push(note_id);
    }
    Ok(entries)
}

fn validate_index_entry(value: &Dict, project_id: &str, line_number: usize) -> Result<()> {
    let schema = value.get("schema_version").unwrap_or(&Value::Null);
    if !json::py_eq(schema, &Value::Int(NOTE_INDEX_SCHEMA_VERSION)) {
        return Err(contract(format!(
            "note index line {line_number} has unsupported schema"
        )));
    }
    let note_id = value.string("note_id");
    validate_note_id(&note_id)?;
    if !is_artifact_id(&value.string("artifact_id")) {
        return Err(contract("note index artifact_id is invalid"));
    }
    if !value
        .get("project_id")
        .is_some_and(|id| id.is_str(project_id))
    {
        return Err(contract(
            "note index project_id does not match the artifact store",
        ));
    }
    let path = format!(".orchestrator/notes/{note_id}.md");
    if !value.get("path").is_some_and(|value| value.is_str(&path)) {
        return Err(contract("note index path disagrees with note_id"));
    }
    validate_timestamp(&value.string("created_at"), "note index created_at")?;
    validate_timestamp(&value.string("updated_at"), "note index updated_at")?;
    if !in_set(value.get("recording_state"), &NOTE_RECORDING_STATES)? {
        return Err(contract("note index recording_state is invalid"));
    }
    let count_valid = match value.get("segment_count") {
        Some(Value::Int(count)) => *count >= 0,
        Some(Value::BigInt(digits)) => !digits.starts_with('-'),
        _ => false,
    };
    if !count_valid {
        return Err(contract("note index segment_count is invalid"));
    }
    let Some(Value::Bool(materialized)) = value.get("materialized") else {
        return Err(contract("note index materialized must be Boolean"));
    };
    for key in ["creation_event_id", "last_event_id"] {
        if !is_safe_id(&value.string(key)) {
            return Err(contract(format!("note index {key} is invalid")));
        }
    }
    if !is_digest(&value.string("creation_request_sha256")) {
        return Err(contract("note index creation_request_sha256 is invalid"));
    }
    if !materialized {
        validate_timestamp(&value.string("archived_at"), "note index archived_at")?;
        if !is_object_id(&value.string("source_commit")) {
            return Err(contract("archived note source_commit is invalid"));
        }
        if !is_object_id(&value.string("source_blob")) {
            return Err(contract("archived note source_blob is invalid"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "---\nnote_schema_version: 1\nid: RR-N1\nartifact_id: note-0123456789\n\
        project_id: global-notes\ncreated_at: 2026-11-14T00:00:00Z\n\
        capture_started_at: 2026-11-14T00:00:00Z\nupdated_at: 2026-11-14T00:01:00Z\n\
        recording_state: recording\ncheckpoint_reason: checkpoint\nsegment_count: 1\n\
        note_metadata: {\"origin\": \"generated\", \"state\": \"pending\", \"error_code\": null}\n---\n\n\
        ## Transcript\n\n<!-- relay-note-segment {\"captured_at\":\"2026-11-14T00:00:30Z\",\
        \"end_ms\":1200,\"segment_id\":\"s1\",\"start_ms\":0} -->\nDéjà vu.\n";

    #[test]
    fn canonical_notes_render_back_unchanged() {
        let document = parse_note_document(NOTE.as_bytes()).unwrap();
        assert_eq!(document.update.segments[0].text, "Déjà vu.");
        assert_eq!(render_note_document(&document).unwrap(), NOTE.as_bytes());
    }

    #[test]
    fn rendering_normalises_spacing_and_order() {
        let loose = NOTE
            .replace(
                "{\"captured_at\":\"2026-11-14T00:00:30Z\",\"end_ms\":1200,",
                "{\"end_ms\": 1200, \"captured_at\": \"2026-11-14T00:00:30Z\", ",
            )
            .replace("Déjà vu.\n", "Déjà vu.   \n\n\n");
        let document = parse_note_document(loose.as_bytes()).unwrap();
        assert_eq!(render_note_document(&document).unwrap(), NOTE.as_bytes());
    }

    #[test]
    fn refuses_with_contract_messages() {
        let message = |text: &str| parse_note_document(text.as_bytes()).unwrap_err().message;
        assert_eq!(
            message(&NOTE.replace("segment_count: 1", "segment_count: 2")),
            "note segment_count does not match transcript segments"
        );
        assert_eq!(
            message(&NOTE.replace("\"pending\"", "\"ready\"")),
            "invalid note metadata"
        );
        assert_eq!(
            message(&NOTE.replace("id: RR-N1", "id: RR-N01")),
            "invalid unpadded note ID: 'RR-N01'"
        );
        assert_eq!(
            message(&NOTE.replace("updated_at: 2026-11-14T00:01:00Z", "updated_at: 2026-11-14")),
            "note captured_at must include a UTC offset"
        );
    }

    #[test]
    fn note_ids() {
        assert_eq!(validate_note_id("RR-N12").unwrap(), ("RR".to_string(), 12));
        assert_eq!(
            validate_note_id("A-B-N3").unwrap_err().kind,
            ErrorKind::NoteContract
        );
        for refused in ["RR-N0", "RR-N", "-N1", "RR-n1", "RR-N1x"] {
            assert!(validate_note_id(refused).is_err(), "{refused}");
        }
    }
}
