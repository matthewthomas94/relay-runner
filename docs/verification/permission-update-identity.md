# Permission identity across app updates

Inline fix verified on 2026-09-15.

## Changes

- Local packaging selects the same Developer ID team as public releases instead
  of silently falling back to an ad-hoc signature on every rebuild.
- Packaging and preserving reinstall validate the release signature. Before
  replacing an installed app, they also evaluate its designated requirement
  against the new app. Incompatible replacements stop before changing the app.
- Ad-hoc test artifacts require an explicit opt-in and cannot refresh the
  installed app. Tagged release builds require the fixed release identity.
- Permission setup refreshes the macOS status and completes immediately when
  permission is already granted. Actual revocation still requires setup.
- The behavior is shared by Codex and Claude; permission ownership stays in the app.

## Verification

- Reproduced redundant requests with two failing Swift tests before the fix.
- Passed 93 Swift permission, onboarding, and updater tests, plus 44 Python
  signing, preserving-install, bundled-service, and release-documentation tests.
- Real macOS signing experiment: two different Developer ID builds passed the
  same permission requirement; an ad-hoc replacement was rejected.
- Default local release build selected the existing Developer ID automatically.
  The full signed app, DMG, and ZIP built successfully. No public release was made.
- The installed replacement satisfied the previous installed app's designated
  requirement and matched the built executable SHA-256:
  `72b9bf19022a3ddc7567af85c995d0ce98e082991a568c772afee1fe4e024566`.
- Preserving installer reported unchanged app state and both registered
  repositories, and retained the previous app in Trash. Relaunched app PID was
  `85409`; the orchestrator health endpoint returned `ok: true`.
- Fresh app-reported permission status before and after replacement was
  Microphone `granted`, Accessibility `denied`, Screen Recording `denied`.
  Microphone retention is verified. Retention of granted Accessibility and
  Screen Recording, and a public Sparkle update, still require separate UAT.

The local build is Developer ID signed but was not notarized. Previously lost
grants cannot be recreated by preserving the signing identity; macOS may need
one final user approval when moving from an old ad-hoc install.
