//! Port of `services/sidecar_lane.py` for the Rust bridge (RR-492): the
//! bounded, provider-neutral lane that runs safe read-only voice sidecars
//! beside the foreground provider.
//!
//! The lane runs one task at a time on its own thread, with at most
//! `max_pending` more waiting. Each task asks a fresh, one-shot provider
//! process that may only read the public web: Codex `app-server` with web
//! search on and every mutation tool off, or `claude --print` with only
//! `WebSearch` and `WebFetch`. Both are the messenger backends launched as the
//! `sidecar` actor. A failure reaches the bridge as a `failed` lifecycle event
//! and a fixed final text; its detail never leaves the lane.

use std::any::Any;
use std::io;
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::json::{Dict, Value, py_strip};
use crate::messenger::Backend;
use crate::messenger::catalog;
use crate::messenger::claude::ClaudeBackend;
use crate::messenger::codex::CodexBackend;
use crate::messenger::config::{self, Config};
use crate::support::Failure;

use super::ports::{Event, Sidecar};

pub const SIDECAR_SYSTEM_PROMPT: &str = "You are Relay Runner's bounded read-only sidecar.

Complete only the independent inspection or public research task in the user
request. You are not the foreground orchestrator: do not plan or mutate project
work, use repository files, control the desktop, contact people, spend money, or
perform any external side effect. Use only public web search/fetch capabilities.
Return a concise, independently verifiable result and include source URLs for
external factual claims. If the task cannot be completed under these limits,
state the limitation plainly. Never address speech or TTS directly.
";

pub const DEFAULT_TIMEOUT: f64 = 90.0;
pub const DEFAULT_MAX_PENDING: usize = 4;
const ACTOR_ROLE: &str = "sidecar";
const FAILED_RESULT: &str =
    "The independent read-only task could not complete in its bounded sidecar lane.";
const DEFAULT_SUMMARY: &str = "Independent bounded read-only work.";
/// `resolve_codex_family_from_cli`'s default timeout.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);
/// How often the lane thread looks at the shutdown flag (`get(timeout=0.1)`).
const POLL: Duration = Duration::from_millis(100);
/// How long `shutdown` waits for the lane thread (`join(timeout=2)`).
const JOIN_TIMEOUT: f64 = 2.0;

/// `SidecarLifecycleEvent`.
#[derive(Clone, Debug)]
pub struct SidecarLifecycleEvent {
    /// `started`, `completed` or `failed`.
    pub phase: &'static str,
    pub command: Dict,
    pub public_summary: String,
}

/// Runs one task's prompt within the timeout. A failure is named only by the
/// exception class Python would have raised, which is all the lane reports.
pub type Execute = Box<dyn Fn(&str, Duration) -> Result<String, Failure> + Send + Sync>;
pub type OnLifecycle = Box<dyn Fn(&SidecarLifecycleEvent) + Send + Sync>;
pub type OnFinal = Box<dyn Fn(&str, &Dict) + Send + Sync>;

/// `SidecarTask`.
struct Task {
    prompt: String,
    command: Dict,
}

/// `SidecarLane`: a single-flight sidecar worker concurrent with the
/// foreground provider.
pub struct SidecarLane {
    tasks: SyncSender<Option<Task>>,
    shutdown: Arc<AtomicBool>,
    /// Set when the lane thread has returned.
    finished: Arc<Event>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl SidecarLane {
    /// `SidecarLane(execute, on_lifecycle=..., on_final=...)`: a 90 second
    /// task timeout and four waiting tasks.
    pub fn new(execute: Execute, on_lifecycle: OnLifecycle, on_final: OnFinal) -> io::Result<Self> {
        Self::with_limits(
            execute,
            on_lifecycle,
            on_final,
            DEFAULT_TIMEOUT,
            DEFAULT_MAX_PENDING,
        )
    }

    /// `SidecarLane(..., timeout=timeout, max_pending=max_pending)`; the
    /// timeout is at least a second and at least one task may wait.
    pub fn with_limits(
        execute: Execute,
        on_lifecycle: OnLifecycle,
        on_final: OnFinal,
        timeout: f64,
        max_pending: usize,
    ) -> io::Result<Self> {
        let (tasks, receiver) = mpsc::sync_channel(max_pending.max(1));
        let shutdown = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(Event::default());
        let worker = Worker {
            execute,
            on_lifecycle,
            on_final,
            timeout: Duration::from_secs_f64(timeout.max(1.0)),
        };
        let (flag, done) = (Arc::clone(&shutdown), Arc::clone(&finished));
        let thread = thread::Builder::new()
            .name("relay-read-only-sidecar".into())
            .spawn(move || {
                worker.run(&receiver, &flag);
                done.set();
            })?;
        Ok(Self {
            tasks,
            shutdown,
            finished,
            thread: Mutex::new(Some(thread)),
        })
    }
}

impl Sidecar for SidecarLane {
    /// `submit`: queues a non-empty prompt unless the lane is shut down or
    /// already has `max_pending` tasks waiting.
    fn submit(&self, prompt: &str, command: &Dict) -> bool {
        let cleaned = py_strip(prompt);
        if cleaned.is_empty() || self.shutdown.load(Ordering::SeqCst) {
            return false;
        }
        let task = Task {
            prompt: cleaned.to_string(),
            command: command.clone(),
        };
        self.tasks.try_send(Some(task)).is_ok()
    }

    /// `shutdown`: no further task starts; a running one may finish. Waits up
    /// to two seconds for the lane thread unless called from it.
    fn shutdown(&self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = self.tasks.try_send(None);
        let mut thread = self.thread.lock().unwrap();
        let other_thread = thread
            .as_ref()
            .is_some_and(|handle| handle.thread().id() != thread::current().id());
        if other_thread
            && self.finished.wait(JOIN_TIMEOUT)
            && let Some(handle) = thread.take()
        {
            let _ = handle.join();
        }
    }
}

/// What the lane thread owns: `_run`, `_emit_lifecycle` and `_emit_final`.
struct Worker {
    execute: Execute,
    on_lifecycle: OnLifecycle,
    on_final: OnFinal,
    timeout: Duration,
}

impl Worker {
    fn run(&self, tasks: &Receiver<Option<Task>>, shutdown: &AtomicBool) {
        while !shutdown.load(Ordering::SeqCst) {
            let task = match tasks.recv_timeout(POLL) {
                Ok(Some(task)) => task,
                Err(RecvTimeoutError::Timeout) => continue,
                Ok(None) | Err(RecvTimeoutError::Disconnected) => return,
            };
            self.emit_lifecycle("started", &task.command);
            // Provider failure, a panic included, becomes bounded public state.
            let result = match panic::catch_unwind(AssertUnwindSafe(|| {
                (self.execute)(&task.prompt, self.timeout)
            })) {
                Ok(Ok(text)) if !py_strip(&text).is_empty() => Ok(py_strip(&text).to_string()),
                Ok(Ok(_)) => Err(Failure("RuntimeError")),
                Ok(Err(failure)) => Err(failure),
                Err(_) => Err(Failure("panic")),
            };
            match result {
                Ok(text) => {
                    self.emit_lifecycle("completed", &task.command);
                    self.emit_final(&text, &task.command);
                }
                Err(Failure(name)) => {
                    eprintln!("[sidecar] read-only task failed ({name})");
                    self.emit_lifecycle("failed", &task.command);
                    self.emit_final(FAILED_RESULT, &task.command);
                }
            }
        }
    }

    fn emit_lifecycle(&self, phase: &'static str, command: &Dict) {
        let reason = command
            .get("work_disposition")
            .and_then(Value::as_dict)
            .map(|disposition| disposition.string("public_reason"))
            .unwrap_or_default();
        let event = SidecarLifecycleEvent {
            phase,
            command: command.clone(),
            public_summary: if reason.is_empty() {
                DEFAULT_SUMMARY.to_string()
            } else {
                reason
            },
        };
        // Lifecycle reporting cannot kill the lane.
        if let Err(panic) = panic::catch_unwind(AssertUnwindSafe(|| (self.on_lifecycle)(&event))) {
            eprintln!(
                "[sidecar] lifecycle callback failed: {}",
                panic_message(&panic)
            );
        }
    }

    fn emit_final(&self, text: &str, command: &Dict) {
        // Reporting failure cannot kill the lane.
        if let Err(panic) = panic::catch_unwind(AssertUnwindSafe(|| (self.on_final)(text, command)))
        {
            eprintln!("[sidecar] final callback failed: {}", panic_message(&panic));
        }
    }
}

fn panic_message(panic: &Box<dyn Any + Send>) -> &str {
    panic
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("panic")
}

// -- the provider executor ------------------------------------------------------

/// `CodexSidecarBackend`: Codex `app-server` with web search enabled and every
/// mutation tool disabled.
pub fn codex_sidecar(config: &Config, argv: &[String]) -> CodexBackend {
    let mut command = argv.to_vec();
    command.extend(
        [
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
            "tools.web_search=true",
            "-c",
            "mcp_servers={}",
        ]
        .map(String::from),
    );
    let mut params = CodexBackend::new(config.clone(), argv.to_vec()).thread_start_params();
    params.insert("baseInstructions", SIDECAR_SYSTEM_PROMPT);
    params.insert("developerInstructions", SIDECAR_SYSTEM_PROMPT);
    params.insert("sandbox", "read-only");
    CodexBackend::with_launch(
        config.clone(),
        argv.to_vec(),
        ACTOR_ROLE,
        Some(command),
        Some(params),
    )
}

/// `ClaudeSidecarBackend`: a Claude print session restricted to public web
/// read tools.
pub fn claude_sidecar(config: &Config, argv: &[String]) -> ClaudeBackend {
    let mut command = argv.to_vec();
    command.extend(
        [
            "--print",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model",
            &config.model,
            "--tools",
            "WebSearch,WebFetch",
            "--allowedTools",
            "WebSearch,WebFetch",
            "--permission-mode",
            "dontAsk",
            "--safe-mode",
            "--no-chrome",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config",
            r#"{"mcpServers":{}}"#,
            "--system-prompt",
            SIDECAR_SYSTEM_PROMPT,
        ]
        .map(String::from),
    );
    if config.effort != "default" {
        command.extend(["--effort".to_string(), config.effort.clone()]);
    }
    ClaudeBackend::with_launch(config.clone(), argv.to_vec(), ACTOR_ROLE, Some(command))
}

/// `ProviderSidecarExecutor.__call__` once its backend is built: one ask,
/// then the one-shot backend is shut down.
fn ask_once(backend: &dyn Backend, prompt: &str, timeout: Duration) -> Result<String, Failure> {
    let task_prompt = format!(
        "{SIDECAR_SYSTEM_PROMPT}\n\nIndependent user task:\n{}",
        py_strip(prompt)
    );
    let answer = backend.ask(&task_prompt, timeout, None);
    backend.shutdown();
    answer
        .map(|text| py_strip(&text).to_string())
        .map_err(|_| Failure("MessengerError"))
}

/// `UnavailableSidecarExecutor`: every task fails. As in Python, its reason
/// (provider command not found, or the provider model could not be resolved)
/// never leaves the lane, which reports only the failure.
fn unavailable() -> Execute {
    Box::new(|_, _| Err(Failure("RuntimeError")))
}

/// `resolve_messenger_catalog_selection`: a Codex family resolved to the
/// newest model the CLI lists, and the effort to one that model advertises.
fn resolve_catalog_selection(mut config: Config, argv: &[String]) -> Result<Config, String> {
    if config.provider != "codex" {
        return Ok(config);
    }
    let family =
        catalog::normalize_codex_family(&config.model, catalog::CODEX_MESSENGER_DEFAULT_FAMILY);
    let model = catalog::resolve_family(&family, &catalog::fetch_models(argv, CATALOG_TIMEOUT)?)?;
    config.effort = catalog::resolve_effort(&config.effort, &model)?;
    config.model = model.launch_model().to_string();
    Ok(config)
}

/// `create_sidecar_executor`: the configured foreground provider (the app
/// config's `[general]` table, with the messenger's model and effort) as the
/// restricted sidecar runtime.
pub fn create_sidecar_executor(app_config: &Dict, cwd: &str) -> Execute {
    let general = app_config
        .get("general")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    let mut config = Config::from_general(&general, cwd);
    let Some(argv) = config::resolve_command(&config.provider, &config.command) else {
        return unavailable();
    };
    config.enabled = true;
    config.command = config::shlex_join(&argv);
    let Ok(config) = resolve_catalog_selection(config, &argv) else {
        return unavailable();
    };
    Box::new(move |prompt, timeout| {
        let backend: Box<dyn Backend> = if config.provider == "claude" {
            Box::new(claude_sidecar(&config, &argv))
        } else {
            Box::new(codex_sidecar(&config, &argv))
        };
        ask_once(backend.as_ref(), prompt, timeout)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;
    use crate::messenger::Partial;

    fn command(seq: i64) -> Dict {
        parse(&format!(
            r#"{{"relay_command_seq": {seq}, "relay_command_id": "cmd-{seq}",
                "work_disposition": {{"route": "run_sidecar",
                                      "public_reason": "Independent bounded public research."}}}}"#
        ))
        .unwrap()
        .as_dict()
        .unwrap()
        .clone()
    }

    type Recorded = Arc<Mutex<Vec<(String, String)>>>;

    /// A lane whose lifecycle events and finals are recorded as
    /// (phase or text, command id); `finished` is set after `finals` finals.
    fn lane(
        execute: Execute,
        timeout: f64,
        max_pending: usize,
        finals: usize,
    ) -> (SidecarLane, Recorded, Recorded, Arc<Event>) {
        let lifecycle: Recorded = Arc::default();
        let outcomes: Recorded = Arc::default();
        let finished = Arc::new(Event::default());
        let (events, results, done) = (
            Arc::clone(&lifecycle),
            Arc::clone(&outcomes),
            Arc::clone(&finished),
        );
        let lane = SidecarLane::with_limits(
            execute,
            Box::new(move |event| {
                assert_eq!(event.public_summary, "Independent bounded public research.");
                events.lock().unwrap().push((
                    event.phase.to_string(),
                    event.command.string("relay_command_id"),
                ));
            }),
            Box::new(move |text, command| {
                let mut results = results.lock().unwrap();
                results.push((text.to_string(), command.string("relay_command_id")));
                if results.len() == finals {
                    done.set();
                }
            }),
            timeout,
            max_pending,
        )
        .unwrap();
        (lane, lifecycle, outcomes, finished)
    }

    fn pairs(recorded: &Recorded) -> Vec<(String, String)> {
        recorded.lock().unwrap().clone()
    }

    fn owned(expected: &[(&str, &str)]) -> Vec<(String, String)> {
        expected
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect()
    }

    #[test]
    fn lane_runs_concurrently_and_bounds_pending_work() {
        let started = Arc::new(Event::default());
        let release = Arc::new(Event::default());
        let (on_start, gate) = (Arc::clone(&started), Arc::clone(&release));
        let (lane, lifecycle, finals, finished) = lane(
            Box::new(move |prompt, timeout| {
                assert_eq!(timeout, Duration::from_secs(5));
                on_start.set();
                assert!(gate.wait(2.0));
                Ok(format!("result for {prompt}"))
            }),
            5.0,
            1,
            2,
        );
        assert!(!lane.submit("   ", &command(9)));
        assert!(lane.submit("first", &command(1)));
        assert!(started.wait(1.0));
        assert!(lane.submit(" second ", &command(2)));
        assert!(!lane.submit("third", &command(3)));
        release.set();
        assert!(finished.wait(2.0));
        lane.shutdown();
        assert!(!lane.submit("fourth", &command(4)));

        assert_eq!(
            pairs(&lifecycle),
            owned(&[
                ("started", "cmd-1"),
                ("completed", "cmd-1"),
                ("started", "cmd-2"),
                ("completed", "cmd-2"),
            ])
        );
        assert_eq!(
            pairs(&finals),
            owned(&[
                ("result for first", "cmd-1"),
                ("result for second", "cmd-2")
            ])
        );
    }

    #[test]
    fn lane_reports_provider_failure_as_lifecycle_and_final() {
        let (lane, lifecycle, finals, finished) = lane(
            Box::new(|prompt, _| match prompt {
                "error" => Err(Failure("MessengerError")),
                "empty" => Ok("  \n".to_string()),
                _ => panic!("private provider detail"),
            }),
            DEFAULT_TIMEOUT,
            DEFAULT_MAX_PENDING,
            3,
        );
        assert!(lane.submit("error", &command(1)));
        assert!(lane.submit("empty", &command(2)));
        assert!(lane.submit("panic", &command(3)));
        assert!(finished.wait(2.0));
        lane.shutdown();

        let phases: Vec<String> = pairs(&lifecycle)
            .into_iter()
            .map(|(phase, _)| phase)
            .collect();
        assert_eq!(
            phases,
            [
                "started", "failed", "started", "failed", "started", "failed"
            ]
        );
        assert!(pairs(&finals).iter().all(|(text, _)| text == FAILED_RESULT));
    }

    #[test]
    fn a_callback_panic_does_not_stop_the_lane() {
        let finished = Arc::new(Event::default());
        let done = Arc::clone(&finished);
        let lane = SidecarLane::new(
            Box::new(|prompt, _| Ok(prompt.to_string())),
            Box::new(|event| assert_ne!(event.phase, "started")),
            Box::new(move |text, _| {
                assert_ne!(text, "first");
                done.set();
            }),
        )
        .unwrap();
        assert!(lane.submit("first", &command(1)));
        assert!(lane.submit("second", &command(2)));
        assert!(finished.wait(2.0));
        lane.shutdown();
    }

    fn config(provider: &str, command: &str, model: &str) -> Config {
        Config {
            enabled: true,
            provider: provider.into(),
            command: command.into(),
            model: model.into(),
            effort: "high".into(),
            cwd: "/tmp".into(),
        }
    }

    #[test]
    fn codex_and_claude_backends_enforce_the_same_read_only_boundary() {
        let codex = codex_sidecar(
            &config("codex", "/opt/codex", "gpt-test"),
            &["/opt/codex".into()],
        );
        assert_eq!(codex.actor_role, "sidecar");
        let codex_command = codex.spawn_command();
        assert_eq!(codex_command[..3], ["/opt/codex", "app-server", "--stdio"]);
        for flag in [
            "tools.web_search=true",
            "features.shell_tool=false",
            "features.unified_exec=false",
        ] {
            assert!(codex_command.iter().any(|part| part == flag), "{flag}");
        }
        let params = codex.thread_start_params();
        assert!(params.get("sandbox").unwrap().is_str("read-only"));
        assert_eq!(
            params
                .get("runtimeWorkspaceRoots")
                .unwrap()
                .as_list()
                .map(<[Value]>::len),
            Some(0)
        );
        assert!(
            params
                .get("baseInstructions")
                .unwrap()
                .is_str(SIDECAR_SYSTEM_PROMPT)
        );
        assert!(
            params
                .get("developerInstructions")
                .unwrap()
                .is_str(SIDECAR_SYSTEM_PROMPT)
        );
        assert!(params.get("model").unwrap().is_str("gpt-test"));

        let claude = claude_sidecar(
            &config("claude", "/opt/claude", "sonnet"),
            &["/opt/claude".into()],
        );
        assert_eq!(claude.actor_role, "sidecar");
        // A sidecar never resumes a session.
        let claude_command = claude.spawn_command(Some("abc"));
        assert_eq!(claude_command[0], "/opt/claude");
        for flag in [
            "WebSearch,WebFetch",
            "--safe-mode",
            "--no-chrome",
            "dontAsk",
        ] {
            assert!(claude_command.iter().any(|part| part == flag), "{flag}");
        }
        let allowed = claude_command
            .iter()
            .position(|part| part == "--allowedTools")
            .unwrap();
        assert_eq!(claude_command[allowed + 1], "WebSearch,WebFetch");
        assert!(
            !claude_command
                .iter()
                .any(|part| part == "Bash" || part == "--resume")
        );
        assert_eq!(
            claude_command[claude_command.len() - 2..],
            ["--effort", "high"]
        );
    }

    #[test]
    fn provider_executor_shuts_down_its_one_shot_backend() {
        #[derive(Default)]
        struct Fake {
            calls: Mutex<Vec<String>>,
        }
        impl Backend for Fake {
            fn start(&self) -> Result<(), String> {
                Ok(())
            }
            fn ask(
                &self,
                prompt: &str,
                timeout: Duration,
                _: Option<Partial>,
            ) -> Result<String, String> {
                self.calls
                    .lock()
                    .unwrap()
                    .push(format!("ask {} {prompt}", timeout.as_secs()));
                Ok(" verified result \n".to_string())
            }
            fn interrupt(&self) {}
            fn rebind(&self, _: &str) -> Result<(), String> {
                Ok(())
            }
            fn shutdown(&self) {
                self.calls.lock().unwrap().push("shutdown".to_string());
            }
        }

        let backend = Fake::default();
        let answer = ask_once(&backend, "  compare the APIs ", Duration::from_secs(12));
        assert_eq!(answer.unwrap(), "verified result");
        let calls = backend.calls.lock().unwrap();
        assert_eq!(
            calls[0],
            format!("ask 12 {SIDECAR_SYSTEM_PROMPT}\n\nIndependent user task:\ncompare the APIs")
        );
        assert_eq!(calls.last().unwrap(), "shutdown");
    }

    #[test]
    fn a_missing_provider_command_makes_every_task_fail() {
        let app_config =
            parse(r#"{"general": {"provider": "claude", "command": "/nonexistent/claude"}}"#)
                .unwrap()
                .as_dict()
                .unwrap()
                .clone();
        let execute = create_sidecar_executor(&app_config, "/tmp");
        assert!(matches!(
            execute("research", Duration::from_secs(1)),
            Err(Failure("RuntimeError"))
        ));
    }
}
