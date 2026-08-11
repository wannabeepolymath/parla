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
        try Data(#"{"futureField":true,"cleanupModel":"m"}"#.utf8).write(to: store.url)
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

    func testLiveStreamingEnabledDefaultTrue() {
        XCTAssertTrue(Settings().liveStreamingEnabled)
    }

    func testLiveStreamingEnabledTolerantDecode() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertTrue(missing.liveStreamingEnabled)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"liveStreamingEnabled":false}"#.utf8))
        XCTAssertFalse(off.liveStreamingEnabled)
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
        var s = Settings()
        s.dictionary = ["aaaa"]
        try store.save(s)
        _ = store.load() // prime the cache

        // Identical length, written immediately: mtime and size may both be
        // unchanged, so save() must drop the cache itself.
        s.dictionary = ["bbbb"]
        try store.save(s)
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
