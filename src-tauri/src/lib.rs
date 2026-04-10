use serde::{Deserialize, Serialize};
use std::fs;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::Mutex;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem},
    AppHandle, Manager, State,
};

// Custom deserializer: accept both TOML integer and float for the rate field
fn deserialize_rate<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    struct RateVisitor;
    impl<'de> de::Visitor<'de> for RateVisitor {
        type Value = f64;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            write!(f, "a number (integer or float)")
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<f64, E> {
            Ok(v as f64)
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<f64, E> {
            Ok(v as f64)
        }
        fn visit_f64<E: de::Error>(self, v: f64) -> Result<f64, E> {
            Ok(v)
        }
    }
    deserializer.deserialize_any(RateVisitor)
}

// ---------------------------------------------------------------------------
// Config types — mirrors config.toml
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub stt: SttConfig,
    pub tts: TtsConfig,
    pub controls: ControlsConfig,
    pub general: GeneralConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SttConfig {
    pub model: String,
    pub input_device: String,
    pub input_mode: String,
    pub push_to_talk_key: String,
    pub vad_sensitivity: String,
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsConfig {
    pub engine: String,
    pub voice: String,
    #[serde(deserialize_with = "deserialize_rate")]
    pub rate: f64,
    #[serde(default = "default_true")]
    pub auto_play: bool,
    pub chime: String,
    pub show_notification: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlsConfig {
    pub play_pause_key: String,
    pub skip_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralConfig {
    pub command: String,
    #[serde(default = "default_terminal")]
    pub terminal: String,
    pub auto_start: bool,
}

fn default_terminal() -> String {
    "warp".into()
}

impl Default for Config {
    fn default() -> Self {
        Config {
            stt: SttConfig {
                model: "parakeet-tdt-v2".into(),
                input_device: "default".into(),
                input_mode: "always_on".into(),
                push_to_talk_key: String::new(),
                vad_sensitivity: "medium".into(),
            },
            tts: TtsConfig {
                engine: "kokoro".into(),
                voice: "af_bella".into(),
                rate: 1.0,
                auto_play: true,
                chime: "Tink".into(),
                show_notification: true,
            },
            controls: ControlsConfig {
                play_pause_key: "F5".into(),
                skip_key: "Shift+F5".into(),
            },
            general: GeneralConfig {
                command: "claude".into(),
                terminal: "warp".into(),
                auto_start: false,
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Config file I/O
// ---------------------------------------------------------------------------

fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("voice-terminal")
}

fn config_path() -> PathBuf {
    config_dir().join("config.toml")
}

fn load_config() -> Config {
    let path = config_path();
    let mut config = if path.exists() {
        let content = fs::read_to_string(&path).unwrap_or_default();
        toml::from_str(&content).unwrap_or_default()
    } else {
        Config::default()
    };
    migrate_config(&mut config);
    config
}

fn migrate_config(config: &mut Config) {
    // Migrate old Whisper STT models to Parakeet
    match config.stt.model.as_str() {
        "tiny.en" | "base.en" | "small.en" | "medium.en" => {
            config.stt.model = "parakeet-tdt-v2".into();
        }
        "large" | "large-v3" => {
            config.stt.model = "parakeet-tdt-v3".into();
        }
        _ => {}
    }
    // Migrate old TTS engines (say/piper -> kokoro)
    if config.tts.engine == "say" || config.tts.engine == "piper" {
        let voice_map: &[(&str, &str)] = &[
            ("Amy", "bf_emma"),
            ("Libritts", "af_bella"),
            ("Glow-TTS", "af_sarah"),
        ];
        let new_voice = voice_map
            .iter()
            .find(|(old, _)| *old == config.tts.voice)
            .map(|(_, new)| *new)
            .unwrap_or("af_bella");
        config.tts.engine = "kokoro".into();
        config.tts.voice = new_voice.into();
    }
    // Migrate old WPM rate (int > 10) to length-scale (0.5-2.0)
    if config.tts.rate > 10.0 {
        config.tts.rate = (2.0 - (config.tts.rate - 100.0) * 1.5 / 200.0).clamp(0.5, 2.0);
    }
}

fn save_config_to_disk(config: &Config) -> Result<(), String> {
    let dir = config_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create config dir: {e}"))?;
    let content = toml::to_string_pretty(config).map_err(|e| format!("Failed to serialize config: {e}"))?;
    fs::write(config_path(), content).map_err(|e| format!("Failed to write config: {e}"))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Process manager
// ---------------------------------------------------------------------------

pub struct ProcessManager {
    children: Vec<(&'static str, Child)>,
    services_dir: PathBuf,
    models_dir: PathBuf,
    sidecar_bin: PathBuf,
}

impl ProcessManager {
    fn new(services_dir: PathBuf, models_dir: PathBuf, sidecar_bin: PathBuf) -> Self {
        ProcessManager {
            children: Vec::new(),
            services_dir,
            models_dir,
            sidecar_bin,
        }
    }

    fn start_services(&mut self, config: &Config) {
        self.stop_services();

        // Create FIFO before services start
        let _ = std::process::Command::new("mkfifo")
            .arg("/tmp/voice_in.fifo")
            .output();

        let config_path_str = config_path().to_string_lossy().to_string();
        let models_dir_str = self.models_dir.to_string_lossy().to_string();

        // Start voice-listen sidecar (FluidAudio/Parakeet STT on Neural Engine)
        if let Ok(child) = Command::new(&self.sidecar_bin)
            .arg("--model")
            .arg(&config.stt.model)
            .arg("--input-mode")
            .arg(&config.stt.input_mode)
            .arg("--vad-sensitivity")
            .arg(&config.stt.vad_sensitivity)
            .env("VOICE_MODELS_DIR", &models_dir_str)
            .spawn()
        {
            self.children.push(("voice_listen", child));
        }

        // Launch voice_bridge.py in the user's preferred terminal.
        // Shows the conversation visually and handles TTS via clean JSON API.
        let bridge_script = self.services_dir.join("voice_bridge.py");

        #[cfg(target_os = "macos")]
        {
            let terminal = config.general.terminal.to_lowercase();
            let launcher = "/tmp/voice_bridge_launch.sh";
            // Use venv Python if available, otherwise fall back to system python3
            let venv_python = self.services_dir.join(".venv/bin/python3");
            let python_bin = if venv_python.exists() {
                venv_python.to_string_lossy().to_string()
            } else {
                "python3".to_string()
            };
            let _ = std::fs::write(
                launcher,
                format!(
                    "#!/bin/bash\nexport VOICE_MODELS_DIR='{}'\nexec '{}' '{}' --config '{}'\n",
                    models_dir_str,
                    python_bin,
                    bridge_script.display(),
                    config_path_str,
                ),
            );
            let _ = Command::new("chmod").arg("+x").arg(launcher).output();

            match terminal.as_str() {
                "warp" => {
                    let apple_script = format!(
                        "tell application \"Warp\" to activate\n\
                         delay 0.5\n\
                         tell application \"System Events\"\n\
                           tell process \"Warp\"\n\
                             keystroke \"t\" using command down\n\
                             delay 0.3\n\
                             keystroke \"bash {}\"\n\
                             keystroke return\n\
                           end tell\n\
                         end tell",
                        launcher,
                    );
                    let _ = Command::new("osascript")
                        .arg("-e")
                        .arg(&apple_script)
                        .spawn();
                }
                "iterm2" | "iterm" => {
                    let apple_script = format!(
                        r#"tell application "iTerm2"
                            activate
                            tell current window
                                create tab with default profile command "bash {}"
                            end tell
                        end tell"#,
                        launcher,
                    );
                    let _ = Command::new("osascript")
                        .arg("-e")
                        .arg(&apple_script)
                        .spawn();
                }
                _ => {
                    let apple_script = format!(
                        r#"tell application "Terminal"
                            activate
                            do script "bash {}"
                        end tell"#,
                        launcher,
                    );
                    let _ = Command::new("osascript")
                        .arg("-e")
                        .arg(&apple_script)
                        .spawn();
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let shell_cmd = format!(
                "VOICE_MODELS_DIR='{}' python3 '{}' --config '{}'",
                models_dir_str,
                bridge_script.display(),
                config_path_str,
            );
            let _ = Command::new("x-terminal-emulator")
                .arg("-e")
                .arg(&shell_cmd)
                .spawn();
        }
    }

    fn stop_services(&mut self) {
        // Kill managed child processes (voice_listen, tts_worker)
        for (name, child) in self.children.iter_mut() {
            let _ = child.kill();
            let _ = child.wait();
            eprintln!("[process_manager] Stopped {name}");
        }
        self.children.clear();

        // Kill any voice_bridge.py processes (spawned in terminal, not tracked as Child)
        let _ = Command::new("pkill")
            .args(["-f", "voice_bridge.py"])
            .output();

        // Clean up IPC files
        let _ = fs::remove_file("/tmp/voice_in.fifo");
        let _ = fs::remove_file("/tmp/tts_control.sock");
    }

    fn is_running(&self) -> bool {
        !self.children.is_empty()
    }
}

impl Drop for ProcessManager {
    fn drop(&mut self) {
        self.stop_services();
    }
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

pub struct AppState {
    config: Mutex<Config>,
    process_manager: Mutex<ProcessManager>,
}

// ---------------------------------------------------------------------------
// Tauri commands (called from React frontend)
// ---------------------------------------------------------------------------

#[tauri::command]
fn get_config(state: State<AppState>) -> Config {
    eprintln!("[tauri] get_config called");
    let cfg = state.config.lock().unwrap().clone();
    eprintln!("[tauri] get_config returning rate={}", cfg.tts.rate);
    cfg
}

#[tauri::command]
fn save_config(state: State<AppState>, config: Config) -> Result<(), String> {
    save_config_to_disk(&config)?;

    let mut current = state.config.lock().unwrap();
    *current = config.clone();

    // Restart services with new config if they were running
    let mut pm = state.process_manager.lock().unwrap();
    if pm.is_running() {
        pm.start_services(&config);
    }

    Ok(())
}

#[tauri::command]
fn start_services(state: State<AppState>) -> Result<(), String> {
    let config = state.config.lock().unwrap().clone();
    let mut pm = state.process_manager.lock().unwrap();
    pm.start_services(&config);
    Ok(())
}

#[tauri::command]
fn stop_services(state: State<AppState>) -> Result<(), String> {
    let mut pm = state.process_manager.lock().unwrap();
    pm.stop_services();
    Ok(())
}

#[tauri::command]
fn services_running(state: State<AppState>) -> bool {
    state.process_manager.lock().unwrap().is_running()
}

#[tauri::command]
fn tts_command(cmd: String) -> Result<(), String> {
    let sock_path = "/tmp/tts_control.sock";
    let sock = UnixDatagram::unbound().map_err(|e| format!("Socket error: {e}"))?;
    sock.send_to(cmd.as_bytes(), sock_path)
        .map_err(|e| format!("Send error: {e}"))?;
    Ok(())
}

#[tauri::command]
fn list_voices() -> Vec<String> {
    vec![
        "af_bella".into(), "af_sarah".into(), "af_nicole".into(),
        "af_sky".into(), "af_heart".into(),
        "am_adam".into(), "am_michael".into(),
        "bf_emma".into(), "bf_isabella".into(),
        "bm_george".into(), "bm_lewis".into(),
    ]
}

#[tauri::command]
fn list_chimes() -> Vec<String> {
    let sounds_dir = PathBuf::from("/System/Library/Sounds");
    if let Ok(entries) = fs::read_dir(&sounds_dir) {
        entries
            .filter_map(|e| {
                let e = e.ok()?;
                let name = e.file_name().to_string_lossy().to_string();
                if name.ends_with(".aiff") {
                    Some(name.trim_end_matches(".aiff").to_string())
                } else {
                    None
                }
            })
            .collect()
    } else {
        vec!["Tink".into(), "Glass".into(), "Ping".into(), "Pop".into()]
    }
}

// ---------------------------------------------------------------------------
// App setup
// ---------------------------------------------------------------------------

fn resolve_resource_dirs() -> (PathBuf, PathBuf, PathBuf) {
    // Bundled app: resources are in ../Resources/ relative to the binary
    if let Some(resources) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|p| p.join("../Resources")))
        .filter(|p| p.join("services").exists())
    {
        return (
            resources.join("services"),
            resources.join("models"),
            resources.join("voice-listen"),
        );
    }

    // Dev mode: services/ and models/ at the project root, sidecar in stt-sidecar/
    for base in [
        std::env::current_dir().ok(),
        std::env::current_dir().ok().and_then(|cwd| cwd.join("..").canonicalize().ok()),
    ]
    .into_iter()
    .flatten()
    {
        if base.join("services").exists() {
            // Prefer release build, fall back to debug
            let sidecar = if base.join("stt-sidecar/.build/release/voice-listen").exists() {
                base.join("stt-sidecar/.build/release/voice-listen")
            } else {
                base.join("stt-sidecar/.build/debug/voice-listen")
            };
            return (
                base.join("services"),
                base.join("models"),
                sidecar,
            );
        }
    }

    (
        PathBuf::from("services"),
        PathBuf::from("models"),
        PathBuf::from("voice-listen"),
    )
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let config = load_config();

    // Resolve services, models, and sidecar binary (bundled or development)
    let (services_dir, models_dir, sidecar_bin) = resolve_resource_dirs();

    let auto_start = config.general.auto_start;
    let config_clone = config.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(AppState {
            config: Mutex::new(config),
            process_manager: Mutex::new(ProcessManager::new(services_dir, models_dir, sidecar_bin)),
        })
        .setup(move |app| {
            // Build tray menu
            let status = MenuItemBuilder::with_id("status", "Idle")
                .enabled(false)
                .build(app)?;
            let play = MenuItemBuilder::with_id("play", "Play / Pause").build(app)?;
            let replay = MenuItemBuilder::with_id("replay", "Replay").build(app)?;
            let skip = MenuItemBuilder::with_id("skip", "Skip").build(app)?;
            let sep1 = PredefinedMenuItem::separator(app)?;
            let start = MenuItemBuilder::with_id("start", "Start Services").build(app)?;
            let stop = MenuItemBuilder::with_id("stop", "Stop Services").build(app)?;
            let settings = MenuItemBuilder::with_id("settings", "Settings\u{2026}").build(app)?;
            let sep2 = PredefinedMenuItem::separator(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit Voice Terminal").build(app)?;

            let menu = MenuBuilder::new(app)
                .item(&status)
                .item(&play)
                .item(&replay)
                .item(&skip)
                .item(&sep1)
                .item(&start)
                .item(&stop)
                .item(&settings)
                .item(&sep2)
                .item(&quit)
                .build()?;

            let tray = app.tray_by_id("main-tray")
                .expect("tray icon 'main-tray' not found — check tauri.conf.json");
            tray.set_menu(Some(menu))?;
            tray.set_show_menu_on_left_click(true)?;
            tray.set_tooltip(Some("Voice Terminal"))?;
            tray.on_menu_event(move |app_handle: &AppHandle, event| {
                match event.id().as_ref() {
                    "play" => {
                        let _ = tts_control_send("toggle");
                    }
                    "replay" => {
                        let _ = tts_control_send("replay");
                    }
                    "skip" => {
                        let _ = tts_control_send("skip");
                    }
                    "start" => {
                        let state = app_handle.state::<AppState>();
                        let config = state.config.lock().unwrap().clone();
                        let mut pm = state.process_manager.lock().unwrap();
                        pm.start_services(&config);
                    }
                    "stop" => {
                        let state = app_handle.state::<AppState>();
                        let mut pm = state.process_manager.lock().unwrap();
                        pm.stop_services();
                    }
                    "settings" => {
                        eprintln!("[tauri] Settings menu clicked");
                        if let Some(window) = app_handle.get_webview_window("settings") {
                            eprintln!("[tauri] Showing settings window");
                            let _ = window.show();
                            let _ = window.set_focus();
                            eprintln!("[tauri] Settings window shown");
                        } else {
                            eprintln!("[tauri] Settings window not found!");
                        }
                    }
                    "quit" => {
                        let state = app_handle.state::<AppState>();
                        let mut pm = state.process_manager.lock().unwrap();
                        pm.stop_services();
                        app_handle.exit(0);
                    }
                    _ => {}
                }
            });

            // Auto-start services if configured
            if auto_start {
                let state = app.state::<AppState>();
                let mut pm = state.process_manager.lock().unwrap();
                pm.start_services(&config_clone);
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            start_services,
            stop_services,
            services_running,
            tts_command,
            list_voices,
            list_chimes,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn tts_control_send(cmd: &str) -> Result<(), String> {
    let sock = UnixDatagram::unbound().map_err(|e| format!("{e}"))?;
    sock.send_to(cmd.as_bytes(), "/tmp/tts_control.sock")
        .map_err(|e| format!("{e}"))?;
    Ok(())
}
