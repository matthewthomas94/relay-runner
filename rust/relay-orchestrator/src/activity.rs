//! A worker's live activity summary (RR-12): its most recent tool call,
//! distilled to a chip of at most 60 characters for the board
//! (`derive_activity`, `derive_codex_activity` and their helpers in
//! `services/orchestrator.py`).

use std::sync::LazyLock;

use relay_intents::json::{Dict, Value, py_is_space, py_strip};
use relay_intents::pattern::{self, Regex};
use relay_services::continuity::providers::shlex_split;

pub const ACTIVITY_MAX_LEN: usize = 60;
/// A no-op tool does not replace an activity set this recently.
pub const ACTIVITY_DEBOUNCE_SECONDS: f64 = 5.0;
/// How often a tool in flight refreshes `activity_at`.
pub const ACTIVITY_HEARTBEAT_SECONDS: f64 = 5.0;
/// `_NOOP_TOOLS`.
pub const NOOP_TOOLS: [&str; 4] = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList"];
const SHELL_NAMES: [&str; 3] = ["sh", "bash", "zsh"];

fn compile(text: &str) -> Regex {
    pattern::compile(text, false)
}

static SWIFT_TEST: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(swift test|xcodebuild\b.*\btest\b)\b"));
static SWIFT_BUILD: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(swift build|xcodebuild)\b"));
static PYTEST: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(pytest|python3? -m pytest)\b"));
static NODE_TASK: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(npm|pnpm|yarn) (run )?(test|lint|build)\b"));
static MAKE_TASK: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(make|just) (test|lint|build)\b"));
static TASK_NAME: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(test|lint|build)\b"));
static SEARCH: LazyLock<Regex> = LazyLock::new(|| compile(r"\b(git grep|rg|grep)\b"));
static LS_FILES: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit ls-files\b"));
static GIT_COMMIT: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit commit\b"));
static GIT_ADD: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit add\b"));
static GIT_STATUS: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit status\b"));
static GIT_INSPECT: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit (diff|show|log)\b"));
static GIT_OTHER: LazyLock<Regex> = LazyLock::new(|| compile(r"\bgit \w+"));

/// `_clip(text)`: stripped, and cut to the limit with an ellipsis.
pub fn clip(text: &str) -> String {
    let text = py_strip(text);
    if text.chars().count() <= ACTIVITY_MAX_LEN {
        return text.to_string();
    }
    let head: String = text.chars().take(ACTIVITY_MAX_LEN - 1).collect();
    format!("{}…", head.trim_end_matches(py_is_space))
}

/// `os.path.basename(path)`.
fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// `_shell_words(command)`: `shlex.split`, or a whitespace split where the
/// line does not parse.
fn shell_words(command: &str) -> Vec<String> {
    shlex_split(command).unwrap_or_else(|| {
        command
            .split(py_is_space)
            .filter(|word| !word.is_empty())
            .map(str::to_string)
            .collect()
    })
}

/// `_unwrap_shell_command(command)`: the first line, or the script of an
/// `env ... sh -c '<script>'` wrapper.
fn unwrap_shell_command(command: &str) -> String {
    let stripped = py_strip(command);
    let first = relay_artifacts::pystr::splitlines(stripped)
        .first()
        .map(|line| py_strip(line).to_string())
        .unwrap_or_default();
    let mut words = shell_words(&first);
    if words.is_empty() {
        return String::new();
    }
    if basename(&words[0]) == "env" && words.len() > 1 {
        let mut index = 1;
        while index < words.len() && (words[index].starts_with('-') || words[index].contains('=')) {
            index += 1;
        }
        if index < words.len() {
            words.drain(..index);
        }
    }
    if SHELL_NAMES.contains(&basename(&words[0])) {
        for (index, word) in words.iter().enumerate().skip(1) {
            if word == "-c" || (word.starts_with('-') && word[1..].contains('c')) {
                if index + 1 < words.len() {
                    return py_strip(&words[index + 1]).to_string();
                }
                break;
            }
        }
    }
    first
}

/// `_activity_from_description(description)`: capitalised and clipped.
fn activity_from_description(description: &str) -> String {
    let description = py_strip(description);
    let mut characters = description.chars();
    let Some(first) = characters.next() else {
        return String::new();
    };
    clip(&format!("{}{}", first.to_uppercase(), characters.as_str()))
}

/// `_task_activity(task)`.
fn task_activity(task: &str) -> &'static str {
    match task {
        "test" => "Running tests",
        "lint" => "Running lint",
        "build" => "Running build",
        _ => "Running project task",
    }
}

fn found(regex: &Regex, text: &str) -> bool {
    pattern::search(regex, text)
}

/// `_semantic_shell_activity(command, description)`.
pub fn semantic_shell_activity(command: &str, description: &str) -> String {
    let command = unwrap_shell_command(command);
    let lowered = command.to_lowercase();
    let lower = lowered
        .split(py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let words = shell_words(&command);
    let first = words.first().map(|word| basename(word)).unwrap_or_default();
    let or_description = |fallback: &str| {
        let text = activity_from_description(description);
        if text.is_empty() {
            fallback.to_string()
        } else {
            text
        }
    };
    if lower.is_empty() {
        return or_description("Running command");
    }
    if lower.contains("apply_patch") {
        return "Editing source files".to_string();
    }
    if found(&SWIFT_TEST, &lower) {
        return "Running Swift tests".to_string();
    }
    if found(&SWIFT_BUILD, &lower) {
        return "Running Swift build".to_string();
    }
    if found(&PYTEST, &lower) {
        return "Running Python tests".to_string();
    }
    if found(&NODE_TASK, &lower) || found(&MAKE_TASK, &lower) {
        return pattern::group(&TASK_NAME, &lower, 1)
            .map_or("Running project task", task_activity)
            .to_string();
    }
    if found(&SEARCH, &lower) {
        return "Searching source files".to_string();
    }
    if ["find", "fd"].contains(&first) {
        return "Finding files".to_string();
    }
    if ["cat", "sed", "head", "tail", "nl", "wc"].contains(&first) {
        return "Reading source files".to_string();
    }
    if ["ls", "pwd", "tree"].contains(&first) || found(&LS_FILES, &lower) {
        return "Inspecting workspace".to_string();
    }
    if found(&GIT_COMMIT, &lower) {
        return "Committing changes".to_string();
    }
    if found(&GIT_ADD, &lower) {
        return "Staging changes".to_string();
    }
    if found(&GIT_STATUS, &lower) {
        return "Checking git status".to_string();
    }
    if found(&GIT_INSPECT, &lower) {
        return "Inspecting git changes".to_string();
    }
    if found(&GIT_OTHER, &lower) {
        return "Working with git".to_string();
    }
    or_description("Investigating")
}

/// `str(value or "")`.
fn text_or_empty(value: Option<&Value>) -> String {
    value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default()
}

/// `derive_activity(tool_name, tool_input)`: a Claude tool call.
pub fn derive_activity(tool_name: &str, tool_input: Option<&Dict>) -> String {
    let empty = Dict::new();
    let input = tool_input.unwrap_or(&empty);
    let base = |path: &str| {
        let name = basename(path);
        if name.is_empty() {
            path.to_string()
        } else {
            name.to_string()
        }
    };
    match tool_name {
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
            let file = input
                .truthy("file_path")
                .or_else(|| input.truthy("notebook_path"))
                .map(Value::py_str)
                .unwrap_or_default();
            if file.is_empty() {
                clip("Editing")
            } else {
                clip(&format!("Editing {}", base(&file)))
            }
        }
        "Read" => {
            let file = text_or_empty(input.get("file_path"));
            if file.is_empty() {
                clip("Reading")
            } else {
                clip(&format!("Reading {}", base(&file)))
            }
        }
        "Grep" | "Glob" => "Searching".to_string(),
        "Bash" => {
            let command = text_or_empty(input.get("command"));
            let description = text_or_empty(input.get("description"));
            semantic_shell_activity(py_strip(&command), py_strip(&description))
        }
        "WebFetch" | "WebSearch" => "Researching".to_string(),
        "Task" | "Agent" => "Delegating to sub-agent".to_string(),
        "TodoWrite" | "TaskCreate" | "TaskUpdate" | "TaskList" => "Planning".to_string(),
        _ => {
            let clipped = clip(tool_name);
            if clipped.is_empty() {
                "Working".to_string()
            } else {
                clipped
            }
        }
    }
}

/// `derive_codex_activity(item)`: a Codex `exec --json` item.
pub fn derive_codex_activity(item: &Dict) -> String {
    let kind = text_or_empty(item.get("type"));
    if kind == "command_execution" {
        let command = text_or_empty(item.get("command"));
        return semantic_shell_activity(py_strip(&command), "");
    }
    if kind == "file_change" {
        let paths: Vec<String> = item
            .get("changes")
            .filter(|value| value.truthy())
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .map(|change| text_or_empty(change.get("path")))
            .collect();
        if paths.iter().any(|path| path.contains("/.orchestrator/")) {
            return "Updating ticket run log".to_string();
        }
        return "Editing source files".to_string();
    }
    if kind == "web_search" || kind == "web_search_call" {
        return "Researching".to_string();
    }
    let name = item
        .truthy("name")
        .or_else(|| item.truthy("tool_name"))
        .map(Value::py_str)
        .unwrap_or(kind);
    if name.ends_with("apply_patch") {
        return "Editing source files".to_string();
    }
    let clipped = clip(&name);
    if clipped.is_empty() {
        "Working".to_string()
    } else {
        clipped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(pairs: &[(&str, &str)]) -> Dict {
        let mut dict = Dict::new();
        for (key, value) in pairs {
            dict.insert(key, *value);
        }
        dict
    }

    #[test]
    fn claude_tools_summarise_as_python_does() {
        assert_eq!(
            derive_activity("Edit", Some(&input(&[("file_path", "/a/b/main.rs")]))),
            "Editing main.rs"
        );
        assert_eq!(derive_activity("Read", None), "Reading");
        assert_eq!(derive_activity("Glob", None), "Searching");
        assert_eq!(derive_activity("WebFetch", None), "Researching");
        assert_eq!(derive_activity("Agent", None), "Delegating to sub-agent");
        assert_eq!(derive_activity("TodoWrite", None), "Planning");
        assert_eq!(derive_activity("", None), "Working");
        assert_eq!(derive_activity("mcp__x__y", None), "mcp__x__y");
        assert_eq!(
            derive_activity(
                "Bash",
                Some(&input(&[
                    ("command", "swift build"),
                    ("description", "Build the project")
                ]))
            ),
            "Running Swift build"
        );
        assert_eq!(
            derive_activity(
                "Bash",
                Some(&input(&[
                    ("command", "cat .orchestrator/CT-1.md"),
                    ("description", "Read the ticket")
                ]))
            ),
            "Reading source files"
        );
    }

    #[test]
    fn shell_commands_unwrap_env_and_shell_wrappers() {
        assert_eq!(
            semantic_shell_activity("env A=1 bash -lc 'git commit -m x'", ""),
            "Committing changes"
        );
        assert_eq!(
            semantic_shell_activity("/bin/zsh -c \"npm run test\"", ""),
            "Running tests"
        );
        assert_eq!(semantic_shell_activity("make lint", ""), "Running lint");
        assert_eq!(semantic_shell_activity("", "look around"), "Look around");
        assert_eq!(semantic_shell_activity("", ""), "Running command");
        assert_eq!(
            semantic_shell_activity("./run.sh", "describe it"),
            "Describe it"
        );
        assert_eq!(semantic_shell_activity("./run.sh", ""), "Investigating");
        assert_eq!(semantic_shell_activity("git push", ""), "Working with git");
        assert_eq!(
            semantic_shell_activity("rg foo", ""),
            "Searching source files"
        );
        assert_eq!(
            semantic_shell_activity("ls -la", ""),
            "Inspecting workspace"
        );
    }

    #[test]
    fn codex_items_summarise_as_python_does() {
        let mut item = input(&[
            ("type", "command_execution"),
            ("command", "git diff --stat"),
        ]);
        assert_eq!(derive_codex_activity(&item), "Inspecting git changes");
        item = input(&[("type", "file_change")]);
        let mut change = Dict::new();
        change.insert("path", "/w/.orchestrator/CT-1.md");
        item.insert("changes", Value::List(vec![Value::Dict(change)]));
        assert_eq!(derive_codex_activity(&item), "Updating ticket run log");
        assert_eq!(
            derive_codex_activity(&input(&[("type", "web_search")])),
            "Researching"
        );
        assert_eq!(
            derive_codex_activity(&input(&[("type", "mcp"), ("name", "fs/apply_patch")])),
            "Editing source files"
        );
        assert_eq!(derive_codex_activity(&Dict::new()), "Working");
    }

    #[test]
    fn long_text_is_clipped_with_an_ellipsis() {
        let long = "word ".repeat(30);
        let clipped = clip(&long);
        assert!(clipped.ends_with('…'));
        assert!(clipped.chars().count() <= ACTIVITY_MAX_LEN);
    }
}
