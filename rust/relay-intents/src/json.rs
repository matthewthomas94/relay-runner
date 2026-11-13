//! JSON as Python's `json` module reads and writes it.
//!
//! The hook, the reply helper and the intent inbox replace Python code whose
//! files, FIFO lines and SQLite rows are still read by the Python bridge and
//! by Swift, so the text they produce must be what `json.dumps` produced: insertion-ordered
//! objects, `sort_keys`, ASCII-only escapes and `repr` floats. The same holds
//! for the values they act on, which follow Python's truthiness, `str()`,
//! `int()` and `float()` rules.

use std::collections::HashMap;
use std::fmt::Write as _;

/// The deepest nesting `parse` accepts; Python stops near 1000 frames.
const MAX_DEPTH: usize = 512;

#[derive(Clone, Debug)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    /// An integer outside `i64`, kept as written so it round-trips.
    BigInt(String),
    Float(f64),
    Str(String),
    List(Vec<Value>),
    Dict(Dict),
}

/// A JSON object that keeps insertion order, like a Python `dict`.
#[derive(Clone, Debug, Default)]
pub struct Dict {
    entries: Vec<(String, Value)>,
}

impl Dict {
    pub fn new() -> Self {
        Self::default()
    }

    /// Builds an object from parsed pairs: a repeated key keeps its first
    /// position and its last value.
    fn from_pairs(pairs: Vec<(String, Value)>) -> Self {
        let mut entries: Vec<(String, Value)> = Vec::with_capacity(pairs.len());
        if pairs.len() <= 16 {
            for (key, value) in pairs {
                match entries.iter_mut().find(|(existing, _)| *existing == key) {
                    Some(entry) => entry.1 = value,
                    None => entries.push((key, value)),
                }
            }
        } else {
            let mut positions: HashMap<String, usize> = HashMap::with_capacity(pairs.len());
            for (key, value) in pairs {
                match positions.get(&key) {
                    Some(&position) => entries[position].1 = value,
                    None => {
                        positions.insert(key.clone(), entries.len());
                        entries.push((key, value));
                    }
                }
            }
        }
        Self { entries }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|(existing, _)| existing == key)
            .map(|(_, value)| value)
    }

    /// `d.get(key)` when that is not `None`.
    pub fn present(&self, key: &str) -> Option<&Value> {
        self.get(key).filter(|value| !matches!(value, Value::Null))
    }

    /// `d.get(key)` when that is truthy.
    pub fn truthy(&self, key: &str) -> Option<&Value> {
        self.get(key).filter(|value| value.truthy())
    }

    /// `str(d.get(key) or "")`.
    pub fn string(&self, key: &str) -> String {
        self.truthy(key).map(Value::py_str).unwrap_or_default()
    }

    /// `str(d.get(key) or "").strip()`.
    pub fn text(&self, key: &str) -> String {
        py_strip(&self.string(key)).to_string()
    }

    pub fn insert(&mut self, key: &str, value: impl Into<Value>) {
        let value = value.into();
        match self
            .entries
            .iter_mut()
            .find(|(existing, _)| existing == key)
        {
            Some(entry) => entry.1 = value,
            None => self.entries.push((key.to_string(), value)),
        }
    }

    pub fn remove(&mut self, key: &str) -> Option<Value> {
        let position = self
            .entries
            .iter()
            .position(|(existing, _)| existing == key)?;
        Some(self.entries.remove(position).1)
    }

    /// `d.update(other)`.
    pub fn update(&mut self, other: &Dict) {
        for (key, value) in other.iter() {
            self.insert(key, value.clone());
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries
            .iter()
            .map(|(key, value)| (key.as_str(), value))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

impl From<&str> for Value {
    fn from(value: &str) -> Self {
        Value::Str(value.to_string())
    }
}

impl From<String> for Value {
    fn from(value: String) -> Self {
        Value::Str(value)
    }
}

impl From<i64> for Value {
    fn from(value: i64) -> Self {
        Value::Int(value)
    }
}

impl From<f64> for Value {
    fn from(value: f64) -> Self {
        Value::Float(value)
    }
}

impl From<bool> for Value {
    fn from(value: bool) -> Self {
        Value::Bool(value)
    }
}

impl From<Dict> for Value {
    fn from(value: Dict) -> Self {
        Value::Dict(value)
    }
}

impl From<Vec<Value>> for Value {
    fn from(value: Vec<Value>) -> Self {
        Value::List(value)
    }
}

impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(value: Option<T>) -> Self {
        value.map_or(Value::Null, Into::into)
    }
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_dict(&self) -> Option<&Dict> {
        match self {
            Value::Dict(dict) => Some(dict),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match self {
            Value::List(items) => Some(items),
            _ => None,
        }
    }

    /// Python's `bool(value)`.
    pub fn truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(flag) => *flag,
            Value::Int(number) => *number != 0,
            Value::BigInt(_) => true,
            Value::Float(number) => *number != 0.0,
            Value::Str(text) => !text.is_empty(),
            Value::List(items) => !items.is_empty(),
            Value::Dict(dict) => !dict.is_empty(),
        }
    }

    /// Python's `value == "text"`.
    pub fn is_str(&self, text: &str) -> bool {
        self.as_str() == Some(text)
    }

    /// Python's `str(value)`.
    pub fn py_str(&self) -> String {
        match self {
            Value::Str(text) => text.clone(),
            other => other.py_repr(),
        }
    }

    /// Python's `repr(value)`. Which non-ASCII characters Python escapes
    /// depends on the Unicode database; only control characters are escaped
    /// here. It is reached only for a list or object where text was expected.
    fn py_repr(&self) -> String {
        match self {
            Value::Null => "None".to_string(),
            Value::Bool(true) => "True".to_string(),
            Value::Bool(false) => "False".to_string(),
            Value::Int(number) => number.to_string(),
            Value::BigInt(digits) => digits.clone(),
            Value::Float(number) => float_repr(*number),
            Value::Str(text) => str_repr(text),
            Value::List(items) => {
                let parts: Vec<String> = items.iter().map(Value::py_repr).collect();
                format!("[{}]", parts.join(", "))
            }
            Value::Dict(dict) => {
                let parts: Vec<String> = dict
                    .iter()
                    .map(|(key, value)| format!("{}: {}", str_repr(key), value.py_repr()))
                    .collect();
                format!("{{{}}}", parts.join(", "))
            }
        }
    }

    /// Python's `int(value)`, or `None` where it raises. Integers that do not
    /// fit `i64` are refused; no identifier Relay writes is that large.
    pub fn py_int(&self) -> Option<i64> {
        match self {
            Value::Bool(flag) => Some(i64::from(*flag)),
            Value::Int(number) => Some(*number),
            Value::Float(number) => {
                let truncated = number.trunc();
                (truncated.is_finite() && truncated.abs() < 9.2e18).then_some(truncated as i64)
            }
            Value::Str(text) => py_int_from_str(text),
            _ => None,
        }
    }

    /// `int(value)` for anything but a `bool`, as the hook's
    /// `_nonnegative_int` and the broker's `_integer` both start.
    pub fn py_int_not_bool(&self) -> Option<i64> {
        match self {
            Value::Bool(_) => None,
            other => other.py_int(),
        }
    }

    /// Python's `float(value)`, or `None` where it raises.
    pub fn py_float(&self) -> Option<f64> {
        match self {
            Value::Bool(flag) => Some(f64::from(u8::from(*flag))),
            Value::Int(number) => Some(*number as f64),
            Value::BigInt(digits) => digits.parse().ok(),
            Value::Float(number) => Some(*number),
            // Rust reads the spellings Python does, apart from underscores
            // between digits, which no timestamp Relay writes contains.
            Value::Str(text) => py_strip(text).parse().ok(),
            _ => None,
        }
    }
}

/// Python's `a == b` for JSON values: numbers compare by value across `bool`,
/// `int` and `float`, and objects ignore key order.
pub fn py_eq(left: &Value, right: &Value) -> bool {
    fn number(value: &Value) -> Option<f64> {
        match value {
            Value::Bool(flag) => Some(f64::from(u8::from(*flag))),
            Value::Int(number) => Some(*number as f64),
            Value::Float(number) => Some(*number),
            _ => None,
        }
    }
    match (left, right) {
        (Value::Null, Value::Null) => true,
        (Value::Str(a), Value::Str(b)) => a == b,
        (Value::BigInt(a), Value::BigInt(b)) => a == b,
        (Value::Int(a), Value::Int(b)) => a == b,
        (Value::List(a), Value::List(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(x, y)| py_eq(x, y))
        }
        (Value::Dict(a), Value::Dict(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, value)| b.get(key).is_some_and(|other| py_eq(value, other)))
        }
        _ => match (number(left), number(right)) {
            (Some(a), Some(b)) => a == b,
            _ => false,
        },
    }
}

/// `py_eq` where a missing key reads as `None`, as `d.get(key)` does.
pub fn py_eq_optional(left: Option<&Value>, right: Option<&Value>) -> bool {
    py_eq(left.unwrap_or(&Value::Null), right.unwrap_or(&Value::Null))
}

/// The characters Python's `str.strip()` removes: Unicode whitespace plus the
/// four ASCII separators U+001C to U+001F, which Rust does not count.
fn py_is_space(character: char) -> bool {
    character.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&character)
}

/// Python's `text.strip()`.
pub fn py_strip(text: &str) -> &str {
    text.trim_matches(py_is_space)
}

/// Python's `int(text)` for a string: optional whitespace and sign, and
/// single underscores between digits.
pub fn py_int_from_str(text: &str) -> Option<i64> {
    let text = py_strip(text);
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text.strip_prefix('+').unwrap_or(text)),
    };
    if digits.is_empty()
        || digits.starts_with('_')
        || digits.ends_with('_')
        || digits.contains("__")
    {
        return None;
    }
    let mut value: i64 = 0;
    for character in digits.chars().filter(|character| *character != '_') {
        let digit = i64::from(character.to_digit(10)?);
        value = value.checked_mul(10)?.checked_add(digit)?;
    }
    Some(if negative { -value } else { value })
}

/// Python's `repr(float)`: the shortest digits that round-trip, in fixed
/// notation unless the exponent is below -4 or at least 16.
pub fn float_repr(value: f64) -> String {
    if value.is_nan() {
        return "nan".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf" } else { "-inf" }.to_string();
    }
    let formatted = format!("{value:e}");
    let (mantissa, exponent) = formatted
        .split_once('e')
        .expect("LowerExp always writes an exponent");
    let exponent: i32 = exponent.parse().expect("LowerExp exponent is an integer");
    let sign = if mantissa.starts_with('-') { "-" } else { "" };
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let point = exponent + 1;
    if point <= -4 || point > 16 {
        let fraction = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        let exponent_sign = if exponent < 0 { '-' } else { '+' };
        return format!(
            "{sign}{}{fraction}e{exponent_sign}{:02}",
            &digits[..1],
            exponent.abs()
        );
    }
    if point <= 0 {
        return format!(
            "{sign}0.{}{digits}",
            "0".repeat(point.unsigned_abs() as usize)
        );
    }
    let point = point as usize;
    if point >= digits.len() {
        return format!("{sign}{digits}{}.0", "0".repeat(point - digits.len()));
    }
    format!("{sign}{}.{}", &digits[..point], &digits[point..])
}

fn str_repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut out = String::with_capacity(text.len() + 2);
    out.push(quote);
    for character in text.chars() {
        match character {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other if other == quote => {
                out.push('\\');
                out.push(other);
            }
            other if other.is_control() && (other as u32) < 0x100 => {
                let _ = write!(out, "\\x{:02x}", other as u32);
            }
            other => out.push(other),
        }
    }
    out.push(quote);
    out
}

// -- reading -----------------------------------------------------------------

/// Python's `json.loads(text)`, or `None` where it raises. `NaN`, `Infinity`
/// and `-Infinity` are accepted, as Python accepts them. A lone surrogate
/// escape, which a Rust string cannot hold, is read as U+FFFD.
pub fn parse(text: &str) -> Option<Value> {
    let mut parser = Parser {
        bytes: text.as_bytes(),
        position: 0,
    };
    parser.skip_whitespace();
    let value = parser.value(0)?;
    parser.skip_whitespace();
    (parser.position == parser.bytes.len()).then_some(value)
}

/// `parse` for bytes: anything that is not UTF-8 is refused.
pub fn parse_bytes(bytes: &[u8]) -> Option<Value> {
    parse(std::str::from_utf8(bytes).ok()?)
}

struct Parser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.position).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.position += 1;
        }
    }

    fn literal(&mut self, word: &str, value: Value) -> Option<Value> {
        if self.bytes[self.position..].starts_with(word.as_bytes()) {
            self.position += word.len();
            Some(value)
        } else {
            None
        }
    }

    fn value(&mut self, depth: usize) -> Option<Value> {
        match self.peek()? {
            b'"' => self.string().map(Value::Str),
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'n' => self.literal("null", Value::Null),
            b't' => self.literal("true", Value::Bool(true)),
            b'f' => self.literal("false", Value::Bool(false)),
            b'N' => self.literal("NaN", Value::Float(f64::NAN)),
            b'I' => self.literal("Infinity", Value::Float(f64::INFINITY)),
            b'-' if self.bytes[self.position..].starts_with(b"-Infinity") => {
                self.literal("-Infinity", Value::Float(f64::NEG_INFINITY))
            }
            _ => self.number(),
        }
    }

    fn object(&mut self, depth: usize) -> Option<Value> {
        if depth >= MAX_DEPTH {
            return None;
        }
        self.position += 1;
        let mut pairs = Vec::new();
        self.skip_whitespace();
        if self.peek()? == b'}' {
            self.position += 1;
            return Some(Value::Dict(Dict::new()));
        }
        loop {
            if self.peek()? != b'"' {
                return None;
            }
            let key = self.string()?;
            self.skip_whitespace();
            if self.peek()? != b':' {
                return None;
            }
            self.position += 1;
            self.skip_whitespace();
            let value = self.value(depth + 1)?;
            pairs.push((key, value));
            self.skip_whitespace();
            match self.peek()? {
                b'}' => {
                    self.position += 1;
                    return Some(Value::Dict(Dict::from_pairs(pairs)));
                }
                b',' => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                _ => return None,
            }
        }
    }

    fn array(&mut self, depth: usize) -> Option<Value> {
        if depth >= MAX_DEPTH {
            return None;
        }
        self.position += 1;
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.peek()? == b']' {
            self.position += 1;
            return Some(Value::List(items));
        }
        loop {
            items.push(self.value(depth + 1)?);
            self.skip_whitespace();
            match self.peek()? {
                b']' => {
                    self.position += 1;
                    return Some(Value::List(items));
                }
                b',' => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                _ => return None,
            }
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.position;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.position += 1;
        }
        self.position - start
    }

    /// `-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?`; a fraction or exponent that
    /// does not complete is left unread, which the caller then refuses.
    fn number(&mut self) -> Option<Value> {
        let start = self.position;
        if self.peek() == Some(b'-') {
            self.position += 1;
        }
        match self.peek()? {
            b'0' => self.position += 1,
            b'1'..=b'9' => {
                self.digits();
            }
            _ => return None,
        }
        let mut is_float = false;
        if self.peek() == Some(b'.')
            && matches!(self.bytes.get(self.position + 1), Some(b'0'..=b'9'))
        {
            is_float = true;
            self.position += 1;
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            let exponent_start = self.position;
            self.position += 1;
            if matches!(self.peek(), Some(b'-' | b'+')) {
                self.position += 1;
            }
            if self.digits() > 0 {
                is_float = true;
            } else {
                self.position = exponent_start;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.position]).ok()?;
        if is_float {
            return text.parse().ok().map(Value::Float);
        }
        Some(match text.parse::<i64>() {
            Ok(number) => Value::Int(number),
            Err(_) => Value::BigInt(text.to_string()),
        })
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = self.bytes.get(self.position..self.position + 4)?;
        if !digits.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        self.position += 4;
        u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
    }

    fn string(&mut self) -> Option<String> {
        self.position += 1;
        let mut out = String::new();
        loop {
            let start = self.position;
            while !matches!(self.peek()?, b'"' | b'\\' | 0..=0x1f) {
                self.position += 1;
            }
            // The input is UTF-8 and the run ends at an ASCII byte.
            out.push_str(std::str::from_utf8(&self.bytes[start..self.position]).ok()?);
            match self.peek()? {
                b'"' => {
                    self.position += 1;
                    return Some(out);
                }
                b'\\' => {
                    self.position += 1;
                    let escape = self.peek()?;
                    self.position += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return None,
                    }
                }
                // A raw control character inside a string.
                _ => return None,
            }
        }
    }

    fn unicode_escape(&mut self) -> Option<char> {
        let unit = self.hex4()?;
        if (0xd800..0xdc00).contains(&unit) && self.bytes[self.position..].starts_with(b"\\u") {
            let after_high = self.position;
            self.position += 2;
            match self.hex4() {
                Some(low) if (0xdc00..0xe000).contains(&low) => {
                    return char::from_u32(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00));
                }
                _ => self.position = after_high,
            }
        }
        Some(char::from_u32(unit).unwrap_or(char::REPLACEMENT_CHARACTER))
    }
}

// -- writing -----------------------------------------------------------------

/// `json.dumps(value, sort_keys=True)`: the form of every FIFO line and of the
/// version 1 ledger, the binding and the manual submission file.
pub fn dumps_sorted(value: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, value, true, ", ", ": ");
    out
}

/// `json.dumps(value, sort_keys=True, separators=(",", ":"))`.
pub fn dumps_compact_sorted(value: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, value, true, ",", ":");
    out
}

/// `json.dumps(value, separators=(",", ":"))`, in insertion order.
pub fn dumps_compact(value: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, value, false, ",", ":");
    out
}

fn write_value(out: &mut String, value: &Value, sort_keys: bool, item: &str, key: &str) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Int(number) => {
            let _ = write!(out, "{number}");
        }
        Value::BigInt(digits) => out.push_str(digits),
        Value::Float(number) if number.is_nan() => out.push_str("NaN"),
        Value::Float(number) if number.is_infinite() => {
            out.push_str(if *number > 0.0 {
                "Infinity"
            } else {
                "-Infinity"
            });
        }
        Value::Float(number) => out.push_str(&float_repr(*number)),
        Value::Str(text) => write_string(out, text),
        Value::List(items) => {
            out.push('[');
            for (index, element) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(item);
                }
                write_value(out, element, sort_keys, item, key);
            }
            out.push(']');
        }
        Value::Dict(dict) => {
            let mut entries: Vec<(&str, &Value)> = dict.iter().collect();
            if sort_keys {
                // UTF-8 byte order is code point order, which is how Python
                // sorts the keys.
                entries.sort_by(|left, right| left.0.cmp(right.0));
            }
            out.push('{');
            for (index, (name, element)) in entries.into_iter().enumerate() {
                if index > 0 {
                    out.push_str(item);
                }
                write_string(out, name);
                out.push_str(key);
                write_value(out, element, sort_keys, item, key);
            }
            out.push('}');
        }
    }
}

/// `ensure_ascii`: everything outside space to `~` is escaped, astral
/// characters as a surrogate pair.
fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            ' '..='~' => out.push(character),
            other => {
                let mut units = [0u16; 2];
                for unit in other.encode_utf16(&mut units) {
                    let _ = write!(out, "\\u{unit:04x}");
                }
            }
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(text: &str) -> String {
        dumps_sorted(&parse(text).unwrap())
    }

    #[test]
    fn writes_what_python_json_dumps_writes() {
        // Each expectation is `json.dumps(json.loads(text), sort_keys=True)`.
        let cases = [
            (
                r#"{"b": 1, "a": [true, false, null]}"#,
                r#"{"a": [true, false, null], "b": 1}"#,
            ),
            (
                r#"{"a":{"z":1,"y":{"d":2,"c":3}}}"#,
                r#"{"a": {"y": {"c": 3, "d": 2}, "z": 1}}"#,
            ),
            (
                r#""Done — déjà vu ✅""#,
                r#""Done \u2014 d\u00e9j\u00e0 vu \u2705""#,
            ),
            (r#""😀 \ud83d\ude00""#, r#""\ud83d\ude00 \ud83d\ude00""#),
            (
                r#""\u0000\u001f\u007f\b\f\n\r\t\"\\\/""#,
                r#""\u0000\u001f\u007f\b\f\n\r\t\"\\/""#,
            ),
            ("[]", "[]"),
            ("{}", "{}"),
            (r#"{"a": 1, "a": 2, "b": 3}"#, r#"{"a": 2, "b": 3}"#),
            ("[NaN, Infinity, -Infinity]", "[NaN, Infinity, -Infinity]"),
            (
                "[-0, -0.0, 1E2, 1e-7, 12345678901234567890]",
                "[0, -0.0, 100.0, 1e-07, 12345678901234567890]",
            ),
            (" \t\r\n[1 , 2]\n", "[1, 2]"),
        ];
        for (text, expected) in cases {
            assert_eq!(round_trip(text), expected, "{text}");
        }
    }

    #[test]
    fn compact_and_unsorted_forms() {
        let value = parse(r#"{"b": [1, {"d": 1, "c": 2}], "a": "x"}"#).unwrap();
        assert_eq!(
            dumps_compact_sorted(&value),
            r#"{"a":"x","b":[1,{"c":2,"d":1}]}"#
        );
        assert_eq!(dumps_compact(&value), r#"{"b":[1,{"d":1,"c":2}],"a":"x"}"#);
    }

    #[test]
    fn refuses_what_python_json_loads_refuses() {
        let cases = [
            "",
            "   ",
            "{",
            "[1,]",
            "{\"a\":1,}",
            "{'a': 1}",
            "{\"a\" 1}",
            "01",
            "1.",
            ".5",
            "1e",
            "+1",
            "nul",
            "True",
            "\"abc",
            "\"a\nb\"",
            "\"\\x41\"",
            "\"\\u12g4\"",
            "[1] 2",
            "{} trailing",
            "\u{feff}{}",
            "-",
            "- 1",
            "[1 2]",
            "NaNa",
        ];
        for text in cases {
            assert!(parse(text).is_none(), "{text:?}");
        }
        let nested = "[".repeat(MAX_DEPTH + 1) + &"]".repeat(MAX_DEPTH + 1);
        assert!(parse(&nested).is_none());
        assert!(parse_bytes(b"\"caf\xe9\"").is_none());
    }

    #[test]
    fn a_lone_surrogate_becomes_the_replacement_character() {
        for text in [
            r#""\ud83d""#,
            r#""\ude00""#,
            r#""\ud83dx""#,
            r#""\ud83d\u0041""#,
        ] {
            let parsed = parse(text).unwrap();
            assert!(parsed.as_str().unwrap().starts_with('\u{fffd}'), "{text}");
        }
        assert_eq!(
            parse(r#""\ud83d\u0041""#).unwrap().as_str(),
            Some("\u{fffd}A")
        );
    }

    #[test]
    fn float_repr_matches_python() {
        let cases = [
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (1.0, "1.0"),
            (1.5, "1.5"),
            (0.1, "0.1"),
            (1731300000.123456, "1731300000.123456"),
            (1e15, "1000000000000000.0"),
            (9999999999999998.0, "9999999999999998.0"),
            (1e16, "1e+16"),
            (1.5e16, "1.5e+16"),
            (1.2345678901234568e17, "1.2345678901234568e+17"),
            (0.0001, "0.0001"),
            (0.00012, "0.00012"),
            (0.00001, "1e-05"),
            (1.5e-7, "1.5e-07"),
            (5e-324, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (-2.5, "-2.5"),
            (123.456, "123.456"),
        ];
        for (value, expected) in cases {
            assert_eq!(float_repr(value), expected);
        }
    }

    #[test]
    fn python_truthiness_text_and_numbers() {
        let value = parse(
            r#"{"none": null, "zero": 0, "empty": "", "list": [], "text": " a ", "seq": "7",
                "float": 7.9, "flag": true, "dict": {"id": 1}, "items": ["Stop", 2.0]}"#,
        )
        .unwrap();
        let dict = value.as_dict().unwrap();
        for key in ["none", "zero", "empty", "list", "missing"] {
            assert!(dict.truthy(key).is_none(), "{key}");
            assert_eq!(dict.text(key), "");
        }
        assert_eq!(dict.text("text"), "a");
        assert_eq!(dict.string("text"), " a ");
        assert_eq!(dict.text("dict"), "{'id': 1}");
        assert_eq!(dict.text("items"), "['Stop', 2.0]");
        assert_eq!(dict.text("flag"), "True");
        assert_eq!(dict.text("float"), "7.9");
        assert_eq!(dict.get("seq").unwrap().py_int(), Some(7));
        assert_eq!(dict.get("float").unwrap().py_int(), Some(7));
        assert_eq!(dict.get("flag").unwrap().py_int(), Some(1));
        assert_eq!(dict.get("flag").unwrap().py_int_not_bool(), None);
        assert_eq!(dict.get("none").unwrap().py_int(), None);
        assert_eq!(dict.get("dict").unwrap().py_int(), None);
        assert_eq!(dict.get("seq").unwrap().py_float(), Some(7.0));
        assert_eq!(dict.get("text").unwrap().py_float(), None);
        assert_eq!(dict.get("list").unwrap().py_float(), None);
    }

    #[test]
    fn python_int_from_text() {
        assert_eq!(py_int_from_str(" 7 "), Some(7));
        assert_eq!(py_int_from_str("+7"), Some(7));
        assert_eq!(py_int_from_str("-1_000"), Some(-1000));
        for text in [
            "",
            "next",
            "7.0",
            "1__0",
            "_1",
            "1_",
            "0x1f",
            "99999999999999999999",
        ] {
            assert_eq!(py_int_from_str(text), None, "{text}");
        }
    }

    #[test]
    fn python_equality_and_strip() {
        let left = parse(r#"{"a": 1, "b": [1.0, true, "x"], "c": null}"#).unwrap();
        let right = parse(r#"{"c": null, "b": [1, 1, "x"], "a": 1.0}"#).unwrap();
        assert!(py_eq(&left, &right));
        assert!(!py_eq(
            &left,
            &parse(r#"{"a": 1, "b": [1, 1, "x"]}"#).unwrap()
        ));
        assert!(!py_eq(&Value::from("1"), &Value::from(1)));
        assert!(py_eq_optional(None, Some(&Value::Null)));
        assert_eq!(py_strip("\u{1c}\u{a0} a b \t\n\u{1f}"), "a b");
    }

    #[test]
    fn dict_keeps_insertion_order_through_edits() {
        let mut dict = Dict::new();
        dict.insert("b", 1);
        dict.insert("a", "x");
        dict.insert("b", 2);
        dict.insert("c", Value::Null);
        assert_eq!(dict.remove("a").unwrap().as_str(), Some("x"));
        assert!(dict.present("c").is_none());
        assert_eq!(dumps_compact(&Value::Dict(dict)), r#"{"b":2,"c":null}"#);
        let many: String = (0..40)
            .map(|index| format!("\"k{}\": {index}, ", index % 20))
            .collect();
        let parsed = parse(&format!("{{{many}\"end\": 0}}")).unwrap();
        assert_eq!(parsed.as_dict().unwrap().len(), 21);
        assert_eq!(
            parsed.as_dict().unwrap().get("k3").unwrap().py_int(),
            Some(23)
        );
    }
}
