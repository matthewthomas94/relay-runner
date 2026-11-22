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
//! - **The notice queue.** `Presence::queue_notice` queues one text for every
//!   other running session, and `Presence::claim` hands a session its
//!   undelivered notices once (newest `NOTICE_DELIVERY_LIMIT`, plus a count
//!   of the rest). Notices for a session that is not running are dropped.
//! - **Delivery.** `POST /v1/agent-notices/claim` is read by the voice
//!   bridge (appended to a voice turn's prompt) and by the prompt-submit
//!   hook (added as context to a typed turn); the presence routes return the
//!   caller's notices too. Nothing here speaks, types into a terminal or
//!   starts a turn.
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

#[derive(Clone, Debug)]
struct Notice {
    receiver: String,
    seq: i64,
    text: String,
    created_at: f64,
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
        let repo = resolve_path(activity.repo_path);
        if activity.repo_path.trim().is_empty() || self.is_general(&repo) {
            return Recorded::Ignored;
        }
        let repo_text = repo.to_string_lossy().into_owned();
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        let Some(session) = state
            .sessions
            .iter()
            .find(|session| session.key == activity.session_key)
            .cloned()
        else {
            if swept {
                self.save(&state);
            }
            return Recorded::Ignored;
        };
        let now = (self.clock)();
        let note = activity.note.map(one_line);
        let existing = state
            .entries
            .iter_mut()
            .find(|entry| entry.session_key == session.key && entry.repo_path == repo_text);
        let recorded = match existing {
            Some(entry) => {
                entry.last_seen = now;
                if let Some(note) = note {
                    entry.note = note;
                }
                Recorded::Refreshed
            }
            None => {
                let detail = json::py_strip(activity.detail).to_string();
                let name = agent_name(&session.agent);
                let repository = repository_name(&repo_text);
                let text = if detail.is_empty() {
                    format!("Agent notice: {name} started working in {repository}.")
                } else {
                    format!("Agent notice: {name} started working in {repository} ({detail}).")
                };
                state.entries.push(Entry {
                    agent: session.agent.clone(),
                    session_key: session.key.clone(),
                    repo_path: repo_text,
                    source: activity.source,
                    detail,
                    note: note.unwrap_or_default(),
                    first_seen: now,
                    last_seen: now,
                });
                Self::queue_notice(&mut state, &session.key, &text, now);
                Recorded::Entered
            }
        };
        self.save(&state);
        recorded
    }

    /// Queues `text` once for every running session but `sender`'s.
    fn queue_notice(state: &mut State, sender: &str, text: &str, now: f64) {
        let receivers: Vec<String> = state
            .sessions
            .iter()
            .filter(|session| session.key != sender)
            .map(|session| session.key.clone())
            .collect();
        for receiver in receivers {
            state.next_seq += 1;
            state.notices.push(Notice {
                receiver: receiver.clone(),
                seq: state.next_seq,
                text: text.to_string(),
                created_at: now,
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
                match state.overflow.iter_mut().find(|(key, _)| *key == receiver) {
                    Some((_, count)) => *count += 1,
                    None => state.overflow.push((receiver, 1)),
                }
            }
        }
    }

    /// Brings the record up to date with the spools and the clock: a session
    /// whose spool went (or was recreated) stopped, so its entries and
    /// queued notices go and the others hear once which repositories it
    /// left; idle entries expire. True when anything changed.
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
            let mut left: Vec<String> = state
                .entries
                .iter()
                .filter(|entry| entry.session_key == session.key)
                .map(|entry| repository_name(&entry.repo_path))
                .collect();
            left.dedup();
            state
                .entries
                .retain(|entry| entry.session_key != session.key);
            let name = agent_name(&session.agent);
            let text = if left.is_empty() {
                format!("Agent notice: {name} stopped.")
            } else {
                format!("Agent notice: {name} stopped and left {}.", left.join(", "))
            };
            Self::queue_notice(state, &session.key, &text, now);
            changed = true;
        }
        let live_keys: Vec<String> = state
            .sessions
            .iter()
            .map(|session| session.key.clone())
            .collect();
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
    /// repository the daemon cannot see it in, with a one-line note.
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
        let recorded = self.presence.record(&Activity {
            session_key: &caller,
            repo_path: &repo.to_string_lossy(),
            source: Source::Declared,
            detail: &note,
            note: Some(&note),
        });
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
                Presence::queue_notice(&mut state, "george-1", &format!("notice {index}"), 0.0);
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
}
