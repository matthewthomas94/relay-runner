# Project-owned Relay artifact store

This is RR-273 phase 3 and implements the [RR-270 target topology and project repository](../investigations/RR-270-repo-local-retention-and-scope.md#target-topology). The implementation is `services/artifact_store.py`.

## Authority and rollout

The only canonical writable project artifact store is `refs/heads/relay/artifacts` in the registered project's own Git common directory. The ref is orphan-rooted and linear; every reachable tree is verified to contain only the Relay allowlist. Source history must not be reachable through it.

The writer requires an explicit per-project `enabled=True` opt-in and initializes `remote_sync = "local_only"`. Opting out stops new artifact operations and returns callers to the preserved direct-file compatibility path. It never removes or rewrites an existing artifact ref.

The repo-root `.orchestrator/` directory is a projection. It is atomically rebuilt from a verified artifact head, locally excluded through `.git/info/exclude`, and accompanied by app-support metadata containing the base commit, tree, per-file blob IDs, and content hashes. A manual edit or simultaneous ref/file divergence fails closed and requires explicit import or reconciliation.

## Typed writer contract

One process/thread-safe writer lock exists per immutable project ID. A mutation supplies:

- a provider-neutral actor type, device ID, immutable event ID, optional provider attribution, and optional expected base commit;
- one or more typed ticket, config, attachment, archive-index, or Program-event operations; and
- refined bytes only—never a filesystem catch-all or source path.

The event digest covers every typed field and byte hash. A retry with the same event ID and digest returns the original commit; reuse with different content is rejected. Every successful logical event creates one commit with `Relay-Project-ID`, `Relay-Event-ID`, `Relay-Event-Digest`, `Relay-Device-ID`, and `Relay-Actor-Type` trailers. Optional `Relay-Provider` is attribution only and does not affect authorization or Git behavior.

Existing ticket display IDs remain paths such as `RR-283.md`. Each ticket also gains an immutable `artifact_id` in front matter. An existing mismatched artifact ID is an identity error rather than an overwrite.

## Git and source-isolation invariants

Mutations use a private temporary `GIT_INDEX_FILE`, `read-tree`, exact `hash-object` and `update-index --cacheinfo 100644` calls, `write-tree`, and `commit-tree`. Publication is `update-ref <artifact-ref> <new> <expected>` compare-and-swap. There is no checkout, reset, merge, add-all, remote edit, source ref update, or source push.

The allowlist is exactly:

- `.orchestrator/config.toml`;
- `.orchestrator/archive-index.jsonl`;
- `.orchestrator/<ticket-id>.md`;
- `.orchestrator/attachments/<same-ticket-id>/<validated-name>`; and
- `.orchestrator/program/events/<event-id>.json`.

Traversal, absolute paths, control-character filenames, symlink mode, Gitlink/submodule mode, merge-parent history, and any non-regular artifact entry are rejected. Tests preserve source HEAD, non-artifact refs, branch/detached state, index checksum, staged/unstaged/untracked files, configured remotes, and local-ahead commits across initialization, success, failure, and recovery.

## Content and attachment policy

Ticket Markdown is UTF-8, front-matter identified, and limited to 256 KiB. Program events are canonical JSON, project/event identified, and limited to 256 KiB. Explicit raw transcript, raw audio, raw logs/traces, tool output, hidden reasoning, and common credential/private-key fixtures are refused before an object is committed.

Attachments are structurally owned by their typed ticket ID. Filenames cannot carry another path. Declared MIME, extension, and magic bytes must agree; the local-only baseline accepts PNG, JPEG, GIF, WebP, and PDF. Raw audio, archives, executables, and unknown binaries are rejected. The limits are 10 MiB per attachment and 25 MiB aggregate per ticket. The writer also emits an actionable warning when project attachment bytes exceed its configured warning budget (250 MiB by default). Remote exposure confirmation and LFS policy remain later explicit features.

## Failure and restart recovery

Failure injection covers before commit, during CAS, after ref update, and during materialization:

- before commit or CAS leaves the ref and projection unchanged;
- a CAS mismatch leaves a dangling, unreachable commit at most and reports the actual head;
- after ref publication, retry finds the immutable event and rematerializes without a second commit; and
- materialization uses a journal plus temporary/backup directories, so restart reconstructs from the canonical ref.

Initialization adopts only a verified same-project artifact ref. An existing unbased `.orchestrator/` tree is never overwritten; legacy data must enter through the journaled migration in phase 8.

## Provider parity

Codex and Claude receive byte-identical snapshots and typed results from the same head. Provider identity can appear as bounded attribution metadata, but does not alter allowed paths, event identity, limits, locking, CAS behavior, materialization, or error outcomes. Raw provider traces and hidden reasoning have no artifact operation type and are explicitly rejected from Program/ticket payloads.
