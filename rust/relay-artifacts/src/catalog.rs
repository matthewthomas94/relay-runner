//! `services/artifact_catalog.py`: the check that an archived ticket's
//! verified Markdown agrees with its archive catalog entry on everything
//! dependency progression relies on.

use relay_intents::json::{Dict, Value};

use crate::{Error, ErrorKind, Result, isotime, pystr};

pub const DEFAULT_ACTIVITY_FIELDS: [&str; 12] = [
    "activity_at",
    "user_edited_at",
    "pm_edited_at",
    "dependency_updated_at",
    "status_updated_at",
    "claimed_at",
    "run_outcome_at",
    "review_outcome_at",
    "merge_outcome_at",
    "attachment_updated_at",
    "restored_at",
    "reopened_at",
];

fn semantic(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::CatalogSemantic, message)
}

/// Front-matter fields in first-seen order, a repeated key keeping its last
/// value.
pub type FrontMatter = Vec<(String, String)>;

fn get<'f>(front: &'f FrontMatter, key: &str) -> Option<&'f str> {
    front
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_str())
}

/// `validate_catalog_ticket_metadata`: the parsed front matter, or the
/// first disagreement as a `CatalogSemanticError`.
pub fn validate_catalog_ticket_metadata(
    entry: &Dict,
    content: &[u8],
    activity_fields: &[&str],
) -> Result<FrontMatter> {
    let front = front_matter(content)?;
    let ticket_id = entry.string("ticket_id");
    let expected_path = format!(".orchestrator/{ticket_id}.md");
    if !entry
        .get("ticket_path")
        .is_some_and(|path| path.is_str(&expected_path))
    {
        return Err(semantic(
            "archive catalog ticket path disagrees with ticket ID",
        ));
    }
    require_equal("ticket ID", &ticket_id, get(&front, "id").unwrap_or(""))?;
    require_equal(
        "artifact ID",
        &entry.string("artifact_id"),
        get(&front, "artifact_id").unwrap_or(""),
    )?;
    let catalog_title = match entry.truthy("title") {
        Some(title) => title.py_str(),
        None => ticket_id.clone(),
    };
    require_equal(
        "title",
        &catalog_title,
        get(&front, "title").unwrap_or(&ticket_id),
    )?;
    require_equal(
        "status and canceled semantics",
        &canonical_status_value(&entry.string("status")),
        &canonical_status(&front),
    )?;
    let dependencies = match entry.get("dependencies") {
        None => Vec::new(),
        Some(Value::List(items)) => {
            let mut values = Vec::new();
            for item in items {
                match item.as_str() {
                    Some(text) if !pystr::strip(text).is_empty() => {
                        values.push(pystr::strip(text).to_string());
                    }
                    _ => return Err(semantic("archive catalog dependencies are invalid")),
                }
            }
            values
        }
        Some(_) => return Err(semantic("archive catalog dependencies are invalid")),
    };
    let mut catalog_dependencies = dependencies;
    catalog_dependencies.sort();
    let mut markdown_dependencies = parse_list(get(&front, "depends_on").unwrap_or("[]"));
    markdown_dependencies.sort();
    if catalog_dependencies != markdown_dependencies {
        return Err(disagrees("dependencies"));
    }
    let mut latest: Option<i64> = None;
    for field in activity_fields {
        if let Some(value) = get(&front, field).filter(|value| !value.is_empty()) {
            let instant = parse_instant(value)?;
            latest = Some(latest.map_or(instant, |current| current.max(instant)));
        }
    }
    let Some(latest) = latest else {
        return Err(semantic(
            "historical ticket has no durable activity timestamp",
        ));
    };
    if parse_instant(&entry.string("activity_at"))? != latest {
        return Err(disagrees("activity timestamp"));
    }
    Ok(front)
}

fn front_matter(content: &[u8]) -> Result<FrontMatter> {
    let text = std::str::from_utf8(content)
        .map_err(|_| semantic("historical ticket front matter is not UTF-8"))?;
    let lines = pystr::splitlines(text);
    if lines.is_empty() || pystr::strip(lines[0]) != "---" {
        return Err(semantic("historical ticket has no front matter"));
    }
    let mut result: FrontMatter = Vec::new();
    for line in &lines[1..] {
        if pystr::strip(line) == "---" {
            return Ok(result);
        }
        let (key, found, value) = pystr::partition(line, ":");
        if found {
            let key = pystr::strip(key).to_string();
            let value = pystr::strip_quotes(pystr::strip(value)).to_string();
            match result.iter_mut().find(|(name, _)| *name == key) {
                Some(entry) => entry.1 = value,
                None => result.push((key, value)),
            }
        }
    }
    Err(semantic("historical ticket front matter is not closed"))
}

/// `_parse_list`, which reads a bracketless list too.
fn parse_list(value: &str) -> Vec<String> {
    let mut stripped = pystr::strip(value);
    if stripped.is_empty() || stripped == "[]" {
        return Vec::new();
    }
    if let Some(inner) = stripped
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
    {
        stripped = inner;
    }
    stripped
        .split(',')
        .map(|item| pystr::strip_quotes(pystr::strip(item)))
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

fn canonical_status(front: &FrontMatter) -> String {
    let canceled = pystr::strip(get(front, "canceled").unwrap_or("false")).to_lowercase();
    if matches!(canceled.as_str(), "true" | "yes" | "1") {
        return "canceled".to_string();
    }
    canonical_status_value(get(front, "status").unwrap_or("backlog"))
}

fn canonical_status_value(value: &str) -> String {
    let normalized = pystr::strip(value).to_lowercase();
    if normalized == "cancelled" {
        "canceled".to_string()
    } else {
        normalized
    }
}

/// `_parse_instant`: microseconds since 0001-01-01T00:00:00Z.
fn parse_instant(value: &str) -> Result<i64> {
    let parsed = isotime::fromisoformat(&value.replace('Z', "+00:00")).map_err(|_| {
        semantic(format!(
            "invalid historical activity timestamp: {}",
            pystr::repr(value)
        ))
    })?;
    match parsed.utc_micros() {
        None => Err(semantic(format!(
            "historical activity timestamp has no UTC offset: {}",
            pystr::repr(value)
        ))),
        Some(instant) => instant,
    }
}

fn disagrees(label: &str) -> Error {
    semantic(format!(
        "archive catalog {label} disagrees with verified historical Markdown"
    ))
}

fn require_equal(label: &str, catalog: &str, markdown: &str) -> Result<()> {
    if catalog == markdown {
        Ok(())
    } else {
        Err(disagrees(label))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use relay_intents::json;

    const TICKET: &[u8] = b"---\nid: RR-7\nartifact_id: ticket-77777777\ntitle: \"Seven\"\n\
        status: done\ncanceled: false\ndepends_on: [RR-2, RR-1]\nactivity_at: 2026-11-14T00:00:00Z\n\
        merge_outcome_at: 2026-11-14T01:00:00+01:00\n---\nBody\n";

    fn entry(extra: &str) -> Dict {
        let text = format!(
            "{{\"ticket_id\": \"RR-7\", \"ticket_path\": \".orchestrator/RR-7.md\", \
             \"artifact_id\": \"ticket-77777777\", \"title\": \"Seven\", \"status\": \"done\", \
             \"dependencies\": [\"RR-1\", \" RR-2 \"], \"activity_at\": \"2026-11-14T00:00:00.000000+00:00\"{extra}}}"
        );
        json::parse(&text).unwrap().as_dict().unwrap().clone()
    }

    #[test]
    fn agreeing_entries_pass() {
        let front =
            validate_catalog_ticket_metadata(&entry(""), TICKET, &DEFAULT_ACTIVITY_FIELDS).unwrap();
        assert_eq!(get(&front, "title"), Some("Seven"));
    }

    #[test]
    fn disagreements_name_the_field() {
        let message = |extra: &str| {
            validate_catalog_ticket_metadata(&entry(extra), TICKET, &DEFAULT_ACTIVITY_FIELDS)
                .unwrap_err()
                .message
        };
        assert_eq!(
            message(", \"status\": \"canceled\""),
            "archive catalog status and canceled semantics disagrees with verified historical Markdown"
        );
        assert_eq!(
            message(", \"dependencies\": [\"RR-1\"]"),
            "archive catalog dependencies disagrees with verified historical Markdown"
        );
        assert_eq!(
            message(", \"activity_at\": \"2026-11-14T00:00:01Z\""),
            "archive catalog activity timestamp disagrees with verified historical Markdown"
        );
        assert_eq!(
            message(", \"activity_at\": \"2026-11-14T00:00:00\""),
            "historical activity timestamp has no UTC offset: '2026-11-14T00:00:00'"
        );
        assert_eq!(
            message(", \"dependencies\": [\"\"]"),
            "archive catalog dependencies are invalid"
        );
    }
}
