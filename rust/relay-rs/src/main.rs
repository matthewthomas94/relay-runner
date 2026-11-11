//! relay-rs, Relay Runner's Rust helper. Stage 0 of the Rust port (RR-475)
//! ships only `--version`; later stages add subcommands or sibling crates.

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

const USAGE: &str = "usage: relay-rs --version";

fn run(arguments: &[String]) -> Result<&'static str, &'static str> {
    match arguments {
        [flag] if flag == "--version" => Ok(VERSION),
        _ => Err(USAGE),
    }
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
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
