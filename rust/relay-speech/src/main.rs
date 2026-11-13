//! relay-speech: Relay Runner's speech service (RR-481).
//!
//! ```text
//! relay-speech [--socket <path>] [--config <path>]       the speech service
//! relay-speech tutorial [--config <path>]                 the onboarding voice, lines on stdin
//! relay-speech preview --voice <v> --text <t> --output <wav>
//! ```
//!
//! The service speaks docs/specs/speech-service-protocol.md, as
//! `services/speech_service.py` does. `tutorial` is the standalone mode of
//! `services/tts_worker.py` and `preview` is `services/preview_voice.py`.

mod audioqueue;
mod config;
mod coordinator;
mod intent;
mod kokoro;
mod player;
mod remote_audio;
mod sentences;
mod service;
mod sha256;
mod support;
mod synth;
mod testmode;
mod trim;
mod vocab;
mod voices;
mod worker;

use std::io::BufRead;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::audioqueue::AudioQueueOutput;
use crate::player::OutputFactory;
use crate::synth::{KokoroSynth, Synthesizer};
use crate::testmode::{NullOutput, PlaybackLog, SilenceSynth};
use crate::worker::TtsWorker;

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn request_stop(_signal: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn environment(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn parent_pid() -> i32 {
    // SAFETY: getppid has no preconditions.
    unsafe { libc::getppid() }
}

/// `--name value` pairs; anything else is a usage error, as argparse makes it.
fn options(args: &[String], allowed: &[&str]) -> Result<Vec<(String, String)>, String> {
    let mut parsed = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let (name, inline) = match arg.split_once('=') {
            Some((name, value)) => (name, Some(value.to_string())),
            None => (arg.as_str(), None),
        };
        let Some(name) = name
            .strip_prefix("--")
            .filter(|name| allowed.contains(name))
        else {
            return Err(format!("unrecognized argument: {arg}"));
        };
        let value = match inline {
            Some(value) => value,
            None => args
                .next()
                .cloned()
                .ok_or_else(|| format!("--{name} needs a value"))?,
        };
        parsed.push((name.to_string(), value));
    }
    Ok(parsed)
}

fn option<'a>(parsed: &'a [(String, String)], name: &str) -> Option<&'a str> {
    parsed
        .iter()
        .rev()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

fn usage(error: &str) -> ExitCode {
    eprintln!("relay-speech: {error}");
    eprintln!("usage: relay-speech [--socket PATH] [--config PATH]");
    eprintln!("       relay-speech tutorial [--config PATH]");
    eprintln!("       relay-speech preview --voice VOICE --text TEXT --output PATH");
    ExitCode::from(2)
}

fn config_path(parsed: &[(String, String)]) -> PathBuf {
    option(parsed, "config").map_or_else(config::default_config_path, PathBuf::from)
}

fn control_socket_path() -> PathBuf {
    PathBuf::from(environment("TTS_CONTROL_SOCK").unwrap_or_else(|| "/tmp/tts_control.sock".into()))
}

/// The worker of this process: Kokoro on an AudioQueue, or silence on a timer
/// in test mode.
fn build_worker(
    test_mode: bool,
    tutorial: bool,
    config_path: PathBuf,
    control_socket: Option<PathBuf>,
) -> Arc<TtsWorker> {
    let (synth, output_factory, test_log): (
        Arc<dyn Synthesizer>,
        Box<dyn FnOnce(_) -> OutputFactory>,
        _,
    ) = if test_mode {
        let log = Arc::new(PlaybackLog::new(
            environment("RELAY_SPEECH_TEST_PLAYBACK_LOG").map(PathBuf::from),
        ));
        let ms_per_char = environment("RELAY_SPEECH_TEST_MS_PER_CHAR")
            .and_then(|ms| ms.parse().ok())
            .unwrap_or(20.0);
        let output_log = log.clone();
        let factory: Box<dyn FnOnce(_) -> OutputFactory> = Box::new(move |_| {
            Box::new(move |format, rate, feed| {
                Ok(NullOutput::create(format, rate, feed, output_log.clone()))
            })
        });
        (
            Arc::new(SilenceSynth::new(log.clone(), ms_per_char)),
            factory,
            Some(log),
        )
    } else {
        // The tutorial voice never downloads the model, as in Python.
        let factory: Box<dyn FnOnce(_) -> OutputFactory> =
            Box::new(|_| Box::new(AudioQueueOutput::create));
        (Arc::new(KokoroSynth::load(!tutorial)), factory, None)
    };
    let worker = TtsWorker::new(worker::Options {
        synth,
        output_factory,
        config_path,
        tutorial,
        control_socket,
        test_log,
    });
    TtsWorker::install(&worker);
    worker
}

fn listen(path: &PathBuf) -> std::io::Result<UnixListener> {
    let _ = std::fs::remove_file(path);
    // The socket is never open to another user.
    // SAFETY: umask has no preconditions; the previous mask is restored.
    let previous = unsafe { libc::umask(0o177) };
    let listener = UnixListener::bind(path);
    // SAFETY: as above.
    unsafe { libc::umask(previous) };
    listener
}

fn serve(args: &[String]) -> ExitCode {
    let parsed = match options(args, &["socket", "config"]) {
        Ok(parsed) => parsed,
        Err(error) => return usage(&error),
    };
    let socket = PathBuf::from(
        option(&parsed, "socket")
            .map(str::to_string)
            .or_else(|| environment("RELAY_SPEECH_SERVICE_SOCK"))
            .unwrap_or_else(|| service::DEFAULT_SOCKET.into()),
    );
    let parent = parent_pid();
    for signal in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: the handler only stores to an atomic.
        unsafe { libc::signal(signal, request_stop as *const () as libc::sighandler_t) };
    }
    let listener = match listen(&socket) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!(
                "[relay_speech] Could not listen on {}: {error}",
                socket.display()
            );
            return ExitCode::from(1);
        }
    };
    let test_mode = environment("RELAY_SPEECH_TEST_MODE").as_deref() == Some("1");
    // The client may connect now; its hello is answered once the voice is loaded.
    let worker = build_worker(test_mode, false, config_path(&parsed), None);
    let done = service::Done::new();
    let service = service::SpeechService::new(
        worker,
        service::Settings {
            state_path: PathBuf::from(
                environment("VOICE_COMMAND_STATE_FILE")
                    .unwrap_or_else(|| "/tmp/voice_command_state.json".into()),
            ),
            event_log: Some(PathBuf::from(
                environment("SPEECH_EVENT_LOG")
                    .unwrap_or_else(|| "/tmp/relay_speech_events.jsonl".into()),
            )),
            control_socket: Some(control_socket_path()),
            test_mode,
        },
        done,
    );

    let mut conn = None;
    if listener.set_nonblocking(true).is_ok() {
        while conn.is_none() && !STOP.load(Ordering::SeqCst) && parent_pid() == parent {
            match listener.accept() {
                Ok((stream, _)) => conn = Some(stream),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    }
    // One client for the life of the process: the path is free again.
    drop(listener);
    let _ = std::fs::remove_file(&socket);
    let Some(conn) = conn else {
        service.close();
        return ExitCode::SUCCESS;
    };
    if conn.set_nonblocking(false).is_err() {
        service.close();
        return ExitCode::SUCCESS;
    }
    service.serve(conn, parent, &|| STOP.load(Ordering::SeqCst));
    ExitCode::SUCCESS
}

/// Standalone mode: lines from stdin are queued for speech, and `__PLAY__`,
/// `__REPLAY__` and `__CANCEL__` act on them, as `tts_worker.py` reads them.
fn tutorial(args: &[String]) -> ExitCode {
    let parsed = match options(args, &["config"]) {
        Ok(parsed) => parsed,
        Err(error) => return usage(&error),
    };
    let tutorial = environment("RELAY_TUTORIAL_TTS").as_deref() == Some("1");
    let control = control_socket_path();
    let worker = build_worker(false, tutorial, config_path(&parsed), Some(control.clone()));
    eprintln!(
        "[relay_speech] Voice: {}, Rate: {}",
        worker.voice(),
        worker.rate()
    );
    eprintln!("[relay_speech] Control: {}", control.display());
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        worker::queue_tutorial_line(&worker, line.trim_matches(sentences::is_py_space));
    }
    coordinator::Worker::shutdown(&*worker);
    ExitCode::SUCCESS
}

/// Render an isolated Settings preview WAV; the app owns cancellable playback.
fn preview(args: &[String]) -> ExitCode {
    let parsed = match options(args, &["voice", "text", "output"]) {
        Ok(parsed) => parsed,
        Err(error) => return usage(&error),
    };
    let (Some(voice), Some(text), Some(output)) = (
        option(&parsed, "voice"),
        option(&parsed, "text"),
        option(&parsed, "output"),
    ) else {
        return usage("--voice, --text and --output are required");
    };
    // Own a process group so Settings can cancel this process without touching a session.
    // SAFETY: setsid has no preconditions.
    unsafe { libc::setsid() };
    let parent = parent_pid();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_millis(250));
            if parent_pid() != parent {
                std::process::exit(130);
            }
        }
    });
    match render_preview(voice, text, &PathBuf::from(output)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("[relay_speech] {error}");
            ExitCode::from(1)
        }
    }
}

fn render_preview(voice: &str, text: &str, output: &std::path::Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let (model, voices) = kokoro::find_model().ok_or("Kokoro model not found")?;
    let kokoro = kokoro::Kokoro::load(&model, &voices)
        .map_err(|_| "Preview unavailable. Check local speech setup.")?;
    let samples = kokoro
        .create(text, voice)
        .map_err(|_| "Preview unavailable. Check local speech setup.")?;
    if samples.is_empty() {
        return Err("Synthesis returned no samples".into());
    }
    let audio = synth::Audio {
        samples: synth::to_pcm16(&samples)?,
        sample_rate: kokoro::SAMPLE_RATE,
    };
    synth::write_wav(output, &audio)
        .and_then(|()| std::fs::set_permissions(output, std::fs::Permissions::from_mode(0o600)))
        .map_err(|_| "Preview failed; check local speech setup.".to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("tutorial") => tutorial(&args[1..]),
        Some("preview") => preview(&args[1..]),
        _ => serve(&args),
    }
}
