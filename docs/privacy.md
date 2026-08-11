# Privacy and permissions

Relay Runner keeps speech processing and project coordination on the Mac, while using the selected Codex or Claude CLI for model work. “Local speech” does not mean the entire agent session is offline.

## Data flow

### Stays local by default

- Raw microphone audio is captured by the app and passed to local Parakeet speech recognition.
- Kokoro synthesizes response audio locally and writes temporary playback files.
- Provider session processes, the orchestrator daemon, and the messenger run as local processes.
- The project registry, permission state, local caches, and run databases live under `~/Library/Application Support/relay-runner/`.
- Relay tickets and eligible attachments live in the registered repository's Relay artifact boundary or its `.orchestrator/` compatibility projection.

Relay Runner does not provide a hosted speech, repository, or ticket service.

### Can leave the Mac

- Transcribed prompts are delivered as text to the active Codex or Claude session.
- The provider CLI can read source, terminal context, and tool output according to its working directory, configuration, and permissions.
- A Relay Vision screenshot is returned to the requesting agent. It can therefore be transmitted to that agent's provider.
- Relay Actions results, orchestrator summaries, and public worker progress can become provider context.
- Git content leaves the Mac when the user or an agent explicitly pushes or syncs it.
- First-run setup downloads provider tools when missing, Python packages, Kokoro files, and Parakeet models. Sparkle checks the configured GitHub update feed.

OpenAI and Anthropic process data under their own product settings and terms. Relay Runner cannot change provider retention, training, organization, or regional settings.

## macOS permissions

| Permission | Why it is requested | If it is denied |
| --- | --- | --- |
| Microphone | Capture speech for local transcription. | Voice input is unavailable; other app surfaces can still open. |
| Accessibility | Host Relay Actions clicks, typing, keys, scrolling, window automation, and global shortcut observation. | Voice can still use the menu-bar control; Relay Actions and some shortcuts are unavailable. |
| Input Monitoring | Listen-only fallback for global shortcuts, including non-modifier activation keys and the Workspace hotkey when Accessibility is absent. | Caps Lock and menu controls still provide reduced voice operation; affected global shortcuts are unavailable. |
| Screen Recording | Capture the selected display when Relay Vision is explicitly invoked. | Relay Vision returns a permission error; voice and Relay Actions do not require screenshot access. |

Accessibility and Screen Recording belong to Relay Runner.app because the app hosts the privileged operation. macOS may require the app to relaunch after a grant or revoke. Settings shows the current permission state and recovery routes.

Permissions are capability gates, not per-action confirmations. A successful Relay Actions or Relay Vision call pulses ActionGlow around the screen edge. For a consequential action, the foreground agent should ask in the normal conversation when intent is not already clear.

## Storage and deletion

The fixed application root is `~/Library/Application Support/relay-runner/`. It contains the app-owned project registry, local databases, voice runtime, caches, and recovery metadata. It must never be selected or inferred as a project.

Registered repositories can live anywhere on the Mac. Removing a project from Relay Runner removes the registry entry, bookmark, and rebuildable app caches; it does not delete the repository, Git refs, remote configuration, or repo-owned Relay artifact history.

Temporary voice coordination uses named pipes, sockets, and bounded state files under `/tmp`. Temporary audio is for local synthesis and playback. Diagnostic logs may contain filenames, provider errors, or status details; inspect and redact them before sharing.

The repository's supported fresh-install/reset tool previews its scope unless `--execute` is explicitly supplied. Each reset profile also requires its exact `--confirm-profile` value and retains a recovery manifest. Review that preview before changing recoverable application state; see [fresh-install validation](fresh-install.md).

## Sensitive project content

Raw Relay transcripts, hidden model reasoning, credentials, and tool logs are not valid ticket or artifact content. Visible tickets must contain a refined task summary. The artifact store rejects known private transcript and secret markers, but that filter is a backstop rather than a guarantee. Review project content before committing or pushing it.

See [Security](../SECURITY.md) for private reporting and [Repository audit](repository-audit.md) for the public-tree review performed for this release-readiness pass.
