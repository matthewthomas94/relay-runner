# Graphify Indexing Backend Research

**Created:** 2026-06-06
**Status:** Research recommendation
**Ticket:** RR-37

## Recommendation

Use a single local SQLite database for the Program Manager MVP. Model Graphify Core as provider-neutral graph-shaped records in ordinary tables, add a small per-project file manifest, and use SQLite FTS5 for lexical search over selected text chunks. Do not use live grep as the query path.

Defer Kuzu, Tree-sitter structural indexing, SCIP code intelligence, and LanceDB/vector retrieval until the SQLite MVP has measured gaps. Kuzu is especially a post-MVP risk because its GitHub repository is archived as of October 10, 2025, even though the archived docs still describe it as an embedded Cypher/property-graph database.

This gives Relay Runner a small backend that can answer Program Manager questions across many registered repos without adding a second database engine, a parser toolchain, embedding models, or provider-specific run assumptions.

## Scope Split

Graphify has two layers that should not be collapsed:

- **Graphify Core:** program graph data: Project, Initiative, Ticket, Run, AgentProvider, Risk, Decision, File, and edges such as contains, depends_on, blocks, executes, awaits_merge, related_to, uses_provider, and mentions_file. This is product state and coordination state.
- **Graphify Code Indexing:** enrichment data about repo files and symbols. The MVP should be only a file manifest plus text chunks linked to Project and File nodes. Tree-sitter symbol graphs, SCIP references, call graphs, and embeddings are deeper indexing layers.

Graphify Core should remain authoritative for program status. Code indexing should make context discovery faster and more relevant, not become the source of truth for tickets, runs, or provider status.

## Assumptions

- Relay Runner remains local-first on macOS.
- Registered projects keep their repo-local `.orchestrator/` files as the project source of truth.
- Program Manager queries must run against a maintained index, not by crawling every repo at question time.
- The orchestrator daemon can own writes. The Swift app should read through daemon/API surfaces or carefully scoped read-only connections rather than competing as a second writer.
- Codex and Claude are both supported providers. The data model should store provider metadata without assuming either provider owns run state.

## MVP Backend

### Storage

Create one Program Manager SQLite database, separate from the existing run-history database unless the implementation ticket chooses a shared file with versioned migrations.

Minimal tables:

```sql
projects(
  id text primary key,
  root_path text not null unique,
  name text not null,
  active integer not null default 0,
  created_at real not null,
  updated_at real not null
);

graph_nodes(
  id text primary key,
  kind text not null,
  project_id text,
  stable_key text not null,
  title text,
  body_json text not null,
  updated_at real not null,
  unique(kind, stable_key)
);

graph_edges(
  src_id text not null,
  dst_id text not null,
  kind text not null,
  body_json text not null default '{}',
  updated_at real not null,
  primary key(src_id, dst_id, kind)
);

file_manifest(
  id text primary key,
  project_id text not null,
  rel_path text not null,
  language text,
  size_bytes integer not null,
  mtime_ns integer,
  content_hash text,
  indexed_at real not null,
  deleted_at real,
  unique(project_id, rel_path)
);

file_chunks(
  id integer primary key,
  file_id text not null,
  project_id text not null,
  rel_path text not null,
  chunk_ordinal integer not null,
  start_line integer,
  end_line integer,
  text text not null
);

-- External-content FTS keeps the canonical text in file_chunks.
CREATE VIRTUAL TABLE file_chunks_fts USING fts5(
  text,
  rel_path UNINDEXED,
  project_id UNINDEXED,
  content='file_chunks',
  content_rowid='id'
);
```

Keep `file_chunks` and `file_chunks_fts` consistent in the same transaction, either with explicit insert/delete calls in the ingestion code or with SQLite triggers.

Use explicit indexes for common graph queries:

- `graph_nodes(kind, project_id)`
- `graph_edges(kind, src_id)`
- `graph_edges(kind, dst_id)`
- `file_manifest(project_id, rel_path)`
- `file_chunks(project_id, file_id)`

Use `PRAGMA journal_mode=WAL` for the Program Manager database if the app and daemon will read concurrently. SQLite WAL allows readers and one writer to run at the same time, but it still has a single writer, so route writes through one daemon-side queue.

### Query Model

Expose a small Graphify query facade instead of raw SQL callsites:

- `upsert_node(kind, stable_key, project_id, title, body)`
- `upsert_edge(src, dst, kind, body)`
- `neighbors(node_id, edge_kind=None, direction='both')`
- `tickets_by_state(project_id=None, provider=None)`
- `runs_by_provider(provider=None, state=None)`
- `blocked_work(project_id=None)`
- `awaiting_merge(project_id=None)`
- `search_files(query, project_id=None, limit=20)`

Start with SQL joins and recursive common table expressions only where needed. Do not introduce Cypher for MVP. The graph shape is represented by node and edge tables, but the operational query language stays SQLite.

### Incremental Update Strategy

Program graph ingestion:

- Parse each registered repo's `.orchestrator/*.md` ticket files.
- Upsert Project, Ticket, Run, AgentProvider, Risk, and Decision nodes where available.
- Upsert ticket dependencies and run/provider edges idempotently.
- Read orchestrator run history and normalize provider/run fields.
- Never modify project ticket files from Program Manager ingestion.

Code index ingestion:

- Skip `.git`, `.orchestrator` internals except ticket bodies needed for Graphify Core, dependency directories, build outputs, binary files, app bundles, generated caches, and files over a conservative size threshold.
- Maintain `size_bytes`, `mtime_ns`, and optionally `content_hash`.
- On each pass, re-index files whose size or mtime changed; hash only when size/mtime signals are ambiguous or when correctness matters for a spike.
- Delete stale FTS rows when a file disappears or becomes ignored.
- Chunk text by line ranges with stable ordering, not by AST.

Provider-neutral run ingestion:

- Represent provider as data: `AgentProvider` nodes with `provider_key` values such as `codex` and `claude`.
- Represent runs with normalized fields: `run_id`, `ticket_id`, `attempt`, `provider_key`, `model_alias`, `state`, `branch`, `workspace_path`, `log_path`, `started_at`, `ended_at`, `exit_code`, and provider-specific metadata under `body_json.provider`.
- Link `Run -[uses_provider]-> AgentProvider`, `Run -[executes]-> Ticket`, and `Ticket -[belongs_to]-> Project`.
- Preserve provider-specific details only as optional metadata. Program status queries should not branch on Codex vs. Claude unless the user explicitly filters by provider.

### macOS App Integration

For the MVP, keep the SQLite writer in the Python daemon. The menu bar app should ask the daemon for Program Manager snapshots rather than directly mutating the database. That avoids Swift-side migration logic, reduces file-lock edge cases, and matches the existing orchestrator pattern where the daemon owns SQLite state.

If the Swift app needs direct reads later, use read-only SQLite connections and keep WAL checkpointing under daemon control. Direct Swift writes should wait until the store API and migration story are stable.

## Architecture Options

| Option | Storage | Query model | Incremental updates | Local complexity | macOS integration impact | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| SQLite Graphify Core + FTS5 text index | One local SQLite DB. Core graph in node/edge tables, file manifest and chunks in relational tables, FTS5 over chunks. | SQL joins, small recursive CTEs, FTS5 `MATCH`, BM25 ranking. | Reparse changed ticket files; upsert run rows; re-index files by mtime/size/hash; delete stale rows. | Low. Existing Python daemon already uses SQLite; no new runtime service. | Low. Daemon owns writes; Swift reads through daemon APIs. | **MVP.** Sufficient for program status and basic cross-repo file search. |
| SQLite Core + Kuzu graph mirror | SQLite remains source of truth; Kuzu stores a derived property graph. | SQLite for source-of-truth queries, Cypher for graph traversal and path patterns. | Mirror changed nodes/edges from SQLite into Kuzu after ingestion. Rebuild mirror if schema drifts. | Medium-high. Adds a second database, sync logic, packaging, and maintenance risk because upstream is archived. | Medium. Swift bindings exist in docs, but daemon-owned access is still safer. | Defer. Spike only if SQLite recursive queries become the bottleneck or Cypher materially improves PM workflows. |
| SQLite + Tree-sitter structural index | SQLite stores file manifest, extracted definitions, imports, and syntax captures. Optional serialized parse metadata per file. | SQL over extracted symbols plus Tree-sitter query captures per language. | Reparse changed files; Tree-sitter supports editing old trees for editor-style incremental reparsing, but repo indexing can start with changed-file reparses. | Medium. Requires parser packages, language detection, grammar management, and per-language query files. | Medium. Best kept in daemon or helper process; bundling parsers in the app increases packaging surface. | Defer. Use after FTS cannot answer "where is this defined?" cheaply enough. |
| SCIP-style code intelligence | Store SCIP indexes or normalized occurrence/symbol tables derived from `index.scip`. | Symbol and occurrence lookups: definitions, references, implementations, diagnostics. | Run language-specific indexers per repo or per changed project; ingest emitted protobuf indexes. | High. Requires compiler/language-server-aware indexers, protobuf bindings, toolchain setup, and per-language failures. | High. More external executables and larger logs/status UX. | Defer. Valuable for semantic navigation, not required for Program Manager MVP status visibility. |
| LanceDB/vector or hybrid retrieval | LanceDB tables for chunks, metadata, embeddings, optional FTS/hybrid indexes; SQLite keeps Core. | Vector search, full-text search, hybrid search with reranking. | Chunk changed files, compute embeddings, update vector rows and indexes. | Medium-high. Adds embedding model choice, privacy/cost decisions, index tuning, and another storage engine. | Medium. Likely daemon-side only; Swift consumes ranked results. | Defer. Spike only after lexical FTS misses important natural-language queries. |

## Why SQLite Is Enough For MVP

The Program Manager's first hard problem is not semantic code navigation. It is reliable visibility across projects: which tickets exist, what is blocked, which runs are active, which provider is executing them, what is awaiting merge, and which files or docs are likely relevant.

SQLite covers that problem with fewer moving parts:

- The graph is small and operational: tickets, runs, projects, risks, decisions, and edges are not a web-scale graph.
- The existing daemon already uses SQLite, so failure modes, backup expectations, and local deployment are familiar.
- FTS5 handles the "do not live-grep every repo" requirement for text search while preserving a local, queryable index.
- WAL mode is enough for one daemon writer plus app/API readers.
- Provider-neutral run state is naturally relational: provider-specific fields live in JSON metadata, while common fields stay queryable.

MVP implementation should optimize for correctness, repeatable ingestion, and clear API boundaries. If later queries need multi-hop path planning or symbol-precise navigation, those can be derived from the SQLite source of truth.

## Explicit Deferrals

- **Kuzu or another graph engine:** defer until a spike proves recursive SQL is not enough. If revisited, keep SQLite as the source of truth and treat the graph engine as a rebuildable mirror. Given Kuzu's archived upstream, also evaluate maintained alternatives before committing.
- **Tree-sitter symbols:** defer until file-level FTS produces too many irrelevant hits for common Program Manager questions. Start with 1-2 languages used by Relay Runner instead of a universal parser bundle.
- **SCIP:** defer until users need semantic code navigation across repos. It requires language-specific indexers and compiler context, which is disproportionate for program status.
- **Vector/hybrid retrieval:** defer until lexical search has measured recall failures. Any vector spike must decide local vs. remote embeddings, model footprint, privacy, and cache invalidation.
- **Filesystem watcher:** defer initially. A manual/periodic "refresh registered projects" pass is easier to reason about. Add FSEvents only if refresh latency becomes user-visible.

## Spike Criteria

Run the SQLite MVP spike against at least 5 representative repos and one synthetic larger fixture. Record median and p95 where applicable.

| Dimension | Measurement | MVP acceptance target |
| --- | --- | --- |
| Cold index time | Time to ingest projects, tickets, runs, file manifest, and FTS chunks from an empty DB. | Program graph under 500 ms per typical repo; file text index under 60 seconds for 100k eligible text files or 1 GB of text on the target Mac. |
| Incremental update time | Time after one changed ticket, one changed run, one changed file, and a batch of 100 changed files. | Single ticket/run/file visible under 1 second; 100 changed files under 5 seconds. |
| Query latency | p95 for "blocked across projects", "active agents by provider", "awaiting merge", dependency neighborhood, and top-20 file search. | Status/graph queries under 100 ms; FTS top-20 under 250 ms. |
| Disk footprint | SQLite DB size compared with source ticket/run metadata and indexed text bytes. | Core metadata under 25 MB for typical local project sets; text index under 50 percent of indexed text size unless documented by corpus. |
| Implementation complexity | New runtime dependencies, migration count, daemon modules, Swift surfaces, and test fixtures. | Zero new database services; no new Swift write path; no more than one new Python store module, one ingestion module, and focused tests for idempotency/search. |

If any target fails, the spike should identify whether the failure is schema/index tuning, ingestion batching, file exclusion policy, or a reason to add a deferred backend.

## Primary Sources

- SQLite FTS5 supports full-text virtual tables, BM25/snippet helpers, trigram substring matching, and external/contentless table modes: https://www.sqlite.org/fts5.html
- SQLite WAL allows readers and a writer to run at the same time but still permits only one writer at a time: https://www.sqlite.org/wal.html
- Kuzu docs describe an embedded property graph database with Cypher, columnar storage, CSR adjacency/join indexes, and ACID transactions: https://kuzudb.github.io/docs/
- Kuzu's GitHub repository is archived, and its README says KuzuDB is being archived while v0.11.3 bundles common extensions: https://github.com/kuzudb/kuzu
- Tree-sitter supports parser/syntax tree APIs and many grammars: https://tree-sitter.github.io/tree-sitter/using-parsers/1-getting-started.html
- Tree-sitter advanced parsing docs describe editing an old tree and reparsing with shared structure: https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html
- Tree-sitter queries use S-expression patterns over syntax trees: https://tree-sitter.github.io/tree-sitter/using-parsers/queries/1-syntax.html
- SCIP is a language-agnostic code intelligence protocol for code navigation, and Sourcegraph's docs describe indexes as documents with occurrences and symbols: https://github.com/scip-code/scip and https://sourcegraph.com/docs/code-navigation/writing-an-indexer
- LanceDB docs describe OSS embedded usage and search over vector, full-text, SQL, and hybrid retrieval: https://docs.lancedb.com/ and https://docs.lancedb.com/search/hybrid-search
