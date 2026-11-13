//! `voice_bridge.py` `main()` in relay mode: every collaborator started in
//! the Python order, the relay loop run, and everything stopped again
//! (`_parse_args`, `_speech_service_command`, `_start_speech_service`).

use std::sync::{Arc, OnceLock};
use std::thread;

use relay_intents::broker::ProviderTurnBroker;
use relay_intents::inbox::{InboxOptions, IntentInbox};
use relay_intents::model::normalize_recovery_generation;

use super::config;
use super::context::Bridge;
use super::control_socket;
use super::finals;
use super::messenger_runtime;
use super::orchestrator::{self, LocalDaemon};
use super::ports::{Event, Messenger, Speech};
use super::relay;
use super::remote_link::RemoteLink;
use super::settings::settings;
use super::sidecar::{SidecarLane, create_sidecar_executor};
use super::speech::{self, TtsOptions};
use super::speech_client::{SpeechServiceClient, publish_idle};
use super::store;
use super::targets::{self, ProviderSessionOwnership, StartOrchestrator, StopOrchestrator};
use crate::json::{Dict, Value};
use crate::messenger::config::shlex_split;
use crate::support::{env_or, env_text};

/// `_parse_args`.
#[derive(Default)]
struct Arguments {
    relay: bool,
    suppress_startup_greeting: bool,
    config: Option<String>,
}

fn parse_args(arguments: &[String]) -> Arguments {
    let mut parsed = Arguments::default();
    for (index, argument) in arguments.iter().enumerate() {
        match argument.as_str() {
            "--relay" => parsed.relay = true,
            "--suppress-startup-greeting" => parsed.suppress_startup_greeting = true,
            "--config" if index + 1 < arguments.len() && parsed.config.is_none() => {
                parsed.config = Some(arguments[index + 1].clone());
            }
            _ => {}
        }
    }
    parsed
}

/// The speech service `services/speech_service.py` the app bundle ships
/// beside this binary (`Contents/SharedSupport/services`), or the source
/// tree's when relay-rs runs from `rust/target`.
fn default_speech_service_script() -> Option<String> {
    let executable = std::env::current_exe().ok()?;
    let mut folder = executable.parent()?.to_path_buf();
    let bundled = folder.join("../SharedSupport/services/speech_service.py");
    if bundled.is_file() {
        return Some(bundled.to_string_lossy().into_owned());
    }
    while folder.pop() {
        let candidate = folder.join("services/speech_service.py");
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// `_speech_service_command`: `RELAY_SPEECH_SERVICE_CMD`, else `python3`
/// with the shipped `speech_service.py`, given the bridge's `--config`.
fn speech_service_command(config_path: Option<&str>) -> Option<Vec<String>> {
    let configured = env_text("RELAY_SPEECH_SERVICE_CMD");
    let mut command = if configured.is_empty() {
        vec!["python3".to_string(), default_speech_service_script()?]
    } else {
        shlex_split(&configured)?
    };
    if let Some(path) = config_path {
        command.push("--config".to_string());
        command.push(path.to_string());
    }
    Some(command)
}

/// `_start_speech_service`. The Rust bridge has no in-process speech, so
/// `None` stops it.
fn start_speech_service(config_path: Option<&str>) -> Option<Arc<SpeechServiceClient>> {
    let Some(command) = speech_service_command(config_path) else {
        eprintln!("[voice_bridge] Speech service unavailable: no speech service command");
        return None;
    };
    let settings = settings();
    let client = Arc::new(SpeechServiceClient::new(
        command,
        &settings.speech_service_sock,
        vec![
            // The service judges a command's freshness from the same file.
            ("VOICE_COMMAND_STATE_FILE".to_string(), settings.command_state_file.clone()),
            ("SPEECH_EVENT_LOG".to_string(), settings.speech_event_log.clone()),
            ("TTS_CONTROL_SOCK".to_string(), settings.tts_control_sock.clone()),
        ],
        Box::new(|_reason: &str| targets::on_reply_finished()),
        Box::new(publish_idle),
    ));
    if let Err(error) = client.start() {
        eprintln!("[voice_bridge] Speech service unavailable: {error}");
        return None;
    }
    Some(client)
}

/// The intent inbox and, unless the broker is `legacy`, the provider-turn
/// broker over it, with start-up retirement of stale and ended work.
fn open_inbox() -> Result<(IntentInbox, Option<ProviderTurnBroker>, Option<String>), String> {
    let settings = settings();
    let projection =
        (settings.broker_mode != "legacy").then(|| settings.provider_turn_projection_file.clone());
    let inbox = IntentInbox::open(
        &settings.intent_inbox,
        InboxOptions {
            provider_turn_projection_path: projection.clone(),
            hold_recovered_delivery: env_or("RELAY_CONTINUITY_RECOVERY_PENDING", "") == "1",
            ..InboxOptions::default()
        },
    )
    .map_err(|error| error.to_string())?;
    let generation = env_or("RELAY_RECOVERY_GENERATION", "");
    if !generation.is_empty() {
        // Other live sessions on this shared inbox keep their own work.
        inbox
            .retire_stale_foreground(
                &generation,
                &settings.cmd_file,
                &settings.cmd_meta_file,
                None,
                Some(&targets::startup_voice_session_key()),
            )
            .map_err(|error| error.to_string())?;
    }
    // RR-447: an ended session's queued work never reaches a new session.
    inbox
        .retire_ended_sessions(targets::session_spool_is_live)
        .map_err(|error| error.to_string())?;
    let broker = match &projection {
        Some(path) => {
            let broker = ProviderTurnBroker::open(&settings.intent_inbox, Some(path))
                .map_err(|error| error.to_string())?;
            broker.project().map_err(|error| error.to_string())?;
            Some(broker)
        }
        None => None,
    };
    Ok((inbox, broker, projection))
}

/// The foreground provider session's ownership, when all four identities
/// are known.
fn provider_session_ownership() -> Option<Arc<ProviderSessionOwnership>> {
    let provider_session_id = settings().provider_session_id.clone();
    let provider = env_text("RELAY_RUNNER_PROVIDER");
    let app_session_id = env_text("RELAY_APP_SESSION_ID");
    let recovery_generation = env_text("RELAY_RECOVERY_GENERATION");
    [&provider_session_id, &provider, &app_session_id, &recovery_generation]
        .iter()
        .all(|value| !value.is_empty())
        .then(|| {
            Arc::new(ProviderSessionOwnership::new(
                &provider_session_id,
                &provider,
                &app_session_id,
                &recovery_generation,
            ))
        })
}

/// The messenger's `speak`: its speech through `_queue_tts_text`.
fn messenger_speak(
    speech: &dyn Speech,
    text: &str,
    command_seq: Option<i64>,
    command_id: Option<&str>,
    display_text: Option<&str>,
    metadata: &Dict,
) -> bool {
    let mut payload = Dict::new();
    payload.insert("text", text);
    payload.insert("display_text", display_text);
    payload.insert("relay_command_seq", command_seq);
    payload.insert("relay_command_id", command_id);
    let mut options = TtsOptions {
        allow_pending_command: true,
        ..TtsOptions::default()
    };
    options.apply_metadata(metadata);
    speech::queue_tts_text(speech, &crate::json::dumps(&Value::Dict(payload)), options)
}

/// Runs the bridge; the process exit status.
pub fn run(arguments: &[String]) -> u8 {
    let cli = parse_args(arguments);
    if !cli.relay {
        // Legacy direct mode is Claude-only debugging and stays in Python.
        eprintln!("[voice_bridge] relay-rs bridge runs only in --relay mode");
        return 2;
    }
    let cfg = match config::load_config(cli.config.as_deref()) {
        Ok(cfg) => cfg,
        Err(error) => {
            eprintln!("[voice_bridge] Could not load the config: {}", error.0);
            return 1;
        }
    };
    let settings = settings();
    if !relay::ensure_fifo(&settings.voice_fifo) {
        return 1;
    }
    store::write_bridge_pid_file();
    let status = run_relay_mode(&cli, cfg);
    store::remove_bridge_pid_file();
    status
}

fn run_relay_mode(cli: &Arguments, cfg: Dict) -> u8 {
    let settings = settings();
    let Some(speech) = start_speech_service(cli.config.as_deref()) else {
        return 1;
    };
    let (inbox, broker, projection) = match open_inbox() {
        Ok(opened) => opened,
        Err(error) => {
            eprintln!("[voice_bridge] Could not open the intent inbox: {error}");
            speech.shutdown();
            return 1;
        }
    };
    let shutdown = Arc::new(Event::default());
    let ownership = provider_session_ownership();
    targets::lock().provider_session_ownership = ownership.clone();
    let generation = env_or("RELAY_RECOVERY_GENERATION", "");
    let generation = if generation.is_empty() { "0".to_string() } else { generation };
    let recovery_generation =
        normalize_recovery_generation(&Value::from(generation.as_str())).unwrap_or(generation);
    let messenger_expected = cfg
        .get("general")
        .and_then(Value::as_dict)
        .and_then(|general| general.get("messenger_enabled"))
        .is_none_or(Value::truthy);
    let speech_port: Arc<dyn Speech> = speech.clone();
    let bridge: &'static Bridge = Box::leak(Box::new(Bridge::new(
        cfg,
        speech_port,
        Some(inbox),
        broker,
        projection,
        ownership.clone(),
        Arc::clone(&shutdown),
        recovery_generation,
        messenger_expected,
    )));
    // Register before the control socket so an early __FOCUS__ is not lost.
    targets::install_startup_voice_target(ownership);
    let control = match control_socket::bind() {
        Ok(socket) => socket,
        Err(error) => {
            eprintln!("[voice_bridge] Could not bind the control socket: {error}");
            speech.shutdown();
            return 1;
        }
    };
    let _ = thread::Builder::new()
        .name("bridge-control-socket".to_string())
        .spawn(move || control_socket::serve(bridge, control));

    let orchestrator_session = orchestrator::start_persistent_orchestrator_lifecycle(
        &bridge.cfg,
        Arc::clone(&shutdown),
        None,
        &settings.command_event_log,
        Arc::new(LocalDaemon),
    );
    bridge.set_orchestrator(orchestrator_session.clone());
    let start: StartOrchestrator = Arc::new(move |target| {
        orchestrator::start_target_orchestrator(&bridge.cfg, target, Arc::new(LocalDaemon))
    });
    let stop: StopOrchestrator = Arc::new(|session| {
        orchestrator::stop_persistent_orchestrator_lifecycle(Some(&session), "voice session ended", &LocalDaemon)
    });
    let _ = bridge.start_target_orchestrator.set(start);
    let _ = bridge.stop_target_orchestrator.set(stop);

    let messenger = start_messenger(bridge);
    bridge.set_messenger(messenger.clone());
    orchestrator::surface_recoverable_command_status(
        orchestrator_session.as_deref(),
        bridge.messenger(),
        &|state: &str, fields: Dict| store::notify_state(state, fields),
    );
    match SidecarLane::new(
        create_sidecar_executor(&bridge.cfg, &store::current_dir()),
        Box::new(move |event| {
            finals::handle_sidecar_lifecycle(bridge, event.phase, &event.public_summary, &event.command);
        }),
        Box::new(move |text, command| {
            finals::handle_sidecar_final(bridge, text, command);
        }),
    ) {
        Ok(lane) => bridge.set_sidecar(Arc::new(lane)),
        Err(error) => eprintln!("[voice_bridge] Could not start the sidecar lane: {error}"),
    }
    orchestrator::start_messenger_outcome_polling(
        orchestrator_session.clone(),
        messenger.clone(),
        Arc::clone(&shutdown),
        Arc::new(LocalDaemon),
    );
    let remote = RemoteLink::start(speech.clone());

    let completed = relay::run_relay(bridge, cli.suppress_startup_greeting, remote.as_deref());

    shutdown.set();
    if let Some(remote) = &remote {
        remote.close();
    }
    if let Some(sidecar) = bridge.sidecar() {
        sidecar.shutdown();
    }
    if let Some(messenger) = &messenger {
        messenger.shutdown();
    }
    orchestrator::stop_persistent_orchestrator_lifecycle(orchestrator_session.as_deref(), "bridge stopped", &LocalDaemon);
    speech.shutdown();
    store::remove(&settings.control_sock);
    if completed {
        0
    } else {
        eprintln!("[voice_bridge] voice bridge initialization failed");
        1
    }
}

/// `create_messenger_runtime(...)` with the bridge's speech, freshness and
/// observers, started.
fn start_messenger(bridge: &'static Bridge) -> Option<Arc<dyn Messenger>> {
    static SPEECH: OnceLock<()> = OnceLock::new();
    let _ = SPEECH.set(());
    let runtime = messenger_runtime::create_messenger_runtime(
        &bridge.cfg,
        &store::current_dir(),
        messenger_runtime::Callbacks {
            speak: Box::new(move |text, command_seq, command_id, display_text, metadata| {
                messenger_speak(bridge.speech(), text, command_seq, command_id, display_text, metadata)
            }),
            is_current: Box::new(move |command_seq, command_id| {
                super::turns::key_current(command_seq, command_id, &settings().command_state_file)
            }),
            coverage_provider: Box::new(move |command_seq, command_id| {
                bridge.speech().played_coverage(command_seq, command_id)
            }),
            realization_observer: Box::new(move |realization| bridge.speech().record_realization(realization)),
            timing_observer: Box::new(move |stage, command_seq, command_id, at, provider, outcome| {
                bridge
                    .speech()
                    .record_messenger_stage(stage, command_seq, command_id, at, provider, outcome)
            }),
            continuity_observer: Box::new(|event: &Dict| {
                orchestrator::post_continuity_event(
                    "messenger",
                    &event.string("event"),
                    Some(event),
                    None,
                    &LocalDaemon,
                );
            }),
        },
    )?;
    runtime.start();
    Some(runtime)
}
