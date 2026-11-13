//! The relay loop: the voice FIFO and Relay Remote items in one ordered
//! stream, the intent inbox pump and the TTS FIFO reader (`voice_bridge.py`
//! `ensure_fifo`, `open_fifo`, `_start_intent_inbox_pump`, `_tts_fifo_reader`
//! and `_run_relay`).

use std::ffi::CString;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::FileTypeExt;
use std::sync::LazyLock;
use std::thread;
use std::time::Duration;

use relay_intents::arbitration::{IntentRoute, WorkItemLifecycle};
use relay_intents::pattern::{self, Regex};

use super::authorization;
use super::commands::{self, PublishPaths};
use super::context::Bridge;
use super::controls;
use super::finals;
use super::orchestrator::{self, stop_persistent_orchestrator_lifecycle};
use super::remote_link::RemoteLink;
use super::replies;
use super::settings::settings;
use super::speech::{self, TtsOptions};
use super::store::{self, read_json_file};
use super::targets;
use super::traces;
use super::turns;
use crate::json::{self, Value};

pub const STARTUP_GREETING: &str = "Hello, what would you like to work on?";
const VOICE_TARGET_PREFIX: &str = "__VOICE_TARGET__:";

static SLASH_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^(?:slash|forward slash)\s+(.+)$", true));

/// `ensure_fifo`: a FIFO at `path`, replacing anything else there.
pub fn ensure_fifo(path: &str) -> bool {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_fifo() => return true,
        Ok(_) => {
            if let Err(error) = std::fs::remove_file(path) {
                eprintln!("[voice_bridge] Could not replace non-FIFO {path}: {error}");
                return false;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            eprintln!("[voice_bridge] Could not inspect FIFO {path}: {error}");
            return false;
        }
    }
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    // SAFETY: a valid NUL-terminated path.
    if unsafe { libc::mkfifo(c_path.as_ptr(), 0o666) } == 0 {
        return true;
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::AlreadyExists {
        return match std::fs::metadata(path) {
            Ok(metadata) => metadata.file_type().is_fifo(),
            Err(error) => {
                eprintln!("[voice_bridge] Could not inspect FIFO {path}: {error}");
                false
            }
        };
    }
    eprintln!("[voice_bridge] Could not create FIFO {path}: {error}");
    false
}

/// `open_fifo`: the FIFO opened non-blocking for reading.
fn open_fifo(path: &str) -> Option<i32> {
    if !ensure_fifo(path) {
        return None;
    }
    let c_path = CString::new(path).ok()?;
    // SAFETY: a valid NUL-terminated path.
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_NONBLOCK) };
    if fd < 0 {
        eprintln!(
            "[voice_bridge] Could not open FIFO {path}: {}",
            std::io::Error::last_os_error()
        );
        return None;
    }
    Some(fd)
}

fn close_fd(fd: i32) {
    // SAFETY: an fd this module opened.
    unsafe { libc::close(fd) };
}

/// `select.select(fds, [], [], timeout)`: the readable ones, or `Err`.
fn select_readable(fds: &[i32], timeout: Duration) -> Result<Vec<i32>, ()> {
    // SAFETY: fd_set is plain data; FD_ZERO/FD_SET/FD_ISSET act on it.
    unsafe {
        let mut set: libc::fd_set = std::mem::zeroed();
        libc::FD_ZERO(&mut set);
        let mut highest = -1;
        for &fd in fds {
            if !(0..libc::FD_SETSIZE as i32).contains(&fd) {
                return Err(());
            }
            libc::FD_SET(fd, &mut set);
            highest = highest.max(fd);
        }
        let mut timeval = libc::timeval {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_usec: timeout.subsec_micros() as libc::suseconds_t,
        };
        let ready = libc::select(
            highest + 1,
            &mut set,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut timeval,
        );
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(Vec::new());
            }
            return Err(());
        }
        Ok(fds.iter().copied().filter(|&fd| libc::FD_ISSET(fd, &set)).collect())
    }
}

/// What one `os.read` of the FIFO gave.
enum Read {
    Data(Vec<u8>),
    WouldBlock,
    Eof,
    Failed,
}

fn read_fd(fd: i32) -> Read {
    let mut buffer = [0u8; 4096];
    // SAFETY: reading into a local buffer of the given length.
    let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    match count {
        0 => Read::Eof,
        count if count > 0 => Read::Data(buffer[..count as usize].to_vec()),
        _ => {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                Read::WouldBlock
            } else {
                Read::Failed
            }
        }
    }
}

/// `_start_intent_inbox_pump`: app-owned and manual consumers on one ordered
/// inbox protocol.
fn start_intent_inbox_pump(bridge: &'static Bridge) {
    let settings = settings();
    bridge.sync_inbox_state(&settings.command_state_file);
    let _ = thread::Builder::new()
        .name("intent-inbox-pump".to_string())
        .spawn(move || {
            while !bridge.shutdown.is_set() {
                pump_once(bridge);
                bridge.shutdown.wait(0.05);
            }
        });
}

fn pump_once(bridge: &Bridge) {
    let settings = settings();
    let live = targets::live_voice_targets();
    let mailboxes: Vec<(String, String, Option<std::sync::Arc<targets::ProviderSessionOwnership>>, String)> =
        if live.is_empty() {
            vec![(
                settings.claim_file.clone(),
                settings.manual_ack_file.clone(),
                bridge.ownership.clone(),
                String::new(),
            )]
        } else {
            live.iter()
                .map(|target| {
                    (
                        target.claim_path.clone(),
                        target.manual_ack_path.clone(),
                        targets::voice_target_ownership(target),
                        target.provider_session_id.clone(),
                    )
                })
                .collect()
        };
    let Some(inbox) = bridge.inbox() else {
        return;
    };
    for (claim_file, ack_file, ownership, target_session_id) in mailboxes {
        let claimed = read_json_file(&claim_file);
        if !claimed.is_empty() {
            let provider_session_id = match &ownership {
                Some(ownership) => ownership.provider_session_id(),
                None if !target_session_id.is_empty() => target_session_id.clone(),
                None => turns::authoritative_provider_session_id(),
            };
            let scope = ownership.as_ref().map(|ownership| ownership.provider_turn_scope());
            let seen = turns::provider_turn_seen(
                Some(&claimed),
                &settings.provider_turns_file,
                Some(&provider_session_id),
                scope.as_ref(),
            );
            if let Err(error) = inbox.observe_claim(&claimed, seen, None) {
                eprintln!("[voice_bridge] Could not record the claim: {error}");
            }
        }
        let manual_ack = read_json_file(&ack_file);
        let claimed_ref = (!claimed.is_empty()).then_some(&claimed);
        let ack_ref = (!manual_ack.is_empty()).then_some(&manual_ack);
        if turns::manual_claim_ack_matches(claimed_ref, ack_ref)
            && inbox.observe_claim(&manual_ack, true, None).unwrap_or(false)
        {
            store::remove(&ack_file);
        }
    }
    if let Err(error) = inbox.reconcile_terminal_claims(None) {
        eprintln!("[voice_bridge] Could not reconcile terminal claims: {error}");
    }
    commands::materialize_next(&inbox, &settings.cmd_file, &settings.cmd_meta_file, "shared-ready-file");
    let _guard = store::voice_state_lock();
    if let Err(error) = store::sync_deliverable_state(&settings.command_state_file, &inbox) {
        eprintln!("[voice_bridge] Could not sync intent inbox state: {error}");
    }
}

/// `_tts_fifo_reader`: lines other processes ask to be spoken.
fn start_tts_fifo_reader(bridge: &'static Bridge) {
    let _ = thread::Builder::new().name("tts-fifo-reader".to_string()).spawn(move || {
        while !bridge.shutdown.is_set() {
            match File::open(&settings().tts_in_fifo) {
                Ok(file) => {
                    for line in BufReader::new(file).split(b'\n') {
                        if bridge.shutdown.is_set() {
                            break;
                        }
                        let Ok(line) = line else { break };
                        let text = String::from_utf8_lossy(&line);
                        speech::queue_tts_text(bridge.speech(), &text, TtsOptions::default());
                    }
                }
                Err(_) => {
                    if !bridge.shutdown.is_set() {
                        thread::sleep(Duration::from_millis(200));
                    }
                }
            }
        }
    });
}

/// `_record_bridge_readiness`.
pub fn record_bridge_readiness(outcome: &str) {
    let provider = crate::support::env_text("RELAY_RUNNER_PROVIDER");
    let provider = matches!(provider.as_str(), "codex" | "claude").then_some(provider.as_str());
    super::diagnostics::record_event("shell", "bridge_readiness", outcome, provider);
}

/// One input the loop handles: a FIFO line, or a Relay Remote item.
struct Entry {
    text: String,
    remote: Option<super::remote_link::RemoteItem>,
}

/// `_run_relay`: write voice commands for the active agent and read speech
/// from the TTS FIFO. `false` when the bridge could not start.
pub fn run_relay(bridge: &'static Bridge, suppress_startup_greeting: bool, remote: Option<&RemoteLink>) -> bool {
    let settings = settings();
    let mut suppress_next_messenger_user_reply = suppress_startup_greeting;
    let watchdog_restart = store::watchdog_restart_preserves_turns(false);
    let mut cleanup = vec![
        settings.tts_in_fifo.clone(),
        settings.cmd_file.clone(),
        settings.cmd_meta_file.clone(),
        settings.manual_ack_file.clone(),
    ];
    if !watchdog_restart {
        cleanup.push(settings.claim_file.clone());
        cleanup.push(settings.provider_turns_file.clone());
    }
    if crate::support::env_or("RELAY_CONTINUITY_RECOVERY_PENDING", "") != "1" && !watchdog_restart {
        cleanup.push(settings.command_state_file.clone());
    }
    if crate::support::env_or("RELAY_PRESERVE_CONTEXT_AUTHORIZATION", "") != "1" {
        cleanup.push(settings.authorization_file.clone());
    }
    for path in &cleanup {
        store::remove(path);
    }
    if !ensure_fifo(&settings.tts_in_fifo) {
        return false;
    }
    if targets::startup_key().is_none() {
        targets::install_startup_voice_target(bridge.ownership.clone());
    }
    if bridge.inbox.is_some() {
        start_intent_inbox_pump(bridge);
        if let Some(sidecar) = bridge.sidecar() {
            let pending = bridge
                .inbox()
                .and_then(|inbox| inbox.pending_for_route(IntentRoute::RunSidecar.as_str()).ok())
                .unwrap_or_default();
            for work in pending {
                let Some(metadata) = work.metadata.as_dict() else {
                    continue;
                };
                {
                    // The lock order everywhere: inbox, then command state.
                    let inbox = bridge.inbox();
                    let _guard = store::voice_state_lock();
                    let _ = store::write_command_state(&settings.command_state_file, metadata);
                    if let Some(inbox) = &inbox {
                        let _ = store::sync_deliverable_state(&settings.command_state_file, inbox);
                    }
                }
                let source = match metadata.truthy("source_text") {
                    Some(value) => value.py_str(),
                    None => work.prompt.clone(),
                };
                sidecar.submit(&source, metadata);
            }
        }
    }
    if !suppress_startup_greeting {
        speech::queue_tts_text(
            bridge.speech(),
            STARTUP_GREETING,
            TtsOptions {
                allow_pending_command: true,
                ..TtsOptions::default()
            },
        );
    }
    start_tts_fifo_reader(bridge);
    eprintln!("[voice_bridge] Relay mode — waiting for voice input...");
    eprintln!("[voice_bridge] Voice commands → {}", settings.cmd_file);
    eprintln!("[voice_bridge] TTS input ← {}", settings.tts_in_fifo);

    let Some(mut fifo_fd) = open_fifo(&settings.voice_fifo) else {
        targets::clear_voice_targets();
        return false;
    };
    record_bridge_readiness("ready");
    if let Some(remote) = remote {
        remote.set_attached(true);
    }
    let mut fifo_buffer: Vec<u8> = Vec::new();
    // The session focused when the current recording started; it receives
    // the transcript even if focus moves first (RR-398).
    let mut pinned_target_key: Option<String> = None;
    while !bridge.shutdown.is_set() {
        let mut read_fds = vec![fifo_fd];
        if let Some(remote) = remote {
            read_fds.push(remote.fileno());
        }
        let readable = match select_readable(&read_fds, Duration::from_millis(200)) {
            Ok(readable) => readable,
            Err(()) => {
                close_fd(fifo_fd);
                match open_fifo(&settings.voice_fifo) {
                    Some(fd) => fifo_fd = fd,
                    None => break,
                }
                continue;
            }
        };
        if readable.contains(&fifo_fd) {
            match read_fd(fifo_fd) {
                Read::Data(data) => fifo_buffer.extend_from_slice(&data),
                Read::WouldBlock => {}
                Read::Eof | Read::Failed => {
                    close_fd(fifo_fd);
                    match open_fifo(&settings.voice_fifo) {
                        Some(fd) => fifo_fd = fd,
                        None => break,
                    }
                    continue;
                }
            }
        }
        let mut entries: Vec<Entry> = Vec::new();
        while let Some(position) = fifo_buffer.iter().position(|&byte| byte == b'\n') {
            let line: Vec<u8> = fifo_buffer.drain(..=position).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]);
            entries.push(Entry {
                text: json::py_strip(&text).to_string(),
                remote: None,
            });
        }
        if let Some(remote) = remote
            && readable.contains(&remote.fileno())
        {
            entries.extend(remote.drain().into_iter().map(|item| Entry {
                text: item.text.clone(),
                remote: Some(item),
            }));
        }
        for entry in entries {
            handle_entry(bridge, entry, remote, &mut pinned_target_key, &mut suppress_next_messenger_user_reply);
        }
    }
    if let Some(remote) = remote {
        remote.set_attached(false);
    }
    close_fd(fifo_fd);
    for lifecycle in targets::clear_voice_targets() {
        stop_persistent_orchestrator_lifecycle(&lifecycle, "bridge stopped");
    }
    let preserved: Vec<&String> = if store::watchdog_restart_preserves_turns(true) {
        vec![&settings.command_state_file, &settings.claim_file, &settings.provider_turns_file]
    } else {
        Vec::new()
    };
    let mut removed = vec![
        &settings.tts_in_fifo,
        &settings.cmd_file,
        &settings.cmd_meta_file,
        &settings.command_state_file,
        &settings.claim_file,
        &settings.manual_ack_file,
        &settings.provider_turns_file,
    ];
    if settings.mirrored_command_state_file.is_some() {
        removed.push(&settings.legacy_command_state_file);
    }
    for path in removed {
        if !preserved.contains(&path) {
            store::remove(path);
        }
    }
    true
}

fn handle_entry(
    bridge: &'static Bridge,
    entry: Entry,
    remote: Option<&RemoteLink>,
    pinned_target_key: &mut Option<String>,
    suppress_next_messenger_user_reply: &mut bool,
) {
    let settings = settings();
    let mut text = entry.text;
    if text.is_empty() {
        return;
    }
    if entry.remote.is_none()
        && let Some(key) = text.strip_prefix(VOICE_TARGET_PREFIX)
    {
        let key = json::py_strip(key);
        *pinned_target_key = (!key.is_empty()).then(|| key.to_string());
        return;
    }
    if text == "__CANCEL__" {
        *pinned_target_key = None;
    }
    if controls::handle_relay_control_message(bridge, &text, &PublishPaths::default()) {
        return;
    }
    if let Some(rest) = pattern::group(&SLASH_RE, &text, 1) {
        text = format!("/{}", rest.replace(' ', "-"));
    }
    let voice_target = if entry.remote.is_none() {
        let pinned = pinned_target_key.take().unwrap_or_default();
        targets::voice_target_for(&pinned).or_else(targets::current_voice_target)
    } else {
        targets::current_voice_target()
    };
    let target_repo = match &voice_target {
        Some(target) => target.cwd.clone(),
        None => store::current_dir(),
    };
    let target_orchestrator = targets::voice_target_orchestrator(voice_target.as_ref(), bridge.orchestrator());
    let mut relay_command = match &entry.remote {
        None => commands::begin_relay_command(&text, &settings.command_state_file, None, None),
        Some(item) => {
            let device_id = Value::from(item.device_id.as_str());
            let command = commands::begin_relay_command(
                &text,
                &settings.command_state_file,
                Some(super::remote_link::INPUT_SOURCE),
                Some(&device_id),
            );
            if let Some(remote) = remote {
                remote.accept(item, &command);
            }
            command
        }
    };
    let received_at = relay_command.get("received_at").and_then(Value::py_float);
    speech::record_messenger_stage(bridge.speech(), "user_turn_received", &relay_command, received_at, "ok");
    replies::sweep_outcome_watches(bridge.speech(), &settings.provider_turns_file, None);
    replies::watch_command_outcome(Some(&relay_command));
    if let Some((seq, id)) = store::relay_command_key(&relay_command) {
        bridge.speech().new_turn(seq, &id);
    }
    let should_submit = !*suppress_next_messenger_user_reply;
    *suppress_next_messenger_user_reply = false;
    if should_submit {
        let submitted = bridge
            .messenger()
            .is_some_and(|messenger| messenger.submit_user(&text, &relay_command));
        if !submitted && bridge.messenger_expected {
            speech::record_messenger_stage(
                bridge.speech(),
                "messenger_unavailable",
                &relay_command,
                None,
                "foreground_delivery_preserved",
            );
            speech::queue_messenger_degraded(bridge.speech(), &relay_command, super::messenger_runtime::MESSENGER_DEGRADED_TEXT);
        }
    }
    let active = commands::active_work(&settings.provider_turns_file, Some(&target_repo));
    let foreground_active = turns::any_provider_turn_active(&settings.provider_turns_file, None);
    let resolved = commands::resolve_voice_work_items(&text, &relay_command, &target_repo, &active, foreground_active);
    relay_command.insert(
        "voice_work_items",
        Value::List(resolved.iter().map(|item| Value::Dict(item.item.to_dict())).collect()),
    );
    relay_command.insert(
        "intent_qualifications",
        Value::List(
            resolved
                .iter()
                .filter_map(|item| item.metadata.get("intent_qualification").filter(|value| value.as_dict().is_some()))
                .cloned()
                .collect(),
        ),
    );
    if let Some(last) = resolved.last() {
        relay_command.insert("work_disposition", last.disposition.to_dict());
    }
    if should_submit && let Some(messenger) = bridge.messenger() {
        messenger.update_user_context(&relay_command);
    }
    traces::queue_voice_acknowledgement(&relay_command, Some(&text), bridge.inbox.is_none());
    for resolved_item in resolved {
        let commands::ResolvedItem {
            item,
            action,
            disposition,
            mut metadata,
            prompt,
        } = resolved_item;
        if let Some(target) = &voice_target {
            metadata.insert("voice_target_session_key", target.session_key.as_str());
            if !target.provider.is_empty() {
                metadata.insert("provider", target.provider.as_str());
            }
        }
        store::record_command_action_state(&metadata, "classified");
        let cancelled = item.lifecycle_state == WorkItemLifecycle::Cancelled;
        let allowed = if cancelled {
            Vec::new()
        } else {
            authorization::allowed_mutations_for_metadata(&metadata)
        };
        if let Err(error) = authorization::record_command_authorization(
            &settings.authorization_file,
            &metadata,
            &metadata.string("authorization_relationship"),
            Some(allowed),
            &targets::authorization_session_key(&metadata),
            None,
        ) {
            eprintln!("[voice_bridge] Could not record Relay mutation authorization: {error}");
        }
        if cancelled && bridge.inbox.is_none() {
            store::record_command_action_state(&metadata, "cancelled");
            continue;
        }
        if disposition.route == IntentRoute::RunSidecar {
            let accepted = !cancelled
                && bridge.sidecar().is_some()
                && commands::enqueue_sidecar_intent(
                    bridge,
                    &prompt,
                    &item.source_text,
                    &metadata,
                    &settings.command_state_file,
                );
            if !accepted && !cancelled {
                finals::handle_sidecar_lifecycle(bridge, "failed", &disposition.public_reason, &metadata);
                finals::handle_sidecar_final(
                    bridge,
                    "The independent read-only task could not enter its bounded sidecar lane.",
                    &metadata,
                );
            }
            eprintln!(
                "[voice_bridge] Sidecar {} for intent={}",
                if accepted { "accepted" } else { "rejected" },
                disposition.intent_id
            );
            continue;
        }
        if !cancelled && commands::should_fanout_raw_instruction_to_orchestrator(&action) {
            commands::fanout_raw_instruction_to_orchestrator(
                item.source_text.clone(),
                metadata.clone(),
                action.clone(),
                Some(target_repo.clone()),
                target_orchestrator.clone(),
                settings.command_state_file.clone(),
            );
        }
        if !cancelled {
            orchestrator::start_pm_update_mode(
                bridge,
                &metadata,
                &action.kind,
                target_orchestrator.clone(),
                &item.source_text,
            );
        }
        let paths = PublishPaths {
            command_path: voice_target
                .as_ref()
                .map(|target| target.command_path.clone())
                .unwrap_or_else(|| settings.cmd_file.clone()),
            meta_path: voice_target
                .as_ref()
                .map(|target| target.meta_path.clone())
                .unwrap_or_else(|| settings.cmd_meta_file.clone()),
            state_path: settings.command_state_file.clone(),
            authorization_path: Some(settings.authorization_file.clone()),
            transport: if bridge.inbox.is_some() {
                "app-or-manual-shared-ready-file"
            } else {
                "legacy-ready-file"
            }
            .to_string(),
        };
        {
            let inbox = bridge.inbox();
            commands::publish_command(&prompt, &metadata, &paths, inbox.as_deref());
        }
        if !cancelled && let Some(inbox) = bridge.inbox() {
            commands::announce_voice_paused(bridge, &inbox, &metadata, &settings.command_state_file);
        }
        let state = if cancelled { "cancelled" } else { "queued" };
        store::record_command_action_state(&metadata, state);
        eprintln!(
            "[voice_bridge] Voice item ready: {} intent={} order={} disposition={} state={state}",
            action.outcome,
            item.intent_id,
            item.within_turn_order,
            disposition.route.as_str()
        );
    }
}
