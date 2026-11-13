//! The collaborators `voice_bridge.py` passes from `main()` into every
//! handler (`tts_worker`, `messenger`, `inbox`, `provider_turn_broker`, the
//! orchestrator session and the `recovery_context` dict), held once.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use relay_intents::broker::ProviderTurnBroker;
use relay_intents::inbox::IntentInbox;

use super::orchestrator::OrchestratorSession;
use super::ports::{Event, Messenger, Sidecar, Speech};
use super::settings::settings;
use super::store;
use super::targets::{ProviderSessionOwnership, StartOrchestrator, StopOrchestrator};
use crate::json::Dict;

/// The `recovery_context` keys the control socket keeps between requests.
#[derive(Default)]
pub struct RecoveryState {
    pub applied_keys: BTreeSet<String>,
    pub cooldowns: BTreeMap<String, f64>,
    pub resume_keys: BTreeSet<String>,
}

pub struct Bridge {
    pub cfg: Dict,
    pub speech: Arc<dyn Speech>,
    pub inbox: Option<Mutex<IntentInbox>>,
    pub broker: Option<Mutex<ProviderTurnBroker>>,
    /// `provider_turn_broker.projection_path`.
    pub broker_projection_path: Option<String>,
    pub ownership: Option<Arc<ProviderSessionOwnership>>,
    pub shutdown: Arc<Event>,
    /// `normalize_recovery_generation(RELAY_RECOVERY_GENERATION or "0")`.
    pub recovery_generation: String,
    pub messenger_expected: bool,
    orchestrator: OnceLock<Option<Arc<OrchestratorSession>>>,
    messenger: OnceLock<Option<Arc<dyn Messenger>>>,
    sidecar: OnceLock<Arc<dyn Sidecar>>,
    pub start_target_orchestrator: OnceLock<StartOrchestrator>,
    pub stop_target_orchestrator: OnceLock<StopOrchestrator>,
    pub recovery: Mutex<RecoveryState>,
}

impl Bridge {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        cfg: Dict,
        speech: Arc<dyn Speech>,
        inbox: Option<IntentInbox>,
        broker: Option<ProviderTurnBroker>,
        broker_projection_path: Option<String>,
        ownership: Option<Arc<ProviderSessionOwnership>>,
        shutdown: Arc<Event>,
        recovery_generation: String,
        messenger_expected: bool,
    ) -> Self {
        Self {
            cfg,
            speech,
            inbox: inbox.map(Mutex::new),
            broker: broker.map(Mutex::new),
            broker_projection_path,
            ownership,
            shutdown,
            recovery_generation,
            messenger_expected,
            orchestrator: OnceLock::new(),
            messenger: OnceLock::new(),
            sidecar: OnceLock::new(),
            start_target_orchestrator: OnceLock::new(),
            stop_target_orchestrator: OnceLock::new(),
            recovery: Mutex::new(RecoveryState::default()),
        }
    }

    pub fn speech(&self) -> &dyn Speech {
        self.speech.as_ref()
    }

    pub fn messenger(&self) -> Option<&dyn Messenger> {
        self.messenger.get().and_then(Option::as_deref)
    }

    pub fn messenger_arc(&self) -> Option<Arc<dyn Messenger>> {
        self.messenger.get().cloned().flatten()
    }

    pub fn set_messenger(&self, messenger: Option<Arc<dyn Messenger>>) {
        let _ = self.messenger.set(messenger);
    }

    pub fn orchestrator(&self) -> Option<Arc<OrchestratorSession>> {
        self.orchestrator.get().cloned().flatten()
    }

    pub fn set_orchestrator(&self, session: Option<Arc<OrchestratorSession>>) {
        let _ = self.orchestrator.set(session);
    }

    pub fn sidecar(&self) -> Option<&dyn Sidecar> {
        self.sidecar.get().map(Arc::as_ref)
    }

    pub fn set_sidecar(&self, sidecar: Arc<dyn Sidecar>) {
        let _ = self.sidecar.set(sidecar);
    }

    /// The inbox, locked; `None` without one.
    pub fn inbox(&self) -> Option<MutexGuard<'_, IntentInbox>> {
        self.inbox.as_ref().map(|inbox| {
            inbox
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        })
    }

    pub fn broker(&self) -> Option<MutexGuard<'_, ProviderTurnBroker>> {
        self.broker.as_ref().map(|broker| {
            broker
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        })
    }

    /// `_sync_intent_inbox_state`.
    pub fn sync_inbox_state(&self, state_path: &str) {
        if let Some(inbox) = self.inbox() {
            let _guard = store::voice_state_lock();
            if let Err(error) = store::sync_deliverable_state(state_path, &inbox) {
                eprintln!("[voice_bridge] Could not sync intent inbox state: {error}");
            }
        }
    }

    /// `PROVIDER_TURN_BROKER_MODE == "dual_write"`.
    pub fn dual_write(&self) -> bool {
        settings().broker_mode == "dual_write"
    }
}
