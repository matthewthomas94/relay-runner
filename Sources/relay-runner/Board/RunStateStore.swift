import Foundation

/// One live run as published by the daemon in its runs-index file. Ephemeral
/// state the board overlays on top of the on-disk ticket `status:` — it never
/// touches ticket files. The daemon rewrites the file on every state
/// transition and prunes completed entries after a retention window; see
/// `RunsStore.write_index` in services/orchestrator.py. (RR-11)
struct RunState: Equatable, Decodable {
    let ticketId: String
    let repoPath: String
    let runId: Int
    /// Matches the daemon's run-state enum: Claimed | Running | Succeeded |
    /// Failed | Stalled | Canceled.
    let state: String
    let lastError: String?

    private enum CodingKeys: String, CodingKey {
        case ticketId = "ticket_id"
        case repoPath = "repo_path"
        case runId = "run_id"
        case state
        case lastError = "last_error"
    }

    var isActive: Bool {
        state == "Claimed" || state == "Running" || state == "Stalled"
    }

    /// The column this run forces the card into, overriding the ticket file's
    /// `status:`. `nil` means no override — placement falls back to the file.
    func placement(ticketStatus: Ticket.Status) -> Ticket.Status? {
        switch state {
        case "Claimed", "Running", "Stalled":
            return .inProgress
        case "Succeeded":
            // Worker finished but the human hasn't merged yet (file still
            // `ready`) → surface in Done with an "awaiting merge" pill.
            return ticketStatus == .ready ? .done : nil
        default:
            // Failed / Canceled: don't move the card, just badge it.
            return nil
        }
    }

    /// The status pill to render on the card, or `nil` for no pill.
    func pill(ticketStatus: Ticket.Status) -> RunPill? {
        switch state {
        case "Claimed", "Running":
            return .running
        case "Stalled":
            return .stalled
        case "Failed":
            return .failed
        case "Succeeded":
            return ticketStatus == .ready ? .awaitingMerge : nil
        default:
            return nil
        }
    }
}

/// Card pill states. Colors/labels are mapped in the view layer so this stays
/// free of SwiftUI.
enum RunPill: Equatable {
    case running
    case stalled
    case failed
    case awaitingMerge
}

/// Reads the daemon's runs-index file and projects it onto the active project.
enum RunStateStore {

    /// `~/Library/Application Support/relay-runner/orchestrator/runs.json` —
    /// matches `_data_root()` in services/orchestrator.py.
    private static var indexURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("relay-runner", isDirectory: true)
            .appendingPathComponent("orchestrator", isDirectory: true)
            .appendingPathComponent("runs.json", isDirectory: false)
    }

    private struct RunsIndex: Decodable {
        let runs: [RunState]
    }

    /// Run states for `repoPath`, keyed by ticket id. When a ticket has more
    /// than one entry (e.g. a finished run plus a fresh re-dispatch), the
    /// active one wins; otherwise the most recent (highest run_id). Returns an
    /// empty map when the file is absent or unreadable — the board then
    /// renders purely from ticket files.
    static func load(forRepo repoPath: URL) -> [String: RunState] {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RunsIndex.self, from: data) else {
            return [:]
        }
        let target = repoPath.resolvingSymlinksInPath().path
        var byTicket: [String: RunState] = [:]
        for run in decoded.runs {
            guard URL(fileURLWithPath: run.repoPath).resolvingSymlinksInPath().path == target else {
                continue
            }
            if let existing = byTicket[run.ticketId] {
                byTicket[run.ticketId] = prefer(existing, over: run)
            } else {
                byTicket[run.ticketId] = run
            }
        }
        return byTicket
    }

    /// Active runs outrank terminal ones; ties break toward the newer run_id.
    private static func prefer(_ a: RunState, over b: RunState) -> RunState {
        if a.isActive != b.isActive { return a.isActive ? a : b }
        return a.runId >= b.runId ? a : b
    }
}
