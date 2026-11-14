//! `graphify.db`: `GraphifyCoreStore` in `services/graphify_core.py`, the
//! program graph (projects, tickets, runs, providers and their edges) and the
//! lexical file index beside it. The ingest that fills it is a later part of
//! the port.
//!
//! Python opens a connection per call and keeps a thread-local one inside
//! `transaction()`. Here one connection serves the store: [`GraphifyStore::with`]
//! runs operations in autocommit, [`GraphifyStore::transaction`] runs them in
//! one `BEGIN … COMMIT`, and both hand the operations a [`Graph`].

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::Connection;
use rusqlite::types::Value as Sql;

use relay_intents::json;

use crate::sql::{self, int, opt_int, opt_text, real, text};
use crate::{Dict, Error, Result, Value};

pub const NODE_PROJECT: &str = "Project";
pub const NODE_INITIATIVE: &str = "Initiative";
pub const NODE_TICKET: &str = "Ticket";
pub const NODE_RUN: &str = "Run";
pub const NODE_AGENT_PROVIDER: &str = "AgentProvider";
pub const NODE_RISK: &str = "Risk";
pub const NODE_DECISION: &str = "Decision";
pub const NODE_PROGRAM_EVENT: &str = "ProgramEvent";
pub const NODE_IDEA: &str = "Idea";
pub const NODE_STATUS: &str = "Status";
pub const NODE_FILE: &str = "File";

pub const EDGE_BELONGS_TO: &str = "belongs_to";
pub const EDGE_CONTAINS: &str = "contains";
pub const EDGE_DEPENDS_ON: &str = "depends_on";
pub const EDGE_BLOCKS: &str = "blocks";
pub const EDGE_EXECUTES: &str = "executes";
pub const EDGE_AWAITS_MERGE: &str = "awaits_merge";
pub const EDGE_RELATED_TO: &str = "related_to";
pub const EDGE_USES_PROVIDER: &str = "uses_provider";
pub const EDGE_MENTIONS_FILE: &str = "mentions_file";

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS graph_nodes (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        project_id TEXT,
        stable_key TEXT NOT NULL,
        title TEXT,
        body_json TEXT NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(kind, stable_key)
    );
    CREATE INDEX IF NOT EXISTS idx_graph_nodes_kind_project
        ON graph_nodes(kind, project_id);
    CREATE INDEX IF NOT EXISTS idx_graph_nodes_project
        ON graph_nodes(project_id);

    CREATE TABLE IF NOT EXISTS graph_edges (
        src_id TEXT NOT NULL,
        dst_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        body_json TEXT NOT NULL DEFAULT '{}',
        updated_at REAL NOT NULL,
        PRIMARY KEY(src_id, dst_id, kind),
        FOREIGN KEY(src_id) REFERENCES graph_nodes(id) ON DELETE CASCADE,
        FOREIGN KEY(dst_id) REFERENCES graph_nodes(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_graph_edges_kind_src
        ON graph_edges(kind, src_id);
    CREATE INDEX IF NOT EXISTS idx_graph_edges_kind_dst
        ON graph_edges(kind, dst_id);

    CREATE TABLE IF NOT EXISTS file_manifest (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        rel_path TEXT NOT NULL,
        language TEXT,
        size_bytes INTEGER NOT NULL,
        mtime_ns INTEGER,
        content_hash TEXT,
        indexed_at REAL NOT NULL,
        deleted_at REAL,
        UNIQUE(project_id, rel_path)
    );
    CREATE INDEX IF NOT EXISTS idx_file_manifest_project_path
        ON file_manifest(project_id, rel_path);

    CREATE TABLE IF NOT EXISTS file_chunks (
        id INTEGER PRIMARY KEY,
        file_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        rel_path TEXT NOT NULL,
        chunk_ordinal INTEGER NOT NULL,
        start_line INTEGER,
        end_line INTEGER,
        text TEXT NOT NULL,
        FOREIGN KEY(file_id) REFERENCES file_manifest(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_file_chunks_project_file
        ON file_chunks(project_id, file_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS file_chunks_fts USING fts5(
        text,
        rel_path UNINDEXED,
        project_id UNINDEXED,
        content='file_chunks',
        content_rowid='id'
    );

    CREATE TRIGGER IF NOT EXISTS file_chunks_ai AFTER INSERT ON file_chunks BEGIN
        INSERT INTO file_chunks_fts(rowid, text, rel_path, project_id)
        VALUES (new.id, new.text, new.rel_path, new.project_id);
    END;
    CREATE TRIGGER IF NOT EXISTS file_chunks_ad AFTER DELETE ON file_chunks BEGIN
        INSERT INTO file_chunks_fts(file_chunks_fts, rowid, text, rel_path, project_id)
        VALUES ('delete', old.id, old.text, old.rel_path, old.project_id);
    END;
    ";

/// One lexical chunk of an indexed file.
#[derive(Clone, Debug, Default)]
pub struct FileChunk {
    /// `None` is the chunk's position.
    pub chunk_ordinal: Option<i64>,
    pub start_line: Option<i64>,
    pub end_line: Option<i64>,
    pub text: String,
}

/// The file `upsert_file_index` records.
#[derive(Clone, Debug, Default)]
pub struct FileIndex {
    pub project_id: String,
    pub rel_path: String,
    pub language: Option<String>,
    pub size_bytes: i64,
    pub mtime_ns: Option<i64>,
    pub content_hash: Option<String>,
    pub chunks: Vec<FileChunk>,
}

pub struct GraphifyStore {
    path: PathBuf,
    connection: Mutex<Connection>,
}

impl GraphifyStore {
    /// Opens `path` (or `:memory:`) and creates the schema in place.
    pub fn open(path: &Path) -> Result<Self> {
        let memory = path.as_os_str() == ":memory:";
        let connection = if memory {
            Connection::open_in_memory()?
        } else {
            sql::make_parent(path)?;
            Connection::open(path)?
        };
        connection.busy_timeout(sql::DEFAULT_TIMEOUT)?;
        connection.pragma_update(None, "foreign_keys", true)?;
        if !memory {
            connection.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
        }
        connection.execute_batch(SCHEMA)?;
        Ok(Self {
            path: path.to_path_buf(),
            connection: Mutex::new(connection),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Runs `work` with each statement committed as it runs.
    pub fn with<T>(&self, work: impl FnOnce(&Graph<'_>) -> Result<T>) -> Result<T> {
        let connection = self.lock();
        let graph = Graph {
            connection: &connection,
            in_transaction: false,
        };
        let result = work(&graph);
        if !connection.is_autocommit() {
            let _ = connection.execute_batch("ROLLBACK");
        }
        result
    }

    /// Runs `work` as one atomic commit; an error rolls everything back.
    pub fn transaction<T>(&self, work: impl FnOnce(&Graph<'_>) -> Result<T>) -> Result<T> {
        let connection = self.lock();
        let graph = Graph {
            connection: &connection,
            in_transaction: true,
        };
        sql::transaction(&connection, "BEGIN", || work(&graph))
    }

    /// A consistent copy at `destination` through SQLite's online backup,
    /// written to a temporary file, made owner-only and renamed into place.
    pub fn backup(&self, destination: &Path) -> Result<PathBuf> {
        sql::make_parent(destination)?;
        let name = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        let temporary = destination.with_file_name(format!(".{name}.{nanos}.tmp"));
        {
            let connection = self.lock();
            let mut target = Connection::open(&temporary)?;
            let backup = rusqlite::backup::Backup::new(&connection, &mut target)?;
            // Every page in one step, as Python's `pages=-1`; rusqlite
            // panics on a count that is not positive.
            backup.run_to_completion(i32::MAX, Duration::ZERO, None)?;
        }
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temporary, destination)?;
        Ok(destination.to_path_buf())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// The graph operations, on the store's connection.
pub struct Graph<'a> {
    connection: &'a Connection,
    in_transaction: bool,
}

impl Graph<'_> {
    /// Inserts or updates the node `(kind, stable_key)`; an unchanged node is
    /// not rewritten (RR-471).
    pub fn upsert_node(
        &self,
        kind: &str,
        stable_key: &str,
        project_id: Option<&str>,
        title: Option<&str>,
        body: Option<&Dict>,
        node_id: Option<&str>,
    ) -> Result<Dict> {
        let kind = require_text(Some(kind), "kind")?;
        let stable_key = require_text(Some(stable_key), "stable_key")?;
        let node_id = match node_id {
            Some(node_id) => require_text(Some(node_id), "node_id")?,
            None => default_node_id(&kind, &stable_key),
        };
        let now = sql::now();
        let body_json = encode_body(body);
        let c = self.connection;
        let select = "SELECT * FROM graph_nodes WHERE kind = ? AND stable_key = ?";
        let key = [text(&kind), text(&stable_key)];
        if let Some(row) = sql::row(c, select, &key)?
            && optional_text(&row, "project_id") == project_id
            && optional_text(&row, "title") == title
            && sql::field_str(&row, "body_json") == body_json
        {
            return node_from_row(&row, "");
        }
        sql::execute(
            c,
            "
                INSERT INTO graph_nodes(id, kind, project_id, stable_key, title, body_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, stable_key) DO UPDATE SET
                    project_id = excluded.project_id,
                    title = excluded.title,
                    body_json = excluded.body_json,
                    updated_at = excluded.updated_at
                ",
            &[
                text(node_id),
                text(&kind),
                opt_text(project_id),
                text(&stable_key),
                opt_text(title),
                text(body_json),
                real(now),
            ],
        )?;
        let row = sql::row(c, select, &key)?.unwrap_or_default();
        node_from_row(&row, "")
    }

    pub fn get_node(&self, node_id: &str) -> Result<Option<Dict>> {
        sql::row(
            self.connection,
            "SELECT * FROM graph_nodes WHERE id = ?",
            &[text(node_id)],
        )?
        .map(|row| node_from_row(&row, ""))
        .transpose()
    }

    pub fn find_node(&self, kind: &str, stable_key: &str) -> Result<Option<Dict>> {
        sql::row(
            self.connection,
            "SELECT * FROM graph_nodes WHERE kind = ? AND stable_key = ?",
            &[text(kind), text(stable_key)],
        )?
        .map(|row| node_from_row(&row, ""))
        .transpose()
    }

    pub fn delete_node(&self, node_id: &str) -> Result<bool> {
        let node_id = require_text(Some(node_id), "node_id")?;
        let deleted = sql::execute(
            self.connection,
            "DELETE FROM graph_nodes WHERE id = ?",
            &[text(node_id)],
        )?;
        Ok(deleted > 0)
    }

    pub fn nodes(&self, kind: Option<&str>, project_id: Option<&str>) -> Result<Vec<Dict>> {
        let mut clauses = Vec::new();
        let mut values = Vec::new();
        if let Some(kind) = kind {
            clauses.push("kind = ?");
            values.push(text(kind));
        }
        if let Some(project_id) = project_id {
            clauses.push("project_id = ?");
            values.push(text(project_id));
        }
        let filter = where_clause(&clauses);
        sql::rows(
            self.connection,
            &format!("SELECT * FROM graph_nodes{filter} ORDER BY kind, stable_key"),
            &values,
        )?
        .iter()
        .map(|row| node_from_row(row, ""))
        .collect()
    }

    /// Inserts or updates the edge; an unchanged edge is not rewritten.
    pub fn upsert_edge(
        &self,
        src_id: &str,
        dst_id: &str,
        kind: &str,
        body: Option<&Dict>,
    ) -> Result<Dict> {
        let src_id = require_text(Some(src_id), "src_id")?;
        let dst_id = require_text(Some(dst_id), "dst_id")?;
        let kind = require_text(Some(kind), "kind")?;
        let now = sql::now();
        let body_json = encode_body(body);
        let c = self.connection;
        let select = "SELECT * FROM graph_edges WHERE src_id = ? AND dst_id = ? AND kind = ?";
        let key = [text(&src_id), text(&dst_id), text(&kind)];
        if let Some(row) = sql::row(c, select, &key)?
            && sql::field_str(&row, "body_json") == body_json
        {
            return edge_from_row(&row, "");
        }
        sql::execute(
            c,
            "
                INSERT INTO graph_edges(src_id, dst_id, kind, body_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(src_id, dst_id, kind) DO UPDATE SET
                    body_json = excluded.body_json,
                    updated_at = excluded.updated_at
                ",
            &[
                text(&src_id),
                text(&dst_id),
                text(&kind),
                text(body_json),
                real(now),
            ],
        )?;
        let row = sql::row(c, select, &key)?.unwrap_or_default();
        edge_from_row(&row, "")
    }

    pub fn get_edge(&self, src_id: &str, dst_id: &str, kind: &str) -> Result<Option<Dict>> {
        sql::row(
            self.connection,
            "SELECT * FROM graph_edges WHERE src_id = ? AND dst_id = ? AND kind = ?",
            &[text(src_id), text(dst_id), text(kind)],
        )?
        .map(|row| edge_from_row(&row, ""))
        .transpose()
    }

    pub fn edges(
        &self,
        kind: Option<&str>,
        src_id: Option<&str>,
        dst_id: Option<&str>,
    ) -> Result<Vec<Dict>> {
        let mut clauses = Vec::new();
        let mut values = Vec::new();
        for (column, value) in [
            ("kind = ?", kind),
            ("src_id = ?", src_id),
            ("dst_id = ?", dst_id),
        ] {
            if let Some(value) = value {
                clauses.push(column);
                values.push(text(value));
            }
        }
        let filter = where_clause(&clauses);
        sql::rows(
            self.connection,
            &format!("SELECT * FROM graph_edges{filter} ORDER BY kind, src_id, dst_id"),
            &values,
        )?
        .iter()
        .map(|row| edge_from_row(row, ""))
        .collect()
    }

    /// The node's neighbours: `out`, `in` or `both`, each entry
    /// `{direction, edge, node}`.
    pub fn neighbors(
        &self,
        node_id: &str,
        edge_kind: Option<&str>,
        direction: &str,
    ) -> Result<Vec<Dict>> {
        let node_id = require_text(Some(node_id), "node_id")?;
        if !["out", "in", "both"].contains(&direction) {
            return Err(Error::invalid("direction must be 'out', 'in', or 'both'"));
        }
        let mut results = Vec::new();
        if direction == "out" || direction == "both" {
            results.extend(self.neighbors_for(&node_id, edge_kind, true)?);
        }
        if direction == "in" || direction == "both" {
            results.extend(self.neighbors_for(&node_id, edge_kind, false)?);
        }
        Ok(results)
    }

    fn neighbors_for(
        &self,
        node_id: &str,
        edge_kind: Option<&str>,
        outward: bool,
    ) -> Result<Vec<Dict>> {
        let (edge_side, neighbor_side) = if outward {
            ("src_id", "dst_id")
        } else {
            ("dst_id", "src_id")
        };
        let mut clauses = vec![format!("e.{edge_side} = ?")];
        let mut values = vec![text(node_id)];
        if let Some(kind) = edge_kind {
            clauses.push("e.kind = ?".to_string());
            values.push(text(kind));
        }
        let statement = format!(
            "
            SELECT
                n.id AS n_id,
                n.kind AS n_kind,
                n.project_id AS n_project_id,
                n.stable_key AS n_stable_key,
                n.title AS n_title,
                n.body_json AS n_body_json,
                n.updated_at AS n_updated_at,
                e.src_id AS e_src_id,
                e.dst_id AS e_dst_id,
                e.kind AS e_kind,
                e.body_json AS e_body_json,
                e.updated_at AS e_updated_at
            FROM graph_edges e
            JOIN graph_nodes n ON n.id = e.{neighbor_side}
            WHERE {}
            ORDER BY e.kind, n.kind, n.stable_key
            ",
            clauses.join(" AND ")
        );
        sql::rows(self.connection, &statement, &values)?
            .iter()
            .map(|row| {
                let mut entry = Dict::new();
                entry.insert("direction", if outward { "out" } else { "in" });
                entry.insert("edge", edge_from_row(row, "e_")?);
                entry.insert("node", node_from_row(row, "n_")?);
                Ok(entry)
            })
            .collect()
    }

    /// Run nodes, by state and by the provider they used.
    pub fn runs_by_provider(
        &self,
        provider: Option<&str>,
        state: Option<&str>,
    ) -> Result<Vec<Dict>> {
        let mut runs = self.nodes(Some(NODE_RUN), None)?;
        if let Some(state) = state {
            let wanted = normalize_key(&Value::Str(state.to_string()));
            runs.retain(|run| normalize_key(&Value::Str(node_state(run))) == wanted);
        }
        let Some(provider) = provider else {
            return Ok(runs);
        };
        let provider_key = normalize_key(&Value::Str(provider.to_string()));
        let provider_nodes: HashSet<String> = self
            .nodes(Some(NODE_AGENT_PROVIDER), None)?
            .iter()
            .filter(|node| {
                normalize_key(node.get("stable_key").unwrap_or(&Value::Null)) == provider_key
                    || normalize_key(body_field(node, "provider_key")) == provider_key
            })
            .map(|node| sql::field_str(node, "id").to_string())
            .collect();
        let run_ids: HashSet<String> = self
            .edges(Some(EDGE_USES_PROVIDER), None, None)?
            .iter()
            .filter(|edge| provider_nodes.contains(sql::field_str(edge, "dst_id")))
            .map(|edge| sql::field_str(edge, "src_id").to_string())
            .collect();
        runs.retain(|run| {
            run_ids.contains(sql::field_str(run, "id"))
                || normalize_key(body_field(run, "provider_key")) == provider_key
        });
        Ok(runs)
    }

    /// Ticket nodes, by state and by the provider of the runs that executed them.
    pub fn tickets_by_state(
        &self,
        state: Option<&str>,
        project_id: Option<&str>,
        provider: Option<&str>,
    ) -> Result<Vec<Dict>> {
        let mut tickets = self.nodes(Some(NODE_TICKET), project_id)?;
        if let Some(state) = state {
            let wanted = normalize_key(&Value::Str(state.to_string()));
            tickets.retain(|ticket| normalize_key(&Value::Str(node_state(ticket))) == wanted);
        }
        let Some(provider) = provider else {
            return Ok(tickets);
        };
        let run_ids: HashSet<String> = self
            .runs_by_provider(Some(provider), None)?
            .iter()
            .map(|run| sql::field_str(run, "id").to_string())
            .collect();
        let ticket_ids: HashSet<String> = self
            .edges(Some(EDGE_EXECUTES), None, None)?
            .iter()
            .filter(|edge| run_ids.contains(sql::field_str(edge, "src_id")))
            .map(|edge| sql::field_str(edge, "dst_id").to_string())
            .collect();
        let provider_key = normalize_key(&Value::Str(provider.to_string()));
        tickets.retain(|ticket| {
            ticket_ids.contains(sql::field_str(ticket, "id"))
                || normalize_key(body_field(ticket, "provider_key")) == provider_key
        });
        Ok(tickets)
    }

    /// Blocked ticket nodes; `tickets` classifies nodes already loaded.
    pub fn blocked_work(
        &self,
        project_id: Option<&str>,
        tickets: Option<Vec<Dict>>,
    ) -> Result<Vec<Dict>> {
        let mut tickets = match tickets {
            Some(tickets) => tickets,
            None => self.nodes(Some(NODE_TICKET), project_id)?,
        };
        let blocked: HashSet<String> = self
            .edges(Some(EDGE_BLOCKS), None, None)?
            .iter()
            .map(|edge| sql::field_str(edge, "dst_id").to_string())
            .collect();
        tickets.retain(|ticket| {
            blocked.contains(sql::field_str(ticket, "id"))
                || ["blocked", "verification_blocked"]
                    .contains(&normalize_key(&Value::Str(node_state(ticket))).as_str())
        });
        Ok(tickets)
    }

    /// Ticket nodes awaiting merge; `tickets` classifies nodes already loaded.
    pub fn awaiting_merge(
        &self,
        project_id: Option<&str>,
        tickets: Option<Vec<Dict>>,
    ) -> Result<Vec<Dict>> {
        let mut tickets = match tickets {
            Some(tickets) => tickets,
            None => self.nodes(Some(NODE_TICKET), project_id)?,
        };
        let ticket_ids: HashSet<String> = tickets
            .iter()
            .map(|ticket| sql::field_str(ticket, "id").to_string())
            .collect();
        let mut awaiting = HashSet::new();
        for edge in self.edges(Some(EDGE_AWAITS_MERGE), None, None)? {
            for side in ["src_id", "dst_id"] {
                let id = sql::field_str(&edge, side);
                if ticket_ids.contains(id) {
                    awaiting.insert(id.to_string());
                }
            }
        }
        tickets.retain(|ticket| {
            awaiting.contains(sql::field_str(ticket, "id"))
                || ["awaiting_merge", "awaiting-merge", "awaiting merge"]
                    .contains(&normalize_key(&Value::Str(node_state(ticket))).as_str())
        });
        Ok(tickets)
    }

    pub fn get_file_manifest(&self, project_id: &str, rel_path: &str) -> Result<Option<Dict>> {
        let project_id = require_text(Some(project_id), "project_id")?;
        let rel_path = require_text(Some(rel_path), "rel_path")?;
        Ok(sql::row(
            self.connection,
            "SELECT * FROM file_manifest WHERE project_id = ? AND rel_path = ?",
            &[text(project_id), text(rel_path)],
        )?
        .map(|row| pick(&row, &MANIFEST_FIELDS)))
    }

    pub fn file_manifests(
        &self,
        project_id: Option<&str>,
        include_deleted: bool,
    ) -> Result<Vec<Dict>> {
        let mut clauses = Vec::new();
        let mut values = Vec::new();
        if let Some(project_id) = project_id {
            clauses.push("project_id = ?");
            values.push(text(project_id));
        }
        if !include_deleted {
            clauses.push("deleted_at IS NULL");
        }
        let filter = where_clause(&clauses);
        Ok(sql::rows(
            self.connection,
            &format!("SELECT * FROM file_manifest{filter} ORDER BY project_id, rel_path"),
            &values,
        )?
        .iter()
        .map(|row| pick(row, &MANIFEST_FIELDS))
        .collect())
    }

    /// Records a file's manifest node, its project edges and its chunks,
    /// replacing the chunks it had.
    pub fn upsert_file_index(&self, file: &FileIndex) -> Result<Dict> {
        let project_id = require_text(Some(&file.project_id), "project_id")?;
        let rel_path = require_text(Some(&file.rel_path), "rel_path")?;
        let stable_key = format!("{project_id}:{rel_path}");
        let file_id = default_node_id(NODE_FILE, &stable_key);
        let now = sql::now();
        let mut manifest_body = Dict::new();
        manifest_body.insert("rel_path", rel_path.as_str());
        manifest_body.insert("language", optional(file.language.as_deref()));
        manifest_body.insert("size_bytes", file.size_bytes);
        manifest_body.insert("mtime_ns", file.mtime_ns.map_or(Value::Null, Value::Int));
        manifest_body.insert("content_hash", optional(file.content_hash.as_deref()));
        manifest_body.insert("indexed_at", now);
        manifest_body.insert("deleted_at", Value::Null);
        manifest_body.insert("index_kind", "manifest_text");
        let node = self.upsert_node(
            NODE_FILE,
            &stable_key,
            Some(&project_id),
            Some(&rel_path),
            Some(&manifest_body),
            Some(&file_id),
        )?;
        let node_id = sql::field_str(&node, "id").to_string();
        self.upsert_edge(&node_id, &project_id, EDGE_BELONGS_TO, None)?;
        self.upsert_edge(&project_id, &node_id, EDGE_CONTAINS, None)?;

        let c = self.connection;
        let write = || -> Result<()> {
            sql::execute(
                c,
                "
                    INSERT INTO file_manifest(
                        id, project_id, rel_path, language, size_bytes,
                        mtime_ns, content_hash, indexed_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(project_id, rel_path) DO UPDATE SET
                        id = excluded.id,
                        language = excluded.language,
                        size_bytes = excluded.size_bytes,
                        mtime_ns = excluded.mtime_ns,
                        content_hash = excluded.content_hash,
                        indexed_at = excluded.indexed_at,
                        deleted_at = NULL
                    ",
                &[
                    text(&node_id),
                    text(&project_id),
                    text(&rel_path),
                    opt_text(file.language.as_ref()),
                    int(file.size_bytes),
                    opt_int(file.mtime_ns),
                    opt_text(file.content_hash.as_ref()),
                    real(now),
                ],
            )?;
            sql::execute(
                c,
                "DELETE FROM file_chunks WHERE file_id = ?",
                &[text(&node_id)],
            )?;
            for (index, chunk) in file.chunks.iter().enumerate() {
                sql::execute(
                    c,
                    "
                        INSERT INTO file_chunks(
                            file_id, project_id, rel_path, chunk_ordinal,
                            start_line, end_line, text
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ",
                    &[
                        text(&node_id),
                        text(&project_id),
                        text(&rel_path),
                        int(chunk.chunk_ordinal.unwrap_or(index as i64)),
                        opt_int(chunk.start_line),
                        opt_int(chunk.end_line),
                        text(&chunk.text),
                    ],
                )?;
            }
            Ok(())
        };
        if self.in_transaction {
            write()?;
        } else {
            sql::transaction(c, "BEGIN", write)?;
        }
        Ok(self
            .get_file_manifest(&project_id, &rel_path)?
            .unwrap_or(manifest_body))
    }

    /// Marks the project's files absent from `seen_rel_paths` deleted and
    /// drops their chunks; returns how many.
    pub fn mark_missing_files_deleted(
        &self,
        project_id: &str,
        seen_rel_paths: &BTreeSet<String>,
    ) -> Result<usize> {
        let project_id = require_text(Some(project_id), "project_id")?;
        let now = sql::now();
        let c = self.connection;
        let rows = sql::rows(
            c,
            "
                SELECT id, rel_path
                FROM file_manifest
                WHERE project_id = ? AND deleted_at IS NULL
                ",
            &[text(&project_id)],
        )?;
        let stale: Vec<&Dict> = rows
            .iter()
            .filter(|row| !seen_rel_paths.contains(sql::field_str(row, "rel_path")))
            .collect();
        if stale.is_empty() {
            return Ok(0);
        }
        let write = || -> Result<()> {
            for row in &stale {
                let id = sql::field_str(row, "id");
                sql::execute(c, "DELETE FROM file_chunks WHERE file_id = ?", &[text(id)])?;
                sql::execute(
                    c,
                    "UPDATE file_manifest SET deleted_at = ? WHERE id = ?",
                    &[real(now), text(id)],
                )?;
            }
            Ok(())
        };
        if self.in_transaction {
            write()?;
        } else {
            sql::transaction(c, "BEGIN", write)?;
        }
        Ok(stale.len())
    }

    /// Full-text search over live chunks, best `bm25` rank first.
    pub fn search_files(
        &self,
        query: &str,
        project_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<Dict>> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        let match_query = fts_query(query);
        if match_query.is_empty() {
            return Ok(Vec::new());
        }
        let mut clauses = vec!["file_chunks_fts MATCH ?", "m.deleted_at IS NULL"];
        let mut values: Vec<Sql> = vec![text(match_query)];
        if let Some(project_id) = project_id {
            clauses.push("c.project_id = ?");
            values.push(text(project_id));
        }
        values.push(int(limit));
        let statement = format!(
            "
                SELECT
                    c.file_id,
                    c.project_id,
                    c.rel_path,
                    c.chunk_ordinal,
                    c.start_line,
                    c.end_line,
                    c.text,
                    m.language,
                    m.size_bytes,
                    m.mtime_ns,
                    m.content_hash,
                    m.indexed_at,
                    bm25(file_chunks_fts) AS rank
                FROM file_chunks_fts
                JOIN file_chunks c ON c.id = file_chunks_fts.rowid
                JOIN file_manifest m ON m.id = c.file_id
                WHERE {}
                ORDER BY rank, c.rel_path, c.chunk_ordinal
                LIMIT ?
                ",
            clauses.join(" AND ")
        );
        sql::rows(self.connection, &statement, &values)
    }
}

const MANIFEST_FIELDS: [&str; 9] = [
    "id",
    "project_id",
    "rel_path",
    "language",
    "size_bytes",
    "mtime_ns",
    "content_hash",
    "indexed_at",
    "deleted_at",
];

fn pick(row: &Dict, keys: &[&str]) -> Dict {
    let mut picked = Dict::new();
    for key in keys {
        picked.insert(key, row.get(key).cloned().unwrap_or(Value::Null));
    }
    picked
}

fn optional(value: Option<&str>) -> Value {
    value.map_or(Value::Null, |value| Value::Str(value.to_string()))
}

fn optional_text<'a>(row: &'a Dict, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str)
}

fn where_clause(clauses: &[&str]) -> String {
    if clauses.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", clauses.join(" AND "))
    }
}

/// `_default_node_id`: `kind.lower():stable_key`.
pub fn default_node_id(kind: &str, stable_key: &str) -> String {
    format!("{}:{stable_key}", kind.to_lowercase())
}

/// `_require_text`.
fn require_text(value: Option<&str>, field: &str) -> Result<String> {
    let text = value.map(json::py_strip).unwrap_or("");
    if text.is_empty() {
        return Err(Error::invalid(format!("{field} is required")));
    }
    Ok(text.to_string())
}

/// `_encode_body`: compact, sorted JSON; no body is `{}`.
pub fn encode_body(body: Option<&Dict>) -> String {
    let body = body.cloned().unwrap_or_default();
    json::dumps_compact_sorted(&Value::Dict(body))
}

/// `_decode_body`: an object, `{}` for any other JSON value.
fn decode_body(raw: &str) -> Result<Value> {
    let raw = if raw.is_empty() { "{}" } else { raw };
    Ok(match sql::loads(raw, "body_json")? {
        Value::Dict(body) => Value::Dict(body),
        _ => Value::Dict(Dict::new()),
    })
}

fn node_from_row(row: &Dict, prefix: &str) -> Result<Dict> {
    let mut node = Dict::new();
    for key in ["id", "kind", "project_id", "stable_key", "title"] {
        node.insert(
            key,
            row.get(&format!("{prefix}{key}"))
                .cloned()
                .unwrap_or(Value::Null),
        );
    }
    node.insert(
        "body",
        decode_body(sql::field_str(row, &format!("{prefix}body_json")))?,
    );
    node.insert(
        "updated_at",
        row.get(&format!("{prefix}updated_at"))
            .cloned()
            .unwrap_or(Value::Null),
    );
    Ok(node)
}

fn edge_from_row(row: &Dict, prefix: &str) -> Result<Dict> {
    let mut edge = Dict::new();
    for key in ["src_id", "dst_id", "kind"] {
        edge.insert(
            key,
            row.get(&format!("{prefix}{key}"))
                .cloned()
                .unwrap_or(Value::Null),
        );
    }
    edge.insert(
        "body",
        decode_body(sql::field_str(row, &format!("{prefix}body_json")))?,
    );
    edge.insert(
        "updated_at",
        row.get(&format!("{prefix}updated_at"))
            .cloned()
            .unwrap_or(Value::Null),
    );
    Ok(edge)
}

fn body_field<'a>(node: &'a Dict, key: &str) -> &'a Value {
    node.get("body")
        .and_then(Value::as_dict)
        .and_then(|body| body.get(key))
        .unwrap_or(&Value::Null)
}

/// `_node_state`: the body's `state`, else its `status`.
fn node_state(node: &Dict) -> String {
    let body = node.get("body").and_then(Value::as_dict);
    body.and_then(|body| body.truthy("state").or_else(|| body.truthy("status")))
        .map(Value::py_str)
        .unwrap_or_default()
}

/// `_normalize_key`: `str(value or "").strip().lower()`.
fn normalize_key(value: &Value) -> String {
    if !value.truthy() {
        return String::new();
    }
    json::py_strip(&value.py_str()).to_lowercase()
}

/// `_fts_query`: up to eight word tokens, quoted and joined with `AND`.
pub fn fts_query(query: &str) -> String {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for character in query.chars() {
        if character.is_ascii_alphanumeric() || character == '_' {
            current.push(character);
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
        .iter()
        .take(8)
        .map(|token| format!("\"{token}\""))
        .collect::<Vec<_>>()
        .join(" AND ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graph_round_trip_in_memory() {
        let store = GraphifyStore::open(Path::new(":memory:")).unwrap();
        store
            .transaction(|graph| {
                graph.upsert_node(
                    NODE_PROJECT,
                    "p1",
                    Some("project:p1"),
                    Some("P1"),
                    None,
                    Some("project:p1"),
                )?;
                let mut body = Dict::new();
                body.insert("state", "Blocked");
                graph.upsert_node(
                    NODE_TICKET,
                    "p1:T-1",
                    Some("project:p1"),
                    Some("T-1"),
                    Some(&body),
                    None,
                )?;
                graph.upsert_edge("ticket:p1:T-1", "project:p1", EDGE_BELONGS_TO, None)?;
                graph.upsert_file_index(&FileIndex {
                    project_id: "project:p1".into(),
                    rel_path: "src/main.rs".into(),
                    language: Some("rust".into()),
                    size_bytes: 12,
                    mtime_ns: Some(7),
                    content_hash: None,
                    chunks: vec![FileChunk {
                        text: "fn relay_store() {}".into(),
                        start_line: Some(1),
                        end_line: Some(1),
                        chunk_ordinal: None,
                    }],
                })?;
                Ok(())
            })
            .unwrap();
        store
            .with(|graph| {
                assert_eq!(graph.blocked_work(Some("project:p1"), None)?.len(), 1);
                let hits = graph.search_files("relay_store", None, 5)?;
                assert_eq!(sql::field_str(&hits[0], "rel_path"), "src/main.rs");
                let neighbours = graph.neighbors("project:p1", None, "both")?;
                assert_eq!(neighbours.len(), 3);
                let seen = BTreeSet::new();
                assert_eq!(graph.mark_missing_files_deleted("project:p1", &seen)?, 1);
                assert!(graph.search_files("relay_store", None, 5)?.is_empty());
                Ok(())
            })
            .unwrap();
        assert_eq!(fts_query("a-b c_d!"), "\"a\" AND \"b\" AND \"c_d\"");
    }
}
