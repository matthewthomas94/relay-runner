# Relay Runner Product Context

## Register

product

## Users

Developers using Codex or Claude Code on macOS who want to direct coding work by voice while retaining the full interactive agent session, local project context, and visible control over what the agent is doing.

## Product Purpose

Relay Runner is a native macOS control surface for voice-driven agent sessions. It captures and speaks locally, connects transcribed commands to the user's configured Codex or Claude CLI, and keeps project work, status, permissions, and agent activity visible without moving source code or voice data into a separate service.

## Brand Personality

Native, calm, and trustworthy. The interface should feel like a focused macOS utility: concise during routine work, explicit when state or permissions matter, and equally at home with either supported agent provider.

## Anti-references

Relay Runner should not resemble a generic chat wrapper, a decorative sci-fi HUD, or a replacement IDE. It should not hide process state, imply that local data is cloud-hosted, invent unfamiliar controls where macOS conventions already work, or make Codex and Claude feel like separate products.

## Design Principles

1. Keep the agent workflow in view. Voice augments the normal interactive session rather than obscuring it.
2. Make local ownership legible. On-device speech, repo-local tickets, and app-owned permissions should remain clear in the interface.
3. Preserve provider parity. Share concepts and user flows while containing necessary CLI differences inside the implementation.
4. Signal state without stealing focus. Overlays and ambient effects should communicate activity, then recede so the developer can keep working.
5. Prefer graceful fallback. Missing permissions, unavailable models, and external-tool boundaries should produce an understandable recovery path.

## Accessibility & Inclusion

Preserve native keyboard and focus behavior, expose meaningful labels for non-text state, avoid using color as the only status signal, and honor the macOS Reduce Motion setting. Voice is an additional input path, not a requirement for navigating or controlling the app.
