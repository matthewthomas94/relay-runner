# macOS Permission Brokering

**Status:** Proposed next implementation step
**Ticket:** RR-134

Relay Runner should own the user's permission experience wherever macOS allows it. The app cannot silently grant TCC permissions, and some permissions are tied to the executable that touches the protected API. The design goal is therefore:

- centralize all checks, prompts, diagnostics, and recovery copy in Relay Runner;
- keep Codex and Claude on equivalent user-facing flows;
- be explicit when macOS requires the user to grant a terminal, IDE, native agent app, or helper binary instead of Relay Runner.

## Classification

| Classification | Meaning |
|---|---|
| Relay Runner-brokerable | The menu-bar app can request or register the permission for `com.relayrunner.app`, poll the result, deep-link to Settings, and recover without an agent-specific flow. |
| Helper-process-brokerable | A Relay Runner-owned helper can request/check the permission for its own stable signed identity if the app owns that helper's lifecycle and surfaces its status. This is viable only when the protected API runs in that helper. |
| Provider-specific | The user flow is shared, but launch commands, auth paths, bypass flags, or model/effort flags differ between Codex and Claude. This is not a macOS TCC distinction. |
| Unavoidable per-binary macOS state | macOS records the grant against the responsible executable or code signature that touches the protected API. Relay Runner can guide and diagnose it, but cannot collapse grants for Terminal, Codex.app, Claude.app, Warp, VS Code, worker CLIs, or other hosts into a single app toggle. |

## Current permission inventory

| Capability | Current owner/path | macOS surface | Classification | Notes |
|---|---|---|---|---|
| Voice capture | `PermissionsManager.requestMicrophonePrompt`, `STTEngine` | Microphone for `com.relayrunner.app`; usage string in `Info.plist` | Relay Runner-brokerable | Relay Runner can reset only its own Microphone entry with `tccutil reset Microphone com.relayrunner.app`, show the in-app prompt again, poll status, and recover STT after a grant. |
| TTS output | `tts_worker.py`, `preview_voice.py`, `afplay` | No TCC for local audio playback | Relay Runner-brokerable diagnostics | The app should report model/runtime/playback readiness, not ask for a privacy grant. |
| Playback controls and recording gestures | `CapsLockGesture`, `MediaController`, `PermissionsManager` | Input Monitoring for global key capture; optional Accessibility for media-key fallback | Relay Runner-brokerable | Input Monitoring enables non-Caps-Lock activation keys and the double-tap Shift board hotkey. MediaRemote usually avoids Accessibility; the fallback media-key path needs Relay Runner Accessibility. |
| Screen observation | `relay-vision-mcp` screenshot path and `PermissionPreflight.ensureScreenRecording` | Screen Recording | Unavoidable per-binary macOS state today; helper-process-brokerable only after an app-owned capture helper exists | The current MCP server runs inside the active agent session's process tree, so the grant may need to be applied to the terminal, IDE, Codex.app, Claude.app, or another parent. Screen Recording generally requires relaunching that host. |
| Screen manipulation | `relay-actions-mcp` click/type/key/scroll and AX window tools | Accessibility | Unavoidable per-binary macOS state today; helper-process-brokerable only after an app-owned action helper exists | CGEvent posting and AX reads are checked in the process that performs them. Relay Runner can open Settings and show the parent-app wizard, but the current action helper must still see its own responsible host as trusted. |
| App automation | Current product path is Relay Actions UI automation; no first-class Apple Events automation feature | Accessibility for UI automation; Apple Events only if future app-owned scripts target other apps | Unavoidable per-binary macOS state for agent-run automation; helper-process-brokerable for future app-owned automation | If future broker code sends Apple Events directly from Relay Runner or a signed helper, add the required usage description and track AppleEvents as that binary's TCC state. Agent-run `osascript` or provider tools remain per-host/per-binary. |
| Subprocess launch | `ProcessManager`, `scripts/relay-bridge`, launchd watchdog recovery | No privacy TCC for launching local subprocesses | Relay Runner-brokerable diagnostics; provider-specific launch rendering | Relay Runner can own executable discovery, PATH setup, venv install, launchd recovery, and clear errors. Codex and Claude differ in initial prompt/slash command shape, binary resolution, and bypass flag. |
| Worker execution | `services/orchestrator.py`, `services/orchestrator_workflow.md`, provider CLIs | No new Relay Runner app TCC; provider CLI auth and sandbox/approval flags | Provider-specific, plus unavoidable per-binary state for any worker tool that touches macOS-protected APIs | Codex uses `--dangerously-bypass-approvals-and-sandbox` and `model_reasoning_effort`; Claude uses `--dangerously-skip-permissions` and `--effort`. Those bypass agent prompts, not macOS privacy prompts. |

## Current gaps

The app already has `PermissionsManager` for Relay Runner app permissions, `ParentPermissionGuidance` for Codex/Claude parent targets, per-session parent onboarding, and MCP preflight messages that report missing parent grants back to the menu-bar app.

The remaining gap is that these pieces are not modeled as one brokered permission domain. Settings currently lists only Relay Runner app permissions, while parent-app Accessibility and Screen Recording live in onboarding/preflight flows. The user cannot see a single "why is screen control unavailable?" surface that combines:

- Relay Runner app grants such as Microphone and Input Monitoring;
- parent-host grants such as Accessibility and Screen Recording for Terminal, Codex.app, Claude.app, or a detected host;
- provider setup differences such as Codex/Claude auth, binary lookup, and bypass flag rendering;
- runtime readiness such as voice bridge, MCP registration, venv, and worker daemon state.

## Proposed implementation path

1. Add a `PermissionBroker` domain model in the app layer.
   - Represent each capability as a `PermissionRequirement` with id, display name, owner kind, current status, Settings action, verification method, recovery copy, and provider applicability.
   - Keep `PermissionsManager` as the source for Relay Runner app TCC state.
   - Add parent-app requirement rows driven by `ParentPermissionGuidance`, `ParentOnboardingTracker`, and `parent_permission_revoked` events from Relay Actions and Relay Vision.
   - Add non-TCC readiness rows for TTS playback, subprocess launch, MCP registration, and worker execution so they appear in the same diagnostics surface without being mislabeled as privacy grants.

2. Route onboarding and Settings through the broker.
   - First-run setup should show Relay Runner-brokerable requirements first: Microphone, optional Input Monitoring, local voice runtime, provider tool install, and provider sign-in.
   - Screen observation/manipulation requirements should be shown as parent-host requirements for both Codex and Claude. The content should use the same component and differ only in provider name and target app list.
   - Status Settings should add a "Screen Control" or "Agent Host Permissions" section showing the detected/current parent targets, last missing permission reported by MCP preflight, and the exact restart requirement for Screen Recording.

3. Preserve provider parity.
   - Codex and Claude both get the same broker requirement ids and status language for voice, hotkeys, parent Accessibility, parent Screen Recording, MCP registration, and workers.
   - Provider-specific rendering remains limited to known launch/auth differences: Codex native CLI path and initial prompt, Claude slash command path, Codex `model_reasoning_effort`, Claude `--effort`, and the existing bypass flags.
   - Any future provider must implement the same requirement set before it is treated as fully supported.

4. Keep per-binary limits visible.
   - The broker must never imply that granting Relay Runner Screen Recording fixes screenshots when the active MCP server is being evaluated as Terminal, Codex.app, Claude.app, or another host.
   - The UI should say "Grant Screen Recording to <host>, then quit and reopen <host>" for current agent-spawned Relay Vision.
   - If a future app-owned helper performs capture or CGEvents, that helper can move the row from "unavoidable per-binary" to "helper-process-brokerable", but the row should still name the helper's signed identity.

## Diagnostics surface

The broker should expose one computed list for UI and support logs:

| Field | Purpose |
|---|---|
| `id` | Stable requirement id, for example `relay.microphone`, `relay.inputMonitoring`, `parent.screenRecording`, `provider.auth`, `runtime.voiceBridge`, `worker.providerFlags`. |
| `owner` | `relayRunnerApp`, `relayHelper`, `parentHost`, `provider`, or `runtime`. |
| `classification` | One of the classification values above. |
| `provider` | `codex`, `claude`, or `all`. |
| `targetDisplayName` | The app or helper the user must grant, such as Relay Runner, Terminal.app, Codex.app, or Claude.app. |
| `status` | `granted`, `missing`, `deferred`, `restricted`, `needsRestart`, `notInstalled`, or `unknown`. |
| `action` | In-app request, open Settings pane, reinstall tools, retry setup, sign in, restart host, or no action. |
| `detail` | Short user-facing explanation that distinguishes privacy grants from runtime readiness. |

The same list can drive:

- onboarding step selection and resume state;
- Settings status rows;
- parent-permission recovery after MCP preflight reports a missing grant;
- support/export diagnostics without including raw Relay transcripts or command captures.

## Verification targets

- Fresh Codex setup with no grants: broker lists Microphone and Input Monitoring for Relay Runner, then parent Accessibility and Screen Recording for Codex.app and Terminal.app.
- Fresh Claude setup with no grants: same requirement ids and copy shape, with Claude.app and Terminal.app as the default parent targets.
- Detected non-default parent: broker replaces the default target list with the detected host for parent permission rows.
- Screen Recording grant path: row remains `needsRestart` until the granted host has been relaunched and Relay Vision preflight confirms capture.
- Worker run: provider flags are reported as provider setup/readiness, not as macOS privacy permissions.
- Logs and ticket/run prose contain refined status only; raw Relay command captures remain private runtime metadata.
