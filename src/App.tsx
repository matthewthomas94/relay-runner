import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import Settings from "./components/Settings";
import { ErrorBoundary } from "./ErrorBoundary";

export interface Config {
  stt: {
    model: string;
    input_device: string;
    input_mode: string;
    push_to_talk_key: string;
    vad_sensitivity: string;
  };
  tts: {
    engine: string;
    voice: string;
    rate: number;
    auto_play: boolean;
    chime: string;
    show_notification: boolean;
  };
  controls: {
    play_pause_key: string;
    skip_key: string;
  };
  general: {
    command: string;
    terminal: string;
    auto_start: boolean;
  };
}

const defaultConfig: Config = {
  stt: {
    model: "parakeet-tdt-v2",
    input_device: "default",
    input_mode: "always_on",
    push_to_talk_key: "",
    vad_sensitivity: "medium",
  },
  tts: {
    engine: "kokoro",
    voice: "af_bella",
    rate: 1.0,
    auto_play: true,
    chime: "Tink",
    show_notification: true,
  },
  controls: {
    play_pause_key: "F5",
    skip_key: "Shift+F5",
  },
  general: {
    command: "claude",
    terminal: "warp",
    auto_start: false,
  },
};

function App() {
  const [config, setConfig] = useState<Config>(defaultConfig);
  const [voices, setVoices] = useState<string[]>([]);
  const [chimes, setChimes] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    invoke<Config>("get_config")
      .then(setConfig)
      .catch(() => {});
    invoke<string[]>("list_voices")
      .then(setVoices)
      .catch(() => setVoices(["af_bella", "af_sarah", "am_adam", "bf_emma"]));
    invoke<string[]>("list_chimes")
      .then(setChimes)
      .catch(() => setChimes(["Tink", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine"]));
  }, []);

  const handleSave = async (newConfig: Config) => {
    setSaving(true);
    try {
      await invoke("save_config", { config: newConfig });
      setConfig(newConfig);
    } catch (e) {
      console.error("Failed to save config:", e);
    } finally {
      setSaving(false);
    }
  };

  return (
    <ErrorBoundary>
      <div className="app">
        <Settings
          config={config}
          voices={voices}
          chimes={chimes}
          saving={saving}
          onSave={handleSave}
        />
      </div>
    </ErrorBoundary>
  );
}

export default App;
