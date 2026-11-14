//! Queue drains and the ready sweeps.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use relay_artifacts::ErrorKind;
use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::retention::{ArtifactRetentionManager, HistoryAccess, RetentionOptions};
use relay_artifacts::tickets::Ticket;

use crate::daemon::{Daemon, resolve_path};
use crate::failure::{Class, Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;
use crate::trace::LifecycleEvent;
use relay_intents::json::Dict;

/// `AUTO_DISPATCH_BACKOFF_SECONDS`.
pub const AUTO_DISPATCH_BACKOFF_SECONDS: f64 = 30.0;
/// `QUEUE_DRAIN_QUIESCENCE_SECONDS`.
pub const QUEUE_DRAIN_QUIESCENCE_SECONDS: f64 = 2.0;
/// `VERIFICATION_BLOCKED_STATUS`.
pub const VERIFICATION_BLOCKED_STATUS: &str = "verification_blocked";

/// `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// Python's `except (ValueError, RuntimeError)`: every failure but an
/// `OSError` and one the handler does not catch.
pub fn is_value_or_runtime(failure: &Failure) -> bool {
    !matches!(failure.class, Class::Io | Class::Escape)
}

/// Why `_all_dependencies_done` raised.
pub enum DependencyFailure {
    /// `DependencyHistoryUnavailable`: an archived predecessor whose
    /// verified history cannot be read.
    History {
        message: String,
        availability: Option<String>,
        recovery: Option<String>,
    },
    Failure(Failure),
}

impl DependencyFailure {
    fn into_failure(self) -> Failure {
        match self {
            Self::History { message, .. } => Failure::validation(message),
            Self::Failure(failure) => failure,
        }
    }
}

impl Daemon {
    pub fn list_queue_drains_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: list_queue_drains_route"))
    }

    pub fn sweep_ready_tickets_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: sweep_ready_tickets_route",
        ))
    }

    pub fn sweep_program_ready_tickets_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: sweep_program_ready_tickets_route",
        ))
    }

    pub fn reconcile_queue_drains_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: reconcile_queue_drains_route",
        ))
    }

    pub fn cancel_queue_drain_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: cancel_queue_drain_route"))
    }
}

/// `QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS`.
pub const QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS: f64 = 5.0;

impl Daemon {
    /// `reconcile_queue_drains(repo_paths=..., trigger=...)`.
    pub fn reconcile_queue_drains(
        &self,
        _repo_paths: Option<Vec<String>>,
        _trigger: Option<&str>,
    ) -> Outcome<Dict> {
        Ok(Dict::new())
    }

    /// `_record_queue_drain_after_event`: record the drain after a run
    /// event; a failure is only logged, since the caller's outcome is durable.
    pub fn record_queue_drain_after_event(
        &self,
        repo_path: Option<&str>,
        trigger: &str,
        drive_reviews: bool,
    ) {
        let Some(repo_path) = repo_path.filter(|path| !path.is_empty()) else {
            return;
        };
        let repo = resolve_path(repo_path);
        if !repo.is_dir() || !repo.join(".git").exists() {
            return;
        }
        if let Err(error) =
            self.record_queue_drain_locked(&repo, Some(trigger), None, drive_reviews)
        {
            eprintln!("[orchestrator] queue-drain record failed after {trigger}: {error}");
        }
    }
}

impl Daemon {
    /// `_all_dependencies_done(repo=, ticket=, all_tickets=,
    /// artifact_lifecycle=)`: every predecessor is `done` on the board, or
    /// archived as done with verified history.
    pub(crate) fn all_dependencies_done(
        &self,
        repo: &Path,
        depends_on: &[String],
        all_tickets: &[Ticket],
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Outcome<bool> {
        self.dependencies_done(repo, depends_on, all_tickets, lifecycle)
            .map_err(DependencyFailure::into_failure)
    }

    /// [`Daemon::all_dependencies_done`], keeping a history failure's detail
    /// for the ready sweep's skip entry.
    pub(crate) fn dependencies_done(
        &self,
        repo: &Path,
        depends_on: &[String],
        all_tickets: &[Ticket],
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Result<bool, DependencyFailure> {
        let mut by_id: HashMap<&str, &Ticket> = HashMap::new();
        for ticket in all_tickets {
            by_id.insert(ticket.id.as_str(), ticket);
        }
        let mut missing = Vec::new();
        for dependency in depends_on {
            match by_id.get(dependency.as_str()) {
                Some(ticket) if ticket.status != "done" => return Ok(false),
                Some(_) => {}
                None => missing.push(dependency),
            }
        }
        if missing.is_empty() {
            return Ok(true);
        }
        let found;
        let lifecycle = match lifecycle {
            Some(lifecycle) => lifecycle,
            None => {
                found = self
                    .artifact_lifecycle(&repo.to_string_lossy())
                    .map_err(DependencyFailure::Failure)?;
                match &found {
                    Some(lifecycle) => lifecycle,
                    None => return Ok(false),
                }
            }
        };
        let manager = ArtifactRetentionManager::new(
            &lifecycle.store,
            RetentionOptions {
                lease_store: Some(lifecycle.leases.clone()),
                enabled: true,
                ..RetentionOptions::default()
            },
        )
        .map_err(|error| DependencyFailure::Failure(error.into()))?;
        for dependency in missing {
            match manager.dependency_satisfied(dependency, None) {
                Ok(true) => {}
                Ok(false) => return Ok(false),
                Err(error) if matches!(error.kind, ErrorKind::DependencyHistoryUnavailable) => {
                    // The Rust error carries only its message; the verified
                    // detail is read again from the archived card.
                    let detail = manager
                        .historical_search(dependency)
                        .ok()
                        .and_then(|cards| {
                            cards.into_iter().find(|card| card.ticket_id == *dependency)
                        })
                        .and_then(|card| {
                            manager
                                .historical_detail(&card.artifact_id, HistoryAccess::default())
                                .ok()
                        });
                    return Err(DependencyFailure::History {
                        message: error.message,
                        availability: detail
                            .as_ref()
                            .map(|detail| detail.availability.value().to_string()),
                        recovery: detail.and_then(|detail| detail.recovery),
                    });
                }
                Err(error) => return Err(DependencyFailure::Failure(error.into())),
            }
        }
        Ok(true)
    }

    /// `_ensure_queue_drain_for_ticket`: a live drain for a ready or
    /// in-progress ticket.
    pub(crate) fn ensure_queue_drain_for_ticket(
        &self,
        repo: &Path,
        ticket: &Ticket,
        provider_key: &str,
        target_branch: &str,
        trigger: &str,
    ) -> Outcome<Option<Dict>> {
        if ticket.canceled || ticket.draft {
            return Ok(None);
        }
        if !["ready", "in_progress"].contains(&ticket.status.as_str()) {
            return Ok(None);
        }
        let repo_text = repo.to_string_lossy();
        let (drain, created) = self.queue_drains.ensure_active(
            &repo_text,
            target_branch,
            provider_key,
            std::slice::from_ref(&ticket.id),
            Some(&format!("Queue drain started by {trigger}.")),
            false,
        )?;
        if created {
            let message = format!(
                "Started queue drain {} for {}.",
                drain.string("id"),
                ticket.id
            );
            self.emit_lifecycle(&LifecycleEvent {
                kind: "reasoning-summary",
                message: Some(&message),
                repo_path: Some(&repo_text),
                provider_key: Some(provider_key),
                ..LifecycleEvent::default()
            });
        }
        Ok(Some(drain))
    }

    /// `_record_queue_drain_locked`.
    pub(crate) fn record_queue_drain_locked(
        &self,
        _repo: &Path,
        _trigger: Option<&str>,
        _sweep_result: Option<&Dict>,
        _drive_reviews: bool,
    ) -> Outcome<Option<Dict>> {
        Ok(None)
    }
}
