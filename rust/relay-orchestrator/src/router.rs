//! `Handler._route`: every route, tested in the Python daemon's order.
//!
//! The order matters where paths overlap (`/v1/artifacts/history/search`
//! before `/v1/artifacts/history/{artifact_id}`, the personal-storage and
//! General task prefixes before everything else), so this is one function
//! that reads like the Python `if` chain rather than a table. Each handler
//! takes the whole request and answers its status and body; the domain
//! modules own the field reading so each route reads its body as Python
//! does.

use relay_intents::json::{Dict, Value};

use crate::daemon::Daemon;
use crate::failure::Outcome;
use crate::http::SERVER_VERSION;
use crate::request::Request;

/// A route's answer: status and JSON body.
pub type Reply = (u16, Value);

/// `(status, payload)` for a dict body.
pub fn reply(status: u16, body: Dict) -> Outcome<Reply> {
    Ok((status, Value::Dict(body)))
}

/// One key and value as a dict.
pub fn single(key: &str, value: impl Into<Value>) -> Dict {
    let mut dict = Dict::new();
    dict.insert(key, value);
    dict
}

/// `_route(method, path)`: the status and body, or `None` when the failure
/// escapes the handler and the connection must close unanswered.
pub fn route(daemon: &Daemon, request: &Request) -> Option<Reply> {
    match dispatch(daemon, request) {
        Ok(reply) => Some(reply),
        Err(failure) => failure.response(),
    }
}

fn dispatch(daemon: &Daemon, request: &Request) -> Outcome<Reply> {
    let method = request.method.as_str();
    let s = request.parts();
    let get = method == "GET";
    let post = method == "POST";
    let n = s.len();
    let prefix = |head: &[&str]| s.len() >= head.len() && s[..head.len()] == *head;
    let is = |path: &[&str]| s == path;

    if get && is(&["v1", "health"]) {
        let mut body = Dict::new();
        body.insert("ok", true);
        body.insert("version", SERVER_VERSION);
        return reply(200, body);
    }

    if prefix(&["v1", "personal-storage"])
        && let Some(answer) = crate::personal::route(daemon, request)
    {
        return answer;
    }

    if prefix(&["v1", "general", "tasks"]) {
        if get && n == 3 {
            return daemon.general_task_list(request);
        }
        if get && n == 4 {
            return daemon.general_task_get(request);
        }
        if post {
            return daemon.general_task_post(request);
        }
    }

    if get && is(&["v1", "artifacts", "rollout"]) {
        return daemon.artifact_rollout_status(request);
    }
    if get && is(&["v1", "artifacts", "retention", "preview"]) {
        return daemon.artifact_retention_preview(request);
    }
    if get && is(&["v1", "artifacts", "retention", "status"]) {
        return daemon.artifact_retention_status(request);
    }
    if get && is(&["v1", "artifacts", "storage"]) {
        return daemon.artifact_storage_metrics(request);
    }
    if get && is(&["v1", "artifacts", "history", "search"]) {
        return daemon.artifact_history_search(request);
    }
    if get && is(&["v1", "artifacts", "notes"]) {
        return daemon.artifact_note_list(request);
    }
    if get && n == 4 && prefix(&["v1", "artifacts", "notes"]) {
        return daemon.artifact_note_get(request);
    }
    if get && n == 4 && prefix(&["v1", "artifacts", "history"]) {
        return daemon.artifact_history_detail(request);
    }
    if get && n == 6 && prefix(&["v1", "artifacts", "history"]) && s[4] == "attachments" {
        return daemon.artifact_history_attachment(request);
    }
    if get && n == 4 && prefix(&["v1", "artifacts", "dependencies"]) {
        return daemon.artifact_dependency_summary(request);
    }
    if get && is(&["v1", "runs"]) {
        return daemon.list_runs_route(request);
    }
    if get && is(&["v1", "queue-drains"]) {
        return daemon.list_queue_drains_route(request);
    }
    if get && is(&["v1", "program", "status"]) {
        return daemon.program_status_route(request);
    }
    if get && is(&["v1", "program", "dashboard"]) {
        return daemon.program_dashboard_route(request);
    }
    if get && is(&["v1", "orchestrator-sessions"]) {
        return daemon.list_orchestrator_sessions_route(request);
    }
    if get && is(&["v1", "messenger", "outcomes"]) {
        return daemon.pending_messenger_outcomes_route(request);
    }
    if post && n == 5 && prefix(&["v1", "messenger", "outcomes"]) && s[4] == "delivered" {
        return daemon.mark_messenger_outcome_delivered_route(request);
    }
    if post && n == 5 && prefix(&["v1", "messenger", "outcomes"]) && s[4] == "attempt" {
        return daemon.record_messenger_outcome_attempt_route(request);
    }
    if post && is(&["v1", "orchestrator-session", "ensure"]) {
        return daemon.ensure_orchestrator_session_route(request);
    }
    if post && is(&["v1", "orchestrator-session", "heartbeat"]) {
        return daemon.heartbeat_orchestrator_session_route(request);
    }
    if post && is(&["v1", "continuity", "observation"]) {
        return daemon.observe_continuity_event_route(request);
    }
    if post && is(&["v1", "orchestrator-session", "stop"]) {
        return daemon.stop_orchestrator_session_route(request);
    }
    if post && is(&["v1", "orchestrator-session", "command"]) {
        return daemon.record_orchestrator_command_route(request);
    }
    if post && is(&["v1", "program", "capture"]) {
        return daemon.session_capture_route(request);
    }
    if post && is(&["v1", "artifacts", "retention", "apply"]) {
        return daemon.artifact_retention_apply(request);
    }
    if post && is(&["v1", "artifacts", "retention", "retry"]) {
        return daemon.artifact_retention_retry(request);
    }
    if post
        && n == 5
        && prefix(&["v1", "artifacts", "history"])
        && (s[4] == "restore" || s[4] == "reopen")
    {
        return daemon.artifact_history_restore(request);
    }
    if post && is(&["v1", "artifacts", "tickets", "claim-next-id"]) {
        return daemon.artifact_board_claim_next_id(request);
    }
    if post && is(&["v1", "artifacts", "notes", "create"]) {
        return daemon.artifact_note_create(request);
    }
    if post && n == 5 && prefix(&["v1", "artifacts", "notes"]) && s[4] == "update" {
        return daemon.artifact_note_update(request);
    }
    if post && n == 5 && prefix(&["v1", "artifacts", "notes"]) && s[4] == "retry-metadata" {
        return daemon.artifact_note_metadata_retry(request);
    }
    if post && n == 5 && prefix(&["v1", "artifacts", "notes"]) && s[4] == "archive" {
        return daemon.artifact_note_archive(request);
    }
    if post
        && n == 5
        && prefix(&["v1", "artifacts", "notes"])
        && (s[4] == "delete" || s[4] == "cancel")
    {
        return daemon.artifact_note_delete(request);
    }
    if post && is(&["v1", "artifacts", "tickets", "write"]) {
        return daemon.artifact_board_write_ticket(request);
    }
    if post && is(&["v1", "artifacts", "tickets", "delete"]) {
        return daemon.artifact_board_delete_ticket(request);
    }
    if post && is(&["v1", "artifacts", "attachments", "write"]) {
        return daemon.artifact_board_write_attachment(request);
    }
    if post && is(&["v1", "orchestrator-actions"]) {
        return daemon.apply_orchestrator_actions_route(request);
    }
    if get && n == 3 && prefix(&["v1", "continuity-reports"]) {
        return daemon.get_continuity_report_route(request);
    }
    if post
        && n == 6
        && prefix(&["v1", "continuity-reports"])
        && s[3] == "proposals"
        && s[5] == "review"
    {
        return daemon.review_continuity_proposal_route(request);
    }
    if post && is(&["v1", "spikes", "follow-ups", "propose"]) {
        return daemon.propose_spike_followups_route(request);
    }
    if post
        && n == 7
        && prefix(&["v1", "spikes", "follow-ups"])
        && s[4] == "proposals"
        && s[6] == "review"
    {
        return daemon.review_spike_followup_route(request);
    }
    if post && is(&["v1", "runs"]) {
        return daemon.dispatch_route(request);
    }
    if post && is(&["v1", "ready-sweep"]) {
        return daemon.sweep_ready_tickets_route(request);
    }
    if post && is(&["v1", "program", "ready-sweep"]) {
        return daemon.sweep_program_ready_tickets_route(request);
    }
    if post && is(&["v1", "queue-drain", "reconcile"]) {
        return daemon.reconcile_queue_drains_route(request);
    }
    if post && n == 4 && prefix(&["v1", "queue-drains"]) && s[3] == "cancel" {
        return daemon.cancel_queue_drain_route(request);
    }
    if get && n == 3 && prefix(&["v1", "runs"]) {
        return daemon.get_run_route(request);
    }
    if post && n == 4 && prefix(&["v1", "runs"]) && s[3] == "outcome" {
        return daemon.submit_worker_outcome_route(request);
    }
    if get && n == 4 && prefix(&["v1", "runs"]) && s[3] == "outcome" {
        return daemon.get_worker_outcome_route(request);
    }
    if get && n == 4 && prefix(&["v1", "runs"]) && s[3] == "review" {
        return daemon.inspect_run_for_review_route(request);
    }
    if post && n == 4 && prefix(&["v1", "runs"]) && s[3] == "review" {
        return daemon.dispatch_review_worker_route(request);
    }
    if post && n == 5 && prefix(&["v1", "runs"]) && s[3] == "review" && s[4] == "decision" {
        return daemon.review_decision_route(request);
    }
    if post && n == 4 && prefix(&["v1", "runs"]) && s[3] == "cancel" {
        return daemon.cancel_run_route(request);
    }
    if post && is(&["v1", "runs", "reconcile-preserved"]) {
        return daemon.reconcile_preserved_run_route(request);
    }
    if post && is(&["v1", "runs", "recover-preserved-collision"]) {
        return daemon.recover_preserved_run_collision_route(request);
    }
    if post && n == 4 && prefix(&["v1", "runs"]) && s[3] == "resume-verification" {
        return daemon.resume_verification_blocked_route(request);
    }
    reply(
        404,
        single("error", format!("no route for {method} {}", request.path)),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_builds_a_one_key_dict() {
        assert_eq!(single("ok", true).string("ok"), "True");
    }
}
