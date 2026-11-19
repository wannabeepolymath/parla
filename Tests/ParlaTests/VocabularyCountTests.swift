import XCTest
@testable import Parla
@testable import ParlaCore

/// The Hub's retained-word count must follow the loaded model, not just its capacity:
/// every Whisper model reports the same capacity but tokenizes differently.
final class VocabularyCountTests: XCTestCase {
    @MainActor func testCountIsRecomputedWhenTheModelChangesAtTheSameCapacity() throws {
        let root = URL(fileURLWithPath: "/private/tmp/parla-vocab-count-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = HubModel(store: SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore()),
                           history: HistoryStore(url: root.appendingPathComponent("history.json")),
                           recordings: RecordingStore(directory: root.appendingPathComponent("audio")))
        hub.words = ["alpha", "beta", "gamma"].map { HubModel.WordRow(text: $0) }
        let cheap = NSObject(), dear = NSObject()
        var resident: (budget: PromptBudget, model: ObjectIdentifier)?
        hub.vocabularyBudget = { resident }

        resident = (PromptBudget(capacity: 12, count: { _ in 1 }), ObjectIdentifier(cheap))
        XCTAssertEqual(hub.retainedVocabularyCount().count, 3)
        resident = (PromptBudget(capacity: 12, count: { $0.utf8.count }), ObjectIdentifier(dear))
        XCTAssertEqual(hub.retainedVocabularyCount().count, 2, "same capacity, different tokenizer")
        resident = nil
        XCTAssertFalse(hub.retainedVocabularyCount().exact)
    }
}
