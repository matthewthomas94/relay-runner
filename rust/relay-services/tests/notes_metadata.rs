//! Note metadata generation through both providers (RR-499), against the
//! contract suite's fake CLIs (`tests/contract/fakes/provider.py`): Claude
//! passes the subscription gate and answers on stdout, Codex resolves its
//! family through `app-server` `model/list` and writes `result.json`.

mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::atomic::AtomicBool;

use relay_intents::json::{self, Dict, Value};
use relay_services::notes::metadata::{Generate, NoteMetadataGenerator};

use common::{TempRoot, python, repo_root};

fn wrapper(bin: &Path, python: &Path, state: &Path, name: &str) -> String {
    let script = bin.join(name);
    fs::write(
        &script,
        format!(
            "#!/bin/sh\nRELAY_CONTRACT_FAKE_STATE='{}' exec '{}' '{}' {name} \"$@\"\n",
            state.display(),
            python.display(),
            repo_root()
                .join("tests/contract/fakes/provider.py")
                .display()
        ),
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    script.to_string_lossy().into_owned()
}

fn generator(provider: &str, command: String) -> NoteMetadataGenerator {
    let mut general = Dict::new();
    general.insert("provider", provider);
    general.insert("command", command);
    let mut config = Dict::new();
    config.insert("general", general);
    NoteMetadataGenerator::new(
        Box::new(move || config.clone()),
        Box::new(|_, configured| Ok(configured.to_string())),
    )
}

#[test]
fn claude_and_codex_generate_the_same_fields() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("metadata");
    let bin = root.path.join("bin");
    let state = root.path.join("fake");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(&state).unwrap();
    let cancel = AtomicBool::new(false);
    for provider in ["claude", "codex"] {
        let command = wrapper(&bin, &python, &state, provider);
        let fields = generator(provider, command)
            .generate("We decided to ship.", &cancel)
            .unwrap_or_else(|error| panic!("{provider}: {error}"));
        assert_eq!(fields.string("title"), "Scripted note title", "{provider}");
        assert_eq!(fields.string("provider"), provider);
        assert_eq!(
            fields.get("prompt_version").and_then(Value::py_int),
            Some(1)
        );
        let model = fields.string("model");
        if provider == "claude" {
            assert_eq!(model, "opus");
        } else {
            assert!(model.ends_with("-sol"), "{model}");
        }
    }
    let invocations: Vec<Value> = fs::read_to_string(state.join("invocations.jsonl"))
        .unwrap()
        .lines()
        .filter_map(json::parse)
        .collect();
    let launches: Vec<&Dict> = invocations
        .iter()
        .filter_map(Value::as_dict)
        .filter(|entry| entry.string("role") == "note-metadata")
        .collect();
    assert_eq!(launches.len(), 2);
    for launch in launches {
        assert_eq!(
            json::dumps(launch.get("stdin_keys").unwrap()),
            r#"["relay_captured_transcript"]"#
        );
    }
    // The subscription gate ran for Claude only; Codex asked its catalogue.
    let roles: Vec<String> = invocations
        .iter()
        .filter_map(Value::as_dict)
        .map(|entry| entry.string("role"))
        .collect();
    assert!(roles.contains(&"auth".to_string()));
    assert!(roles.contains(&"app-server".to_string()));
}

#[test]
fn empty_and_oversized_input_never_launches() {
    let cancel = AtomicBool::new(false);
    let never = generator("claude", "/nonexistent".into());
    assert_eq!(never.generate("  ", &cancel).unwrap_err().message, "empty");
    assert_eq!(
        never
            .generate(&"x".repeat(96_001), &cancel)
            .unwrap_err()
            .message,
        "input_too_large"
    );
    let unsupported = generator("gemini", "/nonexistent".into());
    assert_eq!(
        unsupported.generate("text", &cancel).unwrap_err().message,
        "provider_unavailable"
    );
}
