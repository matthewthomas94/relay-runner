//! `.orchestrator/<id>.md` ticket files, as `services/tickets.py` reads and
//! writes them.
//!
//! `parse` is Python's `tickets.parse`: the same field rules and the same
//! `TicketParseError` messages. `render` is the file `tickets.write`
//! produces, which normalises the front matter (field order, quotes, a
//! default `order`), so it is not a round trip. `TicketDocument` is: it keeps
//! every line `parse` splits off, so `serialise` gives back the file byte for
//! byte while `ticket()` gives the validated fields.

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::pystr::{self, repr, strip};
use crate::{Error, ErrorKind, Result};

pub const VALID_STATUSES: [&str; 5] = [
    "backlog",
    "ready",
    "in_progress",
    "verification_blocked",
    "done",
];
pub const VALID_PRIORITIES: [&str; 4] = ["urgent", "high", "medium", "low"];
pub const VALID_EXECUTION_MODES: [&str; 2] = ["implementation", "spike"];
pub const VALID_VERIFICATION_ORIGINS: [&str; 1] = ["inline"];

/// The front-matter keys `tickets.write` emits first, in this order; it
/// matches the Swift writer (`Sources/relay-runner/Board/TicketWriter.swift`).
pub const FIELD_ORDER: [&str; 12] = [
    "id",
    "title",
    "status",
    "priority",
    "execution_mode",
    "depends_on",
    "run_id",
    "canceled",
    "verification_blocker",
    "verification_resume",
    "verification_origin",
    "order",
];

fn parse_error(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::TicketParse, message)
}

/// Front-matter values by key, in first-seen order; a repeated key keeps its
/// first position and its last value, as a Python `dict` does.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fields {
    entries: Vec<(String, String)>,
}

impl Fields {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.as_str())
    }

    pub fn insert(&mut self, key: &str, value: &str) {
        match self.entries.iter_mut().find(|(name, _)| name == key) {
            Some(entry) => entry.1 = value.to_string(),
            None => self.entries.push((key.to_string(), value.to_string())),
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.entries
            .iter()
            .map(|(name, value)| (name.as_str(), value.as_str()))
    }
}

/// A validated ticket: the structured values `tickets.parse` returns, with
/// every raw field in `raw_fields`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub id: String,
    pub title: String,
    pub status: String,
    pub priority: String,
    pub execution_mode: String,
    pub depends_on: Vec<String>,
    pub run_id: Option<i64>,
    pub canceled: bool,
    pub draft: bool,
    pub verification_blocker: Option<String>,
    pub verification_resume: Option<String>,
    pub verification_origin: Option<String>,
    pub order: i64,
    pub body: String,
    pub raw_fields: Fields,
}

/// `_strip_quotes`: one matching pair of quotes around the whole value.
fn strip_quote_pair(text: &str) -> &str {
    let mut characters = text.chars();
    match (characters.next(), characters.next_back()) {
        (Some(first @ ('"' | '\'')), Some(last)) if first == last => &text[1..text.len() - 1],
        _ => text,
    }
}

/// `_parse_list`: a bracketed, comma-separated list of ids.
pub fn parse_list(raw: &str) -> Vec<String> {
    let Some(inner) = raw
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
    else {
        return Vec::new();
    };
    strip(inner)
        .split(',')
        .filter(|part| !strip(part).is_empty())
        .map(|part| strip_quote_pair(strip(part)).to_string())
        .collect()
}

/// `_format_list`.
pub fn format_list(items: &[String]) -> String {
    if items.is_empty() {
        "[]".to_string()
    } else {
        format!("[{}]", items.join(", "))
    }
}

/// A ticket file split the way `tickets.parse` splits it, keeping every line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TicketDocument {
    opening: String,
    front_matter: Vec<String>,
    closing: String,
    /// The text after the closing line, or `None` when the file ends on it
    /// without a newline. `tickets.parse` reads both as an empty body.
    body: Option<String>,
}

impl TicketDocument {
    /// `_split_frontmatter`: lines split on `\n` only, the first and the next
    /// line whose stripped text is `---` delimiting the front matter.
    pub fn parse(contents: &str) -> Result<Self> {
        let lines: Vec<&str> = contents.split('\n').collect();
        if strip(lines[0]) != "---" {
            return Err(parse_error("missing opening --- frontmatter delimiter"));
        }
        let closing = lines[1..]
            .iter()
            .position(|line| strip(line) == "---")
            .map(|index| index + 1)
            .ok_or_else(|| parse_error("missing closing --- frontmatter delimiter"))?;
        Ok(Self {
            opening: lines[0].to_string(),
            front_matter: lines[1..closing]
                .iter()
                .map(|line| line.to_string())
                .collect(),
            closing: lines[closing].to_string(),
            body: (closing + 1 < lines.len()).then(|| lines[closing + 1..].join("\n")),
        })
    }

    /// The file this document was parsed from, byte for byte.
    pub fn serialise(&self) -> String {
        let mut text = self.opening.clone();
        for line in &self.front_matter {
            text.push('\n');
            text.push_str(line);
        }
        text.push('\n');
        text.push_str(&self.closing);
        if let Some(body) = &self.body {
            text.push('\n');
            text.push_str(body);
        }
        text
    }

    /// `_parse_frontmatter`.
    pub fn fields(&self) -> Fields {
        let mut fields = Fields::default();
        for line in &self.front_matter {
            let stripped = strip(line);
            if stripped.is_empty() || stripped.starts_with('#') {
                continue;
            }
            let (key, found, value) = pystr::partition(stripped, ":");
            if found {
                fields.insert(strip(key), strip_quote_pair(strip(value)));
            }
        }
        fields
    }

    /// The body `tickets.parse` returns.
    pub fn body(&self) -> &str {
        self.body.as_deref().unwrap_or("")
    }

    /// `tickets.parse`'s validation of the fields.
    pub fn ticket(&self) -> Result<Ticket> {
        let raw = self.fields();
        let require = |key: &str| {
            raw.get(key)
                .map(str::to_string)
                .ok_or_else(|| parse_error(format!("missing required field: {key}")))
        };
        let status = require("status")?;
        if !VALID_STATUSES.contains(&status.as_str()) {
            return Err(parse_error(format!("invalid status: {}", repr(&status))));
        }
        let priority = require("priority")?;
        if !VALID_PRIORITIES.contains(&priority.as_str()) {
            return Err(parse_error(format!(
                "invalid priority: {}",
                repr(&priority)
            )));
        }
        let execution_mode =
            strip(raw.get("execution_mode").unwrap_or("implementation")).to_lowercase();
        if !VALID_EXECUTION_MODES.contains(&execution_mode.as_str()) {
            return Err(parse_error(format!(
                "invalid execution_mode: {}",
                repr(&execution_mode)
            )));
        }
        let canceled = match require("canceled")?.to_lowercase().as_str() {
            "true" => true,
            "false" => false,
            other => return Err(parse_error(format!("invalid canceled: {}", repr(other)))),
        };
        let draft = match raw.get("draft").unwrap_or("false").to_lowercase().as_str() {
            "true" => true,
            "false" => false,
            other => return Err(parse_error(format!("invalid draft: {}", repr(other)))),
        };
        let run_id_raw = require("run_id")?;
        let run_id = match run_id_raw.to_lowercase().as_str() {
            "null" | "" => None,
            _ => Some(
                pystr::int(&run_id_raw)
                    .ok_or_else(|| parse_error(format!("invalid run_id: {}", repr(&run_id_raw))))?,
            ),
        };
        let optional = |key: &str| {
            let value = strip(raw.get(key).unwrap_or(""));
            (!value.is_empty()).then(|| value.to_string())
        };
        let verification_blocker = optional("verification_blocker");
        let verification_resume = optional("verification_resume");
        let verification_origin = optional("verification_origin").map(|value| value.to_lowercase());
        if let Some(origin) = &verification_origin
            && !VALID_VERIFICATION_ORIGINS.contains(&origin.as_str())
        {
            return Err(parse_error(format!(
                "invalid verification_origin: {}",
                repr(origin)
            )));
        }
        if status == "verification_blocked" {
            if run_id.is_none() && verification_origin.as_deref() != Some("inline") {
                return Err(parse_error("verification_blocked ticket requires run_id"));
            }
            if verification_blocker.is_none() {
                return Err(parse_error("missing required field: verification_blocker"));
            }
            if verification_resume.is_none() {
                return Err(parse_error("missing required field: verification_resume"));
            }
        }
        let id = require("id")?;
        let title = require("title")?;
        let depends_on = parse_list(&require("depends_on")?);
        // `int(raw.get("order", "0") or "0")` raises a plain ValueError.
        let order_raw = match raw.get("order") {
            Some("") | None => "0",
            Some(value) => value,
        };
        let order = pystr::int(order_raw).ok_or_else(|| {
            Error::value(format!(
                "invalid literal for int() with base 10: {}",
                repr(order_raw)
            ))
        })?;
        Ok(Ticket {
            id,
            title,
            status,
            priority,
            execution_mode,
            depends_on,
            run_id,
            canceled,
            draft,
            verification_blocker,
            verification_resume,
            verification_origin,
            order,
            body: self.body().to_string(),
            raw_fields: raw,
        })
    }
}

/// `tickets.parse(contents)`.
pub fn parse(contents: &str) -> Result<Ticket> {
    TicketDocument::parse(contents)?.ticket()
}

/// `tickets.read(path)`: the file as `read_text` gives it, so with
/// universal newlines.
pub fn read(path: &Path) -> Result<Ticket> {
    let bytes = fs::read(path)?;
    parse(&pystr::universal_newlines(pystr::decode_utf8(&bytes)?))
}

/// The text `tickets.write` writes for `ticket`.
pub fn render(ticket: &Ticket) -> String {
    let mut lines = vec!["---".to_string()];
    let mut field = |key: &str, value: Option<String>| {
        if let Some(value) = value {
            lines.push(format!("{key}: {value}"));
        }
    };
    field("id", Some(ticket.id.clone()));
    field("title", Some(ticket.title.clone()));
    field("status", Some(ticket.status.clone()));
    field("priority", Some(ticket.priority.clone()));
    field("execution_mode", Some(ticket.execution_mode.clone()));
    field("depends_on", Some(format_list(&ticket.depends_on)));
    field(
        "run_id",
        Some(
            ticket
                .run_id
                .map_or("null".to_string(), |id| id.to_string()),
        ),
    );
    field("canceled", Some(ticket.canceled.to_string()));
    field("verification_blocker", ticket.verification_blocker.clone());
    field("verification_resume", ticket.verification_resume.clone());
    field("verification_origin", ticket.verification_origin.clone());
    field("order", Some(ticket.order.to_string()));
    for (key, value) in ticket.raw_fields.iter() {
        if !FIELD_ORDER.contains(&key) {
            lines.push(format!("{key}: {value}"));
        }
    }
    lines.push("---".to_string());
    let mut output = lines.join("\n") + "\n" + &ticket.body;
    if !output.ends_with('\n') {
        output.push('\n');
    }
    output
}

/// `tickets.write(path, ticket)`: written to `<path>.tmp`, then renamed.
pub fn write(path: &Path, ticket: &Ticket) -> Result<()> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    fs::write(&temporary, render(ticket))?;
    fs::rename(&temporary, path)?;
    Ok(())
}

type Identity = (u64, u64, i64, i64, i64, i64);

/// Parsed tickets per board, keyed by each file's stat identity, so the
/// frequent ready sweeps parse only changed files (RR-440).
type BoardCache = HashMap<String, (Identity, Ticket)>;

static SCAN_CACHE: Mutex<Vec<(PathBuf, BoardCache)>> = Mutex::new(Vec::new());
const SCAN_CACHE_DIRECTORIES: usize = 32;

fn identity(path: &Path) -> std::io::Result<Identity> {
    let metadata = fs::metadata(path)?;
    Ok((
        metadata.ino(),
        metadata.size(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    ))
}

/// `tickets.scan_repo`: every parseable `<repo>/.orchestrator/*.md`, sorted
/// by path. Unreadable files and `TicketParseError`s are skipped; any other
/// error (an `order` that is not an integer) propagates, as in Python.
pub fn scan_repo(repo_path: &Path) -> Result<Vec<(PathBuf, Ticket)>> {
    let directory = repo_path.join(".orchestrator");
    if !directory.is_dir() {
        return Ok(Vec::new());
    }
    let cached = {
        let cache = SCAN_CACHE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        cache
            .iter()
            .find(|(path, _)| *path == directory)
            .map(|(_, files)| files.clone())
            .unwrap_or_default()
    };
    let mut paths: Vec<PathBuf> = fs::read_dir(&directory)?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".md"))
        })
        .collect();
    paths.sort();
    let mut parsed = HashMap::new();
    let mut tickets = Vec::new();
    for path in paths {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_string();
        let Ok(before) = identity(&path) else {
            continue;
        };
        let ticket = match cached.get(&name) {
            Some((recorded, ticket)) if *recorded == before => ticket.clone(),
            _ => match read(&path) {
                Ok(ticket) => ticket,
                Err(error) if matches!(error.kind, ErrorKind::Io | ErrorKind::TicketParse) => {
                    continue;
                }
                // A file that is not UTF-8 fails `read_text` with a
                // UnicodeDecodeError, which is a ValueError too.
                Err(error) => return Err(error),
            },
        };
        // A file rewritten while it was read is parsed again next scan.
        if identity(&path).ok() == Some(before) {
            parsed.insert(name, (before, ticket.clone()));
        }
        tickets.push((path, ticket));
    }
    let mut cache = SCAN_CACHE
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    cache.retain(|(path, _)| *path != directory);
    if cache.len() >= SCAN_CACHE_DIRECTORIES {
        cache.remove(0);
    }
    cache.push((directory, parsed));
    Ok(tickets)
}

/// `tickets.find_dependents`.
pub fn find_dependents(repo_path: &Path, ticket_id: &str) -> Result<Vec<(PathBuf, Ticket)>> {
    Ok(scan_repo(repo_path)?
        .into_iter()
        .filter(|(_, ticket)| ticket.depends_on.iter().any(|id| id == ticket_id))
        .collect())
}

/// `tickets.all_deps_done`: every dependency resolves to a `done` ticket.
/// A repeated id resolves to the last ticket with it, as Python's dict does.
pub fn all_deps_done(ticket: &Ticket, all_tickets: &[Ticket]) -> bool {
    let by_id: HashMap<&str, &Ticket> = all_tickets
        .iter()
        .map(|ticket| (ticket.id.as_str(), ticket))
        .collect();
    ticket.depends_on.iter().all(|dependency| {
        by_id
            .get(dependency.as_str())
            .is_some_and(|found| found.status == "done")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TICKET: &str = "---\nid: RR-1\nartifact_id: ticket-abc12345\ntitle: \"Quoted: title\"\n\
        status: backlog\npriority: low\ndepends_on: [RR-2, 'RR-3']\nrun_id: null\ncanceled: false\n\
        # comment: ignored\n---\n\n## Description\n\nBody.\n";

    #[test]
    fn parses_like_python() {
        let ticket = parse(TICKET).unwrap();
        assert_eq!(ticket.title, "Quoted: title");
        assert_eq!(ticket.depends_on, ["RR-2", "RR-3"]);
        assert_eq!(ticket.run_id, None);
        assert_eq!(ticket.execution_mode, "implementation");
        assert_eq!(ticket.order, 0);
        assert_eq!(ticket.body, "\n## Description\n\nBody.\n");
        assert_eq!(
            ticket.raw_fields.get("artifact_id"),
            Some("ticket-abc12345")
        );
        assert_eq!(ticket.raw_fields.get("# comment"), None);
    }

    #[test]
    fn documents_round_trip_byte_for_byte() {
        for text in [
            TICKET,
            "---\nid: X\n---",
            "---\nid: X\n---\n",
            " --- \r\nid: X\r\n---\r\nbody\r\n",
            "---\n---\n\n\n",
        ] {
            assert_eq!(TicketDocument::parse(text).unwrap().serialise(), text);
        }
    }

    #[test]
    fn renders_what_tickets_write_writes() {
        let ticket = parse(TICKET).unwrap();
        assert_eq!(
            render(&ticket),
            "---\nid: RR-1\ntitle: Quoted: title\nstatus: backlog\npriority: low\n\
             execution_mode: implementation\ndepends_on: [RR-2, RR-3]\nrun_id: null\n\
             canceled: false\norder: 0\nartifact_id: ticket-abc12345\n---\n\n## Description\n\nBody.\n"
        );
    }

    #[test]
    fn refuses_with_python_messages() {
        let message = |text: &str| parse(text).unwrap_err().message;
        assert_eq!(
            message("id: X\n"),
            "missing opening --- frontmatter delimiter"
        );
        assert_eq!(
            message("---\nid: X\n"),
            "missing closing --- frontmatter delimiter"
        );
        assert_eq!(
            message("---\nid: X\n---\n"),
            "missing required field: status"
        );
        assert_eq!(
            message("---\nstatus: open\n---\n"),
            "invalid status: 'open'"
        );
        assert_eq!(
            message("---\nstatus: done\npriority: low\ncanceled: no\n---\n"),
            "invalid canceled: 'no'"
        );
        assert_eq!(
            message(
                "---\nstatus: verification_blocked\npriority: low\ncanceled: false\nrun_id: 5\n---\n"
            ),
            "missing required field: verification_blocker"
        );
        let order = parse(
            "---\nid: X\ntitle: T\nstatus: done\npriority: low\ncanceled: false\nrun_id: 1\n\
             depends_on: []\norder: x\n---\n",
        )
        .unwrap_err();
        assert_eq!(order.kind, ErrorKind::Value);
    }
}
