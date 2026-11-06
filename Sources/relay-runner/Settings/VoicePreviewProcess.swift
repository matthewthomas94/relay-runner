import Darwin
import Foundation

/// Bounded child-process ownership, independent of playback and app state.
@MainActor
enum VoicePreviewProcess {
    static func signal(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
    }

    static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        signal(process, SIGTERM)
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        if process.isRunning { signal(process, SIGKILL) }
    }

    static func run(_ process: Process, timeout: TimeInterval = 60, cancelled: () -> Bool) async throws {
        let pipe = Pipe()
        // Drain continuously without retaining/logging potentially private stderr.
        pipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
        do {
            guard !cancelled() else { throw CancellationError() }
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                guard !cancelled() else { throw CancellationError() }
                guard Date() < deadline else { throw VoicePreviewFailure.previewFailed }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !cancelled() else { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw VoicePreviewFailure.previewFailed }
        } catch {
            await stop(process)
            throw error
        }
    }
}
