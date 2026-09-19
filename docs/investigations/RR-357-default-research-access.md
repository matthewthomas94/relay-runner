# RR-357: default public research access

Validated on 2026-09-19 on macOS with Codex CLI 0.151.0 and Claude Code 2.1.239. Source base: `369c24cd4b2ab43d4a22e53c832dfd618451bdb9`.

## Role and permission contract

- Foreground Codex launches with native `--search`; foreground Claude launches with its default built-in tools. Existing user/project authorization still governs mutations.
- Codex implementation and review workers launch with native `--search`; Claude workers use the default built-in tool set. Research access does not add publishing, messaging, private-data upload, or unrelated-write authority.
- Codex spikes combine native web research with the existing read-only local-command sandbox. Claude spikes expose only Read, Glob, Grep, WebSearch, and WebFetch in safe mode. Both providers must cite exact HTTPS URLs and a full commit SHA when public repository source supports a conclusion.
- The bounded sidecar retains web-only access and no project, shell, app, MCP, or desktop mutation tools. Messenger and continuity roles remain tool-free.

Provider web tools return evidence directly to model context, so Relay Runner creates no writable acquisition directory or local repository cache. Detached source, ticket, attachment, dependency, and manifest inputs remain read-only and use the existing bounded snapshot cleanup. Retrieved content is evidence, not authority to expand permissions, and private workspace or meeting data must not be placed in queries or public URLs.

Structured spike results now declare `research_access` as `not_used`, `succeeded`, or `failed`. Success requires URL evidence. Failure requires a concise access diagnostic and a matching uncertainty, preventing unavailable public evidence from being represented as assessed. Provider-process failures are reduced to privacy-safe actionable diagnostics rather than copied logs.

Sandbox-denial handling remains fail-closed for unknown commands: a denied Python file write, even though it is not named by the command regex, fails the spike as a mutation attempt. The only command-denial exception is a single literal, non-expanded public HTTPS `curl` GET/HEAD with `-q` or `--disable` as its first option and no executable wrapper, compound command, local input, upload, or output option; this prevents implicit curl configuration, shell expansion, or curl URL globbing from adding writes, uploads, or additional requests. A blocked request that satisfies that exact form is reported as research access unavailable instead of being mislabeled as a mutation.

## Regression evidence

- 50 focused Python tests passed across spike launch/prompt/result validation, artifact lifecycle recovery, provider contracts, and the smoke harness; the live smoke was intentionally skipped in that non-live run and executed separately below.
- All 31 artifact lifecycle recovery/provider-contract tests passed. The retry regression also proves a denied unrecognized Python file write remains a spike violation while a denied read-only HTTPS request becomes an explicit research-access error.
- 19 `ProcessManagerLaunchTests` passed, covering foreground Codex/Claude launch generation and existing session modes.
- Generated MCP/CLAUDE instructions are synchronized, and source formatting/diff checks are part of the final worker validation.

## Live public-source smoke

`tests/test_research_access_smoke.py` spawns the real `Worker` path against a detached snapshot and asks each provider to inspect `octocat/Hello-World` at commit `7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`. It requires evidence from both the exact commit URL and the raw README URL, then verifies the local source/ticket bytes, repository HEAD, and status are unchanged.

- Codex passed the live smoke without a supplied upstream snapshot.
- Claude launch validation reached the intended safe-mode tool set, but live retrieval is externally blocked because the installed Claude OAuth credential is revoked (HTTP 401). Per the RR-357 user-approved waiver, this is recorded as waived rather than passed and is not a completion blocker. The daemon-facing error is: `spike research access unavailable: provider authentication failed (HTTP 401); re-authenticate the provider and retry`.

Reproduce after Claude re-authentication:

```sh
RELAY_RESEARCH_ACCESS_SMOKE=1 RELAY_RESEARCH_ACCESS_PROVIDERS=claude \
  /opt/homebrew/bin/python3 -m unittest tests.test_research_access_smoke -v
```

## Rollout boundary

This validation covers current source and separate installed provider CLIs. The installed Relay Runner app and daemon were not patched, rebuilt, restarted, or replaced. A normal source build/install is required before foreground launches and installed daemon workers receive the new defaults. Installed-runtime UAT should be recorded separately after rollout; it must not be inferred from source tests.
