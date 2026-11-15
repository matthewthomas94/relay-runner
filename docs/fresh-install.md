# Fresh-install and clean-user validation

## Preserving app replacement

For a normal update, build with Relay Runner's Developer ID certificate, then
preview and execute the replacement:

```bash
RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh
scripts/relay-runner-fresh-install --app 'dist/Relay Runner.app'
scripts/relay-runner-fresh-install --app 'dist/Relay Runner.app' --execute
```

Quit the app and stop idle bundled services before replacement. Preflight checks
the new app's signature against the release identity and the installed app's
designated requirement. Incompatible or ad-hoc updates are rejected before any
replacement; normal installs preserve Relay state and repositories and retain
the old app in Trash for rollback. See [permission identity details](release-updates.md#preserve-permissions-across-updates).

## Deliberate state resets

`scripts/relay-runner-fresh-install` has three deliberately narrow reset
profiles. Running a profile without `--execute` is a read-only inventory. An
execution needs both `--confirm-daemon-stopped` and the exact profile repeated
in `--confirm-profile`; every moved item is retained in a timestamped Trash
directory with `reset-recovery.json` for recovery.

| Profile | What it can reset | What it deliberately leaves alone |
| --- | --- | --- |
| `relay-owned` | Relay Application Support, Relay preferences/cache, its orchestrator launch agent, and the named Relay temporary artifacts | Repositories, developer build state, credentials, provider directories, and non-Relay temporary files |
| `voice-models` | Only the two Kokoro model files Relay downloads | The containing directory, Hugging Face cache, Python environments, and other models |
| `provider-integrations` | Named Relay bridge/stop/dispatch/workflow entries for both Codex and Claude | `~/.codex`, `~/.claude`, credentials, global configuration, caches, and repositories |

For example, preview and then execute only the Relay-owned profile:

```bash
scripts/relay-runner-fresh-install --reset-profile relay-owned
scripts/relay-runner-fresh-install --reset-profile relay-owned --execute \
  --confirm-daemon-stopped --confirm-profile relay-owned
```

Restore a completed profile only while Relay writers remain stopped:

```bash
scripts/relay-runner-fresh-install --restore-profile \
  "$HOME/.Trash/relay-runner-relay-owned-.../reset-recovery.json" --execute \
  --confirm-daemon-stopped --confirm-profile relay-owned
```

These profiles cannot recreate a new macOS user. TCC permissions, Keychain
entries, notification authorization, Gatekeeper/quarantine decisions, and
shared machine dependency caches must be assessed in a clean user or VM.

## Evidence capture

After an install and first launch, record only installation metadata and an
optional checksum of an already-created incident/support bundle; it never reads
or embeds source content:

```bash
scripts/relay-runner-fresh-install --capture-evidence /tmp/relay-first-run.json \
  --app "/Volumes/Relay Runner/Relay Runner.app" \
  --installer-context "DMG mounted" --startup-outcome "onboarding shown" \
  --incident-bundle /tmp/relay-support.zip
```

The report includes the app identifier/version/manifest digest, the `relay-rs`
version that wrote it, the startup outcome, and the support bundle's
filename/size/checksum. Inspect the
support bundle before sharing it.

## Second-Mac clean-user procedure

1. Keep an untouched administrator account for recovery; do not run the test
   from it. Create a disposable standard macOS user and sign into that user.
2. Install the reviewed DMG in the disposable account. Record installer context
   and app version, then complete onboarding and the first Workspace setup.
3. Check the requested system prompts and first-run behavior. Test both Codex
   and Claude setup states independently: absent/unconfigured, then the
   account-specific sign-in or CLI state needed by that provider. Do not copy
   credentials from the administrator account.
4. Create any incident/support bundle, run the evidence capture command, and
   retain the report outside the disposable home if it is needed for review.
5. Sign out, return to the administrator account, and remove the disposable
   user **with its home folder** through System Settings. Confirm the retained
   administrator account still opens normally.

A VM snapshot taken before step 1 is an equivalent, faster reset path. Revert
the snapshot for another first-run pass, but still record physical-Mac checks
when Gatekeeper, device permissions, or hardware audio behavior are in scope.

## Runtime

Relay Runner runs no Python (RR-487). Every service is a native binary the app
bundle ships in `Contents/MacOS`, for Claude and Codex sessions alike, so a Mac
needs neither Python nor the Xcode Command Line Tools for Relay Runner itself.
Project and worker features still run `git`; on a Mac without the Command Line
Tools, macOS offers to install them the first time `git` runs.

| Binary | Runs |
| --- | --- |
| `relay-rs` | The voice bridge (`relay-rs bridge`), the messenger, Relay Remote, the provider hook and reply helper, the Claude subscription gate, Codex model resolution, the harness updater, and the CLIs behind `scripts/relay-ticket-history`, `relay-artifact-*`, `relay-runner-fresh-install` and `relay-work-style` |
| `relay-speech` | Speech: the voice bridge, the onboarding tutorial voice and the Settings voice preview all start it (RR-481) |
| `relay-orchestrator` | The orchestrator daemon, run by the `com.relay.orchestrator` LaunchAgent (RR-500) |

First-run setup (onboarding, Start Session, or
`scripts/relay-bridge --setup-only`) downloads the two Kokoro model files to
`~/.local/share/kokoro` over plain HTTPS with `curl`, installs the Relay skills
and MCP registrations, and installs the orchestrator LaunchAgent. It creates no
virtual environment and installs no packages. `scripts/build-dmg.sh` refuses to
package a bundle that contains a `.py` file.

The one-release rollback switches `RELAY_HOOK_RUNTIME`, `RELAY_SPEECH_RUNTIME`,
`RELAY_BRIDGE_RUNTIME`, `RELAY_MESSENGER_RUNTIME`, `RELAY_REMOTE_RUNTIME` and
`RELAY_ORCHESTRATOR_RUNTIME` are retired and no longer read. If one was set
with `launchctl setenv`, clear it with `launchctl unsetenv <name>`.

## Upgrading from a release with Python services

Releases before RR-487 created a Python virtual environment and could download
a Python interpreter. On an upgraded Mac, the first setup run of the new
release (onboarding, the next Start Session, or `relay-orchestrator --install`)
removes only these Relay-owned folders, and only once no process still runs
from them:

- `~/Library/Application Support/relay-runner/services/.venv` (and the
  `services` folder if it is then empty)
- `~/Library/Application Support/relay-runner/python` and any leftover
  `python.old` or `.python-stage.*` from an interrupted download

Everything else is kept and read unchanged by the Rust services: settings
(`config.toml`), the project registry, tickets (in each project's
`.orchestrator/` and `relay/artifacts` ref), the run ledger and other
orchestrator databases, notes, Relay Remote paired devices, installed skills,
and the Kokoro model cache in `~/.local/share/kokoro`, which `relay-speech`
uses as is. Homebrew, system or other Python installations are never touched.

A Python voice bridge or daemon left running by the previous release is
stopped by the normal session start and by the LaunchAgent restart that setup
performs, so the new binaries take over without a reboot.
