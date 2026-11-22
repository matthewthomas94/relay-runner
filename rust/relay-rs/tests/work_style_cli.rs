//! RR-522: `relay-rs work-style` sets the style of the agent
//! `RELAY_SESSION_AGENT` names, in the app's `config.toml`, and no other.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct Home(PathBuf);

impl Home {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("relay-rs-work-style-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("Library/Application Support/relay-runner")).unwrap();
        fs::create_dir_all(path.join("project")).unwrap();
        Self(path)
    }

    fn config(&self) -> PathBuf {
        self.0
            .join("Library/Application Support/relay-runner/config.toml")
    }

    fn work_style(&self, agent: Option<&str>, arguments: &[&str]) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_relay-rs"));
        command
            .arg("work-style")
            .args(arguments)
            .arg("--repo")
            .arg(self.0.join("project"))
            .env("HOME", &self.0)
            .env_remove("RELAY_WORK_STYLE")
            .env_remove("RELAY_SESSION_AGENT");
        if let Some(agent) = agent {
            command.env("RELAY_SESSION_AGENT", agent);
        }
        command.output().unwrap()
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn stdout(output: &Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn saved(config: &Path) -> String {
    fs::read_to_string(config).unwrap()
}

#[test]
fn set_changes_only_the_sessions_agent() {
    let home = Home::new("set");
    let original = "[tts]\nvoice = \"am_puck\"\n\n[agents.george]\nwork_style = \"orchestrated\"\n";
    fs::write(home.config(), original).unwrap();

    let output = home.work_style(Some("isabella"), &["set", "direct"]);
    assert_eq!(
        stdout(&output),
        "project: direct (makes changes now, without tickets), from Isabella's setting\n"
    );
    let text = saved(&home.config());
    assert!(text.starts_with(original), "{text}");
    assert!(
        text.ends_with("[agents.isabella]\nwork_style = \"direct\"\n"),
        "{text}"
    );

    // George keeps its own style; Puck has nothing saved and gets the default.
    assert_eq!(
        stdout(&home.work_style(Some("george"), &["show"])),
        "project: orchestrated (turns changes into tickets for workers), from George's setting\n"
    );
    assert_eq!(
        stdout(&home.work_style(Some("puck"), &[])),
        "project: auto (decides per request, and asks when unsure), from the default\n"
    );

    // Without an agent there is nothing to set.
    let output = home.work_style(None, &["set", "orchestrated"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("RELAY_SESSION_AGENT"));
    assert_eq!(saved(&home.config()), text);
}
