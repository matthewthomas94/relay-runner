//! `ClaudeMessengerBackend`: a warm `claude --print` stream-json process with
//! tools, slash commands and MCP servers off. It starts only on a verified
//! Claude subscription, and each focused session resumes its own Claude
//! session.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use crate::json::{self, Dict, Value, py_strip};

use super::config::{Config, child_environment};
use super::process::{Proc, read_json_lines};
use super::subscription;
use super::{Backend, MESSENGER_SYSTEM_PROMPT, Partial, first_semantic_response};

/// One `ask` waiting for its `result` line (Python's `_pending` dict).
struct Pending {
    serial: u64,
    process: Arc<Proc>,
    text: String,
    error: Option<String>,
    done: bool,
    on_partial: Option<Partial>,
    partial_delivered: bool,
}

#[derive(Default)]
struct State {
    proc: Option<Arc<Proc>>,
    pending: Option<Pending>,
    next_serial: u64,
    session_id: Option<String>,
    partition_session_ids: HashMap<String, String>,
    partition: String,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    fn is_current(state: &State, proc: &Arc<Proc>) -> bool {
        state
            .proc
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, proc))
    }

    /// The pending ask for `proc`, while `proc` is current.
    fn pending_for<'a>(state: &'a mut State, proc: &Arc<Proc>) -> Option<&'a mut Pending> {
        if !Self::is_current(state, proc) {
            return None;
        }
        state
            .pending
            .as_mut()
            .filter(|pending| Arc::ptr_eq(&pending.process, proc))
    }

    /// `_take_claude_partial_locked`.
    fn take_partial(pending: &mut Pending, complete: bool) -> Option<(Partial, String)> {
        if pending.partial_delivered || pending.on_partial.is_none() {
            return None;
        }
        let response = first_semantic_response(&pending.text, complete)?;
        pending.partial_delivered = true;
        Some((pending.on_partial.take()?, response))
    }

    /// `_append_partial` (`replace: false`) and `_set_partial` (`replace: true`).
    fn update_text(&self, proc: &Arc<Proc>, text: &str, replace: bool) {
        if text.is_empty() && !replace {
            return;
        }
        let partial = {
            let mut state = self.lock();
            let Some(pending) = Self::pending_for(&mut state, proc) else {
                return;
            };
            if replace {
                pending.text = text.to_string();
            } else {
                pending.text.push_str(text);
            }
            Self::take_partial(pending, false)
        };
        emit(partial);
    }

    /// One stream-json line; `false` stops the reader.
    fn handle(&self, message: &Dict, proc: &Arc<Proc>) -> bool {
        {
            let mut state = self.lock();
            if !Self::is_current(&state, proc) {
                return false;
            }
            if let Some(session_id) = message.truthy("session_id") {
                state.session_id = Some(session_id.py_str());
            }
        }
        let kind = message.get("type");
        if kind.is_some_and(|k| k.is_str("stream_event")) {
            let Some(event) = message.get("event").and_then(Value::as_dict) else {
                return true;
            };
            let delta = event.get("delta").and_then(Value::as_dict);
            if let Some(delta) = delta.filter(|d| {
                event
                    .get("type")
                    .is_some_and(|t| t.is_str("content_block_delta"))
                    && d.get("type").is_some_and(|t| t.is_str("text_delta"))
            }) {
                self.update_text(proc, &delta.string("text"), false);
            }
            return true;
        }
        if kind.is_some_and(|k| k.is_str("assistant")) {
            let content = message
                .get("message")
                .and_then(Value::as_dict)
                .and_then(|m| m.get("content"))
                .and_then(Value::as_list);
            if let Some(content) = content {
                let text: String = content
                    .iter()
                    .filter_map(Value::as_dict)
                    .filter(|block| block.get("type").is_some_and(|t| t.is_str("text")))
                    .map(|block| block.string("text"))
                    .collect();
                if !text.is_empty() {
                    self.update_text(proc, &text, true);
                }
            }
            return true;
        }
        if !kind.is_some_and(|k| k.is_str("result")) {
            return true;
        }
        let is_error = message.truthy("is_error").is_some();
        let partial = {
            let mut state = self.lock();
            let Some(pending) = Self::pending_for(&mut state, proc) else {
                return true;
            };
            let partial = if is_error {
                pending.error = Some(
                    message
                        .truthy("result")
                        .map_or_else(|| "Claude messenger turn failed".to_string(), Value::py_str),
                );
                None
            } else {
                pending.text = message.string("result");
                Self::take_partial(pending, true)
            };
            pending.done = true;
            partial
        };
        self.changed.notify_all();
        emit(partial);
        true
    }

    /// The reader's `finally`: a pending ask on this process fails.
    fn exited(&self, proc: &Arc<Proc>) {
        let mut state = self.lock();
        if !Self::is_current(&state, proc) {
            return;
        }
        if let Some(pending) = state.pending.as_mut()
            && Arc::ptr_eq(&pending.process, proc)
            && !pending.done
        {
            pending.error = Some("Claude messenger process exited".to_string());
            pending.done = true;
        }
        state.proc = None;
        drop(state);
        self.changed.notify_all();
    }

    /// Fails the pending ask and kills the process (`interrupt` and
    /// `shutdown`). `only_when_pending` is `interrupt`'s early return.
    fn interrupt(&self, only_when_pending: bool) {
        let proc = {
            let mut state = self.lock();
            if only_when_pending && state.pending.is_none() {
                return;
            }
            let proc = state.proc.take();
            if let Some(pending) = state.pending.as_mut() {
                pending.error = Some("Claude messenger was interrupted".to_string());
                pending.done = true;
            }
            proc
        };
        self.changed.notify_all();
        if let Some(proc) = proc {
            proc.kill();
        }
    }
}

fn emit(partial: Option<(Partial, String)>) {
    if let Some((callback, response)) = partial {
        callback(response);
    }
}

pub struct ClaudeBackend {
    config: Config,
    argv: Vec<String>,
    /// `actor_role`: whom the provider process acts as.
    pub actor_role: &'static str,
    /// The whole `spawn_command` of a subclass that overrides it.
    command: Option<Vec<String>>,
    start_lock: Mutex<()>,
    shared: Arc<Shared>,
}

impl ClaudeBackend {
    pub fn new(config: Config, argv: Vec<String>) -> Self {
        Self::with_launch(config, argv, "messenger", None)
    }

    /// A backend that runs as `actor_role` and, given `command`, spawns that
    /// instead of the messenger's command, as `ClaudeSidecarBackend`
    /// (`sidecar_lane.py`) does.
    pub fn with_launch(
        config: Config,
        argv: Vec<String>,
        actor_role: &'static str,
        command: Option<Vec<String>>,
    ) -> Self {
        Self {
            config,
            argv,
            actor_role,
            command,
            start_lock: Mutex::new(()),
            shared: Arc::new(Shared {
                state: Mutex::new(State::default()),
                changed: Condvar::new(),
            }),
        }
    }

    pub fn spawn_command(&self, session_id: Option<&str>) -> Vec<String> {
        if let Some(command) = &self.command {
            return command.clone();
        }
        let mut command = self.argv.clone();
        for part in [
            "--print",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model",
            &self.config.model,
            "--tools",
            "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config",
            r#"{"mcpServers":{}}"#,
            "--system-prompt",
            MESSENGER_SYSTEM_PROMPT,
        ] {
            command.push(part.to_string());
        }
        if self.config.effort != "default" {
            command.extend(["--effort".to_string(), self.config.effort.clone()]);
        }
        if let Some(session_id) = session_id {
            command.extend(["--resume".to_string(), session_id.to_string()]);
        }
        command
    }

    fn write(&self, payload: &Dict, proc: &Arc<Proc>) -> Result<(), String> {
        let current = self.shared.lock().proc.clone();
        if !current
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, proc))
        {
            return Err("Claude messenger process was superseded".to_string());
        }
        if !proc.is_running() {
            return Err("Claude messenger process is not writable".to_string());
        }
        proc.write_line(&json::dumps_compact(&Value::Dict(payload.clone())))
            .map_err(|error| format!("could not write to Claude messenger: {error}"))
    }
}

impl Backend for ClaudeBackend {
    fn start(&self) -> Result<(), String> {
        let _guard = self.start_lock.lock().unwrap();
        if self
            .shared
            .lock()
            .proc
            .as_ref()
            .is_some_and(|proc| proc.is_running())
        {
            return Ok(());
        }
        let environment = child_environment(self.actor_role);
        // Subscription-only: never start Claude on an API key or other metered route.
        let readiness = subscription::check(&self.argv, &self.config.cwd, &environment);
        if !readiness.ready() {
            return Err(readiness.message);
        }
        let session_id = self.shared.lock().session_id.clone();
        let argv = self.spawn_command(session_id.as_deref());
        let mut command = Command::new(&argv[0]);
        command
            .args(&argv[1..])
            .current_dir(&self.config.cwd)
            .env_clear()
            .envs(&environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let (proc, stdout) = Proc::spawn(&mut command)
            .map_err(|error| format!("could not start Claude messenger: {error}"))?;
        let proc = Arc::new(proc);
        self.shared.lock().proc = Some(Arc::clone(&proc));
        let shared = Arc::clone(&self.shared);
        thread::Builder::new()
            .name("claude-messenger-reader".into())
            .spawn(move || {
                read_json_lines(stdout, |message| shared.handle(message, &proc));
                shared.exited(&proc);
            })
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    fn rebind(&self, partition: &str) -> Result<(), String> {
        let proc = {
            let _guard = self.start_lock.lock().unwrap();
            let mut state = self.shared.lock();
            if let Some(session_id) = state.session_id.clone() {
                let current = state.partition.clone();
                state.partition_session_ids.insert(current, session_id);
            }
            state.partition = partition.to_string();
            state.session_id = state.partition_session_ids.get(partition).cloned();
            state.proc.take()
        };
        if let Some(proc) = proc {
            proc.kill();
        }
        self.start()
    }

    fn ask(
        &self,
        prompt: &str,
        timeout: Duration,
        on_partial: Option<Partial>,
    ) -> Result<String, String> {
        self.start()?;
        let proc = self.shared.lock().proc.clone();
        let Some(proc) = proc.filter(|proc| proc.is_running()) else {
            return Err("Claude messenger is not ready".to_string());
        };
        let serial = {
            let mut state = self.shared.lock();
            state.next_serial += 1;
            let serial = state.next_serial;
            state.pending = Some(Pending {
                serial,
                process: Arc::clone(&proc),
                text: String::new(),
                error: None,
                done: false,
                on_partial,
                partial_delivered: false,
            });
            serial
        };
        let mut message = Dict::new();
        message.insert("role", "user");
        message.insert("content", prompt);
        let mut payload = Dict::new();
        payload.insert("type", "user");
        payload.insert("message", message);
        let result = self
            .write(&payload, &proc)
            .and_then(|()| self.wait(serial, timeout));
        let mut state = self.shared.lock();
        if state
            .pending
            .as_ref()
            .is_some_and(|pending| pending.serial == serial)
        {
            state.pending = None;
        }
        result
    }

    fn interrupt(&self) {
        self.shared.interrupt(true);
    }

    fn shutdown(&self) {
        self.shared.interrupt(false);
    }
}

impl ClaudeBackend {
    fn wait(&self, serial: u64, timeout: Duration) -> Result<String, String> {
        let deadline = Instant::now() + timeout.max(Duration::from_millis(100));
        let mut state = self.shared.lock();
        loop {
            match state
                .pending
                .as_ref()
                .filter(|pending| pending.serial == serial)
            {
                Some(pending) if pending.done => {
                    return match &pending.error {
                        Some(error) => Err(error.clone()),
                        None => Ok(py_strip(&pending.text).to_string()),
                    };
                }
                Some(_) => {}
                // Replaced by a newer ask: Python's event would never be set.
                None => {}
            }
            let now = Instant::now();
            if now >= deadline {
                drop(state);
                self.interrupt();
                return Err("Claude messenger response timed out".to_string());
            }
            state = self
                .shared
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap()
                .0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_is_tool_free_and_resumes_its_session() {
        let config = Config {
            enabled: true,
            provider: "claude".into(),
            command: "claude".into(),
            model: "sonnet".into(),
            effort: "high".into(),
            cwd: "/".into(),
        };
        let backend = ClaudeBackend::new(config, vec!["/bin/claude".into()]);
        let argv = backend.spawn_command(Some("abc"));
        assert_eq!(
            &argv[..12],
            &[
                "/bin/claude",
                "--print",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model",
                "sonnet",
                "--tools",
                "",
            ]
        );
        assert_eq!(
            &argv[12..16],
            &[
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config",
                r#"{"mcpServers":{}}"#,
            ]
        );
        assert_eq!(argv[16], "--system-prompt");
        assert_eq!(&argv[18..], &["--effort", "high", "--resume", "abc"]);
    }
}
