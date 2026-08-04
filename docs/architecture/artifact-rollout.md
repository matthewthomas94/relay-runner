# Artifact installed verification and staged rollout

RR-289 implements phase 9 of the
[RR-270 verification and rollout design](../investigations/RR-270-repo-local-retention-and-scope.md#verification-strategy).
It does not turn source-test success into a rollout decision. The source harness,
signed installed evidence, cohort acceptance, and cohort promotion are separate
records and separate operator actions.

## Current release boundary

The only initially available cohort is explicit per-project opt-in. Every project
still defaults off through `artifact_lifecycle = "legacy"`; choosing artifact
ownership for one confirmed project changes only that project's config and does
not affect another project. The phase-9 rollout policy adds a local control plane
under:

```
~/Library/Application Support/relay-runner/rollout/
  artifact-rollout-v1.json
  artifact-rollout-v1.backup.json
  artifact-rollout-v1.lock
```

The policy file is app-local operational state, not project truth and not a Git
artifact. It contains cohort switches, explicit project opt-in decisions, and
bounded evidence identifiers/hashes. Repositories, artifact refs, migration
journals, registry backups, and evidence files remain intact when a cohort is
paused or rolled back.

For projects enabled before this control plane existed,
`artifact_lifecycle = "enabled"` is the durable compatibility opt-in. The daemon
re-evaluates that configured opt-in against the `project_opt_in` cohort on every
artifact lifecycle lookup, including cached coordinators. An explicit policy
`opt-out` record takes precedence over the repository config; it cannot be
silently undone by a daemon restart or by falling back to the legacy writer.

Two later cohorts begin disabled:

1. `new_project_default` can affect newly registered projects only. It never
   changes an existing or legacy project.
2. `legacy_migration_offer` can expose an explicit migration offer only. It does
   not migrate or start artifact writes by itself.

Promotion is never automatic. `new_project_default` requires accepted source,
two-device, failure-injection, signed installed Workspace, installed provider
parity, fresh-install/reset, operator-recovery, and opt-in-cohort evidence.
`legacy_migration_offer` additionally requires accepted migration/rollback and
new-project-cohort evidence. A later rejection supersedes an older acceptance
until a new immutable acceptance record is reviewed.

Inspect the bounded state with:

```bash
scripts/relay-artifact-rollout status
```

The daemon exposes the same project-name-free diagnostics at
`GET /v1/artifacts/rollout`. Diagnostics contain cohort states, counts, stable
failure codes, and evidence hashes only. They reject raw logs, transcripts,
audio, prompts, tool output, hidden reasoning, secrets, and unbounded strings.

## Independent kill switches and rollback

Each cohort has independent write and sync switches. Pausing requires positive
proof that writers drained and synchronization froze safely:

```bash
scripts/relay-artifact-rollout pause \
  --cohort project_opt_in \
  --reason-code cas_failure \
  --writers-drained \
  --sync-frozen
```

The switch prevents new work. It never resets a project, deletes a local or
remote ref, rewrites history, removes a remote, discards unpublished commits, or
erases conflict evidence. Resume is a distinct confirmed action after recovery.
Disabling one project's opt-in has the same drain/freeze rule and preserves its
canonical artifact history and materialization for explicit recovery.

The daemon enforces the write decision before returning an artifact lifecycle
coordinator. A blocked decision raises its stable rollout reason instead of
returning `None`, because `None` would activate the legacy direct-file writer.
Artifact HTTP mutations return that reason and bounded recovery action as a
`409` response rather than reducing the gate to an opaque server error.
The same policy decision disables artifact synchronization while the cohort is
paused. A focused daemon test pauses an already-cached configured project,
attempts a board claim, and proves the artifact ref does not move.

If policy JSON is corrupt, a valid backup is used with a visible recovery state.
Diagnostics may inspect that backup, but new starts remain blocked with
`rollout_state_recovery_required` until a reviewed repair. If both copies are
invalid, all new starts fail closed with `rollout_state_corrupt`. Stop writers,
restore a reviewed backup, and explicitly resume; do not synthesize an empty
enabled policy.

## Automated source gate

Run the production harness from a checkout or from the installed bundle:

```bash
scripts/relay-artifact-verify source-harness
```

It creates a temporary bare remote and disposable device-A/device-B clones. The
harness proves:

- unrelated offline ticket events replay and normal-push cleanly;
- same-ticket, config, and same-name attachment conflicts stop with deterministic
  three-way evidence and publish nothing until explicit resolution;
- every observed push has one destination,
  `refs/heads/relay/artifacts`, and no force, delete, mirror, all-refs, or source
  publication option;
- source HEAD, non-artifact refs, index bytes, dirty/staged/untracked files,
  ordinary local-ahead work, configured remotes, and the remote source branch
  remain unchanged;
- a push race retries once, retains one immutable event, and never recurses;
- a crash after artifact-ref publication recovers on restart, stale CAS and
  materialization divergence stop, and retry is idempotent; and
- Codex and Claude produce identical artifact file snapshots. Their only
  intentional differences remain executable discovery, authentication, model
  name, and effort flag rendering.

From a checkout, the harness also audits the complete RR-270 source fixture
manifest so a renamed or removed test cannot silently shrink the release gate.
The installed bundle deliberately does not ship test sources, so its report marks
those entries `external_source_report_required`; pair it with a reviewed checkout
report. The full required source commands remain:

```bash
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
swift test
```

These suites cover exact UTC age boundaries, every active exemption,
archive/restore/dependencies, missing objects, allowlist/privacy/size failures,
registry corruption and access recovery, migration interruption/rollback,
fresh-install/reset, worker/reviewer merge failures, and provider parity. A
passing source report can be recorded as `source_matrix`, `two_device_remote`,
and `failure_injection` evidence, but it cannot satisfy any installed evidence
kind or promote a cohort.

## Signed installed two-device gate

The installed gate accepts only the exact Developer ID Application signed app at
`/Applications/Relay Runner.app`. A Team ID and non-ad-hoc signature alone are
insufficient: Apple Development, Apple Distribution, and other certificate
authorities are rejected. Ad-hoc signatures, invalid nested signatures, another
bundle identifier, a source-build path, and evidence for another bundle hash
fail closed.

First inspect the installed identity and create a bounded evidence template:

```bash
scripts/relay-artifact-verify inspect-installed
scripts/relay-artifact-verify installed-template \
  --output /private/tmp/rr-289-installed-evidence.json
```

On two distinct devices, fill the template with only hashed device/evidence IDs,
bounded OS versions, and `passed` or `failed` outcomes. Do not add paths,
screenshots, logs, transcripts, raw CLI output, credentials, or free-form notes.
Across the two records, the exact signed bundle must pass:

- empty Workspace;
- Add, Create, and Remove project;
- filesystem grant and revocation;
- moved and offline project recovery;
- explicit session scope;
- archive/history/restore;
- conflict UI;
- preserving fresh install and recoverable reset;
- mounted Workspace interactions; and
- dirty source isolation.

Codex and Claude must both pass the same installed scope, artifact snapshot,
lifecycle, conflict, and recovery outcomes. The manifest separately records the
four intentional provider differences listed above. Evaluate it with:

```bash
scripts/relay-artifact-verify evaluate-installed \
  --evidence /private/tmp/rr-289-installed-evidence.json
```

One device, a missing scenario, one provider, a failed outcome, an app/hash/team
mismatch, or an unsupported evidence field yields `verification_blocked` with
stable blocker codes and this resume condition: install the exact Developer ID
signed build on two devices and record every missing mounted Workspace and
provider scenario in one bounded evidence manifest.

## Recording and promoting evidence

Rollout evidence uses immutable IDs and an exact field allowlist. Each record
contains a kind, accepted/rejected outcome, UTC timestamp, report hash, optional
signed bundle identity, provider IDs, bounded scenario IDs, and a rejection code.
It contains no evidence body. Record a reviewed object with:

```bash
scripts/relay-artifact-rollout record-evidence \
  --file /private/tmp/rr-289-rollout-evidence.json
```

Recording all requirements still changes no cohort. After an external review
accepts the opt-in cohort, explicitly promote the next cohort:

```bash
scripts/relay-artifact-rollout promote \
  --cohort new_project_default \
  --confirm
```

Legacy projects remain unchanged. Only after separate new-project acceptance and
migration/rollback evidence may an operator explicitly promote the legacy offer.
The journaled migration itself still requires its own project/path/remote review
and confirmation.

## Fresh install, reset, and recovery ownership

Normal reinstall uses `scripts/relay-runner-fresh-install` and byte-verifies the
replacement app while proving app support and registered repository source state
are unchanged. Deliberate reset requires stopped writers and no active/reviewing
runs, moves only Relay-owned app state to Trash, and writes an exact recovery
manifest. It never edits a registered repository. Re-registration recovers board
truth from the project's preserved local/configured artifact ref; remote first
push, migration, and source cleanup remain explicit operations.

## Deviations and rejection reasons

- The automated remote is a local disposable bare Git remote so the source gate
  is deterministic and cannot touch user or GitHub state. This does not replace
  signed installed authentication/offline testing; that evidence remains gated.
- Mounted AppKit interaction, security-scoped filesystem grants, TCC revocation,
  actual provider authentication, and a second physical device cannot be proven
  by source suites. Treating mocks or source success as that evidence is rejected.
- A Developer ID signed but non-installed bundle is rejected because TCC,
  launch-agent, and mounted Workspace behavior depend on installed identity.
- Provider executable/auth/model/effort differences are documented rather than
  forced into false byte parity. Scope, snapshots, events, conflicts, completion,
  and recovery may not differ.
- Rollback never auto-deletes artifact refs or remote branches. Recoverability and
  immutable event reconciliation take precedence over making rollback look clean.

Until the signed installed two-device manifest passes and is externally accepted,
RR-289 remains `verification_blocked`; RR-273 must not be marked done and neither
later cohort may be enabled.

The current source results and exact installed blocker are recorded in
[RR-289 verification](../verification/RR-289-artifact-rollout.md).
