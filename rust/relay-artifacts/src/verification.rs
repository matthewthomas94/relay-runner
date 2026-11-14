//! `services/artifact_verification.py` (and `artifact_verification_cli.py`):
//! the RR-289 disposable two-device source harness and the signed
//! installed-app gate.
//!
//! The harness drives real Git clones through the artifact store and the
//! sync engine in a temporary directory and reports bounded outcomes only;
//! the gate reads an installed bundle's identity and evaluates a bounded,
//! hash-only evidence manifest. Both produce the JSON the Python module
//! produces, with the same `report_sha256`.
//!
//! Deliberate differences, each documented where it happens:
//!
//! - `Info.plist` is read through `/usr/bin/plutil -convert xml1` rather than
//!   `plistlib`. Binary and XML property lists read the same. Text that is
//!   neither (plistlib's `InvalidFileException`) is refused by its header the
//!   same way; malformed XML that plutil repairs or refuses differently from
//!   plistlib may be classified differently. Only string, integer, real and
//!   boolean values convert as `str()` does; a data, date, array or
//!   dictionary value under the three identity keys reads as text.
//! - The harness's source root, where Python uses the services directory's
//!   parent, is the repository this crate was built from
//!   (`CARGO_MANIFEST_DIR/../..`) unless given.
//! - The CLI's argument parsing accepts the same subcommands and options,
//!   `--name value` and `--name=value`, but not argparse's abbreviated
//!   option prefixes; its usage messages differ.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use fancy_regex::Regex;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::store::{
    ARTIFACT_REF, ArtifactStore, FailureInjector, Mutation, Operation, StoreOptions,
};
use crate::sync::{ArtifactSyncEngine, SyncMode, SyncOptions, SyncState};
use crate::{Error, ErrorKind, Result, notes, paths, pystr, rollout};

pub const VERIFICATION_SCHEMA_VERSION: i64 = 1;
pub const INSTALLED_EVIDENCE_SCHEMA_VERSION: i64 = 1;

/// `INSTALLED_SCENARIOS`, sorted.
pub const INSTALLED_SCENARIOS: [&str; 15] = [
    "add_project",
    "archive_history_restore",
    "conflict_ui",
    "create_project",
    "dirty_source_isolation",
    "empty_workspace",
    "explicit_session_scope",
    "filesystem_grant",
    "filesystem_revocation",
    "fresh_install",
    "mounted_workspace",
    "moved_project",
    "offline_project",
    "remove_project",
    "reset_recovery",
];

/// `PROVIDER_DIFFERENCE_IDS`, sorted.
pub const PROVIDER_DIFFERENCE_IDS: [&str; 4] = [
    "authentication",
    "effort_flag",
    "executable_discovery",
    "model_name",
];

/// `SOURCE_MATRIX`: each RR-270 scenario, the test file that covers it and
/// the test names that must remain in it, in Python's order.
pub const SOURCE_MATRIX: [(&str, &str, &[&str]); 11] = [
    (
        "terminal_count_and_exemptions",
        "tests/test_artifact_retention.py",
        &[
            "test_mixed_terminal_pool_uses_one_25_ticket_limit",
            "test_terminal_overage_has_only_bounded_exact_reasons",
            "test_hundreds_of_terminal_tickets_keep_exactly_newest_25",
        ],
    ),
    (
        "archive_restore_dependencies",
        "tests/test_artifact_retention.py",
        &["test_historical_search_detail_restore_and_dependency_resolution"],
    ),
    (
        "remote_archive_transaction",
        "tests/test_artifact_retention.py",
        &[
            "test_archive_failures_preserve_or_recover_projection_from_canonical_ref",
            "test_crash_after_push_is_resolved_by_refetch_without_local_loss",
            "test_remote_archive_failure_never_advances_local_authority",
            "test_remote_race_discards_only_unpublished_candidate_for_safe_replan",
            "test_unconfirmed_non_github_pushurl_never_publishes",
            "test_push_destination_is_revalidated_immediately_before_publication",
            "test_fresh_recovery_materializes_nonterminal_and_newest_25_only",
        ],
    ),
    (
        "prepared_publication_and_exact_ref_recovery",
        "tests/test_artifact_sync.py",
        &[
            "test_prepared_publication_refetches_proofs_before_local_ref_moves",
            "test_fresh_device_recovers_only_exact_remote_artifact_ref",
            "test_second_device_recovery_preserves_manual_materialization_edits",
        ],
    ),
    (
        "sync_conflicts_and_source_isolation",
        "tests/test_artifact_sync.py",
        &[
            "test_two_devices_rebase_unrelated_offline_events_and_preserve_source_state",
            "test_conflict_taxonomy_covers_display_config_attachment_and_delete_edit",
        ],
    ),
    (
        "allowlist_and_privacy",
        "tests/test_artifact_store.py",
        &["test_security_allowlist_rejects_traversal_cross_ticket_raw_audio_secrets_and_traces"],
    ),
    (
        "registry_recovery",
        "tests/RelayRunnerTests/ProjectRegistryV2Tests.swift",
        &[
            "testAtomicStoreRecoversCorruptPrimaryFromLastKnownGoodBackup",
            "testAvailabilitySurfacesStaleMissingOfflineAndMovedStatesWithoutChangingIdentity",
        ],
    ),
    (
        "migration_and_rollback",
        "tests/test_artifact_migration.py",
        &[
            "test_interruption_after_bootstrap_resumes_without_duplicate_commit",
            "test_rollback_after_cutover_restores_exact_legacy_tree_in_new_commit_and_retains_ref",
        ],
    ),
    (
        "fresh_install_and_reset",
        "tests/test_fresh_install.py",
        &[
            "test_normal_reinstall_requires_execute_and_preserves_all_state_and_registered_repositories",
            "test_deliberate_reset_moves_only_owned_state_to_trash_and_restore_is_exact",
        ],
    ),
    (
        "lifecycle_review_failure",
        "tests/test_artifact_lifecycle.py",
        &[
            "test_done_cannot_publish_before_source_merge",
            "test_failure_retry_cancel_merge_conflict_and_restart_leases_are_idempotent",
        ],
    ),
    (
        "provider_parity",
        "tests/test_artifact_lifecycle.py",
        &["test_outcomes_are_bounded_private_and_provider_neutral"],
    ),
];

/// `ArtifactVerificationError(message, code=..., recovery=...)`.
pub fn verification_error(message: impl Into<String>, code: &str, recovery: &str) -> Error {
    Error::new(ErrorKind::Verification, message)
        .with_code(code)
        .with_recovery(recovery)
}

fn require(condition: bool, message: &str) -> Result<()> {
    if condition {
        return Ok(());
    }
    Err(verification_error(
        message,
        "source_harness_failed",
        "Keep rollout cohorts gated, inspect the disposable fixture, and rerun after repair.",
    ))
}

fn dict(entries: Vec<(&str, Value)>) -> Value {
    let mut result = Dict::new();
    for (key, value) in entries {
        result.insert(key, value);
    }
    Value::Dict(result)
}

fn strings<S: AsRef<str>>(values: impl IntoIterator<Item = S>) -> Value {
    Value::List(
        values
            .into_iter()
            .map(|value| Value::Str(value.as_ref().to_string()))
            .collect(),
    )
}

fn raw_digest(content: &[u8]) -> Vec<u8> {
    let hex = hex_digest(content);
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).unwrap_or(0))
        .collect()
}

/// `tempfile.TemporaryDirectory(prefix=...)`: removed with everything in it
/// when dropped.
struct TemporaryDirectory {
    path: PathBuf,
}

impl TemporaryDirectory {
    fn new(prefix: &str) -> Result<Self> {
        let base = std::env::temp_dir();
        for _ in 0..100 {
            let mut bytes = [0u8; 6];
            if fs::File::open("/dev/urandom")
                .and_then(|mut source| source.read_exact(&mut bytes))
                .is_err()
            {
                let nanos = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |elapsed| elapsed.subsec_nanos());
                bytes[..4].copy_from_slice(&nanos.to_le_bytes());
            }
            let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
            let path = base.join(format!("{prefix}{suffix}"));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Err(Error::new(
            ErrorKind::Io,
            "No usable temporary directory name found",
        ))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

type GitCommands = Arc<Mutex<Vec<Vec<String>>>>;

/// `_Device`: one clone with its `_RecordingArtifactStore`.
struct Device {
    name: String,
    repo: PathBuf,
    store: Arc<ArtifactStore>,
    commands: GitCommands,
}

/// `_RecordingArtifactStore(repo, project_id, state, enabled=True)`.
fn recording_store(
    repo: &Path,
    project_id: &str,
    state: &Path,
    failure_injector: Option<FailureInjector>,
) -> Result<(Arc<ArtifactStore>, GitCommands)> {
    let commands: GitCommands = Arc::default();
    let recorder = Arc::clone(&commands);
    let store = ArtifactStore::open(
        repo,
        project_id,
        state,
        StoreOptions {
            enabled: true,
            failure_injector,
            git_observer: Some(Box::new(move |arguments: &[&str]| {
                recorder
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .push(
                        arguments
                            .iter()
                            .map(|argument| argument.to_string())
                            .collect(),
                    );
            })),
            ..StoreOptions::default()
        },
    )?;
    Ok((Arc::new(store), commands))
}

/// `_engine(device, **kwargs)`.
fn engine(
    store: &ArtifactStore,
    failure_injector: Option<FailureInjector>,
    max_attempts: i64,
) -> Result<ArtifactSyncEngine<'_>> {
    let mut options = SyncOptions::new(SyncMode::Enabled, Some("origin"));
    options.max_attempts = max_attempts;
    options.base_retry_seconds = 0.0;
    options.sleep = Box::new(|_| {});
    options.jitter = Box::new(|| 0.0);
    options.failure_injector = failure_injector;
    ArtifactSyncEngine::new(store, options)
}

/// `_ticket_bytes`.
fn ticket_bytes(ticket_id: &str, title: &str, artifact_id: &str) -> Vec<u8> {
    format!(
        "---\nid: {ticket_id}\nartifact_id: {artifact_id}\ntitle: {title}\nstatus: backlog\n---\n\n## Description\n\n{title}\n"
    )
    .into_bytes()
}

/// `_mutation(device, event_id, *operations)`.
fn device_mutation(
    name: &str,
    store: &ArtifactStore,
    event_id: &str,
    operations: Vec<Operation>,
) -> Result<Mutation> {
    let mut mutation = Mutation::new(event_id, "pm", &format!("device-{name}"), operations);
    mutation.provider = Some(if name == "a" { "codex" } else { "claude" }.to_string());
    mutation.expected_base = store.head()?;
    mutation.summary = event_id.to_string();
    Ok(mutation)
}

/// `_ticket_mutation(device, event_id, ticket_id, title)`.
fn ticket_mutation(
    name: &str,
    store: &ArtifactStore,
    event_id: &str,
    ticket_id: &str,
    title: &str,
) -> Result<Mutation> {
    let artifact_id = format!("artifact-{ticket_id}");
    device_mutation(
        name,
        store,
        event_id,
        vec![Operation::TicketWrite {
            ticket_id: ticket_id.to_string(),
            markdown: ticket_bytes(ticket_id, title, &artifact_id),
            artifact_id,
        }],
    )
}

/// `_write_ticket(device, event_id, ticket_id, title)`.
fn write_ticket(
    name: &str,
    store: &ArtifactStore,
    event_id: &str,
    ticket_id: &str,
    title: &str,
) -> Result<String> {
    Ok(store
        .mutate(&ticket_mutation(name, store, event_id, ticket_id, title)?)?
        .commit_id)
}

fn config_text(store: &ArtifactStore) -> Result<String> {
    let snapshot = store.snapshot()?;
    let content = snapshot
        .file(".orchestrator/config.toml")
        .ok_or_else(|| Error::new(ErrorKind::Runtime, "KeyError: '.orchestrator/config.toml'"))?;
    Ok(pystr::decode_utf8(content)?.to_string())
}

/// `_replace_config(content, key, replacement)`.
fn replace_config(content: &str, key: &str, replacement: &str) -> String {
    let mut lines: Vec<String> = pystr::splitlines(content)
        .into_iter()
        .map(str::to_string)
        .collect();
    let prefix = format!("{key} =");
    match lines
        .iter()
        .position(|line| json::py_strip(line).starts_with(&prefix))
    {
        Some(index) => lines[index] = replacement.to_string(),
        None => lines.push(replacement.to_string()),
    }
    lines.join("\n") + "\n"
}

/// `_files_digest(files)`.
fn files_digest(files: &[(String, Vec<u8>)]) -> String {
    let mut sorted: Vec<&(String, Vec<u8>)> = files.iter().collect();
    sorted.sort_by(|left, right| left.0.cmp(&right.0));
    let mut buffer = Vec::new();
    for (path, content) in sorted {
        buffer.extend_from_slice(path.as_bytes());
        buffer.push(0);
        buffer.extend_from_slice(&raw_digest(content));
    }
    hex_digest(&buffer)
}

/// `_classify(message, operation)`.
fn classify(message: &str, operation: &str) -> Result<String> {
    let (state, recovery) = ArtifactSyncEngine::classify_git_failure(message, operation);
    if recovery.is_empty() {
        return Err(verification_error(
            "Failure classification omitted recovery guidance.",
            "missing_recovery_guidance",
            "Restore bounded user-safe recovery text.",
        ));
    }
    Ok(state.value().to_string())
}

/// `_audit_push_commands(devices)`.
fn audit_push_commands(devices: &[&Device]) -> Result<()> {
    let mut pushes: Vec<Vec<String>> = Vec::new();
    for device in devices {
        let commands = device
            .commands
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        pushes.extend(
            commands
                .iter()
                .filter(|command| command.first().is_some_and(|first| first == "push"))
                .cloned(),
        );
    }
    require(
        !pushes.is_empty(),
        "two-device harness observed no artifact pushes",
    )?;
    const DESTRUCTIVE: [&str; 6] = [
        "-f",
        "--force",
        "--force-with-lease",
        "--mirror",
        "--all",
        "--delete",
    ];
    for command in &pushes {
        require(
            !command.iter().any(|argument| {
                DESTRUCTIVE.contains(&argument.as_str()) || argument.starts_with("--force=")
            }),
            "artifact publication exposed a destructive push option",
        )?;
        let refspecs: Vec<&String> = command
            .iter()
            .filter(|argument| argument.contains(':') && !argument.starts_with("--"))
            .collect();
        require(
            refspecs.len() == 1,
            "artifact push did not use one exact refspec",
        )?;
        require(
            refspecs[0].split_once(':').map(|(_, target)| target) == Some(ARTIFACT_REF),
            "artifact push targeted a non-artifact ref",
        )?;
    }
    Ok(())
}

/// `_source_snapshot(repo)`: everything about a source checkout that
/// artifact synchronization must leave alone.
#[derive(Debug, PartialEq, Eq)]
struct SourceSnapshot {
    head: String,
    status: String,
    refs: Vec<String>,
    remotes_sha256: String,
    index: String,
    files: BTreeMap<String, String>,
}

/// `RR289SourceVerificationHarness`: real two-clone artifact operations in a
/// disposable directory, never touching user repositories or remotes.
pub struct SourceVerificationHarness {
    pub git_binary: String,
    /// The checkout whose tests the source matrix audits.
    pub source_root: PathBuf,
}

impl Default for SourceVerificationHarness {
    fn default() -> Self {
        Self {
            git_binary: "git".to_string(),
            source_root: PathBuf::from(paths::resolve(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.."
            ))),
        }
    }
}

impl SourceVerificationHarness {
    /// `run()`.
    pub fn run(&self) -> Result<Value> {
        let temporary = TemporaryDirectory::new("relay-rr289-")?;
        let root = temporary.path.clone();
        let mut scenarios = Dict::new();
        scenarios.insert(
            "unrelated_offline_edits",
            self.unrelated_offline(&root.join("offline"))?,
        );
        for kind in ["same_ticket", "config_collision", "attachment_collision"] {
            scenarios.insert(
                kind,
                self.conflict_fixture(&root.join(format!("conflict-{kind}")), kind)?,
            );
        }
        scenarios.insert("push_race", self.push_race(&root.join("push-race"))?);
        scenarios.insert(
            "writer_restart_recovery",
            self.writer_restart_recovery(&root.join("writer-recovery"))?,
        );
        scenarios.insert(
            "provider_parity",
            self.provider_parity(&root.join("provider-parity"))?,
        );
        let source_matrix = source_matrix_status(&self.source_root)?;
        let covered = || Value::from("covered_by_source_matrix");
        let passed = || Value::from("passed");
        let mut report = dict(vec![
            ("schema_version", Value::Int(VERIFICATION_SCHEMA_VERSION)),
            ("status", passed()),
            ("harness", Value::from("disposable_two_device_remote")),
            ("device_count", Value::Int(2)),
            ("scenarios", Value::Dict(scenarios)),
            (
                "failure_classification",
                dict(vec![
                    ("registry_corruption", covered()),
                    ("writer_crash", passed()),
                    ("cas_conflict", passed()),
                    ("materialization_conflict", passed()),
                    ("daemon_restart", passed()),
                    (
                        "authentication",
                        Value::Str(classify("Authentication failed", "fetch")?),
                    ),
                    (
                        "offline",
                        Value::Str(classify("Could not resolve host example.invalid", "fetch")?),
                    ),
                    ("push_race", passed()),
                    ("missing_objects", covered()),
                    ("interrupted_migration", covered()),
                    ("review_merge_failure", covered()),
                    ("rollback", covered()),
                    ("recursive_retry", Value::from("bounded")),
                ]),
            ),
            ("source_matrix", source_matrix),
            (
                "privacy",
                dict(vec![
                    ("contains_paths", Value::Bool(false)),
                    ("contains_raw_logs", Value::Bool(false)),
                    ("contains_transcripts", Value::Bool(false)),
                    ("contains_hidden_reasoning", Value::Bool(false)),
                ]),
            ),
        ]);
        let digest = rollout::privacy_safe_report_digest(&report)?;
        if let Value::Dict(fields) = &mut report {
            fields.insert("report_sha256", digest);
        }
        Ok(report)
    }

    fn unrelated_offline(&self, root: &Path) -> Result<Value> {
        let (a, b) = self.make_fixture(root)?;
        write_ticket(&a.name, &a.store, "base-ticket", "RR-1", "Base")?;
        engine(&a.store, None, 3)?.sync()?;
        engine(&b.store, None, 3)?.sync()?;
        write_ticket(&a.name, &a.store, "offline-a", "RR-2", "Device A")?;
        write_ticket(&b.name, &b.store, "offline-b", "RR-3", "Device B")?;
        self.make_dirty_source(&b.repo)?;
        let before = self.source_snapshot(&b.repo)?;
        let remote = root.join("remote.git");
        let source_remote_before =
            self.git(Some(&remote), &["rev-parse", "refs/heads/main"], &[0])?;
        let first = engine(&a.store, None, 3)?.sync()?;
        let second = engine(&b.store, None, 3)?.sync()?;
        let after = self.source_snapshot(&b.repo)?;
        let source_remote_after =
            self.git(Some(&remote), &["rev-parse", "refs/heads/main"], &[0])?;
        let snapshot = b.store.snapshot()?;
        require(
            first.state == SyncState::Clean,
            "device A did not publish cleanly",
        )?;
        require(
            second.state == SyncState::Clean,
            "device B did not rebase cleanly",
        )?;
        require(
            second.observed_state == SyncState::Conflict,
            "offline divergence was not observed before unrelated replay",
        )?;
        require(
            before == after,
            "artifact synchronization changed dirty source state",
        )?;
        require(
            source_remote_before == source_remote_after,
            "artifact synchronization changed the remote source branch",
        )?;
        require(
            snapshot.file(".orchestrator/RR-2.md").is_some()
                && snapshot.file(".orchestrator/RR-3.md").is_some(),
            "unrelated offline ticket events did not both survive",
        )?;
        audit_push_commands(&[&a, &b])?;
        Ok(dict(vec![
            ("outcome", Value::from("passed")),
            ("observed_state", Value::from(second.observed_state.value())),
            ("final_state", Value::from(second.state.value())),
            ("source_state_unchanged", Value::Bool(true)),
            ("remote_source_ref_unchanged", Value::Bool(true)),
            ("both_events_present", Value::Bool(true)),
        ]))
    }

    fn conflict_fixture(&self, root: &Path, kind: &str) -> Result<Value> {
        let (a, b) = self.make_fixture(root)?;
        match kind {
            "same_ticket" => {
                write_ticket(&a.name, &a.store, "shared-base", "RR-4", "Shared")?;
                engine(&a.store, None, 3)?.sync()?;
                engine(&b.store, None, 3)?.sync()?;
                a.store.mutate(&ticket_mutation(
                    &a.name, &a.store, "edit-a", "RR-4", "From A",
                )?)?;
                b.store.mutate(&ticket_mutation(
                    &b.name, &b.store, "edit-b", "RR-4", "From B",
                )?)?;
            }
            "config_collision" => {
                self.write_config_next_id(&a, "config-a", 20)?;
                self.write_config_next_id(&b, "config-b", 30)?;
            }
            "attachment_collision" => {
                for (device, event, marker) in
                    [(&a, "attachment-a", b'A'), (&b, "attachment-b", b'B')]
                {
                    let mut content = b"\x89PNG\r\n\x1a\n".to_vec();
                    content.push(marker);
                    device.store.mutate(&device_mutation(
                        &device.name,
                        &device.store,
                        event,
                        vec![Operation::AttachmentWrite {
                            ticket_id: "RR-5".to_string(),
                            filename: "same.png".to_string(),
                            mime_type: "image/png".to_string(),
                            content,
                        }],
                    )?)?;
                }
            }
            other => {
                return Err(Error::new(
                    ErrorKind::Runtime,
                    format!("AssertionError: {other}"),
                ));
            }
        }
        let before = self.source_snapshot(&b.repo)?;
        engine(&a.store, None, 3)?.sync()?;
        let remote = root.join("remote.git");
        let remote_before = self.git(Some(&remote), &["rev-parse", ARTIFACT_REF], &[0])?;
        let result = engine(&b.store, None, 3)?.sync()?;
        let remote_after = self.git(Some(&remote), &["rev-parse", ARTIFACT_REF], &[0])?;
        require(
            result.state == SyncState::Conflict,
            &format!("{kind} did not stop"),
        )?;
        let Some(report) = &result.conflict_report else {
            return require(false, &format!("{kind} lacks three-way evidence"))
                .map(|()| Value::Null);
        };
        let found: BTreeSet<&str> = report
            .conflicts
            .iter()
            .map(|conflict| conflict.kind.as_str())
            .collect();
        require(
            found.contains(kind),
            &format!(
                "{kind} evidence was classified as [{}]",
                found
                    .iter()
                    .map(|item| pystr::repr(item))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )?;
        require(
            remote_before == remote_after,
            &format!("{kind} published without resolution"),
        )?;
        require(
            before == self.source_snapshot(&b.repo)?,
            &format!("{kind} changed source state"),
        )?;
        audit_push_commands(&[&a, &b])?;
        Ok(dict(vec![
            ("outcome", Value::from("passed")),
            ("state", Value::from(result.state.value())),
            ("conflict_kind", Value::from(kind)),
            ("three_way_evidence", Value::Bool(true)),
            ("publication_stopped", Value::Bool(true)),
            ("source_state_unchanged", Value::Bool(true)),
        ]))
    }

    fn push_race(&self, root: &Path) -> Result<Value> {
        let (a, b) = self.make_fixture(root)?;
        write_ticket(&b.name, &b.store, "race-b", "RR-6", "Device B")?;
        let injected = Arc::new(AtomicBool::new(false));
        let advance: FailureInjector = {
            let injected = Arc::clone(&injected);
            let store = Arc::clone(&a.store);
            let name = a.name.clone();
            Box::new(move |stage: &str| {
                if stage == "before_push" && !injected.swap(true, Ordering::SeqCst) {
                    write_ticket(&name, &store, "race-a", "RR-7", "Device A")?;
                    engine(&store, None, 3)?.sync()?;
                }
                Ok(())
            })
        };
        let result = engine(&b.store, Some(advance), 3)?.sync()?;
        require(
            result.state == SyncState::Clean,
            "push race did not recover",
        )?;
        require(
            result.attempts == 2,
            "push race did not use one bounded retry",
        )?;
        let messages = self.git(Some(&b.repo), &["log", "--format=%B", ARTIFACT_REF], &[0])?;
        require(
            messages.matches("Relay-Event-ID: race-b").count() == 1,
            "push race duplicated event",
        )?;
        audit_push_commands(&[&a, &b])?;
        Ok(dict(vec![
            ("outcome", Value::from("passed")),
            ("attempts", Value::Int(result.attempts)),
            ("event_count", Value::Int(1)),
            ("force_push", Value::Bool(false)),
        ]))
    }

    fn writer_restart_recovery(&self, root: &Path) -> Result<Value> {
        fs::create_dir_all(root)?;
        let repo = root.join("repo");
        fs::create_dir(&repo)?;
        self.git(
            Some(&repo),
            &["init", "--initial-branch=main", "--quiet"],
            &[0],
        )?;
        fs::write(repo.join("source.txt"), "source\n")?;
        self.commit_source(&repo, "source")?;
        let state = root.join("state");
        // Python sets the injector after `initialize`; arming it then is the
        // same thing.
        let armed = Arc::new(AtomicBool::new(false));
        let crashed = Arc::new(AtomicBool::new(false));
        let injector: FailureInjector = {
            let armed = Arc::clone(&armed);
            let crashed = Arc::clone(&crashed);
            Box::new(move |stage: &str| {
                if armed.load(Ordering::SeqCst)
                    && stage == "after_ref_update"
                    && !crashed.swap(true, Ordering::SeqCst)
                {
                    return Err(Error::new(ErrorKind::Runtime, "injected after-ref crash"));
                }
                Ok(())
            })
        };
        let (store, _) = recording_store(&repo, "project-recovery", &state, Some(injector))?;
        store.initialize("recovery-device", "system")?;
        armed.store(true, Ordering::SeqCst);
        let ticket = |ticket_id: &str, title: &str| {
            let artifact_id = format!("artifact-{ticket_id}");
            Operation::TicketWrite {
                ticket_id: ticket_id.to_string(),
                markdown: ticket_bytes(ticket_id, title, &artifact_id),
                artifact_id,
            }
        };
        let mut mutation = Mutation::new(
            "recover-ticket",
            "pm",
            "recovery-device",
            vec![ticket("RR-8", "Recover")],
        );
        mutation.provider = Some("codex".to_string());
        mutation.expected_base = store.head()?;
        match store.mutate(&mutation) {
            Err(error)
                if crashed.load(Ordering::SeqCst)
                    && error.kind == ErrorKind::Runtime
                    && error.message == "injected after-ref crash" => {}
            Err(error) => return Err(error),
            Ok(_) => require(false, "writer failure injection did not fire")?,
        }
        drop(store);
        let (restarted, _) = recording_store(&repo, "project-recovery", &state, None)?;
        let recovered_head = restarted.recover()?;
        let retry = restarted.mutate(&mutation)?;
        require(
            retry.idempotent,
            "writer restart duplicated its immutable event",
        )?;
        require(
            retry.commit_id == recovered_head,
            "recovered event points to another commit",
        )?;

        let stale = restarted.head()?;
        write_ticket("restart", &restarted, "advance-head", "RR-9", "Advance")?;
        let mut stale_mutation = Mutation::new(
            "stale-cas",
            "pm",
            "recovery-device",
            vec![ticket("RR-10", "Stale")],
        );
        stale_mutation.expected_base = stale;
        let cas_stopped = match restarted.mutate(&stale_mutation) {
            Err(error) if error.kind == ErrorKind::ConcurrentUpdate => true,
            Err(error) => return Err(error),
            Ok(_) => false,
        };
        require(cas_stopped, "stale artifact CAS did not stop")?;

        let config_path = repo.join(".orchestrator/config.toml");
        let original = fs::read(&config_path)?;
        let mut diverged = original.clone();
        diverged.extend_from_slice(b"# unreviewed divergence\n");
        fs::write(&config_path, diverged)?;
        let mut blocked = Mutation::new(
            "materialization-conflict",
            "pm",
            "recovery-device",
            vec![ticket("RR-11", "Blocked")],
        );
        blocked.expected_base = restarted.head()?;
        let materialization_stopped = match restarted.mutate(&blocked) {
            Err(error) if error.kind == ErrorKind::MaterializationConflict => true,
            Err(error) => return Err(error),
            Ok(_) => false,
        };
        require(
            materialization_stopped,
            "materialization divergence did not stop",
        )?;
        restarted.recover()?;
        require(
            fs::read(&config_path)? == original,
            "forced recovery did not restore canonical bytes",
        )?;
        Ok(dict(vec![
            ("outcome", Value::from("passed")),
            ("after_ref_restart", Value::from("recovered")),
            ("event_idempotent", Value::Bool(true)),
            ("stale_cas", Value::from("stopped")),
            (
                "materialization_divergence",
                Value::from("stopped_then_recovered"),
            ),
        ]))
    }

    fn provider_parity(&self, root: &Path) -> Result<Value> {
        let mut hashes = BTreeMap::new();
        for provider in ["codex", "claude"] {
            let repo = root.join(provider).join("repo");
            fs::create_dir_all(&repo)?;
            self.git(
                Some(&repo),
                &["init", "--initial-branch=main", "--quiet"],
                &[0],
            )?;
            fs::write(repo.join("source.txt"), "same source\n")?;
            self.commit_source(&repo, "source")?;
            let (store, _) = recording_store(
                &repo,
                "provider-project",
                &root.join(provider).join("state"),
                None,
            )?;
            store.initialize("provider-device", "system")?;
            let artifact_id = "artifact-RR-12".to_string();
            let mut mutation = Mutation::new(
                "provider-equivalent",
                "pm",
                "provider-device",
                vec![Operation::TicketWrite {
                    ticket_id: "RR-12".to_string(),
                    markdown: ticket_bytes("RR-12", "Provider neutral", &artifact_id),
                    artifact_id,
                }],
            );
            mutation.provider = Some(provider.to_string());
            mutation.expected_base = store.head()?;
            store.mutate(&mutation)?;
            // Python passes the provider to `snapshot`, which ignores it.
            let snapshot = store.snapshot()?;
            hashes.insert(provider, files_digest(&snapshot.files));
        }
        require(
            hashes["codex"] == hashes["claude"],
            "provider snapshots differ",
        )?;
        Ok(dict(vec![
            ("outcome", Value::from("passed")),
            ("providers", strings(["codex", "claude"])),
            ("snapshot_sha256", Value::Str(hashes["codex"].clone())),
            ("intentional_differences", strings(PROVIDER_DIFFERENCE_IDS)),
        ]))
    }

    fn make_fixture(&self, root: &Path) -> Result<(Device, Device)> {
        fs::create_dir_all(root)?;
        let remote = root.join("remote.git");
        let remote_text = remote.to_string_lossy().into_owned();
        self.git(None, &["init", "--bare", "--quiet", &remote_text], &[0])?;
        self.git(
            Some(&remote),
            &["symbolic-ref", "HEAD", "refs/heads/main"],
            &[0],
        )?;
        let repo_a = root.join("device-a");
        fs::create_dir(&repo_a)?;
        self.git(
            Some(&repo_a),
            &["init", "--initial-branch=main", "--quiet"],
            &[0],
        )?;
        fs::write(repo_a.join("source.txt"), "source\n")?;
        self.commit_source(&repo_a, "source root")?;
        self.git(
            Some(&repo_a),
            &["remote", "add", "origin", &remote_text],
            &[0],
        )?;
        self.git(Some(&repo_a), &["push", "-q", "-u", "origin", "main"], &[0])?;
        let (store_a, commands_a) =
            recording_store(&repo_a, "project-two-device", &root.join("state-a"), None)?;
        let a = Device {
            name: "a".to_string(),
            repo: repo_a,
            store: store_a,
            commands: commands_a,
        };
        let initialized = a.store.initialize("device-a", "system")?;
        self.enable_remote(&a, &initialized.commit_id)?;
        engine(&a.store, None, 3)?.publish_initial(true)?;
        let repo_b = root.join("device-b");
        let repo_b_text = repo_b.to_string_lossy().into_owned();
        self.git(None, &["clone", "-q", &remote_text, &repo_b_text], &[0])?;
        let refspec = format!("{ARTIFACT_REF}:{ARTIFACT_REF}");
        self.git(
            Some(&repo_b),
            &["fetch", "-q", "--no-tags", "origin", &refspec],
            &[0],
        )?;
        let (store_b, commands_b) =
            recording_store(&repo_b, "project-two-device", &root.join("state-b"), None)?;
        let b = Device {
            name: "b".to_string(),
            repo: repo_b,
            store: store_b,
            commands: commands_b,
        };
        b.store.initialize("device-b", "system")?;
        Ok((a, b))
    }

    fn enable_remote(&self, device: &Device, expected_base: &str) -> Result<()> {
        let mut content = config_text(&device.store)?;
        content = replace_config(&content, "remote_sync", "remote_sync = \"enabled\"");
        content = replace_config(&content, "remote_name", "remote_name = \"origin\"");
        let mut mutation = Mutation::new(
            &format!("enable-{}", device.name),
            "user",
            &format!("device-{}", device.name),
            vec![Operation::ConfigWrite {
                content: content.into_bytes(),
            }],
        );
        mutation.expected_base = Some(expected_base.to_string());
        device.store.mutate(&mutation)?;
        Ok(())
    }

    fn write_config_next_id(&self, device: &Device, event_id: &str, next_id: i64) -> Result<()> {
        let content = config_text(&device.store)?;
        let pattern = Regex::new(r"(?m)^next_id\s*=.*$")
            .map_err(|error| Error::new(ErrorKind::Runtime, error.to_string()))?;
        let replaced = pattern
            .replace_all(&content, format!("next_id = {next_id}").as_str())
            .into_owned();
        device.store.mutate(&device_mutation(
            &device.name,
            &device.store,
            event_id,
            vec![Operation::ConfigWrite {
                content: replaced.into_bytes(),
            }],
        )?)?;
        Ok(())
    }

    fn make_dirty_source(&self, repo: &Path) -> Result<()> {
        fs::write(repo.join("ahead.txt"), "ahead\n")?;
        self.commit_source(repo, "local ahead")?;
        fs::write(repo.join("source.txt"), "unstaged\n")?;
        fs::write(repo.join("staged.txt"), "staged\n")?;
        self.git(Some(repo), &["add", "staged.txt"], &[0])?;
        fs::write(repo.join("untracked.txt"), "untracked\n")?;
        Ok(())
    }

    fn source_snapshot(&self, repo: &Path) -> Result<SourceSnapshot> {
        let mut index =
            PathBuf::from(self.git(Some(repo), &["rev-parse", "--git-path", "index"], &[0])?);
        if !index.is_absolute() {
            index = repo.join(index);
        }
        let mut refs: Vec<String> =
            pystr::splitlines(&self.git(Some(repo), &["show-ref"], &[0, 1])?)
                .into_iter()
                .filter(|line| {
                    !line.ends_with(&format!(" {ARTIFACT_REF}"))
                        && !line.contains("/relay/artifacts")
                        && !line.contains("refs/relay-runner/sync/")
                })
                .map(str::to_string)
                .collect();
        refs.sort();
        let mut files = BTreeMap::new();
        collect_source_files(repo, repo, &mut files)?;
        Ok(SourceSnapshot {
            head: self.git(Some(repo), &["rev-parse", "HEAD"], &[0])?,
            status: self.git(
                Some(repo),
                &["status", "--porcelain=v1", "--untracked-files=all"],
                &[0],
            )?,
            refs,
            remotes_sha256: hex_digest(self.git(Some(repo), &["remote", "-v"], &[0])?.as_bytes()),
            index: hex_digest(&fs::read(&index)?),
            files,
        })
    }

    fn commit_source(&self, repo: &Path, message: &str) -> Result<()> {
        self.git(Some(repo), &["add", "-A"], &[0])?;
        self.git(
            Some(repo),
            &[
                "-c",
                "user.name=Relay Verification",
                "-c",
                "user.email=relay-verification@example.invalid",
                "commit",
                "-q",
                "-m",
                message,
            ],
            &[0],
        )?;
        Ok(())
    }

    /// `_git(repo, *arguments, allowed=...)`: the caller's environment with
    /// the C locale; stripped stdout.
    fn git(&self, repo: Option<&Path>, arguments: &[&str], allowed: &[i32]) -> Result<String> {
        let mut command = Command::new(&self.git_binary);
        if let Some(repo) = repo {
            command.arg("-C").arg(repo);
        }
        let output = command
            .args(arguments)
            .env("LC_ALL", "C")
            .stdin(Stdio::inherit())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|error| {
                // `str(FileNotFoundError)`: the strerror text without Rust's
                // " (os error N)" suffix.
                let text = error.to_string();
                let message = text
                    .rfind(" (os error ")
                    .map_or(text.as_str(), |end| &text[..end]);
                Error::new(
                    ErrorKind::Io,
                    format!(
                        "[Errno {}] {message}: {}",
                        error.raw_os_error().unwrap_or(0),
                        pystr::repr(&self.git_binary)
                    ),
                )
            })?;
        let status = output.status.code().unwrap_or(-1);
        if output.status.code().is_none() || !allowed.contains(&status) {
            return Err(verification_error(
                format!(
                    "Disposable Git fixture failed during {}.",
                    arguments.first().copied().unwrap_or("operation")
                ),
                "disposable_git_failure",
                "Verify local Git availability and rerun the disposable RR-289 harness.",
            ));
        }
        Ok(json::py_strip(&String::from_utf8_lossy(&output.stdout)).to_string())
    }
}

/// The files `_source_snapshot` hashes: every regular file (through a
/// symlink) outside `.git` and `.orchestrator`, as `Path.rglob` walks it
/// without entering symlinked directories.
fn collect_source_files(
    repo: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, String>,
) -> Result<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned());
        if matches!(name.as_deref(), Some(".git" | ".orchestrator")) {
            continue;
        }
        let link = fs::symlink_metadata(&path)?;
        if link.is_dir() {
            collect_source_files(repo, &path, files)?;
            continue;
        }
        if fs::metadata(&path).is_ok_and(|metadata| metadata.is_file()) {
            let relative = path
                .strip_prefix(repo)
                .map(|relative| relative.to_string_lossy().into_owned())
                .unwrap_or_default();
            files.insert(relative, hex_digest(&fs::read(&path)?));
        }
    }
    Ok(())
}

/// `RR289SourceVerificationHarness.audit_source_matrix(repo_root)`.
pub fn audit_source_matrix(repo_root: &Path) -> Result<Value> {
    let mut result = Dict::new();
    for (scenario, relative, needles) in SOURCE_MATRIX {
        let path = repo_root.join(relative);
        if !path.is_file() {
            return Err(verification_error(
                format!("RR-270 source matrix file is missing: {relative}"),
                "source_matrix_missing",
                "Restore the named test file and rerun the full source suites.",
            ));
        }
        let bytes = fs::read(&path)?;
        let content = pystr::universal_newlines(pystr::decode_utf8(&bytes)?);
        if needles.iter().any(|needle| !content.contains(needle)) {
            return Err(verification_error(
                format!("RR-270 source matrix coverage changed for {scenario}."),
                "source_matrix_changed",
                "Review and update the named scenario with equivalent or stronger tests.",
            ));
        }
        result.insert(scenario, "present");
    }
    Ok(Value::Dict(result))
}

/// `RR289SourceVerificationHarness.source_matrix_status(root)`.
pub fn source_matrix_status(root: &Path) -> Result<Value> {
    if root.join("tests").is_dir() {
        return audit_source_matrix(root);
    }
    let mut result = Dict::new();
    for (scenario, _, _) in SOURCE_MATRIX {
        result.insert(scenario, "external_source_report_required");
    }
    Ok(Value::Dict(result))
}

/// `InstalledBundleIdentity`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstalledBundleIdentity {
    pub version: String,
    pub build_number: String,
    pub bundle_identifier: String,
    pub bundle_sha256: String,
    pub signer_team_id: String,
    pub developer_id_signed: bool,
    pub code_signature_valid: bool,
    pub installed_in_applications: bool,
}

impl InstalledBundleIdentity {
    /// `dataclasses.asdict(identity)`.
    pub fn as_dict(&self) -> Value {
        dict(vec![
            ("version", Value::from(self.version.as_str())),
            ("build_number", Value::from(self.build_number.as_str())),
            (
                "bundle_identifier",
                Value::from(self.bundle_identifier.as_str()),
            ),
            ("bundle_sha256", Value::from(self.bundle_sha256.as_str())),
            ("signer_team_id", Value::from(self.signer_team_id.as_str())),
            ("developer_id_signed", Value::Bool(self.developer_id_signed)),
            (
                "code_signature_valid",
                Value::Bool(self.code_signature_valid),
            ),
            (
                "installed_in_applications",
                Value::Bool(self.installed_in_applications),
            ),
        ])
    }

    /// The identity from `as_dict()`'s shape; missing text reads as empty.
    pub fn from_dict(value: &Dict) -> Self {
        let text = |key: &str| value.get(key).map(Value::py_str).unwrap_or_default();
        let flag = |key: &str| value.get(key).is_some_and(Value::truthy);
        Self {
            version: text("version"),
            build_number: text("build_number"),
            bundle_identifier: text("bundle_identifier"),
            bundle_sha256: text("bundle_sha256"),
            signer_team_id: text("signer_team_id"),
            developer_id_signed: flag("developer_id_signed"),
            code_signature_valid: flag("code_signature_valid"),
            installed_in_applications: flag("installed_in_applications"),
        }
    }

    fn bundle(&self) -> Value {
        dict(vec![
            ("version", Value::from(self.version.as_str())),
            ("build_number", Value::from(self.build_number.as_str())),
            (
                "bundle_identifier",
                Value::from(self.bundle_identifier.as_str()),
            ),
            ("bundle_sha256", Value::from(self.bundle_sha256.as_str())),
            ("signer_team_id", Value::from(self.signer_team_id.as_str())),
        ])
    }
}

/// A finished command, as `subprocess.CompletedProcess` carries it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CommandOutput {
    pub returncode: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// The gate's `runner`: runs one command line.
pub type Runner = Box<dyn Fn(&[String]) -> Result<CommandOutput> + Send + Sync>;

/// `SignedInstalledAppGate._run`.
pub fn run_command(command: &[String]) -> Result<CommandOutput> {
    let output = Command::new(&command[0])
        .args(&command[1..])
        .stdin(Stdio::inherit())
        .output()?;
    Ok(CommandOutput {
        returncode: output.status.code().unwrap_or(-1),
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

/// `SignedInstalledAppGate`: bundle identity and bounded two-device manual
/// evidence.
pub struct SignedInstalledAppGate {
    runner: Runner,
}

impl Default for SignedInstalledAppGate {
    fn default() -> Self {
        Self::new(None)
    }
}

fn invalid_evidence(message: &str, recovery: &str) -> Error {
    verification_error(message, "invalid_installed_evidence", recovery)
}

fn keys(dict: &Dict) -> BTreeSet<&str> {
    dict.iter().map(|(key, _)| key).collect()
}

fn same_keys(dict: &Dict, expected: &[&str]) -> bool {
    keys(dict) == expected.iter().copied().collect()
}

/// `value not in {...}` for a JSON value against strings; a list or object
/// is unhashable and raises `TypeError`.
fn not_in(value: &Value, allowed: &[&str]) -> Result<bool> {
    match value {
        Value::List(_) => Err(notes::unhashable("list")),
        Value::Dict(_) => Err(notes::unhashable("dict")),
        Value::Str(text) => Ok(!allowed.contains(&text.as_str())),
        _ => Ok(true),
    }
}

fn hex64(value: &Value) -> bool {
    value.as_str().is_some_and(|text| {
        text.len() == 64
            && text
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

fn os_version(value: &Value) -> bool {
    let Some(text) = value.as_str() else {
        return false;
    };
    let mut characters = text.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && text.chars().count() <= 32
        && characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | '-')
        })
}

/// The outcome checks of one device's `scenarios` or `providers` mapping,
/// in Python's short-circuit order.
fn outcomes_valid(value: &Value, allowed_keys: &[&str]) -> Result<bool> {
    let Some(outcomes) = value.as_dict() else {
        return Ok(false);
    };
    if !outcomes.iter().all(|(key, _)| allowed_keys.contains(&key)) {
        return Ok(false);
    }
    for (_, outcome) in outcomes.iter() {
        if not_in(outcome, &["passed", "failed"])? {
            return Ok(false);
        }
    }
    Ok(true)
}

/// The first `TeamIdentifier=`, `Signature=` and every `Authority=` line,
/// as the gate's multiline regular expressions read `codesign -dv`.
fn signing_details(text: &str) -> (String, String, Vec<String>) {
    let mut team = None;
    let mut signature = None;
    let mut authorities = Vec::new();
    for line in text.split('\n') {
        if team.is_none()
            && let Some(rest) = line.strip_prefix("TeamIdentifier=")
            && !rest.is_empty()
            && !rest.chars().any(json::py_is_space)
        {
            team = Some(rest.to_string());
        }
        if signature.is_none()
            && let Some(rest) = line.strip_prefix("Signature=")
            && !rest.is_empty()
        {
            signature = Some(json::py_strip(rest).to_lowercase());
        }
        if let Some(rest) = line.strip_prefix("Authority=")
            && !rest.is_empty()
        {
            authorities.push(rest.to_string());
        }
    }
    (
        team.unwrap_or_default(),
        signature.unwrap_or_default(),
        authorities,
    )
}

impl SignedInstalledAppGate {
    pub fn new(runner: Option<Runner>) -> Self {
        Self {
            runner: runner.unwrap_or_else(|| Box::new(run_command)),
        }
    }

    /// `inspect(app_path, require_applications=...)`.
    pub fn inspect(
        &self,
        app_path: &str,
        require_applications: bool,
    ) -> Result<InstalledBundleIdentity> {
        let app = PathBuf::from(paths::resolve(&paths::expanduser(app_path)?));
        let expected = PathBuf::from(paths::resolve("/Applications/Relay Runner.app"));
        let installed = app == expected;
        if require_applications && !installed {
            return Err(verification_error(
                "Signed installed verification requires /Applications/Relay Runner.app.",
                "app_not_installed",
                "Use the preserving fresh-install workflow, then rerun against the installed app.",
            ));
        }
        let info = read_info_plist(&app.join("Contents/Info.plist"))?;
        let app_text = app.to_string_lossy().into_owned();
        let command = |arguments: &[&str]| -> Vec<String> {
            arguments
                .iter()
                .map(|argument| argument.to_string())
                .chain([app_text.clone()])
                .collect()
        };
        let verify = (self.runner)(&command(&[
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
        ]))?;
        let details = (self.runner)(&command(&["/usr/bin/codesign", "-dv", "--verbose=4"]))?;
        let mut combined = details.stdout.clone();
        combined.extend_from_slice(&details.stderr);
        let (team, signature, authorities) = signing_details(&String::from_utf8_lossy(&combined));
        let developer_signed = !team.is_empty()
            && !matches!(team.to_lowercase().as_str(), "not set" | "none")
            && signature != "adhoc"
            && authorities.iter().any(|authority| {
                let authority = json::py_strip(authority);
                authority == "Developer ID Application"
                    || authority.starts_with("Developer ID Application:")
            });
        let value = |key: &str| info.get(key).cloned().unwrap_or_default();
        let identity = InstalledBundleIdentity {
            version: value("CFBundleShortVersionString"),
            build_number: value("CFBundleVersion"),
            bundle_identifier: value("CFBundleIdentifier"),
            bundle_sha256: bundle_digest(&app)?,
            signer_team_id: team,
            developer_id_signed: developer_signed,
            code_signature_valid: verify.returncode == 0 && details.returncode == 0,
            installed_in_applications: installed,
        };
        if identity.bundle_identifier != "com.relayrunner.app" {
            return Err(verification_error(
                "Installed app has an unexpected bundle identifier.",
                "installed_bundle_identity_mismatch",
                "Install the reviewed Relay Runner bundle and retry.",
            ));
        }
        if !identity.code_signature_valid || !identity.developer_id_signed {
            return Err(verification_error(
                "Installed app is not validly Developer ID signed.",
                "signed_installed_build_required",
                "Build with SIGN_IDENTITY, install the signed app, and rerun the installed gate.",
            ));
        }
        Ok(identity)
    }

    /// `evaluate(identity, evidence)`.
    pub fn evaluate(&self, identity: &InstalledBundleIdentity, evidence: &Dict) -> Result<Value> {
        validate_evidence_shape(evidence)?;
        let mut blockers: Vec<String> = Vec::new();
        let bundle = evidence.get("bundle").cloned().unwrap_or(Value::Null);
        if !json::py_eq(&bundle, &identity.bundle()) {
            blockers.push("bundle_identity_mismatch".to_string());
        }
        let devices: Vec<&Dict> = evidence
            .get("devices")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .collect();
        let identifiers: BTreeSet<String> = devices
            .iter()
            .map(|item| item.text("device_id_sha256"))
            .collect();
        if identifiers.len() < 2 {
            blockers.push("two_distinct_devices_required".to_string());
        }
        let passed = |field: &str| -> BTreeSet<String> {
            devices
                .iter()
                .flat_map(|item| {
                    item.get(field)
                        .and_then(Value::as_dict)
                        .map(|outcomes| {
                            outcomes
                                .iter()
                                .filter(|(_, outcome)| outcome.is_str("passed"))
                                .map(|(key, _)| key.to_string())
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default()
                })
                .collect()
        };
        let covered = passed("scenarios");
        for scenario in INSTALLED_SCENARIOS {
            if !covered.contains(scenario) {
                blockers.push(format!("scenario_missing:{scenario}"));
            }
        }
        let providers = passed("providers");
        if providers
            != ["claude", "codex"]
                .iter()
                .map(|name| name.to_string())
                .collect()
        {
            blockers.push("installed_provider_parity_required".to_string());
        }
        let differences: BTreeSet<String> = evidence
            .get("intentional_provider_differences")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .collect();
        if differences
            != PROVIDER_DIFFERENCE_IDS
                .iter()
                .map(|name| name.to_string())
                .collect()
        {
            blockers.push("provider_difference_record_incomplete".to_string());
        }
        let blocked = !blockers.is_empty();
        let mut report = dict(vec![
            ("schema_version", Value::Int(VERIFICATION_SCHEMA_VERSION)),
            (
                "status",
                Value::from(if blocked {
                    "verification_blocked"
                } else {
                    "passed"
                }),
            ),
            ("bundle", identity.as_dict()),
            ("device_count", Value::Int(identifiers.len() as i64)),
            ("scenario_count", Value::Int(covered.len() as i64)),
            ("providers", strings(&providers)),
            ("intentional_provider_differences", strings(&differences)),
            ("blocker_codes", strings(&blockers)),
            (
                "resume_condition",
                if blocked {
                    Value::from(
                        "Install the exact Developer ID signed build on two devices and record every missing mounted Workspace and provider scenario in one bounded evidence manifest.",
                    )
                } else {
                    Value::Null
                },
            ),
        ]);
        let digest = rollout::privacy_safe_report_digest(&report)?;
        if let Value::Dict(fields) = &mut report {
            fields.insert("report_sha256", digest);
        }
        Ok(report)
    }

    /// `evidence_template(identity)`.
    pub fn evidence_template(identity: &InstalledBundleIdentity) -> Value {
        dict(vec![
            (
                "schema_version",
                Value::Int(INSTALLED_EVIDENCE_SCHEMA_VERSION),
            ),
            ("bundle", identity.bundle()),
            ("devices", Value::List(Vec::new())),
            (
                "intentional_provider_differences",
                strings(PROVIDER_DIFFERENCE_IDS),
            ),
        ])
    }
}

/// `SignedInstalledAppGate._validate_evidence_shape(evidence)`.
pub fn validate_evidence_shape(evidence: &Dict) -> Result<()> {
    let schema_ok = evidence
        .get("schema_version")
        .is_some_and(|value| json::py_eq(value, &Value::Int(INSTALLED_EVIDENCE_SCHEMA_VERSION)));
    if !same_keys(
        evidence,
        &[
            "schema_version",
            "bundle",
            "devices",
            "intentional_provider_differences",
        ],
    ) || !schema_ok
    {
        return Err(invalid_evidence(
            "Installed evidence manifest has an unsupported shape.",
            "Regenerate the bounded schema-1 template from the exact installed app.",
        ));
    }
    let bundle_ok = evidence
        .get("bundle")
        .and_then(Value::as_dict)
        .is_some_and(|bundle| {
            same_keys(
                bundle,
                &[
                    "version",
                    "build_number",
                    "bundle_identifier",
                    "bundle_sha256",
                    "signer_team_id",
                ],
            )
        });
    if !bundle_ok {
        return Err(invalid_evidence(
            "Installed evidence bundle identity is incomplete.",
            "Regenerate the template from the exact installed app.",
        ));
    }
    let Some(devices) = evidence
        .get("devices")
        .and_then(Value::as_list)
        .filter(|devices| devices.len() <= 8)
    else {
        return Err(invalid_evidence(
            "Installed evidence must contain at most eight bounded device records.",
            "Record two reviewed device summaries without logs, paths, or transcripts.",
        ));
    };
    for item in devices {
        let Some(item) = item.as_dict().filter(|item| {
            same_keys(
                item,
                &[
                    "device_id_sha256",
                    "os_version",
                    "scenarios",
                    "providers",
                    "evidence_sha256",
                ],
            )
        }) else {
            return Err(invalid_evidence(
                "Installed device evidence has an unsupported field.",
                "Use the documented bounded device record only.",
            ));
        };
        let field = |key: &str| item.get(key).cloned().unwrap_or(Value::Null);
        for key in ["device_id_sha256", "evidence_sha256"] {
            if !hex64(&field(key)) {
                return Err(invalid_evidence(
                    "Installed device evidence hash is invalid.",
                    "Record lowercase SHA-256 hashes, never raw device IDs or logs.",
                ));
            }
        }
        if !os_version(&field("os_version")) {
            return Err(invalid_evidence(
                "Installed device OS version is invalid.",
                "Record only the bounded OS version identifier.",
            ));
        }
        if !outcomes_valid(&field("scenarios"), &INSTALLED_SCENARIOS)?
            || !outcomes_valid(&field("providers"), &["codex", "claude"])?
        {
            return Err(invalid_evidence(
                "Installed scenario/provider outcomes are invalid.",
                "Use only documented scenario IDs with explicit passed or failed outcomes.",
            ));
        }
    }
    let differences_ok = match evidence.get("intentional_provider_differences") {
        Some(Value::List(items)) => {
            // `set(differences)` hashes every element before the subset test.
            for item in items {
                not_in(item, &[])?;
            }
            items.iter().all(|item| {
                item.as_str()
                    .is_some_and(|text| PROVIDER_DIFFERENCE_IDS.contains(&text))
            })
        }
        _ => false,
    };
    if !differences_ok {
        return Err(invalid_evidence(
            "Installed provider differences are invalid.",
            "Document only the reviewed auth, executable, model, and effort differences.",
        ));
    }
    rollout::privacy_safe_report_digest(&Value::Dict(evidence.clone()))?;
    Ok(())
}

/// `SignedInstalledAppGate._bundle_digest(app)`.
pub fn bundle_digest(app: &Path) -> Result<String> {
    let mut entries = Vec::new();
    if fs::symlink_metadata(app).is_ok_and(|metadata| metadata.is_dir()) {
        collect_bundle_entries(app, app, &mut entries)?;
    }
    entries.sort_by(|left: &(String, PathBuf), right| left.0.cmp(&right.0));
    let mut buffer = Vec::new();
    for (relative, path) in entries {
        buffer.extend_from_slice(relative.as_bytes());
        buffer.push(0);
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            buffer.extend_from_slice(b"link\0");
            buffer.extend_from_slice(fs::read_link(&path)?.to_string_lossy().as_bytes());
        } else if metadata.is_file() {
            buffer.extend_from_slice(b"file\0");
            buffer.extend_from_slice(&raw_digest(&fs::read(&path)?));
        } else if metadata.is_dir() {
            buffer.extend_from_slice(b"dir\0");
        } else {
            return Err(verification_error(
                "Installed bundle contains an unsupported filesystem entry.",
                "invalid_installed_bundle",
                "Rebuild the signed app from the reviewed packaging script.",
            ));
        }
    }
    Ok(hex_digest(&buffer))
}

fn collect_bundle_entries(
    root: &Path,
    directory: &Path,
    entries: &mut Vec<(String, PathBuf)>,
) -> Result<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let relative = path
            .strip_prefix(root)
            .map(|relative| relative.to_string_lossy().into_owned())
            .unwrap_or_default();
        let is_dir = fs::symlink_metadata(&path)?.is_dir();
        entries.push((relative, path.clone()));
        if is_dir {
            collect_bundle_entries(root, &path, entries)?;
        }
    }
    Ok(())
}

// -- Info.plist ---------------------------------------------------------------

fn invalid_bundle() -> Error {
    verification_error(
        "Installed Relay Runner Info.plist is missing or invalid.",
        "invalid_installed_bundle",
        "Rebuild and reinstall the reviewed bundle.",
    )
}

/// One property-list value from plutil's canonical XML.
enum Plist {
    Text(String),
    Integer(String),
    Real(String),
    Bool(bool),
    /// `<data>`, `<date>`, `<array>` or `<dict>`, kept as text.
    Other(String),
}

impl Plist {
    /// `str(value or "")`.
    fn python_str(&self) -> String {
        match self {
            Plist::Text(text) | Plist::Other(text) => text.clone(),
            Plist::Integer(text) => match text.trim().parse::<i128>() {
                Ok(0) => String::new(),
                Ok(number) => number.to_string(),
                Err(_) => text.clone(),
            },
            // The guard spells out that -0.0 is falsy too, as `bool(-0.0)` is.
            #[allow(clippy::redundant_guards)]
            Plist::Real(text) => match text.trim().parse::<f64>() {
                Ok(number) if number == 0.0 => String::new(),
                Ok(number) => json::float_repr(number),
                Err(_) => text.clone(),
            },
            Plist::Bool(true) => "True".to_string(),
            Plist::Bool(false) => String::new(),
        }
    }
}

/// `plistlib.loads(info_path.read_bytes())`'s top-level keys, as `str()`
/// text. A file that is neither a binary nor an XML property list is
/// refused as plistlib refuses it; plutil then converts either to XML.
fn read_info_plist(path: &Path) -> Result<BTreeMap<String, String>> {
    let bytes = fs::read(path).map_err(|_| invalid_bundle())?;
    let header = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
    let looks_xml = header
        .iter()
        .find(|byte| !byte.is_ascii_whitespace())
        .is_some_and(|byte| *byte == b'<');
    if !bytes.starts_with(b"bplist00") && !looks_xml {
        return Err(invalid_bundle());
    }
    let converted = Command::new("/usr/bin/plutil")
        .args(["-convert", "xml1", "-o", "-"])
        .arg(path)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| invalid_bundle())?;
    if !converted.status.success() {
        return Err(invalid_bundle());
    }
    let text = String::from_utf8(converted.stdout).map_err(|_| invalid_bundle())?;
    let mut reader = XmlReader { text: &text, at: 0 };
    reader.skip_misc();
    if reader.open_tag().map(|(name, _)| name) != Some("plist".to_string()) {
        return Err(invalid_bundle());
    }
    reader.skip_misc();
    match reader.dict_entries() {
        Some(Some(entries)) => Ok(entries
            .into_iter()
            .map(|(key, value)| (key, value.python_str()))
            .collect()),
        // A root that is not a dictionary: `info.get` raises.
        Some(None) => Err(Error::new(
            ErrorKind::Attribute,
            "property list root has no attribute 'get'",
        )),
        None => Err(invalid_bundle()),
    }
}

/// A reader for the canonical XML `plutil -convert xml1` writes.
struct XmlReader<'t> {
    text: &'t str,
    at: usize,
}

impl<'t> XmlReader<'t> {
    fn rest(&self) -> &'t str {
        &self.text[self.at..]
    }

    /// Whitespace, the XML declaration, the doctype and comments.
    fn skip_misc(&mut self) {
        loop {
            let trimmed = self.rest().trim_start();
            self.at = self.text.len() - trimmed.len();
            let end = if trimmed.starts_with("<?") {
                trimmed.find("?>").map(|index| index + 2)
            } else if trimmed.starts_with("<!--") {
                trimmed.find("-->").map(|index| index + 3)
            } else if trimmed.starts_with("<!") {
                trimmed.find('>').map(|index| index + 1)
            } else {
                return;
            };
            match end {
                Some(end) => self.at += end,
                None => {
                    self.at = self.text.len();
                    return;
                }
            }
        }
    }

    /// `<name ...>` or `<name .../>`: the name and whether it closes itself.
    fn open_tag(&mut self) -> Option<(String, bool)> {
        let rest = self.rest();
        if !rest.starts_with('<') || rest.starts_with("</") {
            return None;
        }
        let end = rest.find('>')?;
        let inner = &rest[1..end];
        let closed = inner.ends_with('/');
        let name = inner
            .trim_end_matches('/')
            .split_whitespace()
            .next()?
            .to_string();
        self.at += end + 1;
        Some((name, closed))
    }

    /// Text up to `</name>`, unescaped.
    fn text_until(&mut self, name: &str) -> Option<String> {
        let close = format!("</{name}>");
        let end = self.rest().find(&close)?;
        let raw = &self.rest()[..end];
        self.at += end + close.len();
        Some(unescape(raw))
    }

    /// One value element.
    fn value(&mut self) -> Option<Plist> {
        self.skip_misc();
        let (name, closed) = self.open_tag()?;
        let text = |reader: &mut Self| {
            if closed {
                Some(String::new())
            } else {
                reader.text_until(&name)
            }
        };
        Some(match name.as_str() {
            "string" => Plist::Text(text(self)?),
            "integer" => Plist::Integer(text(self)?),
            "real" => Plist::Real(text(self)?),
            "true" | "false" => {
                if !closed {
                    self.text_until(&name)?;
                }
                Plist::Bool(name == "true")
            }
            "data" | "date" => Plist::Other(text(self)?),
            "array" | "dict" => {
                if !closed {
                    let start = self.at;
                    self.skip_container(&name)?;
                    let inner = self.text[start..self.at].to_string();
                    return Some(Plist::Other(inner));
                }
                Plist::Other(String::new())
            }
            _ => return None,
        })
    }

    /// Past the `</name>` that closes an open container, nesting included.
    fn skip_container(&mut self, name: &str) -> Option<()> {
        loop {
            self.skip_misc();
            let close = format!("</{name}>");
            if self.rest().starts_with(&close) {
                self.at += close.len();
                return Some(());
            }
            if name == "dict" {
                self.skip_misc();
                let (key, closed) = self.open_tag()?;
                if key != "key" {
                    return None;
                }
                if !closed {
                    self.text_until("key")?;
                }
            }
            self.value()?;
        }
    }

    /// The root `<dict>`'s entries; `Some(None)` when the root is another value.
    fn dict_entries(&mut self) -> Option<Option<Vec<(String, Plist)>>> {
        let start = self.at;
        let (name, closed) = self.open_tag()?;
        if name != "dict" {
            self.at = start;
            self.value()?;
            return Some(None);
        }
        let mut entries = Vec::new();
        if closed {
            return Some(Some(entries));
        }
        loop {
            self.skip_misc();
            if self.rest().starts_with("</dict>") {
                return Some(Some(entries));
            }
            let (key, key_closed) = self.open_tag()?;
            if key != "key" {
                return None;
            }
            let key = if key_closed {
                String::new()
            } else {
                self.text_until("key")?
            };
            let value = self.value()?;
            entries.push((key, value));
        }
    }
}

fn unescape(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(index) = rest.find('&') {
        result.push_str(&rest[..index]);
        rest = &rest[index..];
        let Some(end) = rest.find(';') else {
            break;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "lt" => Some('<'),
            "gt" => Some('>'),
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .or_else(|| {
                    entity
                        .strip_prefix('#')
                        .and_then(|digits| digits.parse().ok())
                })
                .and_then(char::from_u32),
        };
        match decoded {
            Some(character) => {
                result.push(character);
                rest = &rest[end + 1..];
            }
            None => {
                result.push('&');
                rest = &rest[1..];
            }
        }
    }
    result.push_str(rest);
    result
}

// -- the command line ---------------------------------------------------------

/// `json.dumps(value, sort_keys=True, indent=2)`.
pub fn dumps_indent_sorted(value: &Value) -> String {
    fn write(out: &mut String, value: &Value, depth: usize) {
        let pad = |depth: usize| "  ".repeat(depth);
        match value {
            Value::List(items) if !items.is_empty() => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(depth + 1));
                    write(out, item, depth + 1);
                }
                out.push('\n');
                out.push_str(&pad(depth));
                out.push(']');
            }
            Value::Dict(dict) if !dict.is_empty() => {
                let mut entries: Vec<(&str, &Value)> = dict.iter().collect();
                entries.sort_by(|left, right| left.0.cmp(right.0));
                out.push('{');
                for (index, (key, item)) in entries.into_iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(depth + 1));
                    out.push_str(&json::dumps(&Value::Str(key.to_string())));
                    out.push_str(": ");
                    write(out, item, depth + 1);
                }
                out.push('\n');
                out.push_str(&pad(depth));
                out.push('}');
            }
            other => out.push_str(&json::dumps(other)),
        }
    }
    let mut out = String::new();
    write(&mut out, value, 0);
    out
}

const USAGE: &str = "usage: relay-artifacts verification [-h] {source-harness,inspect-installed,installed-template,evaluate-installed} ...";

/// The parsed command line.
struct Arguments {
    action: String,
    app: String,
    output: Option<String>,
    evidence: Option<String>,
}

enum Parsed {
    Run(Arguments),
    Exit(u8),
}

fn usage_error(message: &str) -> Parsed {
    eprintln!("{USAGE}");
    eprintln!("relay-artifacts verification: error: {message}");
    Parsed::Exit(2)
}

fn parse_arguments(arguments: &[String]) -> Parsed {
    const ACTIONS: [&str; 4] = [
        "source-harness",
        "inspect-installed",
        "installed-template",
        "evaluate-installed",
    ];
    let Some(action) = arguments.first() else {
        return usage_error("the following arguments are required: action");
    };
    if action == "-h" || action == "--help" {
        println!("{USAGE}");
        println!();
        println!("Run RR-289 disposable source checks or evaluate signed installed evidence.");
        return Parsed::Exit(0);
    }
    if !ACTIONS.contains(&action.as_str()) {
        return usage_error(&format!(
            "argument action: invalid choice: {} (choose from {})",
            pystr::repr(action),
            ACTIONS.join(", ")
        ));
    }
    let allowed: &[&str] = match action.as_str() {
        "source-harness" => &["--output"],
        "inspect-installed" | "installed-template" => &["--app", "--output"],
        _ => &["--app", "--evidence", "--output"],
    };
    let mut parsed = Arguments {
        action: action.clone(),
        app: "/Applications/Relay Runner.app".to_string(),
        output: None,
        evidence: None,
    };
    let mut rest = arguments[1..].iter();
    while let Some(argument) = rest.next() {
        if argument == "-h" || argument == "--help" {
            println!(
                "usage: relay-artifacts verification {action} [-h] {}",
                allowed.join(" ")
            );
            return Parsed::Exit(0);
        }
        let (name, inline) = match argument.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_string())),
            _ => (argument.as_str(), None),
        };
        if !allowed.contains(&name) {
            return usage_error(&format!("unrecognized arguments: {argument}"));
        }
        let value = match inline {
            Some(value) => value,
            None => match rest.next() {
                Some(value) if !value.starts_with('-') || value == "-" => value.clone(),
                _ => return usage_error(&format!("argument {name}: expected one argument")),
            },
        };
        match name {
            "--app" => parsed.app = value,
            "--output" => parsed.output = Some(value),
            _ => parsed.evidence = Some(value),
        }
    }
    if parsed.action == "installed-template" && parsed.output.is_none() {
        return usage_error("the following arguments are required: --output");
    }
    if parsed.action == "evaluate-installed" && parsed.evidence.is_none() {
        return usage_error("the following arguments are required: --evidence");
    }
    Parsed::Run(parsed)
}

/// What `_read_json` raises.
enum ReadFailure {
    /// `OSError`, `UnicodeDecodeError` or `JSONDecodeError`.
    InvalidFile,
    Other(Error),
}

fn read_json(path: &str) -> std::result::Result<Dict, ReadFailure> {
    let path = paths::expanduser(path).map_err(ReadFailure::Other)?;
    let bytes = fs::read(path).map_err(|_| ReadFailure::InvalidFile)?;
    let text = pystr::decode_utf8(&bytes).map_err(|_| ReadFailure::InvalidFile)?;
    match json::parse(&pystr::universal_newlines(text)) {
        None => Err(ReadFailure::InvalidFile),
        Some(Value::Dict(value)) => Ok(value),
        Some(_) => Err(ReadFailure::Other(invalid_evidence(
            "Installed evidence root must be an object.",
            "Regenerate the bounded schema-1 evidence template.",
        ))),
    }
}

/// `_emit(value, output)`.
fn emit(value: &Value, output: Option<&str>) -> Result<()> {
    let payload = dumps_indent_sorted(value) + "\n";
    let Some(output) = output else {
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(payload.as_bytes())?;
        stdout.flush()?;
        return Ok(());
    };
    let destination = PathBuf::from(paths::resolve(&paths::expanduser(output)?));
    let parent = destination.parent().unwrap_or(Path::new("/")).to_path_buf();
    fs::create_dir_all(&parent)?;
    let name = destination
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = loop {
        let mut bytes = [0u8; 6];
        fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let candidate = parent.join(format!(".{name}.{suffix}"));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(mut file) => {
                let written = file
                    .write_all(payload.as_bytes())
                    .and_then(|()| file.sync_all());
                if let Err(error) = written {
                    let _ = fs::remove_file(&candidate);
                    return Err(error.into());
                }
                break candidate;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    };
    let renamed = fs::rename(&temporary, &destination);
    if temporary.exists() {
        let _ = fs::remove_file(&temporary);
    }
    renamed.map_err(Error::from)
}

fn error_envelope(code: &str, error: &str, recovery: &str) -> Value {
    dict(vec![
        ("ok", Value::Bool(false)),
        ("error_code", Value::from(code)),
        ("error", Value::from(error)),
        ("recovery", Value::from(recovery)),
    ])
}

fn invalid_file_envelope() -> Value {
    error_envelope(
        "invalid_evidence_file",
        "Installed evidence file is missing or invalid JSON.",
        "Regenerate the bounded template and record reviewed scenario outcomes.",
    )
}

/// An exception Python's CLI does not catch: the traceback's last line and
/// exit status 1.
fn uncaught(error: &Error) -> u8 {
    eprintln!("Traceback (most recent call last):");
    eprintln!("{}: {}", error.kind.python_class(), error.message);
    1
}

/// The command line, as the Python CLI reads it; returns the exit status.
pub fn cli_main(arguments: &[String]) -> u8 {
    let parsed = match parse_arguments(arguments) {
        Parsed::Exit(code) => return code,
        Parsed::Run(parsed) => parsed,
    };
    let output = parsed.output.as_deref();
    let result: std::result::Result<Value, ReadFailure> = (|| {
        if parsed.action == "source-harness" {
            return SourceVerificationHarness::default()
                .run()
                .map_err(ReadFailure::Other);
        }
        let gate = SignedInstalledAppGate::default();
        let identity = gate
            .inspect(&parsed.app, true)
            .map_err(ReadFailure::Other)?;
        Ok(match parsed.action.as_str() {
            "inspect-installed" => dict(vec![
                ("status", Value::from("passed")),
                ("bundle", identity.as_dict()),
            ]),
            "installed-template" => SignedInstalledAppGate::evidence_template(&identity),
            _ => {
                let evidence = read_json(parsed.evidence.as_deref().unwrap_or_default())?;
                gate.evaluate(&identity, &evidence)
                    .map_err(ReadFailure::Other)?
            }
        })
    })();
    let failure = match result {
        Ok(value) => {
            // The installed template is itself the file evaluate-installed
            // reads; other actions use the ordinary envelope.
            let envelope = if parsed.action == "installed-template" {
                value
            } else {
                dict(vec![("ok", Value::Bool(true)), ("result", value)])
            };
            match emit(&envelope, output) {
                Ok(()) => return 0,
                Err(error) if error.kind == ErrorKind::Io => ReadFailure::InvalidFile,
                Err(error) => return uncaught(&error),
            }
        }
        Err(failure) => failure,
    };
    let envelope = match failure {
        ReadFailure::Other(error) if error.kind == ErrorKind::Verification => error_envelope(
            error.code.as_deref().unwrap_or_default(),
            &error.message,
            error.recovery.as_deref().unwrap_or_default(),
        ),
        ReadFailure::Other(error) if error.kind == ErrorKind::Io => invalid_file_envelope(),
        ReadFailure::Other(error) => return uncaught(&error),
        ReadFailure::InvalidFile => invalid_file_envelope(),
    };
    match emit(&envelope, output) {
        Ok(()) => 2,
        Err(error) => uncaught(&error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indented_dumps_match_python() {
        let value = json::parse(r#"{"b": [1, {"z": null, "a": "é"}], "a": {}, "c": []}"#).unwrap();
        assert_eq!(
            dumps_indent_sorted(&value),
            "{\n  \"a\": {},\n  \"b\": [\n    1,\n    {\n      \"a\": \"\\u00e9\",\n      \"z\": null\n    }\n  ],\n  \"c\": []\n}"
        );
    }

    #[test]
    fn signing_details_read_the_first_matching_lines() {
        let (team, signature, authorities) = signing_details(
            "TeamIdentifier=not set\nSignature=adhoc\nAuthority=Developer ID Application: X (T)\nAuthority=Apple Root CA\n",
        );
        // `^TeamIdentifier=([^\s]+)$` does not match a value with a space.
        assert_eq!(team, "");
        assert_eq!(signature, "adhoc");
        assert_eq!(authorities.len(), 2);
        let (team, _, _) =
            signing_details("TeamIdentifier=\nTeamIdentifier=A B\nTeamIdentifier=T1\n");
        assert_eq!(team, "T1");
    }

    #[test]
    fn os_versions_are_bounded() {
        assert!(os_version(&Value::from("macOS-15.6")));
        assert!(!os_version(&Value::from("-macOS")));
        assert!(!os_version(&Value::from("a".repeat(33).as_str())));
        assert!(os_version(&Value::from("a".repeat(32).as_str())));
    }

    #[test]
    fn replace_config_replaces_the_first_matching_key() {
        assert_eq!(
            replace_config(
                "a = 1\nremote_sync = \"local_only\"\n",
                "remote_sync",
                "remote_sync = \"enabled\""
            ),
            "a = 1\nremote_sync = \"enabled\"\n"
        );
        assert_eq!(replace_config("a = 1", "b", "b = 2"), "a = 1\nb = 2\n");
    }
}
