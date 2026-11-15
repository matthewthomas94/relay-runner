//! relay-rs, Relay Runner's Rust helper. `hook` is the provider lifecycle hook
//! and `reply` the foreground reply helper (RR-478); docs/specs/hook-contract.md
//! describes both. `bridge` is the voice bridge (RR-492), which runs the
//! messenger backends (RR-490) and the Relay Remote server (RR-491)
//! in-process. The per-invocation tools that were Python scripts
//! are subcommands too (RR-487), with the scripts' arguments, output and exit
//! statuses: `fresh-install` (`relay-runner-fresh-install`), `work-style`
//! (`relay-work-style`), `harness-update`, `claude-subscription`,
//! `codex-model`, and the artifact CLIs `ticket-history`
//! (`relay-ticket-history`), `artifact-rollout`, `artifact-verify` and
//! `artifact-migrate`.

mod bridge;
mod cli;
mod fresh_install;
mod harness_update;
mod hook;
mod messenger;
mod provider_gates;
mod remote;
mod reply;
mod support;
mod work_style;

use std::process::ExitCode;

use relay_intents::{json, sha256};

/// `relay-rs <CFBundleShortVersionString> (<CFBundleVersion>)`, as compiled in
/// by build.rs. `services/app_signing.py` compares it with the packaged bundle.
const VERSION: &str = concat!(
    "relay-rs ",
    env!("RELAY_BUNDLE_SHORT_VERSION"),
    " (",
    env!("RELAY_BUNDLE_VERSION"),
    ")"
);

const USAGE: &str = "usage: relay-rs --version\n       \
     relay-rs hook [--record-process | --record-codex-startup | --context-continuation]\n       \
     relay-rs reply\n       \
     relay-rs bridge --config <path> --relay [--suppress-startup-greeting]\n       \
     relay-rs fresh-install [...]\n       \
     relay-rs work-style [show|set] [STYLE] [--repo REPO]\n       \
     relay-rs harness-update --provider {codex,claude} --command COMMAND\n       \
     relay-rs claude-subscription [--binary BINARY] [--cwd CWD] [--signal-login-required]\n       \
     relay-rs codex-model [--command COMMAND] --family FAMILY [--effort EFFORT] [--include-hidden]\n       \
     relay-rs ticket-history ...\n       \
     relay-rs artifact-rollout ...\n       \
     relay-rs artifact-verify ...\n       \
     relay-rs artifact-migrate ...";

fn run(arguments: &[String]) -> Result<&'static str, &'static str> {
    match arguments {
        [flag] if flag == "--version" => Ok(VERSION),
        _ => Err(USAGE),
    }
}

fn main() -> ExitCode {
    support::start_clock();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.split_first() {
        Some((command, mode)) if command == "hook" => return ExitCode::from(hook::run(mode)),
        Some((command, _)) if command == "reply" => return ExitCode::from(reply::run()),
        Some((command, rest)) if command == "bridge" => return ExitCode::from(bridge::run(rest)),
        Some((command, rest)) if command == "fresh-install" => {
            return ExitCode::from(fresh_install::run(rest));
        }
        Some((command, rest)) if command == "work-style" => {
            return ExitCode::from(work_style::run(rest));
        }
        Some((command, rest)) if command == "harness-update" => {
            return ExitCode::from(harness_update::run_cli(rest));
        }
        Some((command, rest)) if command == "claude-subscription" => {
            return ExitCode::from(provider_gates::claude_subscription(rest));
        }
        Some((command, rest)) if command == "codex-model" => {
            return ExitCode::from(provider_gates::codex_model(rest));
        }
        Some((command, rest)) if command == "ticket-history" => {
            return ExitCode::from(relay_artifacts::history::cli_main(rest));
        }
        Some((command, rest)) if command == "artifact-rollout" => {
            return ExitCode::from(relay_artifacts::rollout::cli_main(rest));
        }
        Some((command, rest)) if command == "artifact-verify" => {
            return ExitCode::from(relay_artifacts::verification::cli_main(rest));
        }
        Some((command, rest)) if command == "artifact-migrate" => {
            // The Program export and Graphify rebuild live in relay-services,
            // which the artifact crate cannot depend on.
            return ExitCode::from(relay_artifacts::migration::cli_main_with_program_migration(
                rest,
                Some(Box::new(
                    relay_services::program::artifacts::migrate_program_and_rebuild,
                )),
            ));
        }
        _ => {}
    }
    match run(&arguments) {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(usage) => {
            eprintln!("{usage}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn is_number(text: &str) -> bool {
        !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit())
    }

    #[test]
    fn version_names_the_bundle_version_and_build() {
        let output = run(&arguments(&["--version"])).unwrap();
        let (short_version, build) = output
            .strip_prefix("relay-rs ")
            .and_then(|rest| rest.strip_suffix(')'))
            .and_then(|rest| rest.split_once(" ("))
            .unwrap();
        assert!(short_version.split('.').all(is_number), "{output}");
        assert!(is_number(build), "{output}");
    }

    #[test]
    fn anything_else_is_a_usage_error() {
        for other in [&[][..], &["version"], &["--version", "extra"], &["--help"]] {
            assert_eq!(run(&arguments(other)), Err(USAGE));
        }
    }
}
