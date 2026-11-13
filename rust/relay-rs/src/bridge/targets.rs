//! Voice targets: every live app session the one bridge serves, the focused
//! one, and the provider-session ownership that authorizes a replacement
//! provider (RR-398, RR-401, RR-465, RR-488).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::thread;

use relay_intents::pattern::{self, Regex};

use super::orchestrator::OrchestratorSession;
use super::settings::{basename, dirname, normpath, settings};
use super::store;
use crate::json::{Dict, Value};

/// `_RELAY_SESSION_KEY_RE`, matched in full.
static RELAY_SESSION_KEY_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile_full(r"[a-z0-9-]{1,64}", false));

pub fn valid_session_key(key: &str) -> bool {
    pattern::search(&RELAY_SESSION_KEY_RE, key)
}

/// A live session's native provider binding and voice handoff files.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct VoiceTarget {
    pub session_key: String,
    pub provider: String,
    pub provider_session_id: String,
    pub cwd: String,
    pub command_path: String,
    pub meta_path: String,
    pub claim_path: String,
    pub manual_ack_path: String,
    pub state_path: String,
    pub spool_dir: String,
    pub app_session_id: String,
    pub recovery_generation: String,
    pub project_name: String,
}

/// `ProviderSessionOwnership`: app-authorized provider replacement, without
/// reading mutable session files.
pub struct ProviderSessionOwnership {
    inner: Mutex<OwnershipFields>,
}

struct OwnershipFields {
    provider_session_id: String,
    provider: String,
    app_session_id: String,
    recovery_generation: String,
    foreground_gate_handle: String,
}

impl ProviderSessionOwnership {
    pub fn new(
        provider_session_id: &str,
        provider: &str,
        app_session_id: &str,
        recovery_generation: &str,
    ) -> Self {
        Self {
            inner: Mutex::new(OwnershipFields {
                provider_session_id: crate::json::py_strip(provider_session_id).to_string(),
                provider: crate::json::py_strip(provider).to_lowercase(),
                app_session_id: crate::json::py_strip(app_session_id).to_string(),
                recovery_generation: crate::json::py_strip(recovery_generation).to_string(),
                foreground_gate_handle: String::new(),
            }),
        }
    }

    fn fields(&self) -> MutexGuard<'_, OwnershipFields> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn provider_session_id(&self) -> String {
        self.fields().provider_session_id.clone()
    }

    /// `provider_turn_scope()`.
    pub fn provider_turn_scope(&self) -> Dict {
        let fields = self.fields();
        let mut scope = Dict::new();
        scope.insert("provider", fields.provider.as_str());
        scope.insert("app_session_id", fields.app_session_id.as_str());
        scope.insert("recovery_generation", fields.recovery_generation.as_str());
        scope.insert("actor_role", "foreground_pm");
        scope.insert(
            "foreground_gate_handle",
            fields.foreground_gate_handle.as_str(),
        );
        scope
    }

    /// `authorize_transition`: accepts only the exact app-owned replacement
    /// of the current provider session for the claimed command.
    pub fn authorize_transition(&self, payload: &Dict, claimed: &Dict, state_path: &str) -> &'static str {
        let (provider_session_id, provider, app_session_id, recovery_generation) = {
            let fields = self.fields();
            (
                fields.provider_session_id.clone(),
                fields.provider.clone(),
                fields.app_session_id.clone(),
                fields.recovery_generation.clone(),
            )
        };
        if [
            &provider_session_id,
            &provider,
            &app_session_id,
            &recovery_generation,
        ]
        .iter()
        .any(|value| value.is_empty())
        {
            return "ownership_context_unavailable";
        }
        if !super::turns::manual_claim_ack_matches(Some(claimed), Some(payload)) {
            return "claim_identity_mismatch";
        }
        if !super::turns::relay_command_current_or_preserved(payload, state_path, "") {
            return "claim_not_current_or_preserved";
        }
        let previous_session_id = payload.text("previous_provider_session_id");
        let replacement_session_id = payload.text("provider_session_id");
        let foreground_gate_handle = payload.text("foreground_gate_handle");
        if replacement_session_id.is_empty() || replacement_session_id == previous_session_id {
            return "invalid_replacement_provider_session";
        }
        if foreground_gate_handle.is_empty() {
            return "replacement_foreground_gate_missing";
        }
        if payload.text("provider").to_lowercase() != provider {
            return "provider_mismatch";
        }
        if payload.text("app_session_id") != app_session_id {
            return "app_session_mismatch";
        }
        if payload.text("recovery_generation") != recovery_generation {
            return "recovery_generation_mismatch";
        }
        if payload.string("actor_role") != "foreground_pm" {
            return "actor_role_mismatch";
        }
        let claimed_provider = claimed.text("provider").to_lowercase();
        if !claimed_provider.is_empty() && claimed_provider != provider {
            return "claimed_provider_mismatch";
        }
        let mut fields = self.fields();
        if previous_session_id != fields.provider_session_id {
            return "previous_provider_session_mismatch";
        }
        fields.provider_session_id = replacement_session_id;
        fields.foreground_gate_handle = foreground_gate_handle;
        "accepted_exact_app_owned_replacement"
    }
}

/// The module globals `_VOICE_TARGETS` and friends, under `_VOICE_TARGET_LOCK`.
#[derive(Default)]
pub struct Targets {
    /// Insertion-ordered, like the Python dict.
    targets: Vec<VoiceTarget>,
    ownership: BTreeMap<String, Arc<ProviderSessionOwnership>>,
    orchestrators: BTreeMap<String, Arc<OrchestratorSession>>,
    orchestrator_pending: BTreeSet<String>,
    pub focused_key: Option<String>,
    pub startup_key: Option<String>,
    pub ledger_state_file: Option<String>,
    /// `_PROVIDER_SESSION_OWNERSHIP`: the focused session's ownership.
    pub provider_session_ownership: Option<Arc<ProviderSessionOwnership>>,
    /// `_SPOKEN_REPLY`'s session key: the focused session's reply most
    /// recently handed to speech.
    pub spoken_reply_session: Option<String>,
    /// `_PUBLISHED_SPEECH_QUEUE_DEPTH`.
    pub published_queue_depth: Option<i64>,
}

impl Targets {
    pub fn get(&self, key: &str) -> Option<&VoiceTarget> {
        self.targets.iter().find(|target| target.session_key == key)
    }

    pub fn keys(&self) -> Vec<String> {
        self.targets
            .iter()
            .map(|target| target.session_key.clone())
            .collect()
    }

    fn insert(&mut self, target: VoiceTarget) {
        match self
            .targets
            .iter_mut()
            .find(|existing| existing.session_key == target.session_key)
        {
            Some(existing) => *existing = target,
            None => self.targets.push(target),
        }
    }

    fn remove(&mut self, key: &str) -> Option<VoiceTarget> {
        let position = self
            .targets
            .iter()
            .position(|target| target.session_key == key)?;
        Some(self.targets.remove(position))
    }

    pub fn focused(&self) -> Option<&VoiceTarget> {
        self.get(self.focused_key.as_deref().unwrap_or(""))
    }
}

static TARGETS: LazyLock<Mutex<Targets>> = LazyLock::new(Mutex::default);

/// Locks `_VOICE_TARGET_LOCK`.
pub fn lock() -> MutexGuard<'static, Targets> {
    TARGETS.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `_current_voice_target`.
pub fn current_voice_target() -> Option<VoiceTarget> {
    lock().focused().cloned()
}

/// `_voice_target_for`.
pub fn voice_target_for(session_key: &str) -> Option<VoiceTarget> {
    lock().get(session_key).cloned()
}

/// `_voice_target_for(value)` for a JSON field that may be absent.
pub fn voice_target_for_value(value: Option<&Value>) -> Option<VoiceTarget> {
    let key = match value {
        Some(value) if value.truthy() => value.py_str(),
        _ => String::new(),
    };
    voice_target_for(&key)
}

pub fn live_voice_targets() -> Vec<VoiceTarget> {
    lock().targets.clone()
}

pub fn ledger_state_file() -> Option<String> {
    lock().ledger_state_file.clone()
}

pub fn focused_key() -> Option<String> {
    lock().focused_key.clone()
}

pub fn startup_key() -> Option<String> {
    lock().startup_key.clone()
}

pub fn voice_target_ownership(target: &VoiceTarget) -> Option<Arc<ProviderSessionOwnership>> {
    lock().ownership.get(&target.session_key).cloned()
}

pub fn provider_session_ownership() -> Option<Arc<ProviderSessionOwnership>> {
    lock().provider_session_ownership.clone()
}

/// `_authorization_key_for_target`: only app-owned spools under the
/// sessions root are keyed; manual bridges record key-less authorizations.
pub fn authorization_key_for_target(target: Option<&VoiceTarget>) -> String {
    let Some(target) = target else {
        return settings().relay_session_key.clone();
    };
    if dirname(target.spool_dir.trim_end_matches('/')) != settings().sessions_root
        || !valid_session_key(&target.session_key)
    {
        return String::new();
    }
    target.session_key.clone()
}

/// `_authorization_session_key`: the recorded target, else the focused one.
pub fn authorization_session_key(metadata: &Dict) -> String {
    let target = voice_target_for_value(metadata.get("voice_target_session_key"))
        .or_else(current_voice_target);
    authorization_key_for_target(target.as_ref())
}

/// `_voice_target_orchestrator`: the target's own orchestrator session; the
/// startup target uses the bridge's.
pub fn voice_target_orchestrator(
    target: Option<&VoiceTarget>,
    fallback: Option<Arc<OrchestratorSession>>,
) -> Option<Arc<OrchestratorSession>> {
    let targets = lock();
    match target {
        None => fallback,
        Some(target) if Some(&target.session_key) == targets.startup_key.as_ref() => fallback,
        Some(target) => targets.orchestrators.get(&target.session_key).cloned(),
    }
}

/// `_startup_voice_session_key`.
pub fn startup_voice_session_key() -> String {
    let key = crate::support::env_text("RELAY_SESSION_KEY");
    if !key.is_empty() {
        return key;
    }
    let spool = &settings().spool_dir;
    let name = basename(spool.trim_end_matches('/'));
    if name.is_empty() {
        "legacy".to_string()
    } else {
        name.to_string()
    }
}

/// `_session_spool_is_live`: a session lives while the app keeps its spool.
pub fn session_spool_is_live(session_key: &str) -> bool {
    session_key == startup_voice_session_key()
        || std::path::Path::new(&settings().sessions_root)
            .join(session_key)
            .is_dir()
}

/// `_install_startup_voice_target`: the session this bridge launched with.
pub fn install_startup_voice_target(
    ownership: Option<Arc<ProviderSessionOwnership>>,
) -> VoiceTarget {
    let settings = settings();
    let target = VoiceTarget {
        session_key: startup_voice_session_key(),
        provider: crate::support::env_text("RELAY_RUNNER_PROVIDER"),
        provider_session_id: settings.provider_session_id.clone(),
        cwd: store::current_dir(),
        command_path: settings.cmd_file.clone(),
        meta_path: settings.cmd_meta_file.clone(),
        claim_path: settings.claim_file.clone(),
        manual_ack_path: settings.manual_ack_file.clone(),
        state_path: String::new(),
        spool_dir: settings.spool_dir.clone(),
        app_session_id: crate::support::env_text("RELAY_APP_SESSION_ID"),
        recovery_generation: crate::support::env_text("RELAY_RECOVERY_GENERATION"),
        project_name: String::new(),
    };
    let mut targets = lock();
    targets.targets.clear();
    targets.ownership.clear();
    targets.orchestrators.clear();
    targets.insert(target.clone());
    if let Some(ownership) = ownership {
        targets
            .ownership
            .insert(target.session_key.clone(), ownership);
    }
    targets.orchestrator_pending.clear();
    targets.focused_key = Some(target.session_key.clone());
    targets.startup_key = Some(target.session_key.clone());
    targets.ledger_state_file = Some(settings.command_state_file.clone());
    target
}

/// `_clear_voice_targets`: forgets every target and returns the per-target
/// orchestrator lifecycles to stop.
pub fn clear_voice_targets() -> Vec<Arc<OrchestratorSession>> {
    let mut targets = lock();
    let lifecycles = std::mem::take(&mut targets.orchestrators)
        .into_values()
        .collect();
    targets.targets.clear();
    targets.ownership.clear();
    targets.orchestrator_pending.clear();
    targets.focused_key = None;
    targets.startup_key = None;
    targets.ledger_state_file = None;
    lifecycles
}

/// `_voice_target_from_focus`: validates an app `__FOCUS__` payload.
pub fn voice_target_from_focus(payload: &Dict) -> Option<VoiceTarget> {
    let key = payload.text("session_key");
    let spool_text = payload.text("spool_dir");
    let spool = normpath(if spool_text.is_empty() { "/" } else { &spool_text });
    let cwd = payload.text("cwd");
    if !valid_session_key(&key)
        || basename(&spool) != key
        || dirname(&spool) != settings().sessions_root
        || cwd.is_empty()
        || !cwd.starts_with('/')
    {
        return None;
    }
    let spool_file = |name: &str| format!("{spool}/{name}");
    Some(VoiceTarget {
        provider: payload.text("provider").to_lowercase(),
        provider_session_id: payload.text("provider_session_id"),
        cwd,
        command_path: spool_file("voice_cmd_ready"),
        meta_path: spool_file("voice_cmd_ready.meta"),
        claim_path: spool_file("voice_cmd_claimed.json"),
        manual_ack_path: spool_file("voice_cmd_manual_ack.json"),
        state_path: spool_file("voice_command_state.json"),
        app_session_id: payload.text("app_session_id"),
        recovery_generation: payload.text("recovery_generation"),
        project_name: payload.text("project_name"),
        spool_dir: spool,
        session_key: key,
    })
}

/// `_hand_off_mailbox`: moves an ended target's undelivered command into the
/// focused mailbox.
pub fn hand_off_mailbox(source: &VoiceTarget, destination: Option<&VoiceTarget>) -> bool {
    let Some(destination) = destination else {
        return false;
    };
    if destination.command_path == source.command_path
        || !store::exists(&source.command_path)
        || store::exists(&source.claim_path)
        || store::exists(&destination.command_path)
        || store::exists(&destination.meta_path)
    {
        return false;
    }
    let moved = (|| -> std::io::Result<()> {
        if !destination.spool_dir.is_empty() {
            store::make_private_dirs(&destination.spool_dir)?;
        }
        if store::exists(&source.meta_path) {
            fs::rename(&source.meta_path, &destination.meta_path)?;
        }
        fs::rename(&source.command_path, &destination.command_path)
    })();
    match moved {
        Ok(()) => true,
        Err(error) => {
            eprintln!("[voice_bridge] Could not hand off queued voice command: {error}");
            false
        }
    }
}

pub type StartOrchestrator = Arc<dyn Fn(&VoiceTarget) -> Option<Arc<OrchestratorSession>> + Send + Sync>;
pub type StopOrchestrator = Arc<dyn Fn(Arc<OrchestratorSession>) + Send + Sync>;

/// `_register_target_orchestrator`.
fn register_target_orchestrator(
    target: VoiceTarget,
    start: StartOrchestrator,
    stop: Option<StopOrchestrator>,
) {
    let mut lifecycle = start(&target);
    {
        let mut targets = lock();
        targets.orchestrator_pending.remove(&target.session_key);
        if let Some(session) = lifecycle.take_if(|_| targets.get(&target.session_key).is_some()) {
            targets
                .orchestrators
                .entry(target.session_key.clone())
                .or_insert(session);
        }
    }
    if let (Some(lifecycle), Some(stop)) = (lifecycle, stop) {
        stop(lifecycle);
    }
}

/// `_apply_voice_focus`: registers, focuses and prunes live targets without
/// restarting the bridge. Returns the target and whether it is focused.
pub fn apply_voice_focus(
    payload: &Dict,
    start: Option<StartOrchestrator>,
    stop: Option<StopOrchestrator>,
) -> Option<VoiceTarget> {
    let Some(target) = voice_target_from_focus(payload) else {
        eprintln!("[voice_bridge] Rejected invalid __FOCUS__ target");
        return None;
    };
    let live_keys: Option<Vec<String>> = payload
        .get("live_session_keys")
        .and_then(Value::as_list)
        .map(|keys| keys.iter().map(Value::py_str).collect());
    let (current, pruned, stopped, needs_orchestrator, focused_ownership) = {
        let mut targets = lock();
        targets.insert(target.clone());
        let scope = targets
            .ownership
            .get(&target.session_key)
            .map(|existing| existing.provider_turn_scope())
            .unwrap_or_default();
        // Keep an ownership that already accepted a provider transition; a
        // new app session or recovery generation is a different owner.
        if scope.get("app_session_id").map(Value::py_str).as_deref()
            != Some(target.app_session_id.as_str())
            || scope.get("recovery_generation").map(Value::py_str).as_deref()
                != Some(target.recovery_generation.as_str())
        {
            targets.ownership.remove(&target.session_key);
            if [
                &target.provider_session_id,
                &target.provider,
                &target.app_session_id,
                &target.recovery_generation,
            ]
            .iter()
            .all(|value| !value.is_empty())
            {
                targets.ownership.insert(
                    target.session_key.clone(),
                    Arc::new(ProviderSessionOwnership::new(
                        &target.provider_session_id,
                        &target.provider,
                        &target.app_session_id,
                        &target.recovery_generation,
                    )),
                );
            }
        }
        if payload.get("focus").is_none_or(Value::truthy) {
            targets.focused_key = Some(target.session_key.clone());
        }
        let current = targets.focused().cloned();
        let mut pruned = Vec::new();
        if let Some(live_keys) = &live_keys {
            for key in targets.keys() {
                if !live_keys.contains(&key) && Some(&key) != targets.focused_key.as_ref() {
                    if let Some(ended) = targets.remove(&key) {
                        pruned.push(ended);
                    }
                    targets.ownership.remove(&key);
                }
            }
        }
        let stopped: Vec<Arc<OrchestratorSession>> = pruned
            .iter()
            .filter_map(|ended| targets.orchestrators.remove(&ended.session_key))
            .collect();
        let needs_orchestrator = start.is_some()
            && Some(&target.session_key) != targets.startup_key.as_ref()
            && !targets.orchestrators.contains_key(&target.session_key)
            && !targets.orchestrator_pending.contains(&target.session_key);
        if needs_orchestrator {
            targets
                .orchestrator_pending
                .insert(target.session_key.clone());
        }
        let focused_ownership = targets
            .ownership
            .get(targets.focused_key.as_deref().unwrap_or(""))
            .cloned();
        (current, pruned, stopped, needs_orchestrator, focused_ownership)
    };
    for ended in &pruned {
        let ended_key = authorization_key_for_target(Some(ended));
        if let Some(current) = &current
            && !ended_key.is_empty()
        {
            // Queued work handed to the focused session keeps its grants.
            if let Err(error) = super::authorization::transfer_session_authorizations(
                &settings().authorization_file,
                &ended_key,
                &authorization_key_for_target(Some(current)),
                None,
            ) {
                eprintln!("[voice_bridge] Could not transfer Relay authorizations: {error}");
            }
        }
        hand_off_mailbox(ended, current.as_ref());
    }
    for lifecycle in stopped {
        if let Some(stop) = &stop {
            stop(lifecycle);
        }
    }
    if needs_orchestrator && let Some(start) = start {
        // Registration is an HTTP round trip; keep the control socket responsive.
        let registered = target.clone();
        let stop = stop.clone();
        let _ = thread::Builder::new()
            .name("voice-target-orchestrator".to_string())
            .spawn(move || register_target_orchestrator(registered, start, stop));
    }
    let focused = current
        .as_ref()
        .is_some_and(|current| current.session_key == target.session_key);
    if focused && let Some(current) = &current {
        store::write_bridge_target_files(&current.cwd, &current.provider, &current.spool_dir);
        lock().provider_session_ownership = focused_ownership;
    }
    eprintln!(
        "[voice_bridge] Voice target {}: session={} provider={}",
        if focused { "focused" } else { "registered" },
        target.session_key,
        if target.provider.is_empty() {
            "unknown"
        } else {
            &target.provider
        },
    );
    Some(target)
}

/// `_spool_provider_session_id`: the provider session the app last recorded
/// in the target's spool.
pub fn spool_provider_session_id(target: &VoiceTarget) -> String {
    if target.spool_dir.is_empty() {
        return String::new();
    }
    fs::read_to_string(format!("{}/voice_provider_session_id", target.spool_dir))
        .map(|text| crate::json::py_strip(&text).to_string())
        .unwrap_or_default()
}

/// `_reply_origin_target`: the live session a reply came from, by session
/// key, else by provider session (Stop-hook completions name it
/// `session_id`).
pub fn reply_origin_target(data: &Dict) -> Option<VoiceTarget> {
    if let Some(target) = voice_target_for_value(data.get("session_key")) {
        return Some(target);
    }
    let provider_session_id = {
        let named = data.text("provider_session_id");
        if named.is_empty() {
            data.text("session_id")
        } else {
            named
        }
    };
    if provider_session_id.is_empty() {
        return None;
    }
    live_voice_targets().into_iter().find(|candidate| {
        provider_session_id == candidate.provider_session_id
            || provider_session_id == spool_provider_session_id(candidate)
    })
}

/// `_is_background_target`.
pub fn is_background_target(target: Option<&VoiceTarget>) -> bool {
    let targets = lock();
    target.is_some_and(|target| Some(&target.session_key) != targets.focused_key.as_ref())
}

/// `_note_spoken_reply`.
pub fn note_spoken_reply(target: Option<&VoiceTarget>) {
    let mut targets = lock();
    let session_key = match target {
        Some(target) => target.session_key.clone(),
        None => targets.focused_key.clone().unwrap_or_default(),
    };
    targets.spoken_reply_session = Some(session_key);
}

/// `_on_reply_finished`: a reply was heard or dismissed.
pub fn on_reply_finished() {
    lock().spoken_reply_session = None;
}

/// `(_SPOKEN_REPLY or {}).get("session_key", "")`.
pub fn waiting_session_key() -> String {
    lock().spoken_reply_session.clone().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_keys_match_the_daemon_pattern() {
        assert!(valid_session_key("session-1"));
        assert!(!valid_session_key("Session-1"));
        assert!(!valid_session_key(""));
        assert!(!valid_session_key(&"a".repeat(65)));
    }
}
