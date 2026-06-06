"""SQLite-backed Graphify Core store.

Graphify Core is program state, not code intelligence. This module stores the
provider-neutral graph foundation for Program Manager mode: projects,
initiatives, tickets, runs, agent providers, risks, decisions, and the
relationships between them. File manifests, FTS, symbols, and embeddings belong
to the later code-indexing slice.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable

NODE_PROJECT = "Project"
NODE_INITIATIVE = "Initiative"
NODE_TICKET = "Ticket"
NODE_RUN = "Run"
NODE_AGENT_PROVIDER = "AgentProvider"
NODE_RISK = "Risk"
NODE_DECISION = "Decision"
NODE_PROGRAM_EVENT = "ProgramEvent"
NODE_IDEA = "Idea"
NODE_STATUS = "Status"
NODE_FILE = "File"

EDGE_BELONGS_TO = "belongs_to"
EDGE_CONTAINS = "contains"
EDGE_DEPENDS_ON = "depends_on"
EDGE_BLOCKS = "blocks"
EDGE_EXECUTES = "executes"
EDGE_AWAITS_MERGE = "awaits_merge"
EDGE_RELATED_TO = "related_to"
EDGE_USES_PROVIDER = "uses_provider"
EDGE_MENTIONS_FILE = "mentions_file"

CORE_NODE_KINDS = frozenset(
    {
        NODE_PROJECT,
        NODE_INITIATIVE,
        NODE_TICKET,
        NODE_RUN,
        NODE_AGENT_PROVIDER,
        NODE_RISK,
        NODE_DECISION,
        NODE_PROGRAM_EVENT,
        NODE_IDEA,
        NODE_STATUS,
        NODE_FILE,
    }
)

CORE_EDGE_KINDS = frozenset(
    {
        EDGE_BELONGS_TO,
        EDGE_CONTAINS,
        EDGE_DEPENDS_ON,
        EDGE_BLOCKS,
        EDGE_EXECUTES,
        EDGE_AWAITS_MERGE,
        EDGE_RELATED_TO,
        EDGE_USES_PROVIDER,
        EDGE_MENTIONS_FILE,
    }
)

CODE_INDEX_EXTENSION_POINT = (
    "Graphify's MVP code index is limited to file manifests and lexical text chunks. "
    "Tree-sitter, SCIP, and vector indexes should add derived tables beside these "
    "records instead of changing Program Manager graph semantics."
)


class GraphifyCoreStore:
    SCHEMA = """
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
    """

    def __init__(self, path: str | os.PathLike[str]):
        self.path = Path(path)
        self._memory_conn: sqlite3.Connection | None = None
        if str(self.path) == ":memory:":
            self._memory_conn = sqlite3.connect(":memory:", isolation_level=None, check_same_thread=False)
            self._memory_conn.row_factory = sqlite3.Row
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = self._memory_conn
            if conn is None:
                conn = sqlite3.connect(str(self.path), isolation_level=None)
                conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys = ON")
            if self._memory_conn is None:
                conn.execute("PRAGMA journal_mode = WAL")
            try:
                yield conn
            finally:
                if self._memory_conn is None:
                    conn.close()

    def _init(self) -> None:
        with self._conn() as conn:
            conn.executescript(self.SCHEMA)

    def upsert_node(
        self,
        *,
        kind: str,
        stable_key: str,
        project_id: str | None = None,
        title: str | None = None,
        body: dict[str, Any] | None = None,
        node_id: str | None = None,
    ) -> dict[str, Any]:
        kind = _require_text(kind, "kind")
        stable_key = _require_text(stable_key, "stable_key")
        node_id = _require_text(node_id, "node_id") if node_id is not None else _default_node_id(kind, stable_key)
        now = time.time()
        body_json = _encode_body(body)

        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO graph_nodes(id, kind, project_id, stable_key, title, body_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, stable_key) DO UPDATE SET
                    project_id = excluded.project_id,
                    title = excluded.title,
                    body_json = excluded.body_json,
                    updated_at = excluded.updated_at
                """,
                (node_id, kind, project_id, stable_key, title, body_json, now),
            )
            row = conn.execute(
                "SELECT * FROM graph_nodes WHERE kind = ? AND stable_key = ?",
                (kind, stable_key),
            ).fetchone()
        return _node_from_row(row)

    def get_node(self, node_id: str) -> dict[str, Any] | None:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM graph_nodes WHERE id = ?", (node_id,)).fetchone()
        return _node_from_row(row) if row else None

    def find_node(self, *, kind: str, stable_key: str) -> dict[str, Any] | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM graph_nodes WHERE kind = ? AND stable_key = ?",
                (kind, stable_key),
            ).fetchone()
        return _node_from_row(row) if row else None

    def nodes(self, *, kind: str | None = None, project_id: str | None = None) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if kind is not None:
            clauses.append("kind = ?")
            values.append(kind)
        if project_id is not None:
            clauses.append("project_id = ?")
            values.append(project_id)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._conn() as conn:
            rows = conn.execute(
                f"SELECT * FROM graph_nodes{where} ORDER BY kind, stable_key",
                values,
            ).fetchall()
        return [_node_from_row(row) for row in rows]

    def upsert_edge(
        self,
        *,
        src_id: str,
        dst_id: str,
        kind: str,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        src_id = _require_text(src_id, "src_id")
        dst_id = _require_text(dst_id, "dst_id")
        kind = _require_text(kind, "kind")
        now = time.time()
        body_json = _encode_body(body)

        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO graph_edges(src_id, dst_id, kind, body_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(src_id, dst_id, kind) DO UPDATE SET
                    body_json = excluded.body_json,
                    updated_at = excluded.updated_at
                """,
                (src_id, dst_id, kind, body_json, now),
            )
            row = conn.execute(
                "SELECT * FROM graph_edges WHERE src_id = ? AND dst_id = ? AND kind = ?",
                (src_id, dst_id, kind),
            ).fetchone()
        return _edge_from_row(row)

    def get_edge(self, *, src_id: str, dst_id: str, kind: str) -> dict[str, Any] | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM graph_edges WHERE src_id = ? AND dst_id = ? AND kind = ?",
                (src_id, dst_id, kind),
            ).fetchone()
        return _edge_from_row(row) if row else None

    def edges(
        self,
        *,
        kind: str | None = None,
        src_id: str | None = None,
        dst_id: str | None = None,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if kind is not None:
            clauses.append("kind = ?")
            values.append(kind)
        if src_id is not None:
            clauses.append("src_id = ?")
            values.append(src_id)
        if dst_id is not None:
            clauses.append("dst_id = ?")
            values.append(dst_id)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._conn() as conn:
            rows = conn.execute(
                f"SELECT * FROM graph_edges{where} ORDER BY kind, src_id, dst_id",
                values,
            ).fetchall()
        return [_edge_from_row(row) for row in rows]

    def neighbors(
        self,
        node_id: str,
        *,
        edge_kind: str | None = None,
        direction: str = "both",
    ) -> list[dict[str, Any]]:
        node_id = _require_text(node_id, "node_id")
        if direction not in ("out", "in", "both"):
            raise ValueError("direction must be 'out', 'in', or 'both'")

        results: list[dict[str, Any]] = []
        with self._conn() as conn:
            if direction in ("out", "both"):
                results.extend(
                    self._neighbors_for(conn, node_id=node_id, edge_kind=edge_kind, outward=True)
                )
            if direction in ("in", "both"):
                results.extend(
                    self._neighbors_for(conn, node_id=node_id, edge_kind=edge_kind, outward=False)
                )
        return results

    def _neighbors_for(
        self,
        conn: sqlite3.Connection,
        *,
        node_id: str,
        edge_kind: str | None,
        outward: bool,
    ) -> list[dict[str, Any]]:
        edge_side = "src_id" if outward else "dst_id"
        neighbor_side = "dst_id" if outward else "src_id"
        clauses = [f"e.{edge_side} = ?"]
        values: list[Any] = [node_id]
        if edge_kind is not None:
            clauses.append("e.kind = ?")
            values.append(edge_kind)
        rows = conn.execute(
            f"""
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
            WHERE {' AND '.join(clauses)}
            ORDER BY e.kind, n.kind, n.stable_key
            """,
            values,
        ).fetchall()
        return [
            {
                "direction": "out" if outward else "in",
                "edge": _edge_from_prefixed_row(row),
                "node": _node_from_prefixed_row(row),
            }
            for row in rows
        ]

    def runs_by_provider(
        self,
        provider: str | None = None,
        *,
        state: str | None = None,
    ) -> list[dict[str, Any]]:
        runs = self.nodes(kind=NODE_RUN)
        if state is not None:
            normalized_state = _normalize_key(state)
            runs = [run for run in runs if _normalize_key(_node_state(run)) == normalized_state]
        if provider is None:
            return runs

        provider_key = _normalize_key(provider)
        provider_nodes = {
            node["id"]: node
            for node in self.nodes(kind=NODE_AGENT_PROVIDER)
            if _normalize_key(node["stable_key"]) == provider_key
            or _normalize_key(node["body"].get("provider_key")) == provider_key
        }
        run_ids = {
            edge["src_id"]
            for edge in self.edges(kind=EDGE_USES_PROVIDER)
            if edge["dst_id"] in provider_nodes
        }
        return [
            run
            for run in runs
            if run["id"] in run_ids or _normalize_key(run["body"].get("provider_key")) == provider_key
        ]

    def tickets_by_state(
        self,
        state: str | None = None,
        *,
        project_id: str | None = None,
        provider: str | None = None,
    ) -> list[dict[str, Any]]:
        tickets = self.nodes(kind=NODE_TICKET, project_id=project_id)
        if state is not None:
            normalized_state = _normalize_key(state)
            tickets = [ticket for ticket in tickets if _normalize_key(_node_state(ticket)) == normalized_state]
        if provider is None:
            return tickets

        run_ids = {run["id"] for run in self.runs_by_provider(provider)}
        ticket_ids = {
            edge["dst_id"]
            for edge in self.edges(kind=EDGE_EXECUTES)
            if edge["src_id"] in run_ids
        }
        return [
            ticket
            for ticket in tickets
            if ticket["id"] in ticket_ids or _normalize_key(ticket["body"].get("provider_key")) == _normalize_key(provider)
        ]

    def blocked_work(self, *, project_id: str | None = None) -> list[dict[str, Any]]:
        tickets = self.nodes(kind=NODE_TICKET, project_id=project_id)
        blocked_ids = {
            edge["dst_id"]
            for edge in self.edges(kind=EDGE_BLOCKS)
        }
        return [
            ticket
            for ticket in tickets
            if ticket["id"] in blocked_ids or _normalize_key(_node_state(ticket)) == "blocked"
        ]

    def awaiting_merge(self, *, project_id: str | None = None) -> list[dict[str, Any]]:
        tickets = self.nodes(kind=NODE_TICKET, project_id=project_id)
        ticket_ids = {ticket["id"] for ticket in tickets}
        awaiting_ids = set()
        for edge in self.edges(kind=EDGE_AWAITS_MERGE):
            if edge["src_id"] in ticket_ids:
                awaiting_ids.add(edge["src_id"])
            if edge["dst_id"] in ticket_ids:
                awaiting_ids.add(edge["dst_id"])
        awaiting_states = {"awaiting_merge", "awaiting-merge", "awaiting merge"}
        return [
            ticket
            for ticket in tickets
            if ticket["id"] in awaiting_ids or _normalize_key(_node_state(ticket)) in awaiting_states
        ]

    def get_file_manifest(self, *, project_id: str, rel_path: str) -> dict[str, Any] | None:
        project_id = _require_text(project_id, "project_id")
        rel_path = _require_text(rel_path, "rel_path")
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM file_manifest WHERE project_id = ? AND rel_path = ?",
                (project_id, rel_path),
            ).fetchone()
        return _file_manifest_from_row(row) if row else None

    def file_manifests(
        self,
        *,
        project_id: str | None = None,
        include_deleted: bool = False,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if project_id is not None:
            clauses.append("project_id = ?")
            values.append(project_id)
        if not include_deleted:
            clauses.append("deleted_at IS NULL")
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._conn() as conn:
            rows = conn.execute(
                f"SELECT * FROM file_manifest{where} ORDER BY project_id, rel_path",
                values,
            ).fetchall()
        return [_file_manifest_from_row(row) for row in rows]

    def upsert_file_index(
        self,
        *,
        project_id: str,
        rel_path: str,
        language: str | None,
        size_bytes: int,
        mtime_ns: int | None,
        chunks: Iterable[dict[str, Any]],
        content_hash: str | None = None,
    ) -> dict[str, Any]:
        project_id = _require_text(project_id, "project_id")
        rel_path = _require_text(rel_path, "rel_path")
        file_id = _default_node_id(NODE_FILE, _file_stable_key(project_id, rel_path))
        now = time.time()
        manifest_body = {
            "rel_path": rel_path,
            "language": language,
            "size_bytes": int(size_bytes),
            "mtime_ns": mtime_ns,
            "content_hash": content_hash,
            "indexed_at": now,
            "deleted_at": None,
            "index_kind": "manifest_text",
        }
        file_node = self.upsert_node(
            kind=NODE_FILE,
            stable_key=_file_stable_key(project_id, rel_path),
            project_id=project_id,
            title=rel_path,
            body=manifest_body,
            node_id=file_id,
        )
        self.upsert_edge(src_id=file_node["id"], dst_id=project_id, kind=EDGE_BELONGS_TO)
        self.upsert_edge(src_id=project_id, dst_id=file_node["id"], kind=EDGE_CONTAINS)

        chunk_rows = list(chunks)
        with self._conn() as conn:
            conn.execute("BEGIN")
            try:
                conn.execute(
                    """
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
                    """,
                    (
                        file_node["id"],
                        project_id,
                        rel_path,
                        language,
                        int(size_bytes),
                        mtime_ns,
                        content_hash,
                        now,
                    ),
                )
                conn.execute("DELETE FROM file_chunks WHERE file_id = ?", (file_node["id"],))
                for index, chunk in enumerate(chunk_rows):
                    conn.execute(
                        """
                        INSERT INTO file_chunks(
                            file_id, project_id, rel_path, chunk_ordinal,
                            start_line, end_line, text
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            file_node["id"],
                            project_id,
                            rel_path,
                            int(chunk.get("chunk_ordinal", index)),
                            chunk.get("start_line"),
                            chunk.get("end_line"),
                            str(chunk.get("text") or ""),
                        ),
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return self.get_file_manifest(project_id=project_id, rel_path=rel_path) or manifest_body

    def mark_missing_files_deleted(self, *, project_id: str, seen_rel_paths: set[str]) -> int:
        project_id = _require_text(project_id, "project_id")
        now = time.time()
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT id, rel_path
                FROM file_manifest
                WHERE project_id = ? AND deleted_at IS NULL
                """,
                (project_id,),
            ).fetchall()
            stale = [row for row in rows if row["rel_path"] not in seen_rel_paths]
            if not stale:
                return 0
            conn.execute("BEGIN")
            try:
                for row in stale:
                    conn.execute("DELETE FROM file_chunks WHERE file_id = ?", (row["id"],))
                    conn.execute(
                        "UPDATE file_manifest SET deleted_at = ? WHERE id = ?",
                        (now, row["id"]),
                    )
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
        return len(stale)

    def search_files(
        self,
        query: str,
        *,
        project_id: str | None = None,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        if limit <= 0:
            return []
        match_query = _fts_query(query)
        if not match_query:
            return []

        clauses = ["file_chunks_fts MATCH ?", "m.deleted_at IS NULL"]
        values: list[Any] = [match_query]
        if project_id is not None:
            clauses.append("c.project_id = ?")
            values.append(project_id)
        values.append(int(limit))

        with self._conn() as conn:
            rows = conn.execute(
                f"""
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
                WHERE {' AND '.join(clauses)}
                ORDER BY rank, c.rel_path, c.chunk_ordinal
                LIMIT ?
                """,
                values,
            ).fetchall()
        return [_file_search_from_row(row) for row in rows]


def _default_node_id(kind: str, stable_key: str) -> str:
    return f"{kind.lower()}:{stable_key}"


def _require_text(value: str | None, field: str) -> str:
    if value is None:
        raise ValueError(f"{field} is required")
    text = str(value).strip()
    if not text:
        raise ValueError(f"{field} is required")
    return text


def _encode_body(body: dict[str, Any] | None) -> str:
    return json.dumps(body or {}, sort_keys=True, separators=(",", ":"))


def _decode_body(raw: str) -> dict[str, Any]:
    value = json.loads(raw or "{}")
    return value if isinstance(value, dict) else {}


def _node_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "kind": row["kind"],
        "project_id": row["project_id"],
        "stable_key": row["stable_key"],
        "title": row["title"],
        "body": _decode_body(row["body_json"]),
        "updated_at": row["updated_at"],
    }


def _edge_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "src_id": row["src_id"],
        "dst_id": row["dst_id"],
        "kind": row["kind"],
        "body": _decode_body(row["body_json"]),
        "updated_at": row["updated_at"],
    }


def _node_from_prefixed_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["n_id"],
        "kind": row["n_kind"],
        "project_id": row["n_project_id"],
        "stable_key": row["n_stable_key"],
        "title": row["n_title"],
        "body": _decode_body(row["n_body_json"]),
        "updated_at": row["n_updated_at"],
    }


def _edge_from_prefixed_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "src_id": row["e_src_id"],
        "dst_id": row["e_dst_id"],
        "kind": row["e_kind"],
        "body": _decode_body(row["e_body_json"]),
        "updated_at": row["e_updated_at"],
    }


def _node_state(node: dict[str, Any]) -> str:
    body = node.get("body", {})
    return str(body.get("state") or body.get("status") or "")


def _normalize_key(value: Any) -> str:
    return str(value or "").strip().lower()


def _file_stable_key(project_id: str, rel_path: str) -> str:
    return f"{project_id}:{rel_path}"


def _file_manifest_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "project_id": row["project_id"],
        "rel_path": row["rel_path"],
        "language": row["language"],
        "size_bytes": row["size_bytes"],
        "mtime_ns": row["mtime_ns"],
        "content_hash": row["content_hash"],
        "indexed_at": row["indexed_at"],
        "deleted_at": row["deleted_at"],
    }


def _file_search_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "file_id": row["file_id"],
        "project_id": row["project_id"],
        "rel_path": row["rel_path"],
        "chunk_ordinal": row["chunk_ordinal"],
        "start_line": row["start_line"],
        "end_line": row["end_line"],
        "text": row["text"],
        "language": row["language"],
        "size_bytes": row["size_bytes"],
        "mtime_ns": row["mtime_ns"],
        "content_hash": row["content_hash"],
        "indexed_at": row["indexed_at"],
        "rank": row["rank"],
    }


_FTS_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+")


def _fts_query(query: str) -> str:
    tokens = _FTS_TOKEN_RE.findall(str(query or ""))
    return " AND ".join(f'"{token}"' for token in tokens[:8])
