//! A board's `.orchestrator/config.toml` ticket counter, as
//! `services/orchestrator.py` reads and rewrites it.
//!
//! The rewrite is textual, so every other byte of the file survives: on a
//! legacy board `_ticket_config` and `_write_ticket_config_next_id`, on an
//! artifact board the `next_id` substitution in `_claim_artifact_board_id`,
//! whose result is committed as a `ConfigWrite`.

use std::sync::LazyLock;

use fancy_regex::Regex;

use crate::{Error, Result, pystr, toml};

// Python `str` patterns with re.MULTILINE: `\s` also matches U+001C to
// U+001F, and `$` matches before every newline and at the end.
static PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?m)^[\s\x1c-\x1f]*prefix[\s\x1c-\x1f]*=[\s\x1c-\x1f]*["']?([A-Za-z][A-Za-z0-9]*)["']?[\s\x1c-\x1f]*$"#,
    )
    .expect("prefix pattern")
});
static NEXT_ID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^([\s\x1c-\x1f]*next_id[\s\x1c-\x1f]*=[\s\x1c-\x1f]*)(\d+)([\s\x1c-\x1f]*)$")
        .expect("next_id pattern")
});
static ARTIFACT_NEXT_ID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^next_id[\s\x1c-\x1f]*=[\s\x1c-\x1f]*[^\n]+$").expect("next_id line pattern")
});
static ALPHANUMERIC: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[\p{L}\p{N}]+\z").expect("isalnum pattern"));

/// `_ticket_config`'s parse of the text: the upper-cased prefix and `next_id`.
pub fn ticket_config(text: &str) -> Result<(String, i64)> {
    let prefix = PREFIX.captures(text).ok().flatten();
    let next = NEXT_ID.captures(text).ok().flatten();
    let (Some(prefix), Some(next)) = (prefix, next) else {
        return Err(Error::value(
            "invalid .orchestrator/config.toml: expected prefix and next_id",
        ));
    };
    let digits = &next[2];
    let next_id = pystr::int(digits).ok_or_else(|| {
        Error::value(format!(
            "invalid literal for int() with base 10: {}",
            pystr::repr(digits)
        ))
    })?;
    Ok((prefix[1].to_uppercase(), next_id))
}

/// The text `_write_ticket_config_next_id` writes: the first `next_id` line
/// set to `next_id`, its surrounding whitespace kept, and a final newline.
pub fn with_next_id(text: &str, next_id: i64) -> String {
    let mut updated = match NEXT_ID.captures(text).ok().flatten() {
        Some(found) => {
            let whole = found.get(0).expect("group 0");
            format!(
                "{}{}{next_id}{}{}",
                &text[..whole.start()],
                &found[1],
                &found[3],
                &text[whole.end()..]
            )
        }
        None => text.to_string(),
    };
    if !updated.ends_with('\n') {
        updated.push('\n');
    }
    updated
}

/// An artifact board's claim of its next ticket id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Claim {
    pub prefix: String,
    pub next_id: i64,
    /// The config to commit, `next_id` advanced by one.
    pub config: String,
}

/// `_claim_artifact_board_id`'s reading and rewrite of the artifact config.
pub fn claim_next_id(content: &[u8]) -> Result<Claim> {
    let text = pystr::decode_utf8(content)
        .map_err(|error| Error::value(format!("artifact config is invalid: {error}")))?;
    let config = toml::loads(text)
        .map_err(|error| Error::value(format!("artifact config is invalid: {error}")))?;
    let prefix = config
        .get("prefix")
        .filter(|value| value.truthy())
        .map(toml::Value::py_str)
        .unwrap_or_default();
    let prefix = pystr::strip(&prefix).to_string();
    // Python would also take a `next_id` beyond `i64`; no board reaches one.
    let next_id = match config.get("next_id") {
        Some(toml::Value::Integer(value)) if *value > 0 => Some(*value),
        _ => None,
    };
    let valid_prefix = !prefix.is_empty() && ALPHANUMERIC.is_match(&prefix).unwrap_or(false);
    let (true, Some(next_id)) = (valid_prefix, next_id) else {
        return Err(Error::value("artifact config has no valid prefix/next_id"));
    };
    let Some(found) = ARTIFACT_NEXT_ID.find(text).ok().flatten() else {
        return Err(Error::value("artifact config next_id is ambiguous"));
    };
    let config = format!(
        "{}next_id = {}{}",
        &text[..found.start()],
        next_id + 1,
        &text[found.end()..]
    );
    Ok(Claim {
        prefix,
        next_id,
        config,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_rewrites_the_legacy_counter() {
        let text = "prefix = \"rr\"\n  next_id =  41  \n# next_id = 9\n";
        assert_eq!(ticket_config(text).unwrap(), ("RR".to_string(), 41));
        assert_eq!(
            with_next_id(text, 42),
            "prefix = \"rr\"\n  next_id =  42  \n# next_id = 9\n"
        );
        assert_eq!(
            with_next_id("prefix = 'A'\nnext_id = 1", 2),
            "prefix = 'A'\nnext_id = 2\n"
        );
        assert!(ticket_config("next_id = 1\n").is_err());
    }

    #[test]
    fn claims_the_artifact_counter() {
        let config = b"schema_version = 2\nproject_id = \"p\"\nprefix = \"CT\"\nnext_id = 2\n";
        let claim = claim_next_id(config).unwrap();
        assert_eq!(claim.prefix, "CT");
        assert_eq!(claim.next_id, 2);
        assert_eq!(
            claim.config,
            "schema_version = 2\nproject_id = \"p\"\nprefix = \"CT\"\nnext_id = 3\n"
        );
        for refused in [
            &b"prefix = \"C-T\"\nnext_id = 2\n"[..],
            b"prefix = \"CT\"\nnext_id = true\n",
            b"prefix = \"CT\"\nnext_id = 0\n",
            b"prefix = \"CT\"\n",
            b"prefix = \"CT\"\n next_id = 2\n",
        ] {
            assert!(claim_next_id(refused).is_err());
        }
    }
}
