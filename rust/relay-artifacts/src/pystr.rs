//! The Python `str` operations whose results end up in committed bytes.

use std::sync::LazyLock;

pub use relay_intents::json::{py_is_space as is_space, py_strip as strip};

/// `\d` in a Python `str` pattern, and what `int()` reads as a digit: any
/// character of Unicode category Nd.
static DECIMAL: LazyLock<fancy_regex::Regex> =
    LazyLock::new(|| fancy_regex::Regex::new(r"^\d$").expect("digit pattern"));

fn is_decimal(character: char) -> bool {
    let mut buffer = [0; 4];
    DECIMAL
        .is_match(character.encode_utf8(&mut buffer))
        .unwrap_or(false)
}

/// The value of a decimal digit in any script. Unicode assigns every Nd
/// character in runs of ten, zero to nine, and adjacent runs are whole
/// multiples of ten long, so the value is the distance from the start of the
/// contiguous Nd sequence, modulo ten.
pub fn decimal_value(character: char) -> Option<u32> {
    if let Some(value) = character.to_digit(10) {
        return Some(value);
    }
    if !is_decimal(character) {
        return None;
    }
    let mut start = character as u32;
    while let Some(previous) = start.checked_sub(1).and_then(char::from_u32) {
        if !is_decimal(previous) {
            break;
        }
        start -= 1;
    }
    Some((character as u32 - start) % 10)
}

/// Python's `int(text)`: surrounding whitespace, an optional sign, decimal
/// digits of any script and single underscores between digits. `None` where
/// Python raises, or for a value outside `i64`.
pub fn int(text: &str) -> Option<i64> {
    let text = strip(text);
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
        let digit = i64::from(decimal_value(character)?);
        value = value.checked_mul(10)?.checked_add(digit)?;
    }
    Some(if negative { -value } else { value })
}

/// Python's `repr(text)` for a string.
pub fn repr(text: &str) -> String {
    relay_intents::json::str_repr(text)
}

/// Python's `str.splitlines()`: lines without their terminators, where a
/// terminator is any of `\n`, `\r`, `\r\n`, `\v`, `\f`, U+001C to U+001E,
/// U+0085, U+2028 and U+2029, and a final terminator adds no empty line.
pub fn splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        let breaks = matches!(
            character,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        lines.push(&text[start..index]);
        let mut end = index + character.len_utf8();
        if character == '\r' && characters.peek().map(|(_, next)| *next) == Some('\n') {
            characters.next();
            end += 1;
        }
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// `type(value).__name__` for a JSON value.
pub fn type_name(value: &relay_intents::json::Value) -> &'static str {
    use relay_intents::json::Value;
    match value {
        Value::Null => "NoneType",
        Value::Bool(_) => "bool",
        Value::Int(_) | Value::BigInt(_) => "int",
        Value::Float(_) => "float",
        Value::Str(_) => "str",
        Value::List(_) => "list",
        Value::Dict(_) => "dict",
    }
}

/// The universal-newline translation of text-mode reads such as
/// `Path.read_text()`: `\r\n` and `\r` become `\n`.
pub fn universal_newlines(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

/// `content.decode("utf-8")`, failing with Python's `UnicodeDecodeError`
/// message (a `ValueError`).
pub fn decode_utf8(content: &[u8]) -> crate::Result<&str> {
    std::str::from_utf8(content).map_err(|error| {
        let start = error.valid_up_to();
        let message = match error.error_len() {
            None if content.len() - start > 1 => format!(
                "can't decode bytes in position {start}-{}: unexpected end of data",
                content.len() - 1
            ),
            None => format!(
                "can't decode byte 0x{:02x} in position {start}: unexpected end of data",
                content[start]
            ),
            Some(_) => {
                let byte = content[start];
                let reason = if (0xc2..=0xf4).contains(&byte) {
                    "invalid continuation byte"
                } else {
                    "invalid start byte"
                };
                format!("can't decode byte 0x{byte:02x} in position {start}: {reason}")
            }
        };
        crate::Error::value(format!("'utf-8' codec {message}"))
    })
}

/// Python's `text.strip("\"'")`.
pub fn strip_quotes(text: &str) -> &str {
    text.trim_matches(|character| character == '"' || character == '\'')
}

/// Python's `text.partition(":")` as `(head, found, tail)`.
pub fn partition<'t>(text: &'t str, separator: &str) -> (&'t str, bool, &'t str) {
    match text.split_once(separator) {
        Some((head, tail)) => (head, true, tail),
        None => (text, false, ""),
    }
}

/// `"\n".join(lines).rstrip("\n") + "\n"`: the canonical ending every
/// ticket and note writer gives its Markdown.
pub fn join_lines_with_final_newline<S: AsRef<str>>(lines: &[S]) -> String {
    let mut joined = String::new();
    for (index, line) in lines.iter().enumerate() {
        if index > 0 {
            joined.push('\n');
        }
        joined.push_str(line.as_ref());
    }
    let mut trimmed = joined.trim_end_matches('\n').to_string();
    trimmed.push('\n');
    trimmed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitlines_breaks_where_python_does() {
        assert_eq!(splitlines(""), Vec::<&str>::new());
        assert_eq!(splitlines("a"), vec!["a"]);
        assert_eq!(splitlines("a\n"), vec!["a"]);
        assert_eq!(splitlines("a\n\n"), vec!["a", ""]);
        assert_eq!(splitlines("a\r\nb\rc\n"), vec!["a", "b", "c"]);
        assert_eq!(splitlines("\r\r\n"), vec!["", ""]);
        assert_eq!(
            splitlines("a\u{b}b\u{c}c\u{1c}d\u{1d}e\u{1e}f\u{85}g\u{2028}h\u{2029}i"),
            vec!["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        );
        // U+001F is whitespace to Python but not a line boundary.
        assert_eq!(splitlines("a\u{1f}b"), vec!["a\u{1f}b"]);
    }

    #[test]
    fn int_reads_any_script_like_python() {
        assert_eq!(int(" 42 "), Some(42));
        assert_eq!(int("-1_000"), Some(-1000));
        assert_eq!(int("+0"), Some(0));
        assert_eq!(int("\u{663}\u{665}"), Some(35));
        assert_eq!(int("\u{ff11}\u{ff10}"), Some(10));
        assert_eq!(int("\u{1d7d9}"), Some(1));
        for refused in ["", "_1", "1_", "1__0", "1.0", "0x1", "- 1", "\u{bc}"] {
            assert_eq!(int(refused), None, "{refused:?}");
        }
    }

    #[test]
    fn joins_with_one_final_newline() {
        assert_eq!(join_lines_with_final_newline(&["a", "", ""]), "a\n");
        assert_eq!(join_lines_with_final_newline::<&str>(&[]), "\n");
        assert_eq!(join_lines_with_final_newline(&["a", "b"]), "a\nb\n");
    }

    #[test]
    fn partition_and_quote_strip() {
        assert_eq!(partition("a: b: c", ":"), ("a", true, " b: c"));
        assert_eq!(partition("abc", ":"), ("abc", false, ""));
        assert_eq!(strip_quotes("\"'x'\""), "x");
        assert_eq!(strip_quotes("\"\""), "");
    }
}
