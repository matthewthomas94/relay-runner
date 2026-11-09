import XCTest
@testable import relay_runner

/// Stands in for `AppState`: `saveConfig` persists and, while services run,
/// sends exactly one bridge `reload` per call.
@MainActor
private final class FakeConfigStore {
    var config = AppConfig()
    var saves: [AppConfig] = []
    var failure: Error?
    var bridgeReloads: Int { saves.count }

    lazy var autoSave = SettingsAutoSave(
        current: { [unowned self] in self.config },
        save: { [unowned self] next in
            self.config = next
            self.saves.append(next)
            return self.failure
        }
    )
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

@MainActor
final class SettingsAutoSaveTests: XCTestCase {
    func testEachControlChangeSavesOnceAndAnUnchangedValueDoesNotSave() {
        let store = FakeConfigStore()
        let voice = store.autoSave.binding(\.tts.voice)

        voice.wrappedValue = "bf_isabella"
        XCTAssertEqual(store.saves.count, 1)
        XCTAssertEqual(store.config.tts.voice, "bf_isabella")
        XCTAssertEqual(store.autoSave.status, .saved)

        voice.wrappedValue = "bf_isabella"
        XCTAssertEqual(store.saves.count, 1, "Choosing the current value is not a change")
    }

    func testSaveFailureIsReportedAndTheNextSuccessClearsIt() {
        let store = FakeConfigStore()
        store.failure = DiskFull()
        store.autoSave.binding(\.awareness.live_captions).wrappedValue.toggle()
        XCTAssertEqual(store.autoSave.status, .failed("The disk is full."))

        store.failure = nil
        store.autoSave.binding(\.awareness.live_captions).wrappedValue.toggle()
        XCTAssertEqual(store.autoSave.status, .saved)
    }

    func testTypingAMultiCharacterValueSavesAndReloadsOnce() async throws {
        let store = FakeConfigStore()
        let folder = store.autoSave.binding(\.general.working_directory)
        let edit = SettingsDeferredEdit<String>()

        for typed in ["~", "~/", "~/d", "~/de", "~/dev"] {
            edit.update(typed, settlingAfter: .milliseconds(50)) { folder.wrappedValue = $0 }
        }
        XCTAssertEqual(store.saves.count, 0, "Nothing saves while typing")
        XCTAssertEqual(edit.value, "~/dev")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.saves.count, 1)
        XCTAssertEqual(store.bridgeReloads, 1)
        XCTAssertEqual(store.config.general.working_directory, "~/dev")
        XCTAssertNil(edit.value)
    }

    func testFocusLeavingSavesAtOnceWithoutASecondSaveLater() async throws {
        let store = FakeConfigStore()
        let folder = store.autoSave.binding(\.general.working_directory)
        let edit = SettingsDeferredEdit<String>()

        edit.update("~/src", settlingAfter: .milliseconds(50)) { folder.wrappedValue = $0 }
        edit.flush()
        XCTAssertEqual(store.saves.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.saves.count, 1)
    }

    func testSliderDragSavesOnceOnRelease() {
        let store = FakeConfigStore()
        let rate = store.autoSave.binding(\.tts.rate)
        let drag = SettingsDeferredEdit<Double>()

        for value in [1.4, 1.5, 1.6, 1.7] {
            drag.update(value, settlingAfter: nil) { rate.wrappedValue = $0 }
        }
        XCTAssertEqual(store.saves.count, 0, "Nothing saves mid-drag")
        drag.flush()
        XCTAssertEqual(store.saves.count, 1)
        XCTAssertEqual(store.config.tts.rate, 1.7)
    }

    func testAChangeMadeElsewhereReplacesAPendingEdit() {
        let store = FakeConfigStore()
        let folder = store.autoSave.binding(\.general.working_directory)
        let edit = SettingsDeferredEdit<String>()

        edit.update("~/typed", settlingAfter: nil) { folder.wrappedValue = $0 }
        edit.discard()
        edit.flush()
        XCTAssertEqual(store.saves.count, 0)
        XCTAssertNil(edit.value)
    }

    func testSessionWheelSavesAreNeverOverwrittenBySettings() {
        let store = FakeConfigStore()
        let rate = store.autoSave.binding(\.tts.rate)
        let folder = store.autoSave.binding(\.general.working_directory)
        let edit = SettingsDeferredEdit<String>()
        edit.update("~/dev", settlingAfter: nil) { folder.wrappedValue = $0 }

        // The wheel saves intensity and auto-play while Settings is open.
        store.config.awareness.glow_intensity = 0.35
        store.config.tts.auto_play.toggle()
        let wheelAutoPlay = store.config.tts.auto_play

        rate.wrappedValue = 1.8
        edit.flush()
        XCTAssertEqual(store.saves.count, 2)
        XCTAssertEqual(store.config.awareness.glow_intensity, 0.35)
        XCTAssertEqual(store.config.tts.auto_play, wheelAutoPlay)
        XCTAssertEqual(store.config.tts.rate, 1.8)
        XCTAssertEqual(store.config.general.working_directory, "~/dev")
        XCTAssertEqual(store.autoSave.binding(\.awareness.glow_intensity).wrappedValue, 0.35,
                       "Settings shows the wheel's value at once")
    }

    func testRestartingSTTSettingSavesOnceThroughTheRestartDecision() {
        let store = FakeConfigStore()
        let before = store.config.stt
        store.autoSave.binding(\.stt.vad_sensitivity).wrappedValue = "high"
        XCTAssertEqual(store.saves.count, 1)
        // `persistConfig` hands this change to `restartSTTAfterCurrentRecording`, unchanged.
        XCTAssertTrue(AppState.sttSettingsRequireRestart(old: before, new: store.config.stt))
    }
}
