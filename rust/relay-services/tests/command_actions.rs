//! The daemon's ticket summaries and command resolution (RR-499): each
//! spoken command gives its recorded summary, title and resolved action.

use relay_intents::json::{self, Value};
use relay_services::command_actions::{
    refined_command_summary, refined_ticket_title, resolve_command_action,
};

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

/// `[summary, title, action kind, ticket id, reason]` for each command,
/// recorded from the Python bridge before RR-487 removed it.
const EXPECTED: &str = r#"
["Fix login bug settings page.", "Fix login bug settings page", "needs_project", null, "Project implementation needs a confirmed target repository"]
["Implement use new flow.", "Implement use new flow", "update_ticket", "RR-12", ""]
["Clean up up handling bridge cache.", "Clean up up handling bridge cache", "create_ticket", null, "Substantial or explicitly tracked general work needs a refined General ticket"]
["Write migration moves every old-config value new.", "Write migration moves every old-config value new", "create_ticket", null, "Substantial or explicitly tracked general work needs a refined General ticket"]
["Implement what s screen.", "Implement what s screen", "direct_action", null, "screen_observation"]
["Implement requested project change.", "Implement requested project change", "conversation", null, ""]
["Implement requested project change.", "Implement requested project change", "conversation", null, ""]
["Ship requested project change.", "Ship requested project change", "create_ticket", null, "Substantial or explicitly tracked general work needs a refined General ticket"]
["Update requested project change.", "Update requested project change", "create_ticket", null, "Substantial or explicitly tracked general work needs a refined General ticket"]
["Implement very-long-hyphenated-subject-name-that-keeps-going-for-quite-a-while-yes another-extremely-long-hyphenated-subject-name-so-the-title-needs-cutting.", "Implement very-long-hyphenated-subject-name-that-keeps-going-for-quite-a-...", "create_ticket", null, "Substantial or explicitly tracked general work needs a refined General ticket"]
["Implement dispatch.", "Implement dispatch", "dispatch_ticket", "RR-7", ""]
["Build n code parser.", "Build n code parser", "conversation", null, ""]
["Add tests.", "Add tests", "inspect_ticket", "GEN-0123", "ticket_reference"]
"#;

#[test]
fn summaries_titles_and_actions_are_recorded() {
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
    assert_eq!(actual, EXPECTED.trim().lines().collect::<Vec<_>>());
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
