import { useState } from "react";
import type { Config } from "../App";
import KeyCapture from "./KeyCapture";

interface SettingsProps {
  config: Config;
  voices: string[];
  chimes: string[];
  saving: boolean;
  onSave: (config: Config) => void;
}

export default function Settings({ config, voices, chimes, saving, onSave }: SettingsProps) {
  const [draft, setDraft] = useState<Config>(config);
  const [activeTab, setActiveTab] = useState<"stt" | "tts" | "controls" | "general">("stt");

  // Sync draft when config prop changes (after save)
  const [prevConfig, setPrevConfig] = useState(config);
  if (config !== prevConfig) {
    setDraft(config);
    setPrevConfig(config);
  }

  const updateSTT = (key: string, value: string) =>
    setDraft({ ...draft, stt: { ...draft.stt, [key]: value } });
  const updateTTS = (key: string, value: string | number | boolean) =>
    setDraft({ ...draft, tts: { ...draft.tts, [key]: value } });
  const updateControls = (key: string, value: string) =>
    setDraft({ ...draft, controls: { ...draft.controls, [key]: value } });
  const updateGeneral = (key: string, value: string | boolean) =>
    setDraft({ ...draft, general: { ...draft.general, [key]: value } });

  const hasChanges = JSON.stringify(draft) !== JSON.stringify(config);

  return (
    <div className="settings">
      <h1>Voice Terminal</h1>

      <nav className="tabs">
        {(["stt", "tts", "controls", "general"] as const).map((tab) => (
          <button
            key={tab}
            className={activeTab === tab ? "active" : ""}
            onClick={() => setActiveTab(tab)}
          >
            {tab === "stt" ? "Speech-to-Text" :
             tab === "tts" ? "Text-to-Speech" :
             tab === "controls" ? "Controls" : "General"}
          </button>
        ))}
      </nav>

      <div className="tab-content">
        {activeTab === "stt" && (
          <section>
            <div className="field">
              <label>STT Model</label>
              <select value={draft.stt.model} onChange={(e) => updateSTT("model", e.target.value)}>
                <option value="parakeet-tdt-v2">Parakeet v2 (recommended)</option>
                <option value="parakeet-tdt-v3">Parakeet v3 (most accurate, larger)</option>
              </select>
            </div>

            <div className="field">
              <label>Input Device</label>
              <select value={draft.stt.input_device} onChange={(e) => updateSTT("input_device", e.target.value)}>
                <option value="default">System Default</option>
              </select>
            </div>

            <div className="field">
              <label>Input Mode</label>
              <div className="toggle-group">
                <button
                  className={draft.stt.input_mode === "caps_lock_toggle" ? "active" : ""}
                  onClick={() => updateSTT("input_mode", "caps_lock_toggle")}
                >
                  Caps Lock
                </button>
                <button
                  className={draft.stt.input_mode === "always_on" ? "active" : ""}
                  onClick={() => updateSTT("input_mode", "always_on")}
                >
                  Always-on
                </button>
                <button
                  className={draft.stt.input_mode === "push_to_talk" ? "active" : ""}
                  onClick={() => updateSTT("input_mode", "push_to_talk")}
                >
                  Push-to-talk
                </button>
              </div>
            </div>

            {draft.stt.input_mode === "push_to_talk" && (
              <KeyCapture
                label="Push-to-talk Key"
                value={draft.stt.push_to_talk_key}
                onChange={(key) => updateSTT("push_to_talk_key", key)}
              />
            )}

            <div className="field">
              <label>VAD Sensitivity</label>
              <select value={draft.stt.vad_sensitivity} onChange={(e) => updateSTT("vad_sensitivity", e.target.value)}>
                <option value="low">Low</option>
                <option value="medium">Medium</option>
                <option value="high">High</option>
              </select>
            </div>
          </section>
        )}

        {activeTab === "tts" && (
          <section>
            <div className="field">
              <label>Voice</label>
              <select value={draft.tts.voice} onChange={(e) => updateTTS("voice", e.target.value)}>
                {voices.map((v) => {
                  const parts = v.split("_");
                  if (parts.length === 2) {
                    const accent = parts[0][0] === "a" ? "American" : "British";
                    const gender = parts[0][1] === "f" ? "Female" : "Male";
                    const name = parts[1].charAt(0).toUpperCase() + parts[1].slice(1);
                    return <option key={v} value={v}>{name} ({accent} {gender})</option>;
                  }
                  return <option key={v} value={v}>{v}</option>;
                })}
              </select>
            </div>

            <div className="field">
              <label>Playback Mode</label>
              <div className="toggle-group">
                <button
                  className={draft.tts.auto_play ? "active" : ""}
                  onClick={() => updateTTS("auto_play", true)}
                >
                  Auto-play
                </button>
                <button
                  className={!draft.tts.auto_play ? "active" : ""}
                  onClick={() => updateTTS("auto_play", false)}
                >
                  Queue
                </button>
              </div>
            </div>

            <div className="field">
              <label>Speech Speed: {draft.tts.rate.toFixed(1)}x</label>
              <input
                type="range"
                min={0.5}
                max={2.0}
                step={0.1}
                value={draft.tts.rate}
                onChange={(e) => updateTTS("rate", parseFloat(e.target.value))}
              />
            </div>

            <div className="field">
              <label>Notification Chime</label>
              <select value={draft.tts.chime} onChange={(e) => updateTTS("chime", e.target.value)}>
                {chimes.map((c) => (
                  <option key={c} value={c}>{c}</option>
                ))}
              </select>
            </div>

            <div className="field checkbox">
              <input
                type="checkbox"
                id="show-notification"
                checked={draft.tts.show_notification}
                onChange={(e) => updateTTS("show_notification", e.target.checked)}
              />
              <label htmlFor="show-notification">Show macOS notification on new message</label>
            </div>
          </section>
        )}

        {activeTab === "controls" && (
          <section>
            <KeyCapture
              label="Play / Pause Key"
              value={draft.controls.play_pause_key}
              onChange={(key) => updateControls("play_pause_key", key)}
            />
            <KeyCapture
              label="Skip Key"
              value={draft.controls.skip_key}
              onChange={(key) => updateControls("skip_key", key)}
            />
          </section>
        )}

        {activeTab === "general" && (
          <section>
            <div className="field">
              <label>Target Command</label>
              <input
                type="text"
                value={draft.general.command}
                onChange={(e) => updateGeneral("command", e.target.value)}
                placeholder="claude"
              />
            </div>

            <div className="field">
              <label>Terminal App</label>
              <select value={draft.general.terminal} onChange={(e) => updateGeneral("terminal", e.target.value)}>
                <option value="warp">Warp</option>
                <option value="terminal">Terminal.app</option>
                <option value="iterm2">iTerm2</option>
                <option value="kitty">Kitty</option>
                <option value="alacritty">Alacritty</option>
              </select>
            </div>

            <div className="field checkbox">
              <input
                type="checkbox"
                id="auto-start"
                checked={draft.general.auto_start}
                onChange={(e) => updateGeneral("auto_start", e.target.checked)}
              />
              <label htmlFor="auto-start">Auto-start services on app launch</label>
            </div>
          </section>
        )}
      </div>

      <div className="actions">
        <button
          className="save-btn"
          disabled={!hasChanges || saving}
          onClick={() => onSave(draft)}
        >
          {saving ? "Saving\u2026" : "Save"}
        </button>
      </div>
    </div>
  );
}
