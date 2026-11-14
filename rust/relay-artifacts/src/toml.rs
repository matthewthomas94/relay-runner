//! Python's `tomllib.loads`, ported from CPython 3.14's `Lib/tomllib`.
//!
//! The artifact store refuses a commit whose `config.toml` `tomllib` refuses,
//! and the app configuration is read with it, so this parser accepts exactly
//! TOML 1.0 as `tomllib` reads it (no TOML 1.1 extensions), keeps key order
//! like a Python `dict`, and raises `TOMLDecodeError` with the same message
//! and position. Source: python/cpython@5607950ef232dad16d75c0cf53101d9649d89115
//! (v3.14.5) `Lib/tomllib/_parser.py` and `_re.py`.

use std::collections::HashMap;
use std::fmt::Write as _;

use crate::{Error, ErrorKind, Result};

/// A parsed TOML value. Arrays of tables and inline arrays are both
/// `Array`, as both are Python lists.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    String(String),
    Integer(i64),
    /// An integer outside `i64`, as its decimal digits with a leading `-`
    /// when negative. Python keeps it exactly.
    BigInteger(String),
    Float(f64),
    Boolean(bool),
    Datetime(Datetime),
    Array(Vec<Value>),
    Table(Table),
}

/// A TOML date, time or datetime, as `datetime.date`, `time` or `datetime`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Datetime {
    pub date: Option<(i32, u32, u32)>,
    /// Hour, minute, second and microsecond.
    pub time: Option<(u32, u32, u32, u32)>,
    /// The UTC offset in minutes; `Some(0)` for `Z`.
    pub offset_minutes: Option<i32>,
}

/// A table that keeps insertion order, like the `dict` `tomllib` returns.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table {
    entries: Vec<(String, Value)>,
}

impl Table {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut Value> {
        self.entries
            .iter_mut()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// `table[key] = value`: a new key goes last, an existing one keeps its
    /// place.
    pub fn insert(&mut self, key: &str, value: Value) {
        match self.get_mut(key) {
            Some(existing) => *existing = value,
            None => self.entries.push((key.to_string(), value)),
        }
    }

    /// `table.pop(key, None)`.
    pub fn remove(&mut self, key: &str) -> Option<Value> {
        let position = self.entries.iter().position(|(name, _)| name == key)?;
        Some(self.entries.remove(position).1)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries
            .iter()
            .map(|(name, value)| (name.as_str(), value))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_table(&self) -> Option<&Table> {
        match self {
            Value::Table(table) => Some(table),
            _ => None,
        }
    }

    /// Python's `value == number` for a small integer: `bool`, `int` and
    /// `float` all compare by value.
    pub fn equals_int(&self, number: i64) -> bool {
        match self {
            Value::Integer(value) => *value == number,
            Value::Boolean(value) => i64::from(*value) == number,
            Value::Float(value) => *value == number as f64,
            _ => false,
        }
    }

    /// Python's `bool(value)`.
    pub fn truthy(&self) -> bool {
        match self {
            Value::String(text) => !text.is_empty(),
            Value::Integer(value) => *value != 0,
            Value::BigInteger(_) => true,
            Value::Float(value) => *value != 0.0,
            Value::Boolean(value) => *value,
            // `time(0, 0)` is truthy since Python 3.5, as are all dates.
            Value::Datetime(_) => true,
            Value::Array(items) => !items.is_empty(),
            Value::Table(table) => !table.is_empty(),
        }
    }

    /// Python's `str(value)`.
    pub fn py_str(&self) -> String {
        match self {
            Value::String(text) => text.clone(),
            Value::Datetime(value) => value.py_str(),
            other => other.py_repr(),
        }
    }

    /// Python's `repr(value)`.
    pub fn py_repr(&self) -> String {
        match self {
            Value::String(text) => crate::pystr::repr(text),
            Value::Integer(value) => value.to_string(),
            Value::BigInteger(digits) => digits.clone(),
            Value::Float(value) => relay_intents::json::float_repr(*value),
            Value::Boolean(true) => "True".to_string(),
            Value::Boolean(false) => "False".to_string(),
            Value::Datetime(value) => value.py_repr(),
            Value::Array(items) => {
                let parts: Vec<String> = items.iter().map(Value::py_repr).collect();
                format!("[{}]", parts.join(", "))
            }
            Value::Table(table) => {
                let parts: Vec<String> = table
                    .iter()
                    .map(|(key, value)| format!("{}: {}", crate::pystr::repr(key), value.py_repr()))
                    .collect();
                format!("{{{}}}", parts.join(", "))
            }
        }
    }
}

impl Datetime {
    fn offset_str(&self) -> Option<String> {
        let minutes = self.offset_minutes?;
        let sign = if minutes < 0 { '-' } else { '+' };
        let minutes = minutes.unsigned_abs();
        Some(format!("{sign}{:02}:{:02}", minutes / 60, minutes % 60))
    }

    fn time_str(time: (u32, u32, u32, u32)) -> String {
        let (hour, minute, second, micro) = time;
        let mut text = format!("{hour:02}:{minute:02}:{second:02}");
        if micro != 0 {
            let _ = write!(text, ".{micro:06}");
        }
        text
    }

    /// `str()` of the `date`, `time` or `datetime`.
    pub fn py_str(&self) -> String {
        match (self.date, self.time) {
            (Some((year, month, day)), None) => format!("{year:04}-{month:02}-{day:02}"),
            (None, Some(time)) => Self::time_str(time),
            (Some((year, month, day)), Some(time)) => format!(
                "{year:04}-{month:02}-{day:02} {}{}",
                Self::time_str(time),
                self.offset_str().unwrap_or_default()
            ),
            (None, None) => String::new(),
        }
    }

    /// `repr()` of the `date`, `time` or `datetime`.
    pub fn py_repr(&self) -> String {
        fn clock(parts: &mut Vec<String>, (hour, minute, second, micro): (u32, u32, u32, u32)) {
            parts.push(hour.to_string());
            parts.push(minute.to_string());
            if second != 0 || micro != 0 {
                parts.push(second.to_string());
            }
            if micro != 0 {
                parts.push(micro.to_string());
            }
        }
        let mut parts = Vec::new();
        let name = match (self.date, self.time) {
            (Some((year, month, day)), time) => {
                parts.extend([year.to_string(), month.to_string(), day.to_string()]);
                if let Some(time) = time {
                    clock(&mut parts, time);
                    "datetime.datetime"
                } else {
                    "datetime.date"
                }
            }
            (None, time) => {
                clock(&mut parts, time.unwrap_or_default());
                "datetime.time"
            }
        };
        if let Some(minutes) = self.offset_minutes {
            parts.push(if minutes == 0 {
                "tzinfo=datetime.timezone.utc".to_string()
            } else {
                let seconds = i64::from(minutes) * 60;
                let delta = if seconds < 0 {
                    format!("days=-1, seconds={}", 86_400 + seconds)
                } else {
                    format!("seconds={seconds}")
                };
                format!("tzinfo=datetime.timezone(datetime.timedelta({delta}))")
            });
        }
        format!("{name}({})", parts.join(", "))
    }
}

/// `tomllib.loads(text)`.
pub fn loads(text: &str) -> Result<Table> {
    let source: Vec<char> = text.replace("\r\n", "\n").chars().collect();
    Parser {
        src: &source,
        out: Output::default(),
    }
    .document()
}

/// `tomllib.loads(content.decode("utf-8"))`: a decode failure is
/// `UnicodeDecodeError`, a `ValueError`.
pub fn loads_bytes(content: &[u8]) -> Result<Table> {
    loads(crate::pystr::decode_utf8(content)?)
}

type Key = Vec<String>;

const FROZEN: u8 = 1;
const EXPLICIT_NEST: u8 = 2;

#[derive(Default)]
struct FlagNode {
    flags: u8,
    recursive_flags: u8,
    nested: HashMap<String, FlagNode>,
}

#[derive(Default)]
struct Flags {
    root: HashMap<String, FlagNode>,
    pending: Vec<(Key, u8)>,
}

impl Flags {
    fn add_pending(&mut self, key: Key, flag: u8) {
        if !self.pending.iter().any(|(k, f)| *k == key && *f == flag) {
            self.pending.push((key, flag));
        }
    }

    fn finalize_pending(&mut self) {
        for (key, flag) in std::mem::take(&mut self.pending) {
            self.set(&key, flag, false);
        }
    }

    fn unset_all(&mut self, key: &[String]) {
        let mut container = &mut self.root;
        for part in &key[..key.len() - 1] {
            match container.get_mut(part) {
                Some(node) => container = &mut node.nested,
                None => return,
            }
        }
        container.remove(&key[key.len() - 1]);
    }

    fn set(&mut self, key: &[String], flag: u8, recursive: bool) {
        let mut container = &mut self.root;
        for part in &key[..key.len() - 1] {
            container = &mut container.entry(part.clone()).or_default().nested;
        }
        let node = container.entry(key[key.len() - 1].clone()).or_default();
        if recursive {
            node.recursive_flags |= flag;
        } else {
            node.flags |= flag;
        }
    }

    fn is(&self, key: &[String], flag: u8) -> bool {
        let Some((stem, parents)) = key.split_last() else {
            return false;
        };
        let mut container = &self.root;
        for part in parents {
            let Some(inner) = container.get(part) else {
                return false;
            };
            if inner.recursive_flags & flag != 0 {
                return true;
            }
            container = &inner.nested;
        }
        container
            .get(stem)
            .is_some_and(|node| (node.flags | node.recursive_flags) & flag != 0)
    }
}

/// `NestedDict.get_or_create_nest`; `None` is its `KeyError`.
fn nest<'t>(root: &'t mut Table, key: &[String], access_lists: bool) -> Option<&'t mut Table> {
    let mut container = root;
    for part in key {
        if !container.contains_key(part) {
            container.insert(part, Value::Table(Table::new()));
        }
        let value = if access_lists && matches!(container.get(part), Some(Value::Array(_))) {
            let Some(Value::Array(items)) = container.get_mut(part) else {
                return None;
            };
            items.last_mut()?
        } else {
            container.get_mut(part)?
        };
        container = match value {
            Value::Table(table) => table,
            _ => return None,
        };
    }
    Some(container)
}

#[derive(Default)]
struct Output {
    data: Table,
    flags: Flags,
}

struct Parser<'s> {
    src: &'s [char],
    out: Output,
}

const TOML_WS: &[char] = &[' ', '\t'];
const TOML_WS_AND_NEWLINE: &[char] = &[' ', '\t', '\n'];

fn is_bare_key_char(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '-' || character == '_'
}

fn is_ascii_ctrl(character: char) -> bool {
    (character as u32) < 32 || character == '\u{7f}'
}

/// `ILLEGAL_BASIC_STR_CHARS`, also the literal-string and comment set.
fn illegal_basic(character: char) -> bool {
    is_ascii_ctrl(character) && character != '\t'
}

/// `ILLEGAL_MULTILINE_BASIC_STR_CHARS`, also the multiline literal set.
fn illegal_multiline(character: char) -> bool {
    is_ascii_ctrl(character) && character != '\t' && character != '\n'
}

fn key_repr(key: &[String]) -> String {
    let parts: Vec<String> = key.iter().map(|part| crate::pystr::repr(part)).collect();
    if parts.len() == 1 {
        format!("({},)", parts[0])
    } else {
        format!("({})", parts.join(", "))
    }
}

fn char_repr(character: char) -> String {
    crate::pystr::repr(&character.to_string())
}

impl Parser<'_> {
    fn error(&self, message: impl Into<String>, position: usize) -> Error {
        let message = message.into();
        let coordinates = if position >= self.src.len() {
            "end of document".to_string()
        } else {
            let before = &self.src[..position];
            let line = before.iter().filter(|c| **c == '\n').count() + 1;
            let column = if line == 1 {
                position + 1
            } else {
                position - before.iter().rposition(|c| *c == '\n').unwrap_or(0)
            };
            format!("line {line}, column {column}")
        };
        Error::new(
            ErrorKind::TomlDecode,
            format!("{message} (at {coordinates})"),
        )
    }

    fn char_at(&self, position: usize) -> Option<char> {
        self.src.get(position).copied()
    }

    fn starts_with(&self, position: usize, text: &str) -> bool {
        let mut index = position;
        for character in text.chars() {
            if self.char_at(index) != Some(character) {
                return false;
            }
            index += 1;
        }
        true
    }

    fn skip_chars(&self, mut position: usize, chars: &[char]) -> usize {
        while self.char_at(position).is_some_and(|c| chars.contains(&c)) {
            position += 1;
        }
        position
    }

    fn skip_until(
        &self,
        position: usize,
        expect: &str,
        error_on: fn(char) -> bool,
        error_on_eof: bool,
    ) -> Result<usize> {
        let expected: Vec<char> = expect.chars().collect();
        let found =
            (position..self.src.len()).find(|index| self.src[*index..].starts_with(&expected));
        let end = match found {
            Some(index) => index,
            None => {
                if error_on_eof {
                    return Err(self.error(
                        format!("Expected {}", crate::pystr::repr(expect)),
                        self.src.len(),
                    ));
                }
                self.src.len()
            }
        };
        if let Some(offset) = self.src[position..end].iter().position(|c| error_on(*c)) {
            let at = position + offset;
            return Err(self.error(
                format!("Found invalid character {}", char_repr(self.src[at])),
                at,
            ));
        }
        Ok(end)
    }

    fn skip_comment(&self, position: usize) -> Result<usize> {
        if self.char_at(position) == Some('#') {
            return self.skip_until(position + 1, "\n", illegal_basic, false);
        }
        Ok(position)
    }

    fn skip_comments_and_array_ws(&self, mut position: usize) -> Result<usize> {
        loop {
            let before = position;
            position = self.skip_chars(position, TOML_WS_AND_NEWLINE);
            position = self.skip_comment(position)?;
            if position == before {
                return Ok(position);
            }
        }
    }

    fn document(mut self) -> Result<Table> {
        let mut position = 0;
        let mut header: Key = Vec::new();
        loop {
            position = self.skip_chars(position, TOML_WS);
            let Some(character) = self.char_at(position) else {
                break;
            };
            if character == '\n' {
                position += 1;
                continue;
            }
            if is_bare_key_char(character) || character == '"' || character == '\'' {
                position = self.key_value_rule(position, &header)?;
                position = self.skip_chars(position, TOML_WS);
            } else if character == '[' {
                self.out.flags.finalize_pending();
                let (next, key) = if self.char_at(position + 1) == Some('[') {
                    self.create_list_rule(position)?
                } else {
                    self.create_dict_rule(position)?
                };
                header = key;
                position = self.skip_chars(next, TOML_WS);
            } else if character != '#' {
                return Err(self.error("Invalid statement", position));
            }
            position = self.skip_comment(position)?;
            match self.char_at(position) {
                None => break,
                Some('\n') => position += 1,
                Some(_) => {
                    return Err(self.error(
                        "Expected newline or end of document after a statement",
                        position,
                    ));
                }
            }
        }
        Ok(self.out.data)
    }

    fn create_dict_rule(&mut self, position: usize) -> Result<(usize, Key)> {
        let position = self.skip_chars(position + 1, TOML_WS);
        let (position, key) = self.parse_key(position)?;
        if self.out.flags.is(&key, EXPLICIT_NEST) || self.out.flags.is(&key, FROZEN) {
            return Err(self.error(format!("Cannot declare {} twice", key_repr(&key)), position));
        }
        self.out.flags.set(&key, EXPLICIT_NEST, false);
        if nest(&mut self.out.data, &key, true).is_none() {
            return Err(self.error("Cannot overwrite a value", position));
        }
        if !self.starts_with(position, "]") {
            return Err(self.error("Expected ']' at the end of a table declaration", position));
        }
        Ok((position + 1, key))
    }

    fn create_list_rule(&mut self, position: usize) -> Result<(usize, Key)> {
        let position = self.skip_chars(position + 2, TOML_WS);
        let (position, key) = self.parse_key(position)?;
        if self.out.flags.is(&key, FROZEN) {
            return Err(self.error(
                format!("Cannot mutate immutable namespace {}", key_repr(&key)),
                position,
            ));
        }
        self.out.flags.unset_all(&key);
        self.out.flags.set(&key, EXPLICIT_NEST, false);
        let (stem, parent) = key.split_last().expect("a key has at least one part");
        let appended = match nest(&mut self.out.data, parent, true) {
            Some(container) => match container.get_mut(stem) {
                Some(Value::Array(items)) => {
                    items.push(Value::Table(Table::new()));
                    true
                }
                Some(_) => false,
                None => {
                    container.insert(stem, Value::Array(vec![Value::Table(Table::new())]));
                    true
                }
            },
            None => false,
        };
        if !appended {
            return Err(self.error("Cannot overwrite a value", position));
        }
        if !self.starts_with(position, "]]") {
            return Err(self.error("Expected ']]' at the end of an array declaration", position));
        }
        Ok((position + 2, key))
    }

    fn key_value_rule(&mut self, position: usize, header: &[String]) -> Result<usize> {
        let (position, key, value) = self.parse_key_value_pair(position)?;
        let (stem, parent) = key.split_last().expect("a key has at least one part");
        let absolute_parent: Key = header.iter().chain(parent).cloned().collect();
        for index in 1..key.len() {
            let container_key: Key = header.iter().chain(&key[..index]).cloned().collect();
            if self.out.flags.is(&container_key, EXPLICIT_NEST) {
                return Err(self.error(
                    format!("Cannot redefine namespace {}", key_repr(&container_key)),
                    position,
                ));
            }
            self.out.flags.add_pending(container_key, EXPLICIT_NEST);
        }
        if self.out.flags.is(&absolute_parent, FROZEN) {
            return Err(self.error(
                format!(
                    "Cannot mutate immutable namespace {}",
                    key_repr(&absolute_parent)
                ),
                position,
            ));
        }
        let frozen = matches!(value, Value::Table(_) | Value::Array(_));
        let Some(container) = nest(&mut self.out.data, &absolute_parent, true) else {
            return Err(self.error("Cannot overwrite a value", position));
        };
        if container.contains_key(stem) {
            return Err(self.error("Cannot overwrite a value", position));
        }
        container.insert(stem, value);
        if frozen {
            let full: Key = header.iter().chain(&key).cloned().collect();
            self.out.flags.set(&full, FROZEN, true);
        }
        Ok(position)
    }

    fn parse_key_value_pair(&self, position: usize) -> Result<(usize, Key, Value)> {
        let (position, key) = self.parse_key(position)?;
        if self.char_at(position) != Some('=') {
            return Err(self.error("Expected '=' after a key in a key/value pair", position));
        }
        let position = self.skip_chars(position + 1, TOML_WS);
        let (position, value) = self.parse_value(position)?;
        Ok((position, key, value))
    }

    fn parse_key(&self, position: usize) -> Result<(usize, Key)> {
        let (mut position, part) = self.parse_key_part(position)?;
        let mut key = vec![part];
        position = self.skip_chars(position, TOML_WS);
        while self.char_at(position) == Some('.') {
            position = self.skip_chars(position + 1, TOML_WS);
            let (next, part) = self.parse_key_part(position)?;
            key.push(part);
            position = self.skip_chars(next, TOML_WS);
        }
        Ok((position, key))
    }

    fn parse_key_part(&self, position: usize) -> Result<(usize, String)> {
        match self.char_at(position) {
            Some(character) if is_bare_key_char(character) => {
                let mut end = position;
                while self.char_at(end).is_some_and(is_bare_key_char) {
                    end += 1;
                }
                Ok((end, self.src[position..end].iter().collect()))
            }
            Some('\'') => self.parse_literal_str(position),
            Some('"') => self.parse_basic_str(position + 1, false),
            _ => Err(self.error("Invalid initial character for a key part", position)),
        }
    }

    fn parse_array(&self, position: usize) -> Result<(usize, Value)> {
        let mut items = Vec::new();
        let mut position = self.skip_comments_and_array_ws(position + 1)?;
        if self.starts_with(position, "]") {
            return Ok((position + 1, Value::Array(items)));
        }
        loop {
            let (next, value) = self.parse_value(position)?;
            items.push(value);
            position = self.skip_comments_and_array_ws(next)?;
            match self.char_at(position) {
                Some(']') => return Ok((position + 1, Value::Array(items))),
                Some(',') => {}
                _ => return Err(self.error("Unclosed array", position)),
            }
            position = self.skip_comments_and_array_ws(position + 1)?;
            if self.starts_with(position, "]") {
                return Ok((position + 1, Value::Array(items)));
            }
        }
    }

    fn parse_inline_table(&self, position: usize) -> Result<(usize, Value)> {
        let mut table = Table::new();
        let mut flags = Flags::default();
        let mut position = self.skip_chars(position + 1, TOML_WS);
        if self.starts_with(position, "}") {
            return Ok((position + 1, Value::Table(table)));
        }
        loop {
            let (next, key, value) = self.parse_key_value_pair(position)?;
            position = next;
            let (stem, parent) = key.split_last().expect("a key has at least one part");
            if flags.is(&key, FROZEN) {
                return Err(self.error(
                    format!("Cannot mutate immutable namespace {}", key_repr(&key)),
                    position,
                ));
            }
            let frozen = matches!(value, Value::Table(_) | Value::Array(_));
            let Some(container) = nest(&mut table, parent, false) else {
                return Err(self.error("Cannot overwrite a value", position));
            };
            if container.contains_key(stem) {
                return Err(self.error(
                    format!("Duplicate inline table key {}", crate::pystr::repr(stem)),
                    position,
                ));
            }
            container.insert(stem, value);
            position = self.skip_chars(position, TOML_WS);
            match self.char_at(position) {
                Some('}') => return Ok((position + 1, Value::Table(table))),
                Some(',') => {}
                _ => return Err(self.error("Unclosed inline table", position)),
            }
            if frozen {
                flags.set(&key, FROZEN, true);
            }
            position = self.skip_chars(position + 1, TOML_WS);
        }
    }

    fn parse_basic_str_escape(&self, position: usize, multiline: bool) -> Result<(usize, String)> {
        let first = self.char_at(position + 1);
        let mut position = position + 2;
        if multiline && matches!(first, Some(' ' | '\t' | '\n')) {
            if first != Some('\n') {
                position = self.skip_chars(position, TOML_WS);
                match self.char_at(position) {
                    None => return Ok((position, String::new())),
                    Some('\n') => position += 1,
                    Some(_) => return Err(self.error("Unescaped '\\' in a string", position)),
                }
            }
            position = self.skip_chars(position, TOML_WS_AND_NEWLINE);
            return Ok((position, String::new()));
        }
        let replacement = match first {
            Some('u') => return self.parse_hex_char(position, 4),
            Some('U') => return self.parse_hex_char(position, 8),
            Some('b') => '\u{8}',
            Some('t') => '\t',
            Some('n') => '\n',
            Some('f') => '\u{c}',
            Some('r') => '\r',
            Some('"') => '"',
            Some('\\') => '\\',
            _ => return Err(self.error("Unescaped '\\' in a string", position)),
        };
        Ok((position, replacement.to_string()))
    }

    fn parse_hex_char(&self, position: usize, length: usize) -> Result<(usize, String)> {
        let end = (position + length).min(self.src.len());
        let digits: String = self.src[position..end].iter().collect();
        if digits.chars().count() != length || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(self.error("Invalid hex value", position));
        }
        let position = position + length;
        let code = u32::from_str_radix(&digits, 16).expect("hex digits");
        match char::from_u32(code) {
            Some(character) => Ok((position, character.to_string())),
            None => Err(self.error("Escaped character is not a Unicode scalar value", position)),
        }
    }

    fn parse_literal_str(&self, position: usize) -> Result<(usize, String)> {
        let start = position + 1;
        let end = self.skip_until(start, "'", illegal_basic, true)?;
        Ok((end + 1, self.src[start..end].iter().collect()))
    }

    fn parse_multiline_str(&self, position: usize, literal: bool) -> Result<(usize, Value)> {
        let mut position = position + 3;
        if self.starts_with(position, "\n") {
            position += 1;
        }
        let (delimiter, mut result) = if literal {
            let end = self.skip_until(position, "'''", illegal_multiline, true)?;
            let text: String = self.src[position..end].iter().collect();
            position = end + 3;
            ('\'', text)
        } else {
            let (end, text) = self.parse_basic_str(position, true)?;
            position = end;
            ('"', text)
        };
        for _ in 0..2 {
            if self.char_at(position) != Some(delimiter) {
                break;
            }
            position += 1;
            result.push(delimiter);
        }
        Ok((position, Value::String(result)))
    }

    /// `parse_basic_str`, starting after the opening quote.
    fn parse_basic_str(&self, mut position: usize, multiline: bool) -> Result<(usize, String)> {
        let error_on = if multiline {
            illegal_multiline
        } else {
            illegal_basic
        };
        let mut result = String::new();
        let mut start = position;
        loop {
            let Some(character) = self.char_at(position) else {
                return Err(self.error("Unterminated string", position));
            };
            if character == '"' {
                if !multiline {
                    result.extend(&self.src[start..position]);
                    return Ok((position + 1, result));
                }
                if self.starts_with(position, "\"\"\"") {
                    result.extend(&self.src[start..position]);
                    return Ok((position + 3, result));
                }
                position += 1;
                continue;
            }
            if character == '\\' {
                result.extend(&self.src[start..position]);
                let (next, escaped) = self.parse_basic_str_escape(position, multiline)?;
                result.push_str(&escaped);
                position = next;
                start = position;
                continue;
            }
            if error_on(character) {
                return Err(self.error(
                    format!("Illegal character {}", char_repr(character)),
                    position,
                ));
            }
            position += 1;
        }
    }

    fn parse_value(&self, position: usize) -> Result<(usize, Value)> {
        match self.char_at(position) {
            Some('"') => {
                if self.starts_with(position, "\"\"\"") {
                    return self.parse_multiline_str(position, false);
                }
                let (end, text) = self.parse_basic_str(position + 1, false)?;
                return Ok((end, Value::String(text)));
            }
            Some('\'') => {
                if self.starts_with(position, "'''") {
                    return self.parse_multiline_str(position, true);
                }
                let (end, text) = self.parse_literal_str(position)?;
                return Ok((end, Value::String(text)));
            }
            Some('t') if self.starts_with(position, "true") => {
                return Ok((position + 4, Value::Boolean(true)));
            }
            Some('f') if self.starts_with(position, "false") => {
                return Ok((position + 5, Value::Boolean(false)));
            }
            Some('[') => return self.parse_array(position),
            Some('{') => return self.parse_inline_table(position),
            _ => {}
        }
        if let Some((end, value)) = self.match_datetime(position) {
            return match value {
                Some(value) => Ok((end, Value::Datetime(value))),
                None => Err(self.error("Invalid date or datetime", position)),
            };
        }
        if let Some((end, time)) = self.match_time(position) {
            return Ok((
                end,
                Value::Datetime(Datetime {
                    date: None,
                    time: Some(time),
                    offset_minutes: None,
                }),
            ));
        }
        if let Some((end, value)) = self.match_number(position) {
            return Ok((end, value));
        }
        let ahead = |count: usize| -> String {
            self.src[position..(position + count).min(self.src.len())]
                .iter()
                .collect()
        };
        let three = ahead(3);
        if three == "inf" || three == "nan" {
            return Ok((position + 3, Value::Float(special_float(&three))));
        }
        let four = ahead(4);
        if matches!(four.as_str(), "-inf" | "+inf" | "-nan" | "+nan") {
            return Ok((position + 4, Value::Float(special_float(&four))));
        }
        Err(self.error("Invalid value", position))
    }

    fn digits_in(
        &self,
        position: usize,
        count: usize,
        allowed: impl Fn(u32) -> bool,
    ) -> Option<u32> {
        let mut value = 0;
        for index in 0..count {
            // `to_digit` reads ASCII digits only, as `[0-9]` does.
            value = value * 10 + self.char_at(position + index)?.to_digit(10)?;
        }
        allowed(value).then_some(value)
    }

    /// `_TIME_RE_STR` at `position`: `HH:MM:SS[.ffffff…]`.
    fn match_time(&self, position: usize) -> Option<(usize, (u32, u32, u32, u32))> {
        let hour = self.digits_in(position, 2, |v| v <= 23)?;
        if self.char_at(position + 2) != Some(':') {
            return None;
        }
        let minute = self.digits_in(position + 3, 2, |v| v <= 59)?;
        if self.char_at(position + 5) != Some(':') {
            return None;
        }
        let second = self.digits_in(position + 6, 2, |v| v <= 59)?;
        let mut end = position + 8;
        let mut micro = 0;
        if self.char_at(end) == Some('.')
            && self.char_at(end + 1).is_some_and(|c| c.is_ascii_digit())
        {
            end += 1;
            let mut taken = 0;
            while taken < 6 && self.char_at(end).is_some_and(|c| c.is_ascii_digit()) {
                micro = micro * 10 + self.src[end].to_digit(10).expect("digit");
                taken += 1;
                end += 1;
            }
            micro *= 10_u32.pow(6 - taken);
            while self.char_at(end).is_some_and(|c| c.is_ascii_digit()) {
                end += 1;
            }
        }
        Some((end, (hour, minute, second, micro)))
    }

    /// `RE_DATETIME` and `match_to_datetime`: `None` when the regex does not
    /// match; `Some((end, None))` when it matches an invalid date.
    fn match_datetime(&self, position: usize) -> Option<(usize, Option<Datetime>)> {
        let year = self.digits_in(position, 4, |_| true)?;
        if self.char_at(position + 4) != Some('-') {
            return None;
        }
        let month = self.digits_in(position + 5, 2, |v| (1..=12).contains(&v))?;
        if self.char_at(position + 7) != Some('-') {
            return None;
        }
        let day = self.digits_in(position + 8, 2, |v| (1..=31).contains(&v))?;
        let mut end = position + 10;
        let mut time = None;
        let mut offset = None;
        if matches!(self.char_at(end), Some('T' | 't' | ' '))
            && let Some((after, clock)) = self.match_time(end + 1)
        {
            end = after;
            time = Some(clock);
            if matches!(self.char_at(end), Some('Z' | 'z')) {
                offset = Some(0);
                end += 1;
            } else if let Some(sign @ ('+' | '-')) = self.char_at(end)
                && let Some(hours) = self.digits_in(end + 1, 2, |v| v <= 23)
                && self.char_at(end + 3) == Some(':')
                && let Some(minutes) = self.digits_in(end + 4, 2, |v| v <= 59)
            {
                let total = (hours * 60 + minutes) as i32;
                offset = Some(if sign == '-' { -total } else { total });
                end += 6;
            }
        }
        let valid = year >= 1 && day <= days_in_month(year as i32, month);
        Some((
            end,
            valid.then_some(Datetime {
                date: Some((year as i32, month, day)),
                time,
                offset_minutes: offset,
            }),
        ))
    }

    /// `RE_NUMBER` and `match_to_number`.
    fn match_number(&self, position: usize) -> Option<(usize, Value)> {
        if self.char_at(position) == Some('0')
            && let Some(radix_char @ ('x' | 'b' | 'o')) = self.char_at(position + 1)
        {
            let radix = match radix_char {
                'x' => 16,
                'b' => 2,
                _ => 8,
            };
            if let Some(end) = self.underscored_digits(position + 2, radix) {
                let digits: String = self.src[position + 2..end]
                    .iter()
                    .filter(|c| **c != '_')
                    .collect();
                return Some((end, integer_from_digits(&digits, radix, false)));
            }
        }
        let mut end = position;
        if matches!(self.char_at(end), Some('+' | '-')) {
            end += 1;
        }
        match self.char_at(end) {
            Some('0') => end += 1,
            Some('1'..='9') => end = self.underscored_digits(end, 10)?,
            _ => return None,
        }
        let integer_end = end;
        if self.char_at(end) == Some('.')
            && let Some(after) = self.underscored_digits(end + 1, 10)
        {
            end = after;
        }
        if matches!(self.char_at(end), Some('e' | 'E')) {
            let mut exponent = end + 1;
            if matches!(self.char_at(exponent), Some('+' | '-')) {
                exponent += 1;
            }
            if let Some(after) = self.underscored_digits(exponent, 10) {
                end = after;
            }
        }
        let text: String = self.src[position..end]
            .iter()
            .filter(|c| **c != '_')
            .collect();
        if end > integer_end {
            return Some((
                end,
                Value::Float(text.parse().expect("a TOML float literal")),
            ));
        }
        let negative = text.starts_with('-');
        let digits = text.trim_start_matches(['+', '-']);
        Some((end, integer_from_digits(digits, 10, negative)))
    }

    /// `d(?:_?d)*` in `radix`, returning where it ends.
    fn underscored_digits(&self, position: usize, radix: u32) -> Option<usize> {
        let is_digit = |c: Option<char>| c.is_some_and(|c| c.is_ascii() && c.is_digit(radix));
        if !is_digit(self.char_at(position)) {
            return None;
        }
        let mut end = position + 1;
        loop {
            if is_digit(self.char_at(end)) {
                end += 1;
            } else if self.char_at(end) == Some('_') && is_digit(self.char_at(end + 1)) {
                end += 2;
            } else {
                return Some(end);
            }
        }
    }
}

fn special_float(text: &str) -> f64 {
    let magnitude = if text.ends_with("nan") {
        f64::NAN
    } else {
        f64::INFINITY
    };
    if text.starts_with('-') {
        -magnitude
    } else {
        magnitude
    }
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// `int(text, 0)` for digits already checked against `radix`.
fn integer_from_digits(digits: &str, radix: u32, negative: bool) -> Value {
    if let Ok(value) = i64::from_str_radix(digits, radix) {
        return Value::Integer(if negative { -value } else { value });
    }
    // Base-10^9 limbs, least significant first.
    let mut limbs: Vec<u64> = vec![0];
    for digit in digits
        .chars()
        .map(|c| u64::from(c.to_digit(radix).expect("digit")))
    {
        let mut carry = digit;
        for limb in &mut limbs {
            let value = *limb * u64::from(radix) + carry;
            *limb = value % 1_000_000_000;
            carry = value / 1_000_000_000;
        }
        while carry > 0 {
            limbs.push(carry % 1_000_000_000);
            carry /= 1_000_000_000;
        }
    }
    let mut text = if negative {
        "-".to_string()
    } else {
        String::new()
    };
    let mut limbs = limbs.iter().rev();
    let _ = write!(text, "{}", limbs.next().expect("one limb"));
    for limb in limbs {
        let _ = write!(text, "{limb:09}");
    }
    Value::BigInteger(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn error(text: &str) -> String {
        loads(text).unwrap_err().message
    }

    #[test]
    fn reads_the_artifact_config() {
        let table = loads(
            "schema_version = 2\nproject_id = \"p\"\nnext_id = 3\nremote_sync = 'local_only'\n",
        )
        .unwrap();
        assert_eq!(table.get("schema_version"), Some(&Value::Integer(2)));
        assert_eq!(table.get("project_id").unwrap().as_str(), Some("p"));
        let keys: Vec<&str> = table.iter().map(|(key, _)| key).collect();
        assert_eq!(
            keys,
            ["schema_version", "project_id", "next_id", "remote_sync"]
        );
    }

    #[test]
    fn tables_arrays_and_values() {
        let table = loads(
            "[a.b]\nc = [1, 2.5, -inf, 0x1F, 0o17, 0b11, 1_000, 1e3]\n[[d]]\ne = 1\n[[d]]\ne = 2\n\
             f = { g = true, h.i = \"x\" }\nj = 1979-05-27T07:32:00Z\nk = 07:32:00.5\n\
             l = \"\"\"\nline\\\n   joined\"\"\"\"\n",
        )
        .unwrap();
        let a = table.get("a").unwrap().as_table().unwrap();
        let c = a.get("b").unwrap().as_table().unwrap().get("c").unwrap();
        assert_eq!(
            c.py_repr(),
            "[1, 2.5, -inf, 31, 15, 3, 1000, 1000.0]".to_string()
        );
        let Value::Array(d) = table.get("d").unwrap() else {
            panic!()
        };
        assert_eq!(d.len(), 2);
        let last = d[1].as_table().unwrap();
        assert_eq!(
            last.get("f").unwrap().py_repr(),
            "{'g': True, 'h': {'i': 'x'}}"
        );
        assert_eq!(last.get("j").unwrap().py_str(), "1979-05-27 07:32:00+00:00");
        assert_eq!(last.get("k").unwrap().py_str(), "07:32:00.500000");
        assert_eq!(last.get("l").unwrap().as_str(), Some("linejoined\""));
        assert_eq!(
            loads("n = 123456789012345678901234567890\n")
                .unwrap()
                .get("n"),
            Some(&Value::BigInteger("123456789012345678901234567890".into()))
        );
    }

    #[test]
    fn refuses_what_tomllib_refuses_with_its_message() {
        assert_eq!(
            error("a = 1\na = 2\n"),
            "Cannot overwrite a value (at line 2, column 6)"
        );
        assert_eq!(
            error("a = {b = 1,}"),
            "Invalid initial character for a key part (at line 1, column 12)"
        );
        assert_eq!(
            error("[a]\n[a]\n"),
            "Cannot declare ('a',) twice (at line 2, column 3)"
        );
        assert_eq!(
            error("a = 1 b"),
            "Expected newline or end of document after a statement (at line 1, column 7)"
        );
        assert_eq!(error("a = \"x"), "Unterminated string (at end of document)");
        assert_eq!(
            error("a = 2026-02-30"),
            "Invalid date or datetime (at line 1, column 5)"
        );
        assert_eq!(
            error("a = \"\\e\""),
            "Unescaped '\\' in a string (at line 1, column 8)"
        );
        assert_eq!(
            error("\u{feff}a = 1"),
            "Invalid statement (at line 1, column 1)"
        );
        assert_eq!(
            error("a = 01"),
            "Expected newline or end of document after a statement (at line 1, column 6)"
        );
        assert_eq!(
            error("a = 1\n# \u{0}\n"),
            "Found invalid character '\\x00' (at line 2, column 3)"
        );
        assert_eq!(
            error("a = {\n}"),
            "Invalid initial character for a key part (at line 1, column 6)"
        );
        assert_eq!(
            error("a.b = 1\n[a.b]\n"),
            "Cannot overwrite a value (at line 2, column 5)"
        );
        assert_eq!(
            error("[a.b]\nc=1\n[a]\nb=2\n"),
            "Cannot overwrite a value (at line 4, column 4)"
        );
        assert_eq!(
            error("a = {b=1}\na.c = 2\n"),
            "Cannot mutate immutable namespace ('a',) (at line 2, column 8)"
        );
        assert_eq!(
            error("[[a]]\n[a]\n"),
            "Cannot declare ('a',) twice (at line 2, column 3)"
        );
    }
}
