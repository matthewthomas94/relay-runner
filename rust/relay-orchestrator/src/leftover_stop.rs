//! Automatic stopping of verified leftovers (RR-507).
//!
//! At daemon start, after `reconcile_on_startup`, and then every 15 minutes,
//! the daemon runs the RR-506 scanner and stops its Tier 1 process
//! leftovers: SIGTERM, a grace period, then SIGKILL to whatever is left.
//! Each signal goes only to a process whose identity (pid, uid and start
//! time to the microsecond) still matches the scan, checked just before the
//! signal, so a pid reused since the scan is never hit. Tier 2 path-only
//! matches and old worktrees are never stopped or removed here.
//!
//! `[orchestrator] leftover_cleanup` picks the mode: `stop` (the default),
//! `report` (scan and log, signal nothing) or `off` (no scan). Any other
//! value is treated as `report`. Each stop is logged and sent as a
//! `run-reconciled` lifecycle trace. Claude and Codex runs are treated
//! alike: the scan reads the ledger and the process table, never the
//! provider.

use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{self, Dict, Value};

use crate::daemon::{Daemon, guard};
use crate::leftovers::{Process, ProcessScan};
use crate::process_tree::{self, Identity};
use crate::trace::LifecycleEvent;

/// How often the daemon scans again after its first scan at startup.
pub const INTERVAL_SECONDS: f64 = 900.0;
/// How long a leftover has to exit after SIGTERM before it gets SIGKILL.
pub const STOP_GRACE: Duration = Duration::from_secs(5);
/// How long to wait for a process to go after SIGKILL.
const KILL_WAIT: Duration = Duration::from_secs(1);

/// `[orchestrator] leftover_cleanup`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Off,
    Report,
    Stop,
}

impl Mode {
    /// Missing means `stop`; `off`, `report` and `stop` in any case are
    /// themselves; anything else is `report`, which signals nothing.
    pub fn from_config(orchestrator: &Dict) -> Self {
        match orchestrator.get("leftover_cleanup") {
            None | Some(Value::Null) => Self::Stop,
            Some(Value::Str(text)) => match text.trim().to_lowercase().as_str() {
                "off" => Self::Off,
                "stop" => Self::Stop,
                _ => Self::Report,
            },
            Some(_) => Self::Report,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Report => "report",
            Self::Stop => "stop",
        }
    }
}

/// A Tier 1 leftover to stop: who it was at scan time, and whose it is.
#[derive(Clone, Debug)]
pub(crate) struct Target {
    pub identity: Identity,
    pub run_id: i64,
    pub ticket_id: String,
    pub repo_path: String,
    pub command: String,
    pub evidence: String,
}

/// What stopping one target came to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// Its identity no longer matched before SIGTERM; nothing was sent.
    Gone,
    /// It exited within the grace period after SIGTERM.
    Terminated,
    /// It outlived the grace period and exited after SIGKILL.
    Killed,
    /// It was still running after SIGKILL.
    Survived,
}

impl Stop {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gone => "gone",
            Self::Terminated => "terminated",
            Self::Killed => "killed",
            Self::Survived => "survived",
        }
    }

    fn stopped(self) -> bool {
        matches!(self, Self::Terminated | Self::Killed)
    }
}

/// The identity a scanned process had.
fn identity(process: &Process) -> Identity {
    let start = process.start_us.max(0);
    Identity {
        pid: process.pid,
        uid: process.uid,
        start_sec: (start / 1_000_000) as u64,
        start_usec: (start % 1_000_000) as u64,
    }
}

/// The scan's Tier 1 process leftovers, with the identity each had.
pub(crate) fn targets(table: &[Process], leftovers: &[Dict]) -> Vec<Target> {
    leftovers
        .iter()
        .filter(|entry| entry.string("kind") == "process")
        .filter(|entry| entry.get("tier").and_then(Value::py_int) == Some(1))
        .filter_map(|entry| {
            let pid = entry.get("pid").and_then(Value::py_int)?;
            let process = table.iter().find(|row| i64::from(row.pid) == pid)?;
            Some(Target {
                identity: identity(process),
                run_id: entry
                    .get("run_id")
                    .and_then(Value::py_int)
                    .unwrap_or_default(),
                ticket_id: entry.string("ticket_id"),
                repo_path: entry.string("repo_path"),
                command: entry.string("command"),
                evidence: entry.string("evidence"),
            })
        })
        .collect()
}

/// `signal` to `identity`, only when it still names the scanned process.
fn send(identity: &Identity, signal: libc::c_int) -> bool {
    if identity.pid <= 1 || !process_tree::matches(identity) {
        return false;
    }
    // SAFETY: kill only sends a signal; the identity check just above makes
    // sure the pid still names the process the scan verified.
    unsafe { libc::kill(identity.pid, signal) == 0 }
}

/// Sends SIGTERM to every target whose identity still matches; whether
/// each was sent.
pub(crate) fn terminate(targets: &[Target]) -> Vec<bool> {
    targets
        .iter()
        .map(|target| send(&target.identity, libc::SIGTERM))
        .collect()
}

fn wait_gone(identities: &[&Identity], timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while identities
        .iter()
        .any(|identity| process_tree::matches(identity))
        && Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(20));
    }
}

/// Waits up to `grace` for the targets `terminate` signalled, then sends
/// SIGKILL, again after an identity check, to those still running.
pub(crate) fn finish(targets: &[Target], sent: &[bool], grace: Duration) -> Vec<Stop> {
    let signalled: Vec<&Identity> = targets
        .iter()
        .zip(sent)
        .filter(|(_, sent)| **sent)
        .map(|(target, _)| &target.identity)
        .collect();
    wait_gone(&signalled, grace);
    let mut killed = vec![false; targets.len()];
    for (index, target) in targets.iter().enumerate() {
        if sent[index] && process_tree::matches(&target.identity) {
            killed[index] = send(&target.identity, libc::SIGKILL);
        }
    }
    let after_kill: Vec<&Identity> = targets
        .iter()
        .zip(&killed)
        .filter(|(_, killed)| **killed)
        .map(|(target, _)| &target.identity)
        .collect();
    wait_gone(&after_kill, KILL_WAIT);
    targets
        .iter()
        .enumerate()
        .map(|(index, target)| {
            if !sent[index] {
                Stop::Gone
            } else if process_tree::matches(&target.identity) {
                Stop::Survived
            } else if killed[index] {
                Stop::Killed
            } else {
                Stop::Terminated
            }
        })
        .collect()
}

/// What a pass in `mode` stops of a scan: its Tier 1 processes in `stop`
/// mode, nothing in `report` or `off`.
pub(crate) fn plan(mode: Mode, table: &[Process], leftovers: &[Dict]) -> Vec<Target> {
    match mode {
        Mode::Stop => targets(table, leftovers),
        Mode::Off | Mode::Report => Vec::new(),
    }
}

/// The public trace message for one stopped leftover.
fn stop_message(ticket_id: &str, run_id: i64) -> String {
    format!(
        "Stopped a leftover process of {} run {run_id}",
        ticket_id.to_uppercase()
    )
}

impl Daemon {
    /// One cleanup pass in the configured mode.
    pub fn clean_leftovers(&self, now: f64) -> Dict {
        let mode = Mode::from_config(&self.config_table("orchestrator"));
        let mut result = Dict::new();
        result.insert("mode", mode.as_str());
        if mode == Mode::Off {
            return result;
        }
        // A dispatch reuses the per-ticket workspace, so decide and send
        // SIGTERM while no dispatch can open a run there.
        let dispatching = guard(&self.dispatch_lock);
        let ProcessScan { table, report, .. } = match self.scan_processes(now) {
            Ok(scan) => scan,
            Err(error) => {
                result.insert("error", error.to_string());
                return result;
            }
        };
        result.insert(
            "leftovers",
            Value::List(report.leftovers.iter().cloned().map(Value::Dict).collect()),
        );
        let targets = plan(mode, &table, &report.leftovers);
        if targets.is_empty() {
            return result;
        }
        let sent = terminate(&targets);
        drop(dispatching);
        let outcomes = finish(&targets, &sent, STOP_GRACE);

        let mut stopped = Vec::new();
        for (target, outcome) in targets.iter().zip(outcomes) {
            self.record_stop(target, outcome);
            let mut entry = Dict::new();
            entry.insert("pid", i64::from(target.identity.pid));
            entry.insert("command", target.command.clone());
            entry.insert("run_id", target.run_id);
            entry.insert("ticket_id", target.ticket_id.clone());
            entry.insert("evidence", target.evidence.clone());
            entry.insert("outcome", outcome.as_str());
            stopped.push(Value::Dict(entry));
        }
        result.insert("stopped", Value::List(stopped));
        result
    }

    /// Logs one target's outcome, and traces it when it was stopped.
    fn record_stop(&self, target: &Target, outcome: Stop) {
        let ticket = target.ticket_id.to_uppercase();
        let what = match outcome {
            Stop::Gone => "left alone, it had exited or its pid was reused",
            Stop::Terminated => "stopped with SIGTERM",
            Stop::Killed => "stopped with SIGKILL after the grace period",
            Stop::Survived => "still running after SIGKILL",
        };
        eprintln!(
            "[orchestrator] leftover pid {} ({}) of {ticket} run {} ({}): {what}",
            target.identity.pid, target.command, target.run_id, target.evidence,
        );
        if !outcome.stopped() {
            return;
        }
        let message = stop_message(&target.ticket_id, target.run_id);
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-reconciled",
            ticket_id: Some(&target.ticket_id),
            run_id: Some(target.run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&target.repo_path),
            provider_key: None,
            queue_messenger: Some(false),
        });
    }
}

/// The daemon's background cleanup: once at startup, then every 15
/// minutes. The leftover list is logged when it differs from the last one,
/// so report mode does not repeat the same lines.
pub fn cleanup_loop(daemon: &Daemon, wait: &dyn Fn(f64) -> bool) {
    let mut previous: Option<String> = None;
    loop {
        let result = daemon.clean_leftovers(relay_store::sql::now());
        if let Some(error) = result.get("error") {
            eprintln!("[orchestrator] leftover cleanup failed: {}", error.py_str());
        }
        if let Some(leftovers) = result.get("leftovers") {
            let text = json::dumps(leftovers);
            let empty = matches!(leftovers, Value::List(items) if items.is_empty());
            if previous.as_ref() != Some(&text) && !empty {
                eprintln!(
                    "[orchestrator] leftover processes ({}): {text}",
                    result.string("mode")
                );
            }
            previous = Some(text);
        }
        if !wait(INTERVAL_SECONDS) {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::leftovers::{Args, Scope, classify};
    use std::collections::HashSet;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    /// SIGTERM, `grace`, then SIGKILL, as `clean_leftovers` sends them.
    fn stop(targets: &[Target], grace: Duration) -> Vec<Stop> {
        let sent = terminate(targets);
        finish(targets, &sent, grace)
    }

    fn config(value: Option<Value>) -> Dict {
        let mut table = Dict::new();
        if let Some(value) = value {
            table.insert("leftover_cleanup", value);
        }
        table
    }

    #[test]
    fn the_switch_defaults_to_stop_and_falls_back_to_report() {
        assert_eq!(Mode::from_config(&config(None)), Mode::Stop);
        assert_eq!(Mode::from_config(&config(Some(Value::Null))), Mode::Stop);
        for (text, mode) in [
            ("off", Mode::Off),
            ("OFF", Mode::Off),
            ("report", Mode::Report),
            (" stop ", Mode::Stop),
            ("kill", Mode::Report),
            ("", Mode::Report),
        ] {
            assert_eq!(
                Mode::from_config(&config(Some(Value::Str(text.to_string())))),
                mode,
                "{text:?}"
            );
        }
        assert_eq!(
            Mode::from_config(&config(Some(Value::Bool(true)))),
            Mode::Report
        );
    }

    /// Starts `program` as a leftover is found: in a session of its own with
    /// no terminal, orphaned to launchd once the shell that started it exits.
    fn spawn_orphan(program: &str, args: &[&str]) -> Identity {
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(r#""$0" "$@" </dev/null >/dev/null 2>&1 & echo $!"#)
            .arg(program)
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::null());
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

    /// A perl that sleeps; `ignore_term` makes it ignore SIGTERM. `marker`
    /// ends up in its command line.
    fn sleeper(ignore_term: bool, marker: &str) -> Identity {
        let script = if ignore_term {
            "$SIG{TERM} = 'IGNORE'; sleep 30"
        } else {
            "sleep 30"
        };
        let identity = spawn_orphan("/usr/bin/perl", &["-e", script, marker]);
        // Let perl install its handler before it is signalled.
        thread::sleep(Duration::from_millis(200));
        identity
    }

    fn target(identity: Identity) -> Target {
        Target {
            identity,
            run_id: 1,
            ticket_id: "CT-1".to_string(),
            repo_path: "/repo".to_string(),
            command: "perl".to_string(),
            evidence: "path".to_string(),
        }
    }

    fn cleanup(identities: &[Identity]) {
        for identity in identities {
            if process_tree::matches(identity) {
                // SAFETY: the identity check makes sure the pid is still ours.
                unsafe { libc::kill(identity.pid, libc::SIGKILL) };
            }
        }
    }

    #[test]
    fn sigkill_comes_only_after_the_grace_period() {
        let polite = sleeper(false, "rr507-polite");
        let stubborn = sleeper(true, "rr507-stubborn");
        let grace = Duration::from_millis(800);
        let targets = [target(polite), target(stubborn)];

        let started = Instant::now();
        let sent = terminate(&targets);
        // Inside the grace period the stubborn one is still running.
        thread::sleep(Duration::from_millis(300));
        let polite_gone = !process_tree::matches(&polite);
        let stubborn_waiting = process_tree::matches(&stubborn);
        let outcomes = finish(&targets, &sent, grace);
        let elapsed = started.elapsed();
        cleanup(&[polite, stubborn]);

        assert_eq!(sent, vec![true, true]);
        assert!(polite_gone, "SIGTERM stopped the polite one");
        assert!(stubborn_waiting, "no SIGKILL before the grace period ends");
        assert_eq!(outcomes, vec![Stop::Terminated, Stop::Killed]);
        assert!(
            elapsed >= grace,
            "SIGKILL waited for the grace: {elapsed:?}"
        );
        assert!(!process_tree::matches(&stubborn));
    }

    #[test]
    fn a_changed_identity_is_never_signalled() {
        let live = sleeper(false, "rr507-reused");
        // The scan recorded another start time: the pid now names another
        // process.
        let mut reused = live;
        reused.start_usec = (reused.start_usec + 1) % 1_000_000;
        let mut other_user = live;
        other_user.uid = other_user.uid.wrapping_add(1);
        let outcomes = stop(
            &[target(reused), target(other_user)],
            Duration::from_millis(200),
        );
        let survived = process_tree::matches(&live);
        cleanup(&[live]);
        assert_eq!(outcomes, vec![Stop::Gone, Stop::Gone]);
        assert!(survived, "the live process was never signalled");
    }

    /// A Failed run of `workspace` that ran from `started` to `ended`.
    fn finished_run(id: i64, ticket: &str, workspace: &str, started: f64, ended: f64) -> Dict {
        let mut row = Dict::new();
        row.insert("id", id);
        row.insert("ticket_id", ticket);
        row.insert("repo_path", "/repo");
        row.insert("workspace_path", workspace);
        row.insert("state", "Failed");
        row.insert("started_at", started);
        row.insert("ended_at", ended);
        row.insert("pid", Value::Null);
        row
    }

    /// What `clean_leftovers` does with a scan in `mode`.
    fn apply(mode: Mode, table: &[Process], leftovers: &[Dict]) -> Vec<Stop> {
        stop(&plan(mode, table, leftovers), Duration::from_millis(500))
    }

    #[test]
    fn only_tier_1_is_stopped_and_report_and_off_stop_nothing() {
        let root = std::env::temp_dir().join(format!("relay-rr507-{}", std::process::id()));
        let ws = root.join("ws");
        let owned = ws.join("repo-abc-ct-1").to_string_lossy().into_owned();
        let foreign = ws.join("repo-abc-ct-2").to_string_lossy().into_owned();
        std::fs::create_dir_all(&owned).unwrap();
        std::fs::create_dir_all(&foreign).unwrap();
        let script = |workspace: &str| format!("{workspace}/services/orchestrator.py");

        for mode in [Mode::Off, Mode::Report, Mode::Stop] {
            // Tier 1: points into CT-1's workspace and started during its run.
            let tier1 = sleeper(false, &script(&owned));
            // Tier 2: points into CT-2's workspace but started outside its
            // run, which is dated well after it.
            let tier2 = sleeper(false, &script(&foreign));
            let now = relay_store::sql::now();
            let runs = vec![
                finished_run(1, "CT-1", &owned, now - 60.0, now),
                finished_run(2, "CT-2", &foreign, now + 10.0, now + 20.0),
            ];
            let scope = Scope {
                now: now + 30.0,
                uid: unsafe { libc::geteuid() },
                own_pid: unsafe { libc::getpid() },
                workspace_root: ws.to_string_lossy().into_owned(),
                grace_seconds: 0.0,
                live_runs: HashSet::new(),
                protected: Vec::new(),
                protected_bundle: None,
            };
            let ready = |table: &[Process]| {
                [tier1.pid, tier2.pid].iter().all(|pid| {
                    table
                        .iter()
                        .any(|row| row.pid == *pid && row.args.as_ref().is_some_and(named))
                })
            };
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut table = crate::leftovers::snapshot();
            while !ready(&table) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(20));
                table = crate::leftovers::snapshot();
            }
            let report = classify(&table, &runs, &scope);
            let tier_of = |pid: libc::pid_t| {
                report
                    .leftovers
                    .iter()
                    .find(|entry| entry.get("pid").and_then(Value::py_int) == Some(i64::from(pid)))
                    .and_then(|entry| entry.get("tier").and_then(Value::py_int))
            };
            let tiers = (tier_of(tier1.pid), tier_of(tier2.pid));
            let outcomes = apply(mode, &table, &report.leftovers);
            let alive = (process_tree::matches(&tier1), process_tree::matches(&tier2));
            cleanup(&[tier1, tier2]);

            assert_eq!(tiers, (Some(1), Some(2)), "{mode:?}");
            match mode {
                Mode::Stop => {
                    assert_eq!(outcomes, vec![Stop::Terminated], "only Tier 1");
                    assert_eq!(alive, (false, true), "Tier 2 is left running");
                }
                _ => {
                    assert!(outcomes.is_empty(), "{mode:?}");
                    assert_eq!(alive, (true, true), "{mode:?} stops nothing");
                }
            }
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    fn named(args: &Args) -> bool {
        args.argv
            .last()
            .is_some_and(|arg| arg.ends_with("/services/orchestrator.py"))
    }

    #[test]
    fn the_stop_trace_passes_the_public_trace_rules() {
        let message = stop_message("rr-485", 380);
        let payload = crate::trace::orchestration_trace_payload(
            "run-reconciled",
            Some("rr-485"),
            Some(380),
            "orchestrator",
            Some(&message),
            None,
        )
        .expect("the trace builds");
        assert_eq!(
            payload.string("text"),
            "Stopped a leftover process of RR-485 run 380"
        );
    }

    #[test]
    fn worktree_rows_and_tier_2_are_not_targets() {
        let process = Process {
            pid: 4242,
            ppid: 1,
            pgid: 4242,
            uid: 501,
            start_us: 1_800_000_000_123_456,
            tty: false,
            args: None,
        };
        let entry = |kind: &str, tier: i64| {
            let mut entry = Dict::new();
            entry.insert("kind", kind);
            entry.insert("tier", tier);
            entry.insert("pid", 4242);
            entry.insert("run_id", 7);
            entry.insert("ticket_id", "CT-7");
            entry
        };
        let leftovers = vec![entry("worktree", 1), entry("process", 2)];
        assert!(targets(std::slice::from_ref(&process), &leftovers).is_empty());
        let found = targets(&[process], &[entry("process", 1)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].identity.start_sec, 1_800_000_000);
        assert_eq!(found[0].identity.start_usec, 123_456);
        assert_eq!(found[0].run_id, 7);
    }
}
