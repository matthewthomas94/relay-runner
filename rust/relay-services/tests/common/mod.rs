//! Shared by the integration tests: temporary roots, git repositories and the
//! repository's goldens.
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
