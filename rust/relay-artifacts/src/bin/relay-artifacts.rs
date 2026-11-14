//! `relay-artifacts`: the Rust counterparts of the artifact CLIs in
//! `services/`, one subcommand each, with the same arguments and the same
//! JSON on stdout:
//!
//! - `relay-artifacts migration ...` is `artifact_migration_cli.py`
//! - `relay-artifacts rollout ...` is `artifact_rollout_cli.py`
//! - `relay-artifacts verification ...` is `artifact_verification_cli.py`
//! - `relay-artifacts history ...` is `artifact_history_cli.py`
//!   (`relay-ticket-history`)
//!
//! Nothing ships it yet; the daemon cut-over (RR-500) decides that.

use std::process::ExitCode;

fn main() -> ExitCode {
    let mut arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.is_empty() {
        eprintln!("usage: relay-artifacts {{migration|rollout|verification|history}} ...");
        return ExitCode::from(2);
    }
    let command = arguments.remove(0);
    let code = match command.as_str() {
        "migration" => relay_artifacts::migration::cli_main(&arguments),
        "rollout" => relay_artifacts::rollout::cli_main(&arguments),
        "verification" => relay_artifacts::verification::cli_main(&arguments),
        "history" => relay_artifacts::history::cli_main(&arguments),
        other => {
            eprintln!("relay-artifacts: unknown command {other:?}");
            2
        }
    };
    ExitCode::from(code)
}
