# RR-357: default public research access

Validated on 2026-09-19 on macOS with Codex CLI 0.151.0. Source base: `369c24cd4b2ab43d4a22e53c832dfd618451bdb9`. Claude live checks are waived by the user for this ticket.

## Role and permission contract

- Foreground Codex launches with native `--search`; foreground Claude launches with its default built-in tools. Existing user/project authorization still governs mutations.
- Codex implementation and review workers launch with native `--search`; Claude workers use the default built-in tool set. Research access does not add publishing, messaging, private-data upload, or unrelated-write authority.
- Codex spikes combine native web research with the existing read-only local-command sandbox. Claude spikes expose only Read, Glob, Grep, WebSearch, and WebFetch in safe mode. Both providers must cite exact HTTPS URLs and a full commit SHA when public repository source supports a conclusion.
- The bounded sidecar retains web-only access and no project, shell, app, MCP, or desktop mutation tools. Messenger and continuity roles remain tool-free.

Provider web tools return evidence directly to model context, so Relay Runner creates no writable acquisition directory or local repository cache. Detached source, ticket, attachment, dependency, and manifest inputs remain read-only and use the existing bounded snapshot cleanup. Retrieved content is evidence, not authority to expand permissions, and private workspace or meeting data must not be placed in queries or public URLs.

Structured spike results now declare `research_access` as `not_used`, `succeeded`, or `failed`. Success requires URL evidence. Failure requires a concise access diagnostic and a matching uncertainty, preventing unavailable public evidence from being represented as assessed. Provider-process failures are reduced to privacy-safe actionable diagnostics rather than copied logs.

## Inline redesign and review learnings

The user stopped the automated worker/review loop and authorized inline completion. Earlier reviews found that the proposed curl fallback kept admitting new forms of shell expansion, implicit curl configuration, executable wrappers, and option parsing. Treating command text as proof that a denied operation was safe created an unnecessary permission exception.

The redesign deletes the curl permission classifier, its per-command exception tracking, and the shell-download fallback. All public research uses native provider web tools. Codex commands retain the read-only, network-disabled OS sandbox, which applies to interpreters and child processes. Native web access is independent of command networking; this is documented by [OpenAI](https://learn.chatgpt.com/docs/web-search) and verified by the live tests below. No shell parsing grants network or write access.

Command-text checks are diagnostic only. Any command failure reporting a sandbox, filesystem-permission, or network denial fails the spike, including an unrecognized Python file write. A native web event never grants a later command an exception. Native research failures continue to use the structured `research_access` result and explicit provider-access diagnostics.

## Regression evidence

- The final inline implementation passed 30 focused Python tests covering spike launch/prompt/result validation, Git toolchain isolation, and sidecar boundaries. This includes the actual Codex sandbox smoke; it was enabled, not skipped.
- The denial regression exercises 18 historical commands against four denial messages, both with and without a preceding command-start event (144 cases). Shell expansion, curl configuration, executable wrappers, shell options, and unknown interpreter writes all remain violations. A separate test checks that native web activity cannot authorize a command.
- The real Codex sandbox permits the prepared Git read operations and denies source, ticket, and external-file writes. A controlled local TCP listener accepts an unsandboxed control connection; direct and shell-wrapped Python connection attempts inside the sandbox both fail with `Operation not permitted`, and the listener receives no connection.
- Earlier worker validation passed all 31 artifact lifecycle recovery/provider-contract tests and 19 `ProcessManagerLaunchTests`. Those unchanged paths retain that evidence; these suites were not rerun during inline completion.
- Python compilation, generated MCP/CLAUDE instruction synchronization, and `git diff --check` passed during inline validation.

Reproduce the focused checks, including the real sandbox probe:

```sh
RELAY_SPIKE_CODEX_SANDBOX_SMOKE=1 /opt/homebrew/bin/python3 -m unittest \
  tests.test_spike_execution tests.test_spike_git_toolchain tests.test_sidecar_lane -v
```

## Live public-source smoke

`tests/test_research_access_smoke.py` spawns the real `Worker` path against a detached snapshot and asks the provider to inspect `octocat/Hello-World` at commit `7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`. It requires evidence from both the exact commit URL and the raw README URL, then verifies the local source/ticket bytes, repository HEAD, and status are unchanged. The Codex check also requires a completed native `web_search` event in the actual provider log.

- Codex passed the final inline live smoke without a supplied upstream snapshot: one test passed, with native web retrieval and snapshot integrity verified.
- Earlier Claude launch validation reached the intended safe-mode tool set, but live retrieval failed because the installed OAuth credential was revoked (HTTP 401). Per the RR-357 user-approved waiver, this is recorded as waived rather than passed. No further Claude checks were performed during inline completion. The daemon-facing error is: `spike research access unavailable: provider authentication failed (HTTP 401); re-authenticate the provider and retry`.

Reproduce the required Codex live check:

```sh
RELAY_RESEARCH_ACCESS_SMOKE=1 RELAY_RESEARCH_ACCESS_PROVIDERS=codex \
  /opt/homebrew/bin/python3 -m unittest tests.test_research_access_smoke -v
```

## Rollout boundary

This validation covers current source and separate installed provider CLIs. The installed Relay Runner app and daemon were not patched, rebuilt, restarted, or replaced. A normal source build/install is required before foreground launches and installed daemon workers receive the new defaults. Installed-runtime UAT should be recorded separately after rollout; it must not be inferred from source tests.
