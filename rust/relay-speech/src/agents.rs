//! RR-520: each named agent speaks in its own voice. This is the one Rust map
//! from agent to Kokoro voice; `SessionAgent.voiceID` is the Swift side, and
//! `tests/fixtures/session_agent_voices.json` pins both to the same pairs.
//!
//! A speak request names its session key. The session's spool directory,
//! `<sessions root>/<session key>/`, holds `session_agent` with the agent's
//! slug (written by the app before the provider starts). Speech with no
//! session, or a session without that file, is Puck's.

use std::path::{Path, PathBuf};

/// `(slug, voice)` in table order.
pub const AGENT_VOICES: [(&str, &str); 4] = [
    ("puck", "am_puck"),
    ("isabella", "bf_isabella"),
    ("george", "bm_george"),
    ("sky", "af_sky"),
];

/// Puck's voice: the voice of speech no agent owns.
pub const DEFAULT_VOICE: &str = AGENT_VOICES[0].1;

const SPOOL_FILE: &str = "session_agent";

/// The session spools' parent, as the bridge resolves it:
/// `$RELAY_BRIDGE_RUNTIME_DIR/relay-sessions`, else `/tmp/relay-sessions`.
pub fn sessions_root_from_environment() -> PathBuf {
    let runtime = std::env::var("RELAY_BRIDGE_RUNTIME_DIR")
        .ok()
        .filter(|dir| !dir.is_empty())
        .unwrap_or_else(|| "/tmp".to_string());
    Path::new(&runtime).join("relay-sessions")
}

/// The voice of the agent with `slug`; Puck's for an unknown slug.
pub fn voice_for_agent(slug: &str) -> &'static str {
    AGENT_VOICES
        .iter()
        .find(|(agent, _)| *agent == slug)
        .map_or(DEFAULT_VOICE, |(_, voice)| voice)
}

/// The voice of the agent that owns `session_key`, read from its spool.
pub fn voice_for_session(sessions_root: &Path, session_key: &str) -> &'static str {
    let key = session_key.trim();
    // Spool keys are sanitized by the app; anything else is not a spool.
    let is_spool_key = !key.is_empty()
        && key.len() <= 64
        && key
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
    if !is_spool_key {
        return DEFAULT_VOICE;
    }
    std::fs::read_to_string(sessions_root.join(key).join(SPOOL_FILE))
        .map_or(DEFAULT_VOICE, |slug| voice_for_agent(slug.trim()))
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A temporary sessions root; each `(key, slug)` gets a spool naming its agent.
    pub fn sessions_root(spools: &[(&str, Option<&str>)]) -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "relay-speech-agents-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&root);
        for (key, slug) in spools {
            let spool = root.join(key);
            std::fs::create_dir_all(&spool).unwrap();
            if let Some(slug) = slug {
                std::fs::write(spool.join(SPOOL_FILE), format!("{slug}\n")).unwrap();
            }
        }
        root
    }

    #[test]
    fn the_map_matches_the_swift_agent_table() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/session_agent_voices.json"
        ))
        .unwrap();
        let pinned: Vec<(String, String)> = fixture["agents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|agent| {
                (
                    agent["slug"].as_str().unwrap().to_string(),
                    agent["voice"].as_str().unwrap().to_string(),
                )
            })
            .collect();
        let map: Vec<(String, String)> = AGENT_VOICES
            .iter()
            .map(|(slug, voice)| (slug.to_string(), voice.to_string()))
            .collect();
        assert_eq!(map, pinned);
        assert_eq!(DEFAULT_VOICE, "am_puck");
    }

    #[test]
    fn each_session_speaks_in_its_agents_voice() {
        let root = sessions_root(&[
            ("transport-george", Some("george")),
            ("transport-sky", Some("sky")),
            ("transport-isabella", Some("isabella")),
            ("manual", None),
            ("stray", Some("oberon")),
        ]);
        assert_eq!(voice_for_session(&root, "transport-george"), "bm_george");
        assert_eq!(voice_for_session(&root, "transport-sky"), "af_sky");
        assert_eq!(
            voice_for_session(&root, "transport-isabella"),
            "bf_isabella"
        );
        // No session, no agent file, an unknown agent or a missing spool: Puck.
        assert_eq!(voice_for_session(&root, ""), "am_puck");
        assert_eq!(voice_for_session(&root, "manual"), "am_puck");
        assert_eq!(voice_for_session(&root, "stray"), "am_puck");
        assert_eq!(voice_for_session(&root, "gone"), "am_puck");
        // A key that is not a spool name never leaves the root.
        assert_eq!(voice_for_session(&root, "../transport-sky"), "am_puck");
        let _ = std::fs::remove_dir_all(root);
    }
}
