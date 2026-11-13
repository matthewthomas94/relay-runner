//! The provider-neutral messenger runtime of `services/messenger.py`
//! (`MessengerRuntime` and `create_messenger_runtime`), above the provider
//! backends in `crate::messenger` (RR-492). The bridge links those backends
//! in process; it does not run `relay-rs messenger`.
//!
//! One worker thread turns user turns and public orchestrator events into
//! prompts for the backend and hands what to say to the bridge's `speak`.
//! Progress and lifecycle answers are arbitrated against the speech that
//! already played for the command; authoritative finals are spoken word for
//! word without asking the messenger. Both providers share all of it.

use std::collections::{HashMap, HashSet, VecDeque};
use std::mem;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex, MutexGuard};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use relay_intents::model::{CommandKey as RelayCommandKey, normalize_recovery_generation};
use relay_intents::pattern::{self, Regex};

use crate::json::{self, Dict, Value, py_eq_optional, py_is_space, py_strip};
use crate::messenger::{self, Backend, Config, Partial, SILENT_RESPONSE};
use crate::support::{env_or, now};

use super::command_actions::is_relay_runner_self_explanation;
use super::pm_frontstage::LIFECYCLE_DETAIL_TRACE_KINDS;
use super::ports::{Event, Messenger};

pub const MESSENGER_DEGRADED_TEXT: &str = concat!(
    "I couldn't produce a fast response, but your request is still with the ",
    "foreground session."
);
pub const RELAY_RUNNER_DEMO_EXPLANATION: &str = concat!(
    "Relay Runner is a local macOS workspace that turns natural conversation ",
    "into visible, coordinated software work. It organizes requests into tickets, ",
    "runs coding agents in isolated workspaces, and tracks progress through testing, ",
    "review, and integration."
);
/// `MessengerRuntime`'s `context_limit` and `response_timeout` defaults.
pub const CONTEXT_LIMIT: usize = 16;
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(60);

const PROTECTED_LIFECYCLE_ROLES: [&str; 4] = ["result", "failure", "blocker", "decision"];
const LIFECYCLE_ROLES_BY_DETAIL: [(&str, &str); 12] = [
    ("clarification-request", "decision"),
    ("run-canceled", "failure"),
    ("run-failed", "failure"),
    ("run-health-warning", "blocker"),
    ("run-review-needed", "blocker"),
    ("run-reconciled", "result"),
    ("run-integration-blocked", "blocker"),
    ("run-verification-blocked", "blocker"),
    ("run-verification-resumed", "decision"),
    ("run-merged", "result"),
    ("run-succeeded", "result"),
    ("sidecar-outcome", "result"),
];
const SEMANTIC_STOPWORDS: [&str; 37] = [
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for", "from", "i", "in", "is",
    "it", "me", "my", "of", "on", "or", "our", "so", "that", "the", "their", "them", "they",
    "this", "to", "was", "we", "were", "with", "you", "your", "youre",
];
const WORK_LIFECYCLE_KINDS: [&str; 1] = ["sidecar-outcome"];
const PROMPT_CONTEXT_ENTRY_LIMIT: usize = 4;
const PROMPT_CONTEXT_ENTRY_CHAR_LIMIT: usize = 640;

static SEMANTIC_TOKEN: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"[a-z0-9]+(?:[-_.:/][a-z0-9]+)*", true));
static USER_RESPONSE_ROLE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^__(?P<role>ANSWER|HANDOFF)__\s*(?::|-)?\s*", true));
static HANDOFF_RESPONSE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"\b(?:",
            r"(?:received|picked\s+up|understood)\b.{0,100}\b(?:request|task|question)",
            r"|(?:i|we)\s+(?:will|(?:'|’)ll|am\s+going\s+to|are\s+going\s+to)\s+",
            r"(?:check|confirm|find|inspect|investigate|look|open|report|review|run|use|verify)",
            r"|(?:come|get)\s+back\b|report\s+back\b|return\s+with\b",
            r")",
        ),
        true,
    )
});

/// What the runtime calls back into the bridge with; the keyword arguments
/// of `create_messenger_runtime`.
pub struct Callbacks {
    pub speak: Speak,
    pub is_current: IsCurrent,
    pub coverage_provider: Option<CoverageProvider>,
    pub realization_observer: Option<RealizationObserver>,
    pub timing_observer: Option<TimingObserver>,
    pub continuity_observer: Option<ContinuityObserver>,
}

/// `speak(text, command_seq, command_id, display_text, speech_metadata)`;
/// the sequence and id are `None` for an unscoped lifecycle event.
pub type Speak =
    Box<dyn Fn(&str, Option<i64>, Option<&str>, Option<&str>, &Dict) -> bool + Send + Sync>;
/// `is_current(command_seq, command_id)`.
pub type IsCurrent = Box<dyn Fn(i64, &str) -> bool + Send + Sync>;
/// `coverage_provider(command_seq, command_id)`: the speech that finished
/// playing for a command, oldest first.
pub type CoverageProvider = Box<dyn Fn(i64, &str) -> Vec<Dict> + Send + Sync>;
/// `realization_observer(command_seq, command_id, lifecycle_role=, decision=,
/// reason=)`.
pub type RealizationObserver = Box<dyn Fn(i64, &str, &str, &str, &str) + Send + Sync>;
/// `timing_observer(stage, command_seq, command_id, at=, provider=,
/// outcome=)`, in `Speech::record_messenger_stage`'s order.
pub type TimingObserver =
    Box<dyn Fn(&str, i64, &str, Option<f64>, Option<&str>, &str) + Send + Sync>;
/// `continuity_observer({"event", "relay_command_id", "provider",
/// "recovery_generation"})`.
pub type ContinuityObserver = Box<dyn Fn(&Dict) + Send + Sync>;

/// `_command_key`'s `(relay_command_seq, relay_command_id)`.
type CommandKey = (i64, String);

fn command_key(command: &Dict) -> Option<CommandKey> {
    RelayCommandKey::of(command).map(|key| (key.seq, key.id))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    UserTurn,
    OrchestratorTrace,
    OrchestratorFinal,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::UserTurn => "user_turn",
            Kind::OrchestratorTrace => "orchestrator_trace",
            Kind::OrchestratorFinal => "orchestrator_final",
        }
    }
}

/// `_MessengerEvent`. `command` holds `command_seq` and `command_id`, which
/// are always both set or both `None`.
#[derive(Debug)]
struct MessengerEvent {
    kind: Kind,
    text: String,
    command: Option<CommandKey>,
    generation: u64,
    detail: String,
    work_disposition: Option<Dict>,
    speech_source: String,
    work_lifecycle: bool,
    action_kind: String,
}

/// `_SpeechRealization`.
struct Realization {
    decision: &'static str,
    spoken_text: String,
    lifecycle_role: &'static str,
    covered_facts: Vec<String>,
    reason: &'static str,
}

/// A partition's live state, parked while another session is focused.
struct Parked {
    context: VecDeque<String>,
    generation: u64,
    current_command: Option<CommandKey>,
}

/// What `MessengerRuntime._lock` guards.
struct State {
    context: VecDeque<String>,
    context_limit: usize,
    generation: u64,
    current_command: Option<CommandKey>,
    // RR-402: the live fields above belong to the focused partition; other
    // sessions' state is parked here until refocused.
    partition_key: String,
    parked_partitions: HashMap<String, Parked>,
    bound_partition: String,
    final_commands: Vec<CommandKey>,
    // RR-460: a missing-reply fallback never claims the real final's slot.
    fallback_final_commands: Vec<CommandKey>,
    active_event: Option<Arc<MessengerEvent>>,
    /// In insertion order, as the Python dict prunes its oldest entries.
    action_kinds: Vec<(CommandKey, String)>,
    work_dispositions: HashMap<CommandKey, Dict>,
    user_response_texts: HashMap<CommandKey, String>,
    user_response_roles: HashMap<CommandKey, String>,
    conversation_commands_answered: HashSet<CommandKey>,
    started: bool,
    worker: Option<ThreadId>,
}

impl State {
    /// `self._context.append(entry)` on a bounded deque.
    fn push_context(&mut self, entry: String) {
        while self.context.len() >= self.context_limit {
            self.context.pop_front();
        }
        self.context.push_back(entry);
    }

    fn action_kind(&self, key: &CommandKey) -> Option<&str> {
        self.action_kinds
            .iter()
            .find(|(existing, _)| existing == key)
            .map(|(_, kind)| kind.as_str())
    }

    /// `self._action_kinds[key] = kind`: a known key keeps its position.
    fn set_action_kind(&mut self, key: &CommandKey, kind: &str) {
        match self
            .action_kinds
            .iter_mut()
            .find(|(existing, _)| existing == key)
        {
            Some(entry) => entry.1 = kind.to_string(),
            None => self.action_kinds.push((key.clone(), kind.to_string())),
        }
    }

    /// Forgets the 50 oldest commands once more than 100 are remembered.
    fn prune_commands(&mut self) {
        if self.action_kinds.len() <= 100 {
            return;
        }
        for (old, _) in self.action_kinds.drain(..50).collect::<Vec<_>>() {
            self.work_dispositions.remove(&old);
            self.user_response_texts.remove(&old);
            self.user_response_roles.remove(&old);
            self.conversation_commands_answered.remove(&old);
        }
    }

    fn set_answered(&mut self, key: &CommandKey, answered: bool) {
        if answered {
            self.conversation_commands_answered.insert(key.clone());
        } else {
            self.conversation_commands_answered.remove(key);
        }
    }

    fn finals(&mut self, fallback: bool) -> &mut Vec<CommandKey> {
        if fallback {
            &mut self.fallback_final_commands
        } else {
            &mut self.final_commands
        }
    }
}

/// `MessengerRuntime`: a non-blocking event pump shared by both provider
/// backends.
pub struct MessengerRuntime {
    inner: Arc<Inner>,
}

struct Inner {
    backend: Arc<dyn Backend>,
    /// `backend.config.provider`, when the backend has a config.
    provider: Option<String>,
    callbacks: Callbacks,
    response_timeout: Duration,
    recovery_generation: String,
    state: Mutex<State>,
    /// `_events`; `None` is the shutdown sentinel. Locked after `state` when
    /// both are held.
    events: Mutex<VecDeque<Option<Arc<MessengerEvent>>>>,
    queued: Condvar,
    shutdown: Event,
    finished: Event,
    recovery_lock: Mutex<()>,
}

impl MessengerRuntime {
    /// `MessengerRuntime(backend, ...)`. `recovery_generation` is already
    /// normalised.
    pub fn new(
        backend: Arc<dyn Backend>,
        provider: Option<String>,
        callbacks: Callbacks,
        context_limit: usize,
        recovery_generation: String,
    ) -> Self {
        let context_limit = context_limit.max(4);
        let state = State {
            context: VecDeque::new(),
            context_limit,
            generation: 0,
            current_command: None,
            partition_key: String::new(),
            parked_partitions: HashMap::new(),
            bound_partition: String::new(),
            final_commands: Vec::new(),
            fallback_final_commands: Vec::new(),
            active_event: None,
            action_kinds: Vec::new(),
            work_dispositions: HashMap::new(),
            user_response_texts: HashMap::new(),
            user_response_roles: HashMap::new(),
            conversation_commands_answered: HashSet::new(),
            started: false,
            worker: None,
        };
        let inner = Inner {
            backend,
            provider,
            callbacks,
            response_timeout: RESPONSE_TIMEOUT,
            recovery_generation,
            state: Mutex::new(state),
            events: Mutex::new(VecDeque::new()),
            queued: Condvar::new(),
            shutdown: Event::default(),
            finished: Event::default(),
            recovery_lock: Mutex::new(()),
        };
        Self {
            inner: Arc::new(inner),
        }
    }

    /// `context_size`.
    #[cfg(test)]
    pub fn context_size(&self) -> usize {
        self.inner.lock().context.len()
    }
}

impl Messenger for MessengerRuntime {
    fn start(&self) {
        self.inner.start();
    }

    fn submit_user(&self, text: &str, command: &Dict) -> bool {
        self.inner.submit_user(text, command)
    }

    fn update_user_context(&self, command: &Dict) -> bool {
        self.inner.update_user_context(command)
    }

    fn submit_trace(&self, trace: Dict) -> bool {
        self.inner.submit_trace(&trace)
    }

    fn submit_final(&self, payload: Dict) -> bool {
        self.inner.submit_final(&payload)
    }

    fn focus(&self, partition_key: &str) -> bool {
        self.inner.focus(partition_key)
    }

    fn interrupt(&self) {
        self.inner.interrupt();
    }

    fn recover_backend(&self) -> bool {
        self.inner.recover_backend()
    }

    fn shutdown(&self) {
        self.inner.shutdown();
    }
}

/// `create_messenger_runtime(app_config, cwd=..., speak=..., ...)`: `None`
/// when `[general] messenger_enabled` is off.
pub fn create_messenger_runtime(
    app_config: &Dict,
    cwd: &str,
    callbacks: Callbacks,
) -> Option<Arc<MessengerRuntime>> {
    let general = app_config
        .get("general")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    let config = Config::from_general(&general, cwd);
    if !config.enabled {
        eprintln!("[messenger] disabled by config");
        return None;
    }
    let (backend, config, _unavailable) = messenger::create(config);
    let mut generation = env_or("RELAY_RECOVERY_GENERATION", "");
    if generation.is_empty() {
        generation = "0".to_string();
    }
    let generation = normalize_recovery_generation(&Value::Str(generation)).unwrap_or_else(|| {
        eprintln!("[messenger] invalid recovery generation; using 0");
        "0".to_string()
    });
    Some(Arc::new(MessengerRuntime::new(
        backend,
        Some(config.provider),
        callbacks,
        CONTEXT_LIMIT,
        generation,
    )))
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    fn put(&self, event: Option<Arc<MessengerEvent>>) {
        self.events.lock().unwrap().push_back(event);
        self.queued.notify_one();
    }

    fn get(&self) -> Option<Arc<MessengerEvent>> {
        let mut events = self.events.lock().unwrap();
        loop {
            if let Some(event) = events.pop_front() {
                return event;
            }
            events = self.queued.wait(events).unwrap();
        }
    }

    fn start(self: &Arc<Self>) {
        {
            let mut state = self.lock();
            if state.started {
                return;
            }
            state.started = true;
            let inner = Arc::clone(self);
            let worker = thread::Builder::new()
                .name("relay-messenger".into())
                .spawn(move || {
                    inner.run();
                    inner.finished.set();
                });
            if let Ok(worker) = worker {
                state.worker = Some(worker.thread().id());
            }
        }
        let inner = Arc::clone(self);
        let _ = thread::Builder::new()
            .name("relay-messenger-warmup".into())
            .spawn(move || inner.warm_backend());
    }

    fn submit_user(&self, text: &str, command: &Dict) -> bool {
        let cleaned = py_strip(text);
        let Some(key) = command_key(command).filter(|_| !cleaned.is_empty()) else {
            return false;
        };
        let disposition = command
            .get("work_disposition")
            .and_then(Value::as_dict)
            .cloned();
        let route = disposition
            .as_ref()
            .map(|disposition| disposition.text("route").to_lowercase())
            .unwrap_or_default();
        let action_kind = if is_relay_runner_self_explanation(cleaned) {
            "self_explanation"
        } else if route == "continue_current" {
            "conversation"
        } else if !route.is_empty() {
            "work"
        } else {
            "pending"
        };
        let (generation, supersedes) = {
            let mut state = self.lock();
            let supersedes = state.current_command.is_some();
            state.generation += 1;
            state.current_command = Some(key.clone());
            state.set_action_kind(&key, action_kind);
            let stored = disposition
                .as_ref()
                .filter(|disposition| !disposition.is_empty());
            if let Some(stored) = stored {
                state.work_dispositions.insert(key.clone(), stored.clone());
            }
            state.prune_commands();
            state.push_context(format!("USER: {cleaned}"));
            if let Some(stored) = stored {
                state.push_context(disposition_context(stored));
            }
            self.discard_pending_events();
            (state.generation, supersedes)
        };
        if supersedes {
            self.backend.interrupt();
        }
        self.observe_timing("messenger_submitted", Some(&key), "ok");
        let detail = disposition
            .as_ref()
            .map(|disposition| disposition.string("route"))
            .unwrap_or_default();
        self.put(Some(Arc::new(MessengerEvent {
            kind: Kind::UserTurn,
            text: cleaned.to_string(),
            command: Some(key),
            generation,
            detail,
            work_disposition: disposition,
            speech_source: String::new(),
            work_lifecycle: false,
            action_kind: action_kind.to_string(),
        })));
        true
    }

    /// `update_user_context`: attaches deterministic routing context without
    /// delaying the messenger's start.
    fn update_user_context(&self, command: &Dict) -> bool {
        let key = command_key(command);
        let disposition = command.get("work_disposition").and_then(Value::as_dict);
        let (Some(key), Some(disposition)) = (key, disposition) else {
            return false;
        };
        let route = disposition.text("route").to_lowercase();
        let source_text = command.text("source_text");
        let mut state = self.lock();
        if state.current_command.as_ref() != Some(&key) {
            return false;
        }
        let action_kind = if is_relay_runner_self_explanation(&source_text) {
            "self_explanation"
        } else if route == "continue_current" {
            "conversation"
        } else {
            "work"
        };
        state.set_action_kind(&key, action_kind);
        state
            .work_dispositions
            .insert(key.clone(), disposition.clone());
        if let Some(response_text) = state.user_response_texts.get(&key) {
            let (_, role) = user_response_role(response_text, action_kind);
            state
                .user_response_roles
                .insert(key.clone(), role.to_string());
        }
        let answered = action_kind == "conversation"
            && state.user_response_roles.get(&key).map(String::as_str) == Some("answer");
        state.set_answered(&key, answered);
        state.push_context(disposition_context(disposition));
        let (seq, id) = (Value::Int(key.0), Value::Str(key.1.clone()));
        let hints = command
            .get("intent_qualifications")
            .and_then(Value::as_list)
            .unwrap_or_default();
        for hint in hints.iter().filter_map(Value::as_dict) {
            if !py_eq_optional(hint.get("command_seq"), Some(&seq))
                || !py_eq_optional(hint.get("command_id"), Some(&id))
            {
                continue;
            }
            let Some(bucket) = hint.get("bucket").and_then(Value::as_str) else {
                continue;
            };
            if matches!(bucket, "task" | "action" | "discussion") {
                state.push_context(format!(
                    "PUBLIC INTENT QUALIFICATION: {bucket}; unresolved={}; mixed={}. \
                     Provisional only; the PM resolves scope and authority. Remain tool-free.",
                    py_bool(is_true(hint.get("unresolved"))),
                    py_bool(is_true(hint.get("mixed"))),
                ));
            }
        }
        true
    }

    fn submit_trace(&self, trace: &Dict) -> bool {
        let key = trace
            .get("command")
            .and_then(Value::as_dict)
            .and_then(command_key);
        let kind = trace.truthy("kind").map_or_else(
            || "progress".to_string(),
            |kind| py_strip(&kind.py_str()).to_lowercase(),
        );
        let summary = trace.text("message");
        let detail = trace.text("lifecycle_detail");
        let message = if detail.is_empty() { summary } else { detail };
        let work_lifecycle =
            WORK_LIFECYCLE_KINDS.contains(&kind.as_str()) && is_true(trace.get("work_valid"));
        let disposition = trace
            .get("work_disposition")
            .and_then(Value::as_dict)
            .cloned();
        if message.is_empty() {
            return false;
        }
        let (key, generation) = {
            let mut state = self.lock();
            if work_lifecycle {
                let Some(key) = key else {
                    return false;
                };
                if state.final_commands.contains(&key) {
                    return true;
                }
                state.final_commands.push(key.clone());
                if state.final_commands.len() > 100 {
                    state.final_commands.drain(..50);
                }
                state.push_context(format!("AUTHORITATIVE WORK LIFECYCLE ({kind}): {message}"));
                (Some(key), state.generation)
            } else if key.is_none() && LIFECYCLE_DETAIL_TRACE_KINDS.contains(&kind.as_str()) {
                state.push_context(format!("WORKER LIFECYCLE ({kind}): {message}"));
                (None, state.generation)
            } else {
                let key = key.or_else(|| state.current_command.clone());
                let Some(key) = key.filter(|key| state.current_command.as_ref() == Some(key))
                else {
                    return false;
                };
                state.push_context(format!("ORCHESTRATOR UPDATE ({kind}): {message}"));
                if kind == "clarification-request" {
                    self.discard_pending_kinds(&[Kind::OrchestratorTrace]);
                }
                (Some(key), state.generation)
            }
        };
        self.put(Some(Arc::new(MessengerEvent {
            kind: Kind::OrchestratorTrace,
            text: message,
            command: key,
            generation,
            detail: kind,
            work_disposition: disposition,
            speech_source: String::new(),
            work_lifecycle,
            action_kind: String::new(),
        })));
        true
    }

    fn submit_final(&self, payload: &Dict) -> bool {
        let key = match payload.get("relay_command").and_then(Value::as_dict) {
            Some(nested) => command_key(nested),
            None => command_key(payload),
        };
        let text = payload.text("text");
        let disposition = payload
            .get("work_disposition")
            .and_then(Value::as_dict)
            .cloned();
        if text.is_empty() {
            return false;
        }
        let speech_source = payload.string("speech_source");
        let fallback = speech_source == "fallback";
        let (key, generation, interrupt_handoff, action_kind) = {
            let mut state = self.lock();
            let key = key.or_else(|| state.current_command.clone());
            let Some(key) = key.filter(|key| state.current_command.as_ref() == Some(key)) else {
                return false;
            };
            if state.final_commands.contains(&key) || state.finals(fallback).contains(&key) {
                return true;
            }
            // A conversational turn the messenger answered itself stays quiet
            // only when the final adds nothing to that answer. A final with new
            // substance is still spoken; the answer's phrasing must never
            // decide whether the user hears the orchestrator.
            let answered = state.action_kind(&key) == Some("self_explanation")
                || (state.conversation_commands_answered.contains(&key) && {
                    let answer = state
                        .user_response_texts
                        .get(&key)
                        .map_or("", String::as_str);
                    preserves_authoritative_content(
                        &text,
                        &[],
                        &user_response_role(answer, "conversation").0,
                    )
                });
            if answered {
                state.finals(fallback).push(key);
                state.push_context(format!("AUTHORITATIVE ORCHESTRATOR FINAL: {text}"));
                return true;
            }
            let finals = state.finals(fallback);
            finals.push(key.clone());
            if finals.len() > 100 {
                finals.drain(..50);
            }
            let interrupt_handoff = state.active_event.as_ref().is_some_and(|active| {
                active.kind == Kind::UserTurn && active.command.as_ref() == Some(&key)
            });
            state.generation += 1;
            state.push_context(format!("AUTHORITATIVE ORCHESTRATOR FINAL: {text}"));
            self.discard_pending_kinds(&[Kind::UserTurn, Kind::OrchestratorTrace]);
            let action_kind = state.action_kind(&key).unwrap_or_default().to_string();
            (key, state.generation, interrupt_handoff, action_kind)
        };
        if interrupt_handoff {
            self.backend.interrupt();
        }
        let event = MessengerEvent {
            kind: Kind::OrchestratorFinal,
            text: text.clone(),
            command: Some(key),
            generation,
            detail: String::new(),
            work_disposition: disposition,
            speech_source: if speech_source.is_empty() {
                "orchestrator".to_string()
            } else {
                speech_source
            },
            work_lifecycle: false,
            action_kind,
        };
        if !self.event_is_current(&event) {
            return false;
        }
        let realization = Realization {
            decision: "full",
            spoken_text: text.clone(),
            lifecycle_role: lifecycle_role_for(&event),
            covered_facts: vec![text.clone()],
            reason: "authoritative_final_direct",
        };
        self.observe_realization(&event, &realization);
        let metadata = self.speech_metadata_for(&event, false, Some(&realization), Some(&text), "");
        self.speak(&text, &event, Some(&text), metadata);
        true
    }

    /// `focus`: switches the shared runtime to a session's context partition
    /// (RR-402). `false` when that partition is already focused. The provider
    /// re-binds lazily before the next ask, on the worker thread.
    fn focus(&self, partition_key: &str) -> bool {
        {
            let mut state = self.lock();
            if partition_key == state.partition_key {
                return false;
            }
            let parked = Parked {
                context: mem::take(&mut state.context),
                generation: state.generation,
                current_command: state.current_command.take(),
            };
            let previous = mem::replace(&mut state.partition_key, partition_key.to_string());
            state.parked_partitions.insert(previous, parked);
            if let Some(parked) = state.parked_partitions.remove(partition_key) {
                state.context = parked.context;
                state.generation = parked.generation;
                state.current_command = parked.current_command;
            }
            // Stay ahead of the old partition's generation so its queued or
            // in-flight events can never read as current here.
            state.generation += 1;
            self.discard_pending_events();
        }
        self.backend.interrupt();
        true
    }

    fn interrupt(&self) {
        {
            let mut state = self.lock();
            state.generation += 1;
            state.current_command = None;
            self.discard_pending_events();
        }
        self.backend.interrupt();
    }

    /// `_bind_backend_to_partition`.
    fn bind_backend_to_partition(&self) -> Result<(), String> {
        let key = {
            let state = self.lock();
            if state.partition_key == state.bound_partition {
                return Ok(());
            }
            state.partition_key.clone()
        };
        let started = Instant::now();
        self.backend.rebind(&key)?;
        self.lock().bound_partition = key;
        eprintln!(
            "[messenger] re-bound to focused session in {:.0} ms",
            started.elapsed().as_secs_f64() * 1000.0
        );
        Ok(())
    }

    /// `recover_backend`: recreates a dead provider backend without
    /// interrupting queued or live work.
    fn recover_backend(self: &Arc<Self>) -> bool {
        let _recovery = self.recovery_lock.lock().unwrap();
        {
            let state = self.lock();
            if self.shutdown.is_set()
                || state.active_event.is_some()
                || !self.events.lock().unwrap().is_empty()
            {
                return false;
            }
            self.backend.shutdown();
        }
        let inner = Arc::clone(self);
        let _ = thread::Builder::new()
            .name("relay-messenger-recovery".into())
            .spawn(move || inner.warm_backend());
        true
    }

    fn shutdown(&self) {
        if self.shutdown.is_set() {
            return;
        }
        self.shutdown.set();
        self.backend.interrupt();
        self.put(None);
        let worker = self.lock().worker;
        if let Some(worker) = worker
            && worker != thread::current().id()
        {
            self.finished.wait(2.0);
        }
        self.backend.shutdown();
    }

    fn warm_backend(&self) {
        match self.backend.start() {
            Ok(()) => {
                if self.shutdown.is_set() {
                    self.backend.shutdown();
                    return;
                }
                self.observe_continuity("progress", None);
                eprintln!("[messenger] persistent model process is warm");
            }
            Err(error) => {
                self.observe_continuity("failed", None);
                eprintln!("[messenger] warmup deferred after startup failure: {error}");
            }
        }
    }

    /// `_run`: the worker loop.
    fn run(self: &Arc<Self>) {
        while !self.shutdown.is_set() {
            let Some(event) = self.get() else {
                return;
            };
            if !self.event_is_current(&event) {
                continue;
            }
            let prompt = self.prompt_for(&event);
            self.lock().active_event = Some(Arc::clone(&event));
            let delivered_early = Arc::new(AtomicBool::new(false));
            let response = match self.ask(&event, &prompt, &delivered_early) {
                Ok(response) => {
                    self.clear_active_event(&event);
                    response
                }
                Err(error) => {
                    self.observe_continuity("failed", Some(&event));
                    if event.kind == Kind::UserTurn {
                        self.observe_timing(
                            "messenger_failed",
                            event.command.as_ref(),
                            "provider_unavailable",
                        );
                    }
                    eprintln!("[messenger] response failed: {error}");
                    if (event.kind == Kind::UserTurn || self.must_fail_open(&event))
                        && self.event_is_current(&event)
                    {
                        self.speak_fallback(&event, "arbitration_error");
                    }
                    self.clear_active_event(&event);
                    continue;
                }
            };
            self.observe_continuity("progress", Some(&event));
            if !self.event_is_current(&event) {
                continue;
            }
            // Claimed, not only read: a first sentence racing the completed
            // answer is spoken by whichever arrives first, never by both.
            if delivered_early.swap(true, Ordering::SeqCst) {
                continue;
            }
            if response.is_empty() || response == SILENT_RESPONSE {
                if self.must_fail_open(&event) || event.kind == Kind::UserTurn {
                    self.speak_fallback(&event, "arbitration_unavailable");
                }
                continue;
            }
            if event.kind == Kind::UserTurn {
                self.observe_timing(
                    "messenger_first_semantic_output",
                    event.command.as_ref(),
                    "ok",
                );
            }
            self.deliver_response(&event, &response);
        }
    }

    /// The `try` of `_run`: re-binds, then asks, streaming a user turn's
    /// first sentence to `deliver_partial`.
    fn ask(
        self: &Arc<Self>,
        event: &Arc<MessengerEvent>,
        prompt: &str,
        delivered_early: &Arc<AtomicBool>,
    ) -> Result<String, String> {
        self.bind_backend_to_partition()?;
        self.observe_continuity("progress", Some(event));
        let mut on_partial: Option<Partial> = None;
        if event.kind == Kind::UserTurn {
            self.observe_timing("messenger_provider_started", event.command.as_ref(), "ok");
            let (inner, event, guard) = (
                Arc::clone(self),
                Arc::clone(event),
                Arc::clone(delivered_early),
            );
            on_partial = Some(Box::new(move |response: String| {
                inner.deliver_partial(&event, &guard, &response);
            }));
        }
        let response = self
            .backend
            .ask(prompt, self.response_timeout, on_partial)?;
        Ok(py_strip(&response).to_string())
    }

    /// `deliver_partial`, bound to the event it was asked for.
    fn deliver_partial(&self, event: &MessengerEvent, guard: &AtomicBool, response: &str) {
        if guard.load(Ordering::SeqCst) || !self.event_is_current(event) {
            return;
        }
        if guard.swap(true, Ordering::SeqCst) {
            return;
        }
        self.observe_timing(
            "messenger_first_semantic_output",
            event.command.as_ref(),
            "ok",
        );
        self.deliver_response(event, response);
    }

    /// The `finally` of `_run`.
    fn clear_active_event(&self, event: &Arc<MessengerEvent>) {
        let mut state = self.lock();
        if state
            .active_event
            .as_ref()
            .is_some_and(|active| Arc::ptr_eq(active, event))
        {
            state.active_event = None;
        }
    }

    fn speak_fallback(&self, event: &MessengerEvent, reason: &'static str) {
        let realization = fallback_realization(event, reason);
        self.observe_realization(event, &realization);
        let metadata = self.speech_metadata_for(event, true, Some(&realization), None, "");
        self.speak(&realization.spoken_text, event, Some(&event.text), metadata);
    }

    /// `_deliver_response`.
    fn deliver_response(&self, event: &MessengerEvent, response: &str) {
        if !self.event_is_current(event) {
            return;
        }
        let mut response = response.to_string();
        let raw_response = response.clone();
        let mut role = "";
        if event.kind == Kind::UserTurn {
            let action_kind = self.action_kind_for(event);
            (response, role) = user_response_role(&raw_response, &action_kind);
        }
        let realization = self.realization_for(event, &response);
        if let Some(realization) = &realization {
            self.observe_realization(event, realization);
            if realization.decision == "suppress" {
                return;
            }
            response = realization.spoken_text.clone();
        }
        if response.is_empty() || response == SILENT_RESPONSE {
            return;
        }
        {
            let mut state = self.lock();
            state.push_context(format!("MESSENGER: {response}"));
            if event.kind == Kind::UserTurn
                && let Some(key) = &event.command
            {
                state.user_response_texts.insert(key.clone(), raw_response);
                state
                    .user_response_roles
                    .insert(key.clone(), role.to_string());
                let answered = state.action_kind(key) == Some("conversation") && role == "answer";
                state.set_answered(key, answered);
            }
        }
        let display_text = (event.kind != Kind::UserTurn).then_some(event.text.as_str());
        let metadata =
            self.speech_metadata_for(event, false, realization.as_ref(), Some(&response), role);
        self.speak(&response, event, display_text, metadata);
    }

    fn observe_timing(&self, stage: &str, command: Option<&CommandKey>, outcome: &str) {
        let (Some(observer), Some((seq, id))) = (&self.callbacks.timing_observer, command) else {
            return;
        };
        observer(
            stage,
            *seq,
            id,
            Some(now()),
            self.provider.as_deref(),
            outcome,
        );
    }

    fn observe_continuity(&self, lifecycle_event: &str, event: Option<&MessengerEvent>) {
        let Some(observer) = &self.callbacks.continuity_observer else {
            return;
        };
        let command_id = event
            .and_then(|event| event.command.as_ref())
            .map(|(_, id)| id.clone());
        let mut payload = Dict::new();
        payload.insert("event", lifecycle_event);
        payload.insert("relay_command_id", command_id);
        payload.insert("provider", self.provider.as_deref().unwrap_or("codex"));
        payload.insert("recovery_generation", self.recovery_generation.clone());
        observer(&payload);
    }

    fn event_is_current(&self, event: &MessengerEvent) -> bool {
        if event.work_lifecycle {
            return true;
        }
        let Some(key) = &event.command else {
            return true;
        };
        let current = {
            let state = self.lock();
            event.generation == state.generation && state.current_command.as_ref() == Some(key)
        };
        current && (self.callbacks.is_current)(key.0, &key.1)
    }

    fn must_fail_open(&self, event: &MessengerEvent) -> bool {
        event.kind == Kind::OrchestratorFinal
            || event.action_kind == "self_explanation"
            || event.detail == "clarification-request"
            || event_is_unscoped_lifecycle(event)
            || event.work_lifecycle
    }

    /// `self._action_kinds.get(key, event.action_kind)`.
    fn action_kind_for(&self, event: &MessengerEvent) -> String {
        let state = self.lock();
        event
            .command
            .as_ref()
            .and_then(|key| state.action_kind(key))
            .unwrap_or(&event.action_kind)
            .to_string()
    }

    /// `_prompt_for`.
    fn prompt_for(&self, event: &MessengerEvent) -> String {
        let context_entries: Vec<String> = {
            let state = self.lock();
            let skip = state
                .context
                .len()
                .saturating_sub(PROMPT_CONTEXT_ENTRY_LIMIT);
            state.context.iter().skip(skip).cloned().collect()
        };
        let context = context_entries
            .iter()
            .map(|entry| bounded_context_entry(entry))
            .collect::<Vec<_>>()
            .join("\n");
        let instructions = if event.kind == Kind::UserTurn
            && event.action_kind == "self_explanation"
        {
            format!(
                concat!(
                    "This is Relay Runner's demo-audience self-introduction. Answer it now in one ",
                    "or two concise, natural sentences; do not hand it off, promise a later answer, ",
                    "or mention internal orchestration. Ground the answer in these facts: ",
                    "{}"
                ),
                RELAY_RUNNER_DEMO_EXPLANATION
            )
        } else if event.kind == Kind::OrchestratorTrace && event.detail == "clarification-request" {
            concat!(
                "This is an authoritative clarification request from the orchestrator. Ask the ",
                "user the requested question directly and concisely."
            )
            .to_string()
        } else if event.work_lifecycle {
            concat!(
                "This is an authoritative completed sidecar outcome from accepted background ",
                "work. Convey its result naturally and concisely without treating its originating ",
                "conversation turn as current or adding unsupported claims."
            )
            .to_string()
        } else {
            match event.kind {
                Kind::UserTurn => USER_TURN_INSTRUCTIONS,
                Kind::OrchestratorTrace => TRACE_INSTRUCTIONS,
                Kind::OrchestratorFinal => FINAL_INSTRUCTIONS,
            }
            .to_string()
        };
        let mut realization_instructions = String::new();
        if self.uses_coverage_arbitration(event) {
            let coverage = self.coverage_for(event);
            let coverage = json::dumps_compact(&Value::List(
                coverage.into_iter().map(Value::Dict).collect(),
            ));
            realization_instructions = format!(
                concat!(
                    "\n\nSpeech that actually finished playing for this exact Relay command:\n",
                    "{}\n\n",
                    "The authoritative lifecycle role is {}; do not classify or change it. ",
                    "Return one JSON object with exactly these fields: decision (full, delta, or ",
                    "suppress) and spoken_text. Suppress only when the current ",
                    "event adds no lifecycle advance or user-relevant fact. Use delta when only part is ",
                    "novel. A result, failure, blocker, or critical decision must remain speakable; ",
                    "remove overlap but never its novel identifiers, outcomes, errors, decisions, or ",
                    "next steps. An acknowledgement never covers a later result."
                ),
                coverage,
                lifecycle_role_for(event),
            );
        }
        let closing = if !realization_instructions.is_empty() {
            "Return only the JSON object."
        } else if event.kind == Kind::UserTurn {
            "Return only the role-prefixed words to speak, or __SILENT__."
        } else {
            "Return only the exact words to speak, or __SILENT__."
        };
        format!(
            "{instructions}\n\nRecent session context, oldest to newest:\n{context}\n\n\
             Current event: {}\nCurrent event content:\n{}{realization_instructions}\n{closing}",
            event.kind.as_str(),
            event.text,
        )
    }

    fn uses_coverage_arbitration(&self, event: &MessengerEvent) -> bool {
        self.callbacks.coverage_provider.is_some()
            && event.command.is_some()
            && event.kind != Kind::UserTurn
    }

    /// `_coverage_for`: the played speech for the event's command, bounded.
    fn coverage_for(&self, event: &MessengerEvent) -> Vec<Dict> {
        let (Some(provider), Some((seq, id))) = (&self.callbacks.coverage_provider, &event.command)
        else {
            return Vec::new();
        };
        let mut coverage: Vec<Dict> = provider(*seq, id)
            .iter()
            .map(|item| {
                let facts: Vec<Value> = item
                    .get("covered_facts")
                    .and_then(Value::as_list)
                    .unwrap_or_default()
                    .iter()
                    .map(|fact| {
                        let text = if fact.truthy() {
                            fact.py_str()
                        } else {
                            String::new()
                        };
                        py_strip(&text).to_string()
                    })
                    .filter(|fact| !fact.is_empty())
                    .take(8)
                    .map(|fact| Value::Str(first_chars(&fact, 240)))
                    .collect();
                let mut entry = Dict::new();
                entry.insert(
                    "lifecycle_role",
                    item.truthy("lifecycle_role")
                        .map_or_else(|| "conversation".to_string(), Value::py_str),
                );
                entry.insert("covered_facts", facts);
                entry.insert("spoken_text", first_chars(&item.text("spoken_text"), 800));
                entry
            })
            .collect();
        let excess = coverage.len().saturating_sub(8);
        coverage.drain(..excess);
        coverage
    }

    /// `_realization_for`: how much of an arbitrated answer to speak, failing
    /// open to the authoritative text whenever the answer would lose content.
    fn realization_for(&self, event: &MessengerEvent, response: &str) -> Option<Realization> {
        if !self.uses_coverage_arbitration(event) {
            return None;
        }
        let Some((decision, spoken)) = parse_realization(response) else {
            return Some(fallback_realization(event, "malformed_arbitration"));
        };
        let coverage = self.coverage_for(event);
        let role = lifecycle_role_for(event);
        if decision == "suppress" && coverage.is_empty() {
            return Some(fallback_realization(event, "no_played_coverage"));
        }
        if decision == "suppress" && PROTECTED_LIFECYCLE_ROLES.contains(&role) {
            return Some(fallback_realization(event, "protected_lifecycle"));
        }
        let retained: &[Dict] = if decision == "full" { &[] } else { &coverage };
        let kept = if decision == "suppress" {
            ""
        } else {
            spoken.as_str()
        };
        if !preserves_authoritative_content(&event.text, retained, kept) {
            let reason = match decision {
                "full" => "lossy_full",
                "delta" => "lossy_delta",
                _ => "uncovered_content",
            };
            return Some(fallback_realization(event, reason));
        }
        let reason = match decision {
            "full" => "no_usable_coverage",
            "delta" => "novel_delta",
            _ => "covered_by_played_speech",
        };
        let covered_facts = if spoken.is_empty() {
            Vec::new()
        } else {
            vec![spoken.clone()]
        };
        Some(Realization {
            decision,
            spoken_text: spoken,
            lifecycle_role: role,
            covered_facts,
            reason,
        })
    }

    fn observe_realization(&self, event: &MessengerEvent, realization: &Realization) {
        let (Some(observer), Some((seq, id))) =
            (&self.callbacks.realization_observer, &event.command)
        else {
            return;
        };
        observer(
            *seq,
            id,
            realization.lifecycle_role,
            realization.decision,
            realization.reason,
        );
    }

    /// `_discard_pending_events_locked`: drops queued command-scoped events,
    /// keeping unscoped lifecycle events and accepted work outcomes. Called
    /// with `state` locked.
    fn discard_pending_events(&self) {
        self.retain_queued(|event| event.command.is_none() || event.work_lifecycle);
    }

    /// `_discard_pending_kinds_locked`. Called with `state` locked.
    fn discard_pending_kinds(&self, kinds: &[Kind]) {
        self.retain_queued(|event| !kinds.contains(&event.kind));
    }

    fn retain_queued(&self, keep: impl Fn(&MessengerEvent) -> bool) {
        let mut events = self.events.lock().unwrap();
        let mut preserved = Vec::new();
        let mut saw_shutdown = false;
        while let Some(queued) = events.pop_front() {
            match queued {
                None => {
                    saw_shutdown = true;
                    break;
                }
                Some(event) if keep(&event) => preserved.push(Some(event)),
                Some(_) => {}
            }
        }
        events.extend(preserved);
        if saw_shutdown {
            events.push_back(None);
        }
        if !events.is_empty() {
            self.queued.notify_one();
        }
    }

    /// `_speech_metadata_for`: the speech intent's keyword arguments.
    fn speech_metadata_for(
        &self,
        event: &MessengerEvent,
        fallback: bool,
        realization: Option<&Realization>,
        spoken_text: Option<&str>,
        user_response_role: &str,
    ) -> Dict {
        let action_kind = self.action_kind_for(event);
        let disposition = {
            let state = self.lock();
            event
                .command
                .as_ref()
                .and_then(|key| state.work_dispositions.get(key))
                .cloned()
                .or_else(|| event.work_disposition.clone())
        };
        let (source, kind) = if event.work_lifecycle {
            ("lifecycle", "final")
        } else if fallback {
            let handoff = event.kind == Kind::UserTurn && action_kind != "self_explanation";
            ("fallback", if handoff { "handoff" } else { "fallback" })
        } else if event.kind == Kind::UserTurn {
            let answer = user_response_role == "answer";
            ("messenger", if answer { "conversation" } else { "handoff" })
        } else if event.kind == Kind::OrchestratorFinal {
            let source = if event.speech_source.is_empty() {
                "orchestrator"
            } else {
                event.speech_source.as_str()
            };
            (source, "final")
        } else if event.detail == "clarification-request" {
            ("messenger", "clarification")
        } else {
            ("lifecycle", "progress")
        };
        let spoken_text = spoken_text.filter(|text| !text.is_empty());
        let lifecycle_role = match realization {
            Some(realization) => realization.lifecycle_role,
            None if event.kind == Kind::UserTurn => {
                if user_response_role == "answer" {
                    "conversation"
                } else {
                    "acknowledgement"
                }
            }
            None => lifecycle_role_for(event),
        };
        let covered_facts = match realization {
            Some(realization) => Value::List(
                realization
                    .covered_facts
                    .iter()
                    .map(|fact| Value::Str(fact.clone()))
                    .collect(),
            ),
            None => spoken_text.map_or(Value::Null, |text| Value::List(vec![text.into()])),
        };
        let replayable = matches!(event.kind, Kind::UserTurn | Kind::OrchestratorFinal)
            || event.work_lifecycle
            || (event.kind == Kind::OrchestratorTrace && event.command.is_some());
        let dedup_key = match &event.command {
            Some((seq, id)) if event.work_lifecycle => {
                Some(format!("work-outcome:{seq}:{id}:{}", event.detail))
            }
            _ => None,
        };
        let mut metadata = Dict::new();
        metadata.insert("source", source);
        metadata.insert("kind", kind);
        metadata.insert(
            "authoritative",
            event.kind == Kind::OrchestratorFinal || event.work_lifecycle,
        );
        metadata.insert(
            "semantic_brief",
            match realization {
                Some(realization) => realization.spoken_text.clone(),
                None => spoken_text.unwrap_or(&event.text).to_string(),
            },
        );
        metadata.insert("lifecycle_role", lifecycle_role);
        metadata.insert("covered_facts", covered_facts);
        metadata.insert(
            "realization_decision",
            realization.map_or("full", |realization| realization.decision),
        );
        metadata.insert(
            "suppression_reason",
            realization.map_or("", |realization| realization.reason),
        );
        metadata.insert("replayable", replayable);
        metadata.insert("work_disposition", disposition);
        metadata.insert(
            "freshness_scope",
            if event.work_lifecycle {
                "work"
            } else {
                "conversation"
            },
        );
        metadata.insert("dedup_key", dedup_key);
        metadata
    }

    /// `_speak_safely`.
    fn speak(
        &self,
        text: &str,
        event: &MessengerEvent,
        display_text: Option<&str>,
        metadata: Dict,
    ) {
        let (seq, id) = match &event.command {
            Some((seq, id)) => (Some(*seq), Some(id.as_str())),
            None => (None, None),
        };
        (self.callbacks.speak)(text, seq, id, display_text, &metadata);
    }
}

const USER_TURN_INSTRUCTIONS: &str = concat!(
    "This is a new user turn delivered simultaneously to you and the authoritative ",
    "orchestrator. If it is lightweight social conversation that needs no ",
    "orchestration, reply naturally. If it is a work request or substantive ",
    "question that should be handed off, give a brief contextual acknowledgement ",
    "that names the specific thing you are now looking into using the user's own ",
    "subject and first-person singular language such as I or me, in one ",
    "semantically specific sentence of at most twelve spoken words when the ",
    "meaning permits. Never substitute generic filler such as 'the next step', ",
    "'a plan', or 'the request' for that subject; if the subject is unclear, ",
    "briefly echo the words you heard instead. ",
    "Do not claim unperformed work. ",
    "Do not call yourself the orchestrator in the spoken response. ",
    "If authoritative context names workers, refer to the workers directly. Do not ",
    "invent scope or ",
    "claim that a ticket, worker, or implementation already exists. Prefix the ",
    "response with __ANSWER__ only when it fully answers the user now; otherwise ",
    "prefix it with __HANDOFF__."
);
const TRACE_INSTRUCTIONS: &str = concat!(
    "This is a provider-visible public progress summary or worker lifecycle event. ",
    "Use it with the session context to decide whether a brief spoken update is useful. ",
    "Preserve the event's state semantics: awaiting review is not done, failure needs ",
    "attention, and merged is complete."
);
const FINAL_INSTRUCTIONS: &str = concat!(
    "This is the authoritative orchestrator reply. Convey its outcome naturally and ",
    "concisely without adding unsupported claims."
);

/// `"PUBLIC WORK DISPOSITION: {route} — {public_reason}"`, with Python's
/// `str()` of each value.
fn disposition_context(disposition: &Dict) -> String {
    let field = |key: &str| disposition.get(key).unwrap_or(&Value::Null).py_str();
    format!(
        "PUBLIC WORK DISPOSITION: {} — {}",
        field("route"),
        field("public_reason")
    )
}

/// `value is True`.
fn is_true(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(true)))
}

fn py_bool(flag: bool) -> &'static str {
    if flag { "True" } else { "False" }
}

/// `text[:limit]`, in characters.
fn first_chars(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// `_bounded_context_entry`: keeps a long entry's head and tail.
fn bounded_context_entry(entry: &str) -> String {
    let length = entry.chars().count();
    if length <= PROMPT_CONTEXT_ENTRY_CHAR_LIMIT {
        return entry.to_string();
    }
    let half = (PROMPT_CONTEXT_ENTRY_CHAR_LIMIT - 5) / 2;
    let tail: String = entry.chars().skip(length - half).collect();
    format!("{} ... {tail}", first_chars(entry, half))
}

/// `_user_response_role`: the speakable text and whether it answers now
/// (`answer`) or promises a later result (`handoff`).
fn user_response_role(text: &str, action_kind: &str) -> (String, &'static str) {
    let mut cleaned = text
        .split(py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let mut explicit_role = String::new();
    if let Ok(Some(marker)) = USER_RESPONSE_ROLE.captures(&cleaned) {
        explicit_role = marker
            .get(1)
            .map_or("", |role| role.as_str())
            .to_lowercase();
        let end = marker.get(0).map_or(0, |found| found.end());
        cleaned = py_strip(&cleaned[end..]).to_string();
    }
    if action_kind == "self_explanation" {
        return (cleaned, "answer");
    }
    if explicit_role == "handoff" || pattern::search(&HANDOFF_RESPONSE, &cleaned) {
        return (cleaned, "handoff");
    }
    if explicit_role == "answer" || action_kind == "conversation" {
        return (cleaned, "answer");
    }
    (cleaned, "handoff")
}

/// The `decision` and `spoken_text` of a realization object, or `None` where
/// `_realization_for` raises.
fn parse_realization(response: &str) -> Option<(&'static str, String)> {
    let Some(Value::Dict(payload)) = json::parse(response) else {
        return None;
    };
    let decision = match payload.text("decision").to_lowercase().as_str() {
        "full" => "full",
        "delta" => "delta",
        "suppress" => "suppress",
        _ => return None,
    };
    let spoken = payload.text("spoken_text");
    if decision != "suppress" && spoken.is_empty() {
        return None;
    }
    Some((decision, spoken))
}

/// `_lifecycle_role_for`.
fn lifecycle_role_for(event: &MessengerEvent) -> &'static str {
    if event.work_lifecycle {
        return "result";
    }
    let conversational = matches!(
        event.action_kind.as_str(),
        "conversation" | "self_explanation"
    );
    match event.kind {
        Kind::UserTurn if conversational => "conversation",
        Kind::UserTurn => "acknowledgement",
        Kind::OrchestratorFinal if conversational => "conversation",
        Kind::OrchestratorFinal => "result",
        Kind::OrchestratorTrace => LIFECYCLE_ROLES_BY_DETAIL
            .iter()
            .find(|(detail, _)| *detail == event.detail)
            .map_or("progress", |(_, role)| role),
    }
}

/// `_event_is_unscoped_lifecycle`.
fn event_is_unscoped_lifecycle(event: &MessengerEvent) -> bool {
    event.kind == Kind::OrchestratorTrace
        && LIFECYCLE_DETAIL_TRACE_KINDS.contains(&event.detail.as_str())
        && event.command.is_none()
}

/// `_fallback_realization`: the whole authoritative text, the demo
/// explanation, or the degraded acknowledgement.
fn fallback_realization(event: &MessengerEvent, reason: &'static str) -> Realization {
    let text = if event.action_kind == "self_explanation" {
        RELAY_RUNNER_DEMO_EXPLANATION.to_string()
    } else if event.kind == Kind::UserTurn {
        MESSENGER_DEGRADED_TEXT.to_string()
    } else {
        event.text.clone()
    };
    Realization {
        decision: "full",
        spoken_text: text.clone(),
        lifecycle_role: lifecycle_role_for(event),
        covered_facts: vec![text],
        reason,
    }
}

/// `_preserves_authoritative_content`: every semantic token of the
/// authoritative text, and every pair and triple of neighbouring tokens
/// (which keep who owns an outcome or a negation), survive in what is spoken
/// or already played.
fn preserves_authoritative_content(authoritative: &str, coverage: &[Dict], spoken: &str) -> bool {
    let covered: Vec<String> = coverage
        .iter()
        .map(|item| item.string("spoken_text"))
        .collect();
    let mut anchors = HashSet::new();
    let mut relations = HashSet::new();
    for text in std::iter::once(spoken).chain(covered.iter().map(String::as_str)) {
        let tokens = semantic_tokens(text);
        relations.extend(semantic_relations(&tokens));
        anchors.extend(tokens);
    }
    let required = semantic_tokens(authoritative);
    required.iter().all(|token| anchors.contains(token))
        && semantic_relations(&required)
            .iter()
            .all(|relation| relations.contains(relation))
}

/// `_semantic_relations`.
fn semantic_relations(tokens: &[String]) -> Vec<Vec<String>> {
    [2, 3]
        .iter()
        .flat_map(|width| tokens.windows(*width).map(<[String]>::to_vec))
        .collect()
}

/// `_semantic_tokens`.
fn semantic_tokens(text: &str) -> Vec<String> {
    let normalized = text.to_lowercase().replace(['’', '\''], "");
    pattern::find_all(&SEMANTIC_TOKEN, &normalized)
        .into_iter()
        .filter(|token| !SEMANTIC_STOPWORDS.contains(token) && !matches!(*token, "will" | "going"))
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;

    use super::*;

    /// One scripted answer: what `ask` returns, given its `on_partial`.
    type Step = Box<dyn FnOnce(Option<Partial>) -> Result<String, String> + Send>;

    /// `FakeBackend`: answers each ask with the next scripted step.
    #[derive(Default)]
    struct Fake {
        steps: Mutex<VecDeque<Step>>,
        prompts: Mutex<Vec<String>>,
        rebinds: Mutex<Vec<String>>,
        interrupts: AtomicUsize,
        /// Set by every interrupt, for steps that wait to be interrupted.
        interrupted: Arc<Event>,
    }

    impl Fake {
        fn new(steps: Vec<Step>) -> Arc<Self> {
            let fake = Fake::default();
            fake.steps.lock().unwrap().extend(steps);
            Arc::new(fake)
        }

        fn replies(replies: &[&str]) -> Arc<Self> {
            Self::new(replies.iter().map(|text| reply(text)).collect())
        }

        fn prompts(&self) -> Vec<String> {
            self.prompts.lock().unwrap().clone()
        }
    }

    impl Backend for Fake {
        fn start(&self) -> Result<(), String> {
            Ok(())
        }
        fn ask(
            &self,
            prompt: &str,
            _: Duration,
            on_partial: Option<Partial>,
        ) -> Result<String, String> {
            self.prompts.lock().unwrap().push(prompt.to_string());
            let step = self.steps.lock().unwrap().pop_front();
            step.map_or_else(
                || Err("no scripted response".to_string()),
                |step| step(on_partial),
            )
        }
        fn interrupt(&self) {
            self.interrupts.fetch_add(1, Ordering::SeqCst);
            self.interrupted.set();
        }
        fn rebind(&self, partition: &str) -> Result<(), String> {
            self.rebinds.lock().unwrap().push(partition.to_string());
            Ok(())
        }
        fn shutdown(&self) {}
    }

    fn reply(text: &str) -> Step {
        let text = text.to_string();
        Box::new(move |_| Ok(text))
    }

    fn fail(message: &str) -> Step {
        let message = message.to_string();
        Box::new(move |_| Err(message))
    }

    /// `BlockingBackend`'s first answer: waits for `release`.
    fn blocked(text: &str, started: &Arc<Event>, release: &Arc<Event>) -> Step {
        let (text, started, release) = (text.to_string(), Arc::clone(started), Arc::clone(release));
        Box::new(move |_| {
            started.set();
            if release.wait(5.0) {
                Ok(text)
            } else {
                Err("not released".to_string())
            }
        })
    }

    #[derive(Clone, Debug)]
    struct Spoken {
        text: String,
        seq: Option<i64>,
        id: Option<String>,
        display: Option<String>,
        metadata: Dict,
    }

    /// A timing record: stage, command seq and id, provider, outcome.
    type Stage = (String, i64, String, Option<String>, String);

    #[derive(Clone, Default)]
    struct Recorded {
        spoken: Arc<Mutex<Vec<Spoken>>>,
        timing: Arc<Mutex<Vec<Stage>>>,
        realizations: Arc<Mutex<Vec<(String, String, String)>>>,
    }

    impl Recorded {
        fn spoken(&self) -> Vec<Spoken> {
            self.spoken.lock().unwrap().clone()
        }
        fn texts(&self) -> Vec<String> {
            self.spoken()
                .into_iter()
                .map(|spoken| spoken.text)
                .collect()
        }
        fn stages(&self) -> Vec<String> {
            self.timing
                .lock()
                .unwrap()
                .iter()
                .map(|entry| entry.0.clone())
                .collect()
        }
    }

    struct Options {
        provider: Option<&'static str>,
        current: bool,
        coverage: Option<&'static str>,
        context_limit: usize,
    }

    impl Default for Options {
        fn default() -> Self {
            Options {
                provider: None,
                current: true,
                coverage: None,
                context_limit: CONTEXT_LIMIT,
            }
        }
    }

    fn runtime(backend: &Arc<Fake>, options: Options) -> (MessengerRuntime, Recorded) {
        let recorded = Recorded::default();
        let (spoken, timing, realizations) = (
            Arc::clone(&recorded.spoken),
            Arc::clone(&recorded.timing),
            Arc::clone(&recorded.realizations),
        );
        let coverage = options.coverage.map(|text| {
            let items: Vec<Dict> = match json::parse(text) {
                Some(Value::List(items)) => items
                    .into_iter()
                    .filter_map(|item| item.as_dict().cloned())
                    .collect(),
                _ => panic!("coverage is not a list"),
            };
            Box::new(move |_: i64, _: &str| items.clone()) as CoverageProvider
        });
        let current = options.current;
        let callbacks = Callbacks {
            speak: Box::new(move |text, seq, id, display, metadata| {
                spoken.lock().unwrap().push(Spoken {
                    text: text.to_string(),
                    seq,
                    id: id.map(str::to_string),
                    display: display.map(str::to_string),
                    metadata: metadata.clone(),
                });
                true
            }),
            is_current: Box::new(move |_, _| current),
            coverage_provider: coverage,
            realization_observer: Some(Box::new(move |_, _, role, decision, reason| {
                realizations
                    .lock()
                    .unwrap()
                    .push((role.into(), decision.into(), reason.into()));
            })),
            timing_observer: Some(Box::new(move |stage, seq, id, at, provider, outcome| {
                assert!(at.is_some());
                timing.lock().unwrap().push((
                    stage.into(),
                    seq,
                    id.into(),
                    provider.map(str::to_string),
                    outcome.into(),
                ));
            })),
            continuity_observer: None,
        };
        let backend: Arc<dyn Backend> = Arc::clone(backend) as Arc<dyn Backend>;
        let provider = options.provider.map(str::to_string);
        let runtime = MessengerRuntime::new(
            backend,
            provider,
            callbacks,
            options.context_limit,
            "0".into(),
        );
        (runtime, recorded)
    }

    fn dict(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            other => panic!("not an object: {other:?}"),
        }
    }

    fn command(seq: i64, id: &str) -> Dict {
        let mut command = Dict::new();
        command.insert("relay_command_seq", seq);
        command.insert("relay_command_id", id);
        command
    }

    fn with(mut base: Dict, extra: &str) -> Dict {
        base.update(&dict(extra));
        base
    }

    fn wait_until(predicate: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if predicate() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        predicate()
    }

    fn next_prompt(runtime: &MessengerRuntime) -> String {
        let event = runtime
            .inner
            .events
            .lock()
            .unwrap()
            .pop_front()
            .flatten()
            .unwrap();
        runtime.inner.prompt_for(&event)
    }

    fn context(runtime: &MessengerRuntime) -> String {
        Vec::from(runtime.inner.lock().context.clone()).join("\n")
    }

    const PLAYED_ACKNOWLEDGEMENT: &str = r#"[{"lifecycle_role": "acknowledgement",
        "covered_facts": ["request accepted"], "spoken_text": "I picked it up."}]"#;

    #[test]
    fn the_user_prompt_bounds_repeated_session_context() {
        let (runtime, _) = runtime(&Fake::replies(&[]), Options::default());
        for index in 0..16 {
            let entry = format!("ORCHESTRATOR UPDATE: old-{index}-{}", "x".repeat(2_000));
            runtime.inner.lock().push_context(entry);
        }
        assert!(runtime.submit_user("Explain the latency fix", &command(1, "bounded")));
        let prompt = next_prompt(&runtime);
        assert!(prompt.contains("Explain the latency fix"));
        assert!(prompt.contains("Current event content:"));
        assert!(prompt.len() < 6_000);
    }

    #[test]
    fn focus_partitions_context_per_session_and_restores_on_refocus() {
        let (runtime, _) = runtime(&Fake::replies(&[]), Options::default());
        runtime.focus("session-a");
        runtime.submit_user("alpha secret project", &command(1, "a"));
        next_prompt(&runtime);

        assert!(runtime.focus("session-b"));
        assert!(!runtime.focus("session-b"));
        runtime.submit_user("beta question", &command(2, "b"));
        let prompt_b = next_prompt(&runtime);
        assert!(prompt_b.contains("beta question"));
        assert!(!prompt_b.contains("alpha secret project"));

        runtime.focus("session-a");
        runtime.submit_user("alpha follow-up", &command(3, "a2"));
        let prompt_a = next_prompt(&runtime);
        assert!(prompt_a.contains("alpha secret project"));
        assert!(!prompt_a.contains("beta question"));
    }

    #[test]
    fn a_focus_switch_makes_old_events_stale_and_rebinds_the_backend() {
        let backend = Fake::replies(&[""]);
        let (runtime, _) = runtime(&backend, Options::default());
        runtime.focus("session-a");
        runtime.submit_user("hello", &command(1, "a"));
        let stale = runtime
            .inner
            .events
            .lock()
            .unwrap()
            .pop_front()
            .flatten()
            .unwrap();
        runtime.focus("session-b");
        assert!(!runtime.inner.event_is_current(&stale));

        runtime.start();
        runtime.submit_user("hi", &command(2, "b"));
        assert!(wait_until(
            || *backend.rebinds.lock().unwrap() == ["session-b"]
        ));
        runtime.shutdown();
    }

    #[test]
    fn a_streamed_first_sentence_is_spoken_before_the_turn_completes() {
        let release = Arc::new(Event::default());
        let step_release = Arc::clone(&release);
        let answer = "I picked up the latency regression and I'll return with the result.";
        let backend = Fake::new(vec![Box::new(move |on_partial: Option<Partial>| {
            on_partial.expect("user turns stream")(answer.to_string());
            step_release.wait(5.0);
            Ok(answer.to_string())
        })]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                provider: Some("codex"),
                ..Options::default()
            },
        );
        runtime.start();
        runtime.submit_user(
            "Investigate the latency regression",
            &command(1, "streaming"),
        );

        assert!(wait_until(|| recorded.spoken().len() == 1));
        assert!(!release.is_set());
        assert_eq!(
            recorded.stages()[..3],
            [
                "messenger_submitted",
                "messenger_provider_started",
                "messenger_first_semantic_output"
            ]
        );
        assert_eq!(
            recorded.timing.lock().unwrap()[0].3.as_deref(),
            Some("codex")
        );
        release.set();
        thread::sleep(Duration::from_millis(50));
        assert_eq!(recorded.texts(), [answer]);
        runtime.shutdown();
    }

    #[test]
    fn a_provider_failure_speaks_the_degraded_text_and_keeps_the_final() {
        let backend = Fake::new(vec![fail("provider unavailable")]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let command = command(2, "degraded");
        runtime.submit_user("Fix the provider path", &command);
        assert!(wait_until(|| recorded.texts() == [MESSENGER_DEGRADED_TEXT]));
        let spoken = &recorded.spoken()[0];
        assert_eq!(spoken.metadata.string("source"), "fallback");
        assert_eq!(spoken.metadata.string("kind"), "handoff");
        assert_eq!(spoken.display.as_deref(), Some("Fix the provider path"));
        let failed = recorded.timing.lock().unwrap().last().cloned().unwrap();
        assert_eq!(
            (failed.0.as_str(), failed.4.as_str()),
            ("messenger_failed", "provider_unavailable")
        );

        assert!(runtime.submit_final(with(
            command,
            r#"{"text": "The foreground result is ready."}"#
        )));
        assert_eq!(
            recorded.texts(),
            [MESSENGER_DEGRADED_TEXT, "The foreground result is ready."]
        );
        runtime.shutdown();
    }

    #[test]
    fn a_silent_user_turn_fails_open_for_both_providers() {
        for provider in ["codex", "claude"] {
            let backend = Fake::replies(&["__SILENT__"]);
            let (runtime, recorded) = runtime(
                &backend,
                Options {
                    provider: Some(provider),
                    ..Options::default()
                },
            );
            runtime.start();
            runtime.submit_user("Investigate the missing response", &command(20, provider));
            assert!(
                wait_until(|| recorded.texts() == [MESSENGER_DEGRADED_TEXT]),
                "{provider}"
            );
            runtime.shutdown();
        }
    }

    #[test]
    fn qualification_context_is_provisional_and_scoped_to_the_command() {
        let (runtime, _) = runtime(&Fake::replies(&[]), Options::default());
        let open_chrome = command(3, "codex");
        assert!(runtime.submit_user("Open Chrome", &open_chrome));
        assert!(runtime.update_user_context(&with(
            open_chrome,
            r#"{"source_text": "Open Chrome",
                "work_disposition": {"route": "continue_current", "public_reason": "Foreground action."},
                "intent_qualifications": [
                    {"command_seq": 2, "command_id": "old", "bucket": "task"},
                    {"command_seq": 3, "command_id": "codex", "bucket": "action", "unresolved": false, "mixed": false}
                ]}"#,
        )));
        let context = context(&runtime);
        assert!(context.contains("PUBLIC WORK DISPOSITION: continue_current — Foreground action."));
        assert!(context.contains(
            "PUBLIC INTENT QUALIFICATION: action; unresolved=False; mixed=False. Provisional only; \
             the PM resolves scope and authority. Remain tool-free."
        ));
        assert!(!context.contains("PUBLIC INTENT QUALIFICATION: task"));
        assert!(!runtime.update_user_context(&with(
            command(9, "other"),
            r#"{"work_disposition": {"route": "continue_current"}}"#
        )));
    }

    #[test]
    fn a_conversational_answer_silences_only_a_final_that_adds_nothing() {
        let backend = Fake::replies(&[
            "__ANSWER__ You're welcome.",
            "__ANSWER__ Got it, the board stays as it is.",
        ]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let conversation = r#"{"work_disposition": {"route": "continue_current", "public_reason": "Conversation."}}"#;

        let thanks = command(3, "conversation");
        runtime.submit_user("Thanks", &thanks);
        assert!(wait_until(|| recorded.texts() == ["You're welcome."]));
        assert_eq!(recorded.spoken()[0].metadata.string("kind"), "conversation");
        assert!(runtime.update_user_context(&with(thanks.clone(), conversation)));
        assert!(runtime.submit_final(with(thanks, r#"{"text": "You're welcome!"}"#)));
        assert_eq!(recorded.texts(), ["You're welcome."]);

        let scoping = command(4, "scoping");
        let final_text = "Got it. The board stays. The Start button moves to the Projects header, \
                          and the wheel's project picker goes away.";
        runtime.submit_user(
            "The board stays; only the projects panel changes.",
            &scoping,
        );
        assert!(wait_until(|| recorded.spoken().len() == 2));
        assert!(runtime.update_user_context(&with(scoping.clone(), conversation)));
        let mut payload = scoping;
        payload.insert("text", final_text);
        assert!(runtime.submit_final(payload));
        assert_eq!(recorded.texts()[2], final_text);
        runtime.shutdown();
    }

    #[test]
    fn a_promise_stays_a_handoff_and_never_owns_the_later_result() {
        let handoff = "I received your request and will check the most recent Git commit’s \
                       subject, then return with the result.";
        for provider in ["codex", "claude"] {
            let backend = Fake::replies(&[&format!("__ANSWER__ {handoff}")]);
            let (runtime, recorded) = runtime(
                &backend,
                Options {
                    provider: Some(provider),
                    ..Options::default()
                },
            );
            let command = command(67, &format!("commit-subject-{provider}"));
            runtime.start();
            runtime.submit_user(
                "Use the terminal to tell me the subject of the most recent git commit.",
                &command,
            );
            assert!(wait_until(|| recorded.spoken().len() == 1));
            let first = &recorded.spoken()[0];
            assert_eq!(first.text, handoff);
            assert_eq!(first.metadata.string("kind"), "handoff");
            assert_eq!(first.metadata.string("lifecycle_role"), "acknowledgement");
            assert!(runtime.update_user_context(&with(
                command.clone(),
                r#"{"source_text": "Use the terminal.", "work_disposition": {"route": "continue_current"}}"#,
            )));
            let final_text = "merge RR-347 worker run 105";
            let mut payload = command;
            payload.insert("text", final_text);
            assert!(runtime.submit_final(payload));
            let last = recorded.spoken().last().cloned().unwrap();
            assert_eq!(recorded.texts(), [handoff, final_text]);
            assert_eq!(last.display.as_deref(), Some(final_text));
            assert_eq!(last.metadata.string("kind"), "final");
            assert!(last.metadata.get("authoritative").unwrap().truthy());
            runtime.shutdown();
        }
    }

    #[test]
    fn the_demo_self_explanation_is_answered_directly_without_a_duplicate() {
        let answer = "Relay Runner is a local Mac workspace for turning conversation into \
                      visible software work, with tickets, isolated agents, and tracked review.";
        let backend = Fake::replies(&[answer]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        // The semantic shortcut wins even over stale project-work metadata.
        let command = with(
            command(3, "demo-3"),
            r#"{"work_disposition": {"route": "queue_project_work"}}"#,
        );
        runtime.submit_user(
            "I'm demoing Relay Runner; explain what it does to the audience.",
            &command,
        );
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let prompt = &backend.prompts()[0];
        assert!(prompt.contains("demo-audience self-introduction"));
        assert!(prompt.contains(RELAY_RUNNER_DEMO_EXPLANATION));
        assert!(!prompt.contains("brief contextual acknowledgement"));
        let spoken = &recorded.spoken()[0];
        assert_eq!(spoken.text, answer);
        assert_eq!(spoken.metadata.string("kind"), "conversation");
        assert_eq!(spoken.metadata.string("lifecycle_role"), "conversation");

        assert!(runtime.submit_final(with(
            command,
            r#"{"text": "Relay Runner coordinates software work for you."}"#
        )));
        assert_eq!(recorded.spoken().len(), 1);
        assert_eq!(backend.prompts().len(), 1);
        runtime.shutdown();
    }

    #[test]
    fn the_demo_self_explanation_fails_open_to_the_canonical_answer() {
        let backend = Fake::new(vec![fail("messenger unavailable")]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        runtime.submit_user("What is Relay Runner?", &command(4, "demo-4"));
        assert!(wait_until(
            || recorded.texts() == [RELAY_RUNNER_DEMO_EXPLANATION]
        ));
        assert_eq!(recorded.spoken()[0].metadata.string("kind"), "fallback");
        runtime.shutdown();
    }

    #[test]
    fn a_task_turn_asks_for_a_contextual_handoff() {
        let backend = Fake::replies(&["I'm looking into implementing the new architecture."]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        runtime.submit_user("Implement the new architecture", &command(4, "cmd-4"));
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let prompt = &backend.prompts()[0];
        for fragment in [
            "Implement the new architecture",
            "brief contextual acknowledgement",
            "first-person singular language",
            "Never substitute generic filler",
            "refer to the workers directly",
        ] {
            assert!(prompt.contains(fragment), "{fragment}");
        }
        let spoken = &recorded.spoken()[0];
        assert_eq!(
            spoken.text,
            "I'm looking into implementing the new architecture."
        );
        assert_eq!((spoken.seq, spoken.id.as_deref()), (Some(4), Some("cmd-4")));
        assert_eq!(spoken.display, None);
        assert!(spoken.metadata.get("replayable").unwrap().truthy());
        runtime.shutdown();
    }

    #[test]
    fn trace_and_final_share_bounded_context_and_only_the_current_reply_speaks() {
        let backend = Fake::replies(&[
            "I picked up the messenger work, and I’ll return with the next step.",
            "I’m checking the bridge wiring now.",
            "The messenger architecture is implemented and verified.",
        ]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                context_limit: 6,
                ..Options::default()
            },
        );
        runtime.start();
        let command = command(7, "cmd-7");
        runtime.submit_user("Build the fast messenger", &command);
        assert!(wait_until(|| backend.prompts().len() == 1));
        let mut trace =
            dict(r#"{"kind": "reasoning-summary", "message": "Checking the voice bridge wiring"}"#);
        trace.insert("command", command.clone());
        runtime.submit_trace(trace);
        assert!(wait_until(|| recorded.spoken().len() == 2));
        runtime.submit_final(with(command, r#"{"text": "Implemented and verified."}"#));
        assert!(wait_until(|| recorded.spoken().len() == 3));

        assert_eq!(
            recorded.texts(),
            [
                "I picked up the messenger work, and I’ll return with the next step.",
                "I’m checking the bridge wiring now.",
                "Implemented and verified.",
            ]
        );
        let progress = &recorded.spoken()[1];
        assert_eq!(progress.metadata.string("kind"), "progress");
        assert!(progress.metadata.get("replayable").unwrap().truthy());
        assert_eq!(
            progress.display.as_deref(),
            Some("Checking the voice bridge wiring")
        );
        assert!(backend.prompts()[1].contains("Checking the voice bridge wiring"));
        assert_eq!(backend.prompts().len(), 2);
        assert_eq!(backend.interrupts.load(Ordering::SeqCst), 0);
        assert!(runtime.context_size() <= 6);
        runtime.shutdown();
    }

    #[test]
    fn unscoped_worker_lifecycle_speaks_without_a_command() {
        let backend = Fake::replies(&[
            "RR-7 is awaiting review; it is not merged yet.",
            "__SILENT__",
        ]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                current: false,
                ..Options::default()
            },
        );
        runtime.start();
        assert!(runtime.submit_trace(dict(
            r#"{"kind": "run-review-needed", "message": "RR-7 run 12 awaiting review", "ticket_id": "RR-7"}"#
        )));
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let spoken = &recorded.spoken()[0];
        assert_eq!(
            spoken.text,
            "RR-7 is awaiting review; it is not merged yet."
        );
        assert_eq!((spoken.seq, spoken.id.as_deref()), (None, None));
        assert!(!spoken.metadata.get("replayable").unwrap().truthy());
        assert!(backend.prompts()[0].contains("WORKER LIFECYCLE (run-review-needed)"));
        assert!(backend.prompts()[0].contains("awaiting review is not done"));

        // A silent answer falls back to the event's text.
        assert!(runtime.submit_trace(dict(
            r#"{"kind": "run-merged", "message": "RR-7 run 12 merged"}"#
        )));
        assert!(wait_until(|| recorded.spoken().len() == 2));
        assert_eq!(recorded.texts()[1], "RR-7 run 12 merged");
        runtime.shutdown();
    }

    #[test]
    fn unscoped_lifecycle_speaks_its_full_detail() {
        let detail = "RR-279 verification resumed: Mounted test on the currently running installed \
                      Relay Runner v0.4.35 after Screen Recording and Accessibility were granted.";
        let backend = Fake::replies(&["RR-279 verification has resumed."]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                current: false,
                ..Options::default()
            },
        );
        runtime.start();
        let mut trace = dict(
            r#"{"kind": "run-verification-resumed", "message": "RR-279 verification resumed..."}"#,
        );
        trace.insert("lifecycle_detail", detail);
        assert!(runtime.submit_trace(trace));
        assert!(wait_until(|| recorded.spoken().len() == 1));
        assert!(backend.prompts()[0].contains(detail));
        assert_eq!(recorded.spoken()[0].display.as_deref(), Some(detail));
        runtime.shutdown();
    }

    #[test]
    fn unscoped_lifecycle_survives_a_new_user_turn() {
        let backend = Fake::replies(&[
            "RR-8 failed and needs attention.",
            "I picked up the next request.",
        ]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        assert!(runtime.submit_trace(dict(
            r#"{"kind": "run-failed", "message": "RR-8 run 13 failed"}"#
        )));
        assert!(runtime.submit_user("What happened next?", &command(9, "cmd-9")));
        runtime.start();
        assert!(wait_until(|| recorded.texts()
            == [
                "RR-8 failed and needs attention.",
                "I picked up the next request."
            ]));
        runtime.shutdown();
    }

    #[test]
    fn a_final_speaks_once_and_a_fallback_never_claims_its_slot() {
        let backend = Fake::replies(&["__SILENT__", "__SILENT__"]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let first = command(15, "cmd-15");
        runtime.submit_user("Finish the task", &first);
        assert!(wait_until(|| recorded.spoken().len() == 1));
        assert!(runtime.submit_final(with(first.clone(), r#"{"text": "Finished."}"#)));
        assert!(runtime.submit_final(with(first, r#"{"text": "Finished again."}"#)));
        assert_eq!(recorded.texts(), [MESSENGER_DEGRADED_TEXT, "Finished."]);

        // RR-460: the speech coordinator replaces the fallback with the final.
        let second = command(16, "cmd-16");
        runtime.submit_user("Finish the task", &second);
        assert!(wait_until(|| recorded.spoken().len() == 3));
        let fallback = with(
            second.clone(),
            r#"{"text": "No reply yet.", "speech_source": "fallback"}"#,
        );
        assert!(runtime.submit_final(fallback.clone()));
        assert!(runtime.submit_final(fallback.clone()));
        assert!(runtime.submit_final(with(
            second,
            r#"{"text": "Finished.", "speech_source": "completion"}"#
        )));
        assert!(runtime.submit_final(fallback));
        assert_eq!(recorded.texts()[3..], ["No reply yet.", "Finished."]);
        assert_eq!(recorded.spoken()[3].metadata.string("source"), "fallback");
        assert_eq!(recorded.spoken()[4].metadata.string("source"), "completion");
        runtime.shutdown();
    }

    #[test]
    fn a_final_replaces_a_queued_handoff() {
        let backend = Fake::replies(&["The work is complete."]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        let command = command(17, "cmd-17");
        assert!(runtime.submit_user("Finish the task", &command));
        assert!(runtime.submit_final(with(command, r#"{"text": "Finished."}"#)));
        runtime.start();
        assert!(wait_until(|| recorded.texts() == ["Finished."]));
        thread::sleep(Duration::from_millis(30));
        assert!(backend.prompts().is_empty());
        runtime.shutdown();
    }

    #[test]
    fn a_final_interrupts_an_inflight_handoff_and_speaks_alone() {
        let (started, release) = (Arc::new(Event::default()), Arc::new(Event::default()));
        let backend = Fake::new(vec![blocked("I picked up the task.", &started, &release)]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let command = command(18, "cmd-18");
        assert!(runtime.submit_user("Finish the task", &command));
        assert!(started.wait(1.0));
        assert!(runtime.submit_final(with(command, r#"{"text": "Finished."}"#)));
        assert_eq!(backend.interrupts.load(Ordering::SeqCst), 1);
        release.set();
        thread::sleep(Duration::from_millis(50));
        assert_eq!(recorded.texts(), ["Finished."]);
        assert_eq!(backend.prompts().len(), 1);
        runtime.shutdown();
    }

    #[test]
    fn a_sidecar_final_keeps_its_lifecycle_authority() {
        let backend = Fake::replies(&["__SILENT__"]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let disposition =
            r#"{"route": "run_sidecar", "public_reason": "Independent bounded public research."}"#;
        let command = with(
            command(19, "cmd-19"),
            &format!(r#"{{"work_disposition": {disposition}}}"#),
        );
        runtime.submit_user("Compare the public APIs", &command);
        assert!(wait_until(|| recorded.spoken().len() == 1));
        runtime.submit_final(with(
            command,
            r#"{"text": "The verified comparison is ready.", "speech_source": "lifecycle"}"#,
        ));
        let metadata = recorded.spoken()[1].metadata.clone();
        assert_eq!(metadata.string("source"), "lifecycle");
        assert_eq!(metadata.string("kind"), "final");
        assert!(metadata.get("authoritative").unwrap().truthy());
        assert_eq!(
            json::dumps(metadata.get("work_disposition").unwrap()),
            json::dumps(&dict(disposition).into())
        );
        runtime.shutdown();
    }

    #[test]
    fn a_new_turn_interrupts_the_inflight_answer_and_drops_its_late_partial() {
        let first_partial: Arc<Mutex<Option<Partial>>> = Arc::default();
        let keep = Arc::clone(&first_partial);
        let backend = Fake::default();
        let interrupted = Arc::clone(&backend.interrupted);
        backend.steps.lock().unwrap().extend([
            Box::new(move |on_partial: Option<Partial>| {
                *keep.lock().unwrap() = on_partial;
                interrupted.wait(5.0);
                Ok("Old response belongs to the prior turn.".to_string())
            }) as Step,
            Box::new(move |on_partial: Option<Partial>| {
                let late = first_partial
                    .lock()
                    .unwrap()
                    .take()
                    .expect("the first turn streamed");
                late("Late output belongs to the prior turn.".to_string());
                on_partial.unwrap()(
                    "The second request has the current semantic response.".to_string(),
                );
                Ok("The second request has the current semantic response.".to_string())
            }) as Step,
        ]);
        let backend = Arc::new(backend);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        runtime.submit_user("First request", &command(1, "first"));
        assert!(wait_until(|| backend.prompts().len() == 1));
        runtime.submit_user("Second request", &command(2, "second"));

        assert!(wait_until(|| recorded.spoken().len() == 1));
        thread::sleep(Duration::from_millis(30));
        let spoken = recorded.spoken();
        assert_eq!(spoken.len(), 1);
        assert_eq!(
            spoken[0].text,
            "The second request has the current semantic response."
        );
        assert_eq!(
            (spoken[0].seq, spoken[0].id.as_deref()),
            (Some(2), Some("second"))
        );
        let first_outputs: Vec<_> = recorded
            .timing
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| entry.0 == "messenger_first_semantic_output")
            .map(|entry| (entry.1, entry.2.clone()))
            .collect();
        assert_eq!(first_outputs, [(2, "second".to_string())]);
        assert!(backend.interrupts.load(Ordering::SeqCst) >= 1);
        runtime.shutdown();
    }

    #[test]
    fn the_first_trace_waits_for_the_inflight_handoff() {
        let (started, release) = (Arc::new(Event::default()), Arc::new(Event::default()));
        let backend = Fake::new(vec![
            blocked(
                "I picked up the bridge fix request, and I’ll return with a plan.",
                &started,
                &release,
            ),
            reply("I’m checking the bridge wiring now."),
        ]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let command = command(12, "cmd-12");
        runtime.submit_user("Fix the voice bridge race", &command);
        assert!(started.wait(1.0));
        let mut trace =
            dict(r#"{"kind": "reasoning-summary", "message": "Checking the voice bridge wiring"}"#);
        trace.insert("command", command);
        runtime.submit_trace(trace);
        thread::sleep(Duration::from_millis(50));
        assert!(recorded.spoken().is_empty());
        assert_eq!(backend.interrupts.load(Ordering::SeqCst), 0);
        release.set();
        assert!(wait_until(|| recorded.spoken().len() == 2));
        assert_eq!(
            recorded.texts(),
            [
                "I picked up the bridge fix request, and I’ll return with a plan.",
                "I’m checking the bridge wiring now."
            ]
        );
        runtime.shutdown();
    }

    #[test]
    fn a_clarification_is_asked_directly() {
        let backend = Fake::replies(&[
            "I picked up the test fix request.",
            "Which repository should I use?",
        ]);
        let (runtime, recorded) = runtime(&backend, Options::default());
        runtime.start();
        let command = command(9, "cmd-9");
        runtime.submit_user("Fix the tests", &command);
        assert!(wait_until(|| backend.prompts().len() == 1));
        let mut trace = dict(
            r#"{"kind": "clarification-request", "message": "Ask which repository should be changed"}"#,
        );
        trace.insert("command", command);
        runtime.submit_trace(trace);
        assert!(wait_until(|| recorded.spoken().len() == 2));
        assert_eq!(recorded.texts()[1], "Which repository should I use?");
        assert_eq!(
            recorded.spoken()[1].metadata.string("kind"),
            "clarification"
        );
        assert!(backend.prompts()[1].contains("authoritative clarification request"));
        runtime.shutdown();
    }

    #[test]
    fn played_speech_suppresses_redundant_progress_but_never_a_decision() {
        let suppress = r#"{"decision": "suppress", "spoken_text": ""}"#;
        let backend = Fake::replies(&["I picked up the bridge review.", suppress, suppress]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                coverage: Some(
                    r#"[{"lifecycle_role": "acknowledgement", "covered_facts": ["bridge wiring will be inspected"],
                         "spoken_text": "I will inspect the bridge wiring."}]"#,
                ),
                ..Options::default()
            },
        );
        runtime.start();
        let command = with(
            command(35, "cmd-35"),
            r#"{"work_disposition": {"route": "queue_project_work"}}"#,
        );
        runtime.submit_user("Review the bridge", &command);
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let mut trace = dict(
            r#"{"kind": "reasoning-summary", "message": "I will inspect the bridge wiring."}"#,
        );
        trace.insert("command", command.clone());
        runtime.submit_trace(trace);
        assert!(wait_until(
            || recorded.realizations.lock().unwrap().len() == 1
        ));
        assert_eq!(
            recorded.realizations.lock().unwrap()[0],
            (
                "progress".into(),
                "suppress".into(),
                "covered_by_played_speech".into()
            )
        );
        assert_eq!(recorded.spoken().len(), 1);
        assert!(backend.prompts()[1].contains(concat!(
            "Speech that actually finished playing for this exact Relay command:\n",
            r#"[{"lifecycle_role":"acknowledgement","covered_facts":["bridge wiring will be inspected"],"#,
            r#""spoken_text":"I will inspect the bridge wiring."}]"#,
            "\n\nThe authoritative lifecycle role is progress;"
        )));
        assert!(backend.prompts()[1].ends_with("\nReturn only the JSON object."));

        let mut question = dict(
            r#"{"kind": "clarification-request", "message": "Which bridge implementation should I inspect?"}"#,
        );
        question.insert("command", command);
        runtime.submit_trace(question);
        assert!(wait_until(|| recorded.spoken().len() == 2));
        let spoken = &recorded.spoken()[1];
        assert_eq!(spoken.text, "Which bridge implementation should I inspect?");
        assert_eq!(spoken.metadata.string("lifecycle_role"), "decision");
        assert_eq!(
            spoken.metadata.string("suppression_reason"),
            "protected_lifecycle"
        );
        runtime.shutdown();
    }

    #[test]
    fn a_lossy_delta_speaks_the_complete_detail() {
        let detail = "I found three verification-blocked tickets. I am separating their real-world \
                      evidence requirements from the checks that can run in this worktree now.";
        let backend = Fake::replies(&[
            "I picked up the ticket review.",
            r#"{"decision": "delta", "spoken_text": "I found three verification-blocked tickets."}"#,
            "not-json",
        ]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                coverage: Some(PLAYED_ACKNOWLEDGEMENT),
                ..Options::default()
            },
        );
        runtime.start();
        let command = with(
            command(34, "cmd-34"),
            r#"{"work_disposition": {"route": "continue_current"}}"#,
        );
        runtime.submit_user("Review the blocked tickets", &command);
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let mut trace = dict(r#"{"kind": "reasoning-summary", "message": "I found three..."}"#);
        trace.insert("lifecycle_detail", detail);
        trace.insert("command", command.clone());
        runtime.submit_trace(trace);
        assert!(wait_until(|| recorded.spoken().len() == 2));
        let spoken = &recorded.spoken()[1];
        assert!(backend.prompts()[1].contains(detail));
        assert_eq!(
            (spoken.text.as_str(), spoken.display.as_deref()),
            (detail, Some(detail))
        );
        assert_eq!(spoken.metadata.string("kind"), "progress");
        assert_eq!(spoken.metadata.string("realization_decision"), "full");
        assert_eq!(spoken.metadata.string("suppression_reason"), "lossy_delta");

        let mut malformed =
            dict(r#"{"kind": "reasoning-summary", "message": "Checking the logs now."}"#);
        malformed.insert("command", command);
        runtime.submit_trace(malformed);
        assert!(wait_until(|| recorded.spoken().len() == 3));
        assert_eq!(recorded.texts()[2], "Checking the logs now.");
        assert_eq!(
            recorded.spoken()[2].metadata.string("suppression_reason"),
            "malformed_arbitration"
        );
        runtime.shutdown();
    }

    #[test]
    fn an_authoritative_final_is_spoken_word_for_word() {
        let backend = Fake::replies(&["I picked it up."]);
        let (runtime, recorded) = runtime(
            &backend,
            Options {
                coverage: Some(PLAYED_ACKNOWLEDGEMENT),
                ..Options::default()
            },
        );
        runtime.start();
        let command = with(
            command(41, "cmd-41"),
            r#"{"work_disposition": {"route": "queue_project_work"}}"#,
        );
        runtime.submit_user("Handle RR-263", &command);
        assert!(wait_until(|| recorded.spoken().len() == 1));
        let final_text = "RR-263 completed, but run 42 failed and deployment is blocked.";
        let mut payload = command;
        payload.insert("text", final_text);
        runtime.submit_final(payload);
        let spoken = &recorded.spoken()[1];
        assert_eq!(spoken.text, final_text);
        assert_eq!(spoken.metadata.string("lifecycle_role"), "result");
        assert_eq!(spoken.metadata.string("realization_decision"), "full");
        assert_eq!(
            spoken.metadata.string("suppression_reason"),
            "authoritative_final_direct"
        );
        assert_eq!(
            json::dumps(spoken.metadata.get("covered_facts").unwrap()),
            json::dumps(&vec![Value::from(final_text)].into())
        );
        assert_eq!(
            *recorded.realizations.lock().unwrap(),
            [(
                "result".into(),
                "full".into(),
                "authoritative_final_direct".into()
            )]
        );
        assert_eq!(backend.prompts().len(), 1);
        runtime.shutdown();
    }

    #[test]
    fn relation_reversals_and_dropped_verbs_are_not_preserved() {
        let played: Vec<Dict> = Vec::new();
        assert!(!preserves_authoritative_content(
            "The unit test passed and the integration test failed.",
            &played,
            "The unit test failed and the integration test passed.",
        ));
        assert!(!preserves_authoritative_content(
            "The deployment check passed.",
            &played,
            "The deployment check did not pass.",
        ));
        assert!(!preserves_authoritative_content(
            "RR-263 passed run 39. Inspect the logs and review the deployment report next.",
            &played,
            "RR-263 passed run 39. The logs and deployment report are next.",
        ));
        assert!(preserves_authoritative_content(
            "You're welcome!",
            &played,
            "You’re welcome."
        ));
        let covered = vec![dict(r#"{"spoken_text": "RR-263 is implemented"}"#)];
        assert!(preserves_authoritative_content(
            "RR-263 is implemented and verified.",
            &covered,
            "RR-263 is implemented and verified"
        ));
        assert!(!preserves_authoritative_content(
            "RR-263 is implemented and verified.",
            &covered,
            ""
        ));
    }

    #[test]
    fn response_roles_follow_the_marker_and_promise_language() {
        assert_eq!(
            user_response_role("__ANSWER__  Hi,\n there.", "pending"),
            ("Hi, there.".into(), "answer")
        );
        assert_eq!(
            user_response_role("__handoff__: Checking it.", "conversation"),
            ("Checking it.".into(), "handoff")
        );
        assert_eq!(
            user_response_role("__ANSWER__ I picked up your request.", "conversation"),
            ("I picked up your request.".into(), "handoff")
        );
        assert_eq!(
            user_response_role("Sure thing.", "conversation"),
            ("Sure thing.".into(), "answer")
        );
        assert_eq!(
            user_response_role("Sure thing.", "work"),
            ("Sure thing.".into(), "handoff")
        );
        assert_eq!(
            user_response_role("I'll come back.", "self_explanation"),
            ("I'll come back.".into(), "answer")
        );
    }

    #[test]
    fn self_explanations_are_recognised() {
        for text in [
            "What is Relay Runner?",
            "hey, what does the relay runner do",
            "I'm demoing Relay Runner; explain what it does to the audience.",
            "Tell us about Relay Runner",
            "Describe Relay Runner.",
        ] {
            assert!(is_relay_runner_self_explanation(text), "{text}");
        }
        for text in [
            "What is Relay Runner's version?",
            "Fix the relay runner build",
            "What is this?",
        ] {
            assert!(!is_relay_runner_self_explanation(text), "{text}");
        }
    }

    #[test]
    fn a_disabled_messenger_is_not_created_and_a_missing_command_degrades() {
        let callbacks = || Callbacks {
            speak: Box::new(|_, _, _, _, _| true),
            is_current: Box::new(|_, _| true),
            coverage_provider: None,
            realization_observer: None,
            timing_observer: None,
            continuity_observer: None,
        };
        let disabled = dict(r#"{"general": {"provider": "claude", "messenger_enabled": false}}"#);
        assert!(create_messenger_runtime(&disabled, "/", callbacks()).is_none());

        for provider in ["codex", "claude"] {
            let spoken: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
            let record = Arc::clone(&spoken);
            let mut callbacks = callbacks();
            callbacks.speak = Box::new(move |text, _, _, _, metadata| {
                record
                    .lock()
                    .unwrap()
                    .push((text.to_string(), metadata.string("kind")));
                true
            });
            let config = dict(&format!(
                r#"{{"general": {{"provider": "{provider}", "command": "/nonexistent/{provider}"}}}}"#
            ));
            let runtime = create_messenger_runtime(&config, "/", callbacks).unwrap();
            assert_eq!(runtime.inner.provider.as_deref(), Some(provider));
            runtime.start();
            runtime.submit_user("Handle this request", &command(5, provider));
            assert!(wait_until(|| spoken.lock().unwrap().len() == 1));
            assert_eq!(
                spoken.lock().unwrap()[0],
                (MESSENGER_DEGRADED_TEXT.to_string(), "handoff".to_string())
            );
            runtime.shutdown();
        }
    }
}
