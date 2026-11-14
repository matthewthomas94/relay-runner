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

The report includes the app identifier/version/manifest digest, Python runtime,
startup outcome, and the support bundle's filename/size/checksum. Inspect the
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

## Speech runtime

Speech runs in `relay-speech`, the Rust speech service the app bundle ships in
`Contents/MacOS` (RR-481). The voice bridge, the onboarding tutorial voice and
the Settings voice preview all start it. First-run setup therefore installs
only `services/requirements.txt` into the services venv, and downloads the two
Kokoro model files to `~/.local/share/kokoro` over plain HTTPS with `curl`. A
fresh install no longer installs numpy, onnxruntime, kokoro-onnx or
huggingface_hub.

For one release, the Python speech service remains available as a fallback.
Set `RELAY_SPEECH_RUNTIME=python` in the app's environment, then relaunch the
app and start a session:

```bash
launchctl setenv RELAY_SPEECH_RUNTIME python
```

The next setup run (onboarding, or `scripts/relay-bridge --venv-only`) then
also installs `services/requirements-python-speech.txt`: numpy, onnxruntime,
kokoro-onnx and huggingface_hub, with their espeak-ng based phonemiser. Those
packages are installable only for this fallback. Undo it with
`launchctl unsetenv RELAY_SPEECH_RUNTIME`. A build without `relay-speech`, such
as a source checkout, also uses the Python service and needs those packages,
unless `RELAY_SPEECH_BINARY` names a `relay-speech` built from `rust/`. The
fallback is removed one release after the Rust service ships.

## Voice bridge runtime

The voice bridge runs as `relay-rs bridge`, the Rust bridge the app bundle
ships in `Contents/MacOS` (RR-493), for Claude and Codex sessions alike. For
one release, the Python bridge remains available as a rollback. Set
`RELAY_BRIDGE_RUNTIME=python` in the app's environment, then relaunch the app
and start a session:

```bash
launchctl setenv RELAY_BRIDGE_RUNTIME python
```

`scripts/relay-bridge` then runs `services/voice_bridge.py`; the bridge log
(`/tmp/voice_bridge.log`) names the runtime each launch used. Undo it with
`launchctl unsetenv RELAY_BRIDGE_RUNTIME`. A build without `relay-rs`, such as
a source checkout, also runs the Python bridge. The switch is independent of
`RELAY_SPEECH_RUNTIME` and `RELAY_HOOK_RUNTIME`. The rollback is removed one
release after the Rust bridge ships.
