# Contributing to Relay Runner

Relay Runner is an early macOS project. Focused bug fixes, provider-parity improvements, tests, documentation corrections, and accessibility work are welcome.

## Before opening a change

1. Search existing issues and tickets for overlapping work.
2. Open an issue before a large behavioral or architectural change so its user experience and migration path can be agreed first.
3. Do not include credentials, private transcripts, personal paths, proprietary fonts, or unrelated screenshots in an issue, fixture, commit, or pull request.
4. Read the [Code of Conduct](CODE_OF_CONDUCT.md) and [Security policy](SECURITY.md). Report vulnerabilities privately.

## Set up a development checkout

Requirements:

- macOS 14 or later
- Xcode 16 or later and the Xcode command-line tools
- Git
- Python 3.10–3.13 for the Python service tests
- `dmgbuild` for packaging checks

```bash
git clone https://github.com/matthewthomas94/relay-runner.git
cd relay-runner
swift package resolve
swift test
python3 -m unittest discover -s tests
```

Run `scripts/build-instructions --check` if a change affects provider or MCP instructions. The full command matrix and packaging prerequisites are in [TESTING.md](TESTING.md).

## Make the change

- Keep each change narrow. Do not refactor adjacent code unless the requested behavior requires it.
- Add or update the smallest test that proves the behavior.
- Preserve Codex and Claude parity. Intentional provider differences belong in code comments and [provider documentation](docs/providers.md).
- Keep project mutations explicitly scoped to a registered project. Application Support is runtime state, not a project directory.
- Treat `.orchestrator/` ticket text as public project content. Never paste raw voice transcripts, hidden reasoning, credentials, or tool logs into it.
- Do not commit generated build output, models, venvs, local runtime state, or proprietary font files.

Use a conventional commit with a concise reason for the change. If work is associated with a Relay ticket, include the ticket id, for example `fix: preserve selected project scope (RR-123)`.

## Verify and submit

At minimum, run the focused test for the edited area and `git diff --check`. Before requesting review, run every applicable command in [TESTING.md](TESTING.md).

For packaging changes, use:

```bash
RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh
```

That environment variable prevents a contributor build from replacing an installed copy. An unsigned local build is ad-hoc signed and is not evidence that a public Developer ID release will pass notarization.

Open a pull request that explains the user-visible result, verification performed, provider differences, and any external verification still required. Maintainers may ask for an isolated follow-up when a patch combines unrelated changes.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
