import XCTest
@testable import ParlaCore

final class SettingsTests: XCTestCase {
    func tempStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsStore(url: dir.appendingPathComponent("settings.json"))
    }

    func testDefaultsWhenFileMissing() {
        let store = tempStore()
        let s = store.load()
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")
        XCTAssertTrue(s.dictionary.isEmpty)
        XCTAssertTrue(s.snippets.isEmpty)
        XCTAssertNil(store.lastError) // missing file is fine, not an error
    }

    func testRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes", "Daksh"]
        s.snippets = ["insert my calendar link": "https://cal.com/daksh"]
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertNil(store.lastError)
    }

    func testCorruptFileFallsBackToDefaultsAndReportsError() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.lastError!.contains("\n")) // trimmed to one line for menu display
    }

    func testDirectoryFallsBackToDefaultsAndReportsError() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
    }

    func testErrorClearsOnNextGoodLoad() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        _ = store.load()
        XCTAssertNotNil(store.lastError)
        try store.save(Settings())
        _ = store.load()
        XCTAssertNil(store.lastError)
    }

    func testPartialFileDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dictionary":["Kubernetes"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.dictionary, ["Kubernetes"])
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")  // default survives
        XCTAssertEqual(s.cleanup, CleanupSettings())          // default block
    }

    func testUnknownKeysIgnored() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `liveStreamingEnabled` is a *retired* key, not a hypothetical one: it
        // sits in every settings.json written before it was deleted, and those
        // files must keep decoding.
        try Data(#"{"futureField":true,"liveStreamingEnabled":false,"cleanupModel":"m"}"#.utf8)
            .write(to: store.url)
        XCTAssertEqual(store.load().cleanupModel, "m")
    }

    func testPartialCleanupBlockDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cleanup":{"model":"m"},"dictionary":["X"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.cleanup.provider, "anthropic")
        XCTAssertEqual(s.cleanup.model, "m")
        XCTAssertEqual(s.dictionary, ["X"])
    }

    func testInputDeviceUIDDefaultNil() {
        XCTAssertNil(Settings().inputDeviceUID)
    }

    func testInputDeviceUIDTolerantDecodeAndRoundTrip() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertNil(missing.inputDeviceUID)
        let store = tempStore()
        var s = Settings()
        s.inputDeviceUID = "AppleUSBAudioEngine:Blue:Yeti:1"
        try store.save(s)
        XCTAssertEqual(store.load().inputDeviceUID, s.inputDeviceUID)
    }

    func testCleanupBlockRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "https://api.groq.com/openai/v1"
        s.cleanup.model = "llama-3.3-70b-versatile"
        s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    // load() is on the fn-down keypress path, so it caches. These cover the
    // three ways that cache has to stay honest.

    func testLoadPicksUpAnExternalEdit() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes"]
        try store.save(s)
        XCTAssertEqual(store.load().dictionary, ["Kubernetes"])

        // Same length, so a size-only check would miss it; the editor case.
        try Data(#"{"dictionary":["Kubernetes!"]}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load().dictionary, ["Kubernetes!"])
    }

    func testSaveInvalidatesEvenWhenStampCouldNotChange() throws {
        let store = tempStore()
        // An atomic rewrite of the same length does move the mtime in practice, so
        // simply saving twice never reaches save()'s own invalidation — the stamp
        // check gets there first. Pin the mtime to a whole second (which survives
        // the filesystem round-trip exactly) on both sides instead, so the stamp
        // is provably identical and only save() dropping the cache can save us.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        var s = Settings()
        s.dictionary = ["aaaa"]
        try store.save(s)
        try FileManager.default.setAttributes([.modificationDate: frozen],
                                              ofItemAtPath: store.url.path)
        let before = try FileManager.default.attributesOfItem(atPath: store.url.path)
        _ = store.load() // prime the cache against that stamp

        s.dictionary = ["bbbb"] // identical length
        try store.save(s)
        try FileManager.default.setAttributes([.modificationDate: frozen],
                                              ofItemAtPath: store.url.path)
        let after = try FileManager.default.attributesOfItem(atPath: store.url.path)
        // If either half of the stamp moved, this test is back to proving nothing,
        // so fail loudly rather than pass for the wrong reason.
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
        XCTAssertEqual(after[.size] as? Int, before[.size] as? Int)
        XCTAssertEqual(store.load().dictionary, ["bbbb"])
    }

    func testLastErrorSurvivesACacheHit() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
        // Second call is a cache hit — the ⚠️ menu state must not clear itself.
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
    }

    func testAppearingFileInvalidatesTheNoFileCache() throws {
        let store = tempStore()
        try? FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(store.load(), Settings()) // caches "no file"
        var s = Settings()
        s.dictionary = ["later"]
        try store.save(s)
        XCTAssertEqual(store.load().dictionary, ["later"])
    }
}
