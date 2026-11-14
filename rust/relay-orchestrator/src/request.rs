//! One request as `Handler._route` sees it: `urlparse(path)`, the path
//! segments, `parse_qs(query)` and the JSON body `_read_body` returns.

use relay_intents::json::{self, Dict, Value};

use crate::failure::{Failure, Outcome};

pub struct Request {
    pub method: String,
    /// `urlparse(self.path).path`.
    pub path: String,
    /// `[s for s in path.split("/") if s]`, still percent-encoded.
    pub segments: Vec<String>,
    /// `parse_qs(query)`, in first-appearance order of each name.
    pub query: Vec<(String, Vec<String>)>,
    /// `_read_body(self)`: the body when it is a JSON object, else `{}`.
    pub body: Dict,
}

impl Request {
    /// `target` is the request line's path; `body` the bytes after the
    /// headers (`Content-Length` of them).
    pub fn new(method: &str, target: &str, body: &[u8]) -> Self {
        let (path, query) = split_target(target);
        let segments = path
            .split('/')
            .filter(|segment| !segment.is_empty())
            .map(str::to_string)
            .collect();
        Self {
            method: method.to_string(),
            segments,
            query: parse_qs(&query),
            body: read_body(body),
            path,
        }
    }

    /// The segments as `&str`, for matching.
    pub fn parts(&self) -> Vec<&str> {
        self.segments.iter().map(String::as_str).collect()
    }

    /// `unquote(segments[index])`.
    pub fn unquoted(&self, index: usize) -> String {
        unquote(&self.segments[index])
    }

    /// `(query.get(name) or [None])[0]`.
    pub fn query_first(&self, name: &str) -> Option<String> {
        self.query
            .iter()
            .find(|(key, _)| key == name)
            .and_then(|(_, values)| values.first().cloned())
    }

    /// `(query.get(name) or [default])[0]`.
    pub fn query_or(&self, name: &str, default: &str) -> String {
        self.query_first(name)
            .unwrap_or_else(|| default.to_string())
    }

    /// `query.get(name)`: every value, or `None`.
    pub fn query_all(&self, name: &str) -> Option<Vec<String>> {
        self.query
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, values)| values.clone())
    }

    /// `int((query.get(name) or [default])[0])`.
    pub fn query_int(&self, name: &str, default: i64) -> Outcome<i64> {
        match self.query_first(name) {
            None => Ok(default),
            Some(text) => parse_int(&text),
        }
    }

    /// `str((query.get(name) or ["false"])[0]).lower() in {"1", "true", "yes"}`.
    pub fn query_flag(&self, name: &str) -> bool {
        self.query_first(name)
            .is_some_and(|value| matches!(value.to_lowercase().as_str(), "1" | "true" | "yes"))
    }

    /// `body.get(key)`, `None` when absent.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.body.get(key)
    }

    /// `body.get(key, "")` as a string; Python passes the value through, so
    /// a non-string is rendered with `str()`.
    pub fn text(&self, key: &str) -> String {
        match self.body.get(key) {
            None | Some(Value::Null) => String::new(),
            Some(value) => value.py_str(),
        }
    }

    /// `body.get(key)` when it is truthy, rendered with `str()`.
    pub fn optional_text(&self, key: &str) -> Option<String> {
        match self.body.get(key) {
            None | Some(Value::Null) => None,
            Some(value) => Some(value.py_str()),
        }
    }

    /// `body.get(key) is True`.
    pub fn is_true(&self, key: &str) -> bool {
        matches!(self.body.get(key), Some(Value::Bool(true)))
    }

    /// `bool(body.get(key, default))`.
    pub fn truthy_or(&self, key: &str, default: bool) -> bool {
        self.body.get(key).map_or(default, Value::truthy)
    }
}

/// `int(text)`, with Python's message on failure.
pub fn parse_int(text: &str) -> Outcome<i64> {
    json::py_int_from_str(text).ok_or_else(|| Failure::int_literal(text))
}

/// `urlparse(target)`: the path (without `;params`) and the query.
fn split_target(target: &str) -> (String, String) {
    // `parse_request` collapses a leading `//` (gh-87389) before urlparse
    // could read the first segment as a host.
    let collapsed;
    let target = if target.starts_with("//") {
        collapsed = format!("/{}", target.trim_start_matches('/'));
        collapsed.as_str()
    } else {
        target
    };
    let without_fragment = target.split('#').next().unwrap_or_default();
    let (mut path, query) = match without_fragment.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (without_fragment.to_string(), String::new()),
    };
    // An absolute request target keeps only its path, as urlparse does.
    for scheme in ["http://", "https://"] {
        if let Some(rest) = path.strip_prefix(scheme) {
            path = rest
                .find('/')
                .map_or_else(String::new, |i| rest[i..].to_string());
        }
    }
    // `_splitparams`: `;params` after the last segment's start.
    let start = path.rfind('/').unwrap_or(0);
    if let Some(offset) = path[start..].find(';') {
        path.truncate(start + offset);
    }
    (path, query)
}

/// `parse_qs(query)`: blank values dropped, `+` as a space, then unquoted.
fn parse_qs(query: &str) -> Vec<(String, Vec<String>)> {
    let mut result: Vec<(String, Vec<String>)> = Vec::new();
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        let Some((name, value)) = pair.split_once('=') else {
            continue;
        };
        if value.is_empty() {
            continue;
        }
        let name = unquote(&name.replace('+', " "));
        let value = unquote(&value.replace('+', " "));
        match result.iter_mut().find(|(key, _)| *key == name) {
            Some((_, values)) => values.push(value),
            None => result.push((name, vec![value])),
        }
    }
    result
}

/// `urllib.parse.unquote`: percent escapes as UTF-8, invalid bytes replaced.
pub fn unquote(text: &str) -> String {
    if !text.contains('%') {
        return text.to_string();
    }
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let high = (bytes[index + 1] as char).to_digit(16);
            let low = (bytes[index + 2] as char).to_digit(16);
            if let (Some(high), Some(low)) = (high, low) {
                decoded.push((high * 16 + low) as u8);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// `_read_body`: a JSON object, or `{}` for anything else.
fn read_body(raw: &[u8]) -> Dict {
    if raw.is_empty() {
        return Dict::new();
    }
    match std::str::from_utf8(raw).ok().and_then(json::parse) {
        Some(Value::Dict(dict)) => dict,
        _ => Dict::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_path_drops_query_fragment_and_params() {
        let request = Request::new("GET", "/v1/runs/7;x?limit=2&state=&a=1&a=2#top", b"");
        assert_eq!(request.path, "/v1/runs/7");
        assert_eq!(request.parts(), ["v1", "runs", "7"]);
        assert_eq!(request.query_first("limit").as_deref(), Some("2"));
        assert_eq!(request.query_first("state"), None);
        assert_eq!(request.query_all("a").unwrap(), ["1", "2"]);
    }

    #[test]
    fn empty_segments_are_ignored_and_escapes_kept_until_unquoted() {
        let request = Request::new("GET", "//v1//artifacts/notes/a%20b", b"");
        assert_eq!(request.parts(), ["v1", "artifacts", "notes", "a%20b"]);
        assert_eq!(request.unquoted(3), "a b");
    }

    #[test]
    fn query_values_decode_plus_and_percent() {
        let request = Request::new("GET", "/x?query=a+b%2Bc&flag=YES", b"");
        assert_eq!(request.query_first("query").as_deref(), Some("a b+c"));
        assert!(request.query_flag("flag"));
        assert!(!request.query_flag("missing"));
    }

    #[test]
    fn a_body_that_is_not_an_object_reads_as_empty() {
        for raw in [&b"[1, 2]"[..], b"{not json", b"", b"\xff"] {
            assert!(Request::new("POST", "/v1/runs", raw).body.is_empty());
        }
        let request = Request::new("POST", "/v1/runs", br#"{"ticket_id": "CT-1"}"#);
        assert_eq!(request.text("ticket_id"), "CT-1");
    }

    #[test]
    fn integers_parse_as_python_int() {
        assert_eq!(parse_int(" 12 ").unwrap(), 12);
        assert_eq!(parse_int("1_0").unwrap(), 10);
        assert_eq!(
            parse_int("abc").unwrap_err().message,
            "invalid literal for int() with base 10: 'abc'"
        );
    }

    #[test]
    fn unquote_keeps_a_broken_escape() {
        assert_eq!(unquote("100%"), "100%");
        assert_eq!(unquote("%zz%41"), "%zzA");
        assert_eq!(unquote("%E2%9C%93"), "\u{2713}");
    }
}
