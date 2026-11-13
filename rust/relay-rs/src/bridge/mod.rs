//! `relay-rs bridge`: the voice bridge (RR-492), the Rust form of
//! `services/voice_bridge.py` with `pm_frontstage.py`, `command_actions.py`,
//! `relay_authorization.py`, `speech_client.py`, the provider-neutral half of
//! `messenger.py`, `sidecar_lane.py`, `support_diagnostics.py`, the bridge's
//! use of the continuity modules and `config.py`'s loader.
//!
//! It is launched as `relay-rs bridge --config <path> --relay
//! [--suppress-startup-greeting]` and is accepted by the black-box suite in
//! `tests/contract/test_bridge_contract_*.py`
//! (docs/specs/voice-bridge-contract.md). The Python bridge stays the
//! default until the cut-over (RR-493).

mod authorization;
mod command_actions;
mod commands;
mod config;
mod context;
mod continuity;
mod control_socket;
mod controls;
mod diagnostics;
mod finals;
mod messenger_runtime;
mod orchestrator;
mod pm_frontstage;
mod ports;
mod recovery;
mod relay;
mod remote_link;
mod replies;
mod settings;
mod sidecar;
mod speech;
mod speech_client;
mod store;
mod targets;
mod traces;
mod turns;
mod wiring;

/// Runs the bridge with its command-line arguments.
pub fn run(arguments: &[String]) -> u8 {
    wiring::run(arguments)
}
