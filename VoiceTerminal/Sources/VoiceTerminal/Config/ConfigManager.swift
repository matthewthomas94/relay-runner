import Foundation
import TOMLKit

// MARK: - Config file I/O

final class ConfigManager {

    static let shared = ConfigManager()

    private let configDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("voice-terminal")
    }()

    var configPath: URL { configDir.appendingPathComponent("config.toml") }

    // MARK: - Load

    func load() -> AppConfig {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return AppConfig()
        }
        guard let raw = try? String(contentsOf: configPath, encoding: .utf8) else {
            return AppConfig()
        }

        guard let table = try? TOMLTable(string: raw) else {
            return AppConfig()
        }

        var config = AppConfig()

        // STT
        if let stt = table["stt"]?.tomlValue.table {
            if let v = tomlString(stt, "model") { config.stt.model = v }
            if let v = tomlString(stt, "input_device") { config.stt.input_device = v }
            if let v = tomlString(stt, "input_mode") { config.stt.input_mode = v }
            if let v = tomlString(stt, "push_to_talk_key") { config.stt.push_to_talk_key = v }
            if let v = tomlString(stt, "vad_sensitivity") { config.stt.vad_sensitivity = v }
        }

        // TTS
        if let tts = table["tts"]?.tomlValue.table {
            if let v = tomlString(tts, "engine") { config.tts.engine = v }
            if let v = tomlString(tts, "voice") { config.tts.voice = v }
            if let v = tomlDouble(tts, "rate") { config.tts.rate = v }
            if let v = tomlBool(tts, "auto_play") { config.tts.auto_play = v }
            if let v = tomlString(tts, "chime") { config.tts.chime = v }
            if let v = tomlBool(tts, "show_notification") { config.tts.show_notification = v }
        }

        // Controls
        if let controls = table["controls"]?.tomlValue.table {
            if let v = tomlString(controls, "play_pause_key") { config.controls.play_pause_key = v }
            if let v = tomlString(controls, "skip_key") { config.controls.skip_key = v }
        }

        // General
        if let general = table["general"]?.tomlValue.table {
            if let v = tomlString(general, "command") { config.general.command = v }
            if let v = tomlString(general, "terminal") { config.general.terminal = v }
            if let v = tomlBool(general, "auto_start") { config.general.auto_start = v }
        }

        // Awareness
        if let awareness = table["awareness"]?.tomlValue.table {
            if let v = tomlBool(awareness, "screen_glow") { config.awareness.screen_glow = v }
            if let v = tomlBool(awareness, "live_transcription") { config.awareness.live_transcription = v }
            if let v = tomlBool(awareness, "message_preview") { config.awareness.message_preview = v }
            if let v = tomlBool(awareness, "live_captions") { config.awareness.live_captions = v }
            if let v = tomlDouble(awareness, "glow_intensity") { config.awareness.glow_intensity = v }
        }

        migrate(&config)
        return config
    }

    // MARK: - Save

    func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let toml = serialize(config)
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // Hand-rolled TOML writer — guaranteed compatible with Python's fallback parser
    private func serialize(_ c: AppConfig) -> String {
        var lines: [String] = []

        lines.append("[stt]")
        lines.append("model = \"\(c.stt.model)\"")
        lines.append("input_device = \"\(c.stt.input_device)\"")
        lines.append("input_mode = \"\(c.stt.input_mode)\"")
        lines.append("push_to_talk_key = \"\(c.stt.push_to_talk_key)\"")
        lines.append("vad_sensitivity = \"\(c.stt.vad_sensitivity)\"")
        lines.append("")

        lines.append("[tts]")
        lines.append("engine = \"\(c.tts.engine)\"")
        lines.append("voice = \"\(c.tts.voice)\"")
        lines.append("rate = \(String(format: "%.1f", c.tts.rate))")
        lines.append("auto_play = \(c.tts.auto_play)")
        lines.append("chime = \"\(c.tts.chime)\"")
        lines.append("show_notification = \(c.tts.show_notification)")
        lines.append("")

        lines.append("[controls]")
        lines.append("play_pause_key = \"\(c.controls.play_pause_key)\"")
        lines.append("skip_key = \"\(c.controls.skip_key)\"")
        lines.append("")

        lines.append("[general]")
        lines.append("command = \"\(c.general.command)\"")
        lines.append("terminal = \"\(c.general.terminal)\"")
        lines.append("auto_start = \(c.general.auto_start)")
        lines.append("")

        lines.append("[awareness]")
        lines.append("screen_glow = \(c.awareness.screen_glow)")
        lines.append("live_transcription = \(c.awareness.live_transcription)")
        lines.append("message_preview = \(c.awareness.message_preview)")
        lines.append("live_captions = \(c.awareness.live_captions)")
        lines.append("glow_intensity = \(String(format: "%.1f", c.awareness.glow_intensity))")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Migration (matches lib.rs:150-180 and config.py:135-157)

    private func migrate(_ config: inout AppConfig) {
        // Whisper models -> Parakeet
        switch config.stt.model {
        case "tiny.en", "base.en", "small.en", "medium.en":
            config.stt.model = "parakeet-tdt-v2"
        case "large", "large-v3":
            config.stt.model = "parakeet-tdt-v3"
        default:
            break
        }

        // say/piper -> kokoro
        if config.tts.engine == "say" || config.tts.engine == "piper" {
            let voiceMap = ["Amy": "bf_emma", "Libritts": "af_bella", "Glow-TTS": "af_sarah"]
            config.tts.voice = voiceMap[config.tts.voice] ?? "af_bella"
            config.tts.engine = "kokoro"
        }

        // WPM rate (int > 10) -> speed multiplier (0.5-2.0)
        if config.tts.rate > 10.0 {
            config.tts.rate = min(2.0, max(0.5, 2.0 - (config.tts.rate - 100.0) * 1.5 / 200.0))
        }
    }
}

// MARK: - TOMLKit value helpers

/// Extract a typed value from a TOMLTable entry.
/// TOMLTable subscript returns TOMLValueConvertible? — the concrete type is TOMLValue
/// which has .string, .int, .double, .bool computed properties.
private func tomlString(_ table: TOMLTable, _ key: String) -> String? {
    table[key]?.tomlValue.string
}

private func tomlBool(_ table: TOMLTable, _ key: String) -> Bool? {
    table[key]?.tomlValue.bool
}

private func tomlDouble(_ table: TOMLTable, _ key: String) -> Double? {
    if let d = table[key]?.tomlValue.double { return d }
    if let i = table[key]?.tomlValue.int { return Double(i) }
    return nil
}
