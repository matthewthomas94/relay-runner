//! The provider gates every Relay-launched provider process passes: the
//! subscription-only readiness check for Claude Code
//! (`services/claude_subscription.py`), the Codex model catalogue
//! (`services/codex_model_catalog.py`) and the piped child process both
//! drive. First ported for the messenger (RR-490); the voice bridge and the
//! daemon share them from here.

pub mod catalog;
pub mod process;
pub mod subscription;
