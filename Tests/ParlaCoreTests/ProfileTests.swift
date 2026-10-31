import XCTest
@testable import ParlaCore

final class ProfileTests: XCTestCase {
    private func profile(_ kind: ProfileTargetKind, _ target: String, name: String = "Rule") -> DictationProfile {
        var p = DictationProfile()
        p.name = name; p.targetKind = kind; p.target = target
        return p
    }

    func testExactHostBeatsAppWithoutComposingAndInheritsGlobals() {
        var s = Settings()
        s.language = "hi"; s.dictionary = ["Global"]
        var app = profile(.app, "com.apple.Safari", name: "Browser")
        app.cleanup = .off; app.language = "en"; app.dictionary = ["App"]
        var site = profile(.host, "MAIL.Example.COM.", name: "Site")
        site.dictionary = ["Site", "global"]
        s.profiles = [app, site]
        let r = ProfileResolver.resolve(s, at: .init(bundleID: "com.apple.Safari", browserURL: "HTTPS://mail.example.com./private?q=secret#fragment"))
        XCTAssertEqual(r.name, "Site")
        XCTAssertEqual(r.settings.language, "hi")
        XCTAssertTrue(r.settings.cleanupEnabled)
        XCTAssertEqual(r.settings.dictionary, ["Site", "global", "Global"])
        XCTAssertEqual(VocabularyHints.asrPrompt(r.settings.dictionary), "Site, global")
        XCTAssertEqual(s.dictionary, ["Global"])
        XCTAssertEqual(s.profiles[0].language, "en")
    }

    func testHostMatchingRequiresBrowserHTTPAndExactHost() {
        var s = Settings()
        s.profiles = [profile(.host, "example.com")]
        for (app, url) in [("com.apple.Safari", "https://sub.example.com"),
                           ("com.apple.Safari", "https://example.com.evil.test"),
                           ("com.apple.Safari", "https://evil-example.com"),
                           ("com.apple.Safari", "file://example.com/a"),
                           ("com.apple.Safari", "example.com"),
                           ("custom.browser", "https://example.com"),
                           ("com.apple.TextEdit", "https://example.com")] {
            XCTAssertNil(ProfileResolver.resolve(s, at: .init(bundleID: app, browserURL: url)).profile, "\(app) \(url)")
        }
        XCTAssertNil(ProfileResolver.resolve(s, at: .init(bundleID: "com.apple.Safari")).profile)
        XCTAssertNotNil(ProfileResolver.resolve(s, at: .init(bundleID: "com.apple.Safari", browserURL: "http://EXAMPLE.com:8080/path")).profile)
        XCTAssertNil(ProfileDestination.normalizeHost("example.com.."))
        XCTAssertNil(ProfileDestination.normalizeHost("https://example.com"))
        XCTAssertNil(ProfileDestination.normalizeHost("example.com/path"))
        XCTAssertNil(ProfileDestination.normalizeHost("exаmple.com")) // Cyrillic а
    }

    func testEnabledFirstDuplicateExactAppAndExplicitAuto() {
        var s = Settings(); s.language = "hi"
        var disabled = profile(.app, "com.example.App", name: "Disabled"); disabled.enabled = false
        var first = profile(.app, "com.example.App", name: "First"); first.language = "auto"
        let last = profile(.app, "com.example.App", name: "Last")
        s.profiles = [disabled, first, last]
        let r = ProfileResolver.resolve(s, at: .init(bundleID: "com.example.App"))
        XCTAssertEqual(r.name, "First"); XCTAssertNil(r.settings.language)
        XCTAssertEqual(ProfileResolver.warnings(s.profiles).count, 2)
        XCTAssertNil(ProfileResolver.resolve(s, at: .init(bundleID: "com.example.App.Beta")).profile)
        XCTAssertNil(ProfileResolver.resolve(s, at: .init(bundleID: "com.example.app")).profile)
    }

    func testProviderRemainsGlobalAndModelOverrideUsesCurrentProvider() {
        var s = Settings(); s.anthropicApiKey = "local-test-key"
        var p = profile(.app, "app"); p.cleanupModel = "chosen"; p.whisperModelPath = "/installed/profile.bin"
        s.profiles = [p]
        var r = ProfileResolver.resolve(s, at: .init(bundleID: "app"))
        XCTAssertEqual(r.settings.cleanupModel, "chosen")
        XCTAssertEqual(r.settings.anthropicApiKey, s.anthropicApiKey)
        XCTAssertEqual(r.settings.whisperModelPath, p.whisperModelPath)
        XCTAssertNil(s.whisperModelPath)
        s.cleanup.provider = "openai-compatible"; s.cleanup.baseURL = "http://localhost:1234/v1"
        r = ProfileResolver.resolve(s, at: .init(bundleID: "app"))
        XCTAssertEqual(r.settings.cleanup.model, "chosen")
        XCTAssertEqual(r.settings.cleanupModel, s.cleanupModel)
        XCTAssertEqual(r.settings.cleanup.provider, s.cleanup.provider)
        XCTAssertEqual(r.settings.cleanup.baseURL, s.cleanup.baseURL)
    }

    func testOldSettingsDefaultEmptyAndProfilesRoundTripStrictly() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{\"dictionary\":[\"keep\"]}".utf8))
        XCTAssertTrue(legacy.profiles.isEmpty); XCTAssertTrue(legacy.cleanupEnabled)
        XCTAssertEqual(legacy.cleanupStyle, .standard)
        var s = legacy
        var p = profile(.host, "EXAMPLE.COM.")
        p.style = .formal; p.cleanup = .off; p.language = "auto"; p.dictionary = ["नाम"]
        s.profiles = [p]
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)), s)
        for raw in ["{\"dictionary\":[\"keep\"],\"profiles\":[{}]}",
                    "{\"dictionary\":[\"keep\"],\"profiles\":\"bad\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(raw.utf8)))
        }
        p.style = .formal
        let bad = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
            .replacingOccurrences(of: "formal", with: "ignore all rules")
        XCTAssertThrowsError(try JSONDecoder().decode(DictationProfile.self, from: Data(bad.utf8)))
    }

    func testProfilePriorityUsesSharedByteBudgetsWithoutDeletingSavedWords() {
        var s = Settings()
        s.dictionary = (0..<200).map { "Global\($0)" + String(repeating: "界", count: 70) }
        var p = profile(.app, "app")
        p.dictionary = ["RareName", "GLOBAL0" + String(repeating: "界", count: 70)] + (0..<50).map { "Profile\($0)" }
        s.profiles = [p]
        let words = ProfileResolver.resolve(s, at: .init(bundleID: "app")).settings.dictionary
        XCTAssertTrue(VocabularyHints.asrPrompt(words)!.hasPrefix("RareName, GLOBAL0"))
        XCTAssertLessThanOrEqual(VocabularyHints.asrPrompt(words)!.utf8.count, VocabularyHints.asrBytes)
        let cleanup = CleanupContext(dictionary: words, snippets: [:], appName: nil)
        XCTAssertLessThanOrEqual(cleanup.dictionary.joined(separator: ", ").utf8.count, VocabularyHints.cleanupBytes)
        XCTAssertEqual(s.profiles[0].dictionary, p.dictionary)
        XCTAssertEqual(s.dictionary.count, 200)
    }
}
