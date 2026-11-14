//! `relay-orchestrator [--config <path>] [--print-port]`: the orchestrator
//! daemon, the Rust counterpart of `services/orchestrator.py`.

use std::process::ExitCode;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    ExitCode::from(relay_orchestrator::serve::main(&arguments))
}
