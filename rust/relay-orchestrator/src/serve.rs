//! `main()` and `serve(daemon)`: bind, write the port file, run the
//! background loops, and stop cleanly on SIGTERM or SIGINT.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::{Duration, Instant};

use crate::daemon::{Daemon, load_config};
use crate::http;

static STOP: AtomicBool = AtomicBool::new(false);
static SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(signal: libc::c_int) {
    SIGNAL.store(signal, Ordering::SeqCst);
    STOP.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    for signal in [libc::SIGINT, libc::SIGTERM] {
        // SAFETY: the handler only stores into atomics, which is
        // async-signal-safe.
        unsafe {
            libc::signal(
                signal,
                on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t,
            );
        }
    }
}

/// `stop.wait(seconds)`: false once the daemon is stopping.
fn wait(seconds: f64) -> bool {
    let deadline = Instant::now() + Duration::from_secs_f64(seconds.max(0.0));
    while Instant::now() < deadline {
        if STOP.load(Ordering::Acquire) {
            return false;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        std::thread::sleep(left.min(Duration::from_millis(100)));
    }
    !STOP.load(Ordering::Acquire)
}

fn spawn_loop(name: &str, body: impl FnOnce() + Send + 'static) {
    if let Err(error) = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(body)
    {
        eprintln!("[orchestrator] could not start {name}: {error}");
    }
}

fn write_port_file(daemon: &Daemon, port: u16) {
    if let Err(error) = std::fs::write(&daemon.paths.port_file, port.to_string()) {
        eprintln!(
            "[orchestrator] could not write port file {}: {error}",
            daemon.paths.port_file.display()
        );
    }
}

/// `serve(daemon)`.
pub fn serve(daemon: Arc<Daemon>) -> std::io::Result<()> {
    let (listener, port) = http::bind(daemon.port())?;
    *crate::daemon::guard(&daemon.port) = port;
    write_port_file(&daemon, port);
    eprintln!("[orchestrator] listening on http://127.0.0.1:{port}");
    install_signal_handlers();

    let owner = daemon.clone();
    spawn_loop("runs-index-pruner", move || {
        while wait(30.0) {
            owner.runs.write_index();
        }
    });
    let owner = daemon.clone();
    spawn_loop("orchestrator-command-loop", move || {
        while wait(2.0) {
            if let Err(error) = owner.process_orchestrator_commands(10) {
                eprintln!("[orchestrator] command processing loop failed: {error}");
            }
        }
    });
    let owner = daemon.clone();
    let interval = std::env::var("CONTINUITY_SAMPLE_INTERVAL_SECONDS")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .unwrap_or(1.0)
        .max(0.1);
    spawn_loop("continuity-incident-sampler", move || {
        while wait(interval) {
            if let Err(error) = owner.sample_continuity() {
                eprintln!("[orchestrator] continuity sampler failed: {error}");
            }
        }
    });
    let owner = daemon.clone();
    spawn_loop("queue-drain-monitor", move || {
        while wait(crate::queue::QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS) {
            if let Err(error) = owner.reconcile_queue_drains(None, Some("queue-drain-monitor")) {
                eprintln!("[orchestrator] queue-drain monitor failed: {error}");
            }
        }
    });
    let owner = daemon.clone();
    spawn_loop("ticket-retention", move || {
        crate::board::retention_loop(&owner, &wait);
    });
    let owner = daemon.clone();
    spawn_loop("stale-worktree-sweep", move || {
        crate::worktree_gc::sweep_loop(&owner, &wait);
    });
    let owner = daemon.clone();
    spawn_loop("personal-file-storage", move || {
        while wait(60.0) {
            let connected = owner
                .personal_storage
                .status()
                .map(|status| status.get("connected").is_some_and(|value| value.truthy()));
            let result = match connected {
                Ok(true) => owner
                    .personal_storage
                    .sync(&relay_intents::json::Value::Bool(false), None)
                    .map(|_| ()),
                Ok(false) => Ok(()),
                Err(error) => Err(error),
            };
            if let Err(error) = result {
                eprintln!("[orchestrator] personal storage retry failed: {error}");
            }
        }
    });

    let handler_owner = daemon.clone();
    let handler: Arc<http::Handler> =
        Arc::new(move |request| crate::router::route(&handler_owner, request));
    let served = http::serve(listener, handler, &STOP);
    let signal = SIGNAL.load(Ordering::SeqCst);
    if signal != 0 {
        eprintln!("[orchestrator] caught signal {signal}, shutting down");
    }
    daemon.shutdown();
    let _ = std::fs::remove_file(&daemon.paths.port_file);
    eprintln!("[orchestrator] stopped");
    served
}

const USAGE: &str = "usage: relay-orchestrator [--config <path>] [--print-port]";

/// The process entry point; the exit status.
pub fn main(arguments: &[String]) -> u8 {
    let mut config_path: Option<PathBuf> = None;
    let mut print_port = false;
    let mut rest = arguments.iter();
    while let Some(argument) = rest.next() {
        match argument.as_str() {
            "--config" => match rest.next() {
                Some(path) => config_path = Some(PathBuf::from(path)),
                None => {
                    eprintln!("{USAGE}\nrelay-orchestrator: --config needs a path");
                    return 2;
                }
            },
            "--print-port" => print_port = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                return 0;
            }
            other => {
                eprintln!("{USAGE}\nrelay-orchestrator: unrecognized argument {other}");
                return 2;
            }
        }
    }
    let config = match load_config(config_path.as_deref()) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("[orchestrator] could not load the configuration: {error}");
            return 1;
        }
    };
    let daemon = match Daemon::new(config) {
        Ok(daemon) => daemon,
        Err(error) => {
            eprintln!("[orchestrator] could not start: {error}");
            return 1;
        }
    };
    if print_port {
        println!("{}", daemon.port());
    }
    match serve(daemon) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("[orchestrator] server failed: {error}");
            1
        }
    }
}
