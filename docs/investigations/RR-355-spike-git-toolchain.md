# RR-355: read-only spike Git toolchain

Validated on 2026-09-17, macOS 26.7 (25G229), arm64, Python 3.13.13 and 3.14.5, Codex CLI 0.151.0. Source base: `095d22664cc6dc034f69adb926b8a78db85d53a5` (RR-354).

## Implementation

The daemon verifies direct Git selection before starting a Codex spike. It excludes Apple's `/usr/bin/git` launcher, resolves symlinks, discovers selected Xcode/Command Line Tools Git even when Homebrew is absent from PATH, and probes HEAD/file-list reads with filesystem writes and network denied. A failed or noisy candidate cannot reach the worker. If all candidates fail, dispatch records an actionable failure through the existing artifact writer and starts no worker.

The worker process and Codex shell tools receive the same Git path, `GIT_OPTIONAL_LOCKS=0`, `GIT_NO_LAZY_FETCH=1`, and `GIT_TERMINAL_PROMPT=0`. Codex login shells, shell snapshots, profile environment loading, and approval escalation are disabled. The prompt gives the prepared absolute Git variable and prohibits cache warming or toolchain repair inside research execution. The [official Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) documents the shell and environment settings.

Claude retains safe mode with only Read/Glob/Grep, no shell or Git execution, and no Git preflight dependency. Its prompt describes the resulting evidence limits. Structured mutation validation, branchless snapshots, and daemon-only report persistence remain in place.

## Regression and smoke evidence

- A controlled launcher attempts an `xcrun_db` fixture cache creation, prints the denied-write diagnostic, and still exits zero after a Git read. Preflight rejects it, leaves the cache absent, and selects direct Git. This reproduces the relevant failure contract without deleting or depending on the host's existing xcrun caches.
- With PATH restricted to `/usr/bin:/bin`, discovery selects `/Applications/Xcode.app/Contents/Developer/usr/bin/git` (Apple Git 2.50.1). Direct reads pass in non-login sh/bash/zsh and a nested zsh. A startup file that replaces PATH causes an explicit preflight failure.
- A separate host check confirmed that sh/bash/zsh `-lc` replaced the prepared Git selection with `/usr/bin/git`, while `-c` preserved it. Disabling login-shell and snapshot/profile behavior addresses this observed PATH reset.
- Source, ticket, external-file, and Git-ref writes fail under the preflight policy. The installed Codex read-only sandbox independently denies source, ticket, and external-file writes. Fixture HEAD, clean status, ticket contents, and absence of the forbidden file remain unchanged.
- Provider command/prompt tests verify Codex environment settings and Claude's restricted tool list. Artifact tests verify subprocess environment delivery, preflight failure before worker creation, canonical retry state, released snapshot leases, and continued branchless result handling.

The opt-in installed-CLI smoke uses `codex sandbox` with `sandbox_mode="read-only"` and the exact configuration overrides produced by `_agent_command`, plus the prepared worker environment. It runs Git HEAD, file-list, diff, and status reads in bash and zsh. Reproduce the focused regressions and smoke with:

```sh
RELAY_SPIKE_CODEX_SANDBOX_SMOKE=1 /opt/homebrew/bin/python3.13 -m unittest discover -s tests -p 'test_spike*.py'
/opt/homebrew/bin/python3.13 -m unittest discover -s tests -p 'test_orchestrator_artifact_lifecycle.py'
/opt/homebrew/bin/python3.13 -m unittest discover -s tests -p 'test_artifact_lifecycle.py'
```

Final results: all 32 spike tests passed with the installed-CLI smoke enabled on Python 3.13; all 31 daemon artifact lifecycle tests passed on Python 3.14 (791 seconds), with the three changed launch/preflight cases also passing on Python 3.13; all eight core artifact lifecycle tests passed on Python 3.13. Six Astra/Fable sizing tests and four existing worker/reviewer launch-flag tests also passed. `scripts/build-instructions --check` reported synchronized instructions and `git diff --check` passed. These cover 81 distinct tests; repeated interpreter checks are not counted twice.

An additional bounded check ran the same installed Codex sandbox settings against the assigned RR-355 worktree. The automatically selected executable was `/opt/homebrew/Cellar/git/2.52.0_1/bin/git`. All six bash/zsh HEAD, file-list, and diff reads exited zero with empty stderr; both file lists contained 467 tracked paths. Before/after HEAD and the existing implementation diff were identical. The immutable RR-355 ticket SHA-256 remained `e1339c095f3a4a7093ce58fbedbc0ee8008b8fa5aeac98112014e2e9eb722d21`, matching its artifact manifest.

## Evidence limits

No authenticated Codex or Claude model turn, installed Relay daemon launch, app rebuild/install, or RR-269 retry was performed. The smoke verifies the installed Codex sandbox command path and launch configuration; provider behavior is covered by command/prompt and subprocess fixtures. macOS is the supported Git preflight platform; absence of its sandbox tooling produces an early blocker. Existing warm-cache `/usr/bin/git` reads can succeed, so the regression uses a deterministic denied-cache fixture instead of claiming a fresh host failure.
