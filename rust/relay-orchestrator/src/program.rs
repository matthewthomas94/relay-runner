//! Program status, dashboard and capture: `program_status`,
//! `program_dashboard`, `session_capture` and `_ingest_program_graph`.
//!
//! `_ingest_program_graph` re-ingests only when a board, ref, run or
//! registry input moved, or another writer touched the graph (RR-440,
//! RR-471). The Python daemon keeps that state, and the dashboard's graph
//! context, on itself; here both are kept per graph file, so a second daemon
//! in the same process (the unit tests) never reads another's.

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

use relay_intents::json::{Dict, Value, py_strip};
use relay_services::program::capture::{ArtifactAuthority, CaptureRequest, capture_session_review};
use relay_services::program::ingest::{
    IngestOptions, InputState, StatKey, graph_file_state, ingest_registered_projects,
    registered_projects_input_state, unchanged_project_inputs,
};
use relay_services::program::with_graph;
use relay_services::program_status::{
    ProgramContext, STALE_AFTER_SECONDS, build_program_dashboard, build_program_status,
    program_context,
};
use relay_store::graphify::GraphifyStore;

use crate::daemon::{Daemon, guard};
use crate::failure::Outcome;
use crate::request::Request;
use crate::router::{Reply, reply};

/// `_program_ingest_state`: the inputs, the graph files and the counts of
/// the last ingest.
struct IngestState {
    inputs: InputState,
    graph: Vec<StatKey>,
    counts: Dict,
}

/// Per graph file. Holding the lock for the whole ingest is
/// `_program_ingest_lock`: one ingest at a time, so a slower one cannot
/// record newer inputs than it read.
static INGEST_STATE: LazyLock<Mutex<HashMap<PathBuf, IngestState>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

type ContextKey = (Vec<StatKey>, Option<Vec<String>>);

/// `_program_dashboard_context`, per graph file.
static DASHBOARD_CONTEXT: LazyLock<Mutex<HashMap<PathBuf, (ContextKey, ProgramContext)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

impl Daemon {
    pub fn program_status_route(&self, request: &Request) -> Outcome<Reply> {
        let query = request.query_or("query", "summary");
        let provider = request.query_first("provider");
        let limit = request.query_int("limit", 8)?;
        reply(
            200,
            self.program_status(&query, provider.as_deref(), limit)?,
        )
    }

    pub fn program_dashboard_route(&self, request: &Request) -> Outcome<Reply> {
        let provider = request.query_first("provider");
        let limit = request.query_int("limit", 0)?;
        let trigger = request.query_or("trigger", "program-board-refresh");
        let repo_paths = request.query_all("repo_path");
        let sweep = py_strip(&request.query_or("sweep", "1")).to_lowercase();
        let sweep_ready = !["0", "false", "no"].contains(&sweep.as_str());
        reply(
            200,
            self.program_dashboard(
                provider.as_deref(),
                limit,
                &trigger,
                repo_paths.as_deref(),
                sweep_ready,
            )?,
        )
    }

    pub fn session_capture_route(&self, request: &Request) -> Outcome<Reply> {
        let store = GraphifyStore::open(&self.graphify_path)?;
        let counts = ingest_registered_projects(
            &store,
            &IngestOptions {
                registry_path: self.paths.registered_projects().to_path_buf(),
                runs_db_path: Some(self.runs_db_path()),
                index_files: false,
                ..IngestOptions::default()
            },
        )?;
        let repo_path = request.get("repo_path").filter(|value| value.truthy());
        let lifecycle = match repo_path {
            Some(repo_path) => self.artifact_lifecycle(&repo_path.py_str())?,
            None => None,
        };
        if let Some(lifecycle) = &lifecycle {
            let token = request.optional_text("project_scope_token");
            lifecycle.validate_scope(token.as_deref(), None)?;
        }
        let field = |key: &str| request.get(key).cloned();
        let capture = CaptureRequest {
            repo_path: field("repo_path"),
            entries: field("entries"),
            ticket_id: field("ticket_id"),
            run_id: field("run_id"),
            provider: field("provider"),
            context: field("context"),
            capture_id: field("capture_id"),
            source: request
                .get("source")
                .filter(|value| value.truthy())
                .map_or_else(|| "session_capture".to_string(), Value::py_str),
            occurred_at: None,
        };
        let authority = lifecycle.as_ref().map(|lifecycle| ArtifactAuthority {
            store: &lifecycle.store,
            device_id: Some(self.device_id.as_str()),
        });
        let mut result = with_graph(&store, |graph| {
            capture_session_review(graph, &capture, authority.as_ref())
        })?;
        result.insert("ingest_counts", counts);
        reply(201, result)
    }
}

impl Daemon {
    fn runs_db_path(&self) -> PathBuf {
        self.paths.data_root.join("runs.db")
    }

    /// `_ingest_program_graph()`: the ingest counts.
    fn ingest_program_graph(&self) -> Outcome<Dict> {
        let registry_path = self.paths.registered_projects().to_path_buf();
        let runs_db_path = self.runs_db_path();
        let mut states = guard(&INGEST_STATE);
        let inputs = registered_projects_input_state(&registry_path, Some(&runs_db_path))?;
        let previous = states.get(&self.graphify_path);
        let graph_unchanged = inputs.is_some()
            && previous.is_some_and(|state| state.graph == graph_file_state(&self.graphify_path));
        if graph_unchanged
            && let (Some(previous), Some(inputs)) = (previous, &inputs)
            && previous.inputs == *inputs
        {
            return Ok(previous.counts.clone());
        }
        let unchanged = if graph_unchanged {
            unchanged_project_inputs(previous.map(|state| &state.inputs), inputs.as_ref())
        } else {
            None
        };
        let (unchanged_repo_paths, runs_unchanged) =
            unchanged.unwrap_or_else(|| (BTreeSet::new(), false));
        let store = GraphifyStore::open(&self.graphify_path)?;
        let counts = ingest_registered_projects(
            &store,
            &IngestOptions {
                registry_path,
                runs_db_path: Some(runs_db_path),
                index_files: false,
                unchanged_repo_paths,
                runs_unchanged,
            },
        )?;
        match inputs {
            Some(inputs) => {
                states.insert(
                    self.graphify_path.clone(),
                    IngestState {
                        inputs,
                        graph: graph_file_state(&self.graphify_path),
                        counts: counts.clone(),
                    },
                );
            }
            None => {
                states.remove(&self.graphify_path);
            }
        }
        Ok(counts)
    }

    /// `program_status(query=, provider=, limit=)`.
    fn program_status(&self, query: &str, provider: Option<&str>, limit: i64) -> Outcome<Dict> {
        let store = GraphifyStore::open(&self.graphify_path)?;
        let registry_path = self.paths.registered_projects();
        let counts = self
            .program_status_flight
            .run(|| self.ingest_program_graph())?;
        if counts.get("projects").and_then(Value::py_int) == Some(0) {
            let mut result = Dict::new();
            result.insert("query", if query.is_empty() { "summary" } else { query });
            result.insert("provider", provider);
            result.insert(
                "message",
                format!(
                    "No registered projects found at {}. Activate a project by path or start a \
                     Relay bridge in a git repo, then ask again.",
                    registry_path.display()
                ),
            );
            result.insert("items", Value::List(Vec::new()));
            let mut empty = Dict::new();
            empty.insert("projects", 0);
            empty.insert("items", 0);
            result.insert("counts", empty);
            return Ok(result);
        }
        Ok(build_program_status(
            &store,
            Some(query),
            provider,
            limit,
            None,
            STALE_AFTER_SECONDS,
        )?)
    }

    /// `program_dashboard(provider=, limit=, trigger=, repo_paths=,
    /// sweep_ready=)`.
    fn program_dashboard(
        &self,
        provider: Option<&str>,
        limit: i64,
        trigger: &str,
        repo_paths: Option<&[String]>,
        sweep_ready: bool,
    ) -> Outcome<Dict> {
        if sweep_ready {
            self.program_dashboard_flight.run(|| {
                self.sweep_for_dashboard(trigger, repo_paths)?;
                self.ingest_program_graph()
            })?;
        } else {
            // RR-471: the queue-drain monitor already sweeps every project,
            // so a refresh after a board write only re-reads the graph.
            self.ingest_program_graph()?;
        }
        let store = GraphifyStore::open(&self.graphify_path)?;
        let key: ContextKey = (
            graph_file_state(&self.graphify_path),
            repo_paths.map(<[String]>::to_vec),
        );
        let context = {
            let mut contexts = guard(&DASHBOARD_CONTEXT);
            match contexts.get(&self.graphify_path) {
                Some((cached_key, context)) if *cached_key == key => context.clone(),
                _ => {
                    let context = program_context(&store, repo_paths)?;
                    contexts.insert(self.graphify_path.clone(), (key, context.clone()));
                    context
                }
            }
        };
        Ok(build_program_dashboard(
            &store,
            provider,
            repo_paths,
            limit,
            None,
            STALE_AFTER_SECONDS,
            Some(&context),
        )?)
    }

    /// `sweep_program_ready_tickets(trigger=, repo_paths=)`, the ready sweep
    /// the queue module owns, reached through `POST /v1/program/ready-sweep`.
    /// The repository filter rides in the body for that module to read; the
    /// Python route itself takes only `trigger`.
    fn sweep_for_dashboard(&self, trigger: &str, repo_paths: Option<&[String]>) -> Outcome<()> {
        self.sweep_program_ready_tickets(Some(trigger), repo_paths)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_keys_compare_the_graph_state_and_filter() {
        let path = std::path::Path::new("/nonexistent/graphify.db");
        let a: ContextKey = (graph_file_state(path), None);
        let b: ContextKey = (graph_file_state(path), Some(vec!["/repo".to_string()]));
        assert_eq!(a, (graph_file_state(path), None));
        assert_ne!(a, b);
    }
}
