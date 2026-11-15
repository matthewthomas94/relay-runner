//! The orchestrator daemon in Rust (RR-497): the HTTP server and every route
//! of `services/orchestrator.py`, backed by the artifact crate (parts 1, 2),
//! the SQLite stores (part 3) and the services (part 6).
//!
//! The contract is docs/specs/orchestrator-http-api.md, checked by the
//! black-box suite in tests/contract/ against this binary as well as the
//! Python daemon. A Rust and a Python daemon can take turns on one data root:
//! every database, file and commit is written in the Python daemon's form.
//!
//! Worker, review and spike execution (part 5, RR-498) starts the Claude and
//! Codex processes: `worker` runs them, `execution` decides what a
//! finished run leads to (review, merge, retry, resume, cancel), and `spike`
//! owns the read-only research snapshot and its report.

pub mod actions;
pub mod activity;
pub mod board;
pub mod daemon;
pub mod dispatch;
pub mod execution;
pub mod failure;
pub mod followups;
pub mod general;
pub mod http;
pub mod notes;
pub mod personal;
pub mod program;
pub mod queue;
pub mod relay_command;
pub mod request;
pub mod router;
pub mod runs;
pub mod serve;
pub mod sessions;
pub mod spike;
pub mod trace;
pub mod worker;
