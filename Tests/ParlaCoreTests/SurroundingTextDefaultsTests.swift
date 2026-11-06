import XCTest
@testable import ParlaCore

final class SurroundingTextDefaultsTests: XCTestCase {
    func testLocalDefaultCloudConsentAndSavedOptOut() throws {
        XCTAssertTrue(Settings().cleanup.localSurroundingTextEnabled)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{\"cleanup\":{\"provider\":\"apple-intelligence\"}}".utf8))
        XCTAssertTrue(old.cleanup.localSurroundingTextEnabled)
        let d = try B26CoreDocument(provider: "apple-intelligence")
        let settings = d.store.load(), id = UUID()
        let local = try XCTUnwrap(d.store.capturePhysicalSurroundingTextGrant(settings: settings, destination: .init(bundleID: "test.editor"))).bound(to: id)
        XCTAssertNoThrow(try d.store.withSurroundingTextGrant(local, operationID: id) {})
        var disabled = settings; disabled.cleanup.localSurroundingTextEnabled = false
        d.store.observeSurroundingTextDraft(from: settings, to: disabled)
        XCTAssertNil(d.store.capturePhysicalSurroundingTextGrant(settings: settings, destination: .init(bundleID: "test.editor")), "Opt-out intent must close new captures before a save, including failed saves")
        d.store.observeSurroundingTextDraft(from: disabled, to: settings)
        XCTAssertNotNil(d.store.capturePhysicalSurroundingTextGrant(settings: settings, destination: .init(bundleID: "test.editor")))
        try d.store.save(disabled, replacing: settings)
        XCTAssertFalse(d.store.load().cleanup.localSurroundingTextEnabled)
        XCTAssertNil(d.store.capturePhysicalSurroundingTextGrant(settings: d.store.load(), destination: .init(bundleID: "test.editor")))
        XCTAssertThrowsError(try d.store.withSurroundingTextGrant(local, operationID: id) {})
        let cloud = try B26CoreDocument()
        XCTAssertNil(cloud.store.capturePhysicalSurroundingTextGrant(settings: cloud.store.load(), destination: .init(bundleID: "test.editor")))
        let reviewed = try cloud.enable()
        XCTAssertNotNil(cloud.store.capturePhysicalSurroundingTextGrant(settings: reviewed, destination: .init(bundleID: "test.editor")))
        XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(cloud.backend.reads, 0)
    }
    func testLocalGlobalCaptureGrantCannotCrossProviderOrRevocation() throws {
        let d = try B26CoreDocument(provider: "apple-intelligence")
        try d.patch {
            $0["profiles"] = []
            $0["surroundingTextContext"] = ["future-cloud-schema": true]
        }
        let initial = d.store.load(), id = UUID()
        let grant = try XCTUnwrap(d.store.capturePhysicalSurroundingTextGrant(settings: initial, destination: .init(bundleID: "test.editor"))).bound(to: id)
        XCTAssertNoThrow(try d.store.withSurroundingTextGrant(grant, operationID: id) {})
        d.store.revokeSurroundingTextContext()
        XCTAssertThrowsError(try d.store.withSurroundingTextGrant(grant, operationID: id) {})
        XCTAssertNil(d.store.capturePhysicalSurroundingTextGrant(settings: initial, destination: .init(bundleID: "test.editor"), live: true))
        let fresh = try XCTUnwrap(d.store.capturePhysicalSurroundingTextGrant(settings: initial, destination: .init(bundleID: "test.editor"))).bound(to: id)
        XCTAssertNoThrow(try d.store.withSurroundingTextGrant(fresh, operationID: id) {})
        var cloud = initial; cloud.cleanup.provider = "openai-compatible"
        try d.store.save(cloud, replacing: initial)
        XCTAssertThrowsError(try d.store.withSurroundingTextGrant(fresh, operationID: id) {})
        XCTAssertNil(d.store.capturePhysicalSurroundingTextGrant(settings: d.store.load(), destination: .init(bundleID: "test.editor")))
    }
}
