import XCTest
@testable import ParlaCore

/// The whole first-run gate is one asymmetric default: fresh install ⇒ onboard,
/// existing settings.json ⇒ never onboard. Both halves get a test because
/// getting the second one wrong interrupts the only user Parla has.
final class OnboardingFlagTests: XCTestCase {
    private func store() -> SettingsStore {
        SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json"))
    }

    func testFreshInstallStartsIncomplete() {
        XCTAssertFalse(store().load().onboardingCompleted)
    }

    func testExistingSettingsFileCountsAsCompleted() throws {
        let s = store()
        try FileManager.default.createDirectory(
            at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cleanupModel":"claude-haiku-4-5"}"#.utf8).write(to: s.url)
        XCTAssertTrue(s.load().onboardingCompleted)
    }

    func testExplicitFalseSurvivesAReload() throws {
        let s = store()
        var settings = Settings()
        settings.onboardingCompleted = false
        try s.save(settings)
        XCTAssertFalse(s.load().onboardingCompleted)
    }
}
