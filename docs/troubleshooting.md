# Troubleshooting

## Start Session cannot find Codex or Claude

- Confirm `codex --version` or `claude --version` works in a normal terminal.
- Complete `codex login` or `claude /login` for the selected provider.
- In **Settings → General**, reinstall Relay Skills.
- If Codex family resolution fails, select a family visible to the installed Codex account; Relay Runner does not silently downgrade it.
- If a Claude model is unavailable, confirm the account supports that alias and effort level.

## Voice setup does not finish

First setup creates a local Python runtime, installs packages, downloads Kokoro model files, and installs Relay integrations. It requires network access and can take several minutes.

Retry from onboarding or Relay Skills. Open Console.app and filter for “Relay Runner” for the underlying setup line. Python 3.14 is not supported by the current Kokoro dependency; the installer selects or downloads a compatible Python 3.10–3.13 runtime.

## The microphone or activation key does not work

- Confirm Relay Runner is enabled in **System Settings → Privacy & Security → Microphone**.
- Use the menu-bar record control to separate microphone behavior from global-shortcut behavior.
- Caps Lock can operate with reduced permissions. Non-modifier global activation keys and the Workspace shortcut can require Input Monitoring or Accessibility.
- After changing a TCC grant, follow macOS's relaunch request and recheck Settings.

## Relay Actions cannot click, type, or inspect windows

Enable **Relay Runner** in Accessibility, then relaunch if macOS requests it. The grant belongs to Relay Runner.app, not Terminal, Codex, Claude, Warp, or an editor.

ActionGlow indicates a successful Relay tool call. It does not prove the target application accepted an input or that the requested user outcome occurred; verify consequential results in the target application.

## Relay Vision cannot take a screenshot

Enable **Relay Runner** in Screen Recording and relaunch the app if requested. Voice transcription, speech, and non-visual Relay Actions do not require Screen Recording. DRM-protected content can remain unavailable even with permission.

## No audio reply plays

- Check **Settings → TTS → Auto-play**. With auto-play off, use the replay control.
- Confirm macOS output volume and device selection.
- Preview a voice in TTS Settings to separate local synthesis from provider delivery.
- A queued or accepted reply is not playback evidence; inspect status until the item reaches its played state.

## Workspace shows no project

An empty registry is valid. Add or create a Git project, then select it before starting project work. Relay Runner does not treat its Application Support directory, an arbitrary cwd, or a parent folder as mutation authority.

If a registered project moved or its volume is offline, use Locate/Regrant. Removing it from Relay Runner leaves the repository and Relay artifact history untouched.

## A ticket is stuck

Inspect the ticket's canonical `run_id`, current board status, and the orchestrator run. `ready` dispatches automatically. A `verification_blocked` ticket requires its named external condition to change and an explicit resume; it should not be redispatched as an ordinary failure.

Run:

```bash
scripts/relay-orchestrator --status
```

The detailed queue, review, cancellation, and recovery behavior is in [Orchestrator](orchestrator.md).

## A source build warns or replaces the installed app

Use this for contributor packaging:

```bash
RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh
```

Without that variable, the script refreshes `/Applications/Relay Runner.app` when an installed copy exists. Without Developer ID credentials, the output is ad-hoc signed for the current Mac and Gatekeeper can reject it on another Mac.

For unresolved problems, follow [Support](../SUPPORT.md). Remove credentials, transcripts, personal paths, and project content before sharing logs or screenshots.
