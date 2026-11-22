//! RR-527: the checkout claim, enforced before a foreground agent's tool
//! call changes a registered project's checkout.
//!
//! On `PreToolUse` the hook works out what the call would change:
//!
//! - **File-writing tools**: Claude Code's `Write`, `Edit`, `MultiEdit`
//!   (`file_path`) and `NotebookEdit` (`notebook_path`); Codex's
//!   `apply_patch`, whose patch names each file it adds, updates, deletes or
//!   moves to.
//! - **Shell commands** (`Bash` for both providers) that change a checkout's
//!   git state or its remote: `git checkout`, `switch`, `commit`, `merge`,
//!   `rebase`, `reset`, `stash`, `cherry-pick`, `revert`, `pull`, `push` and
//!   `tag`, in the shell's directory, after `cd`, or with `git -C`; `gh
//!   release` and `gh workflow run`; and the project's release scripts
//!   (`build-dmg.sh`, `generate-appcast.sh`, any `release*` script).
//!
//! Anything else allows at once without asking the daemon, so reads, searches,
//! builds and tests cost one process start. Otherwise it asks the daemon
//! (`POST /v1/checkout-claims/write`), which takes or refreshes the caller's
//! claim, or refuses because another agent holds it; only a refusal prints
//! anything. A daemon that does not answer allows the call.
//!
//! Shell parsing is by name, not a full shell: a command inside `$(…)` or
//! backticks, `eval`, an alias or function, a script that runs git itself,
//! and shell file writes (`>`, `sed -i`, `rm`, `mv`, `cp`) are not seen.

use std::path::{Component, Path, PathBuf};

use crate::bridge::notices::Daemon;
use crate::bridge::targets::valid_session_key;
use crate::json::{self, Dict, Value};

/// The daemon route that checks, takes and refreshes a claim.
pub const WRITE_PATH: &str = "/v1/checkout-claims/write";

/// Git subcommands that change a checkout's state or its remote.
const MUTATING_GIT: [&str; 12] = [
    "checkout",
    "switch",
    "commit",
    "merge",
    "rebase",
    "reset",
    "stash",
    "cherry-pick",
    "revert",
    "pull",
    "push",
    "tag",
];

/// `git tag` options that only list or verify.
const TAG_LIST_OPTIONS: [&str; 11] = [
    "-l",
    "--list",
    "-v",
    "--verify",
    "--contains",
    "--no-contains",
    "--points-at",
    "--merged",
    "--no-merged",
    "--sort",
    "--format",
];

/// Words that run the command after them.
const WRAPPERS: [&str; 8] = [
    "command", "exec", "nohup", "time", "sudo", "builtin", "noglob", "env",
];

/// What one tool call would change: the paths it writes (files, or the
/// directory a git command runs in) and a one-line action, the claim's
/// purpose when this call takes it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Change {
    pub paths: Vec<String>,
    pub action: String,
}

/// `path` made absolute against `cwd`, with `~` expanded and `.`/`..`
/// folded lexically. The daemon resolves symlinks.
fn absolute(path: &str, cwd: &str, home: &str) -> String {
    let expanded = if path == "~" {
        PathBuf::from(home)
    } else if let Some(rest) = path.strip_prefix("~/") {
        Path::new(home).join(rest)
    } else {
        PathBuf::from(path)
    };
    let joined = if expanded.is_absolute() {
        expanded
    } else {
        Path::new(cwd).join(expanded)
    };
    let mut folded = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                folded.pop();
            }
            other => folded.push(other.as_os_str()),
        }
    }
    folded.to_string_lossy().into_owned()
}

fn file_name(path: &str) -> String {
    Path::new(path).file_name().map_or_else(
        || path.to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// The files a Codex `apply_patch` patch adds, updates, deletes or moves to.
pub fn patch_paths(patch: &str) -> Vec<String> {
    const MARKERS: [&str; 4] = [
        "*** Add File: ",
        "*** Update File: ",
        "*** Delete File: ",
        "*** Move to: ",
    ];
    patch
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            MARKERS
                .iter()
                .find_map(|marker| line.strip_prefix(marker))
                .map(|path| path.trim().to_string())
        })
        .filter(|path| !path.is_empty())
        .collect()
}

#[derive(Debug, PartialEq)]
enum Token {
    Word(String),
    /// `;`, `&`, `|`, a newline or a parenthesis: a command boundary.
    Boundary,
}

/// A shell command split into words and command boundaries: quotes and
/// backslashes as the shell reads them, `#` comments dropped. Expansions are
/// left as text.
fn tokenize(command: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = command.chars().peekable();
    let finish = |tokens: &mut Vec<Token>, word: &mut String, in_word: &mut bool| {
        if *in_word {
            tokens.push(Token::Word(std::mem::take(word)));
            *in_word = false;
        }
    };
    while let Some(character) = chars.next() {
        match character {
            '\'' => {
                in_word = true;
                for quoted in chars.by_ref() {
                    if quoted == '\'' {
                        break;
                    }
                    word.push(quoted);
                }
            }
            '"' => {
                in_word = true;
                while let Some(quoted) = chars.next() {
                    match quoted {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some(next @ ('"' | '\\' | '$' | '`')) => word.push(next),
                            Some('\n') => {}
                            Some(next) => {
                                word.push('\\');
                                word.push(next);
                            }
                            None => word.push('\\'),
                        },
                        other => word.push(other),
                    }
                }
            }
            '\\' => match chars.next() {
                Some('\n') => {}
                Some(next) => {
                    in_word = true;
                    word.push(next);
                }
                None => {}
            },
            '#' if !in_word => {
                for skipped in chars.by_ref() {
                    if skipped == '\n' {
                        break;
                    }
                }
                finish(&mut tokens, &mut word, &mut in_word);
                tokens.push(Token::Boundary);
            }
            // `2>&1`, `&>file`: a redirection, not a boundary.
            '&' if in_word && word.ends_with(['>', '<']) => word.push('&'),
            '&' if chars.peek() == Some(&'>') => {
                in_word = true;
                word.push('&');
            }
            ';' | '&' | '|' | '\n' | '(' | ')' => {
                finish(&mut tokens, &mut word, &mut in_word);
                tokens.push(Token::Boundary);
            }
            space if space.is_whitespace() => finish(&mut tokens, &mut word, &mut in_word),
            other => {
                in_word = true;
                word.push(other);
            }
        }
    }
    finish(&mut tokens, &mut word, &mut in_word);
    tokens
}

/// One simple command: its words without leading assignments and wrappers.
fn simple_commands(command: &str) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let mut current: Vec<String> = Vec::new();
    for token in tokenize(command) {
        match token {
            Token::Word(word) => current.push(word),
            Token::Boundary => {
                if !current.is_empty() {
                    commands.push(std::mem::take(&mut current));
                }
            }
        }
    }
    if !current.is_empty() {
        commands.push(current);
    }
    commands
        .into_iter()
        .map(|words| {
            let mut index = 0;
            let mut in_env = false;
            while index < words.len() {
                let word = words[index].as_str();
                let assignment = word
                    .split_once('=')
                    .is_some_and(|(name, _)| is_variable_name(name));
                if in_env && matches!(word, "-u" | "-C" | "-P" | "-S") {
                    // `env -u NAME`: the option's value is not the program.
                    index += 2;
                } else if assignment
                    || WRAPPERS.contains(&word)
                    || (in_env && word.starts_with('-'))
                {
                    in_env |= word == "env";
                    index += 1;
                } else {
                    break;
                }
            }
            let index = index.min(words.len());
            words[index..].to_vec()
        })
        .filter(|words| !words.is_empty())
        .collect()
}

fn is_variable_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|first| first == '_' || first.is_ascii_alphabetic())
        && chars.all(|rest| rest == '_' || rest.is_ascii_alphanumeric())
}

/// The directory a git command changes and its subcommand, when it is one
/// of `MUTATING_GIT` in a mutating form.
fn git_change(arguments: &[String], cwd: &str, home: &str) -> Option<(String, String)> {
    let mut directory = cwd.to_string();
    let mut work_tree: Option<String> = None;
    let mut git_dir: Option<String> = None;
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "-C" => {
                directory = absolute(arguments.get(index + 1)?, &directory, home);
                index += 2;
            }
            "-c" | "--namespace" | "--exec-path" | "--config-env" => index += 2,
            "--git-dir" => {
                git_dir = Some(absolute(arguments.get(index + 1)?, &directory, home));
                index += 2;
            }
            "--work-tree" => {
                work_tree = Some(absolute(arguments.get(index + 1)?, &directory, home));
                index += 2;
            }
            "-h" | "--help" | "--version" => return None,
            _ if argument.starts_with("-C") => {
                directory = absolute(&argument[2..], &directory, home);
                index += 1;
            }
            _ if argument.starts_with("--git-dir=") => {
                git_dir = Some(absolute(&argument[10..], &directory, home));
                index += 1;
            }
            _ if argument.starts_with("--work-tree=") => {
                work_tree = Some(absolute(&argument[12..], &directory, home));
                index += 1;
            }
            _ if argument.starts_with('-') => index += 1,
            _ => break,
        }
    }
    let subcommand = arguments.get(index)?.as_str();
    if !MUTATING_GIT.contains(&subcommand) {
        return None;
    }
    let rest = &arguments[index + 1..];
    let has = |options: &[&str]| {
        rest.iter().any(|argument| {
            options
                .iter()
                .any(|option| argument == option || argument.starts_with(&format!("{option}=")))
        })
    };
    if has(&["-h", "--help", "--dry-run"]) {
        return None;
    }
    let read_only = match subcommand {
        "stash" => rest
            .iter()
            .find(|argument| !argument.starts_with('-'))
            .is_some_and(|action| action == "list" || action == "show"),
        "tag" => {
            rest.is_empty()
                || has(&TAG_LIST_OPTIONS)
                || rest.iter().any(|argument| {
                    argument.starts_with("-n") && argument[2..].chars().all(|c| c.is_ascii_digit())
                })
        }
        "push" => has(&["-n"]),
        _ => false,
    };
    if read_only {
        return None;
    }
    let target = work_tree
        .or_else(|| {
            git_dir.map(|git_dir| {
                if file_name(&git_dir) == ".git" {
                    Path::new(&git_dir)
                        .parent()
                        .map_or(git_dir.clone(), |parent| {
                            parent.to_string_lossy().into_owned()
                        })
                } else {
                    git_dir
                }
            })
        })
        .unwrap_or(directory);
    Some((target, format!("git {subcommand}")))
}

/// Whether `program` is one of the project's release scripts.
fn is_release_script(program: &str) -> bool {
    let name = file_name(program);
    name == "build-dmg.sh" || name == "generate-appcast.sh" || name.starts_with("release")
}

/// What a shell command would change, starting in `cwd`.
pub fn shell_change(command: &str, cwd: &str, home: &str) -> Change {
    let mut change = Change::default();
    collect_shell(command, cwd, home, &mut change, 0);
    change
}

fn collect_shell(command: &str, cwd: &str, home: &str, change: &mut Change, depth: usize) {
    let mut directory = cwd.to_string();
    for words in simple_commands(command) {
        let mut words = words.as_slice();
        let program = file_name(&words[0]);
        match program.as_str() {
            "cd" | "pushd" => {
                match words.get(1).map(String::as_str) {
                    None => directory = home.to_string(),
                    Some("-") => {}
                    Some(target) => directory = absolute(target, &directory, home),
                }
                continue;
            }
            "sh" | "bash" | "zsh" | "dash" => {
                let inline = words.iter().position(|word| {
                    word.starts_with('-') && !word.starts_with("--") && word.contains('c')
                });
                if let Some(position) = inline {
                    if depth < 4
                        && let Some(script) = words.get(position + 1)
                    {
                        collect_shell(script, &directory, home, change, depth + 1);
                    }
                    continue;
                }
                match words[1..].iter().position(|word| !word.starts_with('-')) {
                    Some(position) => words = &words[position + 1..],
                    None => continue,
                }
            }
            _ => {}
        }
        let program = file_name(&words[0]);
        let found = if program == "git" {
            git_change(&words[1..], &directory, home)
        } else if program == "gh" {
            let arguments: Vec<&str> = words[1..].iter().map(String::as_str).collect();
            match arguments.as_slice() {
                ["release", action, ..]
                    if matches!(
                        *action,
                        "create" | "edit" | "delete" | "upload" | "delete-asset"
                    ) =>
                {
                    Some((directory.clone(), format!("gh release {action}")))
                }
                ["workflow", "run", ..] => Some((directory.clone(), "gh workflow run".to_string())),
                _ => None,
            }
        } else if is_release_script(&words[0]) {
            let script = absolute(&words[0], &directory, home);
            let parent = Path::new(&script)
                .parent()
                .map_or(directory.clone(), |parent| {
                    parent.to_string_lossy().into_owned()
                });
            // A bare name found on PATH says nothing about the checkout; the
            // shell's directory is the best guess.
            let target = if words[0].contains('/') {
                parent
            } else {
                directory.clone()
            };
            Some((target, format!("release script {program}")))
        } else {
            None
        };
        if let Some((path, action)) = found {
            if change.action.is_empty() {
                change.action = action;
            }
            if !change.paths.contains(&path) {
                change.paths.push(path);
            }
        }
    }
}

/// What a `PreToolUse` call would change, from its tool name and input.
pub fn tool_change(tool_name: &str, input: &Dict, cwd: &str, home: &str) -> Change {
    match tool_name {
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => {
            let path = ["file_path", "notebook_path"]
                .into_iter()
                .map(|key| input.text(key))
                .find(|path| !path.is_empty());
            match path {
                Some(path) => Change {
                    action: format!("{tool_name} {}", file_name(&path)),
                    paths: vec![absolute(&path, cwd, home)],
                },
                None => Change::default(),
            }
        }
        "apply_patch" => {
            let files = patch_paths(&input.string("command"));
            Change {
                action: files
                    .first()
                    .map(|first| format!("apply_patch {}", file_name(first)))
                    .unwrap_or_default(),
                paths: files.iter().map(|path| absolute(path, cwd, home)).collect(),
            }
        }
        "Bash" => shell_change(&input.string("command"), cwd, home),
        _ => Change::default(),
    }
}

/// The hook's stdout for one `PreToolUse` payload: a deny decision when the
/// daemon refuses the change, else `None` (the call goes ahead). Claude Code
/// and Codex both read `permissionDecision: "deny"` with its reason as a
/// blocked call the model sees.
pub fn pre_tool_use(
    payload: &Dict,
    session_key: &str,
    home: &str,
    daemon: &dyn Daemon,
) -> Option<String> {
    if !valid_session_key(session_key) {
        return None;
    }
    let input = match payload.get("tool_input") {
        Some(Value::Dict(input)) => input.clone(),
        _ => Dict::new(),
    };
    let cwd = payload.text("cwd");
    let change = tool_change(&payload.text("tool_name"), &input, &cwd, home);
    if change.paths.is_empty() {
        return None;
    }
    let mut request = Dict::new();
    request.insert("relay_session_key", session_key);
    request.insert(
        "paths",
        Value::List(
            change
                .paths
                .iter()
                .map(|path| Value::from(path.as_str()))
                .collect(),
        ),
    );
    request.insert("action", change.action.as_str());
    let answer = match daemon.post_json(WRITE_PATH, &request) {
        Ok(answer) => answer,
        Err(error) => {
            eprintln!("[relay_completion_hook] checkout claim unavailable, allowed: {error}");
            return None;
        }
    };
    if answer.text("decision") != "refuse" {
        return None;
    }
    let reason = Some(answer.text("message"))
        .filter(|message| !message.is_empty())
        .unwrap_or_else(|| {
            "Refused by the Relay checkout claim: another Relay agent holds this checkout. Stop \
             and ask the user how to proceed."
                .to_string()
        });
    let mut specific = Dict::new();
    specific.insert("hookEventName", "PreToolUse");
    specific.insert("permissionDecision", "deny");
    specific.insert("permissionDecisionReason", reason);
    let mut output = Dict::new();
    output.insert("hookSpecificOutput", Value::Dict(specific));
    Some(json::dumps_compact(&Value::Dict(output)))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::bridge::orchestrator::DaemonError;

    const CWD: &str = "/Users/me/dev/relay-runner";
    const HOME: &str = "/Users/me";

    fn shell(command: &str) -> Change {
        shell_change(command, CWD, HOME)
    }

    fn changed(command: &str) -> Vec<String> {
        shell(command).paths
    }

    #[test]
    fn each_listed_git_command_changes_the_checkout_here_and_with_dash_c() {
        for (subcommand, arguments) in [
            ("checkout", "main"),
            ("switch", "-c feature"),
            ("commit", "-m 'message'"),
            ("merge", "relay/rr-1"),
            ("rebase", "main"),
            ("reset", "--hard HEAD~1"),
            ("stash", ""),
            ("stash", "pop"),
            ("cherry-pick", "abc123"),
            ("revert", "abc123"),
            ("pull", "--rebase"),
            ("push", "origin main"),
            ("tag", "v0.7.7"),
            ("tag", "-d v0.7.7"),
        ] {
            let here = shell(&format!("git {subcommand} {arguments}"));
            assert_eq!(here.paths, vec![CWD.to_string()], "git {subcommand}");
            assert_eq!(here.action, format!("git {subcommand}"));
            assert_eq!(
                changed(&format!(
                    "git -C /Users/me/dev/other {subcommand} {arguments}"
                )),
                vec!["/Users/me/dev/other".to_string()],
                "git -C … {subcommand}"
            );
            assert_eq!(
                changed(&format!(
                    "cd /tmp && git -C ../Users/me/dev/other {subcommand} {arguments}"
                )),
                vec!["/Users/me/dev/other".to_string()],
            );
        }
    }

    #[test]
    fn read_only_git_commands_change_nothing() {
        for command in [
            "git status",
            "git log --oneline -5",
            "git diff HEAD~1",
            "git -C /Users/me/dev/relay-runner status --short",
            "git show HEAD",
            "git branch --show-current",
            "git stash list",
            "git stash show -p stash@{0}",
            "git tag",
            "git tag -l 'v0.7*'",
            "git tag --contains HEAD",
            "git tag -n5",
            "git push --dry-run origin main",
            "git push -n origin main",
            "git commit --help",
            "git --version",
            "git fetch origin",
            "ls -la && cat README.md | grep git",
            "echo 'git push'",
            "cargo test --workspace --locked",
            "swift build --build-tests",
        ] {
            assert!(changed(command).is_empty(), "{command}");
        }
    }

    #[test]
    fn the_shell_directory_follows_cd_and_wrappers_are_seen_through() {
        assert_eq!(
            changed("cd ~/dev/docs-site && git commit -am wip"),
            vec!["/Users/me/dev/docs-site".to_string()]
        );
        assert_eq!(
            changed("cd rust; GIT_EDITOR=true git rebase --continue"),
            vec![format!("{CWD}/rust")]
        );
        assert_eq!(
            changed("env -u FOO GIT_TRACE=1 command git push"),
            vec![CWD.to_string()]
        );
        assert_eq!(
            changed("bash -lc 'cd /Users/me/dev/other && git push'"),
            vec!["/Users/me/dev/other".to_string()]
        );
        assert_eq!(
            changed("git --work-tree=/Users/me/dev/w --git-dir=/Users/me/dev/w/.git commit"),
            vec!["/Users/me/dev/w".to_string()]
        );
        assert_eq!(
            changed("git --git-dir=/Users/me/dev/w/.git reset --hard"),
            vec!["/Users/me/dev/w".to_string()]
        );
        assert_eq!(
            changed("git status 2>&1 | head; git push origin main &>/dev/null"),
            vec![CWD.to_string()]
        );
        assert_eq!(
            changed("ls # git push"),
            Vec::<String>::new(),
            "a comment is not a command"
        );
    }

    #[test]
    fn release_scripts_and_gh_releases_change_the_checkout() {
        assert_eq!(
            shell("./scripts/build-dmg.sh --notarize").paths,
            vec![format!("{CWD}/scripts")]
        );
        assert_eq!(
            shell("bash scripts/generate-appcast.sh").paths,
            vec![format!("{CWD}/scripts")]
        );
        assert_eq!(
            shell("gh release create v0.7.7 --notes x").action,
            "gh release create"
        );
        assert_eq!(
            shell("gh workflow run tag-release.yml -f tag=v0.7.7").paths,
            vec![CWD.to_string()]
        );
        assert!(changed("gh release view v0.7.7").is_empty());
        assert!(changed("gh pr list").is_empty());
        assert!(changed("cargo build --release").is_empty());
    }

    #[test]
    fn file_tools_name_their_target_and_reads_name_nothing() {
        let mut input = Dict::new();
        input.insert("file_path", "/Users/me/dev/relay-runner/README.md");
        for tool in ["Write", "Edit", "MultiEdit"] {
            let change = tool_change(tool, &input, CWD, HOME);
            assert_eq!(change.paths, vec!["/Users/me/dev/relay-runner/README.md"]);
            assert_eq!(change.action, format!("{tool} README.md"));
        }
        let mut notebook = Dict::new();
        notebook.insert("notebook_path", "notes/a.ipynb");
        assert_eq!(
            tool_change("NotebookEdit", &notebook, CWD, HOME).paths,
            vec![format!("{CWD}/notes/a.ipynb")]
        );
        for tool in [
            "Read",
            "Grep",
            "Glob",
            "WebFetch",
            "mcp__relay-orchestrator__agent_presence",
        ] {
            assert_eq!(
                tool_change(tool, &input, CWD, HOME),
                Change::default(),
                "{tool}"
            );
        }
    }

    #[test]
    fn a_codex_patch_names_every_file_it_touches() {
        let patch = "*** Begin Patch\n*** Add File: docs/new.md\n+hello\n*** Update File: \
                     src/a.rs\n*** Move to: src/b.rs\n@@\n-x\n+y\n*** Delete File: \
                     /Users/me/dev/other/c.rs\n*** End Patch\n";
        let mut input = Dict::new();
        input.insert("command", patch);
        let change = tool_change("apply_patch", &input, CWD, HOME);
        assert_eq!(
            change.paths,
            vec![
                format!("{CWD}/docs/new.md"),
                format!("{CWD}/src/a.rs"),
                format!("{CWD}/src/b.rs"),
                "/Users/me/dev/other/c.rs".to_string(),
            ]
        );
        assert_eq!(change.action, "apply_patch new.md");
    }

    /// A daemon that refuses writes under one path, records each request,
    /// and is down when `refusing` is `None`.
    struct ClaimDaemon {
        refusing: Option<String>,
        requests: Mutex<Vec<Dict>>,
    }

    impl Daemon for ClaimDaemon {
        fn post_json(&self, path: &str, payload: &Dict) -> Result<Dict, DaemonError> {
            assert_eq!(path, WRITE_PATH);
            self.requests.lock().unwrap().push(payload.clone());
            let Some(refusing) = &self.refusing else {
                return Err(DaemonError::Io(std::io::Error::from(
                    std::io::ErrorKind::ConnectionRefused,
                )));
            };
            let refused = payload
                .get("paths")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .any(|path| path.py_str().starts_with(refusing.as_str()));
            let mut answer = Dict::new();
            answer.insert("decision", if refused { "refuse" } else { "allow" });
            if refused {
                answer.insert(
                    "message",
                    "Refused by the Relay checkout claim: Puck holds it.",
                );
            }
            Ok(answer)
        }

        fn get_json(&self, _path: &str, _params: &Dict) -> Result<Dict, DaemonError> {
            Ok(Dict::new())
        }
    }

    fn payload(tool: &str, key: &str, value: &str) -> Dict {
        let mut input = Dict::new();
        input.insert(key, value);
        let mut payload = Dict::new();
        payload.insert("hook_event_name", "PreToolUse");
        payload.insert("tool_name", tool);
        payload.insert("tool_input", Value::Dict(input));
        payload.insert("cwd", CWD);
        payload
    }

    #[test]
    fn a_refusal_is_a_deny_decision_both_providers_read() {
        let daemon = ClaimDaemon {
            refusing: Some(CWD.to_string()),
            requests: Mutex::default(),
        };
        let output = pre_tool_use(
            &payload("Edit", "file_path", &format!("{CWD}/README.md")),
            "george-1",
            HOME,
            &daemon,
        )
        .unwrap();
        let Some(Value::Dict(parsed)) = json::parse(&output) else {
            panic!("not JSON: {output}");
        };
        let specific = parsed.get("hookSpecificOutput").unwrap().as_dict().unwrap();
        assert_eq!(specific.text("hookEventName"), "PreToolUse");
        assert_eq!(specific.text("permissionDecision"), "deny");
        assert!(
            specific
                .text("permissionDecisionReason")
                .contains("Puck holds it")
        );
        // Only the provider-defined keys: Codex's schema allows no others.
        assert_eq!(parsed.len(), 1);
        assert_eq!(specific.len(), 3);
        {
            let requests = daemon.requests.lock().unwrap();
            assert_eq!(requests[0].text("relay_session_key"), "george-1");
            assert_eq!(requests[0].text("action"), "Edit README.md");
        }

        // The Codex shell tool is refused the same way.
        assert!(
            pre_tool_use(
                &payload("Bash", "command", "git push"),
                "george-1",
                HOME,
                &daemon
            )
            .is_some()
        );
    }

    #[test]
    fn reads_allowed_writes_and_a_down_daemon_print_nothing() {
        let daemon = ClaimDaemon {
            refusing: Some(CWD.to_string()),
            requests: Mutex::default(),
        };
        for (tool, key, value) in [
            ("Read", "file_path", "/Users/me/dev/relay-runner/README.md"),
            ("Bash", "command", "git status && git log && git diff"),
            ("Bash", "command", "cargo test"),
        ] {
            assert_eq!(
                pre_tool_use(&payload(tool, key, value), "george-1", HOME, &daemon),
                None
            );
        }
        // None of those needed the daemon.
        assert!(daemon.requests.lock().unwrap().is_empty());
        assert_eq!(
            pre_tool_use(
                &payload("Write", "file_path", "/Users/me/dev/elsewhere/a.txt"),
                "george-1",
                HOME,
                &daemon
            ),
            None
        );
        let down = ClaimDaemon {
            refusing: None,
            requests: Mutex::default(),
        };
        assert_eq!(
            pre_tool_use(
                &payload("Bash", "command", "git push"),
                "george-1",
                HOME,
                &down
            ),
            None
        );
        assert_eq!(down.requests.lock().unwrap().len(), 1);
        // No session key: nothing is enforced or asked.
        assert_eq!(
            pre_tool_use(&payload("Bash", "command", "git push"), "", HOME, &daemon),
            None
        );
    }
}
