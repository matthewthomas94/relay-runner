//! Sentence splitting, the twin of `_sentence_chunks` in `services/tts_worker.py`.
//!
//! Python collapses every whitespace run to one space and then cuts after
//! `[.!?]+["')\]]*` wherever that is followed by whitespace or the end. From
//! any starting point the regular expression can only succeed with its longest
//! match (anything shorter ends on punctuation, not whitespace), so a scan for
//! the longest run at each terminator gives the same chunks.

/// Python's `str.isspace()`, which `\s` and `strip()` use: Unicode White_Space
/// plus the four ASCII information separators.
pub fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

fn is_terminator(c: char) -> bool {
    matches!(c, '.' | '!' | '?')
}

fn is_closer(c: char) -> bool {
    matches!(c, '"' | '\'' | ')' | ']')
}

/// `re.sub(r"\s+", " ", text.strip())`.
pub fn compact(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_space = false;
    for c in text.trim_matches(is_py_space).chars() {
        if is_py_space(c) {
            pending_space = true;
        } else {
            if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.push(c);
        }
    }
    out
}

/// Split text into sentence-sized chunks while preserving all text.
pub fn sentence_chunks(text: &str) -> Vec<String> {
    let compact = compact(text);
    let chars: Vec<(usize, char)> = compact.char_indices().collect();
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < chars.len() {
        if !is_terminator(chars[index].1) {
            index += 1;
            continue;
        }
        let mut end = index;
        while end < chars.len() && is_terminator(chars[end].1) {
            end += 1;
        }
        while end < chars.len() && is_closer(chars[end].1) {
            end += 1;
        }
        if end == chars.len() || is_py_space(chars[end].1) {
            let byte_end = chars.get(end).map_or(compact.len(), |&(at, _)| at);
            let chunk = compact[start..byte_end].trim_matches(is_py_space);
            if !chunk.is_empty() {
                chunks.push(chunk.to_string());
            }
            start = byte_end;
        }
        index = end;
    }
    let tail = compact[start..].trim_matches(is_py_space);
    if !tail.is_empty() {
        chunks.push(tail.to_string());
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `rust/relay-speech/tests/sentences.json` holds what the Python splitter
    /// makes of the RR-479 corpus and of the edge cases beside it;
    /// `tests/test_speech_sentence_fixture.py` keeps it in step with Python.
    #[test]
    fn matches_the_python_splitter_on_the_prototype_corpus() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/sentences.json")).unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert!(cases.len() > 57, "the corpus and the edge cases");
        for case in cases {
            let text = case["text"].as_str().unwrap();
            let expected: Vec<String> = case["chunks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|chunk| chunk.as_str().unwrap().to_string())
                .collect();
            assert_eq!(sentence_chunks(text), expected, "{text:?}");
        }
    }

    #[test]
    fn whitespace_collapses_and_empty_text_has_no_chunks() {
        assert_eq!(sentence_chunks("  \n\t "), Vec::<String>::new());
        assert_eq!(
            sentence_chunks("One.\n\nTwo?  Three"),
            ["One.", "Two?", "Three"]
        );
    }
}
