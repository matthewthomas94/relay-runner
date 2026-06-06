# Program Manager MVP

This document defines the first Relay Runner Program Manager MVP. It is the product and architecture contract for replacing the old PM-sync and GSD-style workflows with a native program layer while preserving each repo's `.orchestrator/` board as the project-level source of truth.

## Goals

- Manage work across multiple local projects from Relay Runner without moving project tickets out of their repos.
- Keep each repo's `.orchestrator/` directory authoritative for project tickets, dependencies, run logs, and merge audit history.
- Add a program-level registry, graph, status surface, and board that can answer cross-project questions without copy/paste ledger updates.
- Make Graphify Core the early MVP foundation for program data: projects, initiatives, tickets, runs, providers, risks, decisions, and relationships.
- Add a small Graphify code-indexing slice later in the MVP only as enrichment for "what files or docs may be relevant?" queries.
- Provide equivalent Program Manager behavior for Codex and Claude sessions, dispatches, health, and run status.

## Non-goals

- Do not replace per-repo `.orchestrator/` boards or make the program layer the ticket source of truth.
- Do not add deep code intelligence in Graphify Core: no Tree-sitter symbol graph, SCIP reference graph, vector search, or whole-repo semantic indexing in the foundation ticket.
- Do not revive PM-sync copy/paste YAML, `.pm/project-id`, or a separate ledger chat as part of the target workflow.
- Do not reintroduce GSD-style external project management flows. The native Program Manager owns cross-project review and planning.
- Do not require a live `/relay-bridge` cwd as the only way to see program status. The bridge remains one activation path, not the program selector.

## Success Criteria

- A user can register at least two local repos and see cross-project status without opening each project board.
- The existing project board still opens for the active project and still reads that repo's `.orchestrator/` files.
- Program status can report active work, blocked work, awaiting-merge work, stale runs, risks, and decisions with project and ticket references.
- Native session review capture writes structured graph events instead of emitting PM-sync YAML.
- Codex and Claude runs appear with the same program-level state model, with provider labels and documented provider-specific health details.
- The MVP can be verified with fixture or temporary repos and leaves ticket files as repo-local source-of-truth artifacts.

## Data Ownership

The Program Manager has two layers:

| Layer | Source of truth | Scope | Writes |
| --- | --- | --- | --- |
| Project board | `<repo>/.orchestrator/*.md` and `.orchestrator/config.toml` | One repo | Board UI, sub-agent claiming/logging, daemon dependency auto-progression |
| Program layer | Relay Runner program registry and Graphify Core store | Registered local repos | Project activation, ingestion, session review capture, graph maintenance |

The program layer indexes and links project data, but it does not own ticket status. Ticket status remains in the project repo. Cross-project ingestion must be idempotent and read-only with respect to project ticket files.

## Project Lifecycle

The MVP project lifecycle is:

1. **Resolve -> Register -> Activate -> Ensure Board**
2. **Resolve:** accept a repo path, cwd from `/relay-bridge`, or known project alias and resolve it to a canonical local repo.
3. **Register:** store the project in the program registry with repo path, display name or alias, last seen timestamp, and provider-relevant metadata.
4. **Activate:** mark a registered project as the active project for the current Relay Runner session or UI action.
5. **Ensure Board:** if the active project is an existing git repo without `.orchestrator/config.toml`, initialize `.orchestrator/` and its config. Non-git folders require an explicit initialization path or refusal; they must not silently run `git init`.

Existing `/relay-bridge` cwd resolution remains valid: starting a Codex or Claude session in a repo should register and activate that repo. Program UI and MCP paths must also activate a project by path or alias so program status is not coupled to one live bridge cwd.

## Graphify MVP Scope

Graphify is part of the MVP in two layers.

### Graphify Core

Graphify Core lands early as the program graph foundation. It stores graph-shaped records for:

- Projects and initiatives.
- Tickets and dependencies.
- Runs and agent providers.
- Risks, decisions, ideas, status events, and session review events.
- Relationships such as `belongs_to`, `contains`, `depends_on`, `blocks`, `executes`, `awaits_merge`, `related_to`, and `uses_provider`.

Graphify Core must stay provider-neutral. Codex and Claude are provider labels and metadata sources, not separate graph models.

### Code-Indexing Slice

The later MVP code-indexing slice enriches Graphify Core with a per-project file manifest and searchable text index over important repo files. It is enough to answer basic context questions without live-grepping every registered repo.

The slice should defer Tree-sitter, SCIP, vector search, and full semantic code intelligence unless a prior research ticket proves a small piece is cheap and necessary.

## Provider Parity

Relay Runner supports Codex and Claude. Program Manager behavior should be equivalent unless an intentional difference is documented.

- **Program management:** registered projects, graph nodes, board rows, risks, decisions, and captured session events use the same schema for Codex and Claude.
- **Project activation:** Codex and Claude sessions can both activate the current repo from `/relay-bridge` cwd and can both use programmatic activation by path or alias.
- **Dispatch:** per-project dispatch remains provider-configured. The program layer records which provider ran a ticket and shows equivalent status for Codex and Claude workers.
- **Provider health:** health checks may use provider-specific commands and auth paths, such as Codex and Claude login/config checks, but the Program Board should show a common health vocabulary: ready, missing CLI, unauthenticated, misconfigured, rate-limited, or unknown.
- **Sub-agent status:** active, succeeded, failed, canceled, stalled, and awaiting-merge states are provider-neutral. Provider-specific error text can be attached as metadata.
- **Intentional differences:** CLI names, model names, permission flags, auth files, and context-capture capabilities may differ. Those differences should be documented in implementation notes or user-facing copy when they affect behavior.

## Program Surfaces

- **Project Registry:** stores registered projects and activation metadata.
- **Graphify Core:** stores the program graph derived from registries, ticket files, run history, and session review capture.
- **Program Status MCP and Voice:** answers cross-project questions from Graphify Core, such as "what are all agents doing?", "what is blocked?", "what is awaiting merge?", and "what should I look at next?"
- **Program Board:** a distinct read-only overlay for cross-project status. It does not replace the existing active-project board.
- **Native Session Review Capture:** writes structured ProgramEvent, Decision, Risk, Idea, and Status nodes directly into Graphify Core. It does not produce PM-sync YAML and does not require `.pm/project-id`.

## Roadmap

The MVP ticket order is:

1. **RR-36: Program Manager MVP spec and roadmap**: create this contract. No runtime behavior.
2. **RR-37: Research scalable Graphify indexing backend**: can run in parallel with RR-36. Recommends the storage/query/indexing approach and distinguishes Graphify Core from deeper code indexing.
3. **RR-38: Project registry and activation flow**: depends on RR-36. Implements Resolve -> Register -> Activate -> Ensure Board.
4. **RR-39: Graphify Core store and query API**: depends on RR-36 and RR-37. Implements the provider-neutral graph foundation.
5. **RR-40: Cross-project ingestion into Graphify Core**: depends on RR-38 and RR-39. Ingests registered projects' `.orchestrator/` tickets and run history read-only.
6. **RR-41: Program status MCP and voice commands**: depends on RR-40. Exposes cross-project status queries from Graphify Core.
7. **RR-42: Read-only Program Board overlay**: depends on RR-41. Adds the first cross-project board while preserving the existing project board.
8. **RR-43: Native session review capture**: depends on RR-39 and RR-41. Replaces the PM-sync copy/paste loop with direct graph capture.
9. **RR-44: Deprecate PM-sync guidance and metadata**: depends on RR-43. Removes Relay Runner-facing PM-sync guidance and marks `.pm/project-id` legacy without deleting user data.
10. **RR-46: Graphify code-indexing MVP slice**: depends on RR-37, RR-39, and RR-40. Adds the small file manifest and text index enrichment.
11. **RR-45: Multi-project MVP verification**: depends on RR-42, RR-43, RR-44, and RR-46. Verifies the full MVP across multiple projects with provider-neutral Codex and Claude metadata.
