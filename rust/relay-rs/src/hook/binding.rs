//! The session binding: a small private sidecar that ties one app launch to
//! the provider's native session. It is operational state, outside the user
//! archive; no prompt, reasoning, tool output or transcript content is copied
//! into it, and a session is never discovered by its working directory.

use std::fs::{self, DirBuilder, File, OpenOptions, TryLockError};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use crate::json::{self, Dict, Value, py_eq, py_eq_optional, py_strip};
use crate::support::{Failure, env_optional, env_or, read_json_file};

const SUBPROCESS_TIMEOUT: Duration = Duration::from_secs(2);
/// How long `--record-codex-startup` watches for the native session.
const STARTUP_WAIT: Duration = Duration::from_secs(120);
const STARTUP_POLL: Duration = Duration::from_millis(200);

/// Python's `Path(path).resolve()`: absolute, symbolic links followed, and a
/// part that does not exist kept as written.
fn resolve(path: &str) -> PathBuf {
    let path = Path::new(path);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    let mut missing = Vec::new();
    let mut existing = absolute.as_path();
    let mut resolved = loop {
        if let Ok(resolved) = fs::canonicalize(existing) {
            break resolved;
        }
        match (existing.parent(), existing.components().next_back()) {
            (Some(parent), Some(last)) => {
                missing.push(last);
                existing = parent;
            }
            _ => break PathBuf::from("/"),
        }
    };
    for component in missing.into_iter().rev() {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::Normal(name) => resolved.push(name),
            _ => {}
        }
    }
    resolved
}

/// Python's `uuid.UUID(text)`: the 128-bit value, or `None` where it raises.
/// Braces, a `urn:uuid:` prefix and hyphens are optional, as they are there.
fn parse_uuid(text: &str) -> Option<u128> {
    let hex = text.replace("urn:", "").replace("uuid:", "");
    let hex = hex.trim_matches(['{', '}']).replace('-', "");
    if hex.len() != 32 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    u128::from_str_radix(&hex, 16).ok()
}

/// `str(uuid.UUID(text))`.
fn canonical_uuid(text: &str) -> Option<String> {
    let hex = format!("{:032x}", parse_uuid(text)?);
    Some(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// Runs a system tool for at most two seconds and returns its exit status
/// and stdout. A tool that does not finish is stopped and reported as a
/// failure, as `subprocess.run(timeout=2)` does.
fn run_tool(program: &str, arguments: &[&str]) -> Result<(bool, String), Failure> {
    let mut child = Command::new(program)
        .args(arguments)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdout = child.stdout.take().ok_or(Failure("OSError"))?;
    // The tool closes stdout when it exits. Waiting for that on a channel
    // wakes as soon as it happens; a polling sleep is stretched by macOS
    // timer coalescing and cost tens of milliseconds per hook.
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut output = Vec::new();
        let _ = stdout.read_to_end(&mut output);
        let _ = sender.send(output);
    });
    let Ok(output) = receiver.recv_timeout(SUBPROCESS_TIMEOUT) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(Failure("TimeoutExpired"));
    };
    let status = child.wait()?;
    Ok((
        status.success(),
        String::from_utf8_lossy(&output).into_owned(),
    ))
}

/// What identifies a process beyond its reusable pid: start time, user and
/// process group, exactly as `ps` prints them. Swift compares the same text.
fn process_identity(pid: i64) -> Result<Option<String>, Failure> {
    let (succeeded, stdout) = run_tool(
        "/bin/ps",
        &[
            "-p",
            &pid.to_string(),
            "-o",
            "lstart=",
            "-o",
            "uid=",
            "-o",
            "pgid=",
        ],
    )?;
    let identity = py_strip(&stdout);
    Ok((succeeded && !identity.is_empty()).then(|| identity.to_string()))
}

/// Binds an exact native session to this app launch. `Ok(false)` means the
/// event does not belong to the launch and nothing was written.
///
/// With `process_only` the launcher records the process it is about to
/// become, before any native session exists. `expected_binding` is the
/// binding a startup watcher started from: it is replaced only while it is
/// still exactly that.
pub fn record_session_binding(
    payload: &Dict,
    process_only: bool,
    expected_binding: Option<&Dict>,
) -> Result<bool, Failure> {
    let destination = env_or("RELAY_SESSION_BINDING_PATH", "");
    let context_id = env_or("RELAY_CONTEXT_ID", "");
    let transport_id = env_or("RELAY_PROVIDER_SESSION_ID", "");
    let expected_cwd = env_or("RELAY_CONTEXT_WORKING_DIRECTORY", "");
    let provider = env_or("RELAY_RUNNER_PROVIDER", "");
    if destination.is_empty()
        || context_id.is_empty()
        || expected_cwd.is_empty()
        || !matches!(provider.as_str(), "codex" | "claude")
    {
        return Ok(false);
    }
    let native_id = ["session_id", "sessionId"]
        .into_iter()
        .map(|key| payload.text(key))
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    if (!process_only && parse_uuid(&native_id).is_none()) || parse_uuid(&transport_id).is_none() {
        return Ok(false);
    }
    let path = Path::new(&destination);
    let in_bindings = path
        .parent()
        .and_then(Path::file_name)
        .is_some_and(|name| name == "bindings");
    let file_name = format!("{transport_id}.json");
    if !in_bindings
        || path
            .file_name()
            .is_none_or(|name| name != file_name.as_str())
    {
        return Ok(false);
    }
    let directory = path.parent().unwrap_or(Path::new(""));
    let actual_cwd = match payload.truthy("cwd") {
        Some(cwd) => cwd.py_str(),
        None => std::env::current_dir()?.to_string_lossy().into_owned(),
    };
    let working_directory = resolve(&expected_cwd);
    if resolve(&actual_cwd) != working_directory {
        return Ok(false);
    }

    let mut binding = Dict::new();
    binding.insert("schema_version", 1);
    binding.insert("context_id", context_id);
    binding.insert("provider", provider);
    binding.insert("provider_session_id", transport_id.clone());
    binding.insert("native_session_id", (!process_only).then_some(native_id));
    binding.insert(
        "working_directory",
        working_directory.to_string_lossy().into_owned(),
    );
    binding.insert(
        "transcript_path",
        Some(payload.string("transcript_path")).filter(|transcript| !transcript.is_empty()),
    );
    let raw_pid = env_or("RELAY_PROVIDER_PROCESS_ID", "");
    let pid = Some(&raw_pid)
        .filter(|raw| !raw.is_empty() && raw.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|raw| raw.parse::<i64>().ok())
        .filter(|pid| *pid > 1);
    if let Some(pid) = pid
        && (!process_only || pid == i64::from(std::os::unix::process::parent_id()))
        && let Some(identity) = process_identity(pid)?
    {
        binding.insert("provider_pid", pid);
        binding.insert("provider_process_identity", identity);
    }
    if process_only && binding.get("provider_pid").is_none() {
        return Err(Failure("ValueError"));
    }
    if let Some(expected) = expected_binding
        && !py_eq_optional(
            binding.get("provider_process_identity"),
            expected.get("provider_process_identity"),
        )
    {
        return Ok(false);
    }

    if let Some(parents) = directory
        .parent()
        .filter(|parents| !parents.as_os_str().is_empty())
    {
        fs::create_dir_all(parents)?;
    }
    match DirBuilder::new().mode(0o700).create(directory) {
        Err(error) if !directory.is_dir() => return Err(error.into()),
        _ => {}
    }
    let lock_path = directory.join(format!("{transport_id}.lock"));
    let temporary = directory.join(format!("{transport_id}.{}.tmp", std::process::id()));
    let guard = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&lock_path)?;
    fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o600))?;
    guard.lock()?;
    if let Some(expected) = expected_binding
        && !py_eq(
            &Value::Dict(read_json_file(&destination)),
            &Value::Dict(expected.clone()),
        )
    {
        return Ok(false);
    }
    let written = (|| {
        fs::write(&temporary, json::dumps_sorted(&Value::Dict(binding)))?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temporary, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written?;
    Ok(true)
}

/// One open file of the provider process, from `lsof -F`: its descriptor
/// (`cwd`, `txt` or a number) and its name.
struct OpenFile {
    descriptor: String,
    name: Option<String>,
}

fn open_files(lsof_output: &str) -> Vec<OpenFile> {
    let mut files: Vec<OpenFile> = Vec::new();
    for line in lsof_output.lines() {
        if let Some(descriptor) = line.strip_prefix('f') {
            files.push(OpenFile {
                descriptor: descriptor.to_string(),
                name: None,
            });
        } else if let (Some(name), Some(file)) = (line.strip_prefix('n'), files.last_mut()) {
            file.name = Some(name.to_string());
        }
    }
    files
}

fn value_matches_environment(value: Option<&Value>, variable: &str) -> bool {
    match (value, env_optional(variable)) {
        (None | Some(Value::Null), None) => true,
        (Some(value), Some(expected)) => value.is_str(&expected),
        _ => false,
    }
}

/// Whether another process holds an exclusive lock on `lock`. The file is
/// only tested, never created, and a lock taken by the test is released.
fn exclusively_locked(lock: &Path) -> Result<bool, Failure> {
    let handle = File::open(lock)?;
    match handle.try_lock() {
        Ok(()) => {
            handle.unlock()?;
            Ok(false)
        }
        Err(TryLockError::WouldBlock) => Ok(true),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

/// Observes only this launch's native writer; never searches sessions by
/// working directory.
///
/// Codex can hold an empty native thread before running any lifecycle hook or
/// creating a transcript. Its exclusive writer lock supplies the real UUID;
/// the first real prompt hook later supplies the transcript path.
pub fn record_codex_startup_binding() -> Result<bool, Failure> {
    if env_optional("RELAY_RUNNER_PROVIDER").as_deref() != Some("codex") {
        return Ok(false);
    }
    let binding_path = env_or("RELAY_SESSION_BINDING_PATH", "");
    let binary = env_or("RELAY_PROVIDER_BINARY", "");
    if binary.is_empty() || !Path::new(&binary).is_absolute() {
        return Ok(false);
    }
    let expected = read_json_file(&binding_path);
    let pid = match expected.get("provider_pid") {
        Some(Value::Int(pid)) if *pid > 1 => *pid,
        _ => return Ok(false),
    };
    let Some(identity) = expected
        .truthy("provider_process_identity")
        .and_then(Value::as_str)
    else {
        return Ok(false);
    };
    if env_optional("RELAY_PROVIDER_PROCESS_ID") != Some(pid.to_string()) {
        return Ok(false);
    }
    let Some(working_directory) = expected.truthy("working_directory").and_then(Value::as_str)
    else {
        return Ok(false);
    };
    let working_directory = resolve(working_directory);
    if !expected
        .get("provider")
        .is_some_and(|provider| provider.is_str("codex"))
        || !value_matches_environment(
            expected.get("provider_session_id"),
            "RELAY_PROVIDER_SESSION_ID",
        )
        || !value_matches_environment(expected.get("context_id"), "RELAY_CONTEXT_ID")
        || working_directory != resolve(&env_or("RELAY_CONTEXT_WORKING_DIRECTORY", ""))
    {
        return Ok(false);
    }
    let native_root = match env_optional("CODEX_HOME").filter(|home| !home.is_empty()) {
        Some(home) => resolve(&home),
        None => resolve(&format!("{}/.codex", env_or("HOME", ""))),
    };
    let locks_directory = native_root.join("thread-writer-locks");
    let binary = resolve(&binary);
    let current_identity = || process_identity(pid).map(Option::unwrap_or_default);
    let enriched = |binding: &Dict| binding.truthy("native_session_id").is_some();

    let deadline = Instant::now() + STARTUP_WAIT;
    loop {
        if current_identity()? != identity {
            return Ok(false);
        }
        let current = read_json_file(&binding_path);
        let replaced = expected
            .iter()
            .filter(|(key, _)| !matches!(*key, "native_session_id" | "transcript_path"))
            .any(|(key, value)| !py_eq_optional(current.get(key), Some(value)));
        if replaced {
            return Ok(false);
        }
        if enriched(&current) {
            // A native lifecycle hook already supplied richer state.
            return Ok(true);
        }
        let (listed, output) = run_tool(
            "/usr/sbin/lsof",
            &["-n", "-P", "-a", "-p", &pid.to_string(), "-Fftln"],
        )?;
        let files = open_files(&output);
        let resolved_name = |file: &OpenFile| resolve(file.name.as_deref().unwrap_or_default());
        // macOS lsof supplies descriptor paths but omits file and lock types.
        // Test the one exact owned file instead; never acquire or create its
        // lock.
        let mut locks: Vec<PathBuf> = files
            .iter()
            .filter(|file| {
                !file.descriptor.is_empty()
                    && file.descriptor.bytes().all(|byte| byte.is_ascii_digit())
            })
            .filter_map(|file| file.name.as_deref())
            .filter(|name| {
                Path::new(name)
                    .parent()
                    .is_some_and(|parent| resolve(&parent.to_string_lossy()) == locks_directory)
            })
            .map(resolve)
            .collect();
        locks.sort();
        locks.dedup();
        let has = |descriptor: &str, target: &Path| {
            files
                .iter()
                .any(|file| file.descriptor == descriptor && resolved_name(file) == target)
        };
        if listed
            && let [lock] = locks.as_slice()
            && has("cwd", &working_directory)
            && has("txt", &binary)
        {
            let named_lock = lock
                .extension()
                .is_some_and(|extension| extension == "lock");
            let native_id = match lock.file_stem().filter(|_| named_lock) {
                Some(stem) => match canonical_uuid(&stem.to_string_lossy()) {
                    Some(native_id) => native_id,
                    None => return Ok(false),
                },
                None => String::new(),
            };
            let held = !native_id.is_empty() && lock.is_file() && exclusively_locked(lock)?;
            if held && current_identity()? == identity {
                // Recheck the sidecar immediately before publication. Never
                // replace an already-enriched native hook binding.
                let latest = read_json_file(&binding_path);
                if enriched(&latest) {
                    return Ok(true);
                }
                if !py_eq(&Value::Dict(latest), &Value::Dict(expected.clone())) {
                    return Ok(false);
                }
                let mut payload = Dict::new();
                payload.insert("session_id", native_id);
                payload.insert("cwd", expected.get("working_directory").cloned());
                return record_session_binding(&payload, false, Some(&expected));
            }
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(STARTUP_POLL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_forms_python_accepts() {
        let canonical = "0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d";
        for text in [
            canonical,
            "0F3A1C52-7D4E-4B8A-9C11-5E6F7A8B9C0D",
            "0f3a1c527d4e4b8a9c115e6f7a8b9c0d",
            "{0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d}",
            "urn:uuid:0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d",
        ] {
            assert_eq!(canonical_uuid(text).as_deref(), Some(canonical), "{text}");
        }
        for text in [
            "",
            "unknown",
            "session-1",
            "startup-session",
            "0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0",
            "0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0dd",
            "zf3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d",
            "not-a-session",
        ] {
            assert_eq!(parse_uuid(text), None, "{text}");
        }
    }

    #[test]
    fn resolve_follows_links_and_keeps_missing_parts() {
        let root = std::env::temp_dir().join(format!("relay-rs-resolve-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("real/inner")).unwrap();
        std::os::unix::fs::symlink(root.join("real"), root.join("link")).unwrap();
        let real = fs::canonicalize(root.join("real")).unwrap();
        let text = |path: PathBuf| path.to_string_lossy().into_owned();
        assert_eq!(resolve(&text(root.join("link"))), real);
        assert_eq!(resolve(&text(root.join("link/inner/"))), real.join("inner"));
        assert_eq!(
            resolve(&text(root.join("link/missing/file.json"))),
            real.join("missing/file.json")
        );
        assert_eq!(
            resolve(&text(root.join("link/missing/../inner"))),
            real.join("inner")
        );
        assert_eq!(
            resolve(""),
            fs::canonicalize(std::env::current_dir().unwrap()).unwrap()
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn lsof_fields_group_into_open_files() {
        let files = open_files(
            "p4242\nfcwd\na \ntDIR\nn/work/project\nftxt\nn/usr/bin/codex\nf12\nau\nl \ntREG\nn/home/locks/a.lock\nf13\n",
        );
        let listed: Vec<(&str, Option<&str>)> = files
            .iter()
            .map(|file| (file.descriptor.as_str(), file.name.as_deref()))
            .collect();
        assert_eq!(
            listed,
            [
                ("cwd", Some("/work/project")),
                ("txt", Some("/usr/bin/codex")),
                ("12", Some("/home/locks/a.lock")),
                ("13", None),
            ]
        );
    }
}
