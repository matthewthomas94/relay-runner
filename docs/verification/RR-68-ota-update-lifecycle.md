# RR-68 OTA Update Lifecycle Verification

This checklist covers the signed Sparkle path that unit tests cannot fully
exercise locally. Run it before promoting the first OTA release and whenever
packaging, helper binaries, service launchers, or Sparkle metadata changes.

## Preconditions

- Two signed and notarized release builds exist with increasing
  `CFBundleVersion` values.
- The production `SPARKLE_ED_PRIVATE_KEY` matches the committed
  `SUPublicEDKey` in `Info.plist`.
- The old version is installed as `/Applications/Relay Runner.app`, not run
  from a DMG, Downloads, or an app-translocated path.
- At least one Codex session and one Claude session can be started from Relay
  Runner on the test machine.

## Automated Checks

Run these before manual OTA testing:

```bash
plutil -lint Info.plist
bash -n scripts/build-dmg.sh
bash -n scripts/generate-appcast.sh
ruby -e 'require "psych"; Psych.load_file(".github/workflows/build-dmg.yml")'
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/build-instructions --check
```

When validating a signed archive locally, also run `scripts/build-dmg.sh` with
the release signing environment and run `scripts/generate-appcast.sh` with a
matching Sparkle private key. `generate-appcast.sh` must fail if the archive is
missing, unsigned, or signed with a private key that does not match
`SUPublicEDKey`.

## Old To New OTA Flow

1. Install the old `RelayRunner.dmg`, then launch
   `/Applications/Relay Runner.app`.
2. Confirm the running app is the installed bundle:

   ```bash
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Relay Runner.app/Contents/Info.plist'
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Relay Runner.app/Contents/Info.plist'
   codesign -dv --verbose=4 '/Applications/Relay Runner.app' 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
   ```

3. Start a Codex session from Relay Runner, then end it. Start a Claude
   session from Relay Runner, then leave it active for the update test.
4. Use "Check for Updates..." from the Relay Runner menu. Accept the update.
5. After Sparkle relaunches the app, repeat the plist and `codesign` checks.
   The bundle identifier and Developer ID team must be unchanged, and
   `CFBundleVersion` must be the new value.
6. Confirm the app relaunched from `/Applications`:

   ```bash
   ps -o command= -p "$(pgrep -x relay-runner)"
   ```

## Bundled Service Checks

After update and relaunch:

1. Confirm the old voice bridge was stopped during Sparkle relaunch:

   ```bash
   pgrep -fl 'voice_bridge.py' || true
   ```

2. Start a fresh Codex session and confirm the bridge uses the new bundle:

   ```bash
   cat /tmp/voice_bridge.provider
   ps -o command= -p "$(pgrep -f 'voice_bridge.py')"
   ```

   The provider should be `codex`, and the command should reference
   `/Applications/Relay Runner.app/Contents/SharedSupport/services/voice_bridge.py`.

3. Repeat with Claude. The provider should be `claude`; the service path should
   still resolve under the new `/Applications/Relay Runner.app` bundle.
4. Check MCP registrations for both providers:

   ```bash
   claude mcp get relay-actions
   claude mcp get relay-vision
   claude mcp get relay-orchestrator
   codex mcp get relay-actions
   codex mcp get relay-vision
   codex mcp get relay-orchestrator
   ```

   Each registered command should point into
   `/Applications/Relay Runner.app/Contents/MacOS/`.

## Orchestrator Stale Service Recovery

Relay Runner reuses `relay-orchestrator --restart-if-idle` for an already
installed orchestrator launch agent after app launch and when the Program Board
detects an old schema. That preserves the RR-60 stale schema recovery path
instead of adding a second daemon manager.

1. With no active workers, relaunch Relay Runner after OTA and inspect
   `/tmp/relay_orchestrator.log`. It should show the daemon restarting or
   serving from the new bundle path.
2. With an active Codex worker, relaunch Relay Runner after OTA. The menu should
   show that bundled service refresh was deferred until active workers finish.
   The worker should continue using its existing worktree.
3. Repeat with an active Claude worker. The behavior is intentionally the same:
   active workers defer the launchd orchestrator restart, regardless of
   provider.
4. After workers finish, quit and reopen Relay Runner or open the Program Board
   to trigger the stale-schema refresh path. The daemon should then resolve
   `services/orchestrator.py` from the new app bundle.

## TCC Attribution

Sparkle replacement must preserve the bundle identifier, signing team, and
helper placement:

```bash
codesign -dv --verbose=4 '/Applications/Relay Runner.app/Contents/MacOS/relay-actions-mcp' 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
codesign -dv --verbose=4 '/Applications/Relay Runner.app/Contents/MacOS/relay-vision-mcp' 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
```

Relay Actions and Relay Vision helpers must remain inside
`Contents/MacOS/` so Screen Recording and Accessibility prompts are attributed
to Relay Runner rather than a loose helper binary. Codex and Claude sessions
both use the same helper paths; provider-specific launch syntax does not change
TCC attribution.

## Failure Modes

- Running from DMG or app translocation: Relay Runner shows the installer flow
  and does not start Sparkle. Install to `/Applications` first.
- Running from Downloads or another non-installed app bundle: the update menu
  logs that Sparkle is unavailable outside the installed app.
- Missing appcast: Sparkle shows its normal update failure UI; Relay Runner logs
  the Sparkle error.
- Unsigned archive or Sparkle key mismatch: appcast generation or Sparkle
  validation fails before install. Regenerate the archive with the matching
  EdDSA key.
- Active voice session: Sparkle relaunch stops `voice_bridge.py` so stale
  service code does not keep running indefinitely. The Codex or Claude terminal
  remains open, but the user must start a new Relay session after relaunch.
- Active orchestrator workers: restart is deferred and surfaced in the menu.
  Finish the workers, then quit and reopen Relay Runner or open Program Board
  to retry stale-daemon recovery.
