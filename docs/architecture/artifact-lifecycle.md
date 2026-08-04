# Artifact-owned worker lifecycle

This is RR-273 phase 6 and implements the [RR-270 worker and lifecycle contract](../investigations/RR-270-repo-local-retention-and-scope.md#worker-and-lifecycle-contract). The provider-neutral coordinator is `services/artifact_lifecycle.py`; daemon integration remains in `services/orchestrator.py`.

## Rollout and authority

Artifact lifecycle is selected per project by `artifact_lifecycle = "enabled"` in the canonical artifact `config.toml`. Missing or `legacy` keeps the existing ticket-on-worker-branch path. Change the gate only after active runs drain: disabling it stops new artifact-owned claims but preserves the artifact ref, emitted events, source commits, outcomes, and leases for recovery.

The artifact gate currently covers implementation worktrees. Branchless spike result persistence remains on the legacy lifecycle; an enabled project refuses a spike with an explicit instruction to drain and switch the reversible gate instead of mixing two authorities in one run.

An artifact-owned dispatch requires a current registry-v2 scope token. The daemon verifies project ID, resolved repository path, Git-common-directory fingerprint, registry schema and record timestamp before claim. Daemon-owned retry, resume, and dependency continuations may carry the already validated immutable project ID internally; cwd and repo path alone never confirm ownership.

## Worker and review boundary

Claim is one idempotent artifact-writer event. It records the run in the canonical ticket, acquires a durable worker snapshot lease, and materializes a read-only worktree input containing only:

- the assigned ticket;
- ticket-owned eligible attachments;
- bounded summaries of required active or archived dependencies; and
- a manifest identifying project, ticket, run, provider, artifact head, exact files, hashes, and source start commit.

The worker branch must not track `.orchestrator` or `.relay`. Codex and Claude receive the same `orchestrator_artifact_workflow.md` contract and submit the same bounded outcome schema to `POST /v1/runs/<run-id>/outcome`: status, safe summary, exact changed source paths, verification summary, and source commit. Verification-blocked outcomes also require a precise external blocker and resume condition. Raw logs remain local and are tail-capped at 2 MiB; transcripts, tool traces, hidden reasoning, secrets, lifecycle paths, and unknown fields are rejected.

Worker completion independently proves that the declared commit is worktree HEAD, differs from the leased source start, exactly matches the committed changed-path set, contains no lifecycle files, and leaves no uncommitted source changes. Review replaces the worker lease with a reviewer lease. A successful source merge must be present at canonical source HEAD before one artifact transaction publishes the bounded run summary, `done` or `verification_blocked`, and any newly ready dependents. Merge failure, dirty source, missing evidence, cancellation, provider failure, or review retry cannot publish done or advance dependencies.

## Idempotency, recovery, and retention

Claim, sizing, failure, retry, cancellation, merge-conflict, verification resume, and merge publication use stable run/event identities. Structured outcomes are immutable per run. Duplicate delivery returns the prior result; different bytes under the same identity fail closed.

Worker and reviewer leases are durable app-local records tied to the immutable artifact input. Review transfers ownership without a gap. Successful merge, verification block, failure, retry, and cancellation explicitly release all run leases. Startup recovery retains leases for demonstrably live ledger states and releases only terminal or missing runs; heartbeat age alone never expires one. RR-285 retention therefore cannot archive a ticket or attachment while a live worker or reviewer still needs its snapshot.

## Canonical state and operational behavior

Ready sweeps validate one confirmed project scope before dispatch. Artifact merge publication owns dependency promotion, and internally confirmed same-project dispatch handles promoted tickets. Review retry, explicit verification resume, cancellation, queue-drain classification, health observation, provider authentication failure, and merge-conflict reporting all read the materialized canonical artifact state. If source merge succeeds but artifact publication fails, the run remains `MergeConflict` with its evidence and reviewer lease intact so publication can be recovered without fabricating completion.

Provider attribution affects only diagnostics and launch configuration. Snapshot bytes, validation, event IDs, leases, retry/cancel behavior, merge truth, dependency outcomes, and privacy limits are identical for Codex and Claude; executable discovery, authentication, model names, and effort flags remain the intentional provider-specific differences.

Installed provider parity and cohort promotion remain externally evidence-gated;
see [Artifact installed verification and staged rollout](artifact-rollout.md).
