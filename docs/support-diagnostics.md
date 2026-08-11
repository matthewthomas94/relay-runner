# Local support diagnostics

Relay Runner records a bounded, local incident timeline so first-run and Workspace failures remain diagnosable when the orchestrator, provider, or network is unavailable. This journal complements Apple Unified Logging, signposts, MetricKit, and native macOS crash reports; no remote reporting SDK is required.

## Allowlisted schema

Version 1 JSONL events contain only:

- timestamp, schema version, emitting process, phase, and outcome;
- app-session, incident, retry-attempt, and correlation identifiers;
- an optional `codex` or `claude` provider label;
- an optional bounded, redacted summary; and
- allowlisted build, version, exit/error code, launch-mode, payload-count, and transport attributes.

Swift, shell, and Python writers share the same field names. Provider-specific commands, authentication, flags, models, and output are never journal fields; Codex and Claude differ only by the allowlisted provider label.

Identifiers use one cross-language contract: accept only a lowercase RFC 4122 UUID, Relay's `inc-` plus 12 lowercase hexadecimal digits, or a `shell-<epoch>-<pid>` / `orchestrator-<epoch>-<pid>` identifier. Everything else—including mixed case, paths, credential-like text, prompts, punctuation, and values longer than 64 characters—is replaced wholesale with `redacted-id`; it is never filtered or truncated into a journal identifier, and each replacement increments `redaction_count`.

The journal is stored under `~/Library/Application Support/relay-runner/support-diagnostics/v1/` with owner-only permissions. `RELAY_DIAGNOSTICS_DIR` may override the location for tests. Files older than seven days are removed and aggregate journals are capped at 5 MiB. Every writer holds the same atomic `.journal.lock` directory across append and retention: acquisition retries every 50 ms for at most five seconds, and a lock abandoned for 30 seconds is atomically renamed and removed. This bounded, stale-recoverable protocol interoperates across Swift, Python, and shell and cannot remain held after a normal process exit.

## Redaction and bundles

Before writing, bounded summaries and attributes redact home, volume, and temporary paths; bearer values; credential-like assignments; and common token prefixes. Unknown processes, providers, attributes, phases, and outcomes are rejected.

A Workspace load failure displays its stable incident ID. Retry keeps that incident ID and increments `retry_attempt`. The failure surface previews event/file/redaction counts and can create a ZIP using the Swift app plus macOS `ditto`; Python, the orchestrator, the provider, and network access are not required.

Bundles include the revalidated allowlisted timeline, app/build and macOS versions, and a manifest describing retention and redaction. They exclude raw commands and transcripts, prompts and provider output, repository paths or contents, credentials, audio, screenshots, worker logs, native crash reports, and full temporary-directory contents. Review the preview before sharing.

## Apple crash and symbol contract

MetricKit delivery is recorded only as a bounded payload count. MetricKit payload contents and native crash reports stay on the Mac and are not copied into a support bundle. Investigators correlate those Apple-owned records with the app version/build and incident timestamps.

Every release build passes `-g`, runs `dsymutil` for the app and its three Swift MCP helpers, and verifies each dSYM UUID against its packaged Mach-O with `dwarfdump`. CI retains `dist/RelayRunner-dSYMs.zip` as a private build artifact; it is not published to the public Sparkle release. A release is symbol-verifiable only when that UUID check passes and the private artifact is retained.

No remote pilot is enabled. Any future Sentry evaluation must be separately approved, explicit opt-in, client-side allowlisted, revocable, offline-safe, and tested for both Swift and Python reporting without weakening the local bundle.
