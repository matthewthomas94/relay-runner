# RR-289 verification record

Date: 2026-08-05 (Australia/Melbourne)

RR-289's implementation and source gates pass. On 2026-08-05 the user explicitly
deferred execution of the signed installed two-device gate to RR-290. No evidence
in this record enables either later rollout cohort; the deferral closes RR-289's
implementation scope without asserting that the installed gate passed.

## Passing evidence

- `/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'`:
  549 tests passed with 0 failures on the clean final run. The first post-change
  run exposed one unrelated temporary-WAV cleanup race in a TTS test; that test
  immediately passed alone and the complete rerun passed.
- `swift test`: 668 tests executed, 3 intentional benchmark skips, 0 failures.
- The focused artifact rollout/lifecycle/verification set passed 20 tests. It
  proves configured project opt-ins are checked on every daemon lifecycle
  lookup, explicit opt-out takes precedence, a paused cohort blocks a cached
  board writer without moving the artifact ref, backup recovery state blocks new
  starts pending reviewed repair, and non-Developer-ID certificate authorities
  are rejected even when they carry a Team ID.
- `scripts/relay-artifact-verify source-harness` from the checkout: passed the
  disposable two-device remote harness and all nine RR-270 source-matrix groups;
  report SHA-256
  `ff8fa880c2eb73e11a3b3104998f85427027e488ce38a132f4c93b2449c195cd`.
- `scripts/build-dmg.sh`: produced the app, DMG, and Sparkle zip and refreshed
  `/Applications/Relay Runner.app`. The installed bundle contains the rollout
  and verification modules and both command-line entrypoints.
- The installed bundle's `source-harness` passed all seven executable remote,
  conflict, source-isolation, crash-recovery, and provider-parity scenarios;
  report SHA-256
  `c3433d2a6a3007367b2120b903794e3182ffaae8aae2a8cb0392386e8946fa5e`.
  Its nine source-matrix entries correctly report
  `external_source_report_required` because test sources are not shipped in the
  app and are supplied by the passing checkout report above.
- Installed rollout diagnostics reported zero app-local explicit project-policy
  opt-in records. The compatibility config opt-in remains subject to the enabled
  `project_opt_in` baseline gate. Both `new_project_default` and
  `legacy_migration_offer` had writes and sync disabled.

The automated remote harness uses independent disposable clones of one bare
remote. It does not claim two physical Macs, TCC behavior, mounted AppKit
interaction, or authenticated provider sessions.

## Blocking installed evidence

The installed gate rejected `/Applications/Relay Runner.app` with
`signed_installed_build_required`, as designed:

- bundle identifier: `com.relayrunner.app`;
- version/build: `0.4.29` / `33`;
- signature: ad-hoc;
- Team ID: not set; and
- locally available valid code-signing identities: 0.

No bounded evidence manifest exists for the exact same Developer ID signed bundle
on two distinct physical devices, and no mounted Codex-and-Claude scenario matrix
has been accepted. Source and disposable-clone results must not be promoted into
that missing evidence.

## Exact resume condition

Build and install one exact valid Developer ID signed Relay Runner bundle on two
distinct physical Macs. On both devices, complete every mounted Workspace
scenario in the RR-289 installed template, including filesystem grants and
revocation, moved/offline recovery, explicit scope, history/restore, conflict UI,
fresh install/reset, source isolation, and Codex/Claude parity. Evaluate the one
bounded manifest with `relay-artifact-verify evaluate-installed`, externally
accept the resulting signed evidence, then explicitly review cohort promotion.

Until that condition is met, RR-290 remains backlog verification work and later
cohort promotion is prohibited. RR-289 and its RR-273 implementation roadmap are
closed under the explicit scope decision, not under a fabricated evidence result.
