//! The daemon's ticket summaries and command resolution against
//! `services/command_actions.py` (RR-499): the same spoken commands give the
//! same summary, title and resolved action in Rust and in Python.

mod common;

use relay_intents::json::{self, Value};
use relay_services::command_actions::{
    refined_command_summary, refined_ticket_title, resolve_command_action,
};

use common::{TempRoot, python, run_python};

const COMMANDS: &[&str] = &[
    "Fix the login bug on the settings page",
    "Can you please make RR-12 use the new API token flow",
    "clean up the source_text handling in the bridge and the transcript cache",
    "Let's write a migration that moves every old_config value into the new store and then \
     refactor the loader to read only the new store keys from disk",
    "what's on my screen?",
    "",
    "   ",
    "Ship it",
    "update update update",
    "Implement a very-long-hyphenated-subject-name-that-keeps-going-for-quite-a-while-yes \
     another-extremely-long-hyphenated-subject-name-so-the-title-needs-cutting",
    "dispatch RR-7",
    "Café naïve résumé: build the ünïcode parser",
    "gen-0123 abc-1x add tests for rr-4 and Rr-5",
];

const PYTHON: &str = r#"
import json, command_actions as c
for text in json.loads(sys.argv[1]):
    action = c.resolve_command_action(text)
    print(json.dumps([c.refined_command_summary(text), c.refined_ticket_title(text),
                      action.kind, action.ticket_id, action.reason]))
"#;

#[test]
fn summaries_titles_and_actions_match_python() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("command-actions");
    let commands = json::dumps(&Value::List(
        COMMANDS.iter().map(|text| Value::from(*text)).collect(),
    ));
    let expected = run_python(&python, &root.path, PYTHON, &[&commands]);
    let actual: Vec<String> = COMMANDS
        .iter()
        .map(|text| {
            let action = resolve_command_action(text, None, None);
            json::dumps(&Value::List(vec![
                refined_command_summary(text).into(),
                refined_ticket_title(text).into(),
                action.kind.as_str().into(),
                action.ticket_id.clone().into(),
                action.reason.into(),
            ]))
        })
        .collect();
    assert_eq!(actual, expected.lines().collect::<Vec<_>>());
}

#[test]
fn private_words_and_ticket_ids_stay_out_of_titles() {
    assert_eq!(
        refined_command_summary("please fix the API key leak in RR-12"),
        "Fix leak."
    );
    assert_eq!(
        refined_ticket_title("   "),
        "Implement requested project change"
    );
}
