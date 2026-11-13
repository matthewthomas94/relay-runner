//! relay-rs, Relay Runner's Rust helper. `hook` is the provider lifecycle hook
//! and `reply` the foreground reply helper (RR-478); docs/specs/hook-contract.md
//! describes both. `messenger` serves the voice messenger's provider backends
//! (RR-490) and `remote` is the Relay Remote server (RR-491). Later stages of
//! the Rust port add subcommands or sibling crates.

mod hook;
mod json;
mod messenger;
mod remote;
mod reply;
mod sha256;
mod support;

use std::process::ExitCode;

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
     relay-rs messenger\n       \
     relay-rs remote [--socket <path>]";

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
        Some((command, rest)) if command == "messenger" && rest.is_empty() => {
            return ExitCode::from(messenger::run());
        }
        Some((command, rest)) if command == "remote" => return ExitCode::from(remote::run(rest)),
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
