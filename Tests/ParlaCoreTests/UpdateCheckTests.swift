import XCTest
@testable import ParlaCore

final class UpdateCheckTests: XCTestCase {
    func testStripsLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "v0.2.0", current: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "v0.1.0", current: "v0.1.0"))
    }

    func testNumericNotStringCompare() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "0.10.0", current: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.9.0", current: "0.10.0"))
    }

    func testUnequalComponentCounts() {
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.1", current: "0.1.0")) // 0.1 == 0.1.0
        XCTAssertTrue(UpdateCheck.isNewer(remote: "0.1.1", current: "0.1"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.1", current: "0.1.1"))
    }

    func testSameVersionNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(remote: "1.2.3", current: "1.2.3"))
    }

    func testGarbageTagsDoNotCrash() {
        // Non-numeric components parse as 0 rather than crashing: "1.2.0-beta"
        // and "1.2.1-rc1" both reduce to 1.2.0, so neither beats 1.2.0.
        XCTAssertFalse(UpdateCheck.isNewer(remote: "v1.2.0-beta", current: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "1.2.1-rc1", current: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "nightly", current: "0.1.0"))
        // A prerelease suffix on an already-bumped component still detects newer.
        XCTAssertTrue(UpdateCheck.isNewer(remote: "1.3.0-rc1", current: "1.2.0"))
    }

    func testDecodeSampleReleasePayload() throws {
        let json = Data(#"""
        {"tag_name":"v0.2.0","html_url":"https://github.com/wannabeepolymath/parla/releases/tag/v0.2.0","name":"0.2.0","extra":true}
        """#.utf8)
        let release = try JSONDecoder().decode(UpdateCheck.Release.self, from: json)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/wannabeepolymath/parla/releases/tag/v0.2.0")
    }

    func testDecodeMissingHtmlURL() throws {
        let release = try JSONDecoder().decode(UpdateCheck.Release.self, from: Data(#"{"tag_name":"v0.3.0"}"#.utf8))
        XCTAssertEqual(release.tagName, "v0.3.0")
        XCTAssertNil(release.htmlURL)
    }

    // MARK: - Assets

    private func release(_ tag: String, assets: [String]) -> Data {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.invalid/\#($0)"}"# }
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://example.invalid/tag","assets":[\#(list.joined(separator: ","))]}"#.utf8)
    }

    func testPicksTheExactlyNamedDMG() throws {
        let data = release("v0.6.0", assets: ["Parla-0.6.0.dmg.sha256", "parla-0.6.0.dmg", "Parla-0.6.dmg", "Parla-0.6.0.dmg"])
        let decoded = try JSONDecoder().decode(UpdateCheck.Release.self, from: data)
        XCTAssertEqual(UpdateCheck.dmgURL(in: decoded), URL(string: "https://example.invalid/Parla-0.6.0.dmg"))
    }

    func testNearMissesAndMissingAssetsMeanNoDMG() throws {
        let nearMisses = release("v0.6.0", assets: ["Parla-v0.6.0.dmg", "Parla-0.6.0.zip", "Parla-0.6.0.dmg.sig", "Parla-0.5.0.dmg"])
        XCTAssertNil(UpdateCheck.dmgURL(in: try JSONDecoder().decode(UpdateCheck.Release.self, from: nearMisses)))
        let noAssets = try JSONDecoder().decode(UpdateCheck.Release.self, from: Data(#"{"tag_name":"v0.6.0"}"#.utf8))
        XCTAssertNil(UpdateCheck.dmgURL(in: noAssets))
    }

    // MARK: - Outcomes (no network: the fetch is injected)

    // One fixed suite, wiped around each test: a per-test UUID suite left a
    // plist behind in ~/Library/Preferences on every run (wiping doesn't delete it).
    private static let suite = "ParlaCoreTests.UpdateCheck"
    private let defaults = UserDefaults(suiteName: UpdateCheckTests.suite)!

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }
    private var requested: [URL] = []

    private func check(force: Bool = false, status: Int = 200, body: Data? = nil,
                       now: Date = Date()) async -> UpdateCheck.Outcome {
        let payload = body ?? release("v0.6.0", assets: ["Parla-0.6.0.dmg"])
        return await UpdateCheck.check(currentVersion: "0.5.0", force: force, defaults: defaults, now: now) { request in
            self.requested.append(request.url!)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testOutcomesAreDistinct() async {
        let available = await check()
        XCTAssertEqual(available, .available(UpdateCheck.Update(
            version: "v0.6.0", url: URL(string: "https://example.invalid/tag")!,
            dmgURL: URL(string: "https://example.invalid/Parla-0.6.0.dmg"))))
        let upToDate = await check(force: true, body: release("v0.5.0", assets: []))
        XCTAssertEqual(upToDate, .upToDate)
        let serverError = await check(force: true, status: 500)
        XCTAssertEqual(serverError, .failed)
        let garbage = await check(force: true, body: Data("not json".utf8))
        XCTAssertEqual(garbage, .failed)
        let throttled = await check()
        XCTAssertEqual(throttled, .throttled)
        let unbundled = await UpdateCheck.check(currentVersion: nil, force: true, defaults: defaults) { _ in
            XCTFail("an unbundled build must not fetch"); throw URLError(.cancelled)
        }
        XCTAssertEqual(unbundled, .failed)
    }

    func testForceBypassesTheThrottleTheScheduledCheckObeys() async {
        let start = Date()
        _ = await check(now: start)
        let scheduled = await check(now: start + 60 * 60)
        XCTAssertEqual(scheduled, .throttled)
        XCTAssertEqual(requested.count, 1)
        guard case .available = await check(force: true, now: start + 60 * 60) else { return XCTFail("forced check was throttled") }
        XCTAssertEqual(requested.count, 2)
        guard case .available = await check(now: start + 60 * 60 + 24 * 60 * 60) else { return XCTFail("due check was throttled") }
    }

    func testOnlyASuccessfulFetchStampsTheThrottle() async {
        _ = await check(status: 503)
        guard case .available = await check() else { return XCTFail("a failed fetch started the 24 h throttle") }
    }

    func testFeedURLOverrideIsHonored() async {
        defaults.set("https://feed.invalid/latest.json", forKey: UpdateCheck.feedURLKey)
        _ = await check()
        XCTAssertEqual(requested, [URL(string: "https://feed.invalid/latest.json")!])
        defaults.removeObject(forKey: UpdateCheck.feedURLKey)
        _ = await check(force: true)
        XCTAssertEqual(requested.last, UpdateCheck.latestURL)
    }
}
