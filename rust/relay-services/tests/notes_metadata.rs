//! Note metadata generation (RR-499): input the generator refuses, and a
//! provider it does not support, never launch a provider.

use std::sync::atomic::AtomicBool;

use relay_intents::json::Dict;
use relay_services::notes::metadata::{Generate, NoteMetadataGenerator};

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
