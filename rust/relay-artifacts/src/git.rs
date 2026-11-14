//! Git plumbing as `ArtifactStore._git` runs it: `git -C <repo>`, the
//! caller's environment without repository overrides, a fixed Relay Runner
//! identity and the C locale, so both daemons write identical commits.

use std::ffi::OsString;
use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::{Error, ErrorKind, Result};

/// Variables that would point Git at another repository or index.
const SCRUBBED: [&str; 6] = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
];

/// `_git_environment(additions)`.
pub fn environment(additions: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    let mut environment: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(key, _)| !SCRUBBED.iter().any(|name| key == name))
        .collect();
    let mut set = |key: &str, value: &str| {
        environment.retain(|(existing, _)| existing != key);
        environment.push((key.into(), value.into()));
    };
    set("GIT_AUTHOR_NAME", "Relay Runner");
    set("GIT_AUTHOR_EMAIL", "relay-runner@localhost");
    set("GIT_COMMITTER_NAME", "Relay Runner");
    set("GIT_COMMITTER_EMAIL", "relay-runner@localhost");
    set("LC_ALL", "C");
    for (key, value) in additions {
        set(key, value);
    }
    environment
}

/// A finished Git command.
pub struct Output {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Output {
    /// `stdout.decode("utf-8", errors="replace")`.
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    /// The stripped text, as most callers read one value.
    pub fn line(&self) -> String {
        crate::pystr::strip(&self.text()).to_string()
    }
}

/// Runs `git -C <repo> <arguments>`. A status outside `allowed` is an
/// `ArtifactStoreError` naming the command and Git's message.
pub fn run(
    repo: &Path,
    arguments: &[&str],
    additions: &[(&str, &str)],
    input: Option<&[u8]>,
    allowed: &[i32],
) -> Result<Output> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .env_clear()
        .envs(environment(additions))
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Error::new(ErrorKind::Io, format!("git could not start: {error}")))?;
    let output = std::thread::scope(|scope| {
        if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
            // Written alongside the read: `cat-file --batch` answers while
            // its input is still arriving.
            scope.spawn(move || {
                let _ = stdin.write_all(bytes);
            });
        }
        child.wait_with_output()
    })?;
    let status = output
        .status
        .code()
        .unwrap_or_else(|| -output.status.signal().unwrap_or(0));
    let result = Output {
        status,
        stdout: output.stdout,
        stderr: output.stderr,
    };
    if !allowed.contains(&status) {
        return Err(Error::new(
            ErrorKind::Store,
            format!(
                "git {} failed ({status}): {}",
                arguments.join(" "),
                crate::pystr::strip(&String::from_utf8_lossy(&result.stderr))
            ),
        ));
    }
    Ok(result)
}
