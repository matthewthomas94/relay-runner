//! `tomllib.loads`, the TOML 1.0 reader `config.py` uses on Python 3.11+.
//!
//! It follows tomllib's own parser rule for rule, including which tables may
//! be declared again, so a file Python refuses is refused here too. Values
//! are the JSON `Value`s the rest of the bridge reads: a table is a `Dict` in
//! the order its keys first appear, an array of tables a list of them. Dates
//! and times have no `Value`, so a file holding one is refused; Relay never
//! writes one.

use std::collections::HashSet;

use crate::json::{Dict, Value};

/// A TOML document tomllib would refuse, with tomllib's message.
#[derive(Debug, PartialEq)]
pub struct DecodeError(pub &'static str);

type Parsed<T> = Result<T, DecodeError>;

/// `tomllib.loads(text)`.
pub fn loads(text: &str) -> Parsed<Dict> {
    let source: Vec<char> = text.replace("\r\n", "\n").chars().collect();
    let mut parser = Parser {
        src: source,
        pos: 0,
        root: Table::default(),
        explicit: HashSet::new(),
        pending: Vec::new(),
    };
    parser.document()?;
    Ok(parser.root.into_dict())
}

/// A table while the document is read: an inline table or array is already
/// a finished `Value`, which nothing may add to.
enum Node {
    Value(Value),
    Table(Table),
    Tables(Vec<Table>),
}

#[derive(Default)]
struct Table {
    entries: Vec<(String, Node)>,
}

impl Table {
    fn contains(&self, key: &str) -> bool {
        self.entries.iter().any(|(existing, _)| existing == key)
    }

    fn into_dict(self) -> Dict {
        let mut dict = Dict::new();
        for (key, node) in self.entries {
            dict.insert(&key, node.into_value());
        }
        dict
    }
}

impl Node {
    fn into_value(self) -> Value {
        match self {
            Node::Value(value) => value,
            Node::Table(table) => Value::Dict(table.into_dict()),
            Node::Tables(tables) => Value::List(
                tables
                    .into_iter()
                    .map(|t| Value::Dict(t.into_dict()))
                    .collect(),
            ),
        }
    }
}

/// `NestedDict.get_or_create_nest`: the table at `key`, created where
/// missing; through an array of tables, its last table.
fn nest<'a>(mut table: &'a mut Table, key: &[String]) -> Parsed<&'a mut Table> {
    for part in key {
        let index = match table
            .entries
            .iter()
            .position(|(existing, _)| existing == part)
        {
            Some(index) => index,
            None => {
                table
                    .entries
                    .push((part.clone(), Node::Table(Table::default())));
                table.entries.len() - 1
            }
        };
        table = match &mut table.entries[index].1 {
            Node::Table(inner) => inner,
            Node::Tables(tables) => tables.last_mut().ok_or(DecodeError(OVERWRITE))?,
            Node::Value(_) => return Err(DecodeError(OVERWRITE)),
        };
    }
    Ok(table)
}

const OVERWRITE: &str = "Cannot overwrite a value";

fn bare_key(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '-' || c == '_'
}

fn ws(c: char) -> bool {
    c == ' ' || c == '\t'
}

fn ws_and_newline(c: char) -> bool {
    ws(c) || c == '\n'
}

/// tomllib's `ASCII_CTRL` less the characters a context allows.
fn illegal(c: char, allow_newline: bool) -> bool {
    (c < ' ' || c == '\u{7f}') && c != '\t' && !(allow_newline && c == '\n')
}

struct Parser {
    src: Vec<char>,
    pos: usize,
    root: Table,
    /// tomllib's `Flags.EXPLICIT_NEST`: tables a header or a dotted key
    /// already defined, which no later header may declare again.
    explicit: HashSet<Vec<String>>,
    /// Dotted-key tables of the current section, explicit from the next
    /// header on.
    pending: Vec<Vec<String>>,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.src.get(self.pos).copied()
    }

    fn starts_with(&self, text: &str) -> bool {
        let mut index = self.pos;
        for c in text.chars() {
            if self.src.get(index) != Some(&c) {
                return false;
            }
            index += 1;
        }
        true
    }

    fn skip(&mut self, accept: fn(char) -> bool) {
        while self.peek().is_some_and(accept) {
            self.pos += 1;
        }
    }

    fn text(&self, start: usize, end: usize) -> String {
        self.src[start..end].iter().collect()
    }

    /// The main loop of `tomllib.loads`.
    fn document(&mut self) -> Parsed<()> {
        let mut header: Vec<String> = Vec::new();
        loop {
            self.skip(ws);
            let Some(c) = self.peek() else { break };
            if c == '\n' {
                self.pos += 1;
                continue;
            }
            if bare_key(c) || c == '"' || c == '\'' {
                self.key_value_rule(&header)?;
                self.skip(ws);
            } else if c == '[' {
                for key in self.pending.drain(..) {
                    self.explicit.insert(key);
                }
                header = if self.src.get(self.pos + 1) == Some(&'[') {
                    self.create_list_rule()?
                } else {
                    self.create_dict_rule()?
                };
                self.skip(ws);
            } else if c != '#' {
                return Err(DecodeError("Invalid statement"));
            }
            self.skip_comment()?;
            match self.peek() {
                None => break,
                Some('\n') => self.pos += 1,
                Some(_) => {
                    return Err(DecodeError(
                        "Expected newline or end of document after a statement",
                    ));
                }
            }
        }
        Ok(())
    }

    fn skip_comment(&mut self) -> Parsed<()> {
        if self.peek() == Some('#') {
            self.pos += 1;
            while let Some(c) = self.peek() {
                if c == '\n' {
                    break;
                }
                if illegal(c, false) {
                    return Err(DecodeError("Found invalid character"));
                }
                self.pos += 1;
            }
        }
        Ok(())
    }

    fn skip_comments_and_array_ws(&mut self) -> Parsed<()> {
        loop {
            let start = self.pos;
            self.skip(ws_and_newline);
            self.skip_comment()?;
            if self.pos == start {
                return Ok(());
            }
        }
    }

    /// `create_dict_rule`: a `[table]` header.
    fn create_dict_rule(&mut self) -> Parsed<Vec<String>> {
        self.pos += 1;
        self.skip(ws);
        let key = self.key()?;
        if self.explicit.contains(&key) {
            return Err(DecodeError("Cannot declare a table twice"));
        }
        self.explicit.insert(key.clone());
        nest(&mut self.root, &key)?;
        if !self.starts_with("]") {
            return Err(DecodeError(
                "Expected ']' at the end of a table declaration",
            ));
        }
        self.pos += 1;
        Ok(key)
    }

    /// `create_list_rule`: an `[[array]]` header.
    fn create_list_rule(&mut self) -> Parsed<Vec<String>> {
        self.pos += 2;
        self.skip(ws);
        let key = self.key()?;
        // The new table frees everything declared in the previous one, but
        // the array itself stays closed to a `[table]` header.
        self.explicit.retain(|declared| !declared.starts_with(&key));
        self.explicit.insert(key.clone());
        let (stem, parent) = key.split_last().expect("a key has a part");
        let table = nest(&mut self.root, parent)?;
        match table
            .entries
            .iter_mut()
            .find(|(existing, _)| existing == stem)
        {
            Some((_, Node::Tables(tables))) => tables.push(Table::default()),
            Some(_) => return Err(DecodeError(OVERWRITE)),
            None => table
                .entries
                .push((stem.clone(), Node::Tables(vec![Table::default()]))),
        }
        if !self.starts_with("]]") {
            return Err(DecodeError(
                "Expected ']]' at the end of an array declaration",
            ));
        }
        self.pos += 2;
        Ok(key)
    }

    /// `key_value_rule`: `key = value` in the current section.
    fn key_value_rule(&mut self, header: &[String]) -> Parsed<()> {
        let (key, value) = self.key_value_pair()?;
        let (stem, parent) = key.split_last().expect("a key has a part");
        for end in 1..key.len() {
            let container: Vec<String> = header.iter().chain(&key[..end]).cloned().collect();
            if self.explicit.contains(&container) {
                return Err(DecodeError("Cannot redefine namespace"));
            }
            self.pending.push(container);
        }
        let path: Vec<String> = header.iter().chain(parent).cloned().collect();
        let table = nest(&mut self.root, &path)?;
        if table.contains(stem) {
            return Err(DecodeError(OVERWRITE));
        }
        table.entries.push((stem.clone(), Node::Value(value)));
        Ok(())
    }

    fn key_value_pair(&mut self) -> Parsed<(Vec<String>, Value)> {
        let key = self.key()?;
        if self.peek() != Some('=') {
            return Err(DecodeError("Expected '=' after a key in a key/value pair"));
        }
        self.pos += 1;
        self.skip(ws);
        let value = self.value()?;
        Ok((key, value))
    }

    fn key(&mut self) -> Parsed<Vec<String>> {
        let mut key = vec![self.key_part()?];
        self.skip(ws);
        while self.peek() == Some('.') {
            self.pos += 1;
            self.skip(ws);
            key.push(self.key_part()?);
            self.skip(ws);
        }
        Ok(key)
    }

    fn key_part(&mut self) -> Parsed<String> {
        match self.peek() {
            Some(c) if bare_key(c) => {
                let start = self.pos;
                self.skip(bare_key);
                Ok(self.text(start, self.pos))
            }
            Some('\'') => self.literal_string(),
            Some('"') => {
                self.pos += 1;
                self.basic_string(false)
            }
            _ => Err(DecodeError("Invalid initial character for a key part")),
        }
    }

    /// `parse_value`.
    fn value(&mut self) -> Parsed<Value> {
        let Some(c) = self.peek() else {
            return Err(DecodeError("Invalid value"));
        };
        match c {
            '"' if self.starts_with("\"\"\"") => {
                return self.multiline_string(false).map(Value::Str);
            }
            '"' => {
                self.pos += 1;
                return self.basic_string(false).map(Value::Str);
            }
            '\'' if self.starts_with("'''") => return self.multiline_string(true).map(Value::Str),
            '\'' => return self.literal_string().map(Value::Str),
            't' if self.starts_with("true") => {
                self.pos += 4;
                return Ok(Value::Bool(true));
            }
            'f' if self.starts_with("false") => {
                self.pos += 5;
                return Ok(Value::Bool(false));
            }
            '[' => return self.array(),
            '{' => return self.inline_table(),
            _ => {}
        }
        if self.at_date_or_time() {
            return Err(DecodeError("Dates and times are not supported"));
        }
        if let Some(number) = self.number()? {
            return Ok(number);
        }
        for (text, value) in [
            ("inf", f64::INFINITY),
            ("nan", f64::NAN),
            ("-inf", f64::NEG_INFINITY),
            ("+inf", f64::INFINITY),
            ("-nan", f64::NAN),
            ("+nan", f64::NAN),
        ] {
            if self.starts_with(text) {
                self.pos += text.chars().count();
                return Ok(Value::Float(value));
            }
        }
        Err(DecodeError("Invalid value"))
    }

    /// Where tomllib's `RE_DATETIME` or `RE_LOCALTIME` would match: four
    /// digits and `-`, or two digits and `:`.
    fn at_date_or_time(&self) -> bool {
        let digit = |offset: usize| {
            self.src
                .get(self.pos + offset)
                .is_some_and(char::is_ascii_digit)
        };
        let at = |offset: usize, c: char| self.src.get(self.pos + offset) == Some(&c);
        (digit(0) && digit(1) && digit(2) && digit(3) && at(4, '-'))
            || (digit(0) && digit(1) && at(2, ':'))
    }

    /// `RE_NUMBER` and `match_to_number`: `None` where nothing matches.
    fn number(&mut self) -> Parsed<Option<Value>> {
        let start = self.pos;
        if self.peek() == Some('0') {
            let radix = match self.src.get(start + 1) {
                Some('x') => Some(16),
                Some('o') => Some(8),
                Some('b') => Some(2),
                _ => None,
            };
            if let Some(radix) = radix {
                self.pos = start + 2;
                if let Some(digits) = self.digits(radix) {
                    if let Ok(value) = i64::from_str_radix(&digits, radix) {
                        return Ok(Some(Value::Int(value)));
                    }
                    let value = u128::from_str_radix(&digits, radix)
                        .map_err(|_| DecodeError("Integer out of range"))?;
                    return Ok(Some(Value::BigInt(value.to_string())));
                }
                self.pos = start;
            }
        }
        let mut text = String::new();
        if let Some(sign @ ('+' | '-')) = self.peek() {
            text.push(sign);
            self.pos += 1;
        }
        match self.peek() {
            Some('0') => {
                text.push('0');
                self.pos += 1;
            }
            Some('1'..='9') => text.push_str(&self.digits(10).expect("a digit is next")),
            _ => {
                self.pos = start;
                return Ok(None);
            }
        }
        let mut float = false;
        let fraction_start = self.pos;
        if self.peek() == Some('.') {
            self.pos += 1;
            match self.digits(10) {
                Some(digits) => {
                    text.push('.');
                    text.push_str(&digits);
                    float = true;
                }
                None => self.pos = fraction_start,
            }
        }
        let exponent_start = self.pos;
        if let Some('e' | 'E') = self.peek() {
            self.pos += 1;
            let mut exponent = String::from("e");
            if let Some(sign @ ('+' | '-')) = self.peek() {
                exponent.push(sign);
                self.pos += 1;
            }
            match self.digits(10) {
                Some(digits) => {
                    text.push_str(&exponent);
                    text.push_str(&digits);
                    float = true;
                }
                None => self.pos = exponent_start,
            }
        }
        if float {
            let value: f64 = text.parse().expect("the float grammar is Rust's");
            return Ok(Some(Value::Float(value)));
        }
        Ok(Some(match text.parse::<i64>() {
            Ok(value) => Value::Int(value),
            // Python's integers have no bound; keep the digits as written.
            Err(_) => Value::BigInt(text.trim_start_matches('+').to_string()),
        }))
    }

    /// `d(?:_?d)*` in `radix`, without the underscores; `None`, with the
    /// position unchanged, unless a digit is next.
    fn digits(&mut self, radix: u32) -> Option<String> {
        let is_digit = |c: Option<&char>| c.is_some_and(|c| c.is_digit(radix));
        if !is_digit(self.src.get(self.pos)) {
            return None;
        }
        let mut digits = String::new();
        loop {
            digits.push(self.src[self.pos]);
            self.pos += 1;
            if is_digit(self.src.get(self.pos)) {
                continue;
            }
            if self.src.get(self.pos) == Some(&'_') && is_digit(self.src.get(self.pos + 1)) {
                self.pos += 1;
                continue;
            }
            return Some(digits);
        }
    }

    fn array(&mut self) -> Parsed<Value> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_comments_and_array_ws()?;
        if self.starts_with("]") {
            self.pos += 1;
            return Ok(Value::List(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_comments_and_array_ws()?;
            match self.peek() {
                Some(']') => {
                    self.pos += 1;
                    return Ok(Value::List(items));
                }
                Some(',') => self.pos += 1,
                _ => return Err(DecodeError("Unclosed array")),
            }
            self.skip_comments_and_array_ws()?;
            if self.starts_with("]") {
                self.pos += 1;
                return Ok(Value::List(items));
            }
        }
    }

    fn inline_table(&mut self) -> Parsed<Value> {
        self.pos += 1;
        let mut table = Table::default();
        self.skip(ws);
        if self.starts_with("}") {
            self.pos += 1;
            return Ok(Value::Dict(table.into_dict()));
        }
        loop {
            let (key, value) = self.key_value_pair()?;
            let (stem, parent) = key.split_last().expect("a key has a part");
            let nested = nest(&mut table, parent)?;
            if nested.contains(stem) {
                return Err(DecodeError("Duplicate inline table key"));
            }
            nested.entries.push((stem.clone(), Node::Value(value)));
            self.skip(ws);
            match self.peek() {
                Some('}') => {
                    self.pos += 1;
                    return Ok(Value::Dict(table.into_dict()));
                }
                Some(',') => self.pos += 1,
                _ => return Err(DecodeError("Unclosed inline table")),
            }
            self.skip(ws);
        }
    }

    /// `parse_basic_str`, from just after the opening quote(s).
    fn basic_string(&mut self, multiline: bool) -> Parsed<String> {
        let mut result = String::new();
        loop {
            let Some(c) = self.peek() else {
                return Err(DecodeError("Unterminated string"));
            };
            if c == '"' {
                if !multiline {
                    self.pos += 1;
                    return Ok(result);
                }
                if self.starts_with("\"\"\"") {
                    self.pos += 3;
                    return Ok(result);
                }
                result.push(c);
                self.pos += 1;
                continue;
            }
            if c == '\\' {
                self.escape(multiline, &mut result)?;
                continue;
            }
            if illegal(c, multiline) {
                return Err(DecodeError("Illegal character in a string"));
            }
            result.push(c);
            self.pos += 1;
        }
    }

    /// `parse_basic_str_escape`, at the backslash.
    fn escape(&mut self, multiline: bool, result: &mut String) -> Parsed<()> {
        let id = self.src.get(self.pos + 1).copied();
        self.pos += 2;
        if multiline && matches!(id, Some(' ' | '\t' | '\n')) {
            // A line-ending backslash trims up to the next non-blank.
            if id != Some('\n') {
                self.skip(ws);
                match self.peek() {
                    None => return Ok(()),
                    Some('\n') => self.pos += 1,
                    Some(_) => return Err(DecodeError("Unescaped '\\' in a string")),
                }
            }
            self.skip(ws_and_newline);
            return Ok(());
        }
        let replacement = match id {
            Some('u') => return self.hex_char(4, result),
            Some('U') => return self.hex_char(8, result),
            Some('b') => '\u{8}',
            Some('t') => '\t',
            Some('n') => '\n',
            Some('f') => '\u{c}',
            Some('r') => '\r',
            Some('"') => '"',
            Some('\\') => '\\',
            _ => return Err(DecodeError("Unescaped '\\' in a string")),
        };
        result.push(replacement);
        Ok(())
    }

    fn hex_char(&mut self, length: usize, result: &mut String) -> Parsed<()> {
        let end = self.pos + length;
        if end > self.src.len() || !self.src[self.pos..end].iter().all(char::is_ascii_hexdigit) {
            return Err(DecodeError("Invalid hex value"));
        }
        let code = u32::from_str_radix(&self.text(self.pos, end), 16).expect("hex digits");
        let c = char::from_u32(code).ok_or(DecodeError(
            "Escaped character is not a Unicode scalar value",
        ))?;
        result.push(c);
        self.pos = end;
        Ok(())
    }

    /// `parse_literal_str`, at the opening apostrophe.
    fn literal_string(&mut self) -> Parsed<String> {
        self.pos += 1;
        let start = self.pos;
        loop {
            match self.peek() {
                None => return Err(DecodeError("Unterminated string")),
                Some('\'') => break,
                Some(c) if illegal(c, false) => {
                    return Err(DecodeError("Found invalid character"));
                }
                Some(_) => self.pos += 1,
            }
        }
        let text = self.text(start, self.pos);
        self.pos += 1;
        Ok(text)
    }

    /// `parse_multiline_str`, at the opening delimiter.
    fn multiline_string(&mut self, literal: bool) -> Parsed<String> {
        self.pos += 3;
        if self.peek() == Some('\n') {
            self.pos += 1;
        }
        let delimiter = if literal { '\'' } else { '"' };
        let mut result = if literal {
            let start = self.pos;
            while !self.starts_with("'''") {
                match self.peek() {
                    None => return Err(DecodeError("Unterminated string")),
                    Some(c) if illegal(c, true) => {
                        return Err(DecodeError("Found invalid character"));
                    }
                    Some(_) => self.pos += 1,
                }
            }
            let text = self.text(start, self.pos);
            self.pos += 3;
            text
        } else {
            self.basic_string(true)?
        };
        // Up to two quotes may directly precede the closing three.
        for _ in 0..2 {
            if self.peek() != Some(delimiter) {
                break;
            }
            result.push(delimiter);
            self.pos += 1;
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::dumps;

    fn json(text: &str) -> String {
        dumps(&Value::Dict(loads(text).unwrap()))
    }

    fn refused(text: &str) -> bool {
        loads(text).is_err()
    }

    #[test]
    fn the_file_swift_writes_reads_back() {
        let text = "[stt]\nmodel = \"phonon-2\"\ntrue_whisper = false\n\n\
                    [tts]\nrate = 1.3\nauto_play = true\n\n\
                    [awareness]\nglow_intensity = 0.75\n";
        assert_eq!(
            json(text),
            r#"{"stt": {"model": "phonon-2", "true_whisper": false}, "tts": {"rate": 1.3, "auto_play": true}, "awareness": {"glow_intensity": 0.75}}"#
        );
    }

    // The expected text below is `json.dumps(tomllib.loads(text))` on
    // Python 3.14.
    #[test]
    fn values_match_tomllib() {
        let text = concat!(
            "# comment\r\n",
            "  a = 'lit\\eral'  # trailing\n",
            "b = \"tab\\there \\u00e9 \\U0001F600 \\\"q\\\" \\\\\"\n",
            "c = [ 1, -2, +3, 1_000, 0xff, 0o17, 0b101, 0x1_0000_0000_0000_0000, ]\n",
            "d = [1.5, -0.0, 1e3, 2E-2, 6.02_2e2_3, inf, -inf]\n",
            "e = [\n  'x', # inside\n  [true, false],\n  {f = 1, g.h = \"i\"},\n]\n",
            "\"quoted key\" = 1\n",
            "'lit key'.\"q\" . bare = 2\n",
            "big = 99999999999999999999\n",
            "s = \"\"\"\nfirst\\\n    second \\\n\n  third\"\"\"\"\"\n",
            "t = '''\nraw \\n ''text'''''\n",
            "",
        );
        assert_eq!(
            json(text),
            concat!(
                r#"{"a": "lit\\eral", "b": "tab\there \u00e9 \ud83d\ude00 \"q\" \\", "#,
                r#""c": [1, -2, 3, 1000, 255, 15, 5, 18446744073709551616], "#,
                r#""d": [1.5, -0.0, 1000.0, 0.02, 6.022e+23, Infinity, -Infinity], "#,
                r#""e": ["x", [true, false], {"f": 1, "g": {"h": "i"}}], "#,
                r#""quoted key": 1, "lit key": {"q": {"bare": 2}}, "#,
                r#""big": 99999999999999999999, "#,
                r#""s": "firstsecond third\"\"", "t": "raw \\n ''text''"}"#
            )
        );
        assert!(matches!(loads("n = nan").unwrap().get("n"), Some(Value::Float(v)) if v.is_nan()));
    }

    #[test]
    fn tables_and_arrays_of_tables_nest_like_tomllib() {
        let text = concat!(
            "top = 1\n",
            "[a.b]\nc = 1\n",
            "[a]\nd = 2\n",
            "[[list]]\nx = 1\n[list.sub]\ny = 2\n",
            "[[list]]\nx = 3\n[list.sub]\ny = 4\n",
            "[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nsmooth = true\n",
        );
        assert_eq!(
            json(text),
            concat!(
                r#"{"top": 1, "a": {"b": {"c": 1}, "d": 2}, "#,
                r#""list": [{"x": 1, "sub": {"y": 2}}, {"x": 3, "sub": {"y": 4}}], "#,
                r#""fruit": {"apple": {"color": "red", "texture": {"smooth": true}}}}"#
            )
        );
    }

    #[test]
    fn documents_tomllib_refuses_are_refused() {
        for text in [
            "a = 1\na = 2",
            "[a]\n[a]",
            "[a]\nb = 1\n[a.b]",
            "a = {b = 1}\na.c = 2",
            "a = {b = 1}\n[a]",
            "a = [1]\n[[a]]",
            "[[a]]\n[a]",
            "a.b = 1\n[a]",
            "[fruit]\napple.color = 'red'\n[fruit.apple]",
            "[a.b]\n[a]\nb.c = 1",
            "a = {b = 1,}",
            "a = {\nb = 1}",
            "a = {b = 1, b = 2}",
            "a = \"\\e\"",
            "a = \"\\x41\"",
            "a = \"open",
            "a = 'line\nbreak'",
            "a = \"\\ud800\"",
            "a = 010",
            "a = 1.",
            "a = .5",
            "a = 1__0",
            "a = 1e",
            "a = truex",
            "a = 1 b = 2",
            "a =",
            "= 1",
            "a",
            "[a",
            "[[a]",
            "a = 1\rb = 2",
            "a = 1 # bell \u{7}",
            "a = 0x_ff",
            "\u{feff}a = 1",
        ] {
            assert!(refused(text), "{text:?} should be refused");
        }
    }

    #[test]
    fn dates_and_times_are_refused() {
        // tomllib returns `datetime` objects here, which JSON cannot hold.
        for text in ["d = 1979-05-27", "t = 07:32:00", "o = 1979-05-27T07:32:00Z"] {
            assert!(refused(text), "{text:?} should be refused");
        }
    }

    #[test]
    fn an_empty_document_is_an_empty_table() {
        assert!(loads("").unwrap().is_empty());
        assert!(loads("\n  # only a comment\n\t\n").unwrap().is_empty());
        assert_eq!(json("[empty]"), r#"{"empty": {}}"#);
    }
}
