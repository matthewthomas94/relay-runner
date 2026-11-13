//! `relay-rs messenger`: the persistent voice messenger's provider backends,
//! the Rust form of the backend half of `services/messenger.py` (RR-490).
//!
//! Both providers move together: the Codex `app-server` JSON-RPC backend and
//! the Claude stream-json backend, with the model and effort resolution, the
//! Claude subscription gate, warm-up, re-binding to the focused session and
//! interruption. The provider-neutral runtime (prompts, realization, speech)
//! stays in Python until the bridge itself is ported; it reaches these
//! backends through `services/rust_messenger.py` over this process's stdio.
//!
//! The protocol is one JSON object per line each way. A request is
//! `{"id": <int>, "op": <op>, ...}`; the reply is `{"id": <int>, "result": {...}}`
//! or `{"id": <int>, "error": "<message>"}`, and an `ask` may first send one
//! `{"id": <int>, "partial": "<first sentence>"}`. The ops:
//!
//! - `configure` with `general` (the app config's `[general]` table) and
//!   `cwd`: resolves the provider command, model and effort and answers the
//!   resolved `enabled`, `provider`, `command`, `model`, `effort`, `cwd` and
//!   `unavailable` (the reason the backend cannot start, or null).
//! - `start`: warm the provider process.
//! - `ask` with `prompt`, `timeout` (seconds) and `partial` (whether to send
//!   the first speakable sentence early): answers `{"text": ...}`.
//! - `rebind` with `partition`: move to a focused session's own context.
//! - `interrupt`, `shutdown`.
//!
//! End of input shuts the backend down and exits.

mod catalog;
mod claude;
mod codex;
mod config;
mod process;
mod subscription;

use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::json::{self, Dict, Value, py_is_space};

pub use config::Config;

pub const MESSENGER_SYSTEM_PROMPT: &str = include_str!("system_prompt.txt");
const SILENT_RESPONSE: &str = "__SILENT__";
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

/// Receives the first speakable sentence of an answer, at most once.
pub type Partial = Box<dyn FnOnce(String) + Send>;

/// `MessengerBackend`, plus the optional `rebind` both providers have.
pub trait Backend: Send + Sync {
    fn start(&self) -> Result<(), String>;
    fn ask(
        &self,
        prompt: &str,
        timeout: Duration,
        on_partial: Option<Partial>,
    ) -> Result<String, String>;
    fn interrupt(&self);
    fn rebind(&self, partition: &str) -> Result<(), String>;
    fn shutdown(&self);
}

/// `UnavailableMessengerBackend`: every start and ask fails with the reason.
struct Unavailable(String);

impl Backend for Unavailable {
    fn start(&self) -> Result<(), String> {
        Err(self.0.clone())
    }
    fn ask(&self, _: &str, _: Duration, _: Option<Partial>) -> Result<String, String> {
        Err(self.0.clone())
    }
    fn interrupt(&self) {}
    fn rebind(&self, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn shutdown(&self) {}
}

/// The backend `create_messenger_runtime` builds for a config, the config as
/// resolved, and why the backend is unavailable, if it is.
pub fn create(mut config: Config) -> (Arc<dyn Backend>, Config, Option<String>) {
    let unavailable =
        |config: Config, reason: &str| -> (Arc<dyn Backend>, Config, Option<String>) {
            (
                Arc::new(Unavailable(reason.to_string())),
                config,
                Some(reason.to_string()),
            )
        };
    let Some(argv) = config::resolve_command(&config.provider, &config.command) else {
        let executable = config::command_prefix(&config.command)
            .map_or_else(|| config.command.clone(), |prefix| prefix[0].clone());
        eprintln!("[messenger] provider command not found: {executable}");
        return unavailable(config, "messenger provider command is unavailable");
    };
    config.command = config::shlex_join(&argv);
    if config.provider == "claude" {
        let backend = claude::ClaudeBackend::new(config.clone(), argv);
        return (Arc::new(backend), config, None);
    }
    let family =
        catalog::normalize_codex_family(&config.model, catalog::CODEX_MESSENGER_DEFAULT_FAMILY);
    let resolved = catalog::fetch_models(&argv, CATALOG_TIMEOUT)
        .and_then(|models| catalog::resolve_family(&family, &models))
        .and_then(|model| {
            Ok((
                model.launch_model().to_string(),
                catalog::resolve_effort(&config.effort, &model)?,
            ))
        });
    match resolved {
        Ok((model, effort)) => {
            config.model = model;
            config.effort = effort;
            let backend = codex::CodexBackend::new(config.clone(), argv);
            (Arc::new(backend), config, None)
        }
        Err(error) => {
            eprintln!("[messenger] could not resolve Codex messenger model: {error}");
            unavailable(config, "messenger model selection is unavailable")
        }
    }
}

// -- the first speakable sentence ---------------------------------------------

fn is_token_char(character: char) -> bool {
    character.is_ascii_alphanumeric()
}

/// `len(re.findall(r"[a-z0-9]+(?:[-_.:/][a-z0-9]+)*", text, re.IGNORECASE))`.
fn count_tokens(text: &str) -> usize {
    let chars: Vec<char> = text.chars().collect();
    let (mut index, mut count) = (0, 0);
    while index < chars.len() {
        if !is_token_char(chars[index]) {
            index += 1;
            continue;
        }
        count += 1;
        loop {
            while index < chars.len() && is_token_char(chars[index]) {
                index += 1;
            }
            let joined = index + 1 < chars.len()
                && "-_.:/".contains(chars[index])
                && is_token_char(chars[index + 1]);
            if !joined {
                break;
            }
            index += 1;
        }
    }
    count
}

/// `_first_semantic_response`: the first sentence of at least three tokens,
/// or with `complete` the whole answer when it has three; never `__SILENT__`.
pub fn first_semantic_response(text: &str, complete: bool) -> Option<String> {
    let cleaned = text
        .split(py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if cleaned.is_empty() || cleaned == SILENT_RESPONSE {
        return None;
    }
    let chars: Vec<(usize, char)> = cleaned.char_indices().collect();
    let at_break = |index: usize| index == chars.len() || chars[index].1 == ' ';
    let byte = |index: usize| {
        chars
            .get(index)
            .map_or(cleaned.len(), |(offset, _)| *offset)
    };
    let mut index = 0;
    while index < chars.len() {
        if matches!(chars[index].1, '.' | '!' | '?') {
            let quoted = index + 1 < chars.len()
                && matches!(chars[index + 1].1, '"' | '\'' | '\u{2019}')
                && at_break(index + 2);
            let end = if quoted {
                Some(index + 2)
            } else if at_break(index + 1) {
                Some(index + 1)
            } else {
                None
            };
            if let Some(end) = end {
                let candidate = &cleaned[..byte(end)];
                if count_tokens(candidate) >= 3 {
                    return Some(candidate.to_string());
                }
                index = end;
                continue;
            }
        }
        index += 1;
    }
    (complete && count_tokens(&cleaned) >= 3).then_some(cleaned)
}

// -- the stdio server ---------------------------------------------------------

type Output = Arc<Mutex<io::Stdout>>;

fn send(output: &Output, message: Dict) {
    let mut stdout = output.lock().unwrap();
    let _ = writeln!(stdout, "{}", json::dumps_compact(&Value::Dict(message)));
    let _ = stdout.flush();
}

fn reply(output: &Output, id: &Value, outcome: Result<Dict, String>) {
    let mut message = Dict::new();
    message.insert("id", id.clone());
    match outcome {
        Ok(result) => message.insert("result", result),
        Err(error) => message.insert("error", error),
    }
    send(output, message);
}

fn configure(request: &Dict) -> (Arc<dyn Backend>, Dict) {
    let general = request
        .get("general")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    let requested = Config::from_general(&general, &request.string("cwd"));
    let (backend, config, unavailable) = if requested.enabled {
        create(requested)
    } else {
        let reason = "messenger is disabled".to_string();
        let backend: Arc<dyn Backend> = Arc::new(Unavailable(reason.clone()));
        (backend, requested, Some(reason))
    };
    let mut result = Dict::new();
    result.insert("enabled", config.enabled);
    result.insert("provider", config.provider);
    result.insert("command", config.command);
    result.insert("model", config.model);
    result.insert("effort", config.effort);
    result.insert("cwd", config.cwd);
    result.insert("unavailable", unavailable);
    (backend, result)
}

/// `relay-rs messenger`. Always exits 0 once its input ends.
pub fn run() -> u8 {
    let output: Output = Arc::new(Mutex::new(io::stdout()));
    let mut backend: Arc<dyn Backend> = Arc::new(Unavailable("messenger is not configured".into()));
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Some(Value::Dict(request)) = json::parse(&line) else {
            continue;
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let op = request.string("op");
        match op.as_str() {
            "configure" => {
                backend.shutdown();
                let (configured, result) = configure(&request);
                backend = configured;
                reply(&output, &id, Ok(result));
            }
            "interrupt" => {
                backend.interrupt();
                reply(&output, &id, Ok(Dict::new()));
            }
            "shutdown" => {
                backend.shutdown();
                reply(&output, &id, Ok(Dict::new()));
            }
            "start" | "rebind" | "ask" => {
                let backend = Arc::clone(&backend);
                let output = Arc::clone(&output);
                thread::spawn(move || {
                    let outcome = match op.as_str() {
                        "start" => backend.start().map(|()| Dict::new()),
                        "rebind" => backend
                            .rebind(&request.string("partition"))
                            .map(|()| Dict::new()),
                        _ => ask(&*backend, &request, &id, &output),
                    };
                    reply(&output, &id, outcome);
                });
            }
            _ => reply(&output, &id, Err(format!("unknown op {op:?}"))),
        }
    }
    backend.shutdown();
    0
}

fn ask(backend: &dyn Backend, request: &Dict, id: &Value, output: &Output) -> Result<Dict, String> {
    let timeout = request
        .get("timeout")
        .and_then(Value::py_float)
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .unwrap_or(60.0);
    let on_partial: Option<Partial> = request.truthy("partial").map(|_| {
        let (id, output) = (id.clone(), Arc::clone(output));
        Box::new(move |text: String| {
            let mut message = Dict::new();
            message.insert("id", id);
            message.insert("partial", text);
            send(&output, message);
        }) as Partial
    });
    let text = backend.ask(
        &request.string("prompt"),
        Duration::from_secs_f64(timeout),
        on_partial,
    )?;
    let mut result = Dict::new();
    result.insert("text", text);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_system_prompt_is_the_python_messengers_word_for_word() {
        let source = include_str!("../../../../services/messenger.py");
        let start = source.find("MESSENGER_SYSTEM_PROMPT = \"\"\"").unwrap() + 29;
        let end = start + source[start..].find("\"\"\"").unwrap();
        assert_eq!(&source[start..end], MESSENGER_SYSTEM_PROMPT);
    }

    #[test]
    fn the_first_sentence_needs_three_tokens() {
        assert_eq!(
            first_semantic_response("  Checking   the\nupload test. More", false).as_deref(),
            Some("Checking the upload test.")
        );
        assert_eq!(
            first_semantic_response("OK. Sure! Looking into it now. Then", false).as_deref(),
            Some("OK. Sure! Looking into it now.")
        );
        assert_eq!(
            first_semantic_response("He said \"stop it now.\" Then", false).as_deref(),
            Some("He said \"stop it now.\"")
        );
        assert_eq!(first_semantic_response("Version 1.2.3 is out", false), None);
        assert_eq!(
            first_semantic_response("Version 1.2.3 is out", true).as_deref(),
            Some("Version 1.2.3 is out")
        );
        assert_eq!(first_semantic_response("rr-490/main.rs ok", true), None);
        assert_eq!(first_semantic_response(" __SILENT__ ", true), None);
        assert_eq!(first_semantic_response("", true), None);
    }

    #[test]
    fn tokens_join_across_single_separators() {
        assert_eq!(count_tokens("a-b c. d_e:f/g h--i"), 5);
        assert_eq!(count_tokens("état ü"), 1);
    }

    #[test]
    fn a_missing_command_is_unavailable() {
        let general =
            json::parse(r#"{"provider": "claude", "command": "/nonexistent/claude"}"#).unwrap();
        let config = Config::from_general(general.as_dict().unwrap(), "/");
        let (backend, config, reason) = create(config);
        assert_eq!(
            reason.as_deref(),
            Some("messenger provider command is unavailable")
        );
        assert_eq!(config.command, "/nonexistent/claude");
        assert_eq!(
            backend.start(),
            Err("messenger provider command is unavailable".to_string())
        );
    }
}
