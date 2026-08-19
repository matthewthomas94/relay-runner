# Relay artifact synchronization

This is RR-273 phase 4 and implements the [RR-270 synchronization state machine](../investigations/RR-270-repo-local-retention-and-scope.md#synchronization-state-machine). The implementation is `services/artifact_sync.py` and the canonical local writer remains `services/artifact_store.py`.

## Explicit setup and identity

Synchronization is opt-in per project. A project configuration records either `remote_sync = "local_only"` with no remote, or `remote_sync = "enabled"` with the exact name of an already configured Git remote. Relay never guesses, adds, renames, or rewrites remotes. A missing remote artifact ref requires a separate confirmed first normal push; Local only performs no network operation.

Retention publication has a stricter prepared-commit entry point. It leaves the local artifact authority unchanged, revalidates and uses the exposure-confirmed push URL for one exact artifact refspec, then performs a second quarantine fetch and verifies caller-supplied source-commit/path/blob/SHA-256 proofs. Push success alone is never durability evidence. Fresh- and second-device recovery likewise fetch only the configured artifact ref, validate a caller-supplied retention-layout predicate before adoption, and refuse to replace an existing unowned or manually edited materialization or overwrite divergent local artifact history.

Remote inspection happens in a temporary bare quarantine repository. Relay fetches exactly `refs/heads/relay/artifacts`, without tags, source refs, pull-request refs, or submodules, then verifies orphan-rooted linear history, the path and mode allowlist, canonical content, and the immutable project ID. Only verified artifact objects are imported through a temporary local scratch ref. A foreign or mislabeled ref is rejected before its ordinary source history can enter the source repository's object database.

## State machine

The provider-neutral states are Local only, Paused, Clean, Ahead, Behind, Syncing, retryable Offline, retryable Authentication, Missing remote ref, Protected ref, Foreign ref, Local ahead fail-closed, Conflict, and Failed. Results include the observed state, bounded transition history, attempt count, local and remote heads, and a user-safe recovery action. Codex and Claude receive the same result; provider attribution does not affect synchronization policy.

Offline and authentication failures retain unpublished local artifact commits. Retry uses exponential delay with jitter and a strict attempt cap. A push race re-enters exact fetch/verification/rebase, while immutable event IDs and compare-and-swap local ref updates prevent duplicated logical events.

## Publication invariants

Relay publishes only an already verified artifact commit with the normal refspec `<commit>:refs/heads/relay/artifacts`. There is no force, force-with-lease, destructive reset, remote deletion, or source refspec. The artifact writer lock spans local relationship checks, unpublished rebase, compare-and-swap updates, publication, and rematerialization. Source HEAD, source refs, branch or detached state, user index, staged/unstaged/untracked files, ordinary local-ahead commits, and configured remotes are outside this state machine.

When both artifact histories advanced, Relay replays only commits carrying the same project ID plus complete Relay event/digest/device/actor trailers. Already-published event IDs with the same digest are skipped; a mismatched digest stops. Unowned or malformed local-ahead commits fail closed.

Unrelated path changes replay automatically. Same-ticket, display-ID, config, attachment-name, delete/edit, and event-ID collisions return deterministic base/local/remote blob evidence. Resolution requires a choice for every conflicting path—local, remote, delete, or reviewed canonical bytes—and creates a new ordinary commit descending from the verified remote head. Resolution records the reconciled event IDs and digests so retrying an original event remains idempotent. Unrelated artifact roots require a separately reviewed identity recovery and cannot be resolved through the ordinary path chooser.

## Recovery and rollback

Switching a project to Local only stops network access while preserving its artifact ref, pending commits, materialization, conflict evidence, and Git remote configuration. A failed push never discards the local candidate. If a replay changes the local artifact ref before an offline or rejected push, Relay immediately rematerializes that local head so the projection and canonical ref remain consistent. No rollback path rewrites published history.

Disposable two-device tests cover initial publication, clean/ahead/behind/diverged transitions, unrelated offline rebase, all conflict classes, explicit resolution, source isolation, push races, bounded retry, missing/protected/auth/offline classification, foreign-ref quarantine, and Codex/Claude-equivalent snapshots.

RR-289 adds a production disposable harness and signed installed gate in
[Artifact installed verification and staged rollout](artifact-rollout.md).
