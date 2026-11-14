//! The subscription-only launch gate for Claude Code, as
//! `services/claude_subscription.py` decides it: the child environment, every
//! Claude settings file that applies, the active Anthropic profile and
//! `claude auth status --json`. Only a positive subscription result is ready.
//! Messages name variables and settings files, never credential values.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{self, Dict, Value, py_strip};

const SUBSCRIPTION_TYPES: [&str; 4] = ["pro", "max", "team", "enterprise"];
const FIRST_PARTY_BASE_URLS: [&str; 2] =
    ["https://api.anthropic.com", "https://api.anthropic.com/"];
pub const METERED_ENVIRONMENT: [&str; 9] = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_PROFILE",
    "ANTHROPIC_FEDERATION_RULE_ID",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "AWS_BEARER_TOKEN_BEDROCK",
    "ANTHROPIC_FOUNDRY_API_KEY",
];
const STATUS_TIMEOUT: Duration = Duration::from_secs(15);
const SIGN_IN: &str =
    "Run `claude auth login` and sign in with your Claude.ai subscription account.";
const THEN_SIGN_IN: &str =
    "then run `claude auth login` and sign in with your Claude.ai subscription account.";
const MANAGED_SETTINGS: &str = "/Library/Application Support/ClaudeCode/managed-settings.json";

#[derive(Debug, PartialEq)]
pub struct Readiness {
    pub state: &'static str,
    pub reason: &'static str,
    pub message: String,
}

impl Readiness {
    pub fn ready(&self) -> bool {
        self.state == "verified"
    }
}

fn verified() -> Readiness {
    Readiness {
        state: "verified",
        reason: "subscription",
        message: "Claude is using your Claude subscription.".to_string(),
    }
}

fn blocked(reason: &'static str, detail: &str) -> Readiness {
    Readiness {
        state: "blocked",
        reason,
        message: format!("Relay Runner only uses your Claude subscription. {detail}"),
    }
}

fn unverified(reason: &'static str, detail: &str) -> Readiness {
    Readiness {
        state: "unverified",
        reason,
        message: format!(
            "Relay Runner couldn't confirm Claude is using your Claude subscription. {detail}"
        ),
    }
}

/// The environment a launch sees, as JSON-like values.
pub type Environment = BTreeMap<String, Value>;

pub fn environment_from_os(environment: &BTreeMap<OsString, OsString>) -> Environment {
    environment
        .iter()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                Value::Str(value.to_string_lossy().into_owned()),
            )
        })
        .collect()
}

fn is_set(name: &str, value: Option<&Value>) -> bool {
    let text = match value {
        None | Some(Value::Null) => String::new(),
        Some(value) => py_strip(&value.py_str()).to_string(),
    };
    if text.is_empty() {
        return false;
    }
    if name.starts_with("CLAUDE_CODE_USE_") {
        return !matches!(text.to_lowercase().as_str(), "0" | "false" | "no" | "off");
    }
    true
}

fn metered_names(get: impl Fn(&str) -> Option<Value>) -> Vec<&'static str> {
    let mut names: Vec<&'static str> = METERED_ENVIRONMENT
        .into_iter()
        .filter(|name| is_set(name, get(name).as_ref()))
        .collect();
    let base_url = get("ANTHROPIC_BASE_URL")
        .filter(Value::truthy)
        .map(|value| py_strip(&value.py_str()).to_string())
        .unwrap_or_default();
    if !base_url.is_empty() && !FIRST_PARTY_BASE_URLS.contains(&base_url.as_str()) {
        names.push("ANTHROPIC_BASE_URL");
    }
    names
}

/// `evaluate`: the decision from the environment, settings and CLI status.
pub fn evaluate(
    environment: &Environment,
    settings: &[(String, Dict)],
    auth_status: Option<&Dict>,
    active_profile: Option<&str>,
) -> Readiness {
    let names = metered_names(|name| environment.get(name).cloned());
    if !names.is_empty() {
        return blocked(
            "metered_environment",
            &format!(
                "{} would route Claude away from your subscription. Remove it from your shell profile and the Relay Runner environment, then start again.",
                names.join(", ")
            ),
        );
    }
    for (label, document) in settings {
        if document.truthy("apiKeyHelper").is_some() {
            return blocked(
                "api_key_helper",
                &format!(
                    "apiKeyHelper in {label} would supply an API key. Remove it, then start again."
                ),
            );
        }
        if document.string("forceLoginMethod").to_lowercase() == "console" {
            return blocked(
                "console_login",
                &format!(
                    "forceLoginMethod in {label} requires Console (API) sign-in. Remove it, then start again."
                ),
            );
        }
        if let Some(env) = document.get("env").and_then(Value::as_dict) {
            let names = metered_names(|name| env.get(name).cloned());
            if !names.is_empty() {
                return blocked(
                    "metered_settings",
                    &format!(
                        "{} in the env of {label} would route Claude away from your subscription. Remove it, then start again.",
                        names.join(", ")
                    ),
                );
            }
        }
    }
    if active_profile == Some("oidc_federation") {
        return blocked(
            "federation_profile",
            "The active Anthropic profile uses workload identity federation, which Claude uses before your subscription login. Deactivate it, then start again.",
        );
    }
    let Some(status) = auth_status else {
        return unverified("status_unavailable", SIGN_IN);
    };
    if status.truthy("loggedIn").is_none() {
        return unverified("not_logged_in", SIGN_IN);
    }
    let method = status.string("authMethod");
    let provider = status.string("apiProvider");
    if method == "third_party" || provider != "firstParty" {
        return blocked(
            "third_party",
            &format!(
                "Claude is configured for a cloud provider route. Remove that configuration, {THEN_SIGN_IN}"
            ),
        );
    }
    if status.truthy("apiKeySource").is_some() || method == "api_key" || method == "api_key_helper"
    {
        return blocked(
            "api_key",
            &format!(
                "Claude would use an API key instead of your subscription login. Remove the key, {THEN_SIGN_IN}"
            ),
        );
    }
    let subscription = status.string("subscriptionType").to_lowercase();
    if SUBSCRIPTION_TYPES.contains(&subscription.as_str())
        && (method == "claude.ai" || method == "oauth_token")
    {
        return verified();
    }
    if method == "oauth_token" {
        return unverified(
            "oauth_token_unverified",
            &format!(
                "Claude is using a long-lived OAuth token (such as CLAUDE_CODE_OAUTH_TOKEN) and doesn't report which plan it belongs to. Unset it, {THEN_SIGN_IN}"
            ),
        );
    }
    if method == "claude.ai" {
        return blocked(
            "no_subscription",
            &format!(
                "The signed-in Claude account has no Pro, Max, Team or Enterprise subscription. {SIGN_IN}"
            ),
        );
    }
    unverified("unknown_route", SIGN_IN)
}

fn env_str(environment: &Environment, name: &str) -> Option<String> {
    environment
        .get(name)
        .filter(|value| value.truthy())
        .map(Value::py_str)
}

fn home(environment: &Environment) -> String {
    env_str(environment, "HOME")
        .or_else(|| std::env::var("HOME").ok())
        .unwrap_or_else(|| "/".to_string())
}

fn read_object(path: &Path) -> Option<Dict> {
    let text = std::fs::read_to_string(path).ok()?;
    match json::parse(&text)? {
        Value::Dict(document) => Some(document),
        _ => None,
    }
}

/// `settings_documents`: every Claude settings file that can change the route.
pub fn settings_documents(
    cwd: &str,
    environment: &Environment,
    managed: &Path,
) -> Vec<(String, Dict)> {
    let config_dir = env_str(environment, "CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(&home(environment)).join(".claude"));
    let project = Path::new(cwd).join(".claude");
    let candidates = [
        (
            managed.to_string_lossy().into_owned(),
            managed.to_path_buf(),
        ),
        (
            "user settings".to_string(),
            config_dir.join("settings.json"),
        ),
        (
            project.join("settings.json").to_string_lossy().into_owned(),
            project.join("settings.json"),
        ),
        (
            project
                .join("settings.local.json")
                .to_string_lossy()
                .into_owned(),
            project.join("settings.local.json"),
        ),
    ];
    candidates
        .into_iter()
        .filter_map(|(label, path)| read_object(&path).map(|document| (label, document)))
        .collect()
}

/// `active_profile_type`: the auth type of the active Anthropic profile.
pub fn active_profile_type(environment: &Environment) -> Option<String> {
    let config_dir = env_str(environment, "ANTHROPIC_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(&home(environment))
                .join(".config")
                .join("anthropic")
        });
    let name = std::fs::read_to_string(config_dir.join("active_config"))
        .map(|text| py_strip(&text).to_string())
        .ok()
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "default".to_string());
    let document = read_object(&config_dir.join("configs").join(format!("{name}.json")))?;
    let authentication = document.get("authentication")?.as_dict()?;
    Some(authentication.get("type")?.py_str())
}

/// `auth_status`: `claude auth status --json` with the launch's environment.
pub fn auth_status(
    prefix: &[String],
    environment: &BTreeMap<OsString, OsString>,
    cwd: &str,
) -> Option<Dict> {
    let mut child = Command::new(&prefix[0])
        .args(&prefix[1..])
        .args(["auth", "status", "--json"])
        .current_dir(cwd)
        .env_clear()
        .envs(environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut text = String::new();
        stdout.read_to_string(&mut text).map(|_| text)
    });
    let deadline = Instant::now() + STATUS_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let text = reader.join().ok()?.ok()?;
    match json::parse(&text)? {
        Value::Dict(status) => Some(status),
        _ => None,
    }
}

/// `check`: the gate for a Relay-owned Claude launch.
pub fn check(
    prefix: &[String],
    cwd: &str,
    environment: &BTreeMap<OsString, OsString>,
) -> Readiness {
    let values = environment_from_os(environment);
    evaluate(
        &values,
        &settings_documents(cwd, &values, Path::new(MANAGED_SETTINGS)),
        auth_status(prefix, environment, cwd).as_ref(),
        active_profile_type(&values).as_deref(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(text: &str) -> Dict {
        json::parse(text).unwrap().as_dict().unwrap().clone()
    }

    fn environment(pairs: &[(&str, &str)]) -> Environment {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), Value::from(*v)))
            .collect()
    }

    const SUBSCRIBED: &str = r#"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "Max"}"#;

    #[test]
    fn a_signed_in_subscription_is_ready() {
        let status = dict(SUBSCRIBED);
        assert!(evaluate(&environment(&[]), &[], Some(&status), None).ready());
        let token =
            dict(r#"{"loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"}"#);
        assert_eq!(
            evaluate(&environment(&[]), &[], Some(&token), None).reason,
            "oauth_token_unverified"
        );
    }

    #[test]
    fn metered_routes_are_blocked_by_name() {
        let status = dict(SUBSCRIBED);
        let blocked = evaluate(
            &environment(&[
                ("ANTHROPIC_API_KEY", "x"),
                ("CLAUDE_CODE_USE_VERTEX", "off"),
                ("ANTHROPIC_BASE_URL", "https://gateway.example"),
            ]),
            &[],
            Some(&status),
            None,
        );
        assert_eq!(blocked.reason, "metered_environment");
        assert_eq!(
            blocked.message,
            "Relay Runner only uses your Claude subscription. ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL would route Claude away from your subscription. Remove it from your shell profile and the Relay Runner environment, then start again."
        );
        let settings = vec![(
            "user settings".to_string(),
            dict(r#"{"env": {"CLAUDE_CODE_USE_BEDROCK": true}}"#),
        )];
        assert_eq!(
            evaluate(&environment(&[]), &settings, Some(&status), None).reason,
            "metered_settings"
        );
        let helper = vec![(
            "user settings".to_string(),
            dict(r#"{"apiKeyHelper": "/bin/key"}"#),
        )];
        assert_eq!(
            evaluate(&environment(&[]), &helper, Some(&status), None).reason,
            "api_key_helper"
        );
        assert_eq!(
            evaluate(
                &environment(&[]),
                &[],
                Some(&status),
                Some("oidc_federation")
            )
            .reason,
            "federation_profile"
        );
    }

    #[test]
    fn an_unreadable_or_signed_out_status_is_unverified() {
        assert_eq!(
            evaluate(&environment(&[]), &[], None, None).reason,
            "status_unavailable"
        );
        let signed_out = dict(r#"{"loggedIn": false}"#);
        let readiness = evaluate(&environment(&[]), &[], Some(&signed_out), None);
        assert_eq!(
            (readiness.state, readiness.reason),
            ("unverified", "not_logged_in")
        );
        let free =
            dict(r#"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}"#);
        assert_eq!(
            evaluate(&environment(&[]), &[], Some(&free), None).reason,
            "no_subscription"
        );
        let bedrock =
            dict(r#"{"loggedIn": true, "authMethod": "third_party", "apiProvider": "bedrock"}"#);
        assert_eq!(
            evaluate(&environment(&[]), &[], Some(&bedrock), None).reason,
            "third_party"
        );
    }
}
