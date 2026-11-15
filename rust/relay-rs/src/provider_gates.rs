//! The provider gates' command lines (RR-487):
//!
//! - `relay-rs claude-subscription` is `services/claude_subscription.py`'s
//!   `main`: exit 0 when Claude would use the user's Claude.ai subscription,
//!   otherwise `[Relay Runner] <message>` on stderr and exit 77 (sign-in
//!   needed, with `--signal-login-required`) or 78.
//! - `relay-rs codex-model` is `services/codex_model_catalog.py`'s `_main`:
//!   the newest model of a Codex family and the effort it resolves to, as one
//!   compact JSON line, or the error on stderr with exit 2.
//!
//! The libraries are `relay_services::providers::{subscription, catalog}`.

use std::collections::BTreeMap;
use std::time::Duration;

use relay_intents::json::{self, Dict, Value, py_strip};
use relay_services::continuity::providers::shlex_split;
use relay_services::providers::{catalog, subscription};

use crate::cli::{Opt, Spec};

/// `LOGIN_REQUIRED_REASONS`: readiness failures that a fresh
/// `claude auth login` can fix.
const LOGIN_REQUIRED_REASONS: [&str; 4] = [
    "status_unavailable",
    "not_logged_in",
    "unknown_route",
    "no_subscription",
];

const CLAUDE_SPEC: Spec = Spec {
    prog: "relay-rs claude-subscription",
    usage: "relay-rs claude-subscription [-h] [--binary BINARY] [--cwd CWD] [--signal-login-required]",
    help: "\nRelay Runner's subscription-only launch gate for Claude Code.\n\n\
           options:\n  -h, --help            show this help message and exit\n  \
           --binary BINARY\n  --cwd CWD\n  --signal-login-required",
    options: &[
        Opt::value("--binary"),
        Opt::value("--cwd"),
        Opt::flag("--signal-login-required"),
    ],
    positionals: &[],
    exclusive: &[],
};

/// The exit status for a readiness reason that is not ready.
fn not_ready_status(reason: &str, signal_login_required: bool) -> u8 {
    if signal_login_required && LOGIN_REQUIRED_REASONS.contains(&reason) {
        77
    } else {
        78
    }
}

pub fn claude_subscription(arguments: &[String]) -> u8 {
    let parsed = match CLAUDE_SPEC.parse(arguments) {
        Ok(parsed) => parsed,
        Err(exit) => return exit.report(),
    };
    let cwd = match parsed.value("--cwd") {
        Some(cwd) => cwd.to_string(),
        None => std::env::current_dir()
            .map(|cwd| cwd.to_string_lossy().into_owned())
            .unwrap_or_else(|_| ".".to_string()),
    };
    let binary = parsed.value("--binary").unwrap_or("claude").to_string();
    let environment: BTreeMap<_, _> = std::env::vars_os().collect();
    let readiness = subscription::check(&[binary], &cwd, &environment);
    if readiness.ready() {
        return 0;
    }
    eprintln!("[Relay Runner] {}", readiness.message);
    not_ready_status(readiness.reason, parsed.flag("--signal-login-required"))
}

const CODEX_SPEC: Spec = Spec {
    prog: "relay-rs codex-model",
    usage: "relay-rs codex-model [-h] [--command COMMAND] --family FAMILY [--effort EFFORT] [--include-hidden]",
    help: "\noptions:\n  -h, --help         show this help message and exit\n  \
           --command COMMAND\n  --family FAMILY\n  --effort EFFORT\n  --include-hidden",
    options: &[
        Opt::value("--command"),
        Opt::value("--family").required(),
        Opt::value("--effort"),
        Opt::flag("--include-hidden"),
    ],
    positionals: &[],
    exclusive: &[],
};

/// `fetch_codex_models_from_cli`'s timeout.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

/// `_command_prefix(command)`: an existing path is the whole command;
/// anything else is split like a shell line, and nothing means `codex`.
fn command_prefix(command: &str) -> Result<Vec<String>, String> {
    let command = py_strip(command);
    let expanded = relay_artifacts::paths::expanduser(command).unwrap_or_default();
    if !command.is_empty() && std::path::Path::new(&expanded).exists() {
        return Ok(vec![expanded]);
    }
    let words = shlex_split(command).ok_or("No closing quotation")?;
    Ok(if words.is_empty() {
        vec!["codex".to_string()]
    } else {
        words
    })
}

/// The selection as `_main` prints it, keys in its order.
fn selection(family: &str, model: &catalog::CodexModel, effort: String) -> String {
    let mut answer = Dict::new();
    answer.insert(
        "selectedFamily",
        catalog::normalize_codex_family(family, catalog::CODEX_DEFAULT_FAMILY),
    );
    answer.insert("resolvedModel", model.launch_model());
    answer.insert(
        "defaultReasoningEffort",
        model.default_reasoning_effort.as_str(),
    );
    answer.insert(
        "supportedReasoningEfforts",
        Value::List(
            model
                .supported_reasoning_efforts
                .iter()
                .map(|effort| Value::from(effort.as_str()))
                .collect(),
        ),
    );
    answer.insert("resolvedEffort", effort);
    json::dumps_compact(&Value::Dict(answer))
}

pub fn codex_model(arguments: &[String]) -> u8 {
    let parsed = match CODEX_SPEC.parse(arguments) {
        Ok(parsed) => parsed,
        Err(exit) => return exit.report(),
    };
    let family = parsed.value("--family").unwrap_or_default();
    let prefix = match command_prefix(parsed.value("--command").unwrap_or("codex")) {
        Ok(prefix) => prefix,
        Err(message) => {
            eprintln!("ValueError: {message}");
            return 1;
        }
    };
    let resolved = catalog::fetch_models_with_hidden(
        &prefix,
        CATALOG_TIMEOUT,
        parsed.flag("--include-hidden"),
    )
    .and_then(|models| catalog::resolve_family(family, &models))
    .and_then(|model| {
        let effort = catalog::resolve_effort(
            parsed
                .value("--effort")
                .unwrap_or(catalog::PROVIDER_DEFAULT_EFFORT),
            &model,
        )?;
        Ok((model, effort))
    });
    match resolved {
        Ok((model, effort)) => {
            println!("{}", selection(family, &model, effort));
            0
        }
        Err(message) => {
            eprintln!("{message}");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn login_required_reasons_exit_77_only_when_signalled() {
        assert_eq!(not_ready_status("not_logged_in", true), 77);
        assert_eq!(not_ready_status("no_subscription", true), 77);
        assert_eq!(not_ready_status("not_logged_in", false), 78);
        assert_eq!(not_ready_status("metered_environment", true), 78);
    }

    #[test]
    fn codex_model_requires_a_family() {
        assert!(CODEX_SPEC.parse(&arguments(&[])).is_err());
        let parsed = CODEX_SPEC
            .parse(&arguments(&["--family", "sol", "--include-hidden"]))
            .unwrap();
        assert_eq!(parsed.value("--family"), Some("sol"));
        assert!(parsed.flag("--include-hidden"));
        assert!(CLAUDE_SPEC.parse(&arguments(&["--signal"])).is_ok());
    }

    #[test]
    fn command_prefix_splits_and_defaults_to_codex() {
        assert_eq!(
            command_prefix("npx codex").unwrap(),
            arguments(&["npx", "codex"])
        );
        assert_eq!(command_prefix("  ").unwrap(), arguments(&["codex"]));
        assert_eq!(command_prefix("/bin/sh").unwrap(), arguments(&["/bin/sh"]));
        assert!(command_prefix("'open").is_err());
    }

    #[test]
    fn selection_prints_python_key_order() {
        let model = catalog::CodexModel {
            id: "gpt-6-sol".to_string(),
            model: "gpt-6-sol".to_string(),
            hidden: false,
            is_default: true,
            default_reasoning_effort: "medium".to_string(),
            supported_reasoning_efforts: vec!["low".to_string(), "medium".to_string()],
            input_modalities: Vec::new(),
        };
        assert_eq!(
            selection("SOL", &model, "low".to_string()),
            r#"{"selectedFamily":"sol","resolvedModel":"gpt-6-sol","defaultReasoningEffort":"medium","supportedReasoningEfforts":["low","medium"],"resolvedEffort":"low"}"#
        );
    }
}
