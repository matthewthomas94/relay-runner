//! `services/artifact_history_cli.py`: the `relay-ticket-history` command's
//! enable, sweep, search and show, with the same arguments and the same
//! JSON on stdout.
//!
//! Reading history from a fresh checkout (`--remote`) fetches the artifact
//! ref into a disposable bare repository; no source ref, index or ticket
//! file changes.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use relay_intents::json::{self, Dict, Value};

use crate::automatic_retention::{
    available_records, enable_automatic_retention, sweep_automatic_retention,
};
use crate::migration::{ArtifactMigrationCoordinator, MigrationOptions};
use crate::retention::{
    ArtifactRetentionManager, HistoryAccess, RetentionOptions, confirm_github_remote,
};
use crate::rollout::ArtifactRolloutStore;
use crate::store::{ARTIFACT_REF, ArtifactStore, StoreOptions};
use crate::{Error, ErrorKind, Result, paths, pystr, toml};

const NO_LOCAL_ARCHIVE: &str = "No local archive exists yet. Relay sets it up automatically when more than \
25 completed tickets need cleanup and a GitHub remote is available. \
Use --remote <name> to read history already stored on GitHub.";
const RETRIEVAL_FAILED: &str =
    "Archive retrieval failed. Check connectivity and the selected GitHub remote.";

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

/// A failed `subprocess` call, which the command reports without detail.
fn subprocess_failure() -> Error {
    Error::new(ErrorKind::Runtime, RETRIEVAL_FAILED).with_code("subprocess")
}

fn enabled_store(repo: &Path, project_id: &str, state: &Path) -> Result<ArtifactStore> {
    ArtifactStore::open(
        repo,
        project_id,
        state,
        StoreOptions {
            enabled: true,
            ..StoreOptions::default()
        },
    )
}

fn read_text(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|error| {
        let message = error.to_string();
        let message = message
            .rfind(" (os error ")
            .map_or(message.clone(), |index| message[..index].to_string());
        Error::new(
            ErrorKind::Io,
            match error.raw_os_error() {
                Some(code) => format!(
                    "[Errno {code}] {message}: {}",
                    pystr::repr(&path.to_string_lossy())
                ),
                None => message,
            },
        )
    })?;
    Ok(pystr::universal_newlines(pystr::decode_utf8(&bytes)?))
}

fn config_string(config: &toml::Table, key: &str) -> Result<String> {
    match config.get(key) {
        Some(toml::Value::String(text)) => Ok(text.clone()),
        Some(_) => Err(Error::new(
            ErrorKind::Type,
            format!("{key} is not a string"),
        )),
        None => Err(Error::new(
            ErrorKind::Runtime,
            format!("KeyError: {}", pystr::repr(key)),
        )),
    }
}

/// `project_store`: the local archive, once the lifecycle is enabled.
pub fn project_store(repo: &Path, state: &Path) -> Result<ArtifactStore> {
    let config = toml::loads(&read_text(&repo.join(".orchestrator/config.toml"))?)?;
    if !matches!(config.get("artifact_lifecycle"), Some(toml::Value::String(text)) if text == "enabled")
    {
        return Err(validation(NO_LOCAL_ARCHIVE));
    }
    enabled_store(repo, &config_string(&config, "project_id")?, state)
}

/// A disposable bare repository holding the remote's artifact history.
pub struct RemoteReader {
    root: PathBuf,
    pub store: ArtifactStore,
}

impl Drop for RemoteReader {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// `git -C <directory> ...` as the history reader runs it: the caller's
/// environment, no credential prompt, a 60 second limit, stripped stdout.
fn reader_git(directory: &Path, arguments: &[&str]) -> Result<String> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Error::new(ErrorKind::Io, error.to_string()))?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        if child.try_wait()?.is_some() {
            break;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(subprocess_failure());
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(subprocess_failure());
    }
    Ok(pystr::strip(&String::from_utf8_lossy(&output.stdout)).to_string())
}

/// `remote_store`: read GitHub history without migrating the checkout.
pub fn remote_store(repo: &Path, remote_name: &str) -> Result<RemoteReader> {
    let url = reader_git(repo, &["remote", "get-url", remote_name])?;
    let base = std::env::var_os("TMPDIR").map_or_else(std::env::temp_dir, PathBuf::from);
    let root = base.join(format!(
        "relay-history-reader-{}",
        &crate::store::random_hex()[..8]
    ));
    std::fs::create_dir(&root)?;
    let guard = TemporaryRoot(Some(root.clone()));
    reader_git(&root, &["init", "--bare", "-q"])?;
    let refspec = format!("{ARTIFACT_REF}:{ARTIFACT_REF}");
    reader_git(
        &root,
        &[
            "fetch",
            "--no-tags",
            "--no-recurse-submodules",
            &url,
            &refspec,
        ],
    )?;
    let config = toml::loads(&reader_git(
        &root,
        &["show", &format!("{ARTIFACT_REF}:.orchestrator/config.toml")],
    )?)?;
    reader_git(
        &root,
        &[
            "remote",
            "add",
            &config_string(&config, "remote_name")?,
            &url,
        ],
    )?;
    let store = enabled_store(
        &root,
        &config_string(&config, "project_id")?,
        &root.join("reader-state"),
    )?;
    // Validate project identity, path allowlist and artifact history.
    store.snapshot()?;
    guard.release();
    Ok(RemoteReader { root, store })
}

struct TemporaryRoot(Option<PathBuf>);

impl TemporaryRoot {
    fn release(mut self) {
        self.0 = None;
    }
}

impl Drop for TemporaryRoot {
    fn drop(&mut self) {
        if let Some(root) = self.0.take() {
            let _ = std::fs::remove_dir_all(root);
        }
    }
}

/// `enable`: migrate when needed, then turn on automatic archival.
pub fn enable(repo: &Path, state: &Path, remote_name: &str) -> Result<Dict> {
    let registry_path = state.join("projects/registry-v2.json");
    let registry = match json::parse(&read_text(&registry_path)?) {
        Some(Value::Dict(dict)) => dict,
        _ => return Err(Error::value("Expecting value")),
    };
    let matches = available_records(&registry, repo)?;
    if matches.len() != 1 {
        return Err(validation(
            "Select one available registered project before enabling archival.",
        ));
    }
    let project_id = matches[0]
        .get("project_id")
        .map(Value::py_str)
        .ok_or_else(|| Error::new(ErrorKind::Runtime, "KeyError: 'project_id'"))?;
    let decision =
        ArtifactRolloutStore::new(state, None)?.decision(&project_id, "existing", true)?;
    if !decision.artifact_writes_enabled || !decision.artifact_sync_enabled {
        return Err(validation(format!(
            "Artifact rollout is paused: {}",
            decision.reason_code
        )));
    }
    let config = toml::loads(&read_text(&repo.join(".orchestrator/config.toml"))?)?;
    if !matches!(config.get("artifact_lifecycle"), Some(toml::Value::String(text)) if text == "enabled")
    {
        // Validate the chosen destination before the journaled cutover.
        let plain = ArtifactStore::open(repo, &project_id, state, StoreOptions::default())?;
        confirm_github_remote(&plain, remote_name, true)?;
        ArtifactMigrationCoordinator::new(
            repo,
            &project_id,
            state,
            &registry_path,
            MigrationOptions {
                runs_db_path: Some(state.join("orchestrator/runs.db")),
                graphify_path: Some(state.join("orchestrator/graphify.db")),
                remote_name: Some(remote_name.to_string()),
                ..MigrationOptions::default()
            },
        )?
        .migrate(true, true)?;
    }
    let store = project_store(repo, state)?;
    if store.project_id != project_id {
        return Err(validation(
            "The archive belongs to another registered project.",
        ));
    }
    let mut result = enable_automatic_retention(&store, remote_name)?;
    result.insert("cleanup", sweep_automatic_retention(&store, None)?);
    Ok(result)
}

/// `urlparse(url).path`.
fn url_path(url: &str) -> String {
    let mut rest = url;
    let mut scheme = String::new();
    if let Some(index) = url.find(':') {
        let candidate = &url[..index];
        if candidate
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
            && candidate
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || "+-.".contains(character))
        {
            scheme = candidate.to_ascii_lowercase();
            rest = &url[index + 1..];
        }
    }
    if let Some(after) = rest.strip_prefix("//") {
        rest = &after[after.find(['/', '?', '#']).unwrap_or(after.len())..];
    }
    let mut path = rest
        .split('#')
        .next()
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("")
        .to_string();
    const USES_PARAMS: [&str; 16] = [
        "", "ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtsps", "rtspu",
        "sip", "sips", "mms", "sftp", "tel",
    ];
    if USES_PARAMS.contains(&scheme.as_str()) && path.contains(';') {
        let segment_start = path.rfind('/').map_or(0, |index| index);
        if let Some(offset) = path[segment_start..].find(';') {
            path.truncate(segment_start + offset);
        }
    }
    path
}

/// `github_repository_url`.
pub fn github_repository_url(store: &ArtifactStore) -> Result<String> {
    let snapshot = store.snapshot()?;
    let config = toml::loads(pystr::decode_utf8(
        snapshot
            .file(".orchestrator/config.toml")
            .unwrap_or_default(),
    )?)?;
    let remote_name = config_string(&config, "remote_name")?;
    let remote = store
        .git(&["remote", "get-url", &remote_name], &[], None, &[0])?
        .line();
    let repository = match remote.strip_prefix("git@github.com:") {
        Some(rest) => rest.to_string(),
        None => url_path(&remote),
    };
    let repository = repository.trim_matches('/');
    let repository = repository.strip_suffix(".git").unwrap_or(repository);
    Ok(format!("https://github.com/{repository}"))
}

/// `urllib.parse.quote(text, safe="")`.
fn quote(text: &str) -> String {
    let mut quoted = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"_.-~".contains(&byte) {
            quoted.push(byte as char);
        } else {
            quoted.push_str(&format!("%{byte:02X}"));
        }
    }
    quoted
}

/// `github_record_url`.
fn github_record_url(repository_url: &str, entry: &Dict) -> String {
    let text = |key: &str| entry.get(key).map(Value::py_str).unwrap_or_default();
    format!(
        "{repository_url}/blob/{}/.orchestrator/{}.md",
        text("source_commit"),
        quote(&text("ticket_id"))
    )
}

/// `str.casefold()`, as far as Relay's titles need.
fn casefold(text: &str) -> String {
    text.to_lowercase().replace('ß', "ss")
}

fn manager(store: &ArtifactStore) -> Result<ArtifactRetentionManager<'_>> {
    ArtifactRetentionManager::new(
        store,
        RetentionOptions {
            enabled: true,
            ..RetentionOptions::default()
        },
    )
}

fn catalog_entry<'c>(catalog: &'c Dict, artifact_id: &str) -> Result<&'c Dict> {
    catalog
        .get(artifact_id)
        .and_then(Value::as_dict)
        .ok_or_else(|| {
            Error::new(
                ErrorKind::Runtime,
                format!("KeyError: {}", pystr::repr(artifact_id)),
            )
        })
}

/// `search`: archived cards matching `query`, optionally in their bodies.
pub fn search(store: &ArtifactStore, query: &str, full_text: bool) -> Result<Vec<Value>> {
    let manager = manager(store)?;
    let catalog = manager.catalog(&manager.head_required()?)?;
    let cards = manager.historical_search(if full_text { "" } else { query })?;
    let repository_url = github_repository_url(store)?;
    let mut result = Vec::new();
    for card in cards {
        if full_text {
            let detail = manager.historical_detail(&card.artifact_id, HistoryAccess::default())?;
            let body = match &detail.ticket_bytes {
                Some(bytes) => pystr::decode_utf8(bytes)?.to_string(),
                None => String::new(),
            };
            let haystack = format!("{} {} {body}", card.ticket_id, card.title);
            if !casefold(&haystack).contains(&casefold(query)) {
                continue;
            }
        }
        let mut item = Dict::new();
        item.insert("ticket_id", card.ticket_id.as_str());
        item.insert("artifact_id", card.artifact_id.as_str());
        item.insert("title", card.title.as_str());
        item.insert("status", card.status.as_str());
        item.insert("activity_at", card.activity_at.isoformat());
        item.insert(
            "github_url",
            github_record_url(&repository_url, catalog_entry(&catalog, &card.artifact_id)?),
        );
        result.push(Value::Dict(item));
    }
    Ok(result)
}

/// `show`: one archived ticket's verified record.
pub fn show(store: &ArtifactStore, ticket_id: &str) -> Result<Dict> {
    let manager = manager(store)?;
    let catalog = manager.catalog(&manager.head_required()?)?;
    let matches: Vec<&Dict> = catalog
        .iter()
        .filter_map(|(key, entry)| entry.as_dict().map(|entry| (key, entry)))
        .filter(|(key, entry)| {
            *key == ticket_id
                || entry
                    .get("ticket_id")
                    .is_some_and(|id| id.is_str(ticket_id))
        })
        .map(|(_, entry)| entry)
        .collect();
    if matches.len() != 1 {
        return Err(validation(format!(
            "No unique archived ticket matches {}.",
            pystr::repr(ticket_id)
        )));
    }
    let entry = matches[0];
    let artifact_id = entry
        .get("artifact_id")
        .map(Value::py_str)
        .unwrap_or_default();
    let detail = manager.historical_detail(&artifact_id, HistoryAccess::default())?;
    let mut result = Dict::new();
    result.insert(
        "ticket_id",
        entry.get("ticket_id").cloned().unwrap_or(Value::Null),
    );
    result.insert("availability", detail.availability.value());
    result.insert(
        "markdown",
        match &detail.ticket_bytes {
            Some(bytes) => Value::Str(pystr::decode_utf8(bytes)?.to_string()),
            None => Value::Null,
        },
    );
    result.insert(
        "attachments",
        Value::List(
            detail
                .attachments
                .iter()
                .cloned()
                .map(Value::Dict)
                .collect(),
        ),
    );
    result.insert("recovery", detail.recovery.clone());
    result.insert(
        "github_url",
        github_record_url(&github_repository_url(store)?, entry),
    );
    result.insert("materialized", false);
    Ok(result)
}

/// `json.dumps(value, indent=2)`: insertion order, ASCII.
pub fn dumps_indent(value: &Value) -> String {
    fn write(out: &mut String, value: &Value, level: usize) {
        let pad = |level: usize| "  ".repeat(level);
        match value {
            Value::List(items) if !items.is_empty() => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(level + 1));
                    write(out, item, level + 1);
                }
                out.push('\n');
                out.push_str(&pad(level));
                out.push(']');
            }
            Value::Dict(dict) if !dict.is_empty() => {
                out.push('{');
                for (index, (key, item)) in dict.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    out.push_str(&pad(level + 1));
                    out.push_str(&json::dumps(&Value::Str(key.to_string())));
                    out.push_str(": ");
                    write(out, item, level + 1);
                }
                out.push('\n');
                out.push_str(&pad(level));
                out.push('}');
            }
            other => out.push_str(&json::dumps(other)),
        }
    }
    let mut out = String::new();
    write(&mut out, value, 0);
    out
}

const USAGE: &str = "usage: artifact_history_cli.py [-h] [--repo REPO] [--state-root STATE_ROOT] [--remote REMOTE] [--full-text] {enable,sweep,search,show} [query]";

fn usage_error(message: &str) -> u8 {
    eprintln!("{USAGE}");
    eprintln!("artifact_history_cli.py: error: {message}");
    2
}

/// `artifact_history_cli.main()`: returns the exit status.
pub fn cli_main(arguments: &[String]) -> u8 {
    if arguments
        .iter()
        .any(|argument| argument == "-h" || argument == "--help")
    {
        println!("{USAGE}\n\nAgent-facing setup, search and retrieval of completed Relay tickets.");
        return 0;
    }
    let valued = ["--repo", "--state-root", "--remote"];
    let flags = ["--full-text"];
    let mut positional = Vec::new();
    let mut options: Vec<String> = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if argument.starts_with("--") {
            options.push(argument.clone());
            let name = argument.split('=').next().unwrap_or_default();
            let takes_value = !argument.contains('=')
                && valued
                    .iter()
                    .filter(|option| option.starts_with(name))
                    .count()
                    == 1
                && !flags.iter().any(|flag| flag.starts_with(name));
            if takes_value && index + 1 < arguments.len() {
                index += 1;
                options.push(arguments[index].clone());
            }
        } else {
            positional.push(argument.clone());
        }
        index += 1;
    }
    let Some(action) = positional.first().cloned() else {
        return usage_error("the following arguments are required: action");
    };
    if !["enable", "sweep", "search", "show"].contains(&action.as_str()) {
        return usage_error(&format!(
            "argument action: invalid choice: {} (choose from enable, sweep, search, show)",
            pystr::repr(&action)
        ));
    }
    if positional.len() > 2 {
        return usage_error(&format!(
            "unrecognized arguments: {}",
            positional[2..].join(" ")
        ));
    }
    let query = positional.get(1).cloned().unwrap_or_default();
    let parsed = match crate::rollout::parse_options(&options, &valued, &flags, false) {
        Ok((parsed, _)) => parsed,
        Err(message) => return usage_error(&message),
    };
    if action == "enable" && parsed.value("--remote").is_none_or(str::is_empty) {
        return usage_error("enable requires --remote");
    }
    let outcome = (|| -> Result<Value> {
        let repo_text = parsed.value("--repo").map_or_else(
            || {
                std::env::current_dir()
                    .map(|path| path.to_string_lossy().into_owned())
                    .unwrap_or_default()
            },
            str::to_string,
        );
        let state_text = parsed.value("--state-root").map_or_else(
            || {
                let home = std::env::var("HOME").unwrap_or_default();
                format!("{home}/Library/Application Support/relay-runner")
            },
            str::to_string,
        );
        let repo = PathBuf::from(paths::resolve(&paths::expanduser(&repo_text)?));
        let state = PathBuf::from(paths::resolve(&paths::expanduser(&state_text)?));
        let remote = parsed.value("--remote").filter(|value| !value.is_empty());
        match action.as_str() {
            "enable" => Ok(Value::Dict(enable(
                &repo,
                &state,
                remote.unwrap_or_default(),
            )?)),
            "sweep" => {
                let store = project_store(&repo, &state)?;
                let decision = ArtifactRolloutStore::new(&state, None)?.decision(
                    &store.project_id,
                    "existing",
                    true,
                )?;
                if !decision.artifact_writes_enabled || !decision.artifact_sync_enabled {
                    return Err(validation(format!(
                        "Artifact rollout is paused: {}",
                        decision.reason_code
                    )));
                }
                Ok(Value::Dict(sweep_automatic_retention(&store, None)?))
            }
            _ => {
                let reader;
                let local;
                let store = match remote {
                    Some(name) => {
                        reader = remote_store(&repo, name)?;
                        &reader.store
                    }
                    None => {
                        local = project_store(&repo, &state)?;
                        &local
                    }
                };
                if action == "search" {
                    Ok(Value::List(search(
                        store,
                        &query,
                        parsed.flag("--full-text"),
                    )?))
                } else {
                    Ok(Value::Dict(show(store, &query)?))
                }
            }
        }
    })();
    match outcome {
        Ok(result) => {
            println!("{}", dumps_indent(&result));
            0
        }
        Err(error) if error.code.as_deref() == Some("subprocess") => {
            let mut answer = Dict::new();
            answer.insert("error", RETRIEVAL_FAILED);
            println!("{}", json::dumps(&Value::Dict(answer)));
            1
        }
        Err(error) => {
            let mut answer = Dict::new();
            answer.insert("error", error.message.as_str());
            answer.insert("recovery", error.recovery.clone());
            println!("{}", dumps_indent(&Value::Dict(answer)));
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_urls_quote_the_ticket_id() {
        let mut entry = Dict::new();
        entry.insert("source_commit", "abc");
        entry.insert("ticket_id", "RR-1/x");
        assert_eq!(
            github_record_url("https://github.com/o/r", &entry),
            "https://github.com/o/r/blob/abc/.orchestrator/RR-1%2Fx.md"
        );
    }

    #[test]
    fn url_paths_follow_urlparse() {
        assert_eq!(url_path("https://github.com/o/r.git"), "/o/r.git");
        assert_eq!(url_path("ssh://git@github.com/o/r.git"), "/o/r.git");
        assert_eq!(url_path("/tmp/remote.git"), "/tmp/remote.git");
    }

    #[test]
    fn indented_json_keeps_insertion_order() {
        let mut inner = Dict::new();
        inner.insert("b", 1_i64);
        inner.insert("a", Value::List(Vec::new()));
        assert_eq!(
            dumps_indent(&Value::Dict(inner)),
            "{\n  \"b\": 1,\n  \"a\": []\n}"
        );
    }
}
