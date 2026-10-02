import ParlaCore
import XCTest
@testable import Parla

final class HubModelTests: XCTestCase {
    /// A debounced save that has already run must not run again at the next
    /// refresh(): the replay wrote the Hub's copy over whatever had reached
    /// settings.json since — a finished download's model path — and the app
    /// switched straight back to the old model.
    func testAFiredSaveIsNotReplayedOverALaterWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        let hub = HubModel(store: store, history: HistoryStore(url: dir.appendingPathComponent("history.json")))
        hub.refresh()
        hub.settings.showHudAlways.toggle()             // a Hub edit, saved on a 0.5 s debounce…
        RunLoop.main.run(until: Date() + 0.8)           // …which fires
        XCTAssertFalse(store.load().showHudAlways)

        var s = store.load()                            // finishDownload's write
        s.whisperModelPath = "/models/new.bin"
        try store.save(s)
        hub.refresh()

        XCTAssertEqual(store.load().whisperModelPath, "/models/new.bin")
        XCTAssertEqual(hub.settings.whisperModelPath, "/models/new.bin")
    }
}
