# Testing Relay Runner

Run tests from the repository root on macOS 14 or later. Xcode 16 or later is required because the resolved FluidAudio package uses Swift 6 tooling.

## Fast checks

```bash
git diff --check
scripts/build-instructions --check
swift test
python3 -m unittest discover -s tests
```

Use a Python 3.10–3.13 interpreter. The app can install its own runtime for end users, but contributor tests should not mutate the installed app or the user's Relay Runner Application Support state.

Run one Python file while iterating with:

```bash
python3 -m unittest tests.test_config
```

Run one Swift test class or method with Swift Package Manager's `--filter` option.

## Clean build

```bash
swift package resolve
swift build
swift test
```

The Swift suite uses disposable fixtures for permission, registry, terminal, and orchestration behavior. Tests must not depend on an installed proprietary font; the app falls back to system typography when optional PP font faces are unavailable.

## Package the app

Install `dmgbuild` into a Python interpreter the script can discover:

```bash
python3 -m pip install --user --break-system-packages dmgbuild
RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh
```

The packaging command must produce:

- `dist/Relay Runner.app`
- `dist/RelayRunner.dmg`
- `dist/RelayRunner.zip`

It verifies the app's nested code signatures and archive shape. Without `SIGN_IDENTITY` and `NOTARY_PROFILE`, the result is an ad-hoc-signed local artifact and does not prove Developer ID or notarization behavior. Maintainers verify public artifacts through the tag workflow and the checklist in [Release updates](docs/release-updates.md).

## Installed and permission-dependent checks

Unit tests and a source build cannot prove macOS TCC or mounted UI behavior. Changes involving Microphone, Accessibility, Input Monitoring, Screen Recording, hotkeys, audio playback, the embedded terminal, onboarding, Sparkle, or the mounted Workspace need an installed-app check.

Record the exact evidence obtained. For audio, a queued or accepted event is not audible proof; playback must reach its terminal played state. If Screen Recording or another external permission is unavailable, preserve the blocker instead of claiming the visual check passed.

Codex and Claude should receive equivalent checks for shared session, scope, voice, MCP, and worker behavior. Provider-specific model names, authentication, launch flags, and account limitations should be verified separately and documented.
