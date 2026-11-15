//! `relay-rs fresh-install`: `services/fresh_install_cli.py` and
//! `services/fresh_install.py`, Relay Runner's supported reinstall and
//! recoverable state-reset workflow (RR-270), with `verify_update_identity`
//! from `services/app_signing.py`.
//!
//! Normal app replacement treats Application Support as immutable input and
//! proves that registered repositories and Relay state are unchanged. A
//! deliberate reset is a separate, explicit operation: after quiescence
//! confirmation it moves only an allowlisted profile of Relay-owned resources
//! to Trash and writes recovery evidence inside the moved directory.
//! Registered repositories are never edited, removed, or rewritten.
//!
//! Arguments, the `{"ok": true, "result": ...}` / `{"ok": false, "error",
//! "recovery"}` JSON, the recovery journal and the exit statuses are the
//! Python tool's. Known differences:
//!
//! - `capture_evidence` records relay-rs's version as `runtime_version`,
//!   where Python recorded its interpreter's `sys.version`.
//! - The usage line is `relay-runner-fresh-install`'s on one line.
//! - A recovery manifest that is not JSON is reported without Python's
//!   decoder position.
//! - A failure Python would have raised as an uncaught exception prints one
//!   line on stderr and exits 1, without a traceback.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use relay_artifacts::paths;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::cli::{Opt, Spec, os_error_text};

/// Run states that keep a reset from proving quiescence.
const RESET_ACTIVE_STATES: [&str; 8] = [
    "Claimed",
    "Running",
    "SpikeResultReady",
    "AwaitingReview",
    "Reviewing",
    "MergeConflict",
    "IntegrationBlocked",
    "Succeeded",
];

pub const PROFILE_RELAY_OWNED: &str = "relay-owned";
pub const PROFILE_VOICE_MODELS: &str = "voice-models";
pub const PROFILE_PROVIDER_INTEGRATIONS: &str = "provider-integrations";
pub const RESET_PROFILES: [&str; 3] = [
    PROFILE_RELAY_OWNED,
    PROFILE_VOICE_MODELS,
    PROFILE_PROVIDER_INTEGRATIONS,
];

const UNRESETTABLE_MACHINE_STATE: [&str; 5] = [
    "TCC permissions",
    "Keychain credentials",
    "notification authorization",
    "Gatekeeper and quarantine decisions",
    "shared dependency caches",
];

const RELAY_TEMPORARY_ARTIFACTS: [&str; 31] = [
    "relay_actions.sock",
    "relay_board_now.txt",
    "relay_board_prev.txt",
    "relay_intent_inbox.sqlite3",
    "relay_orchestrator.port",
    "relay_speech_events.jsonl",
    "relay_terminal_manual_submission.json",
    "relay_terminal_delivery_events.jsonl",
    "relay_tutorial_tts_control.sock",
    "tts_control.sock",
    "tts_debug.log",
    "tts_in.fifo",
    "voice_bridge.cwd",
    "voice_bridge.pid",
    "voice_bridge.provider",
    "voice_bridge.sock",
    "voice_bridge_heartbeat",
    "voice_bridge_heartbeat.pid",
    "voice_bridge_launch.command",
    "voice_bridge_stop_requested",
    "voice_cmd_claimed.json",
    "voice_cmd_manual_ack.json",
    "voice_cmd_ready",
    "voice_cmd_ready.meta",
    "voice_command_authorizations.json",
    "voice_command_state.json",
    "voice_in.fifo",
    "voice_provider_session_id",
    "voice_provider_turns.json",
    "voice_provider_turns_v2.json",
    "voice_state.sock",
];

/// Command-line fragments of Relay processes a reset must not run beside:
/// the app, the Python bridge, daemon and TTS worker, and their Rust
/// replacements (the bridge, the speech service and, below, the daemon).
const RELAY_PROCESS_MARKERS: [&str; 6] = [
    "relay-runner",
    "voice_bridge.py",
    "relay-rs bridge",
    "orchestrator.py",
    "tts_worker.py",
    "relay-speech",
];
/// This tool's own command lines, Python's and Rust's; only those in the
/// running process's lineage are exempt.
const INSTALLER_MARKERS: [&str; 3] = [
    "fresh_install_cli.py",
    "relay-runner-fresh-install",
    "relay-rs fresh-install",
];
/// The Rust orchestrator daemon (RR-500), but not relay-orchestrator-mcp.
const RUST_DAEMON_MARKER: &str = "/MacOS/relay-orchestrator";

const SIGNING_TEAM: &str = "QK9K4AQRNH";
const APP_IDENTIFIER: &str = "com.relayrunner.app";

// -- errors ----------------------------------------------------------------------

/// A failed operation.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    /// `FreshInstallError`, or its `FreshInstallInjectedFailure` subclass.
    Refused {
        message: String,
        recovery: String,
        injected: bool,
    },
    /// Anything Python would have raised uncaught (an `OSError`, say).
    Other(String),
}

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Failure::Other(os_error_text(&error, None))
    }
}

type Outcome<T> = Result<T, Failure>;

fn refuse(message: impl Into<String>, recovery: &str) -> Failure {
    Failure::Refused {
        message: message.into(),
        recovery: recovery.to_string(),
        injected: false,
    }
}

fn io_at(path: &Path) -> impl Fn(io::Error) -> Failure + '_ {
    move |error| Failure::Other(os_error_text(&error, Some(path)))
}

// -- path helpers -----------------------------------------------------------------

/// `str(Path(text).expanduser().resolve())`.
fn resolve_user(text: &str) -> Outcome<String> {
    let expanded = paths::expanduser(text)
        .map_err(|error| Failure::Other(format!("RuntimeError: {}", error.message)))?;
    Ok(paths::resolve(&expanded))
}

/// `Path.home()`.
fn home() -> Outcome<String> {
    paths::expanduser("~")
        .map_err(|error| Failure::Other(format!("RuntimeError: {}", error.message)))
}

/// `str(Path(base) / child)`.
fn join(base: &str, child: &str) -> String {
    paths::normalize(&format!("{base}/{child}"))
}

/// `path.exists() or path.is_symlink()`.
fn lexists(path: &str) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn is_symlink(path: &str) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

fn is_dir(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}

fn is_file(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

fn exists(path: &str) -> bool {
    fs::metadata(path).is_ok()
}

fn parent(path: &str) -> String {
    Path::new(path).parent().map_or_else(
        || path.to_string(),
        |parent| parent.to_string_lossy().into_owned(),
    )
}

fn name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// `len(Path(path).parts)` for an absolute path.
fn part_count(path: &str) -> usize {
    1 + path.split('/').filter(|part| !part.is_empty()).count()
}

fn is_empty_dir(path: &str) -> Outcome<bool> {
    Ok(fs::read_dir(path)
        .map_err(io_at(Path::new(path)))?
        .next()
        .is_none())
}

fn random_hex() -> String {
    relay_artifacts::store::random_hex()
}

/// `time.strftime("%Y%m%d-%H%M%S", time.gmtime())`.
fn timestamp() -> String {
    let text = crate::support::utc_timestamp(crate::support::now());
    format!(
        "{}{}{}-{}{}{}",
        &text[0..4],
        &text[5..7],
        &text[8..10],
        &text[11..13],
        &text[14..16],
        &text[17..19]
    )
}

// -- manifests --------------------------------------------------------------------

/// One entry of `_tree_manifest`.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Entry {
    File { bytes: u64, sha256: String },
    Symlink { target: String },
}

impl Entry {
    fn value(&self) -> Value {
        let mut entry = Dict::new();
        match self {
            Entry::Symlink { target } => {
                entry.insert("kind", "symlink");
                entry.insert("target", target.as_str());
            }
            Entry::File { bytes, sha256 } => {
                entry.insert("kind", "file");
                entry.insert("bytes", *bytes as i64);
                entry.insert("sha256", sha256.as_str());
            }
        }
        Value::Dict(entry)
    }
}

type Manifest = BTreeMap<String, Entry>;

fn manifest_value(manifest: &Manifest) -> Value {
    let mut value = Dict::new();
    for (path, entry) in manifest {
        value.insert(path, entry.value());
    }
    Value::Dict(value)
}

/// `_json_digest`: SHA-256 of `json.dumps(sort_keys=True,
/// separators=(",", ":"), ensure_ascii=False)`.
fn json_digest(value: &Value) -> String {
    hex_digest(json::dumps_compact_sorted_unicode(value).as_bytes())
}

fn symlink_entry(path: &Path) -> Outcome<Entry> {
    let target = fs::read_link(path).map_err(io_at(path))?;
    Ok(Entry::Symlink {
        target: target.to_string_lossy().into_owned(),
    })
}

fn file_entry(path: &Path) -> Outcome<Entry> {
    let content = fs::read(path).map_err(io_at(path))?;
    Ok(Entry::File {
        bytes: content.len() as u64,
        sha256: hex_digest(&content),
    })
}

/// `_tree_manifest(root)`: every file and symlink below `root`, by relative
/// path, without following symlinks. Directories `os.walk` cannot list are
/// skipped, as it skips them.
fn tree_manifest(root: &Path) -> Outcome<Manifest> {
    fn walk(root: &Path, directory: &Path, manifest: &mut Manifest) -> Outcome<()> {
        let Ok(entries) = fs::read_dir(directory) else {
            return Ok(());
        };
        let mut children: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .collect();
        children.sort();
        for child in children {
            let relative = child
                .strip_prefix(root)
                .map(|relative| relative.to_string_lossy().into_owned())
                .unwrap_or_default();
            let Ok(metadata) = fs::symlink_metadata(&child) else {
                continue;
            };
            let file_type = metadata.file_type();
            if file_type.is_symlink() {
                manifest.insert(relative, symlink_entry(&child)?);
            } else if file_type.is_dir() {
                walk(root, &child, manifest)?;
            } else if file_type.is_file() {
                manifest.insert(relative, file_entry(&child)?);
            } else {
                return Err(refuse(
                    format!(
                        "Unsupported special file in managed tree: {}",
                        child.to_string_lossy()
                    ),
                    "Remove/review the special file before install or reset.",
                ));
            }
        }
        Ok(())
    }
    let mut manifest = Manifest::new();
    walk(root, root, &mut manifest)?;
    Ok(manifest)
}

/// `_resource_digest(path)`.
fn resource_digest(path: &str) -> Outcome<Option<String>> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(None);
    };
    let path_ref = Path::new(path);
    let value = if metadata.file_type().is_symlink() {
        symlink_entry(path_ref)?.value()
    } else if is_file(path) {
        file_entry(path_ref)?.value()
    } else if is_dir(path) {
        manifest_value(&tree_manifest(path_ref)?)
    } else {
        return Err(refuse(
            format!("Unsupported special file in managed profile: {path}"),
            "Remove/review the special file before a profile reset.",
        ));
    };
    Ok(Some(json_digest(&value)))
}

/// `_profile_resources`: the named resources each reset profile owns.
fn profile_resources(
    profile: &str,
    state_root: &str,
    home_root: &str,
    temporary_root: &str,
) -> Outcome<Vec<(String, String)>> {
    let in_home = |relative: &str| join(home_root, relative);
    let named = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(name, relative)| (name.to_string(), in_home(relative)))
            .collect()
    };
    match profile {
        PROFILE_RELAY_OWNED => {
            let mut resources = vec![("application-support".to_string(), state_root.to_string())];
            resources.extend(named(&[
                (
                    "preferences",
                    "Library/Preferences/com.relayrunner.app.plist",
                ),
                ("cache", "Library/Caches/com.relayrunner.app"),
                (
                    "orchestrator-launch-agent",
                    "Library/LaunchAgents/com.relay.orchestrator.plist",
                ),
            ]));
            resources.extend(RELAY_TEMPORARY_ARTIFACTS.iter().map(|artifact| {
                (
                    format!("temporary-{artifact}"),
                    join(temporary_root, artifact),
                )
            }));
            Ok(resources)
        }
        PROFILE_VOICE_MODELS => Ok(named(&[
            ("kokoro-model", ".local/share/kokoro/kokoro-v1.0.onnx"),
            ("kokoro-voices", ".local/share/kokoro/voices-v1.0.bin"),
        ])),
        PROFILE_PROVIDER_INTEGRATIONS => Ok(named(&[
            ("codex-relay-bridge-skill", ".codex/skills/relay-bridge"),
            ("codex-relay-stop-skill", ".codex/skills/relay-stop"),
            ("codex-relay-dispatch-skill", ".codex/skills/relay-dispatch"),
            ("codex-relay-workflow-skill", ".codex/skills/relay-workflow"),
            ("claude-relay-bridge-skill", ".claude/skills/relay-bridge"),
            ("claude-relay-stop-skill", ".claude/skills/relay-stop"),
            (
                "claude-relay-dispatch-skill",
                ".claude/skills/relay-dispatch",
            ),
            (
                "claude-relay-workflow-skill",
                ".claude/skills/relay-workflow",
            ),
            // Legacy Claude command files from before the move to skills.
            (
                "claude-relay-bridge-command",
                ".claude/commands/relay-bridge.md",
            ),
            (
                "claude-relay-stop-command",
                ".claude/commands/relay-stop.md",
            ),
            (
                "claude-relay-dispatch-command",
                ".claude/commands/relay-dispatch.md",
            ),
            (
                "claude-relay-workflow-command",
                ".claude/commands/relay-workflow.md",
            ),
        ])),
        _ => Err(refuse(
            format!("Unknown reset profile: {profile}"),
            "Choose relay-owned, voice-models, or provider-integrations.",
        )),
    }
}

/// `_write_json_atomic`: sorted, indented JSON through a private temporary
/// file, fsynced with its directory.
fn write_json_atomic(path: &str, value: &Value) -> io::Result<()> {
    let temporary = format!("{path}.{}.tmp", random_hex());
    let written = (|| -> io::Result<()> {
        let mut file = File::create(&temporary)?;
        file.write_all(relay_artifacts::rollout::dumps_indent_sorted(value).as_bytes())?;
        file.write_all(b"\n")?;
        file.flush()?;
        file.sync_all()?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temporary, path)?;
        File::open(parent(path))?.sync_all()
    })();
    if written.is_err() && is_file(&temporary) && !is_symlink(&temporary) {
        let _ = fs::remove_file(&temporary);
    }
    written
}

// -- repositories ------------------------------------------------------------------

/// `_repository_snapshot`: the repository's refs, index, status and
/// `.orchestrator/` tree, hashed.
fn repository_snapshot(repo: &str, project_id: &Value) -> Outcome<Dict> {
    let git = |arguments: &[&str], allowed: &[i32]| -> Outcome<Vec<u8>> {
        let output = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(arguments)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("LC_ALL", "C")
            .stdin(Stdio::inherit())
            .output()
            .map_err(io_at(Path::new("git")))?;
        if !output
            .status
            .code()
            .is_some_and(|code| allowed.contains(&code))
        {
            return Err(refuse(
                format!(
                    "Could not snapshot registered repository {repo}: git {} failed",
                    arguments.join(" ")
                ),
                "Restore repository access before reinstall/reset.",
            ));
        }
        Ok(output.stdout)
    };
    let text = |bytes: Vec<u8>| json::py_strip(&String::from_utf8_lossy(&bytes)).to_string();
    let head = text(git(&["rev-parse", "--verify", "HEAD"], &[0, 128])?);
    let head_ref = if head.is_empty() {
        Value::from(text(git(&["symbolic-ref", "--quiet", "HEAD"], &[0])?))
    } else {
        Value::Null
    };
    let refs = git(
        &["for-each-ref", "--format=%(refname)%00%(objectname)"],
        &[0],
    )?;
    let status = git(
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        &[0],
    )?;
    let index = git(&["ls-files", "--stage", "-z"], &[0])?;
    let orchestrator_path = join(repo, ".orchestrator");
    let orchestrator = if is_dir(&orchestrator_path) {
        tree_manifest(Path::new(&orchestrator_path))?
    } else {
        Manifest::new()
    };
    let mut snapshot = Dict::new();
    snapshot.insert("project_id", project_id.clone());
    snapshot.insert("repo_path", repo);
    snapshot.insert("available", true);
    snapshot.insert(
        "head",
        if head.is_empty() {
            Value::Null
        } else {
            Value::from(head)
        },
    );
    snapshot.insert("head_ref", head_ref);
    snapshot.insert("refs_sha256", hex_digest(&refs));
    snapshot.insert("status_sha256", hex_digest(&status));
    snapshot.insert("index_sha256", hex_digest(&index));
    snapshot.insert(
        "orchestrator_sha256",
        json_digest(&manifest_value(&orchestrator)),
    );
    Ok(snapshot)
}

/// `_verify_repository_snapshots`.
fn verify_repository_snapshots(snapshots: &[Value]) -> Outcome<()> {
    for expected in snapshots {
        let Value::Dict(expected) = expected else {
            return Err(Failure::Other(
                "AttributeError: a repository snapshot is not an object".to_string(),
            ));
        };
        if !expected.get("available").is_some_and(Value::truthy) {
            continue;
        }
        let repo_path = expected
            .get("repo_path")
            .filter(|value| value.truthy())
            .map(Value::py_str)
            .unwrap_or_default();
        let repo = paths::resolve(&repo_path);
        let project_id = expected.get("project_id").cloned().unwrap_or(Value::Null);
        let actual = repository_snapshot(&repo, &project_id)?;
        if !json::py_eq(&Value::Dict(actual), &Value::Dict(expected.clone())) {
            return Err(refuse(
                format!("Registered repository changed during app-state operation: {repo}"),
                "Stop and restore/reconcile the repository from the recorded snapshot.",
            ));
        }
    }
    Ok(())
}

// -- app signing --------------------------------------------------------------------

/// `app_signing.developer_id_requirement`.
fn developer_id_requirement(identifier: &str) -> String {
    format!(
        "identifier \"{identifier}\" and anchor apple generic \
         and certificate 1[field.1.2.840.113635.100.6.2.6] \
         and certificate leaf[field.1.2.840.113635.100.6.1.13] \
         and certificate leaf[subject.OU] = \"{SIGNING_TEAM}\""
    )
}

fn codesign(arguments: &[&str], target: &str) -> Outcome<std::process::Output> {
    Command::new("/usr/bin/codesign")
        .args(arguments)
        .arg(target)
        .stdin(Stdio::inherit())
        .output()
        .map_err(io_at(Path::new("/usr/bin/codesign")))
}

/// `app_signing.verify_update_identity(source, installed)`: the source must
/// carry Relay Runner's Developer ID signature and satisfy the installed
/// app's designated requirement. A refusal is reported with the rebuild
/// recovery, as `preview_reinstall` reports `AppSigningError`.
fn verify_update_identity(source: &Path, installed: &Path) -> Outcome<()> {
    let signing = |message: String| {
        refuse(
            message,
            "Rebuild with Relay Runner's Developer ID certificate, then repeat preflight.",
        )
    };
    let source = source.to_string_lossy();
    let release = format!("={}", developer_id_requirement(APP_IDENTIFIER));
    let result = codesign(
        &[
            "--verify",
            "--deep",
            "--strict",
            "--test-requirement",
            &release,
        ],
        &source,
    )?;
    if !result.status.success() {
        return Err(signing(format!(
            "App does not have Relay Runner's valid Developer ID signature; \
             replacing the installed app would risk losing macOS permissions. {}",
            json::py_strip(&String::from_utf8_lossy(&result.stderr))
        )));
    }
    let installed_text = installed.to_string_lossy();
    if !exists(&installed_text) {
        return Ok(());
    }
    let previous = codesign(
        &["--display", "--requirements", "-", "--verbose=2"],
        &installed_text,
    )?;
    let details = format!(
        "{}\n{}",
        String::from_utf8_lossy(&previous.stdout),
        String::from_utf8_lossy(&previous.stderr)
    );
    if !previous.status.success() {
        return Err(signing(
            "Cannot read the installed app's signing identity; keeping it in place.".to_string(),
        ));
    }
    if details.contains("Signature=adhoc") {
        // Moving from an old ad-hoc build to Developer ID is a one-time
        // repair. Its hash-based grants cannot transfer, but subsequent
        // builds are stable.
        eprintln!("Previous app was ad-hoc signed; macOS may require one final permission grant.");
        return Ok(());
    }
    let requirement = details
        .lines()
        .find_map(|line| line.strip_prefix("designated => "))
        .unwrap_or_default();
    if requirement.is_empty() {
        return Err(signing(
            "Installed app has no designated requirement; keeping it in place.".to_string(),
        ));
    }
    let requirement = format!("={requirement}");
    let compatible = codesign(
        &["--verify", "--strict", "--test-requirement", &requirement],
        &source,
    )?;
    if !compatible.status.success() {
        return Err(signing(
            "Update changes the installed app's permission identity; keeping it in place."
                .to_string(),
        ));
    }
    Ok(())
}

// -- results ----------------------------------------------------------------------

/// `FreshInstallPreview`.
#[derive(Clone, Debug, Default)]
pub struct Preview {
    pub action: &'static str,
    pub state_root: String,
    pub state_manifest_sha256: String,
    pub state_files: usize,
    pub registered_repositories: Vec<Dict>,
    pub active_run_ids: Vec<i64>,
    pub source_app: Option<String>,
    pub destination_app: Option<String>,
    pub profile: Option<String>,
    pub reset_resources: Vec<Dict>,
    pub machine_state_not_reset: Vec<&'static str>,
}

impl Preview {
    /// `dataclasses.asdict(preview)`.
    pub fn as_value(&self) -> Value {
        let mut value = Dict::new();
        value.insert("action", self.action);
        value.insert("state_root", self.state_root.as_str());
        value.insert("state_manifest_sha256", self.state_manifest_sha256.as_str());
        value.insert("state_files", self.state_files as i64);
        value.insert(
            "registered_repositories",
            Value::List(
                self.registered_repositories
                    .iter()
                    .cloned()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        value.insert(
            "active_run_ids",
            Value::List(
                self.active_run_ids
                    .iter()
                    .map(|id| Value::Int(*id))
                    .collect(),
            ),
        );
        value.insert("source_app", self.source_app.clone());
        value.insert("destination_app", self.destination_app.clone());
        value.insert("profile", self.profile.clone());
        value.insert(
            "reset_resources",
            Value::List(
                self.reset_resources
                    .iter()
                    .cloned()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        value.insert(
            "machine_state_not_reset",
            Value::List(
                self.machine_state_not_reset
                    .iter()
                    .map(|item| Value::from(*item))
                    .collect(),
            ),
        );
        Value::Dict(value)
    }
}

/// `FreshInstallResult`.
#[derive(Clone, Debug, Default)]
pub struct Completed {
    pub action: &'static str,
    pub state_preserved: bool,
    pub repositories_preserved: bool,
    pub destination_app: Option<String>,
    pub recovery_manifest: Option<String>,
    pub trashed_state: Option<String>,
    pub replaced_app_backup: Option<String>,
    pub profile: Option<String>,
    pub evidence_path: Option<String>,
}

impl Completed {
    fn new(action: &'static str) -> Self {
        Self {
            action,
            state_preserved: true,
            repositories_preserved: true,
            ..Self::default()
        }
    }

    /// `dataclasses.asdict(result)`.
    pub fn as_value(&self) -> Value {
        let mut value = Dict::new();
        value.insert("action", self.action);
        value.insert("state_preserved", self.state_preserved);
        value.insert("repositories_preserved", self.repositories_preserved);
        value.insert("destination_app", self.destination_app.clone());
        value.insert("recovery_manifest", self.recovery_manifest.clone());
        value.insert("trashed_state", self.trashed_state.clone());
        value.insert("replaced_app_backup", self.replaced_app_backup.clone());
        value.insert("profile", self.profile.clone());
        value.insert("evidence_path", self.evidence_path.clone());
        Value::Dict(value)
    }
}

// -- processes ------------------------------------------------------------------------

/// The Relay processes in a `ps -axo pid=,ppid=,command=` listing, as
/// "pid parent command", except this tool's own command lines in `own_pid`'s
/// lineage.
fn relay_processes_in(listing: &str, own_pid: i64) -> Outcome<Vec<String>> {
    let unreadable = || {
        refuse(
            "Cannot inspect Relay processes; refusing to move reset-profile state.",
            "Restore process inspection access before retrying the profile reset.",
        )
    };
    let mut order: Vec<i64> = Vec::new();
    let mut processes: HashMap<i64, (i64, String)> = HashMap::new();
    for line in listing.lines() {
        let line = json::py_strip(line);
        if line.is_empty() {
            continue;
        }
        let mut fields = line.splitn(2, char::is_whitespace);
        let pid_text = fields.next().unwrap_or_default();
        let rest = json::py_strip(fields.next().unwrap_or_default());
        let mut fields = rest.splitn(2, char::is_whitespace);
        let parent_text = fields.next().unwrap_or_default();
        let command = json::py_strip(fields.next().unwrap_or_default());
        if parent_text.is_empty() || command.is_empty() {
            return Err(unreadable());
        }
        let (Some(pid), Some(parent)) = (
            json::py_int_from_str(pid_text),
            json::py_int_from_str(parent_text),
        ) else {
            return Err(unreadable());
        };
        if processes
            .insert(pid, (parent, command.to_string()))
            .is_none()
        {
            order.push(pid);
        }
    }
    let mut lineage = vec![own_pid];
    let mut parent = processes.get(&own_pid).map(|(parent, _)| *parent);
    while let Some(next) = parent.filter(|next| !lineage.contains(next)) {
        lineage.push(next);
        parent = processes.get(&next).map(|(parent, _)| *parent);
    }
    let is_rust_daemon = |command: &str| {
        command
            .match_indices(RUST_DAEMON_MARKER)
            .any(|(start, marker)| {
                command[start + marker.len()..]
                    .chars()
                    .next()
                    .is_none_or(char::is_whitespace)
            })
    };
    Ok(order
        .into_iter()
        .filter_map(|pid| {
            let (parent, command) = &processes[&pid];
            let relay = RELAY_PROCESS_MARKERS
                .iter()
                .any(|marker| command.contains(marker))
                || is_rust_daemon(command);
            let own = lineage.contains(&pid)
                && INSTALLER_MARKERS
                    .iter()
                    .any(|marker| command.contains(marker));
            (relay && !own).then(|| format!("{pid} {parent} {command}"))
        })
        .collect())
}

/// The default process detector: `ps` for every Relay process.
fn active_relay_processes() -> Outcome<Vec<String>> {
    let output = Command::new("ps")
        .args(["-axo", "pid=,ppid=,command="])
        .stdin(Stdio::inherit())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| {
            refuse(
                format!(
                    "Cannot inspect Relay processes: {}",
                    os_error_text(&error, Some(Path::new("ps")))
                ),
                "Restore process inspection access before retrying the profile reset.",
            )
        })?;
    if !output.status.success() {
        return Err(refuse(
            "Cannot inspect Relay processes; refusing to move reset-profile state.",
            "Restore process inspection access before retrying the profile reset.",
        ));
    }
    relay_processes_in(
        &String::from_utf8_lossy(&output.stdout),
        i64::from(std::process::id()),
    )
}

// -- the coordinator ------------------------------------------------------------------

pub type ProcessDetector = Box<dyn Fn() -> Vec<String>>;
pub type FailureInjector = Box<dyn Fn(&str) -> Result<(), String>>;
pub type IdentityCheck = Box<dyn Fn(&Path, &Path) -> Outcome<()>>;

/// Where the coordinator works; every path is expanded and resolved.
pub struct Roots {
    pub state_root: String,
    pub trash_root: Option<String>,
    pub home_root: Option<String>,
    pub temporary_root: String,
}

/// `FreshInstallCoordinator`.
pub struct Coordinator {
    pub state_root: String,
    pub trash_root: String,
    pub home_root: String,
    pub temporary_root: String,
    pub active_process_detector: Option<ProcessDetector>,
    pub failure_injector: Option<FailureInjector>,
    /// `verify_update_identity`; tests replace it, since their bundles are
    /// not signed.
    pub identity_check: Option<IdentityCheck>,
}

/// `restore_profile`/`restore_reset`'s keyword arguments.
pub struct RestoreOptions {
    pub execute: bool,
    pub confirm_daemon_stopped: bool,
    pub confirm_profile: Option<String>,
    pub state_root: Option<String>,
    pub home_root: Option<String>,
    pub temporary_root: String,
    pub trash_root: Option<String>,
}

impl Coordinator {
    pub fn new(roots: Roots) -> Outcome<Self> {
        let trash_root = match &roots.trash_root {
            Some(trash) => resolve_user(trash)?,
            None => paths::resolve(&join(&home()?, ".Trash")),
        };
        let home_root = match &roots.home_root {
            Some(home_root) => resolve_user(home_root)?,
            None => paths::resolve(&home()?),
        };
        let coordinator = Self {
            state_root: resolve_user(&roots.state_root)?,
            trash_root,
            home_root,
            temporary_root: resolve_user(&roots.temporary_root)?,
            active_process_detector: None,
            failure_injector: None,
            identity_check: None,
        };
        coordinator.validate_owned_state_root()?;
        Ok(coordinator)
    }

    fn validate_owned_state_root(&self) -> Outcome<()> {
        let forbidden = [
            "/".to_string(),
            paths::resolve(&home()?),
            self.trash_root.clone(),
        ];
        if forbidden.contains(&self.state_root) || part_count(&self.state_root) < 3 {
            return Err(refuse(
                format!("Refusing unsafe Relay state root: {}", self.state_root),
                "Use the exact Relay-owned Application Support directory.",
            ));
        }
        if name(&self.state_root) != "relay-runner" {
            return Err(refuse(
                format!("State root is not Relay-owned by name: {}", self.state_root),
                "Use .../Application Support/relay-runner (or an equivalent test fixture name).",
            ));
        }
        Ok(())
    }

    fn inject(&self, stage: &str) -> Outcome<()> {
        let Some(injector) = &self.failure_injector else {
            return Ok(());
        };
        injector(stage).map_err(|error| Failure::Refused {
            message: format!("Injected fresh-install interruption at {stage}: {error}"),
            recovery: "Use the recorded app/state backup; never modify registered repositories."
                .to_string(),
            injected: true,
        })
    }

    fn state_manifest(&self) -> Outcome<Manifest> {
        if !exists(&self.state_root) {
            return Ok(Manifest::new());
        }
        if is_symlink(&self.state_root) || !is_dir(&self.state_root) {
            return Err(refuse(
                "Relay state root is not a normal directory.",
                "Repair the owned state path before reinstall/reset.",
            ));
        }
        tree_manifest(Path::new(&self.state_root))
    }

    fn profile_resources(&self, profile: &str) -> Outcome<Vec<(String, String)>> {
        profile_resources(
            profile,
            &self.state_root,
            &self.home_root,
            &self.temporary_root,
        )
    }

    fn active_relay_processes(&self) -> Outcome<Vec<String>> {
        match &self.active_process_detector {
            Some(detector) => Ok(detector()),
            None => active_relay_processes(),
        }
    }

    /// `_registered_repository_snapshots`: one snapshot per project in
    /// `projects/registry-v2.json` with a resolved path.
    fn registered_repository_snapshots(&self) -> Outcome<Vec<Dict>> {
        let registry = join(&self.state_root, "projects/registry-v2.json");
        let Some(Value::Dict(document)) = fs::read(&registry)
            .ok()
            .and_then(|bytes| json::parse_bytes(&bytes))
        else {
            return Ok(Vec::new());
        };
        let projects = document
            .get("projects")
            .and_then(Value::as_list)
            .unwrap_or_default();
        let mut result = Vec::new();
        for record in projects {
            let Value::Dict(record) = record else {
                continue;
            };
            let raw = record
                .get("last_resolved_path")
                .filter(|value| value.truthy())
                .map(Value::py_str)
                .unwrap_or_default();
            let raw = json::py_strip(&raw);
            if raw.is_empty() {
                continue;
            }
            let repo = resolve_user(raw)?;
            let project_id = record.get("project_id").cloned().unwrap_or(Value::Null);
            if !is_dir(&repo) {
                let mut missing = Dict::new();
                missing.insert("project_id", project_id);
                missing.insert("repo_path", repo);
                missing.insert("available", false);
                result.push(missing);
                continue;
            }
            result.push(repository_snapshot(&repo, &project_id)?);
        }
        Ok(result)
    }

    /// `_active_run_ids`: runs whose state blocks a reset.
    fn active_run_ids(&self) -> Outcome<Vec<i64>> {
        let mut path = join(&self.state_root, "runs.db");
        if !exists(&path) {
            path = join(&self.state_root, "orchestrator/runs.db");
        }
        if !exists(&path) {
            return Ok(Vec::new());
        }
        let rows =
            (|| -> rusqlite::Result<Vec<(rusqlite::types::Value, rusqlite::types::Value)>> {
                let connection = rusqlite::Connection::open_with_flags(
                    format!("file:{path}?mode=ro"),
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                        | rusqlite::OpenFlags::SQLITE_OPEN_URI,
                )?;
                let mut statement = connection.prepare("SELECT id, state FROM runs ORDER BY id")?;
                statement
                    .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                    .collect()
            })()
            .map_err(|error| {
                let message = match &error {
                    rusqlite::Error::SqliteFailure(_, Some(message)) => message.clone(),
                    other => other.to_string(),
                };
                refuse(
                    format!("Runs ledger cannot prove reset quiescence: {message}"),
                    "Repair/restore runs.db before deliberate state reset.",
                )
            })?;
        let mut ids = Vec::new();
        for (id, state) in rows {
            let rusqlite::types::Value::Text(state) = state else {
                continue;
            };
            if !RESET_ACTIVE_STATES.contains(&state.as_str()) {
                continue;
            }
            match id {
                rusqlite::types::Value::Integer(id) => ids.push(id),
                rusqlite::types::Value::Real(id) => ids.push(id as i64),
                _ => {
                    return Err(Failure::Other(
                        "ValueError: a run id is not a number".to_string(),
                    ));
                }
            }
        }
        Ok(ids)
    }

    fn verify_repositories(snapshots: &[Dict]) -> Outcome<()> {
        let values: Vec<Value> = snapshots.iter().cloned().map(Value::Dict).collect();
        verify_repository_snapshots(&values)
    }

    fn validate_app_bundle(path: &str) -> Outcome<()> {
        let bundle_name = name(path);
        let suffix_is_app = bundle_name.len() > ".app".len() && bundle_name.ends_with(".app");
        if is_symlink(path) || !is_dir(path) || !suffix_is_app {
            return Err(refuse(
                format!("Reviewed source is not a normal .app bundle: {path}"),
                "Build or select a verified Relay Runner.app bundle.",
            ));
        }
        if !is_file(&join(path, "Contents/Info.plist")) {
            return Err(refuse(
                "Source app bundle has no Contents/Info.plist.",
                "Rebuild the complete app bundle before install.",
            ));
        }
        Ok(())
    }

    pub fn preview_reinstall(&self, source_app: &str, destination_app: &str) -> Outcome<Preview> {
        let source = resolve_user(source_app)?;
        let destination = resolve_user(destination_app)?;
        Self::validate_app_bundle(&source)?;
        match &self.identity_check {
            Some(check) => check(Path::new(&source), Path::new(&destination))?,
            None => verify_update_identity(Path::new(&source), Path::new(&destination))?,
        }
        let state = self.state_manifest()?;
        Ok(Preview {
            action: "reinstall",
            state_root: self.state_root.clone(),
            state_manifest_sha256: json_digest(&manifest_value(&state)),
            state_files: state.len(),
            registered_repositories: self.registered_repository_snapshots()?,
            active_run_ids: self.active_run_ids()?,
            source_app: Some(source),
            destination_app: Some(destination),
            ..Preview::default()
        })
    }

    pub fn reinstall(
        &self,
        source_app: &str,
        destination_app: &str,
        execute: bool,
    ) -> Outcome<Completed> {
        if !execute {
            return Err(refuse(
                "Reinstall execution was not explicitly confirmed.",
                "Review preview_reinstall output, then rerun with --execute.",
            ));
        }
        let preview = self.preview_reinstall(source_app, destination_app)?;
        let state_before = self.state_manifest()?;
        let repositories_before = preview.registered_repositories.clone();
        let source = preview.source_app.clone().unwrap_or_default();
        let destination = preview.destination_app.clone().unwrap_or_default();
        let destination_parent = parent(&destination);
        fs::create_dir_all(&destination_parent).map_err(io_at(Path::new(&destination_parent)))?;
        let temporary = join(
            &destination_parent,
            &format!(".{}.relay-install-{}", name(&destination), random_hex()),
        );
        let mut backup: Option<String> = None;
        let attempt = (|| -> Outcome<()> {
            copy_tree(Path::new(&source), Path::new(&temporary))?;
            if tree_manifest(Path::new(&temporary))? != tree_manifest(Path::new(&source))? {
                return Err(refuse(
                    "Copied app bundle failed byte-level verification.",
                    "Keep the installed app unchanged and rebuild a valid source bundle.",
                ));
            }
            self.inject("before_app_replacement")?;
            if lexists(&destination) {
                fs::create_dir_all(&self.trash_root).map_err(io_at(Path::new(&self.trash_root)))?;
                let moved = join(
                    &self.trash_root,
                    &format!(
                        "Relay Runner.app-before-reinstall-{}-{}",
                        timestamp(),
                        &random_hex()[..8]
                    ),
                );
                fs::rename(&destination, &moved).map_err(io_at(Path::new(&destination)))?;
                backup = Some(moved);
            }
            fs::rename(&temporary, &destination).map_err(io_at(Path::new(&temporary)))?;
            self.inject("after_app_replacement")?;
            if tree_manifest(Path::new(&destination))? != tree_manifest(Path::new(&source))? {
                return Err(refuse(
                    "Installed app bundle differs from the reviewed source bundle.",
                    "Restore the recoverable prior app and retry the install.",
                ));
            }
            self.verify_preserved(&state_before, &repositories_before)
        })();
        if let Err(failure) = attempt {
            if is_dir(&temporary) && !is_symlink(&temporary) {
                fs::remove_dir_all(&temporary)?;
            }
            if let Some(backup) = backup.as_deref().filter(|backup| exists(backup)) {
                if lexists(&destination) {
                    let failed = join(
                        &self.trash_root,
                        &format!(
                            "Relay Runner.app-failed-reinstall-{}-{}",
                            timestamp(),
                            &random_hex()[..8]
                        ),
                    );
                    fs::rename(&destination, failed)?;
                }
                fs::rename(backup, &destination)?;
            }
            return Err(failure);
        }
        Ok(Completed {
            destination_app: Some(destination),
            replaced_app_backup: backup,
            ..Completed::new("reinstall")
        })
    }

    fn verify_preserved(
        &self,
        state_before: &Manifest,
        repositories_before: &[Dict],
    ) -> Outcome<()> {
        if &self.state_manifest()? != state_before {
            return Err(refuse(
                "Normal reinstall changed Relay Application Support.",
                "Restore the state backup and reject this install artifact.",
            ));
        }
        Self::verify_repositories(repositories_before)
    }

    pub fn preview_profile(&self, profile: &str) -> Outcome<Preview> {
        let resources = self.profile_resources(profile)?;
        let state = self.state_manifest()?;
        let mut reset_resources = Vec::new();
        for (resource, path) in resources {
            let mut item = Dict::new();
            item.insert("name", resource);
            item.insert("path", path.as_str());
            item.insert("present", lexists(&path));
            item.insert("manifest_sha256", resource_digest(&path)?);
            reset_resources.push(item);
        }
        Ok(Preview {
            action: "reset_profile",
            state_root: self.state_root.clone(),
            state_manifest_sha256: json_digest(&manifest_value(&state)),
            state_files: state.len(),
            registered_repositories: self.registered_repository_snapshots()?,
            active_run_ids: self.active_run_ids()?,
            profile: Some(profile.to_string()),
            reset_resources,
            machine_state_not_reset: UNRESETTABLE_MACHINE_STATE.to_vec(),
            ..Preview::default()
        })
    }

    pub fn reset_profile(
        &self,
        profile: &str,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: Option<&str>,
    ) -> Outcome<Completed> {
        if !execute || !confirm_daemon_stopped || confirm_profile != Some(profile) {
            return Err(refuse(
                format!(
                    "Profile reset requires --execute, --confirm-daemon-stopped, and \
                     --confirm-profile {profile}."
                ),
                "Stop Relay writers, review the profile preview, then repeat its exact profile name.",
            ));
        }
        let preview = self.preview_profile(profile)?;
        if !preview.active_run_ids.is_empty() {
            return Err(refuse(
                format!(
                    "Profile reset refused active or review-blocking runs: {}",
                    preview
                        .active_run_ids
                        .iter()
                        .map(i64::to_string)
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                "Drain, finish, cancel, or reconcile every listed run before reset.",
            ));
        }
        let active_processes = self.active_relay_processes()?;
        if !active_processes.is_empty() {
            return Err(refuse(
                format!(
                    "Profile reset refused active Relay processes: {}",
                    active_processes.join(", ")
                ),
                "Quit Relay Runner and its bridge, daemon, and TTS workers before retrying.",
            ));
        }
        let repositories_before = preview.registered_repositories.clone();
        fs::create_dir_all(&self.trash_root).map_err(io_at(Path::new(&self.trash_root)))?;
        let destination = join(
            &self.trash_root,
            &format!(
                "relay-runner-{profile}-{}-{}",
                timestamp(),
                &random_hex()[..8]
            ),
        );
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&destination)
                .map_err(io_at(Path::new(&destination)))?;
        }
        let manifest_path = join(&destination, "reset-recovery.json");
        let mut manifest = Dict::new();
        manifest.insert("schema_version", 3_i64);
        manifest.insert("action", "reset_profile");
        manifest.insert("profile", profile);
        manifest.insert("moved_at", timestamp());
        manifest.insert("resources", Value::List(Vec::new()));
        manifest.insert(
            "registered_repositories",
            Value::List(
                repositories_before
                    .iter()
                    .cloned()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        manifest.insert("restore_requires_daemon_stopped", true);
        manifest.insert("repositories_must_not_be_mutated", true);
        manifest.insert(
            "machine_state_not_reset",
            Value::List(
                UNRESETTABLE_MACHINE_STATE
                    .iter()
                    .map(|item| Value::from(*item))
                    .collect(),
            ),
        );
        if let Err(error) = write_json_atomic(&manifest_path, &Value::Dict(manifest.clone())) {
            fs::remove_dir(&destination)?;
            return Err(refuse(
                format!(
                    "Could not persist reset recovery journal: {}",
                    os_error_text(&error, None)
                ),
                "Nothing was moved; repair available storage and retry the deliberate reset.",
            ));
        }
        let mut moved: Vec<(String, String)> = Vec::new();
        let attempt = (|| -> Outcome<()> {
            self.inject("before_profile_move")?;
            let mut resources: Vec<Value> = Vec::new();
            for (index, (resource, source)) in
                self.profile_resources(profile)?.into_iter().enumerate()
            {
                if !lexists(&source) {
                    continue;
                }
                let target = join(&destination, &format!("{index:02}-{resource}"));
                let mut record = Dict::new();
                record.insert("name", resource.as_str());
                record.insert("original_path", source.as_str());
                record.insert("trashed_path", target.as_str());
                resources.push(Value::Dict(record));
                manifest.insert("resources", Value::List(resources.clone()));
                write_json_atomic(&manifest_path, &Value::Dict(manifest.clone()))
                    .map_err(io_at(Path::new(&manifest_path)))?;
                fs::rename(&source, &target).map_err(io_at(Path::new(&source)))?;
                moved.push((source, target));
                self.inject(&format!("after_profile_move:{resource}"))?;
            }
            Ok(())
        })();
        if let Err(failure) = attempt {
            restore_moved_resources(&moved)?;
            if is_file(&manifest_path) && !is_symlink(&manifest_path) {
                fs::remove_file(&manifest_path)?;
            }
            if exists(&destination) && is_empty_dir(&destination)? {
                fs::remove_dir(&destination)?;
            }
            return Err(failure);
        }
        self.inject("after_profile_move")?;
        Self::verify_repositories(&repositories_before)?;
        Ok(Completed {
            recovery_manifest: Some(manifest_path),
            trashed_state: Some(destination),
            profile: Some(profile.to_string()),
            ..Completed::new("reset_profile")
        })
    }

    /// `reset_state`: the compatibility reset for the Relay-owned profile,
    /// which only the ported tests still call.
    #[cfg(test)]
    pub fn reset_state(
        &self,
        execute: bool,
        confirm_daemon_stopped: bool,
        confirm_profile: Option<&str>,
    ) -> Outcome<Completed> {
        self.reset_profile(
            PROFILE_RELAY_OWNED,
            execute,
            confirm_daemon_stopped,
            confirm_profile,
        )
    }

    pub fn capture_evidence(
        &self,
        output: &str,
        installer_context: &str,
        startup_outcome: &str,
        source_app: Option<&str>,
        incident_bundle: Option<&str>,
    ) -> Outcome<Completed> {
        let app_evidence = match source_app {
            None => Value::Null,
            Some(source_app) => {
                let app = resolve_user(source_app)?;
                Self::validate_app_bundle(&app)?;
                let info = read_plist(&join(&app, "Contents/Info.plist"))?;
                let field = |key: &str| info.get(key).cloned().unwrap_or(Value::Null);
                let mut evidence = Dict::new();
                evidence.insert("bundle_name", name(&app));
                evidence.insert("bundle_identifier", field("CFBundleIdentifier"));
                evidence.insert("short_version", field("CFBundleShortVersionString"));
                evidence.insert("build_version", field("CFBundleVersion"));
                evidence.insert(
                    "bundle_manifest_sha256",
                    json_digest(&manifest_value(&tree_manifest(Path::new(&app))?)),
                );
                Value::Dict(evidence)
            }
        };
        let incident_evidence = match incident_bundle {
            None => Value::Null,
            Some(incident_bundle) => {
                let bundle = resolve_user(incident_bundle)?;
                if !is_file(&bundle) {
                    return Err(refuse(
                        "Incident/support bundle must be a file.",
                        "Create the bundle first, then record only its filename and checksum.",
                    ));
                }
                let content = fs::read(&bundle).map_err(io_at(Path::new(&bundle)))?;
                let mut evidence = Dict::new();
                evidence.insert("filename", name(&bundle));
                evidence.insert("bytes", content.len() as i64);
                evidence.insert("sha256", hex_digest(&content));
                Value::Dict(evidence)
            }
        };
        let destination = resolve_user(output)?;
        let mut document = Dict::new();
        document.insert("schema_version", 1_i64);
        document.insert("captured_at", timestamp());
        document.insert("installer_context", installer_context);
        // Python recorded its interpreter (`sys.version`); the runtime is
        // now relay-rs, so its version string stands in.
        document.insert("runtime_version", crate::VERSION);
        document.insert("startup_outcome", startup_outcome);
        document.insert("app", app_evidence);
        document.insert("incident_support_bundle", incident_evidence);
        document.insert("source_content_captured", false);
        write_json_atomic(&destination, &Value::Dict(document))
            .map_err(io_at(Path::new(&destination)))?;
        Ok(Completed {
            evidence_path: Some(destination),
            ..Completed::new("capture_evidence")
        })
    }
}

/// `_restore_moved_resources`: put back what a failed reset moved, newest
/// first, without overwriting anything that reappeared.
fn restore_moved_resources(moved: &[(String, String)]) -> Outcome<()> {
    for (original, trashed) in moved.iter().rev() {
        if lexists(trashed) && !lexists(original) {
            fs::create_dir_all(parent(original))?;
            fs::rename(trashed, original)?;
        }
    }
    Ok(())
}

/// `shutil.copytree(source, destination, symlinks=True)`: symlinks copied as
/// links, file contents with their permissions and times.
fn copy_tree(source: &Path, destination: &Path) -> Outcome<()> {
    fs::create_dir(destination).map_err(io_at(destination))?;
    let mut children: Vec<PathBuf> = fs::read_dir(source)
        .map_err(io_at(source))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    children.sort();
    for child in children {
        let target = destination.join(child.file_name().unwrap_or_default());
        let metadata = fs::symlink_metadata(&child).map_err(io_at(&child))?;
        if metadata.file_type().is_symlink() {
            std::os::unix::fs::symlink(fs::read_link(&child)?, &target).map_err(io_at(&target))?;
        } else if metadata.is_dir() {
            copy_tree(&child, &target)?;
        } else {
            fs::copy(&child, &target).map_err(io_at(&child))?;
            let times = fs::FileTimes::new()
                .set_accessed(metadata.accessed()?)
                .set_modified(metadata.modified()?);
            // Best effort, as for a read-only file the times cannot be set
            // through a writable handle.
            if let Ok(file) = File::options().write(true).open(&target) {
                let _ = file.set_times(times);
            }
        }
    }
    let metadata = fs::metadata(source)?;
    fs::set_permissions(
        destination,
        fs::Permissions::from_mode(metadata.mode() & 0o7777),
    )?;
    Ok(())
}

/// `plistlib.loads(path.read_bytes())`, through `plutil`, which reads XML
/// and binary property lists alike.
fn read_plist(path: &str) -> Outcome<Dict> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-convert", "json", "-o", "-", "--", path])
        .stdin(Stdio::null())
        .output()
        .map_err(io_at(Path::new("/usr/bin/plutil")))?;
    match json::parse_bytes(&output.stdout) {
        Some(Value::Dict(info)) if output.status.success() => Ok(info),
        _ => Err(Failure::Other(format!(
            "InvalidFileException: {path} is not a readable property list"
        ))),
    }
}

/// `_read_recovery_manifest`.
fn read_recovery_manifest(recovery_manifest: &str) -> Outcome<(String, Dict)> {
    let expanded = paths::expanduser(recovery_manifest)
        .map_err(|error| Failure::Other(format!("RuntimeError: {}", error.message)))?;
    let candidate = if expanded.starts_with('/') {
        expanded
    } else {
        let cwd = std::env::current_dir()?;
        join(&cwd.to_string_lossy(), &expanded)
    };
    if is_symlink(&candidate) {
        return Err(refuse(
            "Reset recovery manifest must not be a symlink.",
            "Use the original reset-recovery.json inside the Relay Trash backup directory.",
        ));
    }
    let invalid = |detail: String| {
        refuse(
            format!("Reset recovery manifest is invalid: {detail}"),
            "Select the reset-recovery.json inside the moved Trash directory.",
        )
    };
    let bytes = fs::read(&candidate)
        .map_err(|error| invalid(os_error_text(&error, Some(Path::new(&candidate)))))?;
    let text = String::from_utf8(bytes).map_err(|_| {
        Failure::Other("UnicodeDecodeError: the recovery manifest is not UTF-8".to_string())
    })?;
    let Some(document) = json::parse(&text) else {
        return Err(invalid("not valid JSON".to_string()));
    };
    let Value::Dict(document) = document else {
        return Err(refuse(
            "Reset recovery manifest is not an object.",
            "Select the original reset-recovery.json.",
        ));
    };
    Ok((candidate, document))
}

/// `_validate_profile_recovery_resources`: the manifest must sit in its own
/// Relay Trash backup and name only the profile's allowlisted resources.
fn validate_profile_recovery_resources(
    manifest_path: &str,
    profile: &str,
    resources: &[Value],
    expected_resources: &[(String, String)],
    trash_root: &str,
) -> Outcome<()> {
    let backup_root = parent(manifest_path);
    if name(manifest_path) != "reset-recovery.json"
        || paths::normalize(&parent(&backup_root)) != paths::normalize(trash_root)
        || !name(&backup_root).starts_with(&format!("relay-runner-{profile}-"))
        || is_symlink(&backup_root)
    {
        return Err(refuse(
            "Profile recovery manifest is not in the expected Relay Trash backup location.",
            "Use the original reset-recovery.json inside its Relay profile backup directory.",
        ));
    }
    let expected: HashMap<&str, (String, String)> = expected_resources
        .iter()
        .enumerate()
        .map(|(index, (resource, path))| {
            (
                resource.as_str(),
                (
                    paths::resolve(path),
                    join(&backup_root, &format!("{index:02}-{resource}")),
                ),
            )
        })
        .collect();
    let tampered = || {
        refuse(
            "Profile recovery manifest has a resource outside the declared profile allowlist.",
            "Restore the original untampered recovery manifest.",
        )
    };
    let mut seen: Vec<String> = Vec::new();
    for item in resources {
        let Value::Dict(item) = item else {
            return Err(refuse(
                "Profile recovery manifest has an invalid resource inventory.",
                "Restore the original untampered recovery manifest.",
            ));
        };
        let Some(Value::Str(resource)) = item.get("name") else {
            return Err(tampered());
        };
        if seen.contains(resource) {
            return Err(tampered());
        }
        let Some((expected_target, expected_backup)) = expected.get(resource.as_str()) else {
            return Err(tampered());
        };
        seen.push(resource.clone());
        let matches = matches!(
            (item.get("trashed_path"), item.get("original_path")),
            (Some(Value::Str(backup)), Some(Value::Str(original)))
                if backup == expected_backup && original == expected_target
        );
        if !matches {
            return Err(refuse(
                "Profile recovery manifest resource paths do not match the declared profile allowlist.",
                "Restore the original untampered recovery manifest.",
            ));
        }
    }
    Ok(())
}

fn str_field(item: &Dict, key: &str) -> String {
    item.get(key).map(Value::py_str).unwrap_or_default()
}

/// `FreshInstallCoordinator.restore_profile`.
pub fn restore_profile(recovery_manifest: &str, options: &RestoreOptions) -> Outcome<Completed> {
    if !options.execute || !options.confirm_daemon_stopped {
        return Err(refuse(
            "Profile restore requires --execute and --confirm-daemon-stopped.",
            "Stop Relay writers and rerun the recorded restore.",
        ));
    }
    let (path, document) = read_recovery_manifest(recovery_manifest)?;
    let profile = document
        .get("profile")
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default();
    if !document
        .get("action")
        .is_some_and(|action| action.is_str("reset_profile"))
        || !RESET_PROFILES.contains(&profile.as_str())
        || options.confirm_profile.as_deref() != Some(profile.as_str())
    {
        return Err(refuse(
            "Profile recovery manifest or confirmation does not match a supported profile.",
            "Use the exact reset-recovery.json and repeat its profile name.",
        ));
    }
    let resources = match document.get("resources") {
        Some(Value::List(resources)) if !resources.is_empty() => resources.clone(),
        _ => {
            return Err(refuse(
                "Profile recovery manifest has no recoverable resource inventory.",
                "Restore the original untampered recovery manifest.",
            ));
        }
    };
    let expected_home = match &options.home_root {
        Some(home_root) => resolve_user(home_root)?,
        None => paths::resolve(&home()?),
    };
    let expected_state = match &options.state_root {
        Some(state_root) => resolve_user(state_root)?,
        None => join(&expected_home, "Library/Application Support/relay-runner"),
    };
    let expected_temporary = resolve_user(&options.temporary_root)?;
    let expected_trash = match &options.trash_root {
        Some(trash_root) => resolve_user(trash_root)?,
        None => join(&expected_home, ".Trash"),
    };
    let expected_resources = profile_resources(
        &profile,
        &expected_state,
        &expected_home,
        &expected_temporary,
    )?;
    validate_profile_recovery_resources(
        &path,
        &profile,
        &resources,
        &expected_resources,
        &expected_trash,
    )?;
    let moves: Vec<(String, String)> = resources
        .iter()
        .filter_map(Value::as_dict)
        .map(|item| {
            (
                str_field(item, "trashed_path"),
                str_field(item, "original_path"),
            )
        })
        .collect();
    for (source, target) in &moves {
        if !lexists(source) || lexists(target) {
            return Err(refuse(
                "Automatic profile restore would overwrite state or use an ambiguous backup.",
                "Move new state aside only after review, then use the original recovery manifest.",
            ));
        }
    }
    let Some(Value::List(snapshots)) = document.get("registered_repositories") else {
        return Err(refuse(
            "Recovery manifest has no repository safety evidence.",
            "Restore the original untampered recovery manifest.",
        ));
    };
    verify_repository_snapshots(snapshots)?;
    for (source, target) in &moves {
        fs::create_dir_all(parent(target))?;
        fs::rename(source, target)?;
    }
    verify_repository_snapshots(snapshots)?;
    Ok(Completed {
        recovery_manifest: Some(path),
        profile: Some(profile),
        ..Completed::new("restore_profile")
    })
}

/// `FreshInstallCoordinator.restore_reset`: a profile restore, or the
/// schema-1 restore of a whole moved state root.
pub fn restore_reset(recovery_manifest: &str, options: &RestoreOptions) -> Outcome<Completed> {
    if !options.execute || !options.confirm_daemon_stopped {
        return Err(refuse(
            "State restore requires --execute and explicit confirmation that Relay writers are stopped.",
            "Stop the app/daemon and rerun the recorded restore.",
        ));
    }
    let (path, document) = read_recovery_manifest(recovery_manifest)?;
    if document
        .get("action")
        .is_some_and(|action| action.is_str("reset_profile"))
    {
        return restore_profile(&path, options);
    }
    let field = |key: &str| {
        document
            .get(key)
            .filter(|value| value.truthy())
            .map(Value::py_str)
            .unwrap_or_default()
    };
    let moved = paths::resolve(&field("trashed_state"));
    let target = paths::resolve(&field("original_state_root"));
    let expected_path = join(
        &parent(&moved),
        &format!("{}.reset-recovery.json", name(&moved)),
    );
    if paths::normalize(&path) != expected_path || !is_dir(&moved) || is_symlink(&moved) {
        return Err(refuse(
            "Moved state directory no longer matches its recovery manifest.",
            "Locate the exact recorded Trash directory; do not merge ambiguous state.",
        ));
    }
    if exists(&target) {
        if is_dir(&target) && !is_symlink(&target) && is_empty_dir(&target)? {
            fs::remove_dir(&target)?;
        } else {
            return Err(refuse(
                "Relay created new non-empty state after reset; automatic restore would overwrite it.",
                "Stop writers and explicitly reconcile or move the new state first.",
            ));
        }
    }
    let Some(Value::List(repositories)) = document.get("registered_repositories") else {
        return Err(refuse(
            "Recovery manifest has no repository safety evidence.",
            "Restore the original untampered recovery manifest.",
        ));
    };
    verify_repository_snapshots(repositories)?;
    fs::create_dir_all(parent(&target))?;
    fs::rename(&moved, &target)?;
    verify_repository_snapshots(repositories)?;
    Ok(Completed {
        recovery_manifest: Some(path),
        ..Completed::new("restore_state")
    })
}

// -- the command line -------------------------------------------------------------------

const SPEC: Spec = Spec {
    prog: "relay-runner-fresh-install",
    usage: "relay-runner-fresh-install [-h] [--reset-state | --reset-profile {relay-owned,voice-models,provider-integrations} | --restore-reset RESTORE_RESET | --restore-profile RESTORE_PROFILE | --capture-evidence CAPTURE_EVIDENCE] [--app APP] [--destination DESTINATION] [--state-root STATE_ROOT] [--trash-root TRASH_ROOT] [--home-root HOME_ROOT] [--temporary-root TEMPORARY_ROOT] [--execute] [--confirm-daemon-stopped] [--confirm-profile {relay-owned,voice-models,provider-integrations}] [--installer-context INSTALLER_CONTEXT] [--startup-outcome STARTUP_OUTCOME] [--incident-bundle INCIDENT_BUNDLE]",
    help: "\nPreserving reinstall and recoverable Relay state reset\n\n\
           options:\n  \
           -h, --help            show this help message and exit\n  \
           --reset-state         Deprecated alias for --reset-profile relay-owned\n  \
           --reset-profile {relay-owned,voice-models,provider-integrations}\n  \
           --restore-reset RESTORE_RESET\n  \
           --restore-profile RESTORE_PROFILE\n  \
           --capture-evidence CAPTURE_EVIDENCE\n  \
           --app APP             Reviewed Relay Runner.app source for normal reinstall\n  \
           --destination DESTINATION\n  \
           --state-root STATE_ROOT\n  \
           --trash-root TRASH_ROOT\n  \
           --home-root HOME_ROOT\n  \
           --temporary-root TEMPORARY_ROOT\n  \
           --execute\n  \
           --confirm-daemon-stopped\n  \
           --confirm-profile {relay-owned,voice-models,provider-integrations}\n  \
           --installer-context INSTALLER_CONTEXT\n  \
           --startup-outcome STARTUP_OUTCOME\n  \
           --incident-bundle INCIDENT_BUNDLE",
    options: &[
        Opt::flag("--reset-state"),
        Opt::choice("--reset-profile", &RESET_PROFILES),
        Opt::value("--restore-reset"),
        Opt::value("--restore-profile"),
        Opt::value("--capture-evidence"),
        Opt::value("--app"),
        Opt::value("--destination"),
        Opt::value("--state-root"),
        Opt::value("--trash-root"),
        Opt::value("--home-root"),
        Opt::value("--temporary-root"),
        Opt::flag("--execute"),
        Opt::flag("--confirm-daemon-stopped"),
        Opt::choice("--confirm-profile", &RESET_PROFILES),
        Opt::value("--installer-context"),
        Opt::value("--startup-outcome"),
        Opt::value("--incident-bundle"),
    ],
    positionals: &[],
    exclusive: &[
        "--reset-state",
        "--reset-profile",
        "--restore-reset",
        "--restore-profile",
        "--capture-evidence",
    ],
};

/// `fresh_install_cli.main()` after parsing: the operation the flags select.
fn execute(parsed: &crate::cli::Parsed) -> Outcome<Value> {
    let home = home()?;
    let state_root = parsed.value("--state-root").map_or_else(
        || join(&home, "Library/Application Support/relay-runner"),
        str::to_string,
    );
    let home_root = parsed.value("--home-root").unwrap_or(&home).to_string();
    let temporary_root = parsed
        .value("--temporary-root")
        .unwrap_or("/tmp")
        .to_string();
    let trash_root = parsed.value("--trash-root").map(str::to_string);
    let execute = parsed.flag("--execute");
    let confirm_daemon_stopped = parsed.flag("--confirm-daemon-stopped");
    let confirm_profile = parsed.value("--confirm-profile");
    let restore = || RestoreOptions {
        execute,
        confirm_daemon_stopped,
        confirm_profile: confirm_profile.map(str::to_string),
        state_root: Some(state_root.clone()),
        home_root: Some(home_root.clone()),
        temporary_root: temporary_root.clone(),
        trash_root: trash_root.clone(),
    };
    if let Some(manifest) = parsed.value("--restore-profile") {
        return Ok(restore_profile(manifest, &restore())?.as_value());
    }
    if let Some(manifest) = parsed.value("--restore-reset") {
        return Ok(restore_reset(manifest, &restore())?.as_value());
    }
    let coordinator = Coordinator::new(Roots {
        state_root: state_root.clone(),
        trash_root: trash_root.clone(),
        home_root: Some(home_root.clone()),
        temporary_root: temporary_root.clone(),
    })?;
    let profile = parsed
        .value("--reset-profile")
        .or_else(|| parsed.flag("--reset-state").then_some(PROFILE_RELAY_OWNED));
    if let Some(output) = parsed.value("--capture-evidence") {
        return Ok(coordinator
            .capture_evidence(
                output,
                parsed
                    .value("--installer-context")
                    .unwrap_or("manual install"),
                parsed.value("--startup-outcome").unwrap_or("not recorded"),
                parsed.value("--app"),
                parsed.value("--incident-bundle"),
            )?
            .as_value());
    }
    if let Some(profile) = profile {
        return Ok(if execute {
            coordinator
                .reset_profile(profile, true, confirm_daemon_stopped, confirm_profile)?
                .as_value()
        } else {
            coordinator.preview_profile(profile)?.as_value()
        });
    }
    let Some(app) = parsed.value("--app") else {
        return Err(refuse(
            "Normal reinstall requires --app <reviewed Relay Runner.app>.",
            "Build/select the app bundle, run preflight, then add --execute.",
        ));
    };
    let destination = parsed
        .value("--destination")
        .unwrap_or("/Applications/Relay Runner.app");
    Ok(if execute {
        coordinator.reinstall(app, destination, true)?.as_value()
    } else {
        coordinator.preview_reinstall(app, destination)?.as_value()
    })
}

pub fn run(arguments: &[String]) -> u8 {
    let parsed = match SPEC.parse(arguments) {
        Ok(parsed) => parsed,
        Err(exit) => return exit.report(),
    };
    let mut answer = Dict::new();
    match execute(&parsed) {
        Ok(result) => {
            answer.insert("ok", true);
            answer.insert("result", result);
            println!(
                "{}",
                relay_artifacts::rollout::dumps_indent_sorted(&Value::Dict(answer))
            );
            0
        }
        Err(Failure::Refused {
            message, recovery, ..
        }) => {
            answer.insert("ok", false);
            answer.insert("error", message);
            answer.insert("recovery", recovery);
            println!(
                "{}",
                relay_artifacts::history::dumps_indent(&Value::Dict(answer))
            );
            2
        }
        Err(Failure::Other(message)) => {
            eprintln!("relay-runner-fresh-install: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// HEAD, refs, status and the `.orchestrator/` tree of the fixture repository.
    type RepoSnapshot = (Vec<u8>, Vec<u8>, Vec<u8>, BTreeMap<String, Vec<u8>>);

    /// `FreshInstallTests`' fixture: a registered repository with dirty and
    /// untracked files, Relay state that registers it, and two app bundles.
    struct Fixture {
        root: String,
        state: String,
        trash: String,
        home: String,
        tmp: String,
        repo: String,
        source_app: String,
        destination_app: String,
    }

    impl Fixture {
        fn new() -> Self {
            let base =
                std::env::temp_dir().join(format!("relay-fresh-install-tests-{}", random_hex()));
            fs::create_dir_all(&base).unwrap();
            let root = paths::resolve(&base.to_string_lossy());
            let fixture = Self {
                state: join(&root, "Application Support/relay-runner"),
                trash: join(&root, "Trash"),
                home: join(&root, "home"),
                tmp: join(&root, "tmp"),
                repo: join(&root, "registered-project"),
                source_app: join(&root, "build/Relay Runner.app"),
                destination_app: join(&root, "Applications/Relay Runner.app"),
                root,
            };
            fixture.make_repo();
            fixture.make_state();
            make_app(&fixture.source_app, b"new-app");
            make_app(&fixture.destination_app, b"old-app");
            fixture
        }

        /// The coordinator with no running processes and, since the fixture
        /// bundles are marker bytes rather than signed Mach-O bundles, no
        /// signing check.
        fn coordinator(&self) -> Coordinator {
            let mut coordinator = Coordinator::new(Roots {
                state_root: self.state.clone(),
                trash_root: Some(self.trash.clone()),
                home_root: Some(self.home.clone()),
                temporary_root: self.tmp.clone(),
            })
            .unwrap();
            coordinator.active_process_detector = Some(Box::new(Vec::new));
            coordinator.identity_check = Some(Box::new(|_, _| Ok(())));
            coordinator
        }

        fn restore_options(&self) -> RestoreOptions {
            RestoreOptions {
                execute: true,
                confirm_daemon_stopped: true,
                confirm_profile: Some(PROFILE_RELAY_OWNED.to_string()),
                state_root: Some(self.state.clone()),
                home_root: Some(self.home.clone()),
                temporary_root: self.tmp.clone(),
                trash_root: Some(self.trash.clone()),
            }
        }

        fn git(&self, arguments: &[&str]) -> Vec<u8> {
            let output = Command::new("git")
                .arg("-C")
                .arg(&self.repo)
                .args(arguments)
                .output()
                .unwrap();
            assert!(output.status.success(), "git {arguments:?} failed");
            output.stdout
        }

        fn make_repo(&self) {
            fs::create_dir_all(&self.repo).unwrap();
            self.git(&["init", "--initial-branch=main", "--quiet"]);
            fs::write(join(&self.repo, "source.txt"), "source\n").unwrap();
            fs::create_dir_all(join(&self.repo, ".orchestrator")).unwrap();
            fs::write(
                join(&self.repo, ".orchestrator/config.toml"),
                "prefix = \"FX\"\nnext_id = 1\n",
            )
            .unwrap();
            self.git(&["add", "."]);
            self.git(&[
                "-c",
                "user.name=Fresh Install Tests",
                "-c",
                "user.email=fresh@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "fixture",
            ]);
            fs::write(join(&self.repo, "source.txt"), "dirty source\n").unwrap();
            fs::write(join(&self.repo, "untracked.txt"), "untracked\n").unwrap();
        }

        fn make_state(&self) {
            let registry = join(&self.state, "projects/registry-v2.json");
            fs::create_dir_all(parent(&registry)).unwrap();
            let mut project = Dict::new();
            project.insert("project_id", "fixture-project");
            project.insert("last_resolved_path", paths::resolve(&self.repo));
            project.insert("availability", "available");
            let mut document = Dict::new();
            document.insert("schema_version", 2_i64);
            document.insert("active_project_id", "fixture-project");
            document.insert("projects", Value::List(vec![Value::Dict(project)]));
            fs::write(&registry, json::dumps(&Value::Dict(document))).unwrap();
            fs::write(join(&self.state, "config.toml"), "provider = 'codex'\n").unwrap();
            fs::create_dir_all(join(&self.state, "artifacts/fixture-project")).unwrap();
            fs::write(
                join(
                    &self.state,
                    "artifacts/fixture-project/materialization.json",
                ),
                "{}\n",
            )
            .unwrap();
        }

        fn repo_snapshot(&self) -> RepoSnapshot {
            (
                self.git(&["rev-parse", "HEAD"]),
                self.git(&["for-each-ref", "--format=%(refname) %(objectname)"]),
                self.git(&["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
                tree(&join(&self.repo, ".orchestrator")),
            )
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn make_app(path: &str, marker: &[u8]) {
        fs::create_dir_all(join(path, "Contents/MacOS")).unwrap();
        fs::write(
            join(path, "Contents/Info.plist"),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <plist version=\"1.0\">\n<dict>\n\
             \t<key>CFBundleIdentifier</key>\n\t<string>com.relayrunner.app</string>\n\
             \t<key>CFBundleShortVersionString</key>\n\t<string>0.0-test</string>\n\
             \t<key>CFBundleVersion</key>\n\t<string>1</string>\n\
             </dict>\n</plist>\n",
        )
        .unwrap();
        fs::write(join(path, "Contents/MacOS/relay-runner"), marker).unwrap();
    }

    /// Every regular file below `root` and its bytes.
    fn tree(root: &str) -> BTreeMap<String, Vec<u8>> {
        fn walk(root: &Path, directory: &Path, files: &mut BTreeMap<String, Vec<u8>>) {
            let Ok(entries) = fs::read_dir(directory) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let metadata = fs::symlink_metadata(&path).unwrap();
                if metadata.is_dir() {
                    walk(root, &path, files);
                } else if metadata.is_file() {
                    let relative = path
                        .strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned();
                    files.insert(relative, fs::read(&path).unwrap());
                }
            }
        }
        let mut files = BTreeMap::new();
        walk(Path::new(root), Path::new(root), &mut files);
        files
    }

    fn is_refused(outcome: &Outcome<Completed>) -> bool {
        matches!(outcome, Err(Failure::Refused { .. }))
    }

    #[test]
    fn normal_reinstall_requires_execute_and_preserves_all_state_and_registered_repositories() {
        let fixture = Fixture::new();
        let state_before = tree(&fixture.state);
        let repo_before = fixture.repo_snapshot();
        let preview = fixture
            .coordinator()
            .preview_reinstall(&fixture.source_app, &fixture.destination_app)
            .unwrap();
        assert!(preview.state_files > 0);
        assert_eq!(preview.registered_repositories.len(), 1);
        assert!(is_refused(&fixture.coordinator().reinstall(
            &fixture.source_app,
            &fixture.destination_app,
            false
        )));

        let result = fixture
            .coordinator()
            .reinstall(&fixture.source_app, &fixture.destination_app, true)
            .unwrap();

        assert!(result.state_preserved);
        assert!(result.repositories_preserved);
        assert_eq!(tree(&fixture.state), state_before);
        assert_eq!(fixture.repo_snapshot(), repo_before);
        assert_eq!(
            fs::read(join(
                &fixture.destination_app,
                "Contents/MacOS/relay-runner"
            ))
            .unwrap(),
            b"new-app"
        );
        let backup = result
            .replaced_app_backup
            .expect("the replaced app is kept");
        assert_eq!(
            fs::read(join(&backup, "Contents/MacOS/relay-runner")).unwrap(),
            b"old-app"
        );
    }

    #[test]
    fn deliberate_reset_moves_only_owned_state_to_trash_and_restore_is_exact() {
        let fixture = Fixture::new();
        let state_before = tree(&fixture.state);
        let repo_before = fixture.repo_snapshot();
        assert!(is_refused(
            &fixture.coordinator().reset_state(true, false, None)
        ));

        let result = fixture
            .coordinator()
            .reset_state(true, true, Some(PROFILE_RELAY_OWNED))
            .unwrap();

        assert!(!exists(&fixture.state));
        let trashed = result.trashed_state.clone().unwrap();
        let manifest = result.recovery_manifest.clone().unwrap();
        assert!(is_dir(&trashed));
        assert!(is_file(&manifest));
        let moved_state = join(&trashed, "00-application-support");
        assert_eq!(tree(&moved_state), state_before);
        assert_eq!(fixture.repo_snapshot(), repo_before);
        let Some(Value::Dict(recovery)) = json::parse(&fs::read_to_string(&manifest).unwrap())
        else {
            panic!("the recovery manifest is a JSON object");
        };
        assert!(
            recovery
                .get("repositories_must_not_be_mutated")
                .is_some_and(|value| matches!(value, Value::Bool(true)))
        );

        let restored = restore_reset(&manifest, &fixture.restore_options()).unwrap();

        assert!(restored.state_preserved);
        assert_eq!(tree(&fixture.state), state_before);
        assert_eq!(fixture.repo_snapshot(), repo_before);
        assert!(!exists(&moved_state));
    }

    #[test]
    fn reset_refuses_active_runs_and_processes_and_recovers_an_interrupted_move() {
        let fixture = Fixture::new();
        let mut busy = fixture.coordinator();
        busy.active_process_detector = Some(Box::new(|| vec!["123 /relay-runner".to_string()]));
        let refused =
            busy.reset_profile(PROFILE_RELAY_OWNED, true, true, Some(PROFILE_RELAY_OWNED));
        assert!(
            matches!(&refused, Err(Failure::Refused { message, .. }) if message.contains("active Relay processes")),
            "{refused:?}"
        );

        let preference = join(
            &fixture.home,
            "Library/Preferences/com.relayrunner.app.plist",
        );
        fs::create_dir_all(parent(&preference)).unwrap();
        fs::write(&preference, "preferences\n").unwrap();
        let mut interrupted = fixture.coordinator();
        interrupted.failure_injector = Some(Box::new(|stage| {
            if stage == "after_profile_move:preferences" {
                Err("simulated interruption".to_string())
            } else {
                Ok(())
            }
        }));
        let failed =
            interrupted.reset_profile(PROFILE_RELAY_OWNED, true, true, Some(PROFILE_RELAY_OWNED));
        assert!(matches!(
            failed,
            Err(Failure::Refused { injected: true, .. })
        ));
        assert!(is_dir(&fixture.state));
        assert_eq!(fs::read_to_string(&preference).unwrap(), "preferences\n");

        let runs = join(&fixture.state, "orchestrator/runs.db");
        fs::create_dir_all(parent(&runs)).unwrap();
        let connection = rusqlite::Connection::open(&runs).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE runs (id INTEGER PRIMARY KEY, state TEXT);\
                 INSERT INTO runs VALUES (41, 'Reviewing'), (42, 'Done');",
            )
            .unwrap();
        drop(connection);
        let refused = fixture.coordinator().reset_profile(
            PROFILE_RELAY_OWNED,
            true,
            true,
            Some(PROFILE_RELAY_OWNED),
        );
        assert!(
            matches!(&refused, Err(Failure::Refused { message, .. }) if message.ends_with("runs: 41")),
            "{refused:?}"
        );
    }

    #[test]
    fn voice_profile_preview_lists_only_its_models() {
        let fixture = Fixture::new();
        let preview = fixture
            .coordinator()
            .preview_profile(PROFILE_VOICE_MODELS)
            .unwrap();
        let names: Vec<String> = preview
            .reset_resources
            .iter()
            .map(|item| item.get("name").unwrap().py_str())
            .collect();
        assert_eq!(names, ["kokoro-model", "kokoro-voices"]);
        assert!(
            preview
                .machine_state_not_reset
                .contains(&"Keychain credentials")
        );
        let Value::Dict(value) = preview.as_value() else {
            panic!("a preview is an object");
        };
        assert!(
            value
                .get("source_app")
                .is_some_and(|value| matches!(value, Value::Null))
        );
    }

    #[test]
    fn state_roots_must_be_relay_owned_by_name() {
        let refused = Coordinator::new(Roots {
            state_root: "/tmp/not-relay".to_string(),
            trash_root: None,
            home_root: None,
            temporary_root: "/tmp".to_string(),
        });
        assert!(
            matches!(refused, Err(Failure::Refused { message, .. }) if message.starts_with("State root is not Relay-owned"))
        );
        let refused = Coordinator::new(Roots {
            state_root: "/relay-runner".to_string(),
            trash_root: None,
            home_root: None,
            temporary_root: "/tmp".to_string(),
        });
        assert!(
            matches!(refused, Err(Failure::Refused { message, .. }) if message.starts_with("Refusing unsafe"))
        );
    }

    #[test]
    fn process_detection_skips_only_its_own_installer_lineage() {
        let listing = "\
            100 1 /Applications/Relay Runner.app/Contents/MacOS/relay-runner\n\
            200 300 /x/relay-rs fresh-install --reset-profile relay-owned\n\
            300 1 /bin/bash /x/scripts/relay-runner-fresh-install --reset-profile relay-owned\n\
            400 1 python /workspace/relay-runner/services/fresh_install_cli.py --reset-profile relay-owned\n\
            500 1 /Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator --port 0\n\
            600 1 /Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator-mcp\n\
            700 1 /usr/bin/vim notes.txt\n\
            800 1 /x/relay-rs bridge --config c --relay\n";
        assert_eq!(
            relay_processes_in(listing, 200).unwrap(),
            [
                "100 1 /Applications/Relay Runner.app/Contents/MacOS/relay-runner",
                "400 1 python /workspace/relay-runner/services/fresh_install_cli.py --reset-profile relay-owned",
                "500 1 /Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator --port 0",
                "800 1 /x/relay-rs bridge --config c --relay",
            ]
        );
        assert!(relay_processes_in("abc 1 x\n", 1).is_err());
        assert!(relay_processes_in("12\n", 1).is_err());
    }

    #[test]
    fn cli_requires_an_app_for_a_reinstall_and_rejects_two_actions() {
        let arguments = |values: &[&str]| -> Vec<String> {
            values.iter().map(|value| value.to_string()).collect()
        };
        assert!(
            SPEC.parse(&arguments(&[
                "--reset-state",
                "--reset-profile",
                "voice-models"
            ]))
            .is_err()
        );
        let parsed = SPEC
            .parse(&arguments(&["--state-root", "/tmp/x/relay-runner"]))
            .unwrap();
        assert!(matches!(
            execute(&parsed),
            Err(Failure::Refused { message, .. }) if message.starts_with("Normal reinstall requires --app")
        ));
    }
}
