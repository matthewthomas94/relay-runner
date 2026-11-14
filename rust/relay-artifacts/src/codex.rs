//! The Codex model-family names of `services/codex_model_catalog.py` that
//! configuration migration uses. Resolving a family to a concrete model
//! through the Codex app-server belongs with worker launch.

use std::sync::LazyLock;

use fancy_regex::Regex;
use relay_intents::pattern;

use crate::pystr;

pub const CODEX_FAMILIES: [&str; 4] = ["astra", "sol", "terra", "luna"];
pub const CODEX_DEFAULT_FAMILY: &str = "sol";
pub const CODEX_MESSENGER_DEFAULT_FAMILY: &str = "luna";

static FAMILY: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"^gpt-(?P<version>\d+(?:\.\d+)*)(?:-[a-z0-9]+)*-(?P<family>astra|sol|terra|luna)$",
        false,
    )
});

/// `normalize_codex_family(value, default_family=...)`, given `str(value or "")`:
/// a family name, the family of a concrete model id, or the default.
pub fn normalize_codex_family(value: &str, default_family: &str) -> String {
    codex_family_for_model(value).unwrap_or_else(|| default_family.to_string())
}

/// `codex_family_for_model(value)`, given `str(value or "")`.
pub fn codex_family_for_model(value: &str) -> Option<String> {
    let text = pystr::strip(value).to_lowercase();
    if CODEX_FAMILIES.contains(&text.as_str()) {
        return Some(text);
    }
    pattern::group(&FAMILY, &text, 2).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families_from_names_and_model_ids() {
        assert_eq!(normalize_codex_family(" Astra ", "sol"), "astra");
        assert_eq!(normalize_codex_family("gpt-6.1-codex-luna", "sol"), "luna");
        assert_eq!(normalize_codex_family("gpt-6", "luna"), "luna");
        assert_eq!(normalize_codex_family("default", "sol"), "sol");
        assert_eq!(
            codex_family_for_model("gpt-6-terra"),
            Some("terra".to_string())
        );
        assert_eq!(codex_family_for_model("opus"), None);
    }
}
