//! Python `re` patterns, compiled with their Python meaning.
//!
//! `fancy_regex` reads Python's syntax, lookaround included, and searches
//! leftmost-first with backtracking as `re` does. Two spellings mean something
//! else there, so `compile` rewrites them: `$` without `re.MULTILINE` also
//! matches before one final newline, and `\s` in a `str` pattern also matches
//! the separators U+001C to U+001F. `\w` and `\d` follow Unicode in both, from
//! slightly different tables; no voice-turn pattern relies on the difference.

use fancy_regex::Regex;

/// Compiles a Python pattern, with `re.IGNORECASE` when `ignore_case`.
pub fn compile(pattern: &str, ignore_case: bool) -> Regex {
    let mut translated = String::with_capacity(pattern.len() + 16);
    if ignore_case {
        translated.push_str("(?i)");
    }
    let mut in_class = false;
    let mut characters = pattern.chars();
    while let Some(character) = characters.next() {
        match character {
            '\\' => match characters.next() {
                Some('s') if in_class => translated.push_str(r"\s\x1c-\x1f"),
                Some('s') => translated.push_str(r"[\s\x1c-\x1f]"),
                Some(escaped) => {
                    translated.push('\\');
                    translated.push(escaped);
                }
                None => translated.push('\\'),
            },
            '[' if !in_class => {
                in_class = true;
                translated.push('[');
            }
            ']' if in_class => {
                in_class = false;
                translated.push(']');
            }
            '$' if !in_class => translated.push_str(r"(?=\n?\z)"),
            other => translated.push(other),
        }
    }
    Regex::new(&translated).unwrap_or_else(|error| panic!("invalid pattern {pattern:?}: {error}"))
}

/// `pattern.search(text) is not None`. A search that exceeds the backtracking
/// limit counts as no match; no voice turn comes near it.
pub fn search(pattern: &Regex, text: &str) -> bool {
    pattern.is_match(text).unwrap_or(false)
}

/// `pattern.search(text).group(index)`, when the search matches and the
/// group took part.
pub fn group<'t>(pattern: &Regex, text: &'t str, index: usize) -> Option<&'t str> {
    let found = pattern.captures(text).ok().flatten()?;
    found.get(index).map(|group| group.as_str())
}

/// `pattern.findall(text)` for a pattern without groups.
pub fn find_all<'t>(pattern: &Regex, text: &'t str) -> Vec<&'t str> {
    pattern
        .find_iter(text)
        .map_while(Result::ok)
        .map(|found| found.as_str())
        .collect()
}

/// `pattern.split(text)` for a pattern without groups that never matches
/// the empty string.
pub fn split<'t>(pattern: &Regex, text: &'t str) -> Vec<&'t str> {
    let mut pieces = Vec::new();
    let mut last = 0;
    for found in pattern.find_iter(text).map_while(Result::ok) {
        pieces.push(&text[last..found.start()]);
        last = found.end();
    }
    pieces.push(&text[last..]);
    pieces
}

/// `pattern.sub("", text, count=count)`; a `count` of 0 replaces every match.
pub fn sub(pattern: &Regex, text: &str, count: usize) -> String {
    pattern.replacen(text, count, "").into_owned()
}

/// `pattern.match(text)`: a match that starts at the beginning.
pub fn match_start(pattern: &Regex, text: &str) -> bool {
    pattern
        .find(text)
        .ok()
        .flatten()
        .is_some_and(|found| found.start() == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dollar_also_matches_before_a_final_newline() {
        let pattern = compile(r"done$", false);
        assert!(search(&pattern, "done"));
        assert!(search(&pattern, "done\n"));
        assert!(!search(&pattern, "done\n\n"));
        assert!(!search(&pattern, "done now"));
        // Inside a class `$` stays a literal.
        assert!(search(&compile(r"[$]", false), "costs $5"));
    }

    #[test]
    fn whitespace_includes_the_ascii_separators() {
        assert!(search(&compile(r"a\sb", false), "a\u{1f}b"));
        assert!(search(&compile(r"a[,\s]b", false), "a\u{1c}b"));
        assert!(search(&compile(r"a\sb", false), "a\u{a0}b"));
        assert!(!search(&compile(r"a\Sb", false), "a b"));
    }

    #[test]
    fn split_sub_and_find_follow_python() {
        let comma = compile(r"\s*,\s*", false);
        assert_eq!(split(&comma, "a , b,c"), vec!["a", "b", "c"]);
        assert_eq!(split(&comma, "abc"), vec!["abc"]);
        let word = compile(r"[a-z]+", false);
        assert_eq!(find_all(&word, "ab 12 cd"), vec!["ab", "cd"]);
        assert_eq!(sub(&word, "ab cd", 1), " cd");
        assert_eq!(sub(&word, "ab cd", 0), " ");
        let lead = compile(r"(?:do\s+not)\b", true);
        assert!(match_start(&lead, "Do not go"));
        assert!(!match_start(&lead, "I do not go"));
    }
}
