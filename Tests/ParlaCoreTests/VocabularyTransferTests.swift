import XCTest
@testable import ParlaCore

final class VocabularyTransferTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-vocabulary-tests-\(UUID().uuidString)")
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recordFixture("created")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try recordFixture("removed")
    }

    private func recordFixture(_ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(directory.path)\n".utf8))
    }

    private func original() -> Settings {
        var s = Settings()
        s.dictionary = ["Café", "saved"]
        s.snippets = ["address": "old"]
        s.replacements = [.init(source: "cat", replacement: "dog")]
        s.anthropicApiKey = "dummy-anthropic-secret"
        s.cleanup.apiKey = "dummy-other-secret"
        s.cleanup.baseURL = "https://dummy.invalid"
        s.whisperModelPath = "/dummy/model.bin"
        s.language = "hi"
        s.historyEnabled = false
        return s
    }

    private func incoming() throws -> Data {
        var s = Settings()
        s.dictionary = ["Café", " new\nword ", "NEW word"]
        s.snippets = ["address": "new", "unicode": "東京\n$1\\literal"]
        s.replacements = [.init(source: "cat", replacement: "new"), .init(source: "added", replacement: "value")]
        return try VocabularyDocument(settings: s).encoded()
    }

    func testCredentialFreeTypedExportAndConflictPreviewMerge() throws {
        let old = original()
        try store.saveTestSettings(old)
        let exported = try VocabularyDocument(settings: old).encoded()
        let text = String(decoding: exported, as: UTF8.self)
        for secret in ["dummy-anthropic-secret", "dummy-other-secret", "baseURL", "hotkeys", "cleanupModel", "whisperModelPath"] {
            XCTAssertFalse(text.contains(secret))
        }
        let preview = try VocabularyImportPreview(data: incoming(), settings: old)
        XCTAssertEqual(preview.duplicateWords, 1)
        XCTAssertEqual(preview.conflicts, 3)
        XCTAssertEqual(preview.incoming.words, ["Café", "new word"])
        XCTAssertNil(try store.importVocabulary(preview, mode: .merge))
        let merged = store.load()
        XCTAssertEqual(merged.dictionary, ["Café", "saved", "new word"])
        XCTAssertEqual(merged.snippets["address"], "old")
        XCTAssertEqual(merged.snippets["unicode"], "東京\n$1\\literal")
        XCTAssertEqual(merged.replacements, old.replacements + [.init(source: "added", replacement: "value")])
        XCTAssertEqual(VocabularyDocument(settings: merged).applying(to: withoutLegacy(old)), merged)
        XCTAssertNil(merged.anthropicApiKey); XCTAssertEqual(testStoredKey(store.credentials, .anthropic), old.anthropicApiKey)
        XCTAssertEqual(merged.cleanup, withoutLegacy(old).cleanup); XCTAssertEqual(testStoredKey(store.credentials, try .compatible(old.cleanup.baseURL)), old.cleanup.apiKey)
        XCTAssertEqual(merged.hotkeys, old.hotkeys)
    }

    func testReplaceBacksUpOnlyVocabularyAndPreservesNewerUnrelatedSettings() throws {
        var old = original()
        try store.saveTestSettings(old)
        let preview = try VocabularyImportPreview(data: incoming(), settings: old)
        old.cleanupModel = "changed-after-preview"
        old.anthropicApiKey = "dummy-new-key"
        try store.saveTestSettings(old)
        let backup = try XCTUnwrap(store.importVocabulary(preview, mode: .replace))
        let data = try Data(contentsOf: backup)
        XCTAssertEqual(try VocabularyDocument.decode(data), preview.original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("dummy"))
        let result = store.load()
        XCTAssertEqual(VocabularyDocument(settings: result), preview.incoming)
        XCTAssertEqual(result, preview.incoming.applying(to: withoutLegacy(old)))
    }

    func testStalePreviewAndEmptyReplaceNeverEditStore() throws {
        var old = original()
        try store.saveTestSettings(old)
        let preview = try VocabularyImportPreview(data: incoming(), settings: old)
        old.dictionary.append("newer manual edit")
        try store.saveTestSettings(old)
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.importVocabulary(preview, mode: .replace))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        let empty = try VocabularyImportPreview(data: VocabularyDocument(settings: Settings()).encoded(), settings: old)
        XCTAssertThrowsError(try store.importVocabulary(empty, mode: .replace))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocabulary-backups").path))
    }

    func testInvalidUnsupportedOversizedAndSettingsDumpRejectedWithoutEdits() throws {
        let old = original()
        try store.saveTestSettings(old)
        let before = try Data(contentsOf: store.url)
        let valid = try incoming()
        let string = String(decoding: valid, as: UTF8.self)
        let invalid: [Data] = [Data("bad".utf8), Data(string.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 999").utf8),
                               Data(repeating: 0, count: VocabularyDocument.maxFileBytes + 1),
                               try JSONEncoder().encode(old)]
        for data in invalid {
            XCTAssertThrowsError(try VocabularyImportPreview(data: data, settings: old))
        }
        var huge = Settings()
        huge.dictionary = [String(repeating: "界", count: 100)]
        // Raw encoder deliberately bypasses export validation to exercise import.
        XCTAssertThrowsError(try VocabularyImportPreview(data: JSONEncoder().encode(VocabularyDocument(settings: huge)), settings: old))
        var duplicate = Settings()
        duplicate.replacements = [.init(source: "a", replacement: "b"), .init(source: "a", replacement: "c")]
        XCTAssertThrowsError(try VocabularyImportPreview(data: JSONEncoder().encode(VocabularyDocument(settings: duplicate)), settings: old))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }

    func testBackupFailureAndSettingsLoadSaveFailuresAreNonDestructive() throws {
        let old = original()
        try store.saveTestSettings(old)
        let preview = try VocabularyImportPreview(data: incoming(), settings: old)
        let before = try Data(contentsOf: store.url)
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file prevents backup directory".utf8).write(to: blocked)
        XCTAssertThrowsError(try store.importVocabulary(preview, mode: .replace, backupDirectory: blocked))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        try Data("invalid settings".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.importVocabulary(preview, mode: .merge))
        XCTAssertEqual(try Data(contentsOf: store.url), Data("invalid settings".utf8))
        let unavailable = SettingsStore(url: blocked.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        let emptyPreview = try VocabularyImportPreview(data: incoming(), settings: Settings())
        XCTAssertThrowsError(try unavailable.importVocabulary(emptyPreview, mode: .merge))
        XCTAssertEqual(try Data(contentsOf: blocked), Data("file prevents backup directory".utf8))
    }
}
