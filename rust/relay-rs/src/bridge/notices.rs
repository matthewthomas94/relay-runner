//! Agent notices on a session's next turn (RR-525).
//!
//! The daemon queues notices per receiving session; this module claims a
//! session's undelivered notices once through `POST /v1/agent-notices/claim`
//! and renders them with `relay_services::agent_notices`. The bridge appends
//! the block to a voice turn's prompt (`prompt_with_agent_notices`), and the
//! prompt-submit hook adds it as context to a typed turn
//! (`prompt_submit_context`). Neither path speaks a notice, hands it to the
//! messenger or types it into a terminal on its own: it rides only on a turn
//! the user started.

use relay_services::agent_notices::{append_notice_block, notice_block_from_claim};

use super::targets::valid_session_key;
use crate::json::{self, Dict, Value};

pub use super::orchestrator::{Daemon, LocalDaemon};

/// The daemon route that hands a session its notices, once.
pub const CLAIM_PATH: &str = "/v1/agent-notices/claim";

/// `session_key`'s undelivered notices as one block, claimed so no later
/// turn repeats them; `""` when there are none, the key is not a session
/// key or the daemon does not answer.
pub fn claim_notice_block(session_key: &str, daemon: &dyn Daemon) -> String {
    if !valid_session_key(session_key) {
        return String::new();
    }
    let mut payload = Dict::new();
    payload.insert("relay_session_key", session_key);
    match daemon.post_json(CLAIM_PATH, &payload) {
        Ok(answer) => notice_block_from_claim(&answer),
        Err(error) => {
            eprintln!("[voice_bridge] Agent notices unavailable: {error}");
            String::new()
        }
    }
}

/// A voice turn's prompt for `session_key`, with that session's pending
/// agent notices appended the way the work-intent disposition block is.
pub fn prompt_with_agent_notices(prompt: &str, session_key: &str, daemon: &dyn Daemon) -> String {
    append_notice_block(prompt, &claim_notice_block(session_key, daemon))
}

/// The prompt-submit hook's stdout for a typed turn: the provider's
/// `UserPromptSubmit` JSON with the notices as `additionalContext`, or
/// `None` when there is nothing to add. Claude Code and Codex both read
/// this form; neither shows it to the user as a reply.
pub fn prompt_submit_context(session_key: &str, daemon: &dyn Daemon) -> Option<String> {
    let block = claim_notice_block(session_key, daemon);
    if block.is_empty() {
        return None;
    }
    let mut specific = Dict::new();
    specific.insert("hookEventName", "UserPromptSubmit");
    specific.insert("additionalContext", block);
    let mut output = Dict::new();
    output.insert("hookSpecificOutput", Value::Dict(specific));
    Some(json::dumps_compact(&Value::Dict(output)))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::super::orchestrator::DaemonError;
    use super::*;

    /// A daemon holding one session's queue, which a claim empties.
    struct QueueDaemon {
        session_key: String,
        pending: Mutex<Vec<String>>,
        omitted: i64,
        calls: Mutex<Vec<(String, Dict)>>,
    }

    impl QueueDaemon {
        fn new(session_key: &str, pending: &[&str], omitted: i64) -> Self {
            Self {
                session_key: session_key.to_string(),
                pending: Mutex::new(pending.iter().map(|text| text.to_string()).collect()),
                omitted,
                calls: Mutex::default(),
            }
        }
    }

    impl Daemon for QueueDaemon {
        fn post_json(&self, path: &str, payload: &Dict) -> Result<Dict, DaemonError> {
            self.calls
                .lock()
                .unwrap()
                .push((path.to_string(), payload.clone()));
            let mut answer = Dict::new();
            let mut notices = Vec::new();
            let mut omitted = 0;
            if path == CLAIM_PATH && payload.text("relay_session_key") == self.session_key {
                let mut pending = self.pending.lock().unwrap();
                for text in pending.drain(..) {
                    let mut notice = Dict::new();
                    notice.insert("text", text);
                    notices.push(Value::Dict(notice));
                }
                if !notices.is_empty() {
                    omitted = self.omitted;
                }
            }
            answer.insert("notices", Value::List(notices));
            answer.insert("omitted_notices", omitted);
            Ok(answer)
        }

        fn get_json(&self, _path: &str, _params: &Dict) -> Result<Dict, DaemonError> {
            Ok(Dict::new())
        }
    }

    struct DownDaemon;

    impl Daemon for DownDaemon {
        fn post_json(&self, _path: &str, _payload: &Dict) -> Result<Dict, DaemonError> {
            Err(DaemonError::TimedOut)
        }

        fn get_json(&self, _path: &str, _params: &Dict) -> Result<Dict, DaemonError> {
            Err(DaemonError::TimedOut)
        }
    }

    #[test]
    fn a_voice_turn_carries_pending_notices_once() {
        let daemon = QueueDaemon::new(
            "puck-1",
            &["Agent notice: George started working in relay-runner (dispatched RR-530)."],
            0,
        );
        let first = prompt_with_agent_notices("what's next?", "puck-1", &daemon);
        assert!(
            first.starts_with("what's next?\n\nAgent notices ("),
            "{first}"
        );
        assert!(first.ends_with(
            "\n- Agent notice: George started working in relay-runner (dispatched RR-530)."
        ));
        let second = prompt_with_agent_notices("and then?", "puck-1", &daemon);
        assert_eq!(second, "and then?");
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert!(
            calls.iter().all(|(path, payload)| path == CLAIM_PATH
                && payload.text("relay_session_key") == "puck-1")
        );
    }

    #[test]
    fn more_than_ten_pending_shows_the_newest_ten_and_a_count() {
        let pending: Vec<String> = (3..13)
            .map(|index| format!("Agent notice: George started working in repo-{index:02}."))
            .collect();
        let pending: Vec<&str> = pending.iter().map(String::as_str).collect();
        let daemon = QueueDaemon::new("puck-1", &pending, 3);
        let prompt = prompt_with_agent_notices("status?", "puck-1", &daemon);
        assert_eq!(prompt.matches("\n- Agent notice: ").count(), 10);
        assert!(prompt.contains("repo-03") && prompt.contains("repo-12"));
        assert!(prompt.ends_with("\n- 3 older agent notices not shown."));
    }

    #[test]
    fn no_session_key_or_no_daemon_leaves_the_prompt_alone() {
        let daemon = QueueDaemon::new("puck-1", &["Agent notice: Sky stopped."], 0);
        assert_eq!(prompt_with_agent_notices("hi", "", &daemon), "hi");
        assert_eq!(prompt_with_agent_notices("hi", "Not A Key", &daemon), "hi");
        assert!(daemon.calls.lock().unwrap().is_empty());
        assert_eq!(prompt_with_agent_notices("hi", "puck-1", &DownDaemon), "hi");
    }

    #[test]
    fn a_typed_turn_gets_the_notices_as_prompt_submit_context() {
        let daemon = QueueDaemon::new("puck-1", &["Agent notice: Sky stopped."], 0);
        let output = prompt_submit_context("puck-1", &daemon).unwrap();
        let Some(Value::Dict(parsed)) = json::parse(&output) else {
            panic!("not JSON: {output}");
        };
        let specific = parsed.get("hookSpecificOutput").unwrap().as_dict().unwrap();
        assert_eq!(specific.text("hookEventName"), "UserPromptSubmit");
        let context = specific.text("additionalContext");
        assert!(context.starts_with("Agent notices ("));
        assert!(context.ends_with("- Agent notice: Sky stopped."));
        // Only the one provider-defined key: Codex's schema allows no others.
        assert_eq!(parsed.len(), 1);
        assert_eq!(specific.len(), 2);
        assert_eq!(prompt_submit_context("puck-1", &daemon), None);
        assert_eq!(prompt_submit_context("puck-1", &DownDaemon), None);
    }

    /// RR-526: overlap and action notices share the queue and delivery, so
    /// they too ride only on a turn the user started, as one block, once.
    #[test]
    fn action_notices_ride_only_on_a_users_turn() {
        let daemon = QueueDaemon::new(
            "puck-1",
            &[
                "Agent notice: George started working in relay-runner, where you are working too \
                 (tickets: RR-602).",
                "Agent notice: George edited ticket RR-602 \"Bridge fix\" in relay-runner (3 \
                 edits).",
                "Agent notice: George's run of RR-602 in relay-runner merged into the checkout.",
            ],
            0,
        );
        // Queued notices alone touch nothing: no claim without a turn.
        assert!(daemon.calls.lock().unwrap().is_empty());
        let output = prompt_submit_context("puck-1", &daemon).unwrap();
        assert_eq!(output.matches("Agent notices (").count(), 1);
        assert!(output.contains("merged into the checkout"));
        assert_eq!(
            prompt_with_agent_notices("next?", "puck-1", &daemon),
            "next?"
        );
        assert_eq!(daemon.calls.lock().unwrap().len(), 2);
    }

    /// No speech, messenger, reply or terminal path names agent notices: a
    /// notice reaches a provider only inside a turn's prompt or the
    /// prompt-submit hook's context.
    #[test]
    fn no_spoken_or_typed_path_handles_notices() {
        let silent = [
            ("messenger_runtime.rs", include_str!("messenger_runtime.rs")),
            ("speech.rs", include_str!("speech.rs")),
            ("speech_client.rs", include_str!("speech_client.rs")),
            ("traces.rs", include_str!("traces.rs")),
            ("finals.rs", include_str!("finals.rs")),
            ("replies.rs", include_str!("replies.rs")),
            ("pm_frontstage.rs", include_str!("pm_frontstage.rs")),
            ("sidecar.rs", include_str!("sidecar.rs")),
            ("controls.rs", include_str!("controls.rs")),
            ("../messenger/mod.rs", include_str!("../messenger/mod.rs")),
            (
                "../messenger/claude.rs",
                include_str!("../messenger/claude.rs"),
            ),
            (
                "../messenger/codex.rs",
                include_str!("../messenger/codex.rs"),
            ),
            ("../reply.rs", include_str!("../reply.rs")),
        ];
        for (name, source) in silent {
            for marker in ["notice", "Agent notices"] {
                assert!(
                    !source.contains(marker),
                    "{name} mentions {marker:?}; agent notices must stay out of speech, the \
                     messenger and replies"
                );
            }
        }
        // The relay loop claims notices only to append them to a published
        // prompt, after the messenger has already been given the user text.
        let relay = include_str!("relay.rs");
        let claim = relay.find("prompt_with_agent_notices").unwrap();
        let publish = relay[claim..].find("commands::publish_command").unwrap();
        assert!(relay[..claim].contains("submit_user"));
        assert!(
            relay[claim + publish..]
                .find("prompt_with_agent_notices")
                .is_none()
        );
    }
}
