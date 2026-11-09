import SwiftUI

/// Settings has no Save button (RR-470): every control reads the live config
/// and writes each change through `AppState.saveConfig`.
@MainActor
@Observable
final class SettingsAutoSave {
    /// How long typing or a held arrow key must pause before the value saves.
    static let editPause: Duration = .milliseconds(500)

    enum Status: Hashable {
        case idle
        case saved
        case failed(String)
    }

    private(set) var status: Status = .idle
    @ObservationIgnored private let current: () -> AppConfig
    @ObservationIgnored private let save: (AppConfig) -> Error?

    init(current: @escaping () -> AppConfig, save: @escaping (AppConfig) -> Error?) {
        self.current = current
        self.save = save
    }

    /// Reads the live config and saves every write. Text fields and sliders
    /// hold their in-progress value and write it once the edit settles.
    func binding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.current()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// Applies `change` to the live config, so a save made elsewhere (the
    /// session wheel, Relay App) is never overwritten, and saves only a real change.
    func update(_ change: (inout AppConfig) -> Void) {
        let live = current()
        var next = live
        change(&next)
        guard next != live else { return }
        if let error = save(next) {
            status = .failed(error.localizedDescription)
        } else {
            status = .saved
        }
    }
}

/// A control's in-progress value, written once the edit settles: `delay`
/// after the last change, or on `flush()`. With no delay it waits for
/// `flush()`, as a slider drag does until it is released.
@MainActor
@Observable
final class SettingsDeferredEdit<Value: Equatable> {
    private(set) var value: Value?
    @ObservationIgnored private var commit: ((Value) -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func update(_ value: Value, settlingAfter delay: Duration?, commit: @escaping (Value) -> Void) {
        self.value = value
        self.commit = commit
        timer?.cancel()
        timer = nil
        guard let delay else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the pending value now.
    func flush() {
        timer?.cancel()
        timer = nil
        guard let value, let commit else { return }
        self.commit = nil
        commit(value)
        self.value = nil
    }

    /// Drops the pending value: the setting changed elsewhere, and that change wins.
    func discard() {
        timer?.cancel()
        timer = nil
        commit = nil
        if value != nil { value = nil }
    }
}
