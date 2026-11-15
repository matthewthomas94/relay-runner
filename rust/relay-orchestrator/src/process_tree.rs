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

use std::collections::HashMap;

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
}
