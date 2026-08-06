# Public repository audit

This records the RR-174 release-readiness audit performed on 2026-08-06. It is evidence for the reviewed tree, not a promise that future commits are automatically safe.

## Scope and method

The review covered:

- tracked files in the RR-174 base tree;
- reachable Git diffs for common credential and private-key signatures;
- absolute user paths and machine-specific assumptions;
- hard-coded network endpoints;
- committed binaries, models, build output, local databases, caches, and runtime state;
- Swift, Python, model, font, icon, documentation, and release-artifact licensing.

Representative commands:

```bash
git grep -nE '<credential-signature-patterns>'
git log --all -G'<credential-signature-patterns>' --oneline --name-only
git grep -n '/Users/'
git grep -nE 'https?://|127\.0\.0\.1|localhost'
git ls-files | grep -E '(^|/)(\.env|\.DS_Store|dist|models|\.venv|.*\.db)(/|$)'
git status --short --ignored
```

The credential pattern set covered AWS access ids, GitHub token prefixes, OpenAI-style secret prefixes, Slack tokens, and PEM private-key headers. This is a bounded source/history review, not a substitute for GitHub secret scanning or a dedicated scanner in future CI.

## Findings and decisions

### Credential-like strings

No credential or private-key material was found. Two tests intentionally contain the invalid sentinel `sk-abcdefghijklmnopqrstuvwxyz` to prove that Relay artifact filters reject secret-like content. The history search reports those fixtures in every descendant commit where they exist; they are not usable credentials and remain as test data.

Release secrets are referenced only by environment-variable name in GitHub Actions and release documentation. Their values are not stored in the repository.

### Personal and machine-specific paths

The public README images are sanitized copies. The Workspace image replaces the username, home path, account label, and unrelated project; the playback image replaces the original conversational transcript.

Current product source uses generic `/Users/example/...`, `$HOME`, standard application locations, or runtime path resolution. A literal maintainer path in the maintained orchestrator guide was generalized during this pass.

Tracked `.orchestrator/` tickets and `docs/verification/` evidence still contain historical maintainer paths, ticket attachments, machine names, and project names. They are retained deliberately because Relay Runner dogfoods its repo-owned audit trail and those records explain past acceptance evidence. They are not copied into `Relay Runner.app`, the DMG payload, or the Sparkle archive as documentation. The review found no credentials in those retained paths. Rewriting Git history would break existing commit and ticket references without removing an active secret, so no history rewrite was performed.

New tickets and public evidence should use repository-relative attachments and redact personal paths before commit. A newly discovered real secret should follow [SECURITY.md](../SECURITY.md), including rotation before any history cleanup.

### Endpoints

`127.0.0.1` endpoints are intentional loopback-only communication between the app, MCP helpers, voice bridge, and orchestrator. Test-only loopback URLs are retained.

External runtime endpoints are limited to documented provider installation/authentication, public GitHub release/update locations, Hugging Face model downloads, package indexes, and the provider CLIs' own services. No private hostname or RFC1918 address was found. Release-feed values in `Info.plist`, `scripts/generate-appcast.sh`, the workflow, and `docs/release-updates.md` point to the same public update repository.

### Local artifacts

`.gitignore` excludes Swift build output, models, Python caches, IDE state, and DMG output. No venv, model weight, database, `.DS_Store`, `.env`, signing certificate, notary log, or generated `dist/` artifact is tracked.

Tracked PNG, TIFF, SVG, and HTML files are intentional app resources, DMG artwork, documentation, ticket evidence, or sanitized product images. The `.relay/` directory created in a worker worktree is runtime state and is not staged.

### Licensing

The prior README embedded an MIT grant but the repository had no standalone license. RR-174 adds `LICENSE`, this audit, contribution/security/support/conduct/testing routes, and [third-party notices](../THIRD_PARTY_NOTICES.md).

Resolved Swift dependency licenses are permissive and compatible with distribution under the project's MIT license while preserving their notices. The build now copies the project license, third-party inventory, and resolved Swift checkout licenses into the app. Runtime Python packages and speech models download under the terms recorded in `THIRD_PARTY_NOTICES.md`; proprietary PP font files are not bundled and system fonts are the deterministic fallback.

## Release consistency

At audit time:

- the remote default branch is `main`;
- the latest public tag and GitHub release are `v0.4.33`;
- `Info.plist` reports product version `0.4.33`, build `37`;
- the workflow publishes `RelayRunner.dmg`, `RelayRunner.zip`, and `appcast.xml` from `v*` tags;
- the source and update repositories, appcast URL, archive names, and release documentation agree.

RR-174 changes documentation and packaging contents only. It does not change repository visibility, create or move a tag, publish a release or appcast, or make an external announcement.

## Follow-up discipline

Before a future release:

1. rerun the source and history scans on the candidate commit;
2. inspect new ticket attachments and screenshots manually;
3. compare `Package.resolved`, `requirements.txt`, downloaded model cards, and the bundled notices;
4. run the clean checkout and signed-release checks in [TESTING.md](../TESTING.md) and [Release updates](release-updates.md);
5. verify the remote default branch, version/build, tag, release assets, and appcast together.
