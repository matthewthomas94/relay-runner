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

// The ported modules land before the main loop that uses all of them.
#![allow(dead_code)]

pub mod authorization;
pub mod command_actions;
pub mod config;
pub mod continuity;
pub mod diagnostics;
pub mod messenger_runtime;
pub mod pm_frontstage;
pub mod ports;
pub mod settings;
pub mod sidecar;
pub mod speech_client;

/// Runs the bridge with its command-line arguments.
pub fn run(_arguments: &[String]) -> u8 {
    eprintln!("relay-rs bridge: not implemented yet");
    2
}
