//! Agent presence and agent notices (RR-525): which repositories each
//! running Relay agent (Puck, Isabella, George, Sky) is working in, and the
//! one-way notices the other agents receive when that changes.
//!
//! Interfaces later tickets reuse unchanged (RR-526, RR-527):
//!
//! - **Session-to-agent identity.** A session is running while the app keeps
//!   its spool `<runtime>/relay-sessions/<key>/` (the bridge's own liveness
//!   rule), and its agent is the slug in that spool's `session_agent` file.
//!   `Presence::live_sessions` is the one reader of both. A spool recreated
//!   under the same key is a new session (its `generation` differs).
//! - **The presence record.** `Presence::record` takes one `Activity`: a
//!   session key, a repository, how it was learned (`Source`) and a short
//!   detail. Every daemon mutation that names a repository and a session
//!   calls it through `Daemon::note_presence`; `declare` is the agent's own
//!   entry for work the daemon cannot see. A repository leaves an agent's
//!   set after `IDLE_SECONDS` without activity there, and all of a session's
//!   entries go when its spool does. The built-in general-tasks project is
//!   never recorded.
//! - **The notice queue.** `Presence::queue_for` queues one text for one
//!   receiving session, and `Presence::claim` hands a session its
//!   undelivered notices once (newest `NOTICE_DELIVERY_LIMIT`, plus a count
//!   of the rest). Notices for a session that is not running are dropped.
//! - **Delivery.** `POST /v1/agent-notices/claim` is read by the voice
//!   bridge (appended to a voice turn's prompt) and by the prompt-submit
//!   hook (added as context to a typed turn); the presence routes return the
//!   caller's notices too. Nothing here speaks, types into a terminal or
//!   starts a turn.
//!
//! RR-526 adds coordination between agents that share a repository, on the
//! same record, queue and delivery:
//!
//! - **Overlap.** Two running agents overlap on a repository while it is in
//!   both their sets. When it begins, each gets one notice naming the other
//!   with its note and the tickets it wrote or dispatched there; when it ends
//!   (one stopped, or its entry expired) the other gets one notice.
//! - **Action notices.** `Presence::record_action` records an activity and
//!   tells the other agents overlapping on the repository what was done
//!   (`Action`): a ticket created, edited or dispatched, a run merged or
//!   failed, or declared direct work. An agent with no overlap there hears
//!   nothing. Edits of one ticket by one agent collapse into one line until
//!   the receiver's next delivery.
//!
//! The record survives a daemon restart in `<data root>/agent_presence.json`;
//! every read first sweeps it against the live spools, so the entries of a
//! session that no longer exists are gone after a daemon or app restart.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

use relay_artifacts::instant::Instant;
use relay_intents::json::{self, Dict, Value};
use relay_services::agent_notices::{NOTICE_DELIVERY_LIMIT, notice_block};
use relay_services::command_actions::{SESSION_AGENTS, agent_name, known_agent};

use crate::daemon::{Daemon, guard, resolve_path};
use crate::failure::{Failure, Outcome};
use crate::relay_command::{optional_relay_session_key, relay_session_key};
use crate::request::Request;
use crate::router::{Reply, reply};

/// A repository leaves an agent's set after two hours without activity.
pub const IDLE_SECONDS: f64 = 2.0 * 60.0 * 60.0;
/// The most notices kept for one receiver; older ones become a count.
const RECEIVER_QUEUE_LIMIT: usize = 100;
/// The longest declared note kept, in characters.
const NOTE_LIMIT: usize = 200;
/// The most ticket ids remembered per entry for overlap notices.
const ENTRY_TICKET_LIMIT: usize = 10;
/// The most declared paths kept, and the longest one, in characters.
const PATH_LIMIT: usize = 20;
const PATH_LENGTH_LIMIT: usize = 200;
const SCHEMA_VERSION: i64 = 1;

/// Seconds since the Unix epoch; injected so tests control expiry.
pub type Clock = Box<dyn Fn() -> f64 + Send + Sync>;

/// How a repository entered an agent's set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Dispatch,
    TicketClaim,
    TicketWrite,
    OrchestratorAction,
    SessionCapture,
    Declared,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Dispatch => "dispatch",
            Source::TicketClaim => "ticket_claim",
            Source::TicketWrite => "ticket_write",
            Source::OrchestratorAction => "orchestrator_action",
            Source::SessionCapture => "session_capture",
            Source::Declared => "declared",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        [
            Source::Dispatch,
            Source::TicketClaim,
            Source::TicketWrite,
            Source::OrchestratorAction,
            Source::SessionCapture,
            Source::Declared,
        ]
        .into_iter()
        .find(|source| source.as_str() == text)
    }
}

/// One running app session: its key, its agent and the spool it lives in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveSession {
    pub key: String,
    pub agent: String,
    /// Distinguishes a spool recreated under the same key.
    pub generation: String,
}

/// One repository in one session's set.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub agent: String,
    pub session_key: String,
    pub repo_path: String,
    pub source: Source,
    pub detail: String,
    pub note: String,
    /// Tickets this session wrote or dispatched here, oldest first (RR-526).
    pub tickets: Vec<String>,
    pub first_seen: f64,
    pub last_seen: f64,
}

/// One activity to record.
#[derive(Clone, Copy, Debug)]
pub struct Activity<'a> {
    pub session_key: &'a str,
    pub repo_path: &'a str,
    pub source: Source,
    /// What the activity was, e.g. `dispatched RR-530`.
    pub detail: &'a str,
    /// The agent's one-line note; only a declaration has one.
    pub note: Option<&'a str>,
}

/// What `record` did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Recorded {
    /// The repository entered the session's set; the others were told.
    Entered,
    /// The repository was already in the set; only its time moved.
    Refreshed,
    /// Nothing: no running session has the key, or the path is general-tasks.
    Ignored,
}

/// What one agent did in a repository that the other agents sharing it
/// hear about (RR-526).
#[derive(Clone, Copy, Debug)]
pub enum Action<'a> {
    TicketCreated {
        ticket_id: &'a str,
        title: &'a str,
    },
    TicketEdited {
        ticket_id: &'a str,
        title: &'a str,
    },
    TicketDispatched {
        ticket_id: &'a str,
        /// Waiting on its dependencies instead of started.
        queued: bool,
    },
    /// A run the agent dispatched ended; `outcome` reads after the id, e.g.
    /// `merged into the checkout`.
    RunEnded {
        ticket_id: &'a str,
        outcome: &'a str,
    },
    /// Work the agent declared it is about to do directly in the checkout.
    DirectWork {
        description: &'a str,
        paths: &'a [String],
    },
}

impl Action<'_> {
    /// The ticket the action adds to the sender's entry, if any.
    fn authored_ticket(&self) -> Option<&str> {
        match self {
            Action::TicketCreated { ticket_id, .. }
            | Action::TicketEdited { ticket_id, .. }
            | Action::TicketDispatched { ticket_id, .. } => Some(ticket_id),
            Action::RunEnded { .. } | Action::DirectWork { .. } => None,
        }
    }

    /// Notices with the same key for one receiver collapse into one line.
    fn collapse_key(&self, sender: &str, repo: &str) -> String {
        match self {
            Action::TicketEdited { ticket_id, .. } => format!("edited|{sender}|{repo}|{ticket_id}"),
            _ => String::new(),
        }
    }

    /// The notice text; `count` is how many collapsed into it.
    fn text(&self, name: &str, repository: &str, count: i64) -> String {
        let titled = |ticket_id: &str, title: &str| {
            let title = json::py_strip(title);
            if title.is_empty() {
                ticket_id.to_string()
            } else {
                format!("{ticket_id} \"{title}\"")
            }
        };
        match self {
            Action::TicketCreated { ticket_id, title } => format!(
                "Agent notice: {name} created ticket {} in {repository}.",
                titled(ticket_id, title)
            ),
            Action::TicketEdited { ticket_id, title } => {
                let times = if count > 1 {
                    format!(" ({count} edits)")
                } else {
                    String::new()
                };
                format!(
                    "Agent notice: {name} edited ticket {} in {repository}{times}.",
                    titled(ticket_id, title)
                )
            }
            Action::TicketDispatched {
                ticket_id,
                queued: false,
            } => format!("Agent notice: {name} dispatched {ticket_id} in {repository}."),
            Action::TicketDispatched {
                ticket_id,
                queued: true,
            } => format!(
                "Agent notice: {name} queued {ticket_id} in {repository} to start when its \
                 dependencies are done."
            ),
            Action::RunEnded { ticket_id, outcome } => {
                format!("Agent notice: {name}'s run of {ticket_id} in {repository} {outcome}.")
            }
            Action::DirectWork { description, paths } => {
                let paths = if paths.is_empty() {
                    String::new()
                } else {
                    format!(" (paths: {})", paths.join(", "))
                };
                let description = json::py_strip(description);
                let description = if description.is_empty() {
                    String::new()
                } else {
                    format!(": {description}")
                };
                format!(
                    "Agent notice: {name} declared direct work in {repository}{description}{paths}."
                )
            }
        }
    }
}

#[derive(Clone, Debug)]
struct Notice {
    receiver: String,
    seq: i64,
    text: String,
    created_at: f64,
    /// Non-empty for a notice later ones of the same kind collapse into.
    key: String,
    /// How many notices collapsed into this one.
    count: i64,
}

#[derive(Default)]
struct State {
    /// The sessions the last sweep saw running.
    sessions: Vec<LiveSession>,
    entries: Vec<Entry>,
    notices: Vec<Notice>,
    /// Per receiver, notices dropped from a full queue.
    overflow: Vec<(String, i64)>,
    next_seq: i64,
}

/// Notices one session claimed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Claimed {
    /// Oldest first, at most `NOTICE_DELIVERY_LIMIT`.
    pub notices: Vec<String>,
    /// Older notices dropped instead of delivered.
    pub omitted: i64,
}

impl Claimed {
    pub fn block(&self) -> String {
        notice_block(&self.notices, self.omitted)
    }

    fn insert_into(&self, body: &mut Dict) {
        let notices = self
            .notices
            .iter()
            .map(|text| {
                let mut notice = Dict::new();
                notice.insert("text", text.as_str());
                Value::Dict(notice)
            })
            .collect::<Vec<_>>();
        body.insert("notices", Value::List(notices));
        body.insert("omitted_notices", self.omitted);
        body.insert("notice_block", self.block());
    }
}

/// The presence record and notice queue.
pub struct Presence {
    path: PathBuf,
    spool_root: PathBuf,
    general_root: PathBuf,
    clock: Clock,
    state: Mutex<State>,
}

fn iso(seconds: f64) -> String {
    Instant::from_unix_micros((seconds * 1e6) as i64).isoformat_z()
}

/// A repository's short name: its folder's name.
pub fn repository_name(repo_path: &str) -> String {
    Path::new(repo_path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| repo_path.to_string())
}

/// A declared note: its first line, trimmed and bounded.
fn one_line(note: &str) -> String {
    let line = note.lines().map(str::trim).find(|line| !line.is_empty());
    line.unwrap_or_default().chars().take(NOTE_LIMIT).collect()
}

/// Adds `ticket` to an entry's tickets, newest last, keeping the newest
/// `ENTRY_TICKET_LIMIT`.
fn remember_ticket(tickets: &mut Vec<String>, ticket: String) {
    tickets.retain(|known| *known != ticket);
    tickets.push(ticket);
    let excess = tickets.len().saturating_sub(ENTRY_TICKET_LIMIT);
    tickets.drain(..excess);
}

/// What is known of an entry's work, as a parenthesised suffix: its note and
/// the tickets it wrote or dispatched, else its detail; `""` for nothing.
fn work_known(entry: &Entry) -> String {
    let mut parts = Vec::new();
    if !entry.note.is_empty() {
        parts.push(format!("note: {}", entry.note));
    }
    if !entry.tickets.is_empty() {
        parts.push(format!("tickets: {}", entry.tickets.join(", ")));
    }
    if parts.is_empty() && !entry.detail.is_empty() {
        parts.push(entry.detail.clone());
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!(" ({})", parts.join("; "))
    }
}

/// Declared paths: one line each, bounded in number and length.
pub fn bounded_paths(paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .map(|path| one_line(path).chars().take(PATH_LENGTH_LIMIT).collect())
        .filter(|path: &String| !path.is_empty())
        .take(PATH_LIMIT)
        .collect()
}

fn string_list(items: &[String]) -> Value {
    Value::List(
        items
            .iter()
            .map(|item| Value::from(item.as_str()))
            .collect(),
    )
}

fn float_of(dict: &Dict, key: &str) -> f64 {
    dict.get(key).and_then(Value::py_float).unwrap_or(0.0)
}

impl Presence {
    /// Opens the record at `path`, sweeping it against the spools under
    /// `spool_root` at once. `general_root` is the general-tasks folder.
    pub fn open(path: PathBuf, spool_root: PathBuf, general_root: &Path, clock: Clock) -> Self {
        let state = Self::load(&path);
        let presence = Self {
            path,
            spool_root,
            general_root: resolve_path(&general_root.to_string_lossy()),
            clock,
            state: Mutex::new(state),
        };
        {
            let mut state = guard(&presence.state);
            if presence.sweep(&mut state) {
                presence.save(&state);
            }
        }
        presence
    }

    /// Every running app session with a known agent, from the spools.
    pub fn live_sessions(&self) -> Vec<LiveSession> {
        let Ok(directory) = fs::read_dir(&self.spool_root) else {
            return Vec::new();
        };
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        let mut sessions = Vec::new();
        for item in directory.flatten() {
            let key = item.file_name().to_string_lossy().into_owned();
            if relay_session_key(Some(&Value::from(key.as_str())))
                .ok()
                .flatten()
                .as_deref()
                != Some(key.as_str())
            {
                continue;
            }
            let Ok(info) = fs::symlink_metadata(item.path()) else {
                continue;
            };
            if !info.file_type().is_dir() || info.uid() != uid {
                continue;
            }
            let Some(agent) = fs::read_to_string(item.path().join("session_agent"))
                .ok()
                .as_deref()
                .and_then(known_agent)
            else {
                continue;
            };
            let created = info
                .created()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |elapsed| elapsed.as_nanos());
            sessions.push(LiveSession {
                key,
                agent: agent.to_string(),
                generation: format!("{}-{created}", info.ino()),
            });
        }
        sessions.sort_by(|left, right| left.key.cmp(&right.key));
        sessions
    }

    /// Whether `repo_path` is the general-tasks folder or inside it.
    fn is_general(&self, repo_path: &Path) -> bool {
        repo_path.starts_with(&self.general_root)
    }

    /// Records one activity: refreshes its entry, or adds it and tells every
    /// other running session.
    pub fn record(&self, activity: &Activity) -> Recorded {
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        let recorded = self.record_locked(&mut state, activity, None);
        if swept || recorded != Recorded::Ignored {
            self.save(&state);
        }
        recorded
    }

    /// Records one activity and tells the other agents overlapping on the
    /// repository what was done (RR-526). A ticket action also adds its id
    /// to the sender's entry, so a later overlap notice names it.
    pub fn record_action(&self, activity: &Activity, action: &Action) -> Recorded {
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        let recorded = self.record_locked(&mut state, activity, action.authored_ticket());
        if recorded != Recorded::Ignored {
            self.queue_action_locked(&mut state, activity.session_key, activity.repo_path, action);
        }
        if swept || recorded != Recorded::Ignored {
            self.save(&state);
        }
        recorded
    }

    /// Tells the other agents overlapping with `session_key` on `repo_path`
    /// what it did, without recording activity: for a daemon event such as
    /// a run it dispatched ending. Nothing when the sender has no entry
    /// there.
    pub fn notify_action(&self, session_key: &str, repo_path: &str, action: &Action) {
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        let queued = self.queue_action_locked(&mut state, session_key, repo_path, action);
        if swept || queued {
            self.save(&state);
        }
    }

    /// The resolved repository path presence keys entries by, or `None` for
    /// an empty path or general-tasks.
    fn repo_key(&self, repo_path: &str) -> Option<String> {
        let repo = resolve_path(repo_path);
        if repo_path.trim().is_empty() || self.is_general(&repo) {
            return None;
        }
        Some(repo.to_string_lossy().into_owned())
    }

    fn record_locked(
        &self,
        state: &mut State,
        activity: &Activity,
        ticket: Option<&str>,
    ) -> Recorded {
        let Some(repo_text) = self.repo_key(activity.repo_path) else {
            return Recorded::Ignored;
        };
        let Some(session) = state
            .sessions
            .iter()
            .find(|session| session.key == activity.session_key)
            .cloned()
        else {
            return Recorded::Ignored;
        };
        let now = (self.clock)();
        let note = activity.note.map(one_line);
        let ticket = ticket
            .map(|ticket| json::py_strip(ticket).to_uppercase())
            .filter(|ticket| !ticket.is_empty());
        let existing = state
            .entries
            .iter_mut()
            .find(|entry| entry.session_key == session.key && entry.repo_path == repo_text);
        if let Some(entry) = existing {
            entry.last_seen = now;
            if let Some(note) = note {
                entry.note = note;
            }
            if let Some(ticket) = ticket {
                remember_ticket(&mut entry.tickets, ticket);
            }
            return Recorded::Refreshed;
        }
        let detail = json::py_strip(activity.detail).to_string();
        let name = agent_name(&session.agent);
        let repository = repository_name(&repo_text);
        let started = if detail.is_empty() {
            format!("Agent notice: {name} started working in {repository}.")
        } else {
            format!("Agent notice: {name} started working in {repository} ({detail}).")
        };
        let entry = Entry {
            agent: session.agent.clone(),
            session_key: session.key.clone(),
            repo_path: repo_text.clone(),
            source: activity.source,
            detail,
            note: note.unwrap_or_default(),
            tickets: ticket.into_iter().collect(),
            first_seen: now,
            last_seen: now,
        };
        // RR-526: an agent already in this repository now overlaps with this
        // one. Each of the two hears about the other instead of the plain
        // started notice; every other running agent gets that one.
        let overlapping: Vec<Entry> = state
            .entries
            .iter()
            .filter(|other| other.repo_path == repo_text && other.session_key != session.key)
            .cloned()
            .collect();
        let receivers: Vec<String> = state
            .sessions
            .iter()
            .filter(|other| other.key != session.key)
            .map(|other| other.key.clone())
            .collect();
        for receiver in receivers {
            let text = if overlapping
                .iter()
                .any(|other| other.session_key == receiver)
            {
                format!(
                    "Agent notice: {name} started working in {repository}, where you are \
                     working too{}.",
                    work_known(&entry)
                )
            } else {
                started.clone()
            };
            Self::queue_for(state, &receiver, &text, "", now);
        }
        for other in &overlapping {
            let text = format!(
                "Agent notice: {} is also working in {repository}{}.",
                agent_name(&other.agent),
                work_known(other)
            );
            Self::queue_for(state, &session.key, &text, "", now);
        }
        state.entries.push(entry);
        Recorded::Entered
    }

    /// Queues `action` for every other session with an entry in the
    /// repository, when the sender has one there too. True when anything
    /// was queued.
    fn queue_action_locked(
        &self,
        state: &mut State,
        sender: &str,
        repo_path: &str,
        action: &Action,
    ) -> bool {
        let Some(repo_text) = self.repo_key(repo_path) else {
            return false;
        };
        let Some(agent) = state
            .entries
            .iter()
            .find(|entry| entry.session_key == sender && entry.repo_path == repo_text)
            .map(|entry| entry.agent.clone())
        else {
            return false;
        };
        let receivers: Vec<String> = state
            .entries
            .iter()
            .filter(|entry| entry.repo_path == repo_text && entry.session_key != sender)
            .map(|entry| entry.session_key.clone())
            .collect();
        if receivers.is_empty() {
            return false;
        }
        let now = (self.clock)();
        let name = agent_name(&agent);
        let repository = repository_name(&repo_text);
        let key = action.collapse_key(sender, &repo_text);
        for receiver in receivers {
            let collapsed = (!key.is_empty())
                .then(|| {
                    state
                        .notices
                        .iter_mut()
                        .find(|notice| notice.receiver == receiver && notice.key == key)
                })
                .flatten();
            match collapsed {
                Some(notice) => {
                    notice.count += 1;
                    notice.text = action.text(&name, &repository, notice.count);
                }
                None => {
                    let text = action.text(&name, &repository, 1);
                    Self::queue_for(state, &receiver, &text, &key, now);
                }
            }
        }
        true
    }

    /// Queues `text` for one receiver, keeping its queue within
    /// `RECEIVER_QUEUE_LIMIT`; `key` lets later notices collapse into it.
    fn queue_for(state: &mut State, receiver: &str, text: &str, key: &str, now: f64) {
        state.next_seq += 1;
        state.notices.push(Notice {
            receiver: receiver.to_string(),
            seq: state.next_seq,
            text: text.to_string(),
            created_at: now,
            key: key.to_string(),
            count: 1,
        });
        let queued = state
            .notices
            .iter()
            .filter(|notice| notice.receiver == receiver)
            .count();
        if queued > RECEIVER_QUEUE_LIMIT
            && let Some(oldest) = state
                .notices
                .iter()
                .position(|notice| notice.receiver == receiver)
        {
            state.notices.remove(oldest);
            match state.overflow.iter_mut().find(|(key, _)| key == receiver) {
                Some((_, count)) => *count += 1,
                None => state.overflow.push((receiver.to_string(), 1)),
            }
        }
    }

    /// Brings the record up to date with the spools and the clock: a session
    /// whose spool went (or was recreated) stopped, so its entries and
    /// queued notices go and the others hear once which repositories it
    /// left; idle entries expire. An agent that overlapped with the one that
    /// stopped or expired hears that the overlap ended. True when anything
    /// changed.
    fn sweep(&self, state: &mut State) -> bool {
        let live = self.live_sessions();
        let now = (self.clock)();
        let mut changed = false;
        let stopped: Vec<LiveSession> = state
            .sessions
            .iter()
            .filter(|known| !live.contains(known))
            .cloned()
            .collect();
        state.sessions = live;
        for session in &stopped {
            let mut repos: Vec<String> = state
                .entries
                .iter()
                .filter(|entry| entry.session_key == session.key)
                .map(|entry| entry.repo_path.clone())
                .collect();
            repos.dedup();
            state
                .entries
                .retain(|entry| entry.session_key != session.key);
            let left: Vec<String> = repos.iter().map(|repo| repository_name(repo)).collect();
            let name = agent_name(&session.agent);
            let text = if left.is_empty() {
                format!("Agent notice: {name} stopped.")
            } else {
                format!("Agent notice: {name} stopped and left {}.", left.join(", "))
            };
            let receivers: Vec<String> = state
                .sessions
                .iter()
                .filter(|other| other.key != session.key)
                .map(|other| other.key.clone())
                .collect();
            for receiver in receivers {
                let shared: Vec<String> = repos
                    .iter()
                    .filter(|repo| {
                        state
                            .entries
                            .iter()
                            .any(|entry| entry.session_key == receiver && &entry.repo_path == *repo)
                    })
                    .map(|repo| repository_name(repo))
                    .collect();
                let text = if shared.is_empty() {
                    text.clone()
                } else {
                    format!(
                        "{} You no longer share {} with {name}.",
                        text,
                        shared.join(", ")
                    )
                };
                Self::queue_for(state, &receiver, &text, "", now);
            }
            changed = true;
        }
        let live_keys: Vec<String> = state
            .sessions
            .iter()
            .map(|session| session.key.clone())
            .collect();
        // RR-526: an idle entry that expires ends its overlaps; the agent
        // still in the repository hears once.
        let expiring = |entry: &Entry| now - entry.last_seen >= IDLE_SECONDS;
        let ended: Vec<(String, String)> = state
            .entries
            .iter()
            .filter(|entry| live_keys.contains(&entry.session_key) && expiring(entry))
            .flat_map(|gone| {
                state
                    .entries
                    .iter()
                    .filter(|other| {
                        other.repo_path == gone.repo_path
                            && other.session_key != gone.session_key
                            && live_keys.contains(&other.session_key)
                            && !expiring(other)
                    })
                    .map(|other| {
                        (
                            other.session_key.clone(),
                            format!(
                                "Agent notice: {} has had no activity in {} for two hours, so \
                                 you no longer share it.",
                                agent_name(&gone.agent),
                                repository_name(&gone.repo_path)
                            ),
                        )
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        for (receiver, text) in &ended {
            Self::queue_for(state, receiver, text, "", now);
        }
        changed |= !ended.is_empty();
        let before = (
            state.entries.len(),
            state.notices.len(),
            state.overflow.len(),
        );
        // An entry of a session no sweep has seen (a record from before a
        // restart) goes too.
        state.entries.retain(|entry| {
            live_keys.contains(&entry.session_key) && now - entry.last_seen < IDLE_SECONDS
        });
        state
            .notices
            .retain(|notice| live_keys.contains(&notice.receiver));
        state.overflow.retain(|(key, _)| live_keys.contains(key));
        changed
            || before
                != (
                    state.entries.len(),
                    state.notices.len(),
                    state.overflow.len(),
                )
    }

    /// Hands `session_key` its undelivered notices once: the newest
    /// `NOTICE_DELIVERY_LIMIT`, oldest first, and a count of the rest.
    pub fn claim(&self, session_key: &str) -> Claimed {
        let mut state = guard(&self.state);
        let changed = self.sweep(&mut state);
        let mut mine: Vec<Notice> = Vec::new();
        state.notices.retain(|notice| {
            if notice.receiver == session_key {
                mine.push(notice.clone());
                false
            } else {
                true
            }
        });
        let mut omitted = 0;
        if let Some(position) = state
            .overflow
            .iter()
            .position(|(key, _)| key == session_key)
        {
            omitted += state.overflow.remove(position).1;
        }
        if changed || !mine.is_empty() || omitted > 0 {
            self.save(&state);
        }
        mine.sort_by_key(|notice| notice.seq);
        let excess = mine.len().saturating_sub(NOTICE_DELIVERY_LIMIT);
        omitted += excess as i64;
        Claimed {
            notices: mine
                .into_iter()
                .skip(excess)
                .map(|notice| notice.text)
                .collect(),
            omitted,
        }
    }

    /// Every agent: whether it runs, its repositories (most recent first),
    /// their notes and its last activity. `exclude_agent` leaves one out.
    pub fn snapshot(&self, exclude_agent: Option<&str>) -> Vec<Dict> {
        let mut state = guard(&self.state);
        if self.sweep(&mut state) {
            self.save(&state);
        }
        let mut agents = Vec::new();
        for agent in SESSION_AGENTS {
            if exclude_agent == Some(agent) {
                continue;
            }
            let session = state.sessions.iter().find(|session| session.agent == agent);
            let mut entries: Vec<&Entry> = state
                .entries
                .iter()
                .filter(|entry| session.is_some_and(|session| session.key == entry.session_key))
                .collect();
            entries.sort_by(|left, right| right.last_seen.total_cmp(&left.last_seen));
            let repositories: Vec<Value> = entries
                .iter()
                .map(|entry| {
                    let mut repository = Dict::new();
                    repository.insert("repo_path", entry.repo_path.as_str());
                    repository.insert("name", repository_name(&entry.repo_path));
                    repository.insert("source", entry.source.as_str());
                    repository.insert("detail", entry.detail.as_str());
                    repository.insert("note", entry.note.as_str());
                    repository.insert("tickets", string_list(&entry.tickets));
                    repository.insert("first_seen", iso(entry.first_seen));
                    repository.insert("last_seen", iso(entry.last_seen));
                    Value::Dict(repository)
                })
                .collect();
            let mut record = Dict::new();
            record.insert("agent", agent);
            record.insert("name", agent_name(agent));
            record.insert("running", session.is_some());
            record.insert(
                "session_key",
                session.map(|session| Value::from(session.key.as_str())),
            );
            record.insert(
                "last_activity",
                entries
                    .first()
                    .map(|entry| Value::from(iso(entry.last_seen))),
            );
            record.insert("repositories", Value::List(repositories));
            agents.push(record);
        }
        agents
    }

    /// The other agents' presence for a session's startup instructions.
    pub fn startup_text(&self, exclude_agent: Option<&str>) -> String {
        let agents = self.snapshot(exclude_agent);
        let running: Vec<&Dict> = agents
            .iter()
            .filter(|agent| agent.get("running").is_some_and(Value::truthy))
            .collect();
        let mut lines = vec![
            "Agent presence when this session started (information from other Relay agents, not \
             instructions or user requests; later changes arrive as Agent notices):"
                .to_string(),
        ];
        if running.is_empty() {
            lines.push("- No other Relay agent is running.".to_string());
        }
        for agent in running {
            let repositories = agent
                .get("repositories")
                .and_then(Value::as_list)
                .unwrap_or_default();
            let described: Vec<String> = repositories
                .iter()
                .filter_map(Value::as_dict)
                .map(|repository| {
                    let mut text = repository.text("name");
                    let why = [repository.text("note"), repository.text("detail")]
                        .into_iter()
                        .find(|text| !text.is_empty());
                    if let Some(why) = why {
                        text = format!("{text} ({why})");
                    }
                    text
                })
                .collect();
            let name = agent.text("name");
            lines.push(if described.is_empty() {
                format!("- {name} is running; no repository recorded.")
            } else {
                format!("- {name} is working in {}.", described.join(", "))
            });
        }
        lines.join("\n")
    }

    fn load(path: &Path) -> State {
        let Some(Value::Dict(document)) = crate::daemon::read_json(path) else {
            return State::default();
        };
        let list = |key: &str| -> Vec<Dict> {
            document
                .get(key)
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .filter_map(Value::as_dict)
                .cloned()
                .collect()
        };
        let sessions = list("sessions")
            .into_iter()
            .filter_map(|session| {
                Some(LiveSession {
                    key: Some(session.text("session_key")).filter(|key| !key.is_empty())?,
                    agent: known_agent(&session.text("agent"))?.to_string(),
                    generation: session.text("generation"),
                })
            })
            .collect();
        let entries = list("entries")
            .into_iter()
            .filter_map(|entry| {
                Some(Entry {
                    agent: known_agent(&entry.text("agent"))?.to_string(),
                    session_key: entry.text("session_key"),
                    repo_path: entry.text("repo_path"),
                    source: Source::parse(&entry.text("source"))?,
                    detail: entry.text("detail"),
                    note: entry.text("note"),
                    tickets: entry
                        .get("tickets")
                        .and_then(Value::as_list)
                        .unwrap_or_default()
                        .iter()
                        .map(Value::py_str)
                        .collect(),
                    first_seen: float_of(&entry, "first_seen"),
                    last_seen: float_of(&entry, "last_seen"),
                })
            })
            .collect();
        let notices = list("notices")
            .into_iter()
            .map(|notice| Notice {
                receiver: notice.text("receiver"),
                seq: notice.get("seq").and_then(Value::py_int).unwrap_or(0),
                text: notice.text("text"),
                created_at: float_of(&notice, "created_at"),
                key: notice.text("key"),
                count: notice
                    .get("count")
                    .and_then(Value::py_int)
                    .unwrap_or(1)
                    .max(1),
            })
            .collect();
        let overflow = list("overflow")
            .into_iter()
            .map(|item| {
                (
                    item.text("receiver"),
                    item.get("count").and_then(Value::py_int).unwrap_or(0),
                )
            })
            .collect();
        State {
            sessions,
            entries,
            notices,
            overflow,
            next_seq: document
                .get("next_seq")
                .and_then(Value::py_int)
                .unwrap_or(0),
        }
    }

    /// Writes the record atomically; a failure is logged, never raised, so a
    /// presence write never fails the mutation that caused it.
    fn save(&self, state: &State) {
        let mut document = Dict::new();
        document.insert("schema_version", SCHEMA_VERSION);
        let sessions = state
            .sessions
            .iter()
            .map(|session| {
                let mut item = Dict::new();
                item.insert("session_key", session.key.as_str());
                item.insert("agent", session.agent.as_str());
                item.insert("generation", session.generation.as_str());
                Value::Dict(item)
            })
            .collect();
        let entries = state
            .entries
            .iter()
            .map(|entry| {
                let mut item = Dict::new();
                item.insert("agent", entry.agent.as_str());
                item.insert("session_key", entry.session_key.as_str());
                item.insert("repo_path", entry.repo_path.as_str());
                item.insert("source", entry.source.as_str());
                item.insert("detail", entry.detail.as_str());
                item.insert("note", entry.note.as_str());
                item.insert("tickets", string_list(&entry.tickets));
                item.insert("first_seen", entry.first_seen);
                item.insert("last_seen", entry.last_seen);
                Value::Dict(item)
            })
            .collect();
        let notices = state
            .notices
            .iter()
            .map(|notice| {
                let mut item = Dict::new();
                item.insert("receiver", notice.receiver.as_str());
                item.insert("seq", notice.seq);
                item.insert("text", notice.text.as_str());
                item.insert("created_at", notice.created_at);
                if !notice.key.is_empty() {
                    item.insert("key", notice.key.as_str());
                    item.insert("count", notice.count);
                }
                Value::Dict(item)
            })
            .collect();
        let overflow = state
            .overflow
            .iter()
            .map(|(receiver, count)| {
                let mut item = Dict::new();
                item.insert("receiver", receiver.as_str());
                item.insert("count", *count);
                Value::Dict(item)
            })
            .collect();
        document.insert("sessions", Value::List(sessions));
        document.insert("entries", Value::List(entries));
        document.insert("notices", Value::List(notices));
        document.insert("overflow", Value::List(overflow));
        document.insert("next_seq", state.next_seq);
        let temporary = self.path.with_extension("json.tmp");
        let written = fs::write(&temporary, json::dumps(&Value::Dict(document)))
            .and_then(|()| fs::rename(&temporary, &self.path));
        if let Err(error) = written {
            eprintln!("[orchestrator] agent presence not saved: {error}");
        }
    }
}

/// The session key a request names in `field`, when it is a valid key.
fn session_key_in(request: &Request, field: &str) -> Option<String> {
    optional_relay_session_key(request.get(field))
}

impl Daemon {
    /// Records presence for a mutation that named `repo_path` and, in
    /// `session_key`, the session that made it. A request without a session
    /// key records nothing.
    pub fn note_presence(
        &self,
        session_key: Option<&str>,
        repo_path: &str,
        source: Source,
        detail: &str,
    ) {
        let Some(session_key) = session_key else {
            return;
        };
        self.presence.record(&Activity {
            session_key,
            repo_path,
            source,
            detail,
            note: None,
        });
    }

    /// RR-526: records presence like `note_presence`, then tells the other
    /// agents overlapping on `repo_path` what the session did.
    pub fn note_action(
        &self,
        session_key: Option<&str>,
        repo_path: &str,
        source: Source,
        detail: &str,
        action: &Action,
    ) {
        let Some(session_key) = session_key else {
            return;
        };
        self.presence.record_action(
            &Activity {
                session_key,
                repo_path,
                source,
                detail,
                note: None,
            },
            action,
        );
    }

    /// RR-526: a run ended. The agents overlapping with the session that
    /// dispatched it hear the outcome, because a merge changes the shared
    /// checkout. Nothing for a run no session dispatched.
    pub fn note_run_ended(&self, repo_path: &str, ticket_id: &str, kind: &str) {
        let outcome = match kind {
            "run-merged" => "merged into the checkout",
            "run-verification-blocked" => {
                "merged into the checkout and is waiting on external verification"
            }
            "run-failed" => "failed",
            _ => return,
        };
        let dispatcher = match self.messenger_outcomes.dispatcher(repo_path, ticket_id) {
            Ok(Some(dispatcher)) => dispatcher,
            Ok(None) => return,
            Err(error) => {
                eprintln!("[orchestrator] run dispatcher unknown for agent notices: {error}");
                return;
            }
        };
        let ticket_id = json::py_strip(ticket_id).to_uppercase();
        self.presence.notify_action(
            &dispatcher,
            repo_path,
            &Action::RunEnded {
                ticket_id: &ticket_id,
                outcome,
            },
        );
    }

    /// The session key of a mutating request: `relay_session_key`.
    pub fn request_session_key(request: &Request) -> Option<String> {
        session_key_in(request, "relay_session_key")
    }

    /// `GET /v1/agent-presence`: every agent's presence, read only.
    /// `exclude_agent` leaves one agent out of the answer and of
    /// `startup_text`, the block a starting session's instructions carry.
    pub fn agent_presence_route(&self, request: &Request) -> Outcome<Reply> {
        let exclude = request.query_first("exclude_agent");
        let exclude = exclude.as_deref().and_then(known_agent);
        let mut body = Dict::new();
        body.insert(
            "agents",
            Value::List(
                self.presence
                    .snapshot(exclude)
                    .into_iter()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        body.insert("startup_text", self.presence.startup_text(exclude));
        reply(200, body)
    }

    /// `POST /v1/agent-presence`: the read tool. Every agent's presence, and
    /// the caller's undelivered notices, which this delivers.
    pub fn read_agent_presence_route(&self, request: &Request) -> Outcome<Reply> {
        let caller = relay_session_key(request.get("relay_session_key"))?;
        let mut body = Dict::new();
        let claimed = caller
            .as_deref()
            .map(|key| self.presence.claim(key))
            .unwrap_or_default();
        body.insert(
            "agents",
            Value::List(
                self.presence
                    .snapshot(None)
                    .into_iter()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        claimed.insert_into(&mut body);
        reply(200, body)
    }

    /// `POST /v1/agent-presence/declare`: the caller starts work in a
    /// repository the daemon cannot see it in, with a one-line note and, from
    /// RR-526, the optional `paths` it is about to change.
    pub fn declare_agent_presence_route(&self, request: &Request) -> Outcome<Reply> {
        let caller = relay_session_key(request.get("relay_session_key"))?
            .ok_or_else(|| Failure::value("relay_session_key is required"))?;
        let repo_path = request.text("repo_path");
        if repo_path.trim().is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let repo = resolve_path(&repo_path);
        if !repo.is_dir() {
            return Err(Failure::value(format!(
                "repo_path {} is not a directory",
                repo.display()
            )));
        }
        if !self
            .presence
            .live_sessions()
            .iter()
            .any(|session| session.key == caller)
        {
            return Err(Failure::value(
                "relay_session_key names no running Relay agent session",
            ));
        }
        let note = one_line(&request.text("note"));
        // RR-526: optional paths the caller is about to change. The agents
        // overlapping on the repository hear the declaration; the answer
        // carries the caller's own notices, so a collision shows at once.
        let paths = match request.get("paths") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::List(items)) => {
                let mut paths = Vec::new();
                for item in items {
                    let Value::Str(path) = item else {
                        return Err(Failure::value("paths must be a list of strings"));
                    };
                    paths.push(path.clone());
                }
                bounded_paths(&paths)
            }
            Some(_) => return Err(Failure::value("paths must be a list of strings")),
        };
        let recorded = self.presence.record_action(
            &Activity {
                session_key: &caller,
                repo_path: &repo.to_string_lossy(),
                source: Source::Declared,
                detail: &note,
                note: Some(&note),
            },
            &Action::DirectWork {
                description: &note,
                paths: &paths,
            },
        );
        let mut body = Dict::new();
        body.insert(
            "declared",
            match recorded {
                Recorded::Entered => "entered",
                Recorded::Refreshed => "refreshed",
                Recorded::Ignored => "ignored",
            },
        );
        let claimed = self.presence.claim(&caller);
        body.insert(
            "agents",
            Value::List(
                self.presence
                    .snapshot(None)
                    .into_iter()
                    .map(Value::Dict)
                    .collect(),
            ),
        );
        claimed.insert_into(&mut body);
        reply(200, body)
    }

    /// `POST /v1/agent-notices/claim`: the caller's undelivered notices,
    /// delivered once. The voice bridge and the prompt-submit hook read it.
    pub fn claim_agent_notices_route(&self, request: &Request) -> Outcome<Reply> {
        let caller = relay_session_key(request.get("relay_session_key"))?;
        let claimed = caller
            .as_deref()
            .map(|key| self.presence.claim(key))
            .unwrap_or_default();
        let mut body = Dict::new();
        claimed.insert_into(&mut body);
        reply(200, body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A temporary spool root, record file and general-tasks folder, with a
    /// clock the test moves.
    struct Fixture {
        root: PathBuf,
        clock: Arc<AtomicU64>,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "relay-presence-{name}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("relay-sessions")).unwrap();
            fs::create_dir_all(root.join("general-tasks")).unwrap();
            fs::create_dir_all(root.join("relay-runner")).unwrap();
            fs::create_dir_all(root.join("docs-site")).unwrap();
            Self {
                root,
                clock: Arc::new(AtomicU64::new(1_000_000)),
            }
        }

        fn open(&self) -> Presence {
            let clock = self.clock.clone();
            Presence::open(
                self.root.join("agent_presence.json"),
                self.root.join("relay-sessions"),
                &self.root.join("general-tasks"),
                Box::new(move || clock.load(Ordering::SeqCst) as f64),
            )
        }

        fn start(&self, key: &str, agent: &str) {
            let spool = self.root.join("relay-sessions").join(key);
            fs::create_dir_all(&spool).unwrap();
            fs::write(spool.join("session_agent"), format!("{agent}\n")).unwrap();
        }

        fn stop(&self, key: &str) {
            fs::remove_dir_all(self.root.join("relay-sessions").join(key)).unwrap();
        }

        fn advance(&self, seconds: u64) {
            self.clock.fetch_add(seconds, Ordering::SeqCst);
        }

        fn repo(&self, name: &str) -> String {
            self.root.join(name).to_string_lossy().into_owned()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn activity<'a>(key: &'a str, repo: &'a str, detail: &'a str) -> Activity<'a> {
        Activity {
            session_key: key,
            repo_path: repo,
            source: Source::Dispatch,
            detail,
            note: None,
        }
    }

    fn repositories(presence: &Presence, agent: &str) -> Vec<String> {
        presence
            .snapshot(None)
            .into_iter()
            .find(|record| record.string("agent") == agent)
            .unwrap()
            .get("repositories")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .map(|repository| repository.text("name"))
            .collect()
    }

    #[test]
    fn first_activity_tells_each_other_running_agent_once() {
        let fixture = Fixture::new("notices");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let repo = fixture.repo("relay-runner");

        assert_eq!(
            presence.record(&activity("george-1", &repo, "dispatched RR-530")),
            Recorded::Entered
        );
        assert_eq!(
            presence.record(&activity("george-1", &repo, "wrote ticket RR-531")),
            Recorded::Refreshed
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec!["Agent notice: George started working in relay-runner (dispatched RR-530)."]
        );
        assert_eq!(presence.claim("george-1"), Claimed::default());
        assert_eq!(presence.claim("puck-1"), Claimed::default());
    }

    #[test]
    fn no_notice_is_queued_for_an_agent_that_is_not_running() {
        let fixture = Fixture::new("absent");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        presence.record(&activity("george-1", &fixture.repo("relay-runner"), ""));
        // Sky starts only now: the notice was never queued for it.
        fixture.start("sky-1", "sky");
        assert_eq!(presence.claim("sky-1"), Claimed::default());
        assert!(guard(&presence.state).notices.is_empty());
    }

    #[test]
    fn a_stopped_agent_leaves_its_repositories_and_the_others_hear_once() {
        let fixture = Fixture::new("stopped");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        presence.record(&activity("george-1", &fixture.repo("relay-runner"), ""));
        presence.record(&activity("george-1", &fixture.repo("docs-site"), ""));
        presence.claim("puck-1");

        fixture.stop("george-1");
        assert!(repositories(&presence, "george").is_empty());
        assert_eq!(
            presence.claim("puck-1").notices,
            vec!["Agent notice: George stopped and left relay-runner, docs-site."]
        );
        assert_eq!(presence.claim("puck-1"), Claimed::default());
        let george = presence
            .snapshot(None)
            .into_iter()
            .find(|record| record.string("agent") == "george")
            .unwrap();
        assert!(!george.get("running").unwrap().truthy());
    }

    #[test]
    fn a_repository_leaves_the_set_after_two_idle_hours() {
        let fixture = Fixture::new("idle");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let repo = fixture.repo("relay-runner");
        presence.record(&activity("george-1", &repo, ""));
        fixture.advance(IDLE_SECONDS as u64 - 60);
        assert_eq!(repositories(&presence, "george"), vec!["relay-runner"]);
        presence.record(&activity("george-1", &repo, ""));
        fixture.advance(IDLE_SECONDS as u64 - 60);
        assert_eq!(repositories(&presence, "george"), vec!["relay-runner"]);
        fixture.advance(120);
        assert!(repositories(&presence, "george").is_empty());
        // Back after expiry, it is new again.
        fixture.start("puck-1", "puck");
        assert_eq!(
            presence.record(&activity("george-1", &repo, "")),
            Recorded::Entered
        );
        assert_eq!(presence.claim("puck-1").notices.len(), 1);
    }

    #[test]
    fn a_session_that_no_longer_exists_is_gone_after_a_restart() {
        let fixture = Fixture::new("restart");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        presence.record(&activity("george-1", &fixture.repo("relay-runner"), ""));
        presence.record(&activity("puck-1", &fixture.repo("docs-site"), ""));
        drop(presence);

        // Both survive a restart while their sessions run.
        let presence = fixture.open();
        assert_eq!(repositories(&presence, "george"), vec!["relay-runner"]);
        drop(presence);

        // George's session ended while the daemon was down.
        fixture.stop("george-1");
        let presence = fixture.open();
        assert!(repositories(&presence, "george").is_empty());
        assert_eq!(repositories(&presence, "puck"), vec!["docs-site"]);
        let saved = fs::read_to_string(fixture.root.join("agent_presence.json")).unwrap();
        assert!(!saved.contains("george-1"), "{saved}");
    }

    #[test]
    fn general_tasks_and_unknown_sessions_record_nothing() {
        let fixture = Fixture::new("general");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let general = fixture.repo("general-tasks");
        assert_eq!(
            presence.record(&activity("george-1", &general, "")),
            Recorded::Ignored
        );
        let inside = format!("{general}/notes");
        assert_eq!(
            presence.record(&activity("george-1", &inside, "")),
            Recorded::Ignored
        );
        assert_eq!(
            presence.record(&activity("nobody", &fixture.repo("relay-runner"), "")),
            Recorded::Ignored
        );
        assert!(repositories(&presence, "george").is_empty());
        assert_eq!(presence.claim("puck-1"), Claimed::default());
    }

    #[test]
    fn a_spool_without_a_known_agent_is_not_a_running_agent() {
        let fixture = Fixture::new("unknown-agent");
        fixture.start("oberon-1", "oberon");
        fs::create_dir_all(fixture.root.join("relay-sessions").join("bare")).unwrap();
        fs::create_dir_all(fixture.root.join("relay-sessions").join("Not A Key")).unwrap();
        let presence = fixture.open();
        assert!(presence.live_sessions().is_empty());
    }

    #[test]
    fn the_snapshot_lists_all_four_agents_with_notes() {
        let fixture = Fixture::new("snapshot");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        presence.record(&Activity {
            session_key: "george-1",
            repo_path: &fixture.repo("relay-runner"),
            source: Source::Declared,
            detail: "reading the bridge code",
            note: Some("reading the bridge code\nsecond line"),
        });
        let agents = presence.snapshot(None);
        let names: Vec<String> = agents.iter().map(|agent| agent.text("name")).collect();
        assert_eq!(names, vec!["Puck", "Isabella", "George", "Sky"]);
        let george = &agents[2];
        assert!(george.get("running").unwrap().truthy());
        assert_eq!(george.text("session_key"), "george-1");
        let repository = george.get("repositories").unwrap().as_list().unwrap()[0]
            .as_dict()
            .unwrap()
            .clone();
        assert_eq!(repository.text("note"), "reading the bridge code");
        assert_eq!(repository.text("source"), "declared");
        assert!(george.text("last_activity").ends_with('Z'));
        assert!(!agents[0].get("running").unwrap().truthy());
        assert!(matches!(agents[0].get("last_activity"), Some(Value::Null)));
        assert_eq!(presence.snapshot(Some("george")).len(), 3);
    }

    #[test]
    fn startup_text_describes_the_other_running_agents() {
        let fixture = Fixture::new("startup");
        fixture.start("george-1", "george");
        fixture.start("sky-1", "sky");
        let presence = fixture.open();
        presence.record(&activity(
            "george-1",
            &fixture.repo("relay-runner"),
            "dispatched RR-530",
        ));
        let text = presence.startup_text(Some("puck"));
        assert!(text.starts_with("Agent presence when this session started"));
        assert!(text.contains("- George is working in relay-runner (dispatched RR-530)."));
        assert!(text.contains("- Sky is running; no repository recorded."));
        assert!(!text.contains("Puck"));
        let alone = presence.startup_text(Some("george"));
        assert!(!alone.contains("George"));
        fixture.stop("sky-1");
        assert!(
            presence
                .startup_text(Some("george"))
                .contains("No other Relay agent is running.")
        );
    }

    #[test]
    fn more_than_ten_pending_delivers_the_newest_ten_and_counts_the_rest() {
        let fixture = Fixture::new("limit");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        for index in 0..13 {
            let repo = fixture.root.join(format!("repo-{index:02}"));
            fs::create_dir_all(&repo).unwrap();
            presence.record(&activity("george-1", &repo.to_string_lossy(), ""));
        }
        let claimed = presence.claim("puck-1");
        assert_eq!(claimed.omitted, 3);
        assert_eq!(claimed.notices.len(), 10);
        assert!(claimed.notices[0].contains("repo-03"));
        assert!(claimed.notices[9].contains("repo-12"));
        let block = claimed.block();
        assert!(block.starts_with("Agent notices"));
        assert!(block.ends_with("- 3 older agent notices not shown."));
        assert_eq!(presence.claim("puck-1"), Claimed::default());
    }

    #[test]
    fn a_full_queue_counts_what_it_dropped() {
        let fixture = Fixture::new("overflow");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        {
            let mut state = guard(&presence.state);
            presence.sweep(&mut state);
            for index in 0..(RECEIVER_QUEUE_LIMIT + 5) {
                Presence::queue_for(&mut state, "puck-1", &format!("notice {index}"), "", 0.0);
            }
        }
        let claimed = presence.claim("puck-1");
        assert_eq!(claimed.notices.len(), NOTICE_DELIVERY_LIMIT);
        assert_eq!(
            claimed.omitted,
            (RECEIVER_QUEUE_LIMIT + 5 - NOTICE_DELIVERY_LIMIT) as i64
        );
        assert_eq!(
            claimed.notices.last().unwrap(),
            &format!("notice {}", RECEIVER_QUEUE_LIMIT + 4)
        );
    }

    // RR-526: overlap and action notices.

    fn ticket_write<'a>(key: &'a str, repo: &'a str) -> Activity<'a> {
        Activity {
            session_key: key,
            repo_path: repo,
            source: Source::TicketWrite,
            detail: "wrote a ticket",
            note: None,
        }
    }

    fn declared<'a>(key: &'a str, repo: &'a str, note: &'a str) -> Activity<'a> {
        Activity {
            session_key: key,
            repo_path: repo,
            source: Source::Declared,
            detail: note,
            note: Some(note),
        }
    }

    /// Puck, George and Isabella running; Puck and George in relay-runner,
    /// Isabella elsewhere; every queue emptied.
    fn overlapping(fixture: &Fixture) -> Presence {
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        fixture.start("isabella-1", "isabella");
        let presence = fixture.open();
        let repo = fixture.repo("relay-runner");
        presence.record(&declared("puck-1", &repo, "reviewing the hook"));
        presence.record(&declared("george-1", &repo, "fixing the bridge"));
        presence.record(&activity("isabella-1", &fixture.repo("docs-site"), ""));
        for key in ["puck-1", "george-1", "isabella-1"] {
            presence.claim(key);
        }
        presence
    }

    #[test]
    fn an_overlap_tells_each_of_the_two_about_the_other() {
        let fixture = Fixture::new("overlap");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        fixture.start("isabella-1", "isabella");
        let presence = fixture.open();
        let repo = fixture.repo("relay-runner");
        presence.record(&declared("puck-1", &repo, "reviewing the hook"));
        presence.record_action(
            &ticket_write("puck-1", &repo),
            &Action::TicketCreated {
                ticket_id: "RR-600",
                title: "Hook review",
            },
        );
        presence.record_action(
            &activity("puck-1", &repo, "dispatched RR-601"),
            &Action::TicketDispatched {
                ticket_id: "RR-601",
                queued: false,
            },
        );
        for key in ["puck-1", "george-1", "isabella-1"] {
            presence.claim(key);
        }

        // George's first activity here is a ticket write: the overlap begins.
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketCreated {
                ticket_id: "RR-602",
                title: "Bridge fix",
            },
        );
        let puck = presence.claim("puck-1").notices;
        assert_eq!(
            puck,
            vec![
                "Agent notice: George started working in relay-runner, where you are working \
                 too (tickets: RR-602).",
                "Agent notice: George created ticket RR-602 \"Bridge fix\" in relay-runner.",
            ]
        );
        assert_eq!(
            presence.claim("george-1").notices,
            vec![
                "Agent notice: Puck is also working in relay-runner (note: reviewing the hook; \
                 tickets: RR-600, RR-601)."
            ]
        );
        // Isabella shares nothing: the RR-525 started notice only.
        assert_eq!(
            presence.claim("isabella-1").notices,
            vec!["Agent notice: George started working in relay-runner (wrote a ticket)."]
        );
        // Each heard once: more activity is not a new overlap.
        presence.record(&ticket_write("george-1", &repo));
        assert_eq!(presence.claim("puck-1"), Claimed::default());
        assert_eq!(presence.claim("george-1"), Claimed::default());
        let george = presence
            .snapshot(None)
            .into_iter()
            .find(|record| record.string("agent") == "george")
            .unwrap();
        let repository = george.get("repositories").unwrap().as_list().unwrap()[0]
            .as_dict()
            .unwrap()
            .clone();
        let tickets: Vec<String> = repository
            .get("tickets")
            .unwrap()
            .as_list()
            .unwrap()
            .iter()
            .map(Value::py_str)
            .collect();
        assert_eq!(tickets, vec!["RR-602"]);
    }

    #[test]
    fn ticket_dispatch_and_run_actions_reach_only_the_overlapping_agent() {
        let fixture = Fixture::new("actions");
        let presence = overlapping(&fixture);
        let repo = fixture.repo("relay-runner");
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketCreated {
                ticket_id: "RR-610",
                title: "Bridge fix",
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec!["Agent notice: George created ticket RR-610 \"Bridge fix\" in relay-runner."]
        );
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketEdited {
                ticket_id: "RR-610",
                title: "Bridge fix, refined",
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George edited ticket RR-610 \"Bridge fix, refined\" in \
                 relay-runner."
            ]
        );
        presence.record_action(
            &activity("george-1", &repo, "dispatched RR-610"),
            &Action::TicketDispatched {
                ticket_id: "RR-610",
                queued: false,
            },
        );
        presence.record_action(
            &activity("george-1", &repo, "dispatched RR-611"),
            &Action::TicketDispatched {
                ticket_id: "RR-611",
                queued: true,
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George dispatched RR-610 in relay-runner.",
                "Agent notice: George queued RR-611 in relay-runner to start when its \
                 dependencies are done.",
            ]
        );
        presence.notify_action(
            "george-1",
            &repo,
            &Action::RunEnded {
                ticket_id: "RR-610",
                outcome: "merged into the checkout",
            },
        );
        presence.notify_action(
            "george-1",
            &repo,
            &Action::RunEnded {
                ticket_id: "RR-611",
                outcome: "failed",
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George's run of RR-610 in relay-runner merged into the checkout.",
                "Agent notice: George's run of RR-611 in relay-runner failed.",
            ]
        );
        // Isabella runs but is not in relay-runner: none of them. George
        // hears nothing of his own actions.
        assert_eq!(presence.claim("isabella-1"), Claimed::default());
        assert_eq!(presence.claim("george-1"), Claimed::default());
    }

    #[test]
    fn an_agent_without_an_overlap_sends_and_receives_no_action_notice() {
        let fixture = Fixture::new("no-overlap");
        let presence = overlapping(&fixture);
        // Isabella acts in docs-site, where nobody else is.
        presence.record_action(
            &ticket_write("isabella-1", &fixture.repo("docs-site")),
            &Action::TicketCreated {
                ticket_id: "DS-1",
                title: "Docs",
            },
        );
        // A run ending for a session with no entry in the repository is
        // silent too.
        presence.notify_action(
            "isabella-1",
            &fixture.repo("relay-runner"),
            &Action::RunEnded {
                ticket_id: "RR-1",
                outcome: "failed",
            },
        );
        for key in ["puck-1", "george-1", "isabella-1"] {
            assert_eq!(presence.claim(key), Claimed::default(), "{key}");
        }
    }

    #[test]
    fn edits_of_one_ticket_collapse_into_one_line_until_delivery() {
        let fixture = Fixture::new("collapse");
        let presence = overlapping(&fixture);
        let repo = fixture.repo("relay-runner");
        for title in ["First", "Second", "Third"] {
            presence.record_action(
                &ticket_write("george-1", &repo),
                &Action::TicketEdited {
                    ticket_id: "RR-620",
                    title,
                },
            );
        }
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketEdited {
                ticket_id: "RR-621",
                title: "Other",
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George edited ticket RR-620 \"Third\" in relay-runner (3 edits).",
                "Agent notice: George edited ticket RR-621 \"Other\" in relay-runner.",
            ]
        );
        // After delivery a new edit is a new line.
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketEdited {
                ticket_id: "RR-620",
                title: "Fourth",
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec!["Agent notice: George edited ticket RR-620 \"Fourth\" in relay-runner."]
        );
    }

    #[test]
    fn the_overlap_ends_when_the_other_agent_stops() {
        let fixture = Fixture::new("overlap-stop");
        let presence = overlapping(&fixture);
        fixture.stop("george-1");
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George stopped and left relay-runner. You no longer share \
                 relay-runner with George."
            ]
        );
        assert_eq!(
            presence.claim("isabella-1").notices,
            vec!["Agent notice: George stopped and left relay-runner."]
        );
        assert_eq!(presence.claim("puck-1"), Claimed::default());
    }

    #[test]
    fn the_overlap_ends_when_the_other_agents_entry_expires() {
        let fixture = Fixture::new("overlap-expiry");
        let presence = overlapping(&fixture);
        let repo = fixture.repo("relay-runner");
        // Puck keeps working; George goes idle.
        fixture.advance(IDLE_SECONDS as u64 - 60);
        presence.record(&ticket_write("puck-1", &repo));
        assert_eq!(presence.claim("puck-1"), Claimed::default());
        fixture.advance(120);
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George has had no activity in relay-runner for two hours, so \
                 you no longer share it."
            ]
        );
        assert_eq!(presence.claim("george-1"), Claimed::default());
        assert_eq!(presence.claim("isabella-1"), Claimed::default());
        assert_eq!(repositories(&presence, "george"), Vec::<String>::new());
        // No overlap now: George's next action reaches Puck as a new overlap.
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketEdited {
                ticket_id: "RR-630",
                title: "Back",
            },
        );
        let puck = presence.claim("puck-1").notices;
        assert_eq!(puck.len(), 2, "{puck:?}");
        assert!(puck[0].contains("where you are working too"));
    }

    #[test]
    fn declared_direct_work_reaches_the_overlapping_agent_with_its_paths() {
        let fixture = Fixture::new("direct");
        let presence = overlapping(&fixture);
        let repo = fixture.repo("relay-runner");
        // Puck's earlier declaration is queued for George before he declares.
        presence.record_action(
            &declared("puck-1", &repo, "editing the hook parser"),
            &Action::DirectWork {
                description: "editing the hook parser",
                paths: &["rust/relay-rs/src/hook/mod.rs".to_string()],
            },
        );
        let paths = bounded_paths(&[
            "rust/relay-rs/src/hook/mod.rs".to_string(),
            "  ".to_string(),
            "docs/specs/hook-contract.md".to_string(),
        ]);
        presence.record_action(
            &declared("george-1", &repo, "fixing the bridge prompt"),
            &Action::DirectWork {
                description: "fixing the bridge prompt",
                paths: &paths,
            },
        );
        assert_eq!(
            presence.claim("puck-1").notices,
            vec![
                "Agent notice: George declared direct work in relay-runner: fixing the bridge \
                 prompt (paths: rust/relay-rs/src/hook/mod.rs, docs/specs/hook-contract.md)."
            ]
        );
        assert_eq!(
            presence.claim("george-1").notices,
            vec![
                "Agent notice: Puck declared direct work in relay-runner: editing the hook \
                 parser (paths: rust/relay-rs/src/hook/mod.rs)."
            ]
        );
        assert_eq!(presence.claim("isabella-1"), Claimed::default());
    }

    #[test]
    fn action_notices_only_wait_in_the_queue_for_a_claim() {
        let fixture = Fixture::new("silent");
        let presence = overlapping(&fixture);
        let spools = fixture.root.join("relay-sessions");
        let listing = || {
            let mut files: Vec<String> = walk(&spools);
            files.sort();
            files
        };
        let before = listing();
        let repo = fixture.repo("relay-runner");
        presence.record_action(
            &ticket_write("george-1", &repo),
            &Action::TicketCreated {
                ticket_id: "RR-640",
                title: "Silent",
            },
        );
        presence.notify_action(
            "george-1",
            &repo,
            &Action::RunEnded {
                ticket_id: "RR-640",
                outcome: "merged into the checkout",
            },
        );
        // Nothing reached a session's spool, where its inbox, speech and
        // terminal input live: the notices wait for Puck's next claim.
        assert_eq!(listing(), before);
        let saved = fs::read_to_string(fixture.root.join("agent_presence.json")).unwrap();
        assert!(saved.contains("RR-640"), "{saved}");
        assert_eq!(presence.claim("puck-1").notices.len(), 2);
    }

    fn walk(directory: &Path) -> Vec<String> {
        let mut files = Vec::new();
        for item in fs::read_dir(directory).unwrap().flatten() {
            let path = item.path();
            if path.is_dir() {
                files.extend(walk(&path));
            } else {
                files.push(format!(
                    "{}:{}",
                    path.display(),
                    fs::read_to_string(&path).unwrap_or_default()
                ));
            }
        }
        files
    }

    #[test]
    fn collapsed_notices_and_entry_tickets_survive_a_restart() {
        let fixture = Fixture::new("collapse-restart");
        let presence = overlapping(&fixture);
        let repo = fixture.repo("relay-runner");
        let edit = Action::TicketEdited {
            ticket_id: "RR-650",
            title: "Kept",
        };
        presence.record_action(&ticket_write("george-1", &repo), &edit);
        drop(presence);
        let presence = fixture.open();
        presence.record_action(&ticket_write("george-1", &repo), &edit);
        assert_eq!(
            presence.claim("puck-1").notices,
            vec!["Agent notice: George edited ticket RR-650 \"Kept\" in relay-runner (2 edits)."]
        );
        let george = presence
            .snapshot(None)
            .into_iter()
            .find(|record| record.string("agent") == "george")
            .unwrap();
        let repository = george.get("repositories").unwrap().as_list().unwrap()[0]
            .as_dict()
            .unwrap()
            .clone();
        let tickets: Vec<String> = repository
            .get("tickets")
            .unwrap()
            .as_list()
            .unwrap()
            .iter()
            .map(Value::py_str)
            .collect();
        assert_eq!(tickets, vec!["RR-650"]);
    }
}
