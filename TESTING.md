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

## Rust workspace

The Cargo workspace in `rust/` builds `relay-rs`, the Rust helper shipped in the app bundle. `rust/rust-toolchain.toml` pins the toolchain. Install [rustup](https://rustup.rs), which reads that file and installs the pinned toolchain the first time `cargo` runs inside `rust/`:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

A Rust install from another source, such as Homebrew's `rust`, ignores the pin; it works only while its `rustc --version` equals the pinned channel. Run the same checks as CI from inside `rust/`, then the license check from the repository root:

```bash
cd rust
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cd ..
scripts/rust-licenses --check
```

After adding, removing or updating a crate, commit `rust/Cargo.lock` and run `scripts/rust-licenses` to regenerate the Rust section of `THIRD_PARTY_NOTICES.md`. It refuses a crate whose license is outside the allow list at the top of that script; GPL-family licenses must not be added to it.

## Package the app

Install the Rust toolchain as described under [Rust workspace](#rust-workspace); the packaging script stops before building anything when `cargo` is missing or `rustc` is not the pinned version. Install `dmgbuild` into a Python interpreter the script can discover:

```bash
python3 -m pip install --user --break-system-packages dmgbuild
RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh
```

The packaging command must produce:

- `dist/Relay Runner.app`
- `dist/RelayRunner.dmg`
- `dist/RelayRunner.zip`

It verifies the app's nested code signatures and archive shape. Without `SIGN_IDENTITY` and `NOTARY_PROFILE`, the result is an ad-hoc-signed local artifact and does not prove Developer ID or notarization behavior. Maintainers verify public artifacts through the tag workflow and the checklist in [Release updates](docs/release-updates.md).

## Relay Remote (iOS)

The iPhone app and its transport package live under `ios/`. See [ios/README.md](ios/README.md) for the simulator test command, the macOS `swift test` run of `ios/RelayRemoteKit` (including the end-to-end SSH tests against a temporary per-user `sshd`), and the physical-device checks.

## Installed and permission-dependent checks

Unit tests and a source build cannot prove macOS TCC or mounted UI behavior. Changes involving Microphone, Accessibility, Input Monitoring, Screen Recording, hotkeys, audio playback, the embedded terminal, onboarding, Sparkle, or the mounted Workspace need an installed-app check.

Record the exact evidence obtained. For audio, a queued or accepted event is not audible proof; playback must reach its terminal played state. If Screen Recording or another external permission is unavailable, preserve the blocker instead of claiming the visual check passed.

Codex and Claude should receive equivalent checks for shared session, scope, voice, MCP, and worker behavior. Provider-specific model names, authentication, launch flags, and account limitations should be verified separately and documented.
