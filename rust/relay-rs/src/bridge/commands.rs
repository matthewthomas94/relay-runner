//! A voice turn becoming commands: its newest-intent generation, its ordered
//! work items with their actions and dispositions, the durable fan-out of
//! project work to the daemon, and publication through the intent inbox
//! (`voice_bridge.py` from `_begin_relay_command` to `_announce_voice_paused`).

use std::sync::LazyLock;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use relay_intents::arbitration::{
    self, ActiveWork, CancellationScope, DispositionRequest, IntentDisposition, IntentRoute, VoiceWorkItem,
    WorkItemDisposition, WorkItemLifecycle,
};
use relay_intents::inbox::IntentInbox;
use relay_intents::model::normalize_recovery_generation;
use relay_intents::pattern::{self, Regex};
use relay_intents::qualification::{self, format_qualification_for_agent, qualify_intent};

use super::authorization;
use super::command_actions::{self, CommandAction};
use super::context::Bridge;
use super::orchestrator::{OrchestratorSession, post_continuity_event, post_orchestrator_json};
use super::settings::settings;
use super::speech::{self, TtsOptions};
use super::store::{self, read_json_file, relay_command_key};
use super::targets;
use crate::json::{self, Dict, Value};
use crate::support::{env_or, env_text, now};

/// `_begin_relay_command`: record a new newest-intent generation as soon as
/// voice input arrives. Relay Remote passes its input source and device.
pub fn begin_relay_command(
    source_text: &str,
    state_path: &str,
    input_source: Option<&str>,
    device_id: Option<&Value>,
) -> Dict {
    let metadata = {
        let _guard = store::voice_state_lock();
        let previous = read_json_file(state_path);
        let seq = match previous.truthy("relay_command_seq") {
            Some(value) => value.py_int().map(|seq| seq + 1).unwrap_or(1),
            None => 1,
        };
        let time_ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or_default();
        let mut metadata = Dict::new();
        metadata.insert("relay_command_seq", seq);
        metadata.insert(
            "relay_command_id",
            format!("{}-{time_ns}-{seq}", std::process::id()),
        );
        metadata.insert("source_text", source_text);
        metadata.insert("received_at", now());
        metadata.insert("action", "received");
        let generation = match env_or("RELAY_RECOVERY_GENERATION", "") {
            generation if !generation.is_empty() => generation,
            _ => seq.to_string(),
        };
        metadata.insert(
            "recovery_generation",
            normalize_recovery_generation(&Value::from(generation.as_str())).unwrap_or(generation),
        );
        let provider = env_text("RELAY_RUNNER_PROVIDER");
        if !provider.is_empty() {
            metadata.insert("provider", provider);
        }
        if let Some(input_source) = input_source.filter(|source| !source.is_empty()) {
            metadata.insert("input_source", input_source);
            metadata.insert("device_id", device_id.cloned().unwrap_or(Value::Null));
        }
        if let Err(error) = store::write_command_state(state_path, &metadata) {
            eprintln!("[voice_bridge] Could not write the command state: {error}");
        }
        metadata
    };
    store::record_private_command_capture(&metadata);
    post_continuity_event("bridge", "command_received", &metadata, None);
    metadata
}

/// `_metadata_for_action`.
pub fn metadata_for_action(
    action: &CommandAction,
    relay_command: &Dict,
    disposition: Option<&IntentDisposition>,
    work_item: Option<&VoiceWorkItem>,
) -> Dict {
    let mut metadata = relay_command.clone();
    let fallback_relationship = authorization::command_relationship(
        &action.kind,
        action.reason.as_deref().unwrap_or(""),
        &action.source_text,
    )
    .to_string();
    let relationship = match disposition {
        Some(disposition) => arbitration::authorization_relationship_for(disposition, &fallback_relationship),
        None => fallback_relationship,
    };
    metadata.insert("action", action.kind.as_str());
    metadata.insert("outcome", action.outcome.as_str());
    metadata.insert("requires_ticket", action.requires_ticket);
    metadata.insert("authorization_relationship", relationship);
    metadata.insert(
        "intent_qualification",
        qualify_intent(
            &action.source_text,
            &action.kind,
            action.reason.as_deref(),
            relay_command.get("relay_command_id").and_then(Value::as_str),
            relay_command.get("relay_command_seq").and_then(Value::py_int),
        )
        .to_dict(),
    );
    if let Some(disposition) = disposition {
        metadata.insert("intent_id", disposition.intent_id.as_str());
        metadata.insert("work_disposition", disposition.to_dict());
        metadata.insert(
            "preempt_provider",
            disposition.route == IntentRoute::ReplaceCurrent
                && disposition.cancellation_scope == CancellationScope::AllWork,
        );
    }
    if let Some(item) = work_item {
        let mut cancellation_scope = item.cancellation_scope;
        let mut target_intent_ids = item.target_intent_ids.clone();
        if let Some(disposition) = disposition
            && disposition.cancellation_scope != CancellationScope::None
        {
            cancellation_scope = disposition.cancellation_scope;
            target_intent_ids = disposition.target_work_ids.clone();
        }
        let targets: Vec<Value> = target_intent_ids.iter().map(|id| Value::from(id.as_str())).collect();
        let mut voice_work_item = item.to_dict();
        voice_work_item.insert("cancellation_scope", cancellation_scope.as_str());
        voice_work_item.insert("target_intent_ids", Value::List(targets.clone()));
        metadata.insert("intent_id", item.intent_id.as_str());
        metadata.insert("within_turn_order", item.within_turn_order);
        metadata.insert("target", item.target.clone());
        metadata.insert("disposition", item.disposition.as_str());
        metadata.insert("cancellation_scope", cancellation_scope.as_str());
        metadata.insert("lifecycle_state", item.lifecycle_state.as_str());
        metadata.insert("target_intent_ids", Value::List(targets.clone()));
        metadata.insert("voice_work_item", voice_work_item);
        if let Some(disposition) = disposition
            && disposition.route == IntentRoute::ReplaceCurrent
            && matches!(
                disposition.cancellation_scope,
                CancellationScope::Item | CancellationScope::Ticket
            )
        {
            metadata.insert("provider_preempt_intent_ids", Value::List(targets));
        }
    }
    if let Some(ticket_id) = action.ticket_id.as_deref().filter(|value| !value.is_empty()) {
        metadata.insert("ticket_id", ticket_id);
    }
    if let Some(ticket_path) = action.ticket_path.as_deref().filter(|value| !value.is_empty()) {
        metadata.insert("ticket_path", ticket_path);
    }
    if let Some(repo_path) = action.repo_path.as_deref().filter(|value| !value.is_empty()) {
        metadata.insert("repo_path", repo_path);
    }
    if let Some(reason) = action.reason.as_deref().filter(|value| !value.is_empty()) {
        metadata.insert("reason", reason);
    }
    metadata
}

/// `_active_work`: the active turns of the provider turn ledger.
pub fn active_work(turns_path: &str, repo_path: Option<&str>) -> Vec<ActiveWork> {
    let data = read_json_file(turns_path);
    let Some(records) = data.get("records").and_then(Value::as_list) else {
        return Vec::new();
    };
    let mut active = Vec::new();
    for record in records.iter().filter_map(Value::as_dict) {
        if record.string("state") != "active" {
            continue;
        }
        let Some((seq, id)) = relay_command_key(record) else {
            continue;
        };
        let resources = match record.get("resource_claims").and_then(Value::as_list) {
            Some(resources) => resources.iter().map(Value::py_str).collect(),
            None if repo_path.is_some_and(|path| !path.is_empty()) => vec!["repository".to_string()],
            None => Vec::new(),
        };
        let work_id = match record.truthy("intent_id") {
            Some(intent_id) => intent_id.py_str(),
            None => format!("{seq}:{id}"),
        };
        let target = record.string("target");
        active.push(ActiveWork {
            work_id,
            resources,
            target: (!target.is_empty()).then_some(target),
        });
    }
    active
}

/// One item `_resolve_voice_work_items` resolved.
pub struct ResolvedItem {
    pub item: VoiceWorkItem,
    pub action: CommandAction,
    pub disposition: IntentDisposition,
    pub metadata: Dict,
    pub prompt: String,
}

/// `_resolve_voice_work_items`: one real turn as provider-neutral ordered
/// item deliveries.
pub fn resolve_voice_work_items(
    source_text: &str,
    relay_command: &Dict,
    repo_path: &str,
    active: &[ActiveWork],
    foreground_active: bool,
) -> Vec<ResolvedItem> {
    let seq = relay_command
        .get("relay_command_seq")
        .and_then(Value::py_int)
        .unwrap_or(0);
    let command_id = relay_command.string("relay_command_id");
    let items = if command_actions::is_mixed_query_and_mutation(source_text)
        || qualification::whole_turn_resolution_required(source_text)
    {
        vec![VoiceWorkItem {
            intent_id: format!("{command_id}:item:1"),
            source_command_seq: seq,
            source_command_id: command_id.clone(),
            within_turn_order: 1,
            source_text: json::py_strip(source_text).to_string(),
            target: None,
            disposition: WorkItemDisposition::Accepted,
            cancellation_scope: CancellationScope::None,
            lifecycle_state: WorkItemLifecycle::Recognized,
            target_intent_ids: Vec::new(),
        }]
    } else {
        arbitration::normalize_voice_work_items(source_text, seq, &command_id)
    };
    let mut resolved = Vec::new();
    let mut known_work: Vec<ActiveWork> = active.to_vec();
    for item in items {
        let mut item_command = relay_command.clone();
        item_command.insert("source_text", item.source_text.as_str());
        item_command.insert("intent_id", item.intent_id.as_str());
        item_command.insert("within_turn_order", item.within_turn_order);
        item_command.insert("voice_work_item", item.to_dict());
        let action = command_actions::resolve_command_action(&item.source_text, repo_path, &item_command);
        let mut disposition = arbitration::resolve_intent_disposition(&DispositionRequest {
            intent_id: &item.intent_id,
            action_kind: &action.kind,
            action_reason: action.reason.as_deref(),
            source_text: &item.source_text,
            active_work: &known_work,
            requested_resources: &[],
            cancellation_scope: Some(item.cancellation_scope),
            target_work_ids: &item.target_intent_ids,
        });
        if foreground_active && disposition.route == IntentRoute::RunSidecar {
            disposition.route = IntentRoute::ContinueCurrent;
            disposition.public_reason = "Steer the active foreground PM with this voice turn.".to_string();
        }
        let metadata = metadata_for_action(&action, &item_command, Some(&disposition), Some(&item));
        let mut prompt = command_actions::format_command_for_agent(&action, &disposition.to_dict());
        if action.kind != "control" {
            prompt.push_str(&format_qualification_for_agent(&qualify_intent(
                &item.source_text,
                &action.kind,
                action.reason.as_deref(),
                Some(&command_id),
                Some(seq),
            )));
        }
        if item.lifecycle_state != WorkItemLifecycle::Cancelled
            && item.disposition == WorkItemDisposition::Accepted
            && action.kind != "control"
        {
            known_work.push(ActiveWork {
                work_id: item.intent_id.clone(),
                resources: disposition.resource_claims.clone(),
                target: item.target.clone(),
            });
        }
        resolved.push(ResolvedItem {
            item,
            action,
            disposition,
            metadata,
            prompt,
        });
    }
    resolved
}

static PRIVATE_CONTEXT_LINE_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"\b(raw\s+transcript|source_text|hidden\s+reasoning|tool\s+log|shell\s+output|scratchpad|prompt)\b",
            r"|(`|\$\(|&&|\|\||\s;\s|",
            r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
        ),
        true,
    )
});
static WHITESPACE_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"\s+", false));

/// `_sanitized_command_context`.
fn sanitized_command_context(relay_command: &Dict) -> Option<String> {
    let value = relay_command
        .truthy("context")
        .or(relay_command.truthy("refined_context"))
        .or(relay_command.truthy("conversation_context"))
        .or_else(|| relay_command.get("conversation_context").filter(|value| !matches!(value, Value::Null)))?;
    let mut lines: Vec<String> = Vec::new();
    for raw in value.py_str().lines() {
        let collapsed = WHITESPACE_RE.replace_all(raw, " ");
        let line = json::py_strip(&collapsed);
        if line.is_empty() || pattern::search(&PRIVATE_CONTEXT_LINE_RE, line) {
            continue;
        }
        lines.push(line.to_string());
        if lines.len() >= 18 {
            break;
        }
    }
    let joined = lines.join("\n");
    let sanitized = json::py_strip(&joined);
    if sanitized.is_empty() {
        return None;
    }
    let bounded: String = sanitized.chars().take(2400).collect();
    Some(bounded.trim_end_matches(json::py_is_space).to_string())
}

/// `_raw_instruction_payload`.
fn raw_instruction_payload(
    source_text: &str,
    relay_command: &Dict,
    action: &CommandAction,
    repo_path: Option<&str>,
    orchestrator: Option<&OrchestratorSession>,
) -> Dict {
    let metadata = metadata_for_action(action, relay_command, None, None);
    let session_repo = orchestrator.map(|session| session.repo_path.clone()).unwrap_or_default();
    let repo = match repo_path.filter(|path| !path.is_empty()) {
        Some(path) => path.to_string(),
        None if !session_repo.is_empty() => session_repo,
        None => store::current_dir(),
    };
    let mut payload = Dict::new();
    payload.insert("repo_path", store::resolve_path(&repo));
    payload.insert("source_text", source_text);
    for name in [
        "relay_command_seq",
        "relay_command_id",
        "provider",
        "recovery_generation",
        "received_at",
        "action",
        "outcome",
    ] {
        payload.insert(name, metadata.get(name).cloned().unwrap_or(Value::Null));
    }
    payload.insert("status", "queued");
    payload.insert("defer_processing", true);
    for name in [
        "intent_id",
        "within_turn_order",
        "target",
        "disposition",
        "cancellation_scope",
        "lifecycle_state",
    ] {
        if let Some(value) = metadata.present(name) {
            payload.insert(name, value.clone());
        }
    }
    if let Some(context) = sanitized_command_context(relay_command) {
        payload.insert("context", context);
    }
    if let Some(session) = orchestrator {
        payload.insert("session_id", session.session_id.clone());
    }
    payload
}

fn with_session_id(relay_command: &Dict, orchestrator: Option<&OrchestratorSession>) -> Dict {
    let mut payload = relay_command.clone();
    payload.insert(
        "session_id",
        orchestrator.map(|session| session.session_id.clone()).unwrap_or(Value::Null),
    );
    payload
}

/// `_deliver_raw_instruction_to_orchestrator`.
pub fn deliver_raw_instruction_to_orchestrator(
    source_text: &str,
    relay_command: &Dict,
    action: &CommandAction,
    repo_path: Option<&str>,
    orchestrator: Option<&OrchestratorSession>,
    state_path: &str,
) -> bool {
    if !super::turns::command_current(relay_command, state_path) {
        store::record_command_action_state(relay_command, "superseded");
        eprintln!("[voice_bridge] Dropping raw orchestrator command because its Relay command was superseded.");
        return false;
    }
    let payload = raw_instruction_payload(source_text, relay_command, action, repo_path, orchestrator);
    if let Err(error) = post_orchestrator_json("/v1/orchestrator-session/command", &payload) {
        let mut failed = relay_command.clone();
        failed.insert("action", action.kind.as_str());
        failed.insert("outcome", "delivery failed");
        store::record_command_action_state(&failed, "delivery_failed");
        post_continuity_event("bridge", "delivery_failed", &with_session_id(relay_command, orchestrator), None);
        eprintln!("[voice_bridge] Could not fan out raw command to orchestrator: {error}");
        return false;
    }
    post_continuity_event("bridge", "command_delivered", &with_session_id(relay_command, orchestrator), None);
    true
}

/// `_fanout_raw_instruction_to_orchestrator`: deliver on its own thread.
pub fn fanout_raw_instruction_to_orchestrator(
    source_text: String,
    relay_command: Dict,
    action: CommandAction,
    repo_path: Option<String>,
    orchestrator: Option<std::sync::Arc<OrchestratorSession>>,
    state_path: String,
) {
    let _ = thread::Builder::new()
        .name("orchestrator-raw-command-fanout".to_string())
        .spawn(move || {
            deliver_raw_instruction_to_orchestrator(
                &source_text,
                &relay_command,
                &action,
                repo_path.as_deref(),
                orchestrator.as_deref(),
                &state_path,
            );
        });
}

/// `_should_fanout_raw_instruction_to_orchestrator`: durably queue project
/// work without bypassing the foreground PM.
pub fn should_fanout_raw_instruction_to_orchestrator(action: &CommandAction) -> bool {
    matches!(action.kind.as_str(), "create_ticket" | "update_ticket" | "dispatch_ticket")
}

/// `_discard_pending_command`: undo file-backed effects for an unclaimed
/// command being superseded.
pub fn discard_pending_command(command_path: &str, meta_path: &str) {
    if !store::exists(command_path) {
        return;
    }
    let metadata = read_json_file(meta_path);
    if metadata.get("action").is_some_and(|action| action.is_str("create_ticket")) {
        let ticket_path = metadata.string("ticket_path");
        if !ticket_path.is_empty() {
            match std::fs::remove_file(&ticket_path) {
                Ok(()) => eprintln!("[voice_bridge] Removed stale unclaimed ticket {ticket_path}."),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => eprintln!("[voice_bridge] Could not remove stale ticket {ticket_path}: {error}"),
            }
        }
    }
    store::remove(command_path);
    store::remove(meta_path);
}

/// `_release_cancelled_leases`: remove cancelled leases from every live
/// session mailbox.
pub fn release_cancelled_leases(intent_ids: &[String]) {
    if intent_ids.is_empty() {
        return;
    }
    for target in targets::live_voice_targets() {
        let leased = read_json_file(&target.meta_path);
        if intent_ids.contains(&leased.string("intent_id")) {
            store::remove(&target.command_path);
            store::remove(&target.meta_path);
        }
    }
}

/// `_voice_mailbox_for`: deliver an item to the session focused when it was
/// recorded; an ended session's item falls back to the focused session.
pub fn voice_mailbox_for(metadata: &Dict) -> Option<(String, String)> {
    let target = targets::voice_target_for_value(metadata.get("voice_target_session_key"))
        .or_else(targets::current_voice_target)?;
    if !target.spool_dir.is_empty() {
        let _ = store::make_private_dirs(&target.spool_dir);
    }
    Some((target.command_path, target.meta_path))
}

/// `inbox.materialize_next(...)` with the bridge's routing.
pub fn materialize_next(inbox: &IntentInbox, command_path: &str, meta_path: &str, transport: &str) {
    let route: &dyn Fn(&Dict) -> Option<(String, String)> = &voice_mailbox_for;
    let paths_for = (!targets::live_voice_targets().is_empty()).then_some(route);
    if let Err(error) = inbox.materialize_next(command_path, meta_path, transport, paths_for) {
        eprintln!("[voice_bridge] Could not deliver queued voice command: {error}");
    }
}

/// The mailbox paths `_publish_command` writes.
#[derive(Clone, Debug)]
pub struct PublishPaths {
    pub command_path: String,
    pub meta_path: String,
    pub state_path: String,
    pub authorization_path: Option<String>,
    pub transport: String,
}

impl Default for PublishPaths {
    fn default() -> Self {
        let settings = settings();
        Self {
            command_path: settings.cmd_file.clone(),
            meta_path: settings.cmd_meta_file.clone(),
            state_path: settings.command_state_file.clone(),
            authorization_path: Some(settings.authorization_file.clone()),
            transport: "shared-ready-file".to_string(),
        }
    }
}

/// `_publish_command`: publish through the durable inbox, keeping the ready
/// files as transport.
pub fn publish_command(text: &str, metadata: &Dict, paths: &PublishPaths, inbox: Option<&IntentInbox>) {
    store::ensure_session_spool_dir();
    if inbox.is_none() {
        discard_pending_command(&paths.command_path, &paths.meta_path);
    }
    let mut published = metadata.clone();
    published.insert("agent_prompt", text);
    if !published.get("authorization_relationship").is_some_and(Value::truthy) {
        let relationship = authorization::command_relationship(
            &published.string("action"),
            &published.string("reason"),
            &published.string("source_text"),
        );
        published.insert("authorization_relationship", relationship);
    }
    let mut disposition = published.get("work_disposition").and_then(Value::as_dict).cloned();
    let route = disposition.as_ref().map(|disposition| disposition.string("route")).unwrap_or_default();
    if let Some(inbox) = inbox
        && route != IntentRoute::RunSidecar.as_str()
        && published.get("recovery_generation").is_some_and(Value::truthy)
    {
        let generation = published.string("recovery_generation");
        let before = published.get("relay_command_seq").and_then(Value::py_int);
        let session_key = published.string("voice_target_session_key");
        if let Err(error) = inbox.retire_stale_foreground(
            &generation,
            &paths.command_path,
            &paths.meta_path,
            before,
            Some(&session_key),
        ) {
            eprintln!("[voice_bridge] Could not retire stale foreground work: {error}");
        }
    }
    if let Some(inbox) = inbox
        && route == IntentRoute::ReplaceCurrent.as_str()
    {
        if !published.get("cancellation_scope").is_some_and(Value::truthy)
            && !disposition
                .as_ref()
                .is_some_and(|disposition| disposition.get("cancellation_scope").is_some_and(Value::truthy))
        {
            published.insert("cancellation_scope", CancellationScope::AllWork.as_str());
        }
        let cancelled = inbox
            .cancel_scoped(&published, Some(&paths.command_path), Some(&paths.meta_path))
            .unwrap_or_else(|error| {
                eprintln!("[voice_bridge] Could not cancel scoped work: {error}");
                Vec::new()
            });
        release_cancelled_leases(&cancelled);
        if !cancelled.is_empty() {
            let ids = Value::List(cancelled.iter().map(|id| Value::from(id.as_str())).collect());
            published.insert("target_intent_ids", ids.clone());
            if let Some(Value::Dict(item)) = published.get("voice_work_item").cloned() {
                let mut item = item;
                item.insert("target_intent_ids", ids.clone());
                published.insert("voice_work_item", item);
            }
            if let Some(current) = disposition.as_mut() {
                current.insert("target_work_ids", ids.clone());
                current.insert("conflicting_work_ids", ids.clone());
                published.insert("work_disposition", current.clone());
            }
            if published
                .get("cancellation_scope")
                .is_some_and(|scope| scope.is_str("item") || scope.is_str("ticket"))
            {
                published.insert("provider_preempt_intent_ids", ids);
            }
        }
    }
    {
        let _guard = store::voice_state_lock();
        if let Err(error) = store::write_command_state(&paths.state_path, &published) {
            eprintln!("[voice_bridge] Could not write the command state: {error}");
        }
    }
    if let Some(authorization_path) = paths.authorization_path.as_deref().filter(|path| !path.is_empty()) {
        let allowed = if published.get("lifecycle_state").is_some_and(|state| state.is_str("cancelled")) {
            Vec::new()
        } else {
            authorization::allowed_mutations_for_metadata(&published)
        };
        if let Err(error) = authorization::record_command_authorization(
            authorization_path,
            &published,
            &published.string("authorization_relationship"),
            Some(allowed),
            &targets::authorization_session_key(&published),
            None,
        ) {
            eprintln!("[voice_bridge] Could not record Relay mutation authorization: {error}");
        }
    }
    let Some(inbox) = inbox else {
        if let Err(error) = store::atomic_write_json(&paths.meta_path, &published) {
            eprintln!("[voice_bridge] Could not write the mailbox metadata: {error}");
        }
        if let Err(error) = store::write_cmd_file(text, &paths.command_path) {
            eprintln!("[voice_bridge] Could not write the mailbox: {error}");
        }
        return;
    };
    let route = if route.is_empty() { "continue_current".to_string() } else { route };
    let stored = match inbox.enqueue(text, &published, &route) {
        Ok(stored) => stored,
        Err(error) => {
            eprintln!("[voice_bridge] Could not queue the voice command: {error}");
            return;
        }
    };
    {
        let _guard = store::voice_state_lock();
        if let Err(error) = store::write_command_state(&paths.state_path, &stored) {
            eprintln!("[voice_bridge] Could not write the command state: {error}");
        }
        if let Err(error) = store::sync_deliverable_state(&paths.state_path, inbox) {
            eprintln!("[voice_bridge] Could not sync intent inbox state: {error}");
        }
    }
    materialize_next(inbox, &paths.command_path, &paths.meta_path, &paths.transport);
    let _guard = store::voice_state_lock();
    if let Err(error) = store::sync_deliverable_state(&paths.state_path, inbox) {
        eprintln!("[voice_bridge] Could not sync intent inbox state: {error}");
    }
}

/// `_enqueue_sidecar_intent`: route an eligible sidecar without occupying
/// the foreground provider mailbox.
pub fn enqueue_sidecar_intent(bridge: &Bridge, prompt: &str, source_text: &str, metadata: &Dict, state_path: &str) -> bool {
    let mut stored = metadata.clone();
    stored.insert("agent_prompt", prompt);
    let inbox = bridge.inbox();
    if let Some(inbox) = &inbox {
        match inbox.enqueue(prompt, &stored, IntentRoute::RunSidecar.as_str()) {
            Ok(enqueued) => stored = enqueued,
            Err(error) => eprintln!("[voice_bridge] Could not queue the sidecar intent: {error}"),
        }
    }
    {
        let _guard = store::voice_state_lock();
        if let Err(error) = store::write_command_state(state_path, &stored) {
            eprintln!("[voice_bridge] Could not write the command state: {error}");
        }
        if let Some(inbox) = &inbox
            && let Err(error) = store::sync_deliverable_state(state_path, inbox)
        {
            eprintln!("[voice_bridge] Could not sync intent inbox state: {error}");
        }
    }
    drop(inbox);
    bridge.sidecar().is_some_and(|sidecar| sidecar.submit(source_text, &stored))
}

const VOICE_PAUSED_TEXT: &str = "Voice is paused. Message {seq} has an uncertain outcome, so I'm holding this request. \
     Open the Workspace and skip that message to continue.";

/// `_announce_voice_paused`: say that an uncertain message holds this turn
/// instead of going silent (RR-447).
pub fn announce_voice_paused(bridge: &Bridge, inbox: &IntentInbox, command: &Dict, state_path: &str) -> bool {
    let Ok(Some(blocker)) = inbox.recovery_blocker() else {
        return false;
    };
    if command.get("intent_id").is_some_and(|id| id.is_str(&blocker.intent_id)) {
        return false;
    }
    let text = VOICE_PAUSED_TEXT.replace("{seq}", &blocker.command_seq.to_string());
    if let Some(messenger) = bridge.messenger() {
        let mut trace = Dict::new();
        trace.insert("kind", "voice-paused");
        trace.insert("message", text.as_str());
        trace.insert("command", command.clone());
        if messenger.submit_trace(trace) {
            return true;
        }
    }
    speech::queue_tts_text(
        bridge.speech(),
        &text,
        TtsOptions {
            state_path: state_path.to_string(),
            allow_pending_command: true,
            dedup_key: Some(format!(
                "voice-paused:{}:{}",
                blocker.intent_id,
                command.get("intent_id").map(Value::py_str).unwrap_or_else(|| "None".to_string())
            )),
            ..TtsOptions::default()
        },
    )
}
