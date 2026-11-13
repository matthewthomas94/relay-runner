//! Provider-neutral arbitration for voice work received during active work:
//! `services/intent_arbitration.py`.
//!
//! Each pattern is the Python module's, compiled with the same meaning: see
//! `pattern::compile`.

use std::sync::LazyLock;

use fancy_regex::Regex;

use crate::json::{self, Dict, Value};
use crate::model::wire_enum;
use crate::pattern::{self, compile, find_all, search};

wire_enum! {
    /// The one safe route a voice intent takes relative to accepted work.
    IntentRoute {
        ContinueCurrent => "continue_current",
        RunSidecar => "run_sidecar",
        QueueProjectWork => "queue_project_work",
        ClarifyPriority => "clarify_priority",
        ReplaceCurrent => "replace_current",
        ControlOnly => "control_only",
    }
}

wire_enum! {
    /// What a route does to the mutation grants of accepted work.
    AuthorizationEffect {
        Preserve => "preserve",
        RevokeConflicting => "revoke_conflicting",
        None => "none",
    }
}

wire_enum! {
    /// How much accepted work a cancellation reaches.
    CancellationScope {
        None => "none",
        Item => "item",
        Ticket => "ticket",
        AllWork => "all_work",
        Ambiguous => "ambiguous",
    }
}

impl CancellationScope {
    /// `CancellationScope(str(value or "none"))`, with an unknown name read
    /// as `ambiguous`, as `resolve_intent_disposition` coerces it.
    pub fn from_wire(value: Option<&str>) -> Self {
        let text = value.filter(|text| !text.is_empty()).unwrap_or("none");
        Self::parse(text).unwrap_or(CancellationScope::Ambiguous)
    }
}

wire_enum! {
    /// A resource only one piece of work may hold.
    ExclusiveResource {
        Repository => "repository",
        Desktop => "desktop",
        ExternalSideEffect => "external_side_effect",
    }
}

wire_enum! {
    /// Whether a recognised item is work, a cancellation, or work a later
    /// item of the same turn cancelled.
    WorkItemDisposition {
        Accepted => "accepted",
        Cancellation => "cancellation",
        Abandoned => "abandoned",
    }
}

wire_enum! {
    WorkItemLifecycle {
        Recognized => "recognized",
        Cancelled => "cancelled",
    }
}

static EXPLICIT_REPLACE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind|actually\s+instead|replace\s+(?:that|it)|redirect|switch\s+to)\b",
        true,
    )
});
static CANCEL: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind)\b",
        true,
    )
});
static NEGATED_REPLACE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:don'?t|do\s+not|never|no\s+need\s+to)\s+(?:\w+\s+){0,3}?(?:cancel|stop|abort)(?:\s+(?:or|and)\s+(?:cancel|stop|abort))*\b",
        true,
    )
});
static AMBIGUOUS_SWITCH: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(should\s+(?:we|i)\s+switch|maybe\s+instead|could\s+(?:we|you)\s+switch)\b",
        true,
    )
});
static SPEECH_ONLY: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:be\s+quiet|mute|stop\s+(?:the\s+)?(?:audio|playback|speaking|talking))\b",
        true,
    )
});
static ADDITIVE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(also|as\s+well|in\s+addition|another|and\s+then|while\s+you(?:'re|\s+are))\b",
        true,
    )
});
static SIDECAR: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(in\s+parallel|sidecar|meanwhile)\b.*\b(research|inspect|look\s+up|compare|analy[sz]e|summari[sz]e|check)\b",
        true,
    )
});
static MUTATION: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(add|build|change|create|delete|dispatch|edit|fix|implement|install|merge|push|remove|send|update|write)\b",
        true,
    )
});
static GLOBAL_CANCEL: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:all\s+(?:accepted\s+)?work|all\s+(?:the\s+)?(?:tasks|tickets|items)|everything|every\s+(?:task|ticket|item)|the\s+whole\s+(?:queue|turn))\b",
        true,
    )
});
static TICKET_ID: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(GEN-[A-Fa-f0-9]{16}|[A-Za-z][A-Za-z0-9]*-\d+)\b", false));
const ITEM_START: &str = r"add|build|cancel|change|click|create|debug|delete|design|dispatch|drag|edit|fix|focus|implement|install|launch|merge|never\s+mind|nevermind|open|press|redirect|refactor|remove|repair|replace|reveal|run|scratch|scroll|select|ship|show|start|stop|switch|tap|test|type|update|wire|write";
static ITEM_BOUNDARY: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        &format!(
            r"(?<!go ahead)(?:\s*[.;]\s*|\s+\b(?:and(?:\s+then)?|but|then)\b\s+)(?=(?:please\s+)?(?:{ITEM_START})\b)"
        ),
        true,
    )
});
static ITEM_LEAD: LazyLock<Regex> =
    LazyLock::new(|| compile(&format!(r"^\s*(?:please\s+)?(?:{ITEM_START})\b\s*"), true));
static CANCEL_TARGET: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:cancel|stop|abort|scratch(?:\s+that)?|never\s+mind|nevermind)\b(?:\s+(?:the|that|this|last|current))?\s*(.*)$",
        true,
    )
});
static REFERENCE: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(?:that|this|it|last)\b", true));
static CURRENT_REFERENCE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(?:that|this|it|last|current)\b", true));
static WORD: LazyLock<Regex> = LazyLock::new(|| compile(r"[A-Za-z0-9_-]+", false));

const TARGET_STOP_WORDS: [&str; 15] = [
    "a",
    "all",
    "an",
    "and",
    "current",
    "everything",
    "item",
    "please",
    "task",
    "that",
    "the",
    "this",
    "ticket",
    "to",
    "work",
];

fn resource_pattern(resource: ExclusiveResource) -> &'static Regex {
    static REPOSITORY: LazyLock<Regex> = LazyLock::new(|| {
        compile(
            r"\b(code|codebase|file|files|project|repo|repository|source\s+tree|worktree)\b",
            true,
        )
    });
    static DESKTOP: LazyLock<Regex> = LazyLock::new(|| {
        compile(
            r"\b(browser|desktop|screenshot|window)\b|\bon[- ]screen\b",
            true,
        )
    });
    static EXTERNAL: LazyLock<Regex> = LazyLock::new(|| {
        compile(
            r"\b(calendar|email|message|payment|post|publish|purchase|slack)\b",
            true,
        )
    });
    match resource {
        ExclusiveResource::Repository => &REPOSITORY,
        ExclusiveResource::Desktop => &DESKTOP,
        ExclusiveResource::ExternalSideEffect => &EXTERNAL,
    }
}

/// Work already accepted: its id, the resources it holds and its target.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveWork {
    pub work_id: String,
    pub resources: Vec<String>,
    pub target: Option<String>,
}

/// One stable, ordered unit recognised from a Relay voice turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VoiceWorkItem {
    pub intent_id: String,
    pub source_command_seq: i64,
    pub source_command_id: String,
    pub within_turn_order: i64,
    pub source_text: String,
    pub target: Option<String>,
    pub disposition: WorkItemDisposition,
    pub cancellation_scope: CancellationScope,
    pub lifecycle_state: WorkItemLifecycle,
    pub target_intent_ids: Vec<String>,
}

impl VoiceWorkItem {
    /// `to_dict()`, in field order.
    pub fn to_dict(&self) -> Dict {
        let mut payload = Dict::new();
        payload.insert("intent_id", self.intent_id.as_str());
        payload.insert("source_command_seq", self.source_command_seq);
        payload.insert("source_command_id", self.source_command_id.as_str());
        payload.insert("within_turn_order", self.within_turn_order);
        payload.insert("source_text", self.source_text.as_str());
        payload.insert("target", self.target.clone());
        payload.insert("disposition", self.disposition.as_str());
        payload.insert("cancellation_scope", self.cancellation_scope.as_str());
        payload.insert("lifecycle_state", self.lifecycle_state.as_str());
        payload.insert("target_intent_ids", strings(&self.target_intent_ids));
        payload
    }
}

/// The route resolved for one intent and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IntentDisposition {
    pub intent_id: String,
    pub route: IntentRoute,
    pub target_work_ids: Vec<String>,
    pub conflicting_work_ids: Vec<String>,
    pub public_reason: String,
    pub clarification_question: Option<String>,
    pub authorization_effect: AuthorizationEffect,
    pub resource_claims: Vec<String>,
    pub cancellation_scope: CancellationScope,
}

impl IntentDisposition {
    /// `to_dict()`, in field order.
    pub fn to_dict(&self) -> Dict {
        let mut payload = Dict::new();
        payload.insert("intent_id", self.intent_id.as_str());
        payload.insert("route", self.route.as_str());
        payload.insert("target_work_ids", strings(&self.target_work_ids));
        payload.insert("conflicting_work_ids", strings(&self.conflicting_work_ids));
        payload.insert("public_reason", self.public_reason.as_str());
        payload.insert(
            "clarification_question",
            self.clarification_question.clone(),
        );
        payload.insert("authorization_effect", self.authorization_effect.as_str());
        payload.insert("resource_claims", strings(&self.resource_claims));
        payload.insert("cancellation_scope", self.cancellation_scope.as_str());
        payload
    }
}

fn strings(values: &[String]) -> Value {
    Value::List(
        values
            .iter()
            .map(|value| Value::from(value.as_str()))
            .collect(),
    )
}

/// `_target_words`: the lower-cased words of `value` that can name a target.
fn target_words(value: Option<&str>) -> Vec<String> {
    let mut words: Vec<String> = find_all(&WORD, value.unwrap_or(""))
        .into_iter()
        .map(str::to_lowercase)
        .filter(|word| !TARGET_STOP_WORDS.contains(&word.as_str()))
        .collect();
    words.sort_unstable();
    words.dedup();
    words
}

/// `_item_target`: a ticket id, else up to six target words.
fn item_target(source_text: &str, cancellation: bool) -> Option<String> {
    if let Some(ticket) = pattern::group(&TICKET_ID, source_text, 1) {
        return Some(ticket.to_uppercase());
    }
    let text = json::py_strip(source_text);
    let text = if cancellation {
        pattern::group(&CANCEL_TARGET, text, 1)
            .map(|rest| json::py_strip(rest).to_string())
            .unwrap_or_default()
    } else {
        pattern::sub(&ITEM_LEAD, text, 0)
    };
    let words: Vec<&str> = find_all(&WORD, &text)
        .into_iter()
        .filter(|word| !TARGET_STOP_WORDS.contains(&word.to_lowercase().as_str()))
        .take(6)
        .collect();
    Some(words.join(" ").to_lowercase()).filter(|target| !target.is_empty())
}

/// `_matching_prior_item`: the earlier, still open item a cancellation names.
fn matching_prior_item(
    items: &[VoiceWorkItem],
    target: Option<&str>,
    source_text: &str,
) -> Option<usize> {
    let candidates: Vec<usize> = (0..items.len())
        .filter(|index| items[*index].lifecycle_state != WorkItemLifecycle::Cancelled)
        .collect();
    let last = *candidates.last()?;
    if search(&REFERENCE, source_text) && target.is_none() {
        return Some(last);
    }
    let wanted = target_words(target);
    if !wanted.is_empty() {
        for index in candidates.iter().rev() {
            let item = &items[*index];
            let mut known = target_words(item.target.as_deref());
            known.extend(target_words(Some(&item.source_text)));
            if wanted.iter().any(|word| known.contains(word)) {
                return Some(*index);
            }
        }
    }
    (candidates.len() == 1 && target.is_none()).then_some(last)
}

/// Splits a completed turn into durable ordered work and cancellation items.
pub fn normalize_voice_work_items(
    source_text: &str,
    relay_command_seq: i64,
    relay_command_id: &str,
) -> Vec<VoiceWorkItem> {
    let text = json::py_strip(source_text);
    if text.is_empty() {
        return Vec::new();
    }
    let clauses: Vec<&str> = pattern::split(&ITEM_BOUNDARY, text)
        .into_iter()
        .map(|part| part.trim_matches([' ', ',']))
        .filter(|part| !part.is_empty())
        .collect();
    let mut items: Vec<VoiceWorkItem> = Vec::new();
    for (index, clause) in clauses.into_iter().enumerate() {
        let order = index as i64 + 1;
        let cancellation = explicit_cancel_requested(clause);
        let mut scope = CancellationScope::None;
        let target = item_target(clause, cancellation);
        let mut target_ids = Vec::new();
        let mut disposition = WorkItemDisposition::Accepted;
        if cancellation {
            if search(&GLOBAL_CANCEL, clause) {
                scope = CancellationScope::AllWork;
            } else if search(&TICKET_ID, clause) {
                scope = CancellationScope::Ticket;
            } else if let Some(prior) = matching_prior_item(&items, target.as_deref(), clause) {
                scope = CancellationScope::Item;
                target_ids = vec![items[prior].intent_id.clone()];
                let prior = &mut items[prior];
                prior.disposition = WorkItemDisposition::Abandoned;
                prior.cancellation_scope = CancellationScope::Item;
                prior.lifecycle_state = WorkItemLifecycle::Cancelled;
            } else if target.is_some() {
                scope = CancellationScope::Item;
            } else {
                scope = CancellationScope::Ambiguous;
            }
            disposition = WorkItemDisposition::Cancellation;
        }
        items.push(VoiceWorkItem {
            intent_id: format!("{relay_command_id}:item:{order}"),
            source_command_seq: relay_command_seq,
            source_command_id: relay_command_id.to_string(),
            within_turn_order: order,
            source_text: clause.to_string(),
            target,
            disposition,
            cancellation_scope: scope,
            lifecycle_state: WorkItemLifecycle::Recognized,
            target_intent_ids: target_ids,
        });
    }
    items
}

/// The exclusive resources a turn's wording names, in declaration order.
pub fn inferred_resource_claims(source_text: &str) -> Vec<String> {
    ExclusiveResource::ALL
        .iter()
        .filter(|resource| search(resource_pattern(**resource), source_text))
        .map(|resource| resource.as_str().to_string())
        .collect()
}

/// Whether completed language positively requests work preemption.
pub fn explicit_replace_requested(source_text: &str, action_reason: &str) -> bool {
    let negated = search(&NEGATED_REPLACE, source_text);
    let unnegated = pattern::sub(&NEGATED_REPLACE, source_text, 0);
    if search(&EXPLICIT_REPLACE, &unnegated) {
        return true;
    }
    let reason = json::py_strip(action_reason).to_lowercase();
    matches!(
        reason.as_str(),
        "cancel" | "interrupt" | "redirect" | "replace"
    ) && !negated
}

/// Whether completed language positively requests cancellation.
pub fn explicit_cancel_requested(source_text: &str) -> bool {
    search(&CANCEL, &pattern::sub(&NEGATED_REPLACE, source_text, 0))
}

/// Whether a bounded read-only sidecar can run without contention.
pub fn sidecar_eligible(
    source_text: &str,
    active_work: &[ActiveWork],
    requested_resources: &[String],
    project_mutation: bool,
) -> bool {
    if project_mutation || search(&MUTATION, source_text) || !search(&SIDECAR, source_text) {
        return false;
    }
    if requested_resources
        .iter()
        .any(|resource| ExclusiveResource::parse(resource).is_some())
    {
        return false;
    }
    !active_work
        .iter()
        .flat_map(|work| &work.resources)
        .any(|resource| requested_resources.contains(resource))
}

/// The inputs of `resolve_intent_disposition`.
#[derive(Clone, Debug, Default)]
pub struct DispositionRequest<'a> {
    pub intent_id: &'a str,
    pub action_kind: &'a str,
    pub action_reason: Option<&'a str>,
    pub source_text: &'a str,
    pub active_work: &'a [ActiveWork],
    pub requested_resources: &'a [String],
    pub cancellation_scope: Option<CancellationScope>,
    pub target_work_ids: &'a [String],
}

/// Resolves exactly one safe route relative to already accepted work.
pub fn resolve_intent_disposition(request: &DispositionRequest<'_>) -> IntentDisposition {
    let active_ids: Vec<String> = request
        .active_work
        .iter()
        .map(|work| work.work_id.clone())
        .collect();
    let active = !active_ids.is_empty();
    let mut kind = Some(request.action_kind)
        .filter(|kind| !kind.is_empty())
        .unwrap_or("conversation");
    let mut reason = json::py_strip(request.action_reason.unwrap_or("")).to_lowercase();
    let text = request.source_text;
    let mut scope = request
        .cancellation_scope
        .unwrap_or(CancellationScope::None);
    let mut resolved_targets: Vec<String> = request
        .target_work_ids
        .iter()
        .filter(|id| !id.is_empty())
        .cloned()
        .collect();
    let preempting_reason =
        |reason: &str| matches!(reason, "cancel" | "interrupt" | "redirect" | "replace");
    if kind == "control"
        && preempting_reason(&reason)
        && search(&NEGATED_REPLACE, text)
        && !explicit_replace_requested(text, &reason)
    {
        kind = "conversation";
        reason = String::new();
    }
    let mut resources: Vec<String> = request.requested_resources.to_vec();
    resources.extend(inferred_resource_claims(text));
    if kind == "direct_action" {
        resources.push(ExclusiveResource::Desktop.as_str().to_string());
    }
    resources.sort_unstable();
    resources.dedup();

    let disposition =
        |route, targets: &[String], conflicts: &[String], public_reason: &str| IntentDisposition {
            intent_id: request.intent_id.to_string(),
            route,
            target_work_ids: targets.to_vec(),
            conflicting_work_ids: conflicts.to_vec(),
            public_reason: public_reason.to_string(),
            clarification_question: None,
            authorization_effect: AuthorizationEffect::Preserve,
            resource_claims: resources.clone(),
            cancellation_scope: CancellationScope::None,
        };
    let none: &[String] = &[];

    if kind == "control" && !preempting_reason(&reason) {
        return IntentDisposition {
            authorization_effect: AuthorizationEffect::None,
            ..disposition(
                IntentRoute::ControlOnly,
                none,
                none,
                "Handled as a speech or session control.",
            )
        };
    }
    if kind == "control" && search(&SPEECH_ONLY, text) {
        return disposition(
            IntentRoute::ControlOnly,
            &active_ids,
            none,
            "Stopped speech without changing accepted work.",
        );
    }
    if active && search(&AMBIGUOUS_SWITCH, text) {
        return IntentDisposition {
            clarification_question: Some(
                "Should I queue this behind the current work, or switch to it now?".to_string(),
            ),
            ..disposition(
                IntentRoute::ClarifyPriority,
                &active_ids,
                &active_ids,
                "Queueing and switching would produce materially different outcomes.",
            )
        };
    }

    let explicit_replace = explicit_replace_requested(text, &reason);
    if explicit_replace && scope == CancellationScope::None {
        if reason == "interrupt" || search(&GLOBAL_CANCEL, text) {
            scope = CancellationScope::AllWork;
        } else if search(&TICKET_ID, text) {
            scope = CancellationScope::Ticket;
        } else if search(&CURRENT_REFERENCE, text) {
            scope = CancellationScope::Item;
            if resolved_targets.is_empty()
                && let Some(last) = active_ids.last()
            {
                resolved_targets = vec![last.clone()];
            }
        } else {
            scope = CancellationScope::Ambiguous;
        }
    }
    let scoped = |route, targets: &[String], public_reason: &str, question: Option<&str>| {
        let effect = if route == IntentRoute::ReplaceCurrent {
            AuthorizationEffect::RevokeConflicting
        } else {
            AuthorizationEffect::Preserve
        };
        let conflicts = if route == IntentRoute::ReplaceCurrent {
            targets
        } else {
            none
        };
        IntentDisposition {
            clarification_question: question.map(str::to_string),
            authorization_effect: effect,
            cancellation_scope: scope,
            ..disposition(route, targets, conflicts, public_reason)
        }
    };
    if active && explicit_replace && scope == CancellationScope::Ambiguous {
        return scoped(
            IntentRoute::ClarifyPriority,
            &active_ids,
            "The cancellation target is ambiguous, so accepted work remains unchanged.",
            Some("Which item or ticket should I cancel, or should I cancel all accepted work?"),
        );
    }
    if active && explicit_replace {
        let all_work = scope == CancellationScope::AllWork;
        return scoped(
            IntentRoute::ReplaceCurrent,
            if all_work {
                &active_ids
            } else {
                &resolved_targets
            },
            if all_work {
                "The completed turn explicitly cancels all accepted work."
            } else {
                "The completed turn cancels only the resolved item or ticket."
            },
            None,
        );
    }
    if explicit_replace && matches!(scope, CancellationScope::Item | CancellationScope::Ticket) {
        return scoped(
            IntentRoute::ReplaceCurrent,
            &resolved_targets,
            "Recorded a scoped cancellation without widening it to unrelated work.",
            None,
        );
    }
    if explicit_replace && scope == CancellationScope::AllWork {
        return scoped(
            IntentRoute::ReplaceCurrent,
            &active_ids,
            "The completed turn explicitly cancels all accepted work.",
            None,
        );
    }
    if explicit_replace && scope == CancellationScope::Ambiguous {
        return scoped(
            IntentRoute::ClarifyPriority,
            none,
            "The cancellation target is ambiguous.",
            Some("Which item or ticket should I cancel?"),
        );
    }

    let project_mutation = matches!(
        kind,
        "create_ticket" | "update_ticket" | "dispatch_ticket" | "inline_work"
    );
    if active && sidecar_eligible(text, request.active_work, &resources, project_mutation) {
        return disposition(
            IntentRoute::RunSidecar,
            &active_ids,
            none,
            "The task is bounded, read-only, independently verifiable, and resource-safe.",
        );
    }
    if active && search(&SIDECAR, text) && !project_mutation {
        return disposition(
            IntentRoute::QueueProjectWork,
            &active_ids,
            &active_ids,
            "The requested parallel task conflicts with exclusive active resources, so it is queued.",
        );
    }
    let with_repository = || {
        let mut claims = resources.clone();
        claims.push(ExclusiveResource::Repository.as_str().to_string());
        claims.sort_unstable();
        claims.dedup();
        claims
    };
    if kind == "inline_work" && !active {
        return IntentDisposition {
            resource_claims: with_repository(),
            ..disposition(
                IntentRoute::ContinueCurrent,
                none,
                none,
                "The change is done now in this session, not on the ticket path.",
            )
        };
    }
    if project_mutation {
        return IntentDisposition {
            resource_claims: with_repository(),
            ..disposition(
                IntentRoute::QueueProjectWork,
                &active_ids,
                if active { &active_ids } else { none },
                if active {
                    "Project-changing work is queued on the native Relay ticket path."
                } else {
                    "Project-changing work uses the native Relay ticket path."
                },
            )
        };
    }
    if kind == "control" {
        return IntentDisposition {
            authorization_effect: AuthorizationEffect::None,
            ..disposition(
                IntentRoute::ControlOnly,
                &active_ids,
                none,
                "No active work required preemption.",
            )
        };
    }
    disposition(
        IntentRoute::ContinueCurrent,
        &active_ids,
        none,
        if active || search(&ADDITIVE, text) {
            "The turn adds context, asks for status, or can safely steer active work."
        } else {
            "The turn can proceed in the foreground orchestration context."
        },
    )
}

/// Maps work arbitration to the bounded-mutation ledger's relationship.
pub fn authorization_relationship_for(disposition: &IntentDisposition, fallback: &str) -> String {
    match disposition.authorization_effect {
        AuthorizationEffect::RevokeConflicting => "redirect",
        AuthorizationEffect::Preserve
            if disposition.route == IntentRoute::ContinueCurrent && fallback == "inspection" =>
        {
            fallback
        }
        AuthorizationEffect::Preserve if disposition.route == IntentRoute::ContinueCurrent => {
            "conversation"
        }
        AuthorizationEffect::Preserve => "additive",
        AuthorizationEffect::None => fallback,
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn items(text: &str) -> Vec<(String, String, &'static str, &'static str)> {
        normalize_voice_work_items(text, 4, "cmd")
            .into_iter()
            .map(|item| {
                (
                    item.source_text,
                    item.target.unwrap_or_default(),
                    item.disposition.as_str(),
                    item.cancellation_scope.as_str(),
                )
            })
            .collect()
    }

    #[test]
    fn a_turn_splits_into_ordered_items_at_work_verbs() {
        assert_eq!(
            items("fix the login bug and then update the readme"),
            vec![
                (
                    "fix the login bug".into(),
                    "login bug".into(),
                    "accepted",
                    "none"
                ),
                (
                    "update the readme".into(),
                    "readme".into(),
                    "accepted",
                    "none"
                ),
            ]
        );
        // "go ahead and" does not start a new item.
        assert_eq!(items("go ahead and fix it").len(), 1);
        assert_eq!(items("Go ahead and fix it").len(), 1);
        assert_eq!(items("what is left on the release checklist").len(), 1);
    }

    #[test]
    fn a_cancellation_names_the_prior_item_it_ends() {
        let items = normalize_voice_work_items("add dark mode, then cancel that", 1, "c");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].lifecycle_state, WorkItemLifecycle::Cancelled);
        assert_eq!(items[0].disposition, WorkItemDisposition::Abandoned);
        assert_eq!(items[1].cancellation_scope, CancellationScope::Item);
        assert_eq!(items[1].target_intent_ids, vec!["c:item:1".to_string()]);
        let global = normalize_voice_work_items("cancel everything", 1, "c");
        assert_eq!(global[0].cancellation_scope, CancellationScope::AllWork);
        let ticket = normalize_voice_work_items("stop RR-12", 1, "c");
        assert_eq!(ticket[0].cancellation_scope, CancellationScope::Ticket);
        assert_eq!(ticket[0].target.as_deref(), Some("RR-12"));
        let vague = normalize_voice_work_items("never mind", 1, "c");
        assert_eq!(vague[0].cancellation_scope, CancellationScope::Ambiguous);
    }

    #[test]
    fn negated_cancellation_is_not_a_cancellation() {
        assert!(!explicit_cancel_requested("don't stop the build"));
        assert!(explicit_cancel_requested("stop the build"));
        assert!(!explicit_replace_requested(
            "do not cancel or stop it",
            "cancel"
        ));
        assert!(explicit_replace_requested("keep going", "redirect"));
    }

    #[test]
    fn dispositions_follow_the_python_routes() {
        let active = [ActiveWork {
            work_id: "w1".into(),
            resources: vec!["repository".into()],
            target: None,
        }];
        let route = |kind: &str, reason: Option<&str>, text: &str, active: &[ActiveWork]| {
            resolve_intent_disposition(&DispositionRequest {
                intent_id: "i",
                action_kind: kind,
                action_reason: reason,
                source_text: text,
                active_work: active,
                ..Default::default()
            })
        };
        assert_eq!(
            route("control", Some("tts_stop"), "stop", &[]).route,
            IntentRoute::ControlOnly
        );
        let replaced = route("conversation", None, "cancel that", &active);
        assert_eq!(replaced.route, IntentRoute::ReplaceCurrent);
        assert_eq!(replaced.cancellation_scope, CancellationScope::Item);
        assert_eq!(replaced.target_work_ids, vec!["w1".to_string()]);
        assert_eq!(
            route(
                "conversation",
                None,
                "meanwhile research the API docs",
                &active
            )
            .route,
            IntentRoute::RunSidecar
        );
        let ticket = route("create_ticket", None, "create a ticket for dark mode", &[]);
        assert_eq!(ticket.route, IntentRoute::QueueProjectWork);
        assert_eq!(ticket.resource_claims, vec!["repository".to_string()]);
        assert_eq!(
            authorization_relationship_for(&ticket, "mutation"),
            "additive"
        );
        assert_eq!(authorization_relationship_for(&replaced, "x"), "redirect");
    }

    #[test]
    fn scopes_from_the_wire_default_to_none_and_unknown_is_ambiguous() {
        assert_eq!(CancellationScope::from_wire(None), CancellationScope::None);
        assert_eq!(
            CancellationScope::from_wire(Some("")),
            CancellationScope::None
        );
        assert_eq!(
            CancellationScope::from_wire(Some("item")),
            CancellationScope::Item
        );
        assert_eq!(
            CancellationScope::from_wire(Some("x")),
            CancellationScope::Ambiguous
        );
    }
}
