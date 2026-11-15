//! The report-only leftover scanner (RR-506): `GET /v1/maintenance/leftovers`.
//!
//! It lists processes that a finished run left running, and the worktrees the
//! stale-worktree sweep would report, without stopping or removing anything.
//! The rules follow the RR-501 findings.
//!
//! A process is listed only with positive ownership by a finished run:
//!
//! - **Tier 1** (verified Relay leftover): it carries the `RELAY_RUN_ID` and
//!   `RELAY_WORKSPACE` tags (RR-505) of a finished run, or its executable or
//!   command line points into a finished run's workspace and it started while
//!   that run was running. It has no controlling terminal.
//! - **Tier 2** (path-only match): it points into a finished run's workspace
//!   but nothing else proves the run started it: it started outside every run
//!   of that workspace, or it has a controlling terminal, so it may be the
//!   user's.
//!
//! Never listed: another user's process; the daemon, its ancestors and what
//! runs under it; a live run's provider, its group and descendants; the
//! bridge of every orchestrator session that is not stopped, and the bridge
//! named by a `voice_bridge.pid` file, with their children; the Relay Runner
//! app bundle's processes (the active session's provider runs in its
//! terminal) with their descendants; anything pointing into a workspace or
//! ticket that still has an open run (a retry reuses the per-ticket
//! workspace); a run that ended less than the grace period ago; and a
//! process whose command line cannot be read, which is only counted.
//!
//! Workspace paths match only on a path boundary, so `…-rr-48` never claims
//! `…-rr-485/…`. Claude and Codex runs are treated alike: the decision reads
//! the ledger and the process table, never the provider.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use relay_intents::json::{Dict, Value};

use crate::daemon::Daemon;
use crate::failure::Outcome;
use crate::process_tree::{self, PROC_ALL_PIDS};
use crate::router::{Reply, reply};

/// The run states whose processes are leftovers once the run has ended.
/// Every other state (active, awaiting review, kept for verification or
/// integration, a merge conflict kept for retry) vetoes a match.
pub const FINISHED_STATES: [&str; 5] =
    ["Merged", "Failed", "Stalled", "Canceled", "SpikeCompleted"];
/// How long after a run ends its processes are left out, so a provider that
/// is still winding down is not reported.
pub const GRACE_SECONDS: f64 = 120.0;
/// Slack for comparing a process start time with a run's `started_at`, which
/// the ledger takes just before the provider spawns.
const START_SLACK_SECONDS: f64 = 5.0;
const LEDGER_LIMIT: i64 = 100_000;
const SESSION_LIMIT: i64 = 1_000;

/// What the scanner keeps of a readable command line. Of the environment it
/// keeps only the two run tags.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub exe: String,
    pub argv: Vec<String>,
    pub run_id: Option<String>,
    pub workspace: Option<String>,
}

/// One row of the process table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Process {
    pub pid: libc::pid_t,
    pub ppid: libc::pid_t,
    pub pgid: libc::pid_t,
    pub uid: libc::uid_t,
    /// Start time in microseconds, as the ledger's `pid_start_us`.
    pub start_us: i64,
    pub tty: bool,
    /// `None` when the command line cannot be read.
    pub args: Option<Args>,
}

/// What one scan protects and when it runs.
pub struct Scope {
    pub now: f64,
    pub uid: libc::uid_t,
    /// The daemon itself: never listed, nor its ancestors or descendants.
    pub own_pid: libc::pid_t,
    pub workspace_root: String,
    pub grace_seconds: f64,
    /// Run ids of workers and reviewers the daemon is running.
    pub live_runs: HashSet<i64>,
    /// Further roots never listed, with everything under them: the bridges
    /// of live orchestrator sessions.
    pub protected: Vec<libc::pid_t>,
    /// Processes whose executable lies under this folder are roots too: the
    /// app bundle the daemon ships in.
    pub protected_bundle: Option<String>,
}

/// A finished or open run, as the scanner reads it from the ledger.
#[derive(Clone, Debug)]
struct Run {
    id: i64,
    ticket: String,
    repo: String,
    workspace: String,
    state: String,
    started_at: f64,
    ended_at: Option<f64>,
    pid: Option<libc::pid_t>,
    pid_start_us: Option<i64>,
}

impl Run {
    fn read(row: &Dict) -> Self {
        Self {
            id: row.get("id").and_then(Value::py_int).unwrap_or_default(),
            ticket: row.string("ticket_id"),
            repo: row.string("repo_path"),
            workspace: row.string("workspace_path"),
            state: row.string("state"),
            started_at: row
                .get("started_at")
                .and_then(Value::py_float)
                .unwrap_or(0.0),
            ended_at: row.get("ended_at").and_then(Value::py_float),
            pid: row
                .get("pid")
                .and_then(Value::py_int)
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .filter(|pid| *pid > 1),
            pid_start_us: row.get("pid_start_us").and_then(Value::py_int),
        }
    }

    fn open(&self, live: &HashSet<i64>) -> bool {
        live.contains(&self.id)
            || self.ended_at.is_none()
            || !FINISHED_STATES.contains(&self.state.as_str())
    }

    /// The process started while this run was running.
    fn covers(&self, start: f64) -> bool {
        self.ended_at
            .is_some_and(|ended| start >= self.started_at - START_SLACK_SECONDS && start <= ended)
    }

    fn label(&self) -> String {
        format!("run {} ({}, {})", self.id, self.ticket, self.state)
    }
}

/// `path` lies strictly inside `root`.
fn inside(path: &str, root: &str) -> bool {
    let root = root.trim_end_matches('/');
    !root.is_empty() && path.len() > root.len() + 1 && path.starts_with(&format!("{root}/"))
}

/// A character that can continue a path component.
fn path_char(character: char) -> bool {
    character.is_alphanumeric() || matches!(character, '.' | '_' | '-' | '/' | '~' | '+')
}

/// `text` names `workspace` or something inside it: an occurrence that does
/// not continue a longer path on either side. `…/repo-rr-48` matches
/// `…/repo-rr-48/x` and `--dir=…/repo-rr-48`, never `…/repo-rr-485/x`.
pub fn names_workspace(text: &str, workspace: &str) -> bool {
    let workspace = workspace.trim_end_matches('/');
    if workspace.is_empty() {
        return false;
    }
    let mut from = 0;
    while let Some(offset) = text[from..].find(workspace) {
        let start = from + offset;
        let end = start + workspace.len();
        let before = text[..start].chars().next_back();
        let after = text[end..].chars().next();
        let starts = before.is_none_or(|c| !path_char(c));
        let ends = after.is_none_or(|c| c == '/' || !path_char(c));
        if starts && ends {
            return true;
        }
        from = start + workspace.chars().next().map_or(1, char::len_utf8);
    }
    false
}

fn names(args: &Args, workspace: &str) -> bool {
    names_workspace(&args.exe, workspace)
        || args.argv.iter().any(|arg| names_workspace(arg, workspace))
}

/// The pids never listed: the daemon with its ancestors, and every root with
/// what runs under it (descendants by parent pid, and members of a group it
/// leads).
fn protected(table: &[Process], runs: &[Run], scope: &Scope) -> HashSet<libc::pid_t> {
    let by_pid: HashMap<libc::pid_t, &Process> = table.iter().map(|p| (p.pid, p)).collect();
    let mut roots: HashSet<libc::pid_t> = scope.protected.iter().copied().collect();
    roots.insert(scope.own_pid);
    for run in runs.iter().filter(|run| run.open(&scope.live_runs)) {
        let Some(pid) = run.pid else { continue };
        // A recorded start time that differs means the pid is reused.
        let same = match (run.pid_start_us, by_pid.get(&pid)) {
            (Some(start), Some(live)) => live.start_us == start,
            _ => true,
        };
        if same {
            roots.insert(pid);
        }
    }
    if let Some(bundle) = scope.protected_bundle.as_deref() {
        for process in table {
            if process
                .args
                .as_ref()
                .is_some_and(|args| inside(&args.exe, bundle))
            {
                roots.insert(process.pid);
            }
        }
    }

    let mut kept = HashSet::new();
    // The daemon's ancestors (launchd's job, a supervising shell).
    let mut cursor = by_pid.get(&scope.own_pid).map(|own| own.ppid);
    while let Some(pid) = cursor.filter(|pid| *pid > 1 && !kept.contains(pid)) {
        kept.insert(pid);
        cursor = by_pid.get(&pid).map(|process| process.ppid);
    }
    for process in table {
        let mut pid = process.pid;
        let mut steps = 0;
        let under_root = loop {
            if roots.contains(&pid) {
                break true;
            }
            match by_pid.get(&pid) {
                Some(row) if row.ppid > 1 && steps < table.len() => {
                    if roots.contains(&row.pgid) {
                        break true;
                    }
                    pid = row.ppid;
                    steps += 1;
                }
                Some(row) => break roots.contains(&row.pgid),
                None => break false,
            }
        };
        if under_root {
            kept.insert(process.pid);
        }
    }
    kept
}

/// The scan's result: what it lists, and how many processes it could not
/// read.
#[derive(Debug, Default)]
pub struct Report {
    pub leftovers: Vec<Dict>,
    pub unreadable: usize,
}

/// Lists the leftover processes in `table`; `runs` is the whole ledger.
pub fn classify(table: &[Process], runs: &[Dict], scope: &Scope) -> Report {
    let runs: Vec<Run> = runs.iter().map(Run::read).collect();
    let kept = protected(table, &runs, scope);
    let by_id: HashMap<i64, &Run> = runs.iter().map(|run| (run.id, run)).collect();
    let busy_workspaces: HashSet<&str> = runs
        .iter()
        .filter(|run| run.open(&scope.live_runs))
        .map(|run| run.workspace.as_str())
        .collect();
    let busy_tickets: HashSet<(&str, &str)> = runs
        .iter()
        .filter(|run| run.open(&scope.live_runs))
        .map(|run| (run.repo.as_str(), run.ticket.as_str()))
        .collect();
    let busy = |run: &Run| {
        busy_workspaces.contains(run.workspace.as_str())
            || busy_tickets.contains(&(run.repo.as_str(), run.ticket.as_str()))
    };
    // Each workspace under the root, with its runs newest first.
    let mut workspaces: HashMap<&str, Vec<&Run>> = HashMap::new();
    for run in &runs {
        if inside(&run.workspace, &scope.workspace_root) {
            workspaces
                .entry(run.workspace.as_str())
                .or_default()
                .push(run);
        }
    }
    for list in workspaces.values_mut() {
        list.sort_by_key(|run| std::cmp::Reverse(run.id));
    }

    let mut report = Report::default();
    for process in table {
        if process.pid <= 1 || process.uid != scope.uid || kept.contains(&process.pid) {
            continue;
        }
        let Some(args) = process.args.as_ref() else {
            report.unreadable += 1;
            continue;
        };
        let start = process.start_us as f64 / 1_000_000.0;
        // The run tags, when they name a run of this ledger and its workspace.
        let tagged = args
            .run_id
            .as_deref()
            .and_then(|id| id.trim().parse::<i64>().ok())
            .and_then(|id| by_id.get(&id).copied())
            .filter(|run| args.workspace.as_deref() == Some(run.workspace.as_str()));
        // The workspace the command line points into; the longest wins, so a
        // nested path is never claimed by its parent.
        let pointed = workspaces
            .iter()
            .filter(|(workspace, _)| names(args, workspace))
            .max_by_key(|(workspace, _)| workspace.len())
            .map(|(_, runs)| runs.as_slice());

        let (owner, tier, evidence, reason) = if let Some(run) = tagged {
            if run.open(&scope.live_runs) || busy(run) {
                continue;
            }
            if pointed.is_some_and(|runs| runs.iter().any(|run| run.open(&scope.live_runs))) {
                continue;
            }
            if start < run.started_at - START_SLACK_SECONDS {
                (
                    run,
                    2,
                    "environment",
                    format!(
                        "its RELAY_RUN_ID and RELAY_WORKSPACE name {}, but it started before that run began",
                        run.label()
                    ),
                )
            } else if process.tty {
                (
                    run,
                    2,
                    "environment",
                    format!(
                        "its RELAY_RUN_ID and RELAY_WORKSPACE name {}, but it has a controlling terminal, so it may be the user's",
                        run.label()
                    ),
                )
            } else {
                (
                    run,
                    1,
                    "environment",
                    format!(
                        "its RELAY_RUN_ID and RELAY_WORKSPACE name {}, which has ended",
                        run.label()
                    ),
                )
            }
        } else if let Some(runs) = pointed {
            // Any open run of the workspace, or of its ticket, vetoes.
            if runs
                .iter()
                .any(|run| run.open(&scope.live_runs) || busy(run))
            {
                continue;
            }
            match runs.iter().find(|run| run.covers(start)) {
                Some(run) if !process.tty => (
                    *run,
                    1,
                    "path",
                    format!(
                        "its command line points into the workspace of {}, it started while that run was running, and it has no terminal",
                        run.label()
                    ),
                ),
                Some(run) => (
                    *run,
                    2,
                    "path",
                    format!(
                        "its command line points into the workspace of {}, but it has a controlling terminal, so it may be the user's",
                        run.label()
                    ),
                ),
                None => (
                    runs[0],
                    2,
                    "path",
                    format!(
                        "its command line points into the workspace of {}, but it started outside every run of that workspace, so it may be the user's",
                        runs[0].label()
                    ),
                ),
            }
        } else {
            continue;
        };
        let Some(ended_at) = owner.ended_at else {
            continue;
        };
        if scope.now - ended_at < scope.grace_seconds {
            continue;
        }
        let mut entry = Dict::new();
        entry.insert("kind", "process");
        entry.insert("tier", tier);
        entry.insert("reason", reason);
        entry.insert("evidence", evidence);
        entry.insert("pid", i64::from(process.pid));
        entry.insert("ppid", i64::from(process.ppid));
        entry.insert("pgid", i64::from(process.pgid));
        entry.insert("started_at", start);
        entry.insert("tty", process.tty);
        entry.insert(
            "command",
            Path::new(&args.exe)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
        );
        entry.insert("run_id", owner.id);
        entry.insert("ticket_id", owner.ticket.clone());
        entry.insert("run_state", owner.state.clone());
        entry.insert("repo_path", owner.repo.clone());
        entry.insert("workspace_path", owner.workspace.clone());
        entry.insert("run_ended_at", ended_at);
        report.leftovers.push(entry);
    }
    report.leftovers.sort_by_key(|entry| {
        (
            entry
                .get("tier")
                .and_then(Value::py_int)
                .unwrap_or_default(),
            entry.get("pid").and_then(Value::py_int).unwrap_or_default(),
        )
    });
    report
}

/// `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`: the executable, argv and the
/// two run tags of `pid`, or `None` when they cannot be read.
fn read_args(pid: libc::pid_t) -> Option<Args> {
    let mut argmax: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: sysctl writes at most `size` bytes into `argmax`.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || argmax <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; argmax as usize];
    let mut size = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: sysctl writes at most `size` bytes into the buffer.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    buffer.truncate(size);
    parse_procargs(&buffer)
}

/// The `KERN_PROCARGS2` layout: `argc`, the executable path, padding, then
/// `argc` arguments and the environment, each NUL-terminated.
pub fn parse_procargs(buffer: &[u8]) -> Option<Args> {
    let argc = i32::from_ne_bytes(buffer.get(..4)?.try_into().ok()?);
    let argc = usize::try_from(argc).ok()?;
    let mut rest = &buffer[4..];
    let mut next = |skip_padding: bool| -> Option<String> {
        if skip_padding {
            let start = rest.iter().position(|byte| *byte != 0)?;
            rest = &rest[start..];
        }
        let end = rest
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(rest.len());
        let text = String::from_utf8_lossy(&rest[..end]).into_owned();
        rest = rest.get(end + 1..).unwrap_or_default();
        Some(text)
    };
    let exe = next(false)?;
    let mut argv = Vec::with_capacity(argc);
    for index in 0..argc {
        argv.push(next(index == 0)?);
    }
    let mut args = Args {
        exe,
        argv,
        ..Args::default()
    };
    while let Some(variable) = next(false) {
        if variable.is_empty() {
            break;
        }
        if let Some(value) = variable.strip_prefix("RELAY_RUN_ID=") {
            args.run_id = Some(value.to_string());
        } else if let Some(value) = variable.strip_prefix("RELAY_WORKSPACE=") {
            args.workspace = Some(value.to_string());
        }
    }
    Some(args)
}

/// Every process this user can see, with its command line where readable.
pub fn snapshot() -> Vec<Process> {
    process_tree::list(PROC_ALL_PIDS, 0)
        .into_iter()
        .filter_map(|pid| {
            let info = process_tree::info(pid)?;
            Some(Process {
                pid,
                ppid: info.ppid,
                pgid: info.pgid,
                uid: info.identity.uid,
                start_us: process_tree::start_us(&info.identity),
                tty: info.tty,
                args: read_args(pid),
            })
        })
        .collect()
}

/// The pid a `voice_bridge.pid` file names.
fn pid_file(path: &Path) -> Option<libc::pid_t> {
    std::fs::read_to_string(path)
        .ok()?
        .trim()
        .parse::<libc::pid_t>()
        .ok()
        .filter(|pid| *pid > 1)
}

/// The bridges Relay Runner may be running: `/tmp/voice_bridge.pid` and
/// each session spool's.
fn bridge_pids() -> Vec<libc::pid_t> {
    let mut pids: Vec<libc::pid_t> = pid_file(Path::new("/tmp/voice_bridge.pid"))
        .into_iter()
        .collect();
    if let Ok(entries) = std::fs::read_dir("/tmp/relay-sessions") {
        for entry in entries.flatten() {
            pids.extend(pid_file(&entry.path().join("voice_bridge.pid")));
        }
    }
    pids
}

/// The `.app` bundle folder the daemon runs from, if any.
fn own_bundle() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let text = exe.to_string_lossy();
    let end = text.find(".app/Contents/")?;
    Some(text[..end + ".app".len()].to_string())
}

fn worktree_entry(run: &Value) -> Option<Dict> {
    let Value::Dict(run) = run else {
        return None;
    };
    let mut entry = run.clone();
    entry.insert("kind", "worktree");
    entry.insert("tier", 1);
    entry.insert(
        "reason",
        format!(
            "run {} ({}, {}) ended more than the retention window ago and kept its worktree or branch; no later run uses them",
            run.get("run_id").and_then(Value::py_int).unwrap_or_default(),
            run.string("ticket_id"),
            run.string("state"),
        ),
    );
    Some(entry)
}

/// One scan of the process table against the ledger.
pub(crate) struct ProcessScan {
    pub runs: Vec<Dict>,
    pub live_runs: HashSet<i64>,
    pub table: Vec<Process>,
    pub report: Report,
}

impl Daemon {
    /// The process half of a scan. It signals nothing.
    pub(crate) fn scan_processes(&self, now: f64) -> Outcome<ProcessScan> {
        let runs = self.runs.list(None, LEDGER_LIMIT)?;
        let live_runs = self.live_run_ids();
        let mut protected = bridge_pids();
        for session in self.orchestrator_sessions.list(None, SESSION_LIMIT)? {
            if session.string("state") == "stopped" {
                continue;
            }
            if let Some(pid) = session
                .get("pid")
                .and_then(Value::py_int)
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
            {
                protected.push(pid);
            }
        }
        let scope = Scope {
            now,
            // SAFETY: geteuid and getpid cannot fail.
            uid: unsafe { libc::geteuid() },
            own_pid: unsafe { libc::getpid() },
            workspace_root: self.paths.workspace_root.to_string_lossy().into_owned(),
            grace_seconds: GRACE_SECONDS,
            live_runs: live_runs.clone(),
            protected,
            protected_bundle: own_bundle(),
        };
        let table = snapshot();
        let report = classify(&table, &runs, &scope);
        Ok(ProcessScan {
            runs,
            live_runs,
            table,
            report,
        })
    }

    /// One report-only scan. It signals nothing and removes nothing.
    pub fn scan_leftovers(&self, now: f64) -> Outcome<Dict> {
        let ProcessScan {
            runs,
            live_runs,
            table,
            report,
        } = self.scan_processes(now)?;

        // The worktrees the stale-worktree sweep would name, in report mode.
        let mut policy =
            crate::worktree_gc::Policy::from_config(&self.config_table("orchestrator"), self, now);
        policy.delete = false;
        let worktrees = crate::worktree_gc::sweep(&runs, &policy, &live_runs);

        let mut leftovers: Vec<Value> = report.leftovers.into_iter().map(Value::Dict).collect();
        leftovers.extend(worktrees.iter().filter_map(worktree_entry).map(Value::Dict));
        let mut result = Dict::new();
        result.insert("mode", "report");
        result.insert("leftovers", Value::List(leftovers));
        result.insert("processes_scanned", table.len() as i64);
        result.insert("unreadable_processes", report.unreadable as i64);
        result.insert("grace_seconds", GRACE_SECONDS);
        Ok(result)
    }

    pub fn leftovers_route(&self, _request: &crate::request::Request) -> Outcome<Reply> {
        reply(200, self.scan_leftovers(relay_store::sql::now())?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_800_000_000.0;
    const UID: libc::uid_t = 501;
    const DAEMON: libc::pid_t = 100;
    const WS: &str = "/ws";

    fn scope() -> Scope {
        Scope {
            now: NOW,
            uid: UID,
            own_pid: DAEMON,
            workspace_root: WS.to_string(),
            grace_seconds: GRACE_SECONDS,
            live_runs: HashSet::new(),
            protected: Vec::new(),
            protected_bundle: Some("/Applications/Relay Runner.app".to_string()),
        }
    }

    fn workspace(ticket: &str) -> String {
        format!("{WS}/repo-abc-{}", ticket.to_lowercase())
    }

    /// A run that ran from `start` to `end` seconds before NOW.
    fn run(id: i64, ticket: &str, state: &str, start: f64, end: Option<f64>) -> Dict {
        let mut run = Dict::new();
        run.insert("id", id);
        run.insert("ticket_id", ticket);
        run.insert("repo_path", "/repo");
        run.insert("workspace_path", workspace(ticket));
        run.insert("branch", format!("relay/{}", ticket.to_lowercase()));
        run.insert("state", state);
        run.insert("provider_key", if id % 2 == 0 { "codex" } else { "claude" });
        run.insert("started_at", NOW - start);
        run.insert(
            "ended_at",
            end.map_or(Value::Null, |end| Value::Float(NOW - end)),
        );
        run.insert("pid", Value::Null);
        run
    }

    /// A process started `age` seconds before NOW, with no terminal, whose
    /// parent is launchd.
    fn process(pid: libc::pid_t, age: f64, argv: &[&str]) -> Process {
        Process {
            pid,
            ppid: 1,
            pgid: pid,
            uid: UID,
            start_us: ((NOW - age) * 1_000_000.0) as i64,
            tty: false,
            args: Some(Args {
                exe: argv.first().copied().unwrap_or_default().to_string(),
                argv: argv.iter().map(|arg| (*arg).to_string()).collect(),
                ..Args::default()
            }),
        }
    }

    fn tagged(mut process: Process, run_id: i64, ticket: &str) -> Process {
        let args = process.args.as_mut().unwrap();
        args.run_id = Some(run_id.to_string());
        args.workspace = Some(workspace(ticket));
        process
    }

    fn daemon_row() -> Process {
        let mut daemon = process(
            DAEMON,
            10_000.0,
            &["/Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator"],
        );
        daemon.pgid = DAEMON;
        daemon
    }

    fn listed(table: &[Process], runs: &[Dict], scope: &Scope) -> Vec<(i64, i64, i64)> {
        classify(table, runs, scope)
            .leftovers
            .iter()
            .map(|entry| {
                let int = |key| entry.get(key).and_then(Value::py_int).unwrap();
                (int("pid"), int("tier"), int("run_id"))
            })
            .collect()
    }

    fn server(ticket: &str) -> String {
        format!("{}/services/orchestrator.py", workspace(ticket))
    }

    #[test]
    fn an_rr_48_workspace_never_claims_an_rr_485_process() {
        let rr485 = server("RR-485");
        let table = vec![
            daemon_row(),
            process(
                200,
                5_000.0,
                &["/usr/bin/python3", &rr485, "--config", "/tmp/x/config.toml"],
            ),
        ];
        // Only RR-48 is in the ledger: the RR-485 process is nobody's.
        let runs = vec![run(1, "RR-48", "Failed", 6_000.0, Some(4_000.0))];
        assert!(listed(&table, &runs, &scope()).is_empty());
        // With RR-485 finished too, it is RR-485's.
        let runs = vec![
            run(1, "RR-48", "Failed", 6_000.0, Some(4_000.0)),
            run(2, "RR-485", "Merged", 6_000.0, Some(4_000.0)),
        ];
        assert_eq!(listed(&table, &runs, &scope()), vec![(200, 1, 2)]);
        assert!(names_workspace(
            &format!("--dir={}", workspace("RR-48")),
            &workspace("RR-48")
        ));
        assert!(names_workspace(&workspace("RR-48"), &workspace("RR-48")));
        assert!(!names_workspace(&rr485, &workspace("RR-48")));
        assert!(!names_workspace(
            &format!("/private{}", workspace("RR-48")),
            &workspace("RR-48")
        ));
    }

    #[test]
    fn a_reused_workspace_with_an_open_run_vetoes_and_an_older_run_owns_its_process() {
        let path = server("RR-7");
        let table = vec![
            daemon_row(),
            process(200, 5_000.0, &["/usr/bin/python3", &path]),
        ];
        // A retry is running in the same per-ticket workspace.
        for open in [
            "Running",
            "Claimed",
            "AwaitingReview",
            "Reviewing",
            "VerificationBlocked",
            "IntegrationBlocked",
            "MergeConflict",
            "Succeeded",
        ] {
            let runs = vec![
                run(1, "RR-7", "Failed", 6_000.0, Some(4_000.0)),
                run(2, "RR-7", open, 1_000.0, None),
            ];
            assert!(listed(&table, &runs, &scope()).is_empty(), "{open}");
        }
        // Both runs finished: the one running when the process started owns it.
        let runs = vec![
            run(1, "RR-7", "Failed", 6_000.0, Some(4_000.0)),
            run(2, "RR-7", "Merged", 1_000.0, Some(500.0)),
        ];
        assert_eq!(listed(&table, &runs, &scope()), vec![(200, 1, 1)]);
        // Started between the runs: path only.
        let table = vec![
            daemon_row(),
            process(200, 2_000.0, &["/usr/bin/python3", &path]),
        ];
        assert_eq!(listed(&table, &runs, &scope()), vec![(200, 2, 2)]);
    }

    #[test]
    fn a_process_with_a_terminal_is_never_tier_1() {
        let runs = vec![run(1, "RR-9", "Failed", 6_000.0, Some(4_000.0))];
        let mut by_path = process(
            200,
            5_000.0,
            &["/usr/bin/node", &format!("{}/server.js", workspace("RR-9"))],
        );
        by_path.tty = true;
        let mut by_tag = tagged(process(201, 5_000.0, &["/bin/sleep", "30"]), 1, "RR-9");
        by_tag.tty = true;
        let report = classify(&[daemon_row(), by_path, by_tag], &runs, &scope());
        let tiers: Vec<(i64, i64)> = report
            .leftovers
            .iter()
            .map(|e| {
                (
                    e.get("pid").and_then(Value::py_int).unwrap(),
                    e.get("tier").and_then(Value::py_int).unwrap(),
                )
            })
            .collect();
        assert_eq!(tiers, vec![(200, 2), (201, 2)]);
        assert!(
            report.leftovers[0]
                .string("reason")
                .contains("controlling terminal")
        );
    }

    #[test]
    fn an_unreadable_command_line_is_counted_not_listed() {
        let runs = vec![run(1, "RR-9", "Failed", 6_000.0, Some(4_000.0))];
        let mut unreadable = process(200, 5_000.0, &[]);
        unreadable.args = None;
        let report = classify(&[daemon_row(), unreadable], &runs, &scope());
        assert!(report.leftovers.is_empty());
        assert_eq!(report.unreadable, 1);
        assert!(parse_procargs(&[1, 0]).is_none(), "truncated buffer");
    }

    #[test]
    fn a_live_run_vetoes_a_match() {
        let path = server("RR-3");
        // The run is still running, by ledger state and by the daemon's map.
        let table = vec![
            daemon_row(),
            process(200, 5_000.0, &["/usr/bin/python3", &path]),
            tagged(process(201, 5_000.0, &["/bin/sleep"]), 1, "RR-3"),
        ];
        let runs = vec![run(1, "RR-3", "Running", 6_000.0, None)];
        assert!(listed(&table, &runs, &scope()).is_empty());
        let runs = vec![run(1, "RR-3", "Failed", 6_000.0, Some(4_000.0))];
        let mut live = scope();
        live.live_runs.insert(1);
        assert!(listed(&table, &runs, &live).is_empty());
        // A later live run of the same ticket in another repo layout still
        // vetoes the tagged process of the earlier run.
        let mut later = run(2, "RR-3", "Running", 100.0, None);
        later.insert("workspace_path", "/ws/elsewhere-rr-3");
        let runs = vec![run(1, "RR-3", "Failed", 6_000.0, Some(4_000.0)), later];
        assert!(listed(&table, &runs, &scope()).is_empty());
        // A running worker's provider and its tool child are under the run's
        // recorded pid, even when the child points into a finished workspace.
        let mut provider = process(300, 50.0, &["/usr/local/bin/codex", "exec"]);
        provider.ppid = DAEMON;
        let mut tool = process(301, 40.0, &["/usr/bin/python3", &server("RR-4")]);
        tool.ppid = 300;
        tool.pgid = 301;
        let mut worker = run(5, "RR-5", "Running", 60.0, None);
        worker.insert("pid", 300);
        worker.insert("pid_start_us", provider.start_us);
        let runs = vec![run(4, "RR-4", "Failed", 6_000.0, Some(4_000.0)), worker];
        // Reparented to launchd, it is still in the provider's process tree
        // by group when the provider leads it.
        let mut orphan = process(302, 40.0, &["/usr/bin/python3", &server("RR-4")]);
        orphan.pgid = 300;
        let table = vec![daemon_row(), provider, tool, orphan];
        assert!(listed(&table, &runs, &scope()).is_empty());
    }

    #[test]
    fn the_daemon_sessions_workers_and_the_app_are_never_listed() {
        let finished = server("RR-1");
        let runs = vec![run(1, "RR-1", "Failed", 6_000.0, Some(4_000.0))];
        // The daemon itself, pointing into a finished workspace, and its
        // launchd parent and a child of it.
        let mut daemon = daemon_row();
        daemon.ppid = 90;
        daemon.args.as_mut().unwrap().argv.push(finished.clone());
        let parent = process(90, 20_000.0, &["/bin/zsh", &finished]);
        let mut child = process(101, 5_000.0, &["/usr/bin/python3", &finished]);
        child.ppid = DAEMON;
        // The active session's bridge (registered with the daemon) and its
        // speech child.
        let bridge = process(
            400,
            5_000.0,
            &[
                "/Applications/Relay Runner.app/Contents/MacOS/relay-rs",
                "bridge",
                &finished,
            ],
        );
        let mut speech = process(401, 5_000.0, &["/usr/bin/relay-speech", &finished]);
        speech.ppid = 400;
        // The app, the session provider in its terminal, and the provider's
        // MCP server in a session of its own.
        let app = process(
            500,
            20_000.0,
            &["/Applications/Relay Runner.app/Contents/MacOS/relay-runner"],
        );
        let mut provider = tagged(
            process(501, 5_000.0, &["/opt/homebrew/bin/claude", &finished]),
            1,
            "RR-1",
        );
        provider.ppid = 500;
        provider.tty = true;
        let mut mcp = process(502, 5_000.0, &["/usr/bin/python3", &finished]);
        mcp.ppid = 501;
        // Another user's process.
        let mut foreign = process(600, 5_000.0, &["/usr/bin/python3", &finished]);
        foreign.uid = UID + 1;
        // The one real leftover.
        let leftover = process(700, 5_000.0, &["/usr/bin/python3", &finished]);
        let table = vec![
            daemon, parent, child, bridge, speech, app, provider, mcp, foreign, leftover,
        ];
        let mut scope = scope();
        scope.protected.push(400);
        assert_eq!(listed(&table, &runs, &scope), vec![(700, 1, 1)]);
    }

    #[test]
    fn tags_from_another_ledger_and_fresh_runs_are_not_claimed() {
        let runs = vec![run(1, "RR-1", "Failed", 6_000.0, Some(4_000.0))];
        // A test daemon's fake worker reuses run id 1 with its own workspace.
        let mut other = process(200, 5_000.0, &["/bin/sleep", "30"]);
        other.args.as_mut().unwrap().run_id = Some("1".to_string());
        other.args.as_mut().unwrap().workspace = Some("/tmp/contract/ws".to_string());
        // Tagged properly: Tier 1 even with a scrubbed command line.
        let owned = tagged(process(201, 5_000.0, &["/bin/sleep", "30"]), 1, "RR-1");
        assert_eq!(
            listed(
                &[daemon_row(), other.clone(), owned.clone()],
                &runs,
                &scope()
            ),
            vec![(201, 1, 1)]
        );
        // Inside the grace period nothing is listed.
        let runs = vec![run(1, "RR-1", "Failed", 6_000.0, Some(30.0))];
        assert!(listed(&[daemon_row(), other, owned], &runs, &scope()).is_empty());
    }

    #[test]
    fn procargs_keep_only_the_run_tags_of_the_environment() {
        let mut buffer = 2i32.to_ne_bytes().to_vec();
        buffer.extend(b"/usr/bin/python3\0\0\0\0python3\0/ws/repo-abc-rr-1/s.py\0SECRET=x\0RELAY_RUN_ID=7\0RELAY_WORKSPACE=/ws/repo-abc-rr-1\0\0");
        let args = parse_procargs(&buffer).unwrap();
        assert_eq!(args.exe, "/usr/bin/python3");
        assert_eq!(args.argv, vec!["python3", "/ws/repo-abc-rr-1/s.py"]);
        assert_eq!(args.run_id.as_deref(), Some("7"));
        assert_eq!(args.workspace.as_deref(), Some("/ws/repo-abc-rr-1"));
    }

    /// Run by the next test as a throwaway process: the test binary is not
    /// an Apple platform binary, so macOS lets the scanner read its
    /// environment.
    #[test]
    #[ignore = "helper process for a_throwaway_leftover_is_found_and_left_running"]
    fn leftover_helper_sleeps() {
        if std::env::var_os("RELAY_RR506_HELPER").is_some() {
            std::thread::sleep(std::time::Duration::from_secs(30));
        }
    }

    /// Starts `program` the way a leftover ends up: in a session of its own
    /// with no terminal, and orphaned to launchd once the shell that started
    /// it exits. Its identity, for checking and stopping it afterwards.
    fn spawn_orphan(program: &str, args: &[&str], env: &[(&str, &str)]) -> process_tree::Identity {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(r#""$0" "$@" </dev/null >/dev/null 2>&1 & echo $!"#)
            .arg(program)
            .args(args)
            .envs(env.iter().copied())
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        // SAFETY: setsid is async-signal-safe; it drops the terminal.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        let output = command.output().unwrap();
        let pid: libc::pid_t = String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse()
            .unwrap();
        process_tree::info(pid)
            .expect("the orphan is running")
            .identity
    }

    fn stop(identity: &process_tree::Identity) {
        if process_tree::matches(identity) {
            // SAFETY: the identity check makes sure the pid is still ours.
            unsafe { libc::kill(identity.pid, libc::SIGKILL) };
        }
    }

    #[test]
    fn a_throwaway_leftover_is_found_and_left_running() {
        let root = std::env::temp_dir().join(format!("relay-rr506-{}", std::process::id()));
        let workspace = root.join("ws").join("repo-abc-ct-1");
        std::fs::create_dir_all(&workspace).unwrap();
        let workspace = workspace.to_string_lossy().into_owned();
        let script = format!("{workspace}/services/orchestrator.py");
        // Tagged, with a command line that names no workspace.
        let exe = std::env::current_exe().unwrap();
        let tagged = spawn_orphan(
            &exe.to_string_lossy(),
            &[
                "--exact",
                "leftovers::tests::leftover_helper_sleeps",
                "--ignored",
            ],
            &[
                ("RELAY_RR506_HELPER", "1"),
                ("RELAY_RUN_ID", "1"),
                ("RELAY_WORKSPACE", &workspace),
            ],
        );
        // An Apple platform binary, whose environment macOS hides, pointing
        // into the workspace.
        let by_path = spawn_orphan("/usr/bin/perl", &["-e", "sleep 30", &script], &[]);
        let (tagged_pid, path_pid) = (tagged.pid, by_path.pid);
        let ready = |table: &[Process]| {
            table
                .iter()
                .any(|p| p.pid == tagged_pid && p.args.as_ref().is_some_and(|a| a.run_id.is_some()))
                && table.iter().any(|p| {
                    p.pid == path_pid
                        && p.args
                            .as_ref()
                            .is_some_and(|a| a.argv.last() == Some(&script))
                })
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut table = snapshot();
        while !ready(&table) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
            table = snapshot();
        }
        let now = relay_store::sql::now();
        let mut row = Dict::new();
        row.insert("id", 1);
        row.insert("ticket_id", "CT-1");
        row.insert("repo_path", "/repo");
        row.insert("workspace_path", workspace.as_str());
        row.insert("state", "Failed");
        row.insert("started_at", now - 60.0);
        row.insert("ended_at", now);
        row.insert("pid", Value::Null);
        let scope = Scope {
            now,
            uid: unsafe { libc::geteuid() },
            own_pid: unsafe { libc::getpid() },
            workspace_root: root.join("ws").to_string_lossy().into_owned(),
            grace_seconds: 0.0,
            live_runs: HashSet::new(),
            protected: Vec::new(),
            protected_bundle: None,
        };
        let report = classify(&table, &[row.clone()], &scope);
        // The same leftovers while their run is still open are not listed.
        let mut open = row;
        open.insert("state", "Running");
        let vetoed = classify(&table, &[open], &scope);
        let found = |pid| table.iter().find(|p| p.pid == pid).cloned();
        let (tagged_row, path_row) = (found(tagged_pid), found(path_pid));
        let own = table.iter().any(|p| p.pid == scope.own_pid);
        let survived = process_tree::matches(&tagged) && process_tree::matches(&by_path);
        stop(&tagged);
        stop(&by_path);
        let _ = std::fs::remove_dir_all(&root);

        let tagged_row = tagged_row.expect("the tagged leftover is in the table");
        let path_row = path_row.expect("the path leftover is in the table");
        assert!(
            !tagged_row.tty && !path_row.tty,
            "setsid dropped the terminal"
        );
        let tags = tagged_row.args.expect("its command line is readable");
        assert_eq!(tags.run_id.as_deref(), Some("1"));
        assert_eq!(tags.workspace.as_deref(), Some(workspace.as_str()));
        let path_args = path_row.args.expect("its command line is readable");
        assert_eq!(path_args.argv.last(), Some(&script));
        assert!(own, "the scanner sees itself");
        let entry = |pid: libc::pid_t| {
            let entries: Vec<&Dict> = report
                .leftovers
                .iter()
                .filter(|e| e.get("pid").and_then(Value::py_int) == Some(i64::from(pid)))
                .collect();
            assert_eq!(entries.len(), 1, "{:?}", report.leftovers);
            (
                entries[0].get("tier").and_then(Value::py_int),
                entries[0].string("evidence"),
            )
        };
        assert_eq!(entry(tagged_pid), (Some(1), "environment".to_string()));
        assert_eq!(entry(path_pid), (Some(1), "path".to_string()));
        assert!(
            !report
                .leftovers
                .iter()
                .any(|e| e.get("pid").and_then(Value::py_int) == Some(i64::from(scope.own_pid))),
            "the scanner never lists itself"
        );
        assert!(vetoed.leftovers.is_empty(), "an open run vetoes");
        assert!(survived, "the scan stopped nothing");
    }
}
