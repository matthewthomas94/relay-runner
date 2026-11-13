//! Dependency-free, provisional Task / Action / Discussion qualification:
//! `services/intent_qualification.py`.
//!
//! Buckets describe a turn, never grant permission. The PM receives the
//! original turn and keeps authority; control and cancellation keep their
//! own path. The Python `qualify_intent` classifies the command itself when
//! no action kind is given; here the caller always passes the kind, because
//! command classification (`command_actions.py`) is not part of this crate.

use std::sync::LazyLock;

use fancy_regex::Regex;

use crate::json::{self, Dict};
use crate::model::wire_enum;
use crate::pattern::{self, compile, match_start, search};

static POLITE_LEAD: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"^\s*(?:(?:hey|hi|okay|ok|so|please)\b[,!\s]*)*(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?",
        true,
    )
});
static DISCUSSION_ONLY: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:only|just)\s+(?:(?:want|wanted|would\s+like)\s+)?(?:to\s+)?",
            r"(?:discuss|talk\s+(?:through|about)|research|explore|consider|understand)\b",
            r"|\b(?:this\s+is|it['’]?s)\s+(?:only|just)\s+(?:a\s+)?(?:discussion|research|question)\b",
            r"|\b(?:do\s+not|don['’]?t)\s+(?:implement|execute|build|change|do|start)\s+",
            r"(?:it|this|anything|any\s+work)(?:\s+yet)?(?:[.!?,;]|$)",
            r"|\b(?:do\s+not|don['’]?t)\s+(?:implement|execute|act)(?:\s+yet)?(?:[.!?,;]|$)",
        ),
        true,
    )
});
static ASSENT: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\A(?:^\s*(?:(?:yes|yeah|yep|okay|ok|sure)[,!\s]*)?",
            r"(?:do\s+(?:that|it)|go\s+ahead|proceed|continue)?[.!?\s]*$)\z",
        ),
        true,
    )
});
static ACTION: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^(?:open|launch|reveal|bring\s+up|focus|switch\s+to|close|quit|click|",
            r"double[- ]click|right[- ]click|scroll|press|tap|drag|type|select)\b",
            r"|^(?:start|stop|restart|run|spin\s+up)\s+(?:(?:a|the|our|my)\s+)?",
            r"(?:dev(?:elopment)?\s+server|localhost\s+server)\b",
            r"|^(?:send|write|draft|compose)\s+(?:(?:a|an|the)\s+)?(?:email|e-mail|message)\b",
        ),
        true,
    )
});
static CLAUSE_BREAK: LazyLock<Regex> =
    LazyLock::new(|| compile(r"[;.!?]\s+|\s+(?:and\s+then|then|and|but)\s+", true));
static WORK_LEAD: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^(?:fix|build|implement|refactor|create\s+(?:(?:a|the)\s+)?(?:ticket|spike)|",
            r"dispatch|delegate|update|add|remove|write|test)\b",
        ),
        true,
    )
});
static DISCUSSION_LEAD: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"^(?:discuss|research|explore|explain|why|how|what|was|should)\b",
        true,
    )
});
static NO_DISPATCH: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:do\s+not|don['’]?t|never)\s+(?:dispatch|implement|execute|start\s+(?:a\s+)?worker)\b",
            r"|\bbacklog\s+only\b|\bonly\s+(?:create|write|draft)\s+(?:a\s+)?ticket\b",
        ),
        true,
    )
});
static TICKET_AUTHORING: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(?:create|write|draft)\s+(?:a\s+)?ticket\b", true));
static NEGATION_LEAD: LazyLock<Regex> =
    LazyLock::new(|| compile(r"(?:do\s+not|don['’]?t)\b", true));

pub fn dispatch_forbidden(text: &str) -> bool {
    search(&NO_DISPATCH, text)
}

pub fn foreground_action_requested(text: &str) -> bool {
    search(&ACTION, &pattern::sub(&POLITE_LEAD, text, 1))
}

/// Recognises whole-turn research constraints, not scoped implementation
/// limits: "Create a ticket; do not implement it" still authorises ticket
/// authoring.
pub fn discussion_only_requested(text: &str) -> bool {
    let matches: Vec<&str> = pattern::find_all(&DISCUSSION_ONLY, text);
    if matches.is_empty() {
        return false;
    }
    if search(&TICKET_AUTHORING, text) {
        return matches
            .iter()
            .any(|found| !match_start(&NEGATION_LEAD, found));
    }
    true
}

pub fn context_dependent_assent(text: &str) -> bool {
    !json::py_strip(text).is_empty() && search(&ASSENT, text)
}

/// Whether the turn joins recognisably different operations, which are
/// deferred with their full ordered wording.
pub fn mixed_bucket_request(text: &str) -> bool {
    let mut action = false;
    let mut task = false;
    let mut discussion = false;
    for clause in pattern::split(&CLAUSE_BREAK, text) {
        let clause = pattern::sub(&POLITE_LEAD, json::py_strip(clause), 1);
        if search(&ACTION, &clause) {
            action = true;
        } else if search(&WORK_LEAD, &clause) {
            task = true;
        } else if search(&DISCUSSION_LEAD, &clause) {
            discussion = true;
        }
    }
    [action, task, discussion]
        .iter()
        .filter(|seen| **seen)
        .count()
        > 1
}

pub fn whole_turn_resolution_required(text: &str) -> bool {
    discussion_only_requested(text) || mixed_bucket_request(text) || dispatch_forbidden(text)
}

wire_enum! {
    /// The provisional bucket of a turn; a control turn has none.
    QualificationBucket {
        Action => "action",
        Task => "task",
        Discussion => "discussion",
        Undecided => "undecided",
    }
}

/// A provisional, deterministic qualification of one turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IntentQualification {
    pub bucket: Option<QualificationBucket>,
    pub source: String,
    pub unresolved: bool,
    pub mixed: bool,
    pub reason: String,
    pub command_id: Option<String>,
    pub command_seq: Option<i64>,
}

impl IntentQualification {
    /// `to_dict()`, in field order.
    pub fn to_dict(&self) -> Dict {
        let mut payload = Dict::new();
        payload.insert("bucket", self.bucket.map(QualificationBucket::as_str));
        payload.insert("source", self.source.as_str());
        payload.insert("unresolved", self.unresolved);
        payload.insert("mixed", self.mixed);
        payload.insert("reason", self.reason.as_str());
        payload.insert("command_id", self.command_id.clone());
        payload.insert("command_seq", self.command_seq);
        payload
    }
}

/// Qualifies a turn without inference or effects. A bare assent cannot be
/// resolved safely by a text-only rule, so it stays unresolved rather than
/// manufacturing authorisation.
pub fn qualify_intent(
    text: &str,
    action_kind: &str,
    action_reason: Option<&str>,
    command_id: Option<&str>,
    command_seq: Option<i64>,
) -> IntentQualification {
    let assent = context_dependent_assent(text);
    let mut mixed = mixed_bucket_request(text) && !discussion_only_requested(text);
    let mut unresolved = mixed || assent || json::py_strip(text).is_empty();
    let reason_text = action_reason.unwrap_or("");
    let bucket = match action_kind {
        "control" => {
            unresolved = false;
            mixed = false;
            None
        }
        "direct_action" | "inline_work" => Some(QualificationBucket::Action),
        _ if reason_text == "route_undecided" => {
            unresolved = true;
            Some(QualificationBucket::Undecided)
        }
        "create_ticket" | "update_ticket" | "dispatch_ticket" | "needs_project" => {
            Some(QualificationBucket::Task)
        }
        _ => Some(QualificationBucket::Discussion),
    };
    let reason = if assent {
        "context_required"
    } else if !reason_text.is_empty() {
        reason_text
    } else {
        action_kind
    };
    IntentQualification {
        bucket,
        source: "deterministic".to_string(),
        unresolved,
        mixed,
        reason: reason.to_string(),
        command_id: command_id.map(str::to_string),
        command_seq,
    }
}

/// The qualification block appended to the agent prompt.
pub fn format_qualification_for_agent(qualification: &IntentQualification) -> String {
    let bucket = qualification
        .bucket
        .map_or("control", QualificationBucket::as_str);
    let command_id = qualification.command_id.as_deref().unwrap_or("None");
    let command_seq = qualification
        .command_seq
        .map_or_else(|| "None".to_string(), |seq| seq.to_string());
    format!(
        "\n\nRelay intent qualification (provisional):\n\
         - bucket: {bucket}\n\
         - source: {}\n\
         - unresolved: {}\n\
         - mixed: {}\n\
         - command_id: {command_id}\n\
         - command_seq: {command_seq}\n\
         - The PM qualifies the full original turn and may correct this hint. \
         Task means authorized project, substantial General or tracked work; Action means a bounded foreground operation; \
         Discussion includes research and status with read-only tools. \
         Undecided means a change request without a route signal: decide by size, or ask the user which route they want.\n\
         - This bucket does not authorize any effect. Apply whole-turn negations and corrections. \
         Resolve references and mixed scope from conversation; preserve ordered requests and existing accepted work. \
         Do not invent work from an assent, a discussion, or metadata. Ticket creation, dispatch, \
         implementation and sending a message each require their applicable user authority.",
        qualification.source, qualification.unresolved, qualification.mixed,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_turn_constraints_are_recognised() {
        assert!(discussion_only_requested(
            "Can you build this? I only want to discuss feasibility, do not implement it"
        ));
        assert!(!discussion_only_requested(
            "Create a ticket for dark mode; do not implement it"
        ));
        assert!(dispatch_forbidden("create a ticket but don't dispatch it"));
        assert!(foreground_action_requested(
            "hey, can you please open Chrome"
        ));
        assert!(!foreground_action_requested("tell me about Chrome"));
        assert!(mixed_bucket_request("open Chrome and fix the login bug"));
        assert!(!mixed_bucket_request(
            "fix the login bug and update the readme"
        ));
        assert!(context_dependent_assent("yes, do that"));
        assert!(context_dependent_assent("Go ahead."));
        assert!(!context_dependent_assent("   "));
        assert!(!context_dependent_assent("yes but first check the tests"));
    }

    #[test]
    fn buckets_follow_the_action_kind() {
        let qualify = |text, kind, reason| qualify_intent(text, kind, reason, Some("c"), Some(3));
        assert_eq!(qualify("stop", "control", None).bucket, None);
        assert_eq!(
            qualify("open Chrome", "direct_action", None).bucket,
            Some(QualificationBucket::Action)
        );
        let undecided = qualify(
            "make the button blue",
            "conversation",
            Some("route_undecided"),
        );
        assert_eq!(undecided.bucket, Some(QualificationBucket::Undecided));
        assert!(undecided.unresolved);
        assert_eq!(undecided.reason, "route_undecided");
        assert_eq!(
            qualify("create a ticket", "create_ticket", None).reason,
            "create_ticket"
        );
        let assent = qualify("yes do it", "conversation", None);
        assert_eq!(assent.reason, "context_required");
        assert!(assent.unresolved);
    }

    #[test]
    fn the_agent_block_spells_python_values() {
        let qualification = qualify_intent("hello", "conversation", None, None, None);
        let block = format_qualification_for_agent(&qualification);
        assert!(
            block.starts_with(
                "\n\nRelay intent qualification (provisional):\n- bucket: discussion\n"
            )
        );
        assert!(block.contains(
            "- unresolved: false\n- mixed: false\n- command_id: None\n- command_seq: None\n"
        ));
        assert!(block.ends_with("each require their applicable user authority."));
    }
}
