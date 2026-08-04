# Registry v2 and application-support ownership

Registry v2 implements phase 1 of [RR-270's application-support and registration design](../investigations/RR-270-repo-local-retention-and-scope.md#application-support-home). It is the app-owned logical project catalog. It is not a ticket store, a parent for registered repositories, or authority to modify a repository.

## Rollout boundary

The v2 service is available only when `RELAY_RUNNER_REGISTRY_V2=1` (also `true`, `yes`, or `enabled`). The flag defaults off. Phase 1 deliberately leaves every existing `ProjectRegistry` consumer on `program/projects.json`; later Workspace and session-scope phases will opt consumers into the new service. Disabling the flag immediately restores the preserved legacy read path. The legacy file is never changed or removed by v2 migration.

This boundary makes rollback non-destructive: v2 JSON, its backup, and Keychain items may be removed while the flag is disabled, but rollback must not touch a registered repository. The implementation does not yet change Workspace UI, initialize `relay/artifacts`, sync a remote, or cut over repository-local `.orchestrator` files.

## Owned state

The fixed root is `~/Library/Application Support/relay-runner/`:

| Path | Ownership |
|---|---|
| `projects/registry-v2.json` | Schema-2 project records and active immutable project ID |
| `projects/registry-v2.backup.json` | Last known good registry document |
| `backups/registry-v2-*.corrupt.json` | Quarantined unreadable primary or backup copies |
| `indexes/<project-id>/` | Relay-owned rebuildable index state |
| `caches/<project-id>/` | Relay-owned rebuildable cache state |

Each JSON record contains the immutable `project_id`, display name, user-selected and last-resolved paths, file-resource identifier, Git common-directory fingerprint, primary or user-managed worktree kind, remote mode/ref metadata, availability, timestamps, and a bookmark reference. Bookmark bytes are never JSON. They use a generic-password Keychain item with service `com.relayrunner.project-bookmark` and account `<project-id>`.

Normal save is atomic. The first valid save establishes both primary and backup; later saves copy the valid current primary to backup before replacing it. Load prefers a valid primary, quarantines a corrupt primary before restoring a valid backup, and quarantines both unusable copies before creating a valid empty registry. If all app state is absent, load returns the same valid empty schema-2 document.

## Registration and recovery

Inspection is read-only. It resolves the selected directory and symlinks, runs only Git discovery commands, reads any committed `project_id` from `refs/heads/relay/artifacts`, and records no repository artifact. It never creates `.orchestrator`, writes a ref or remote, stages a path, or changes the source worktree.

Duplicate checks are intentionally layered: selected/resolved path, file-resource identifier, Git common directory, then committed project ID. A user-managed worktree may be the one registered primary location; another worktree with the same common directory is reported as a duplicate. Worktrees inside either Relay-owned `workspaces/` location are rejected, as are bare repositories.

Recovery keeps identity stable:

- A resolved moved or renamed bookmark updates only the last-resolved path and access metadata after its common directory or committed project ID matches.
- A missing path remains registered as `missing`; a missing `/Volumes/<name>` mount is `offline`.
- A missing, stale, revoked, or unreadable bookmark becomes `access_requires_regrant`. Stale bookmark bytes are never refreshed silently. Locate/regrant validates identity before explicitly replacing the Keychain item.
- A different common directory without the expected committed project ID becomes `identity_mismatch`.
- The selected path is retained separately from the canonical path, so symlink choices remain visible.

Legacy path records migrate in stable ID order. Existing artifact IDs are adopted; otherwise the legacy record ID deterministically derives an immutable v2 ID. Migration is idempotent, preserves the legacy file and active-project mapping, and marks accessible records for explicit access regrant rather than synthesizing a filesystem grant. Missing records remain in the registry for Locate or Remove.

Remove requires explicit confirmation. It unregisters the record, releases its Keychain access, and deletes only `indexes/<project-id>/` and `caches/<project-id>/`. It never edits or deletes repository files, `.orchestrator`, refs, remotes, the Git index, source history, or remote branches.

## Platform and provider behavior

Security-scoped bookmarks and Keychain persistence are intentional macOS-only implementation details. All project identity, duplicate, availability, migration, and removal semantics are provider-neutral: Codex and Claude use the same records and validation. Provider-specific executable discovery, authentication, model naming, and effort flags remain outside registry v2.

Targeted coverage is in `ProjectRegistryV2Tests`: disposable repositories verify source/index/ref/remote preservation, migration idempotency, corrupt-write recovery, duplicate layers, symlinks, bare and user/Relay worktrees, stale/missing/offline/moved access, identity-checked Locate, safe Remove, and the reversible rollout gate.
