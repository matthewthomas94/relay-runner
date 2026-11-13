//! `CodexMessengerBackend`: a warm `codex app-server --stdio` process with one
//! ephemeral, read-only messenger thread, spoken to over JSON-RPC.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use crate::json::{self, Dict, Value, py_strip};

use super::catalog::{error_message, request};
use super::config::{Config, child_environment};
use super::process::{Proc, read_json_lines};
use super::{Backend, MESSENGER_SYSTEM_PROMPT, Partial, first_semantic_response};

#[derive(Default)]
struct Turn {
    text: String,
    error: Option<String>,
    /// Completed, failed or abandoned: what setting the Python event meant.
    done: bool,
    /// Has an entry in Python's `_turn_events`, so a process exit fails it.
    tracked: bool,
    callback: Option<Partial>,
}

#[derive(Default)]
struct State {
    proc: Option<Arc<Proc>>,
    next_request_id: i64,
    /// Requests waiting for an answer; `Some` once it arrived.
    responses: HashMap<i64, Option<Dict>>,
    turns: HashMap<String, Turn>,
    pending_callback: Option<Partial>,
    thread_id: Option<String>,
    active_turn_id: Option<String>,
    ask_in_progress: bool,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    /// `_fail_pending`: every waiting request and tracked turn fails. With a
    /// process, only while that process is still the current one.
    fn fail_pending(&self, message: &str, proc: Option<&Arc<Proc>>) {
        let mut state = self.lock();
        if let Some(proc) = proc
            && !state
                .proc
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, proc))
        {
            return;
        }
        for response in state.responses.values_mut() {
            let mut error = Dict::new();
            error.insert("message", message);
            let mut failure = Dict::new();
            failure.insert("error", error);
            *response = Some(failure);
        }
        for turn in state.turns.values_mut().filter(|turn| turn.tracked) {
            turn.error = Some(message.to_string());
            turn.done = true;
        }
        state.thread_id = None;
        state.active_turn_id = None;
        for turn in state.turns.values_mut() {
            turn.callback = None;
        }
        state.pending_callback = None;
        if proc.is_some() {
            state.proc = None;
        }
        drop(state);
        self.changed.notify_all();
    }

    /// `_take_partial_locked`: the first speakable sentence of a turn, once.
    fn take_partial(state: &mut State, turn_id: &str, complete: bool) -> Option<(Partial, String)> {
        let turn = state.turns.get_mut(turn_id)?;
        turn.callback.as_ref()?;
        let response = first_semantic_response(&turn.text, complete)?;
        Some((turn.callback.take()?, response))
    }

    fn handle(&self, message: &Dict, proc: &Arc<Proc>) {
        let mut state = self.lock();
        if !state
            .proc
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, proc))
        {
            return;
        }
        if let Some(Value::Int(request_id)) = message.get("id") {
            if let Some(slot) = state.responses.get_mut(request_id) {
                *slot = Some(message.clone());
                drop(state);
                self.changed.notify_all();
            }
            return;
        }
        let method = message.string("method");
        let Some(params) = message.get("params").and_then(Value::as_dict) else {
            return;
        };
        let turn_id = params.string("turnId");
        let partial = match method.as_str() {
            "item/agentMessage/delta" if !turn_id.is_empty() => {
                let delta = params.string("delta");
                state
                    .turns
                    .entry(turn_id.clone())
                    .or_default()
                    .text
                    .push_str(&delta);
                Self::take_partial(&mut state, &turn_id, false)
            }
            "item/completed" if !turn_id.is_empty() => {
                let Some(item) = params.get("item").and_then(Value::as_dict) else {
                    return;
                };
                let text = item.string("text");
                if !item.get("type").is_some_and(|t| t.is_str("agentMessage")) || text.is_empty() {
                    return;
                }
                state.turns.entry(turn_id.clone()).or_default().text = text;
                Self::take_partial(&mut state, &turn_id, true)
            }
            "turn/completed" => {
                let Some(turn) = params.get("turn").and_then(Value::as_dict) else {
                    return;
                };
                let turn_id = match turn.string("id") {
                    id if id.is_empty() => turn_id,
                    id => id,
                };
                if turn_id.is_empty() {
                    return;
                }
                let final_text = last_agent_message(turn.get("items"));
                let status = turn.string("status");
                let error = turn.truthy("error").cloned();
                let entry = state.turns.entry(turn_id.clone()).or_default();
                if !final_text.is_empty() {
                    entry.text = final_text;
                }
                if status == "failed" || error.is_some() {
                    let cause = error.map_or(status, |error| error.py_str());
                    entry.error = Some(format!("Codex messenger turn failed: {cause}"));
                }
                entry.done = true;
                entry.tracked = true;
                let partial = Self::take_partial(&mut state, &turn_id, true);
                drop(state);
                self.changed.notify_all();
                emit(partial);
                return;
            }
            _ => return,
        };
        drop(state);
        emit(partial);
    }
}

fn emit(partial: Option<(Partial, String)>) {
    if let Some((callback, response)) = partial {
        callback(response);
    }
}

/// `_last_agent_message`: the last final answer, else the last message.
fn last_agent_message(items: Option<&Value>) -> String {
    let messages: Vec<&Dict> = items
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .filter(|item| {
            item.get("type").is_some_and(|t| t.is_str("agentMessage"))
                && item.truthy("text").is_some()
        })
        .collect();
    let finals: Vec<&&Dict> = messages
        .iter()
        .filter(|item| item.get("phase").is_some_and(|p| p.is_str("final_answer")))
        .collect();
    finals
        .last()
        .map(|item| item.string("text"))
        .or_else(|| messages.last().map(|item| item.string("text")))
        .unwrap_or_default()
}

pub struct CodexBackend {
    config: Config,
    argv: Vec<String>,
    /// `actor_role`: whom the provider process acts as.
    pub actor_role: &'static str,
    /// The whole `spawn_command` and the `thread_start_params` of a subclass
    /// that overrides them.
    command: Option<Vec<String>>,
    thread_params: Option<Dict>,
    start_lock: Arc<Mutex<()>>,
    shared: Arc<Shared>,
}

impl CodexBackend {
    pub fn new(config: Config, argv: Vec<String>) -> Self {
        Self::with_launch(config, argv, "messenger", None, None)
    }

    /// A backend that runs as `actor_role` and, given them, spawns `command`
    /// and starts its thread with `thread_params` instead of the messenger's,
    /// as `CodexSidecarBackend` (`sidecar_lane.py`) does.
    pub fn with_launch(
        config: Config,
        argv: Vec<String>,
        actor_role: &'static str,
        command: Option<Vec<String>>,
        thread_params: Option<Dict>,
    ) -> Self {
        let state = State {
            next_request_id: 1,
            ..State::default()
        };
        Self {
            config,
            argv,
            actor_role,
            command,
            thread_params,
            start_lock: Arc::default(),
            shared: Arc::new(Shared {
                state: Mutex::new(state),
                changed: Condvar::new(),
            }),
        }
    }

    pub fn spawn_command(&self) -> Vec<String> {
        if let Some(command) = &self.command {
            return command.clone();
        }
        let mut command = self.argv.clone();
        for part in [
            "app-server",
            "--stdio",
            "-c",
            "features.shell_tool=false",
            "-c",
            "features.unified_exec=false",
            "-c",
            "features.apps=false",
            "-c",
            "features.multi_agent=false",
            "-c",
            "features.hooks=false",
            "-c",
            "tools.web_search=false",
            "-c",
            "mcp_servers={}",
        ] {
            command.push(part.to_string());
        }
        command
    }

    pub fn thread_start_params(&self) -> Dict {
        if let Some(params) = &self.thread_params {
            return params.clone();
        }
        let mut params = Dict::new();
        params.insert("model", self.config.model.as_str());
        params.insert("cwd", self.config.cwd.as_str());
        params.insert("approvalPolicy", "never");
        params.insert("sandbox", "read-only");
        params.insert("baseInstructions", MESSENGER_SYSTEM_PROMPT);
        for key in [
            "dynamicTools",
            "environments",
            "runtimeWorkspaceRoots",
            "selectedCapabilityRoots",
        ] {
            params.insert(key, Vec::<Value>::new());
        }
        params.insert("ephemeral", true);
        params
    }

    fn is_ready(&self) -> bool {
        let state = self.shared.lock();
        state.proc.as_ref().is_some_and(|proc| proc.is_running()) && state.thread_id.is_some()
    }

    fn write(&self, payload: Dict) -> Result<(), String> {
        write(&self.shared, payload)
    }

    fn rpc(&self, method: &str, params: Dict, timeout: Duration) -> Result<Dict, String> {
        rpc(&self.shared, method, params, timeout)
    }

    fn stop_process(&self) {
        stop_process(&self.shared);
    }

    fn open_thread(&self) -> Result<String, String> {
        let response = self.rpc(
            "thread/start",
            self.thread_start_params(),
            Duration::from_secs(15),
        )?;
        let thread_id = response
            .get("result")
            .and_then(Value::as_dict)
            .and_then(|result| result.get("thread"))
            .and_then(Value::as_dict)
            .map(|thread| thread.string("id"))
            .unwrap_or_default();
        if thread_id.is_empty() {
            return Err("Codex messenger did not return a thread id".to_string());
        }
        Ok(thread_id)
    }

    fn initialize(&self) -> Result<String, String> {
        let mut client_info = Dict::new();
        client_info.insert("name", "relay-runner-messenger");
        client_info.insert("title", "Relay Runner Messenger");
        client_info.insert("version", "1");
        let mut capabilities = Dict::new();
        capabilities.insert("experimentalApi", true);
        let mut params = Dict::new();
        params.insert("clientInfo", client_info);
        params.insert("capabilities", capabilities);
        self.rpc("initialize", params, Duration::from_secs(10))?;
        self.write(request(None, "initialized", Dict::new()))?;
        self.open_thread()
    }
}

/// `_write_json`.
fn write(shared: &Shared, payload: Dict) -> Result<(), String> {
    let proc = shared.lock().proc.clone();
    let proc = proc
        .filter(|proc| proc.is_running())
        .ok_or("Codex messenger process is not writable")?;
    proc.write_line(&json::dumps_compact(&Value::Dict(payload)))
        .map_err(|error| format!("could not write to Codex messenger: {error}"))
}

/// `_stop_process`.
fn stop_process(shared: &Shared) {
    let proc = {
        let mut state = shared.lock();
        state.thread_id = None;
        state.active_turn_id = None;
        state.pending_callback = None;
        state.proc.take()
    };
    let Some(proc) = proc else { return };
    proc.stop();
    shared.fail_pending("Codex messenger was interrupted", None);
}

/// `_rpc_request`.
fn rpc(shared: &Shared, method: &str, params: Dict, timeout: Duration) -> Result<Dict, String> {
    let request_id = {
        let mut state = shared.lock();
        if !state.proc.as_ref().is_some_and(|proc| proc.is_running()) {
            return Err("Codex messenger process is not running".to_string());
        }
        let request_id = state.next_request_id;
        state.next_request_id += 1;
        state.responses.insert(request_id, None);
        request_id
    };
    if let Err(error) = write(shared, request(Some(request_id), method, params)) {
        shared.lock().responses.remove(&request_id);
        return Err(error);
    }
    let deadline = Instant::now() + timeout.max(Duration::from_millis(100));
    let mut state = shared.lock();
    let response = loop {
        if let Some(Some(_)) = state.responses.get(&request_id) {
            break state
                .responses
                .remove(&request_id)
                .flatten()
                .unwrap_or_default();
        }
        let now = Instant::now();
        if now >= deadline {
            state.responses.remove(&request_id);
            return Err(format!("Codex messenger {method} timed out"));
        }
        state = shared
            .changed
            .wait_timeout(state, deadline - now)
            .unwrap()
            .0;
    };
    if let Some(error) = response.get("error") {
        return Err(format!(
            "Codex messenger {method} failed: {}",
            error_message(error)
        ));
    }
    Ok(response)
}

impl Backend for CodexBackend {
    fn start(&self) -> Result<(), String> {
        let _guard = self.start_lock.lock().unwrap();
        if self.is_ready() {
            return Ok(());
        }
        self.stop_process();
        let mut command = Command::new(&self.argv[0]);
        command
            .args(&self.spawn_command()[1..])
            .current_dir(&self.config.cwd)
            .env_clear()
            .envs(child_environment(self.actor_role))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let (proc, stdout) = Proc::spawn(&mut command)
            .map_err(|error| format!("could not start Codex messenger: {error}"))?;
        let proc = Arc::new(proc);
        self.shared.lock().proc = Some(Arc::clone(&proc));
        let shared = Arc::clone(&self.shared);
        let reader_proc = Arc::clone(&proc);
        thread::Builder::new()
            .name("codex-messenger-reader".into())
            .spawn(move || {
                read_json_lines(stdout, |message| {
                    shared.handle(message, &reader_proc);
                    true
                });
                shared.fail_pending("Codex messenger process exited", Some(&reader_proc));
            })
            .map_err(|error| error.to_string())?;
        match self.initialize() {
            Ok(thread_id) => {
                self.shared.lock().thread_id = Some(thread_id);
                Ok(())
            }
            Err(error) => {
                self.stop_process();
                Err(error)
            }
        }
    }

    fn rebind(&self, _partition: &str) -> Result<(), String> {
        let _guard = self.start_lock.lock().unwrap();
        if !self.is_ready() {
            return Ok(()); // the next start() opens a fresh thread anyway
        }
        let thread_id = self.open_thread()?;
        self.shared.lock().thread_id = Some(thread_id);
        Ok(())
    }

    fn ask(
        &self,
        prompt: &str,
        timeout: Duration,
        on_partial: Option<Partial>,
    ) -> Result<String, String> {
        self.start()?;
        let Some(thread_id) = self.shared.lock().thread_id.clone() else {
            return Err("Codex messenger is not ready".to_string());
        };
        {
            let mut state = self.shared.lock();
            state.ask_in_progress = true;
            state.pending_callback = on_partial;
        }
        let result = self.ask_turn(&thread_id, prompt, timeout);
        let mut state = self.shared.lock();
        state.ask_in_progress = false;
        state.pending_callback = None;
        result
    }

    fn interrupt(&self) {
        let (thread_id, turn_id, ask_in_progress, running) = {
            let state = self.shared.lock();
            (
                state.thread_id.clone(),
                state.active_turn_id.clone(),
                state.ask_in_progress,
                state.proc.as_ref().is_some_and(|proc| proc.is_running()),
            )
        };
        if let (Some(thread_id), Some(turn_id), true) = (thread_id, turn_id, running) {
            let shared = Arc::clone(&self.shared);
            thread::spawn(move || {
                let mut params = Dict::new();
                params.insert("threadId", thread_id);
                params.insert("turnId", turn_id);
                let _ = rpc(&shared, "turn/interrupt", params, Duration::from_secs(3));
            });
        } else if ask_in_progress {
            let shared = Arc::clone(&self.shared);
            let start_lock = Arc::clone(&self.start_lock);
            thread::spawn(move || {
                let _guard = start_lock.lock().unwrap();
                stop_process(&shared);
            });
        }
    }

    fn shutdown(&self) {
        self.stop_process();
    }
}

impl CodexBackend {
    fn ask_turn(&self, thread_id: &str, prompt: &str, timeout: Duration) -> Result<String, String> {
        let mut input = Dict::new();
        input.insert("type", "text");
        input.insert("text", prompt);
        let mut params = Dict::new();
        params.insert("threadId", thread_id);
        params.insert("input", vec![Value::Dict(input)]);
        params.insert("effort", self.config.effort.as_str());
        params.insert("summary", "none");
        params.insert("approvalPolicy", "never");
        params.insert("environments", Vec::<Value>::new());
        params.insert("runtimeWorkspaceRoots", Vec::<Value>::new());
        let response = self.rpc("turn/start", params, timeout.min(Duration::from_secs(15)))?;
        let turn_id = response
            .get("result")
            .and_then(Value::as_dict)
            .and_then(|result| result.get("turn"))
            .and_then(Value::as_dict)
            .map(|turn| turn.string("id"))
            .unwrap_or_default();
        if turn_id.is_empty() {
            return Err("Codex messenger did not return a turn id".to_string());
        }
        let partial = {
            let mut state = self.shared.lock();
            state.active_turn_id = Some(turn_id.clone());
            let callback = state.pending_callback.take();
            let turn = state.turns.entry(turn_id.clone()).or_default();
            turn.tracked = true;
            if callback.is_some() {
                turn.callback = callback;
            }
            Shared::take_partial(&mut state, &turn_id, false)
        };
        emit(partial);
        let deadline = Instant::now() + timeout.max(Duration::from_millis(100));
        let mut state = self.shared.lock();
        loop {
            if state.turns.get(&turn_id).is_some_and(|turn| turn.done) {
                break;
            }
            let now = Instant::now();
            if now >= deadline {
                drop(state);
                self.interrupt();
                return Err("Codex messenger response timed out".to_string());
            }
            state = self
                .shared
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap()
                .0;
        }
        let turn = state.turns.remove(&turn_id).unwrap_or_default();
        if state.active_turn_id.as_deref() == Some(turn_id.as_str()) {
            state.active_turn_id = None;
        }
        match turn.error {
            Some(error) => Err(error),
            None => Ok(py_strip(&turn.text).to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_final_answer_wins() {
        let items = json::parse(
            r#"[
            {"type": "agentMessage", "text": "first", "phase": "final_answer"},
            {"type": "agentMessage", "text": "commentary"},
            {"type": "agentMessage", "text": "second", "phase": "final_answer"},
            {"type": "reasoning", "text": "hidden"}
        ]"#,
        )
        .unwrap();
        assert_eq!(last_agent_message(Some(&items)), "second");
        let plain = json::parse(
            r#"[{"type": "agentMessage", "text": "only"}, {"type": "agentMessage", "text": ""}]"#,
        )
        .unwrap();
        assert_eq!(last_agent_message(Some(&plain)), "only");
        assert_eq!(last_agent_message(None), "");
    }
}
