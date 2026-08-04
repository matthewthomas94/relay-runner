# Explicit project scope (registry v2)

This is RR-273 phase 2 and implements the [RR-270 work-scope state machine](../investigations/RR-270-repo-local-retention-and-scope.md#work-scope-state-machine). It is enabled with `RELAY_RUNNER_REGISTRY_V2=1`; disabling that gate restores legacy Workspace routing without deleting registry-v2 records or access grants.

## Workspace and project management

Workspace is an application-global surface backed by `registry-v2.json`. It opens before a bridge or provider process exists. An empty registry is valid and shows only **Add Existing Project** and **Create Project** filesystem entry points. Ordinary Workspace opening never presents a folder picker and never treats `general.working_directory`, bridge cwd, the application-support home, or a nearby repository as mutation authority.

Add Existing validates an already initialized Git worktree before registration. Create makes a new directory, initializes one Git repository, and registers it; a failed registration rolls back only the directory that operation created. Settings replaces the Workspace-folder identity preference with the registered project list, availability refresh, Locate/Regrant, explicit safe Remove, Add, and Create. Remove releases Relay-owned access/cache state while leaving the repository, refs, remotes, and artifact history untouched.

Onboarding no longer requires a folder or project when the gate is enabled. A user may finish setup, open an honest empty Workspace, and add a project later.

## Confirmation state machine

Project resolution has two deliberately separate states:

1. **Unscoped conversation.** No mutation owner exists. Cwd, bridge cwd, recent use, and voice text may populate `suggestedProjectID`, but cannot authorize work.
2. **Suggested.** The UI or conversation can present a registered candidate. Starting work still fails closed.
3. **Confirmed.** Explicit selection issues a versioned `ConfirmedProjectScopeToken` containing the immutable project ID, registry schema, canonical repository path, Git-common-directory fingerprint, registry-record timestamp, and issue timestamp.
4. **Inherited.** Follow-up work in the same provider thread may reuse that token only while it validates against the current registry record.
5. **Redirected.** Explicitly choosing another available registered project replaces the inherited token.
6. **Canceled or invalidated.** Explicit cancel, project removal, unavailable/revoked access, identity mismatch, path change, record update, or schema change revokes inheritance. Mutation entry points must request a new confirmation.

`ProjectRegistryV2Service.validateScopeToken` is the common fail-closed check. A token cannot target Relay Runner's application-support tree. `ProcessManager.prepareNewSession` also requires the requested cwd to equal the validated registered path. App-owned launches export the same `RELAY_PROJECT_SCOPE_TOKEN`, `RELAY_PROJECT_ID`, and `RELAY_PROJECT_SCOPE_VERSION` for both providers.

## Provider parity and intentional differences

Codex and Claude share project selection, token encoding, validation, inheritance, redirect/cancel, unavailable-project outcomes, and actual launch cwd. Cwd is never inferred differently by provider. Intentional differences remain limited to provider executable discovery, authentication, CLI model/effort flags, and the provider command itself.

## Mutation boundary

Phase 2 supplies the token contract used by later artifact writer, sync, archive/restore, worker lifecycle, Program export, and migration entry points. Until those phases opt in, their legacy paths remain behind their own gates; they must not treat the presence of a cwd as confirmation. Existing voice intent disposition remains unchanged: project-free conversation is allowed, a work intent without valid scope fails closed, and canceling one intent does not discard unrelated accepted work.

## Verification and rollback

Deterministic coverage exercises empty/no-bridge routing, add/create/remove, moved/offline/stale grants, application-home rejection, suggestion versus confirmation, follow-up inheritance, redirect/cancel, stale identity, and equivalent Codex/Claude environment plus cwd behavior. Installed acceptance additionally checks that ordinary Workspace opening does not show a picker and captures the selected project ID and real provider cwd.

Rollback disables `RELAY_RUNNER_REGISTRY_V2`. It does not delete registry-v2 state or modify any registered repository.
