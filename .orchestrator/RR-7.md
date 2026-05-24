---
id: RR-7
title: Linear references remaining in skills
status: done
priority: medium
depends_on: []
run_id: null
canceled: false
order: 10
---

## Description

There are still linear references left in the relay orchestrate skills, this needs to be gone completely from the app and its installed skills. I overwrote the skills and this still remained. do another pass and remove all instructions to use linear

## Run log

**Voice-handled inline (no dispatched run)** — branch `orchestrator/local-kanban-autodispatch`

- Root cause: the bundled `.app`'s `scripts/relay-orchestrator` was the pre-Linear-removal version. Re-installing skills from the bundled app rewrote `~/.claude/commands/relay-{dispatch,link-project,orchestrate,workflow}.md` with the old Linear-laden heredocs. The repo-side script was already clean.
- `scripts/relay-orchestrator`: also remove `relay-orchestrate.md` on every install — previously only the uninstall path removed it. Mirrors the existing `relay-link-project.md` cleanup. New `LEGACY_ORCHESTRATE_MD` constant.
- Reinstalled skills via `scripts/relay-orchestrator --install-skills` using the in-repo script (not the bundled one). `~/.claude/commands/` now contains only `relay-bridge.md`, `relay-dispatch.md`, `relay-stop.md`, `relay-workflow.md` — all Linear-free.
- Bundled `.app` will pick up the same scripts on the next DMG rebuild (per CLAUDE.md "don't ad-hoc fix the bundled .app's scripts — commit upstream").
