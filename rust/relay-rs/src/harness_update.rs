//! `relay-rs harness-update`: `services/harness_update.py`. Update the
//! selected coding harness before Relay launches a new session.
//!
//! One update per provider at a time (an `flock` on
//! `harnesses/<provider>.lock`). Homebrew and npm installs update through
//! their package manager, Claude Code through `claude update`, and Codex
//! through the official installer into Relay's managed bin directory, which
//! never replaces a newer bundled desktop harness with an older release.
//! Prints `{"binary": ...}`, or `{"error": ...}` with exit 1.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{self, Dict, Value};

use crate::cli::{Opt, Spec, os_error_text};

const CODEX_INSTALLER: &str = "https://chatgpt.com/codex/install.sh";
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(180);
const VERSION_TIMEOUT: Duration = Duration::from_secs(15);

const SPEC: Spec = Spec {
    prog: "relay-rs harness-update",
    usage: "relay-rs harness-update [-h] --provider {codex,claude} --command COMMAND",
    help: "\nUpdate the selected coding harness before Relay launches a new session.\n\n\
           options:\n  -h, --help            show this help message and exit\n  \
           --provider {codex,claude}\n  --command COMMAND",
    options: &[
        Opt::choice("--provider", &["codex", "claude"]).required(),
        Opt::value("--command").required(),
    ],
    positionals: &[],
    exclusive: &[],
};

/// `HarnessUpdateError`, or an `OSError` as `str()` shows it.
#[derive(Debug, PartialEq, Eq)]
struct UpdateError(String);

impl From<io::Error> for UpdateError {
    fn from(error: io::Error) -> Self {
        UpdateError(os_error_text(&error, None))
    }
}

type Outcome<T> = Result<T, UpdateError>;

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// `run`: bound downloads and kill the whole updater tree on timeout. The
/// child gets its own session, no stdin and one pipe for stdout and stderr.
fn run(
    arguments: &[String],
    environment: Option<&[(String, String)]>,
    timeout: Duration,
) -> Outcome<String> {
    let (mut reader, writer) = io::pipe()?;
    let mut command = Command::new(&arguments[0]);
    command
        .args(&arguments[1..])
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer);
    if let Some(environment) = environment {
        command.env_clear().envs(environment.iter().cloned());
    }
    // SAFETY: setsid is async-signal-safe and touches no Rust state.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let spawned = command.spawn();
    // The parent's copies of the write end must close, or the read never ends.
    drop(command);
    let mut child = spawned?;
    let collector = thread::spawn(move || {
        let mut output = Vec::new();
        let _ = reader.read_to_end(&mut output);
        output
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            // SAFETY: plain signal delivery to the process group the child leads.
            unsafe {
                libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
            }
            let _ = child.wait();
            let _ = collector.join();
            return Err(UpdateError(
                "The harness update timed out. Check your connection and start the session again."
                    .to_string(),
            ));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let output = collector.join().unwrap_or_default();
    if !status.success() {
        // Installer output can contain shell configuration or credentials.
        let code = status.code().unwrap_or_else(|| {
            use std::os::unix::process::ExitStatusExt;
            -status.signal().unwrap_or(0)
        });
        return Err(UpdateError(format!(
            "The harness updater exited with status {code}. \
             Check your connection and installation permissions, then start the session again."
        )));
    }
    Ok(String::from_utf8_lossy(&output).trim().to_string())
}

/// `version`'s `\b(\d+)\.(\d+)\.(\d+)([^\s]*)`, as (major, minor, patch,
/// stable): a stable build sorts after a prerelease of the same version.
fn parse_version(output: &str) -> Option<(u128, u128, u128, bool)> {
    let characters: Vec<char> = output.chars().collect();
    let is_word = |character: char| character.is_alphanumeric() || character == '_';
    let digits = |start: usize| {
        let mut end = start;
        while end < characters.len() && characters[end].is_ascii_digit() {
            end += 1;
        }
        end
    };
    let number = |start: usize, end: usize| -> Option<u128> {
        characters[start..end]
            .iter()
            .collect::<String>()
            .parse()
            .ok()
    };
    for start in 0..characters.len() {
        if !characters[start].is_ascii_digit() || (start > 0 && is_word(characters[start - 1])) {
            continue;
        }
        let first = digits(start);
        if characters.get(first) != Some(&'.') {
            continue;
        }
        let second = digits(first + 1);
        if second == first + 1 || characters.get(second) != Some(&'.') {
            continue;
        }
        let third = digits(second + 1);
        if third == second + 1 {
            continue;
        }
        let stable = characters
            .get(third)
            .is_none_or(|character| character.is_whitespace());
        return Some((
            number(start, first)?,
            number(first + 1, second)?,
            number(second + 1, third)?,
            stable,
        ));
    }
    None
}

fn version(binary: &str) -> Outcome<(u128, u128, u128, bool)> {
    let output = run(
        &[binary.to_string(), "--version".to_string()],
        None,
        VERSION_TIMEOUT,
    )?;
    parse_version(&output).ok_or_else(|| {
        UpdateError("The updated harness did not report a valid version.".to_string())
    })
}

fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

/// `shutil.which(command)`.
fn which(command: &str) -> Option<String> {
    if command.contains('/') {
        return is_executable_file(Path::new(command)).then(|| command.to_string());
    }
    let path = std::env::var("PATH").unwrap_or_else(|_| "/bin:/usr/bin".to_string());
    path.split(':')
        .map(|directory| Path::new(directory).join(command))
        .find(|candidate| is_executable_file(candidate))
        .map(|candidate| path_text(&candidate))
}

/// `str(Path(binary).resolve())`.
fn resolved(binary: &str) -> String {
    relay_artifacts::paths::resolve(binary)
}

/// `package_manager`: (kind, executable, option, package) for a Homebrew or
/// npm install of the harness.
fn package_manager(binary: &str, provider: &str) -> Option<(&'static str, String, String, String)> {
    let resolved = resolved(binary);
    for (directory, kind) in [("Caskroom", "--cask"), ("Cellar", "--formula")] {
        let marker = format!("/{directory}/");
        if let Some((prefix, package_path)) = resolved.split_once(&marker) {
            let package = package_path.split('/').next().unwrap_or_default();
            let allowed: &[&str] = if provider == "codex" {
                &["codex"]
            } else {
                &["claude-code", "claude-code@latest"]
            };
            if allowed.contains(&package) {
                return Some((
                    "brew",
                    path_text(&Path::new(prefix).join("bin/brew")),
                    kind.to_string(),
                    package.to_string(),
                ));
            }
        }
    }
    let package = if provider == "codex" {
        "@openai/codex"
    } else {
        "@anthropic-ai/claude-code"
    };
    let marker = format!("/lib/node_modules/{package}/");
    let (prefix, _) = resolved.split_once(&marker)?;
    let local = Path::new(prefix).join("bin/npm");
    let npm = if local.is_file() {
        Some(path_text(&local))
    } else {
        which("npm")
    }?;
    Some(("npm", npm, prefix.to_string(), package.to_string()))
}

/// `dict(os.environ, **overrides)`.
fn environment_with(overrides: &[(&str, String)]) -> Vec<(String, String)> {
    let mut environment: Vec<(String, String)> = std::env::vars()
        .filter(|(name, _)| !overrides.iter().any(|(key, _)| key == name))
        .collect();
    environment.extend(
        overrides
            .iter()
            .map(|(name, value)| (name.to_string(), value.clone())),
    );
    environment
}

fn current_path() -> String {
    std::env::var("PATH").unwrap_or_default()
}

/// `tempfile.TemporaryDirectory(prefix=...)`, removed when dropped.
struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(prefix: &str) -> Outcome<Self> {
        use std::os::unix::fs::DirBuilderExt;
        let base = std::env::var_os("TMPDIR").map_or_else(std::env::temp_dir, PathBuf::from);
        let path = base.join(format!(
            "{prefix}{}",
            &relay_artifacts::store::random_hex()[..8]
        ));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn update_harness(provider: &str, command: &str, root: &Path) -> Outcome<String> {
    fs::create_dir_all(root).map_err(|error| UpdateError(os_error_text(&error, Some(root))))?;
    let lock_path = root.join(format!("{provider}.lock"));
    let lock: File = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&lock_path)
        .map_err(|error| UpdateError(os_error_text(&error, Some(&lock_path))))?;
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            return Err(UpdateError(
                "A harness update is already running. Wait for it to finish, then start the session again."
                    .to_string(),
            ));
        }
        return Err(error.into());
    }
    let mut binary = which(command);
    let manager = binary
        .as_deref()
        .and_then(|binary| package_manager(binary, provider));
    if let Some((kind, executable, option, package)) = manager {
        if kind == "brew" {
            let environment = environment_with(&[
                ("NONINTERACTIVE", "1".to_string()),
                ("HOMEBREW_NO_INSTALL_CLEANUP", "1".to_string()),
            ]);
            run(
                &[executable.clone(), "update".to_string()],
                Some(&environment),
                DEFAULT_TIMEOUT,
            )?;
            run(
                &[executable.clone(), "upgrade".to_string(), option, package],
                Some(&environment),
                DEFAULT_TIMEOUT,
            )?;
            let parent = Path::new(&executable).parent().unwrap_or(Path::new(""));
            binary = Some(path_text(&parent.join(provider)));
        } else {
            let environment = environment_with(&[
                ("NONINTERACTIVE", "1".to_string()),
                ("HOMEBREW_NO_INSTALL_CLEANUP", "1".to_string()),
                ("PATH", format!("{option}/bin:{}", current_path())),
            ]);
            run(
                &[
                    executable,
                    "install".to_string(),
                    "--global".to_string(),
                    "--prefix".to_string(),
                    option,
                    format!("{package}@latest"),
                ],
                Some(&environment),
                DEFAULT_TIMEOUT,
            )?;
        }
    } else if provider == "claude" {
        let Some(binary) = &binary else {
            return Err(UpdateError(
                "Claude Code is not installed. Run setup before starting a session.".to_string(),
            ));
        };
        if std::env::var("DISABLE_UPDATES").as_deref() == Ok("1") {
            return Err(UpdateError(
                "Claude Code updates are disabled by DISABLE_UPDATES. Enable updates before starting a session."
                    .to_string(),
            ));
        }
        run(
            &[binary.clone(), "update".to_string()],
            None,
            DEFAULT_TIMEOUT,
        )?;
    } else {
        let bundled = binary
            .as_deref()
            .is_some_and(|binary| binary.contains(".app/Contents/"));
        let standalone = binary
            .as_deref()
            .is_some_and(|binary| resolved(binary).contains("/packages/standalone/"));
        let managed_bin = root.join("codex/bin");
        if let Some(binary) = &binary {
            let parent = relay_artifacts::paths::normalize(
                &Path::new(binary)
                    .parent()
                    .map(path_text)
                    .unwrap_or_default(),
            );
            if !bundled
                && !standalone
                && parent != relay_artifacts::paths::normalize(&path_text(&managed_bin))
            {
                return Err(UpdateError(
                    "This custom Codex executable has no supported automatic updater. \
                     Choose the default Codex command in Settings to use automatic updates."
                        .to_string(),
                ));
            }
        }
        let previous_version = match (&binary, bundled) {
            (Some(binary), true) => Some(version(binary)?),
            _ => None,
        };
        fs::create_dir_all(&managed_bin)?;
        // Keep the official installer from discovering another package
        // manager on PATH and rewriting the user's shell profile.
        let managed_codex = managed_bin.join("codex");
        if let Some(binary) = binary.as_deref().filter(|_| bundled)
            && fs::symlink_metadata(&managed_codex).is_err()
        {
            std::os::unix::fs::symlink(binary, &managed_codex)?;
        }
        let environment = environment_with(&[
            ("CODEX_INSTALL_DIR", path_text(&managed_bin)),
            ("CODEX_NON_INTERACTIVE", "true".to_string()),
            ("CODEX_RELEASE", "latest".to_string()),
            ("CODEX_INSTALL_DAEMON_ONLY", "0".to_string()),
            ("CODEX_INSTALL_DEFER_SELECTION", "0".to_string()),
            (
                "PATH",
                format!("{}:{}", path_text(&managed_bin), current_path()),
            ),
        ]);
        {
            let temporary = TemporaryDirectory::new("relay-codex-update-")?;
            let installer = path_text(&temporary.0.join("install.sh"));
            let curl: Vec<String> = [
                "/usr/bin/curl",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--connect-timeout",
                "10",
                "--max-time",
                "30",
                CODEX_INSTALLER,
                "--output",
                &installer,
            ]
            .iter()
            .map(|value| value.to_string())
            .collect();
            run(&curl, None, DEFAULT_TIMEOUT)?;
            run(
                &["/bin/sh".to_string(), installer],
                Some(&environment),
                DEFAULT_TIMEOUT,
            )?;
        }
        let updated_binary = path_text(&managed_codex);
        let updated_version = version(&updated_binary)?;
        // Desktop builds can lead the public standalone release. Never
        // replace a newer bundled harness with an older stable CLI.
        if previous_version.is_none_or(|previous| updated_version >= previous) {
            binary = Some(updated_binary);
        }
    }
    let binary = binary.unwrap_or_default();
    version(&binary)?;
    drop(lock);
    Ok(binary)
}

fn answer(outcome: Outcome<String>) -> (String, u8) {
    let mut document = Dict::new();
    let status = match outcome {
        Ok(binary) => {
            document.insert("binary", binary);
            0
        }
        Err(UpdateError(message)) => {
            document.insert("error", message);
            1
        }
    };
    (json::dumps(&Value::Dict(document)), status)
}

pub fn run_cli(arguments: &[String]) -> u8 {
    let parsed = match SPEC.parse(arguments) {
        Ok(parsed) => parsed,
        Err(exit) => return exit.report(),
    };
    let home = std::env::var("HOME").unwrap_or_default();
    let root = Path::new(&home).join("Library/Application Support/relay-runner/harnesses");
    let outcome = update_harness(
        parsed.value("--provider").unwrap_or_default(),
        parsed.value("--command").unwrap_or_default(),
        &root,
    );
    let (text, status) = answer(outcome);
    println!("{text}");
    status
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn versions_compare_with_stable_after_prerelease() {
        assert_eq!(parse_version("codex-cli 0.46.0"), Some((0, 46, 0, true)));
        assert_eq!(
            parse_version("2.1.3-beta.1 (Claude Code)"),
            Some((2, 1, 3, false))
        );
        assert_eq!(parse_version("v1.2.3"), None);
        assert_eq!(parse_version("version 1.2"), None);
        assert!(parse_version("1.2.3").unwrap() > parse_version("1.2.3-rc1").unwrap());
        assert!(parse_version("1.10.0").unwrap() > parse_version("1.9.9").unwrap());
    }

    #[test]
    fn package_managers_are_recognized_by_resolved_path() {
        assert_eq!(
            package_manager("/opt/homebrew/Caskroom/codex/0.46.0/codex", "codex"),
            Some((
                "brew",
                "/opt/homebrew/bin/brew".to_string(),
                "--cask".to_string(),
                "codex".to_string()
            ))
        );
        assert_eq!(
            package_manager("/opt/homebrew/Cellar/claude-code/2.0/bin/claude", "claude"),
            Some((
                "brew",
                "/opt/homebrew/bin/brew".to_string(),
                "--formula".to_string(),
                "claude-code".to_string()
            ))
        );
        assert_eq!(
            package_manager("/opt/homebrew/Cellar/other/1/bin/claude", "claude"),
            None
        );
        assert_eq!(
            package_manager("/usr/local/bin/codex-custom", "codex"),
            None
        );
    }

    #[test]
    fn run_merges_output_and_reports_status_without_it() {
        let shell = |script: &str| arguments(&["/bin/sh", "-c", script]);
        assert_eq!(
            run(&shell("echo out; echo err >&2"), None, DEFAULT_TIMEOUT).unwrap(),
            "out\nerr"
        );
        let failed = run(&shell("echo secret; exit 3"), None, DEFAULT_TIMEOUT).unwrap_err();
        assert!(
            failed
                .0
                .starts_with("The harness updater exited with status 3.")
        );
        assert!(!failed.0.contains("secret"));
        let timed_out = run(
            &shell("sleep 5 & sleep 5"),
            None,
            Duration::from_millis(200),
        )
        .unwrap_err();
        assert!(timed_out.0.contains("timed out"));
    }

    #[test]
    fn a_held_lock_refuses_a_second_update() {
        let root = std::env::temp_dir().join(format!(
            "relay-harness-update-test-{}",
            relay_artifacts::store::random_hex()
        ));
        fs::create_dir_all(&root).unwrap();
        let held = File::create(root.join("claude.lock")).unwrap();
        // SAFETY: flock on a descriptor this test owns.
        assert_eq!(
            unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        assert_eq!(
            update_harness("claude", "claude", &root),
            Err(UpdateError(
                "A harness update is already running. Wait for it to finish, then start the session again."
                    .to_string()
            ))
        );
        drop(held);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn answers_are_python_json() {
        assert_eq!(
            answer(Ok("/bin/codex".to_string())),
            (r#"{"binary": "/bin/codex"}"#.to_string(), 0)
        );
        assert_eq!(
            answer(Err(UpdateError("no".to_string()))),
            (r#"{"error": "no"}"#.to_string(), 1)
        );
        assert!(
            SPEC.parse(&arguments(&["--provider", "gemini", "--command", "x"]))
                .is_err()
        );
    }
}
