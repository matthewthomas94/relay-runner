//! Relay Remote agent routing (RR-534; docs/specs/relay-remote.md, "Agents").
//!
//! A phone's `utterance` and `control` may name an `agent` slug. An addressed
//! utterance goes to that agent's own voice target, whichever target is
//! focused on the Mac: delivery writes into the target's mailbox and never
//! moves the focus that local microphone input follows. An utterance for an
//! agent that is not running asks the app to start it and is held, then
//! handled once, when that agent's target is registered and ready. An
//! addressed control acts on that agent's speech only. Items without an
//! agent go to the focused target exactly as before.
//!
//! The bridge tags `accepted` and outbound speech with the agent of the
//! session they belong to (`agent_for_session`).

use std::collections::{BTreeMap, VecDeque};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use relay_services::command_actions::agent_name;

use super::commands::PublishPaths;
use super::context::Bridge;
use super::controls;
use super::remote_link::{RemoteItem, RemoteLink};
use super::store;
use super::targets::{self, VoiceTarget};
use crate::json::{self, Dict, Value};

/// How long an addressed utterance waits for its agent to start and be ready.
const START_WAIT: Duration = Duration::from_secs(120);

/// Where an agent's session stands, from the bridge's voice targets.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Presence {
    /// Registered and ready for input.
    Ready,
    /// Registered, its provider still starting.
    Starting,
    /// No live session.
    Off,
}

/// The live voice target that runs `agent`, ready or not.
fn live_target(agent: &str) -> Option<VoiceTarget> {
    targets::live_voice_targets()
        .into_iter()
        .find(|target| targets::session_agent(Some(target)) == Some(agent))
}

fn presence(agent: &str) -> Presence {
    match live_target(agent) {
        Some(target) if target.ready => Presence::Ready,
        Some(_) => Presence::Starting,
        None => Presence::Off,
    }
}

/// The voice target a Relay Remote item is delivered to: the named agent's
/// ready session, or without an agent the focused one. `None` for a named
/// agent that has no ready session.
pub fn voice_target(item: &RemoteItem) -> Option<VoiceTarget> {
    match item.agent.as_deref() {
        None => targets::current_voice_target(),
        Some(agent) => live_target(agent).filter(|target| target.ready),
    }
}

/// The agent of the live session `session_key`, for its frames' `agent`.
pub fn agent_for_session(session_key: &str) -> Option<&'static str> {
    if session_key.is_empty() {
        return None;
    }
    targets::voice_target_for(session_key).and_then(|target| targets::session_agent(Some(&target)))
}

struct Held {
    item: RemoteItem,
    since: Instant,
}

/// Addressed utterances waiting for their agent, oldest first, and when each
/// agent's start was last asked for.
#[derive(Default)]
struct Pending {
    held: VecDeque<Held>,
    requested: BTreeMap<String, Instant>,
}

/// What one pass over the remote items decided.
#[derive(Debug, Default)]
struct Admission {
    /// Items to handle now, in order.
    deliver: Vec<RemoteItem>,
    /// Agents the app is asked to start.
    start: Vec<String>,
    /// Held utterances whose agent never became ready.
    expired: Vec<RemoteItem>,
}

impl Pending {
    fn holds_for(&self, agent: &str) -> bool {
        self.held
            .iter()
            .any(|held| held.item.agent.as_deref() == Some(agent))
    }

    /// Held items whose agent is now ready come first, in the order they
    /// arrived, then the fresh items that can go now. An utterance for an
    /// agent that is not ready, or that has older items still held, waits;
    /// an agent with no session is asked to start once per `START_WAIT`. A
    /// control for an agent without a session has nothing to act on.
    fn admit(
        &mut self,
        fresh: Vec<RemoteItem>,
        now: Instant,
        presence: &dyn Fn(&str) -> Presence,
    ) -> Admission {
        let mut admission = Admission::default();
        let mut deliver_fresh = Vec::new();
        for item in fresh {
            let Some(agent) = item.agent.clone() else {
                deliver_fresh.push(item);
                continue;
            };
            if item.control {
                if presence(&agent) != Presence::Off {
                    deliver_fresh.push(item);
                }
                continue;
            }
            if presence(&agent) == Presence::Ready && !self.holds_for(&agent) {
                deliver_fresh.push(item);
                continue;
            }
            self.held.push_back(Held { item, since: now });
        }
        let mut kept = VecDeque::new();
        for held in std::mem::take(&mut self.held) {
            let agent = held.item.agent.clone().unwrap_or_default();
            let present = presence(&agent);
            if present == Presence::Ready {
                admission.deliver.push(held.item);
                continue;
            }
            if now.duration_since(held.since) > START_WAIT {
                admission.expired.push(held.item);
                continue;
            }
            if present == Presence::Off
                && self
                    .requested
                    .get(&agent)
                    .is_none_or(|asked| now.duration_since(*asked) > START_WAIT)
            {
                self.requested.insert(agent.clone(), now);
                admission.start.push(agent);
            }
            kept.push_back(held);
        }
        self.held = kept;
        let waiting: Vec<String> = self
            .held
            .iter()
            .filter_map(|held| held.item.agent.clone())
            .collect();
        self.requested.retain(|agent, _| waiting.contains(agent));
        admission.deliver.extend(deliver_fresh);
        admission
    }
}

static PENDING: LazyLock<Mutex<Pending>> = LazyLock::new(Mutex::default);

fn pending() -> MutexGuard<'static, Pending> {
    PENDING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Asks the app to start `agent` for a held message: a `remote_agent`
/// `start` datagram on its state socket, beside the `remote_device` events.
fn request_start(agent: &str) {
    let mut event = Dict::new();
    event.insert("source", "remote_agent");
    event.insert("state", "start");
    event.insert("agent", agent);
    store::send_state_datagram(json::dumps(&Value::Dict(event)).as_bytes());
    eprintln!("[voice_bridge] Relay Remote asked the app to start agent={agent}");
}

/// The remote items the relay loop handles now; called on every loop pass
/// so held items go as soon as their agent is ready.
pub fn admit(fresh: Vec<RemoteItem>, remote: &RemoteLink) -> Vec<RemoteItem> {
    let admission = pending().admit(fresh, Instant::now(), &presence);
    for agent in &admission.start {
        request_start(agent);
    }
    for item in &admission.expired {
        let name = item.agent.as_deref().map_or_else(String::new, agent_name);
        remote.refuse(
            &item.device_id,
            "agent_unavailable",
            &format!("{name} did not start, so the message was not delivered"),
        );
    }
    admission.deliver
}

/// Holds an addressed utterance again when its agent's session went away
/// between admission and delivery.
pub fn hold_again(item: RemoteItem) {
    pending().held.push_front(Held {
        item,
        since: Instant::now(),
    });
}

/// An addressed `control`: it acts on that agent's speech only, as the
/// session wheel acts on one session's. `stop`, `cancel`, `play`, `replay`
/// and `interrupt` keep their meaning.
pub fn control(bridge: &'static Bridge, item: &RemoteItem) {
    let Some(target) = item.agent.as_deref().and_then(live_target) else {
        return;
    };
    let speech = bridge.speech();
    let key = target.session_key.as_str();
    match item.text.as_str() {
        "__TTS_STOP__" => speech.stop_session_playback(key, "recording_barge_in"),
        "__CANCEL__" => speech.skip_session(key, "user_stop"),
        "__REPLAY__" => {
            speech.replay_session(key);
        }
        "__PLAY__" => {
            if !speech.control_session(key, "play", &targets::waiting_session_key()) {
                speech.replay_session(key);
            }
        }
        "__INTERRUPT__" => controls::interrupt(bridge, &PublishPaths::default(), Some(&target)),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utterance(agent: Option<&str>, client_id: &str) -> RemoteItem {
        RemoteItem {
            text: "hello".into(),
            device_id: "D1".into(),
            client_id: client_id.into(),
            control: false,
            agent: agent.map(str::to_string),
        }
    }

    fn ids(items: &[RemoteItem]) -> Vec<&str> {
        items.iter().map(|item| item.client_id.as_str()).collect()
    }

    #[test]
    fn items_without_an_agent_or_for_a_ready_agent_go_at_once() {
        let mut pending = Pending::default();
        let admission = pending.admit(
            vec![utterance(None, "a"), utterance(Some("george"), "b")],
            Instant::now(),
            &|_| Presence::Ready,
        );
        assert_eq!(ids(&admission.deliver), ["a", "b"]);
        assert!(admission.start.is_empty() && pending.held.is_empty());
    }

    /// A message to a stopped agent starts it, waits while it starts, and is
    /// delivered once when it is ready; later messages to it keep their order.
    #[test]
    fn a_message_to_a_stopped_agent_starts_it_and_waits_until_ready() {
        let mut pending = Pending::default();
        let start = Instant::now();
        let off = pending.admit(vec![utterance(Some("sky"), "a")], start, &|_| Presence::Off);
        assert!(off.deliver.is_empty());
        assert_eq!(off.start, ["sky"]);

        // Asked once: later passes while it is still off or starting ask nothing.
        let again = pending.admit(Vec::new(), start + Duration::from_secs(1), &|_| {
            Presence::Off
        });
        assert!(again.start.is_empty() && again.deliver.is_empty());
        let starting = pending.admit(
            vec![utterance(Some("sky"), "b"), utterance(None, "c")],
            start + Duration::from_secs(2),
            &|_| Presence::Starting,
        );
        assert_eq!(ids(&starting.deliver), ["c"]);

        let ready = pending.admit(Vec::new(), start + Duration::from_secs(3), &|_| {
            Presence::Ready
        });
        assert_eq!(ids(&ready.deliver), ["a", "b"]);
        let after = pending.admit(Vec::new(), start + Duration::from_secs(4), &|_| {
            Presence::Ready
        });
        assert!(after.deliver.is_empty(), "delivered once");
    }

    #[test]
    fn a_held_message_expires_when_its_agent_never_becomes_ready() {
        let mut pending = Pending::default();
        let start = Instant::now();
        pending.admit(vec![utterance(Some("isabella"), "a")], start, &|_| {
            Presence::Off
        });
        let late = pending.admit(
            Vec::new(),
            start + START_WAIT + Duration::from_secs(1),
            &|_| Presence::Starting,
        );
        assert_eq!(ids(&late.expired), ["a"]);
        assert!(pending.held.is_empty() && pending.requested.is_empty());
    }

    #[test]
    fn a_control_for_an_agent_without_a_session_is_dropped() {
        let mut pending = Pending::default();
        let control = RemoteItem {
            control: true,
            ..utterance(Some("george"), "a")
        };
        let off = pending.admit(vec![control.clone()], Instant::now(), &|_| Presence::Off);
        assert!(off.deliver.is_empty() && off.start.is_empty() && pending.held.is_empty());
        let starting = pending.admit(vec![control], Instant::now(), &|_| Presence::Starting);
        assert_eq!(ids(&starting.deliver), ["a"]);
    }
}
