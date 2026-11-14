//! Shared by the integration tests: temporary roots, git repositories, the
//! repository's goldens and services, and a Python that can import them.
//!
//! Each test file declares `mod common;` and uses what it needs.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

/// The repository root (this crate is `rust/relay-services`).
pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repository root")
}

pub fn services() -> PathBuf {
    repo_root().join("services")
}

/// `tests/contract/golden/orchestrator/<name>`.
pub fn golden(name: &str) -> PathBuf {
    repo_root()
        .join("tests/contract/golden/orchestrator")
        .join(name)
}

/// A directory removed on drop. Its `orchestrator/` child is a data root
/// whose parent is the state root, as installed.
pub struct TempRoot {
    pub path: PathBuf,
}

impl TempRoot {
    pub fn new(label: &str) -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "relay-services-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("orchestrator")).expect("temporary root");
        Self {
            path: path.canonicalize().expect("canonical temporary root"),
        }
    }

    /// The state root (`~/Library/Application Support/relay-runner`).
    pub fn state_root(&self) -> PathBuf {
        self.path.clone()
    }

    /// The daemon's data root, `<state root>/orchestrator`.
    pub fn data_root(&self) -> PathBuf {
        self.path.join("orchestrator")
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// The identity the contract suite commits with (`GIT_IDENTITY` in
/// `tests/contract/orchestrator_contract_support.py`), isolated from the
/// user's git configuration.
pub const GIT_IDENTITY: [(&str, &str); 6] = [
    ("GIT_AUTHOR_NAME", "Contract Suite"),
    ("GIT_AUTHOR_EMAIL", "suite@contract.invalid"),
    ("GIT_COMMITTER_NAME", "Contract Suite"),
    ("GIT_COMMITTER_EMAIL", "suite@contract.invalid"),
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    ("GIT_CONFIG_NOSYSTEM", "1"),
];

/// Runs git in `repo`; panics on failure; returns trimmed stdout.
pub fn git(repo: &Path, arguments: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .envs(GIT_IDENTITY)
        .stdin(Stdio::null())
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// A git repository on `main` with one commit holding `README.md`.
pub fn make_repo(path: &Path) -> PathBuf {
    fs::create_dir_all(path).unwrap();
    git(path, &["init", "--initial-branch=main", "--quiet"]);
    fs::write(path.join("README.md"), "# Contract project\n").unwrap();
    git(path, &["add", "README.md"]);
    git(
        path,
        &[
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "-m",
            "chore: initial project",
        ],
    );
    path.canonicalize().unwrap()
}

/// A Python 3.10 or newer that can import `services/`, or `None` (with the
/// reason on stderr). `RELAY_SERVICES_PYTHON` names one; otherwise
/// Homebrew's, then `python3` on `PATH`.
pub fn python() -> Option<PathBuf> {
    let candidates: Vec<PathBuf> = match std::env::var_os("RELAY_SERVICES_PYTHON") {
        Some(configured) => vec![PathBuf::from(configured)],
        None => vec![
            PathBuf::from("/opt/homebrew/bin/python3"),
            PathBuf::from("python3"),
        ],
    };
    for candidate in candidates {
        let probe = Command::new(&candidate)
            .env("PYTHONDONTWRITEBYTECODE", "1")
            .arg("-c")
            .arg(
                "import sys; sys.path.insert(0, sys.argv[1]); \
                 assert sys.version_info >= (3, 10); import orchestrator",
            )
            .arg(services())
            .output();
        if probe.is_ok_and(|output| output.status.success()) {
            return Some(candidate);
        }
    }
    eprintln!("skipping: no Python 3.10+ that imports services/ (set RELAY_SERVICES_PYTHON)");
    None
}

/// Runs `script` with `services/` first on `sys.path`, `arguments` as
/// `sys.argv[1:]`, `HOME` at `home` and the git identity above. Panics with
/// stderr when it fails; returns stdout.
pub fn run_python(python: &Path, home: &Path, script: &str, arguments: &[&str]) -> String {
    let prelude = "import sys; sys.path.insert(0, sys.argv.pop(1))\n";
    let output = Command::new(python)
        .arg("-c")
        .arg(format!("{prelude}{script}"))
        .arg(services())
        .args(arguments)
        .env("HOME", home)
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .envs(GIT_IDENTITY)
        .stdin(Stdio::null())
        .output()
        .expect("run python");
    assert!(
        output.status.success(),
        "python failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("utf-8 output")
}
