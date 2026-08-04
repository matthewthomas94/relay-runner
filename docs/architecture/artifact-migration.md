# Guarded artifact migration, rollback, and reinstall recovery

RR-288 implements [RR-270 phase 8](../investigations/RR-270-repo-local-retention-and-scope.md#phase-8--guarded-migration-rollback-and-fresh-install-recovery). Migration is explicit per project, fail-closed, and journaled. It never force-pushes, publishes a source ref, combines source cleanup with unrelated work, or deletes a repository, artifact ref, remote, or remote branch.

## Preview and authority

Run the read-only preflight first:

```bash
scripts/relay-artifact-migrate preview \
  --repo /path/to/project \
  --project-id <registry-v2-project-id>
```

The preview records the resolved repository and Git common directory, source/default branch and HEAD, source status/index/refs/remotes, the exact registry-v2 record, run and Program references, and every legacy path's byte hash, size, modification evidence, tracked state, dependency identity, and referenced attachment. Remote URLs are represented by a privacy-safe locator and hash, not credentials.

Preflight refuses malformed tickets/config/catalog/Program records, missing or foreign attachments, symlinks, Gitlinks/submodules, special or non-allowlisted files, secret/unsupported/oversized content, unavailable or mismatched registry identity, corrupt run/Program stores, active or review-blocking runs, and an unexpected local artifact ref. Each blocker includes the required recovery action. Preview sets `GIT_OPTIONAL_LOCKS=0` and writes no journal, ref, index, registry, or repository file.

## Journaled cutover

After reviewing the preview, explicitly confirm source cleanup:

```bash
scripts/relay-artifact-migrate migrate \
  --repo /path/to/project \
  --project-id <registry-v2-project-id> \
  --confirm-source-cleanup
```

The coordinator holds the same cross-process project writer lock as normal artifact mutations. It stores an exact Relay-owned legacy-tree backup and registry backup, creates the orphan artifact snapshot only through typed operations, gives every ticket deterministic immutable `artifact_id` and `activity_at` anchors, and creates the empty archive catalog when needed. It compares every projected byte hash before source cleanup.

A configured remote remains local-only when its artifact ref is absent unless `--confirm-first-push` is supplied. That option performs one normal exact-ref push. An existing ref is inspected in a disposable bare repository and adopted only when the project identity and every projected artifact byte match. Foreign or divergent history stops for reconciliation. No force option exists.

Source cleanup builds a commit from preflight HEAD with a private index, deleting only the reviewed tracked `.orchestrator` paths. The source branch moves by compare-and-swap, and the real index removes only those paths; unrelated staged, unstaged, untracked, local-ahead, remote, and ref state is checked before and after. The artifact ref is then rematerialized and locally excluded. Workspace board create/edit/move/delete/attachment operations detect `artifact_lifecycle = "enabled"` and synchronously use confirmed-scope daemon endpoints, so the projection never becomes a competing writer.

Program capture-only records are exported to immutable artifact events before a clean registry-v2/artifact/run-backed Graphify rebuild. The final step writes, but does not execute, the first 30-day retention preview. The journal records verified artifact/source commits, the manifest digest, backups, remote outcome, Program rebuild, retention candidates/exemptions, and exact rollback instructions. Re-running the same command resumes or returns the completed result without duplicating commits.

## Rollback

```bash
scripts/relay-artifact-migrate rollback \
  --repo /path/to/project \
  --project-id <registry-v2-project-id>
```

Before source cutover, rollback restores registry authority and retains the unused local artifact ref. After cutover, it first freezes the writer and verifies the artifact head has not advanced, then restores the byte-exact legacy backup in a new reviewed source commit, removes only Relay's local exclude line, restores the registry backup, and switches the materialized config back to the legacy writer. Artifact and remote refs remain intact. Any artifact advance, source-branch change, or evidence of writes to both models stops with immutable event-ID reconciliation required.

## Reinstall and deliberate reset

Normal reinstall is a two-step preview/execute flow and preserves the entire Relay Application Support tree:

```bash
scripts/relay-runner-fresh-install --app "/path/to/Relay Runner.app"
scripts/relay-runner-fresh-install --app "/path/to/Relay Runner.app" --execute
```

The workflow byte-verifies the copied bundle, moves an existing app to Trash as a recoverable backup, then proves Relay state plus every available registered repository's HEAD, refs, index, dirty status, and `.orchestrator` bytes are unchanged.

A deliberate first-run reset is a separate destructive-looking but recoverable operation:

```bash
scripts/relay-runner-fresh-install --reset-state
scripts/relay-runner-fresh-install --reset-state --execute --confirm-daemon-stopped
scripts/relay-runner-fresh-install \
  --restore-reset ~/.Trash/relay-runner-state-....reset-recovery.json \
  --execute --confirm-daemon-stopped
```

Reset refuses active/review-blocking runs and requires explicit confirmation that the app/daemon writers are stopped. It atomically moves only `~/Library/Application Support/relay-runner` to Trash and writes a sidecar recovery manifest. Registered repositories are hash-checked but never edited or deleted. Restore refuses to overwrite any new non-empty state, requiring explicit reconciliation instead.

## Provider parity and privacy

Codex and Claude use identical manifests, typed operations, scope validation, file bytes, conflict behavior, resume stages, and rollback. Provider attribution can change commit metadata only. Journals and diagnostics contain bounded IDs, state, paths, counts, hashes, and recovery actions; they exclude credentials, raw audio/transcripts/logs, tool traces, session traces, and hidden reasoning.
