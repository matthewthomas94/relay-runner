import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import Settings from "./components/Settings";

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
    chime: string;
    show_notification: boolean;
  };
  controls: {
    play_pause_key: string;
    skip_key: string;
  };
  general: {
    command: string;
    auto_start: boolean;
  };
}

const defaultConfig: Config = {
  stt: {
    model: "base.en",
    input_device: "default",
    input_mode: "always_on",
    push_to_talk_key: "",
    vad_sensitivity: "medium",
  },
  tts: {
    engine: "say",
    voice: "Samantha",
    rate: 185,
    chime: "Tink",
    show_notification: true,
  },
  controls: {
    play_pause_key: "F5",
    skip_key: "Shift+F5",
  },
  general: {
    command: "claude",
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
      .catch(() => setVoices(["Samantha", "Alex", "Victoria", "Daniel"]));
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
    <div className="app">
      <Settings
        config={config}
        voices={voices}
        chimes={chimes}
        saving={saving}
        onSave={handleSave}
      />
    </div>
  );
}

export default App;
