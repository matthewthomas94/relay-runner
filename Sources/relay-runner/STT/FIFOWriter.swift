import Foundation

/// Named pipe I/O for communicating with voice_bridge.py.
/// Port of stt-sidecar/Sources/VoiceListen/main.swift:41-61.
enum FIFOWriter {

    static let voiceFifoPath = "/tmp/voice_in.fifo"

    static func ensureFifo(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            var sb = stat()
            stat(path, &sb)
            if (sb.st_mode & S_IFMT) == S_IFIFO { return }
            try? fm.removeItem(atPath: path)
        }
        mkfifo(path, 0o644)
    }

    @discardableResult
    static func write(_ text: String, to path: String = voiceFifoPath) -> Bool {
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard let data = (text + "\n").data(using: .utf8) else { return false }
        return data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count) >= 0
        }
    }
}
