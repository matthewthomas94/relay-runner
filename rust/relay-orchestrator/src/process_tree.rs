//! The processes a worker or reviewer provider leaves behind (RR-503).
//!
//! The provider starts in its own process group, so `killpg` reaches every
//! tool child that stays in it. That alone is not enough (RR-502): Codex
//! shell-tool children and MCP servers call `setsid` themselves, and nothing
//! shows where Claude's tool children go. So the daemon also follows the
//! provider's descendants by parent pid while it runs, and signals only a
//! process whose identity still matches what it recorded: pid, uid and
//! start time (seconds and microseconds). A mismatch means the pid now
//! names another process, which is never signalled.
//!
//! The run ledger keeps the provider's group and start time with its pid
//! (RR-504), so liveness checks and a later daemon can tell the provider
//! from whatever reuses its pid.

use std::collections::HashMap;
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{Dict, Value};
use relay_store::runs::StartupProcess;

/// `PROC_PGRP_ONLY` and `PROC_PPID_ONLY` from `<sys/proc_info.h>`.
const PROC_PGRP_ONLY: u32 = 2;
const PROC_PPID_ONLY: u32 = 6;

/// Who a pid named when it was recorded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Identity {
    pub pid: libc::pid_t,
    pub uid: libc::uid_t,
    pub start_sec: u64,
    pub start_usec: u64,
}

/// One live process: who it is, and where it sits in the tree.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Info {
    pub identity: Identity,
    pub ppid: libc::pid_t,
    pub pgid: libc::pid_t,
}

/// The process `pid` names now; `None` once it has exited (zombies
/// included) or when it cannot be read.
pub(crate) fn info(pid: libc::pid_t) -> Option<Info> {
    if pid <= 1 {
        return None;
    }
    // SAFETY: proc_bsdinfo is plain data; proc_pidinfo writes at most the
    // size passed.
    let mut bsd: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let written =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut bsd).cast(), size) };
    if written != size || bsd.pbi_pid as libc::pid_t != pid || bsd.pbi_status == libc::SZOMB {
        return None;
    }
    Some(Info {
        identity: Identity {
            pid,
            uid: bsd.pbi_uid,
            start_sec: bsd.pbi_start_tvsec,
            start_usec: bsd.pbi_start_tvusec,
        },
        ppid: bsd.pbi_ppid as libc::pid_t,
        pgid: bsd.pbi_pgid as libc::pid_t,
    })
}

/// `identity` still names a live process.
pub(crate) fn matches(identity: &Identity) -> bool {
    info(identity.pid).is_some_and(|live| live.identity == *identity)
}

/// The start time as the ledger's `pid_start_us` stores it.
pub(crate) fn start_us(identity: &Identity) -> i64 {
    let seconds = i64::try_from(identity.start_sec).unwrap_or(i64::MAX);
    let micros = i64::try_from(identity.start_usec).unwrap_or(0);
    seconds.saturating_mul(1_000_000).saturating_add(micros)
}

/// A run row's recorded provider pid.
fn run_pid(run: &Dict) -> Option<libc::pid_t> {
    let pid = run.get("pid").and_then(Value::py_int)?;
    libc::pid_t::try_from(pid).ok().filter(|pid| *pid > 1)
}

/// The process `pid` names now, when it is this user's and started at
/// `start` (`pid_start_us`).
fn recorded_live(pid: libc::pid_t, start: i64) -> Option<Info> {
    // SAFETY: geteuid cannot fail.
    let uid = unsafe { libc::geteuid() };
    info(pid).filter(|live| live.identity.uid == uid && start_us(&live.identity) == start)
}

/// `kill(pid, 0)` succeeds or is refused: all a row without a start time
/// can show.
fn pid_in_use(pid: libc::pid_t) -> bool {
    // SAFETY: kill with signal 0 only checks that the process exists.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// `_process_is_alive(run)`: the run's recorded provider still runs. A row
/// with a start time counts only while its pid names a process of this user
/// with that same start time, so a reused pid never keeps a run alive. An
/// older row without one falls back to `kill(pid, 0)`.
pub(crate) fn process_is_alive(run: &Dict) -> bool {
    let Some(pid) = run_pid(run) else {
        return false;
    };
    match run.get("pid_start_us").and_then(Value::py_int) {
        Some(start) => recorded_live(pid, start).is_some(),
        None => pid_in_use(pid),
    }
}

/// Stops the provider a previous daemon recorded for `run`, with whatever
/// it started (RR-504). Only a provider whose pid still names the process
/// recorded at spawn (same user and start time) is signalled: its group
/// when it still leads the recorded one, and every descendant found under
/// it, by identity. SIGTERM, then SIGKILL to what is left after `grace`. A
/// row without a start time is never signalled.
pub(crate) fn stop_recorded(run: &Dict, grace: Duration) -> StartupProcess {
    let Some(pid) = run_pid(run) else {
        return StartupProcess::Gone;
    };
    let Some(start) = run.get("pid_start_us").and_then(Value::py_int) else {
        return if pid_in_use(pid) {
            StartupProcess::Unverified
        } else {
            StartupProcess::Gone
        };
    };
    let Some(live) = recorded_live(pid, start) else {
        return StartupProcess::Gone;
    };
    // SAFETY: getpgrp and getpid cannot fail.
    let (own_group, own_pid) = unsafe { (libc::getpgrp(), libc::getpid()) };
    if pid == own_pid {
        return StartupProcess::Unverified;
    }
    let recorded_group = run.get("pgid").and_then(Value::py_int);
    let leads_group =
        recorded_group == Some(i64::from(pid)) && live.pgid == pid && pid != own_group;
    let mut tree = ProcessTree::new(pid);
    tree.refresh(true);
    for signal in [libc::SIGTERM, libc::SIGKILL] {
        // SAFETY: the identity check just before makes sure the pid, and
        // the group it leads, still name the recorded provider.
        if matches(&live.identity) {
            unsafe {
                if leads_group {
                    libc::killpg(pid, signal);
                } else {
                    libc::kill(pid, signal);
                }
            }
        }
        tree.signal(signal);
        let deadline = Instant::now() + grace;
        let stopped = || !matches(&live.identity) && tree.survivors().is_empty();
        while !stopped() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        if stopped() {
            break;
        }
    }
    StartupProcess::Stopped
}

/// `proc_listpids(kind, value)`: the pids it reports (zombies included).
fn list(kind: u32, value: libc::pid_t) -> Vec<libc::pid_t> {
    let width = std::mem::size_of::<libc::pid_t>();
    // SAFETY: a null buffer only asks for the size.
    let needed = unsafe { libc::proc_listpids(kind, value as u32, std::ptr::null_mut(), 0) };
    if needed <= 0 {
        return Vec::new();
    }
    // Room for processes started since the size was read.
    let mut pids: Vec<libc::pid_t> = vec![0; needed as usize / width + 64];
    let bytes = (pids.len() * width) as libc::c_int;
    // SAFETY: the buffer holds `bytes` bytes.
    let filled =
        unsafe { libc::proc_listpids(kind, value as u32, pids.as_mut_ptr().cast(), bytes) };
    if filled <= 0 {
        return Vec::new();
    }
    pids.truncate(filled as usize / width);
    pids.retain(|pid| *pid > 1);
    pids
}

/// A provider's descendants: every process seen under it, by identity.
pub(crate) struct ProcessTree {
    root: libc::pid_t,
    uid: libc::uid_t,
    own_pid: libc::pid_t,
    tracked: HashMap<libc::pid_t, Identity>,
}

impl ProcessTree {
    pub(crate) fn new(root: libc::pid_t) -> Self {
        Self {
            root,
            // SAFETY: neither call can fail.
            uid: unsafe { libc::geteuid() },
            own_pid: unsafe { libc::getpid() },
            tracked: HashMap::new(),
        }
    }

    /// Records every live process now reachable from the root, which must
    /// be unreaped when `root_held` (so its pid and group id still name
    /// it), or from a tracked process whose identity still matches: its
    /// children, and the members of a group it leads. Forgets tracked
    /// processes that have gone.
    pub(crate) fn refresh(&mut self, root_held: bool) {
        self.tracked.retain(|_, identity| matches(identity));
        let mut frontier: Vec<libc::pid_t> = self.tracked.keys().copied().collect();
        if root_held {
            frontier.push(self.root);
        }
        while let Some(parent) = frontier.pop() {
            let leads_group =
                parent == self.root || info(parent).is_some_and(|live| live.pgid == parent);
            let mut found = list(PROC_PPID_ONLY, parent);
            if leads_group {
                found.extend(list(PROC_PGRP_ONLY, parent));
            }
            for pid in found {
                if pid == self.root || pid == self.own_pid || self.tracked.contains_key(&pid) {
                    continue;
                }
                let Some(live) = info(pid) else {
                    continue;
                };
                // Only a process still under `parent` counts; the lists and
                // the read are not one atomic step.
                if live.identity.uid != self.uid || (live.ppid != parent && live.pgid != parent) {
                    continue;
                }
                self.tracked.insert(pid, live.identity);
                frontier.push(pid);
            }
        }
    }

    /// The tracked processes still running.
    pub(crate) fn survivors(&self) -> Vec<Identity> {
        self.tracked
            .values()
            .filter(|identity| matches(identity))
            .copied()
            .collect()
    }

    /// Sends `signal` to every tracked process whose identity still
    /// matches; how many it reached.
    pub(crate) fn signal(&self, signal: libc::c_int) -> usize {
        let mut sent = 0;
        for identity in self.tracked.values() {
            if !matches(identity) {
                continue;
            }
            // SAFETY: kill only sends a signal; the identity check just
            // above makes sure the pid still names the recorded process.
            if unsafe { libc::kill(identity.pid, signal) } == 0 {
                sent += 1;
            }
        }
        sent
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    #[test]
    fn identity_reads_this_process_and_rejects_a_changed_start_time() {
        let pid = unsafe { libc::getpid() };
        let live = info(pid).expect("own process");
        assert_eq!(live.identity.uid, unsafe { libc::geteuid() });
        assert!(live.identity.start_sec > 0);
        assert!(matches(&live.identity));
        let mut other = live.identity;
        other.start_usec = other.start_usec.wrapping_add(1);
        assert!(
            !matches(&other),
            "a different start time is another process"
        );
        let mut other = live.identity;
        other.uid = other.uid.wrapping_add(1);
        assert!(!matches(&other), "a different uid is another process");
        assert!(info(1).is_none(), "launchd is never a candidate");
    }

    #[test]
    fn a_reaped_process_no_longer_matches() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let pid = child.id() as libc::pid_t;
        let recorded = info(pid).expect("running child").identity;
        assert!(matches(&recorded));
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!matches(&recorded));
    }

    #[test]
    fn the_tree_follows_children_that_leave_the_group() {
        // A throwaway root with one child in its group and one that starts
        // a session of its own, the way Codex tool children do.
        let mut root = Command::new("/bin/sh")
            .arg("-c")
            .arg("/bin/sleep 30 & /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 30' & wait")
            .stdin(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let pid = root.id() as libc::pid_t;
        let mut tree = ProcessTree::new(pid);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while tree.survivors().len() < 2 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
            tree.refresh(true);
        }
        let survivors = tree.survivors();
        let left_group = survivors
            .iter()
            .filter(|identity| info(identity.pid).is_some_and(|live| live.pgid != pid))
            .count();
        // Stop everything before asserting.
        unsafe { libc::killpg(pid, libc::SIGKILL) };
        tree.signal(libc::SIGKILL);
        root.wait().unwrap();
        assert_eq!(survivors.len(), 2, "both children are tracked");
        assert_eq!(left_group, 1, "the setsid child left the group");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !tree.survivors().is_empty() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(tree.survivors().is_empty());
    }

    /// A run row as the ledger stores a provider: pid, group, start time.
    fn row(pid: libc::pid_t, start: Option<i64>) -> Dict {
        let mut run = Dict::new();
        run.insert("pid", Value::Int(i64::from(pid)));
        run.insert("pgid", Value::Int(i64::from(pid)));
        run.insert("pid_start_us", start.map_or(Value::Null, Value::Int));
        run
    }

    fn still_running(child: &mut std::process::Child) -> bool {
        child.try_wait().unwrap().is_none()
    }

    #[test]
    fn a_reused_pid_is_never_signalled_or_counted_alive() {
        let mut child = Command::new("/bin/sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let pid = child.id() as libc::pid_t;
        let live = info(pid).expect("running child");
        let start = start_us(&live.identity);

        // The pid now names a process that started at another time.
        let reused = row(pid, Some(start + 1));
        assert!(!process_is_alive(&reused));
        assert_eq!(
            stop_recorded(&reused, Duration::from_millis(200)),
            StartupProcess::Gone
        );
        // A row from before RR-504 cannot prove whose the pid is.
        let legacy = row(pid, None);
        assert!(process_is_alive(&legacy), "falls back to kill(pid, 0)");
        assert_eq!(
            stop_recorded(&legacy, Duration::from_millis(200)),
            StartupProcess::Unverified
        );
        thread::sleep(Duration::from_millis(100));
        let survived = still_running(&mut child);
        assert!(process_is_alive(&row(pid, Some(start))));

        child.kill().unwrap();
        child.wait().unwrap();
        assert!(survived, "neither row signalled the process");
        assert!(!process_is_alive(&row(pid, Some(start))));
        assert!(!process_is_alive(&row(0, None)));
    }

    #[test]
    fn startup_stops_a_previous_daemons_provider_and_what_it_started() {
        use relay_store::runs::{NewRun, RunUpdate, RunsStore};

        let data = std::env::temp_dir().join(format!("relay-rr504-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data);
        let store = RunsStore::open(&data.join("runs.db"), None).unwrap();
        let record = |ticket: &str, child: &std::process::Child, shift: i64| {
            let pid = child.id() as libc::pid_t;
            let live = info(pid).expect("running child");
            let run = store
                .insert(&NewRun {
                    ticket_id: ticket.to_string(),
                    repo_path: "/tmp/repo".to_string(),
                    workspace_path: "/tmp/workspace".to_string(),
                    branch: "relay/x".to_string(),
                    state: "Claimed".to_string(),
                    ..NewRun::default()
                })
                .unwrap();
            store
                .update(
                    run,
                    &RunUpdate {
                        state: Some("Running".to_string()),
                        pid: Some(i64::from(pid)),
                        pgid: Some(i64::from(live.pgid)),
                        pid_start_us: Some(start_us(&live.identity) + shift),
                        ..RunUpdate::default()
                    },
                )
                .unwrap();
            run
        };

        // A provider with a tool child in its group and one that left it.
        let mut provider = Command::new("/bin/sh")
            .arg("-c")
            .arg("/bin/sleep 30 & /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 30' & wait")
            .stdin(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let mut tree = ProcessTree::new(provider.id() as libc::pid_t);
        let deadline = Instant::now() + Duration::from_secs(10);
        while tree.survivors().len() < 2 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
            tree.refresh(true);
        }
        let children = tree.survivors();
        // An unrelated process whose pid the ledger recorded for another
        // process (a different start time).
        let mut unrelated = Command::new("/bin/sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let stopped_run = record("RR-1", &provider, 0);
        let reused_run = record("RR-2", &unrelated, -1);

        let reconciled = store
            .reconcile_on_startup(|run| stop_recorded(run, Duration::from_secs(2)))
            .unwrap();
        let provider_stopped = provider.try_wait().unwrap().is_some();
        let unrelated_survived = still_running(&mut unrelated);
        let deadline = Instant::now() + Duration::from_secs(5);
        while children.iter().any(matches) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        let children_left = children.iter().filter(|child| matches(child)).count();
        // Clean up before asserting.
        tree.signal(libc::SIGKILL);
        unsafe { libc::killpg(provider.id() as libc::pid_t, libc::SIGKILL) };
        let _ = provider.wait();
        let _ = unrelated.kill();
        let _ = unrelated.wait();
        let state = |run| store.get(run).unwrap().unwrap().string("last_error");
        let (stopped_error, reused_error) = (state(stopped_run), state(reused_run));
        drop(store);
        let _ = std::fs::remove_dir_all(&data);

        assert_eq!(children.len(), 2, "both tool children started");
        assert_eq!(reconciled, 2);
        assert!(provider_stopped, "the provider was stopped");
        assert_eq!(children_left, 0, "its children were stopped with it");
        assert!(unrelated_survived, "a reused pid is never signalled");
        assert_eq!(
            stopped_error,
            "Worker process of the previous daemon was stopped when daemon restarted"
        );
        assert_eq!(
            reused_error,
            "Worker process was no longer running when daemon restarted"
        );
    }
}
