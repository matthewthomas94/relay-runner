# Security policy

## Supported versions

Relay Runner is an early-release application. Security fixes target the latest published release and the current default branch. Older builds may not receive backports; update to the newest signed release before reproducing a report when practical.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability or include secrets, private transcripts, screenshots, or exploit details in a public ticket.

Use [GitHub's private vulnerability report](https://github.com/matthewthomas94/relay-runner/security/advisories/new). Include:

- affected version and macOS version;
- whether Codex, Claude, or both are affected;
- the permission and project-scope state;
- minimal reproduction steps and impact;
- logs with tokens, usernames, paths, transcripts, and project content removed.

If the private reporting form is unavailable, open a public issue that asks for a private contact route without disclosing the vulnerability.

The maintainer will acknowledge a complete report when it is seen, investigate impact, coordinate a fix and disclosure window, and credit the reporter unless anonymity is requested. Response times are best-effort; this project does not currently provide an enterprise SLA or bug bounty.

## Security boundaries

- Speech recognition and synthesis run locally, but transcribed prompts, provider-visible context, tool results, and invoked Relay Vision screenshots can reach the selected provider.
- Relay Actions can control the Mac after Accessibility is granted. Relay Runner's provider-permission bypass setting is enabled by default; users who want provider approval prompts should disable it in Settings.
- Project work requires an explicitly selected registered project. The local registry and application-support directories are not authority to mutate an arbitrary repository.
- Signed releases use Developer ID, notarization, and Sparkle signatures. Source builds without signing credentials are ad-hoc signed for local use only.

See [Privacy and permissions](docs/privacy.md) and [Architecture](docs/architecture.md) for the complete data and process boundaries.
