# Architecture overview

Relay Runner is a native macOS app with local companion processes. The provider CLI remains the interactive coding-agent process; Relay Runner coordinates it rather than replacing it.

```text
┌──────────────────────────── Relay Runner.app ────────────────────────────┐
│ microphone / Parakeet  overlays  Settings  Workspace  embedded terminal │
│                   │             │                │                       │
│                   └──── local sockets, files, and app-hosted tools ──────┤
└──────────────────────────────────┬────────────────────────────────────────┘
                                   │
                 ┌─────────────────┼──────────────────┐
                 ▼                 ▼                  ▼
        Python voice and     Codex or Claude     MCP helpers
        orchestrator services interactive CLI    Actions / Vision / board
                 │                 │                  │
                 └─────────────────┼──────────────────┘
                                   ▼
                    selected local Git repository
```

## App and provider session

Swift code under `Sources/relay-runner/` owns microphone capture, FluidAudio transcription, Kokoro playback coordination, onboarding, Settings, macOS permissions, overlays, the project registry UI, Workspace, and the SwiftTerm terminal.

**Start Session** validates the selected registered project, prepares the voice runtime and Relay integrations, then launches Codex or Claude in an app-owned pseudo-terminal. Both providers receive the same project-scope and Relay workflow contract. Provider-specific executable discovery, authentication, model resolution, flags, and hooks stay at the launch boundary.

Python modules under `services/` own the voice bridge, tool-free messenger, ticket orchestration, worker lifecycle, program capture, and artifact services. The daemon listens only on loopback and stores durable local run state so a UI or provider turn does not have to stay alive to poll work.

## Voice loop

Parakeet converts captured audio to text on the Mac. Each current voice turn reaches the foreground provider session and a persistent tool-free messenger. The foreground orchestrator is authoritative for decisions and project work; the messenger sees only the user turn plus bounded public progress and produces concise spoken wording. Kokoro synthesizes that speech locally.

Freshness identifiers prevent a superseded voice command from speaking or mutating as though it were current. Raw transcripts remain private coordination metadata and are not valid ticket content.

## Screen capabilities

`relay-actions-mcp` exposes manipulation and window-introspection operations. `relay-vision-mcp` exposes screenshot observation separately. The helpers forward privileged work to Relay Runner.app so macOS attributes Accessibility and Screen Recording to the app. Successful calls pulse ActionGlow.

Current tool and permission details are in [Relay Actions](specs/relay-actions.md), [Relay Vision](specs/relay-vision.md), and [Privacy](privacy.md).

## Projects, tickets, and workers

The application-support registry is a catalog, not a repository. A user explicitly selects a registered Git project before Relay Runner issues a scope token. Cwd, recent use, and a nearby repository can suggest a project but cannot authorize mutation.

Tickets use refined Markdown and YAML metadata. Ready work dispatches to isolated worktrees; implementation and review have distinct lifecycle states. A worker can finish as done only with the declared committed change and verification, or as verification-blocked when a named external condition prevents otherwise complete validation.

Repository-owned artifact mode stores Relay state on an orphan `relay/artifacts` ref and materializes `.orchestrator/` as a projection. Compatibility mode retains directly versioned `.orchestrator/` files. Rollout gates are per project and reversible; application state must not silently choose a project or rewrite source history.

Deeper references:

- [Explicit project scope](architecture/project-scope-v2.md)
- [Registry v2](architecture/registry-v2.md)
- [Orchestrator](orchestrator.md) and [ticket schema](specs/orchestrator-tickets.md)
- [Artifact store](architecture/artifact-store.md), [sync](architecture/artifact-sync.md), [retention](architecture/artifact-retention.md), [migration](architecture/artifact-migration.md), and [worker lifecycle](architecture/artifact-lifecycle.md)

## Distribution

Swift Package Manager resolves FluidAudio, TOMLKit, Sparkle, and SwiftTerm. `scripts/build-dmg.sh` builds the app and three MCP helpers, copies read-only Python service sources, embeds Sparkle, includes license notices, signs the nested bundle, and creates a DMG plus Sparkle zip.

Local builds are ad-hoc signed unless Developer ID and notary credentials are provided. Tagged GitHub Actions runs validate release secrets, sign, notarize, staple, generate an EdDSA-signed appcast, and publish existing release paths. Details are in [Release updates](release-updates.md); normal project work never invokes that release path automatically.
