//! Checkout claims (RR-527): at most one Relay agent at a time edits files,
//! switches branches or releases in a registered project's checkout.
//!
//! A claim names the agent, its session key, the checkout, a one-line
//! purpose and the time of the holder's last write. The first direct write
//! by an agent to a free checkout takes it (`Presence::acquire` from the
//! provider's pre-tool hook through `POST /v1/checkout-claims/write`), each
//! further write refreshes it, and a write by any other agent is refused
//! with the holder's name, purpose and last write. A claim is released by its
//! holder, when the holder's session stops (its spool goes, in the presence
//! sweep) and after `CLAIM_IDLE_SECONDS` without a write. Taking and
//! releasing a claim queues one agent notice for every other running agent.
//!
//! Only a registered project's checkout is claimable (`checkout_for`): never
//! the general-tasks folder, the daemon's worker workspaces, or a Claude Code
//! worktree under `.claude/worktrees`. The daemon's own merges into a
//! checkout neither take nor respect a claim (a known gap).

use std::path::{Component, Path, PathBuf};

use relay_intents::json::{Dict, Value};
use relay_services::command_actions::{agent_name, known_agent};

use super::{Presence, State, float_of, iso, one_line, repository_name};
use crate::daemon::{Daemon, guard, registered_project_repo_paths, resolve_path};
use crate::failure::{Failure, Outcome};
use crate::relay_command::relay_session_key;
use crate::request::Request;
use crate::router::{Reply, reply};

/// A claim is released after thirty minutes without a write by its holder.
pub const CLAIM_IDLE_SECONDS: f64 = 30.0 * 60.0;
/// The purpose of a claim taken by a write that named none.
const DEFAULT_PURPOSE: &str = "editing files";

/// One agent's claim on one checkout.
#[derive(Clone, Debug, PartialEq)]
pub struct Claim {
    pub agent: String,
    pub session_key: String,
    pub repo_path: String,
    pub purpose: String,
    pub claimed_at: f64,
    pub last_write: f64,
}

impl Claim {
    pub(super) fn from_dict(dict: &Dict) -> Option<Self> {
        Some(Self {
            agent: known_agent(&dict.text("agent"))?.to_string(),
            session_key: Some(dict.text("session_key")).filter(|key| !key.is_empty())?,
            repo_path: Some(dict.text("repo_path")).filter(|path| !path.is_empty())?,
            purpose: dict.text("purpose"),
            claimed_at: float_of(dict, "claimed_at"),
            last_write: float_of(dict, "last_write"),
        })
    }

    pub(super) fn to_dict(&self) -> Dict {
        let mut dict = Dict::new();
        dict.insert("agent", self.agent.as_str());
        dict.insert("session_key", self.session_key.as_str());
        dict.insert("repo_path", self.repo_path.as_str());
        dict.insert("purpose", self.purpose.as_str());
        dict.insert("claimed_at", self.claimed_at);
        dict.insert("last_write", self.last_write);
        dict
    }

    /// The claim as the routes and tools show it.
    pub fn public(&self, now: f64) -> Dict {
        let mut dict = Dict::new();
        dict.insert("agent", self.agent.as_str());
        dict.insert("name", agent_name(&self.agent));
        dict.insert("session_key", self.session_key.as_str());
        dict.insert("repo_path", self.repo_path.as_str());
        dict.insert("repository", repository_name(&self.repo_path));
        dict.insert("purpose", self.purpose.as_str());
        dict.insert("claimed_at", iso(self.claimed_at));
        dict.insert("last_write", iso(self.last_write));
        dict.insert(
            "expires_at",
            iso(self.last_write + CLAIM_IDLE_SECONDS).as_str(),
        );
        dict.insert("last_write_ago", ago(now - self.last_write));
        dict
    }

    /// What a refused agent is told: who holds the checkout, why and since
    /// when, and that it must stop and ask the user.
    pub fn refusal(&self, now: f64) -> String {
        let name = agent_name(&self.agent);
        let repository = repository_name(&self.repo_path);
        format!(
            "Refused by the Relay checkout claim: {name} holds the claim on the {repository} \
             checkout ({path}) for \"{purpose}\", last write {ago} ({at}). Another Relay agent is \
             changing this checkout. Do not work around this refusal: do not write through another \
             tool, do not copy the checkout, and do not wait or retry in a loop. Stop, tell the user \
             that {name} holds the {repository} checkout and why, and ask how to proceed.",
            path = self.repo_path,
            purpose = self.purpose,
            ago = ago(now - self.last_write),
            at = iso(self.last_write),
        )
    }
}

/// `seconds` as a short "… ago".
fn ago(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as i64;
    match seconds {
        0..=59 => "just now".to_string(),
        60..=119 => "1 minute ago".to_string(),
        120..=3599 => format!("{} minutes ago", seconds / 60),
        _ => format!("{} hours ago", seconds / 3600),
    }
}

/// What `Presence::acquire` did.
#[derive(Clone, Debug, PartialEq)]
pub enum Acquired {
    /// The caller is not a running agent session: nothing is enforced.
    NotAnAgent,
    /// The caller holds every checkout now; `taken` lists the claims this
    /// call took, the rest were refreshed.
    Granted { claims: Vec<Claim>, taken: usize },
    /// Another agent holds one of the checkouts; nothing changed.
    Refused(Claim),
}

/// What `Presence::release` did.
#[derive(Clone, Debug, PartialEq)]
pub enum Released {
    Released(Vec<Claim>),
    /// The caller holds no claim there.
    NotHeld,
    /// Another agent holds it; only its holder can release it.
    HeldByOther(Claim),
}

/// The registered checkout `path` is in, when it is claimable: the longest
/// registered repository containing it, unless the path is in an excluded
/// root (general-tasks, the daemon's workspaces) or a Claude Code worktree
/// (`.claude/worktrees`). `path` and `registered` are resolved paths.
pub fn checkout_for(path: &Path, registered: &[String], excluded: &[PathBuf]) -> Option<String> {
    if excluded.iter().any(|root| path.starts_with(root)) {
        return None;
    }
    let components: Vec<Component> = path.components().collect();
    if components
        .windows(2)
        .any(|pair| pair[0].as_os_str() == ".claude" && pair[1].as_os_str() == "worktrees")
    {
        return None;
    }
    registered
        .iter()
        .filter(|repo| !repo.is_empty() && path.starts_with(repo.as_str()))
        .max_by_key(|repo| repo.len())
        .cloned()
}

fn taken_notice(claim: &Claim) -> String {
    format!(
        "Agent notice: {} took the checkout claim on {} ({}); other agents' edits, branch \
         switches and releases there are refused until it is released.",
        agent_name(&claim.agent),
        repository_name(&claim.repo_path),
        claim.purpose,
    )
}

fn released_notice(claim: &Claim, why: &str) -> String {
    format!(
        "Agent notice: {} released the checkout claim on {} ({why}).",
        agent_name(&claim.agent),
        repository_name(&claim.repo_path),
    )
}

/// The sweep's part for a stopped session: its claims go, and the others
/// hear once per claim.
pub(super) fn release_stopped(state: &mut State, session: &super::LiveSession, now: f64) {
    let mut released = Vec::new();
    state.claims.retain(|claim| {
        if claim.session_key == session.key {
            released.push(claim.clone());
            false
        } else {
            true
        }
    });
    for claim in released {
        let text = released_notice(&claim, &format!("{} stopped", agent_name(&claim.agent)));
        Presence::queue_notice(state, &session.key, &text, now);
    }
}

/// The sweep's part for claims: an idle claim is released with a notice; a
/// claim of a session no sweep has seen goes silently. True when anything
/// changed.
pub(super) fn sweep(state: &mut State, now: f64) -> bool {
    let before = state.claims.len();
    let live: Vec<String> = state
        .sessions
        .iter()
        .map(|session| session.key.clone())
        .collect();
    state
        .claims
        .retain(|claim| live.contains(&claim.session_key));
    let mut idle = Vec::new();
    state.claims.retain(|claim| {
        if now - claim.last_write >= CLAIM_IDLE_SECONDS {
            idle.push(claim.clone());
            false
        } else {
            true
        }
    });
    for claim in &idle {
        let text = released_notice(claim, "30 minutes without a write");
        Presence::queue_notice(state, &claim.session_key, &text, now);
    }
    before != state.claims.len()
}

impl Presence {
    /// A write by `session_key` to `checkouts` (resolved, claimable paths),
    /// or an explicit claim when `explicit`. Each free checkout is taken with
    /// `purpose`, each the caller holds is refreshed (an explicit claim also
    /// replaces its purpose), and nothing changes when another agent holds
    /// any of them.
    pub fn acquire(
        &self,
        session_key: &str,
        checkouts: &[String],
        purpose: &str,
        explicit: bool,
    ) -> Acquired {
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        let Some(session) = state
            .sessions
            .iter()
            .find(|session| session.key == session_key)
            .cloned()
        else {
            if swept {
                self.save(&state);
            }
            return Acquired::NotAnAgent;
        };
        if let Some(held) = state
            .claims
            .iter()
            .find(|claim| claim.session_key != session.key && checkouts.contains(&claim.repo_path))
        {
            let held = held.clone();
            if swept {
                self.save(&state);
            }
            return Acquired::Refused(held);
        }
        let now = (self.clock)();
        let purpose = Some(one_line(purpose))
            .filter(|purpose| !purpose.is_empty())
            .unwrap_or_else(|| DEFAULT_PURPOSE.to_string());
        let mut claims = Vec::new();
        let mut taken = 0;
        for checkout in checkouts {
            if claims
                .iter()
                .any(|claim: &Claim| &claim.repo_path == checkout)
            {
                continue;
            }
            match state
                .claims
                .iter_mut()
                .find(|claim| &claim.repo_path == checkout)
            {
                Some(claim) => {
                    claim.last_write = now;
                    if explicit {
                        claim.purpose = purpose.clone();
                    }
                    claims.push(claim.clone());
                }
                None => {
                    let claim = Claim {
                        agent: session.agent.clone(),
                        session_key: session.key.clone(),
                        repo_path: checkout.clone(),
                        purpose: purpose.clone(),
                        claimed_at: now,
                        last_write: now,
                    };
                    state.claims.push(claim.clone());
                    Self::queue_notice(&mut state, &session.key, &taken_notice(&claim), now);
                    claims.push(claim);
                    taken += 1;
                }
            }
        }
        self.save(&state);
        Acquired::Granted { claims, taken }
    }

    /// `session_key` releases its claim on `checkout`, or every claim it
    /// holds when `checkout` is `None`.
    pub fn release(&self, session_key: &str, checkout: Option<&str>) -> Released {
        let mut state = guard(&self.state);
        let swept = self.sweep(&mut state);
        if let Some(checkout) = checkout
            && let Some(held) = state
                .claims
                .iter()
                .find(|claim| claim.repo_path == checkout && claim.session_key != session_key)
        {
            let held = held.clone();
            if swept {
                self.save(&state);
            }
            return Released::HeldByOther(held);
        }
        let mut released = Vec::new();
        state.claims.retain(|claim| {
            let mine = claim.session_key == session_key
                && checkout.is_none_or(|checkout| claim.repo_path == checkout);
            if mine {
                released.push(claim.clone());
            }
            !mine
        });
        let now = (self.clock)();
        for claim in &released {
            Self::queue_notice(
                &mut state,
                session_key,
                &released_notice(claim, "released"),
                now,
            );
        }
        if swept || !released.is_empty() {
            self.save(&state);
        }
        if released.is_empty() {
            Released::NotHeld
        } else {
            Released::Released(released)
        }
    }

    /// Every current claim, oldest first.
    pub fn claims(&self) -> Vec<Claim> {
        let mut state = guard(&self.state);
        if self.sweep(&mut state) {
            self.save(&state);
        }
        state.claims.clone()
    }

    /// The current claims as the routes show them.
    pub fn public_claims(&self) -> Value {
        let now = (self.clock)();
        Value::List(
            self.claims()
                .iter()
                .map(|claim| Value::Dict(claim.public(now)))
                .collect(),
        )
    }

    /// The startup lines naming the claims other agents hold.
    pub(super) fn claim_lines(&self, exclude_agent: Option<&str>) -> Vec<String> {
        self.claims()
            .iter()
            .filter(|claim| exclude_agent != Some(claim.agent.as_str()))
            .map(|claim| {
                format!(
                    "- {} holds the checkout claim on {} ({}); your edits, branch switches and \
                     releases there are refused until it is released.",
                    agent_name(&claim.agent),
                    repository_name(&claim.repo_path),
                    claim.purpose,
                )
            })
            .collect()
    }

    pub fn now(&self) -> f64 {
        (self.clock)()
    }
}

/// The string items of a request's list field.
fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(|item| match item {
            Value::Str(text) => Some(text.clone()),
            _ => None,
        })
        .filter(|text| !text.trim().is_empty())
        .collect()
}

impl Daemon {
    /// The claimable checkout each of `paths` is in, deduplicated in order.
    pub fn claimable_checkouts(&self, paths: &[String]) -> Vec<String> {
        let registered = registered_project_repo_paths(self.paths.registered_projects());
        let excluded = [
            self.presence.general_root.clone(),
            resolve_path(&self.paths.workspace_root.to_string_lossy()),
            resolve_path(&self.paths.data_root.to_string_lossy()),
        ];
        let mut checkouts = Vec::new();
        for path in paths {
            if let Some(checkout) = checkout_for(&resolve_path(path), &registered, &excluded)
                && !checkouts.contains(&checkout)
            {
                checkouts.push(checkout);
            }
        }
        checkouts
    }

    /// `POST /v1/checkout-claims/write`: the pre-tool hook's check before a
    /// write. Body `relay_session_key`, `paths` (the files or directories
    /// the tool call changes) and `action` (one line, the claim's purpose
    /// when this write takes it). Always 200: `decision` is `allow` or
    /// `refuse`, with `message` and the holder's `claim` when refused.
    pub fn checkout_write_route(&self, request: &Request) -> Outcome<Reply> {
        let caller = relay_session_key(request.get("relay_session_key"))?;
        let checkouts = self.claimable_checkouts(&strings(request.get("paths")));
        let mut body = Dict::new();
        body.insert(
            "checkouts",
            Value::List(
                checkouts
                    .iter()
                    .map(|path| Value::from(path.as_str()))
                    .collect(),
            ),
        );
        let acquired = match caller.as_deref() {
            Some(caller) if !checkouts.is_empty() => {
                self.presence
                    .acquire(caller, &checkouts, &request.text("action"), false)
            }
            _ => Acquired::NotAnAgent,
        };
        match acquired {
            Acquired::Refused(held) => {
                body.insert("decision", "refuse");
                body.insert("message", held.refusal(self.presence.now()));
                body.insert("claim", held.public(self.presence.now()));
            }
            Acquired::Granted { taken, .. } => {
                body.insert("decision", "allow");
                body.insert("claimed", if taken > 0 { "taken" } else { "refreshed" });
            }
            Acquired::NotAnAgent => {
                body.insert("decision", "allow");
                body.insert("claimed", Value::Null);
            }
        }
        reply(200, body)
    }

    /// The caller's session key and the one claimable checkout `repo_path`
    /// names, for the explicit claim routes.
    fn claim_target(&self, request: &Request) -> Outcome<(String, String)> {
        let caller = relay_session_key(request.get("relay_session_key"))?
            .ok_or_else(|| Failure::value("relay_session_key is required"))?;
        let repo_path = request.text("repo_path");
        if repo_path.trim().is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let checkout = self
            .claimable_checkouts(std::slice::from_ref(&repo_path))
            .into_iter()
            .next()
            .ok_or_else(|| {
                Failure::value(format!(
                    "repo_path {repo_path} is not a registered project's checkout; only those are \
                     claimable (general-tasks and worktrees never are)"
                ))
            })?;
        Ok((caller, checkout))
    }

    /// `POST /v1/checkout-claims/claim`: the caller takes, or refreshes, the
    /// claim on a checkout with a purpose. 409 with the refusal when another
    /// agent holds it.
    pub fn claim_checkout_route(&self, request: &Request) -> Outcome<Reply> {
        let (caller, checkout) = self.claim_target(request)?;
        let purpose = one_line(&request.text("purpose"));
        if purpose.is_empty() {
            return Err(Failure::value("purpose is required"));
        }
        let now = self.presence.now();
        let mut body = Dict::new();
        match self
            .presence
            .acquire(&caller, std::slice::from_ref(&checkout), &purpose, true)
        {
            Acquired::NotAnAgent => {
                return Err(Failure::value(
                    "relay_session_key names no running Relay agent session",
                ));
            }
            Acquired::Refused(held) => {
                body.insert("error", held.refusal(now));
                body.insert("claim", held.public(now));
                return reply(409, body);
            }
            Acquired::Granted { claims, taken } => {
                body.insert("claimed", if taken > 0 { "taken" } else { "refreshed" });
                if let Some(claim) = claims.first() {
                    body.insert("claim", claim.public(now));
                }
            }
        }
        body.insert("checkout_claims", self.presence.public_claims());
        reply(200, body)
    }

    /// `POST /v1/checkout-claims/release`: the caller releases its claim on
    /// `repo_path`, or every claim it holds when `repo_path` is empty. 409
    /// when another agent holds it.
    pub fn release_checkout_route(&self, request: &Request) -> Outcome<Reply> {
        let caller = relay_session_key(request.get("relay_session_key"))?
            .ok_or_else(|| Failure::value("relay_session_key is required"))?;
        let checkout = if request.text("repo_path").trim().is_empty() {
            None
        } else {
            Some(self.claim_target(request)?.1)
        };
        let now = self.presence.now();
        let mut body = Dict::new();
        match self.presence.release(&caller, checkout.as_deref()) {
            Released::HeldByOther(held) => {
                body.insert(
                    "error",
                    format!(
                        "{} holds this checkout claim; only its holder releases it. {}",
                        agent_name(&held.agent),
                        held.refusal(now)
                    ),
                );
                body.insert("claim", held.public(now));
                return reply(409, body);
            }
            Released::NotHeld => {
                body.insert("released", Value::List(Vec::new()));
            }
            Released::Released(claims) => {
                body.insert(
                    "released",
                    Value::List(
                        claims
                            .iter()
                            .map(|claim| Value::Dict(claim.public(now)))
                            .collect(),
                    ),
                );
            }
        }
        body.insert("checkout_claims", self.presence.public_claims());
        reply(200, body)
    }

    /// `GET /v1/checkout-claims`: every current claim, read only.
    pub fn checkout_claims_route(&self, _request: &Request) -> Outcome<Reply> {
        let mut body = Dict::new();
        body.insert("checkout_claims", self.presence.public_claims());
        reply(200, body)
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::Fixture;
    use super::*;

    fn granted(acquired: &Acquired) -> bool {
        matches!(acquired, Acquired::Granted { .. })
    }

    #[test]
    fn the_first_write_takes_a_free_claim_and_another_agent_is_refused() {
        let fixture = Fixture::new("claim-take");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let repo = fixture.repo("relay-runner");
        let checkouts = vec![repo.clone()];

        let first = presence.acquire("puck-1", &checkouts, "Edit README.md", false);
        assert!(
            matches!(first, Acquired::Granted { taken: 1, .. }),
            "{first:?}"
        );
        fixture.advance(120);
        let Acquired::Refused(held) = presence.acquire("george-1", &checkouts, "git push", false)
        else {
            panic!("George's write was not refused");
        };
        assert_eq!(held.agent, "puck");
        let refusal = held.refusal(presence.now());
        assert!(refusal.contains("Puck holds the claim on the relay-runner checkout"));
        assert!(refusal.contains("for \"Edit README.md\""));
        assert!(refusal.contains("last write 2 minutes ago"));
        assert!(refusal.contains(&iso(held.last_write)));
        assert!(refusal.contains("ask how to proceed"));

        // Puck's further writes refresh it, keeping the first purpose.
        let before = held.last_write;
        let again = presence.acquire("puck-1", &checkouts, "Write src/x.rs", false);
        let Acquired::Granted { claims, taken: 0 } = again else {
            panic!("{again:?}");
        };
        assert!(claims[0].last_write > before);
        assert_eq!(claims[0].purpose, "Edit README.md");
        assert_eq!(presence.claims().len(), 1);
    }

    #[test]
    fn the_release_tool_frees_the_checkout_for_another_agent() {
        let fixture = Fixture::new("claim-release");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let checkouts = vec![fixture.repo("relay-runner")];
        presence.acquire("puck-1", &checkouts, "cutting release v0.7.7", true);
        // George cannot release Puck's claim.
        assert!(matches!(
            presence.release("george-1", Some(&checkouts[0])),
            Released::HeldByOther(_)
        ));
        assert!(matches!(
            presence.release("puck-1", Some(&checkouts[0])),
            Released::Released(_)
        ));
        assert_eq!(
            presence.release("puck-1", None),
            Released::NotHeld,
            "a second release finds nothing"
        );
        let Acquired::Granted { claims, taken: 1 } =
            presence.acquire("george-1", &checkouts, "git commit", false)
        else {
            panic!("George's write did not take the claim");
        };
        assert_eq!(claims[0].agent, "george");
    }

    #[test]
    fn the_claim_goes_when_its_holder_stops() {
        let fixture = Fixture::new("claim-stop");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let checkouts = vec![fixture.repo("relay-runner")];
        presence.acquire("puck-1", &checkouts, "", false);
        assert!(matches!(
            presence.acquire("george-1", &checkouts, "", false),
            Acquired::Refused(_)
        ));
        presence.claim("george-1");

        fixture.stop("puck-1");
        assert!(granted(&presence.acquire(
            "george-1",
            &checkouts,
            "git commit",
            false
        )));
        let notices = presence.claim("george-1").notices;
        assert!(
            notices.contains(
                &"Agent notice: Puck released the checkout claim on relay-runner (Puck stopped)."
                    .to_string()
            ),
            "{notices:?}"
        );
    }

    #[test]
    fn the_claim_expires_after_thirty_minutes_without_a_write() {
        let fixture = Fixture::new("claim-idle");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        let checkouts = vec![fixture.repo("relay-runner")];
        presence.acquire("puck-1", &checkouts, "", false);
        fixture.advance(CLAIM_IDLE_SECONDS as u64 - 60);
        presence.acquire("puck-1", &checkouts, "", false);
        fixture.advance(CLAIM_IDLE_SECONDS as u64 - 60);
        assert!(matches!(
            presence.acquire("george-1", &checkouts, "", false),
            Acquired::Refused(_)
        ));
        fixture.advance(120);
        let acquired = presence.acquire("george-1", &checkouts, "git commit", false);
        assert!(
            matches!(acquired, Acquired::Granted { taken: 1, .. }),
            "{acquired:?}"
        );
        assert!(presence.claim("george-1").notices.contains(
            &"Agent notice: Puck released the checkout claim on relay-runner (30 minutes without \
              a write)."
                .to_string()
        ));
    }

    #[test]
    fn taking_and_releasing_queue_one_notice_each_for_the_other_agents() {
        let fixture = Fixture::new("claim-notices");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        fixture.start("sky-1", "sky");
        let presence = fixture.open();
        let checkouts = vec![fixture.repo("relay-runner")];
        presence.acquire("puck-1", &checkouts, "cutting release v0.7.7", true);
        presence.acquire("puck-1", &checkouts, "Edit Info.plist", false);
        let taken = "Agent notice: Puck took the checkout claim on relay-runner (cutting release \
                     v0.7.7); other agents' edits, branch switches and releases there are refused \
                     until it is released.";
        for receiver in ["george-1", "sky-1"] {
            assert_eq!(presence.claim(receiver).notices, vec![taken.to_string()]);
        }
        assert!(presence.claim("puck-1").notices.is_empty());

        presence.release("puck-1", None);
        let released = "Agent notice: Puck released the checkout claim on relay-runner (released).";
        for receiver in ["george-1", "sky-1"] {
            assert_eq!(presence.claim(receiver).notices, vec![released.to_string()]);
        }
        assert!(presence.claim("puck-1").notices.is_empty());
    }

    #[test]
    fn the_presence_read_shows_current_claims_and_startup_names_them() {
        let fixture = Fixture::new("claim-read");
        fixture.start("puck-1", "puck");
        fixture.start("george-1", "george");
        let presence = fixture.open();
        presence.acquire(
            "puck-1",
            &[fixture.repo("relay-runner")],
            "cutting release v0.7.7",
            true,
        );
        let Value::List(claims) = presence.public_claims() else {
            panic!("claims are not a list");
        };
        let claim = claims[0].as_dict().unwrap();
        assert_eq!(claim.text("name"), "Puck");
        assert_eq!(claim.text("repository"), "relay-runner");
        assert_eq!(claim.text("purpose"), "cutting release v0.7.7");
        assert!(claim.text("last_write").ends_with('Z'));
        let startup = presence.startup_text(Some("george"));
        assert!(
            startup.contains("- Puck holds the checkout claim on relay-runner"),
            "{startup}"
        );
        assert!(
            !presence
                .startup_text(Some("puck"))
                .contains("holds the checkout claim")
        );
    }

    #[test]
    fn an_unknown_session_is_not_enforced_and_claims_survive_a_restart() {
        let fixture = Fixture::new("claim-restart");
        fixture.start("puck-1", "puck");
        let presence = fixture.open();
        let checkouts = vec![fixture.repo("relay-runner")];
        assert_eq!(
            presence.acquire("nobody", &checkouts, "", false),
            Acquired::NotAnAgent
        );
        presence.acquire("puck-1", &checkouts, "", false);
        drop(presence);
        let presence = fixture.open();
        assert_eq!(presence.claims().len(), 1);
        drop(presence);
        fixture.stop("puck-1");
        let presence = fixture.open();
        assert!(presence.claims().is_empty());
    }

    #[test]
    fn only_a_registered_checkout_outside_worktrees_is_claimable() {
        let registered = vec![
            "/Users/me/dev/relay-runner".to_string(),
            "/Users/me/dev/relay-runner/vendor/lib".to_string(),
            "/Users/me/Library/Application Support/relay-runner/general-tasks".to_string(),
        ];
        let excluded = vec![
            PathBuf::from("/Users/me/Library/Application Support/relay-runner/general-tasks"),
            PathBuf::from("/Users/me/Library/Application Support/relay-runner/orchestrator"),
        ];
        let checkout = |path: &str| checkout_for(Path::new(path), &registered, &excluded);
        assert_eq!(
            checkout("/Users/me/dev/relay-runner/README.md").as_deref(),
            Some("/Users/me/dev/relay-runner")
        );
        assert_eq!(
            checkout("/Users/me/dev/relay-runner").as_deref(),
            Some("/Users/me/dev/relay-runner")
        );
        assert_eq!(
            checkout("/Users/me/dev/relay-runner/vendor/lib/x.c").as_deref(),
            Some("/Users/me/dev/relay-runner/vendor/lib")
        );
        assert_eq!(checkout("/Users/me/dev/relay-runner-other/x"), None);
        assert_eq!(
            checkout("/Users/me/dev/relay-runner/.claude/worktrees/rr-1/README.md"),
            None
        );
        assert_eq!(
            checkout("/Users/me/Library/Application Support/relay-runner/general-tasks/notes.md"),
            None
        );
        assert_eq!(
            checkout(
                "/Users/me/Library/Application Support/relay-runner/orchestrator/workspaces/\
                 relay-runner-1-rr-5/README.md"
            ),
            None
        );
        assert_eq!(checkout("/tmp/scratch.txt"), None);
    }
}
