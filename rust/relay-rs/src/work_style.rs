//! `relay-rs work-style`: `services/work_style_cli.py`. Show or set the
//! session's Relay work style (auto, direct or orchestrated).
//!
//! Shared by the /work-style skill for Claude and Codex, voice requests such
//! as "switch to direct mode", and anyone at a terminal. `set` writes the same
//! session-work-style.json the Start button's menu uses; the choice covers
//! every project and wins over a project's `.relay-runner.toml`. `show`
//! prints the effective style for a project and where it comes from.

use std::path::Path;
use std::process::{Command, Stdio};

use relay_services::command_actions::{
    WORK_STYLES, current_work_style_and_source, set_session_work_style,
};

use crate::cli::{Opt, Positional, Spec};

const SPEC: Spec = Spec {
    prog: "relay-work-style",
    usage: "relay-work-style [-h] [--repo REPO] [{show,set}] [{auto,direct,orchestrated}]",
    help: "\nShow or set the session's Relay work style (auto, direct or orchestrated).\n\n\
           positional arguments:\n  {show,set}\n  {auto,direct,orchestrated}\n\n\
           options:\n  -h, --help            show this help message and exit\n  \
           --repo REPO           Project to report on (default: the git project of the current directory)",
    options: &[Opt::value("--repo")],
    positionals: &[
        Positional {
            dest: "action",
            choices: &["show", "set"],
        },
        Positional {
            dest: "style",
            choices: &WORK_STYLES,
        },
    ],
    exclusive: &[],
};

fn description(style: &str) -> &'static str {
    match style {
        "direct" => "makes changes now, without tickets",
        "orchestrated" => "turns changes into tickets for workers",
        _ => "decides per request, and asks when unsure",
    }
}

fn source_text(source: &str) -> &'static str {
    match source {
        "env" => "RELAY_WORK_STYLE",
        "session" => "the session's choice",
        "project" => "the project's .relay-runner.toml",
        _ => "the default",
    }
}

/// `_project_root`: the git top level of `path` (default `.`), or the
/// resolved path itself outside a repository.
fn project_root(path: Option<&str>) -> String {
    let start = relay_artifacts::paths::expanduser(path.unwrap_or("."))
        .map(|expanded| relay_artifacts::paths::resolve(&expanded))
        .unwrap_or_else(|_| relay_artifacts::paths::resolve(path.unwrap_or(".")));
    let output = Command::new("git")
        .args(["-C", &start, "rev-parse", "--show-toplevel"])
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output();
    match output {
        Ok(output) if output.status.success() => {
            let top = String::from_utf8_lossy(&output.stdout);
            relay_artifacts::paths::normalize(relay_intents::json::py_strip(&top))
        }
        _ => start,
    }
}

/// `Path(repo).name`.
fn name(repo: &str) -> String {
    Path::new(repo)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn run(arguments: &[String]) -> u8 {
    let parsed = match SPEC.parse(arguments) {
        Ok(parsed) => parsed,
        Err(exit) => return exit.report(),
    };
    let repo = project_root(parsed.value("--repo"));
    if parsed.positional("action") == Some("set") {
        let Some(style) = parsed.positional("style") else {
            return SPEC
                .error(&format!("set needs a style: {}", WORK_STYLES.join(", ")))
                .report();
        };
        if let Err(error) = set_session_work_style(style) {
            eprintln!("relay-work-style: {error}");
            return 1;
        }
    }
    let (style, source) = current_work_style_and_source(Some(&repo));
    println!(
        "{}: {style} ({}), from {}",
        name(&repo),
        description(style),
        source_text(source)
    );
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn parses_action_style_and_repo() {
        let parsed = SPEC
            .parse(&arguments(&["set", "direct", "--repo", "/tmp"]))
            .unwrap();
        assert_eq!(parsed.positional("action"), Some("set"));
        assert_eq!(parsed.positional("style"), Some("direct"));
        assert_eq!(parsed.value("--repo"), Some("/tmp"));
        assert!(SPEC.parse(&arguments(&["bogus"])).is_err());
        assert!(SPEC.parse(&arguments(&["show", "fast"])).is_err());
    }

    #[test]
    fn describes_every_style_and_source() {
        assert_eq!(
            description("auto"),
            "decides per request, and asks when unsure"
        );
        assert_eq!(description("direct"), "makes changes now, without tickets");
        assert_eq!(source_text("project"), "the project's .relay-runner.toml");
        assert_eq!(source_text("default"), "the default");
    }
}
