import XCTest
@testable import ParlaCore

final class PendingAudioDisposalTests: XCTestCase {
    private var root: URL!
    private let samples = (0..<8000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave3b-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recordTestFixture(root, "created")
    }
    override func tearDownWithError() throws {
        // This unique directory was created by this test, never shared or launched.
        XCTAssertTrue(root.lastPathComponent.hasPrefix("parla-wave3b-audio-"))
        try FileManager.default.removeItem(at: root)
        try recordTestFixture(root, "removed")
    }
    func testExplicitDiscardRemovesOnlyOwnedFailedAudioAndSidecar() throws {
        let store = RecordingStore(directory: root, keepAll: true)
        let owned = try XCTUnwrap(store.stash(samples))
        let authority = try XCTUnwrap(store.captureDisposal(for: owned))
        let unrelated = try XCTUnwrap(store.stash(samples))
        store.resolve(unrelated, transcript: nil, secure: false)
        store.resolve(owned, transcript: nil, secure: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path), "nil resolve deliberately retains failed audio")
        try "sidecar".write(to: owned.deletingPathExtension().appendingPathExtension("hyp.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.discard(authority)); XCTAssertTrue(store.discard(authority))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.deletingPathExtension().appendingPathExtension("hyp.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertNil(store.captureDisposal(for: unrelated), "recovery files do not confer capture disposal authority")
    }
    func testDiscardAfterCorpusResolutionDeletesWAVAndHypothesis() throws {
        let store = RecordingStore(directory: root, keepAll: true)
        let url = try XCTUnwrap(store.stash(samples)), authority = try XCTUnwrap(store.captureDisposal(for: url))
        store.resolve(url, transcript: "recognized", secure: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.discard(authority)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testRetentionOffAndFailedStashHaveNoDiscardAuthorityAndTruthfulFailure() throws {
        let store = RecordingStore(directory: root, keepAll: true)
        var settings = Settings(); settings.recoveryAudioEnabled = false; store.configure(settings: settings, error: nil)
        XCTAssertNil(store.stash(samples)); XCTAssertNil(store.captureDisposal(for: nil))
        let failed = RecordingStore(directory: root, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertNil(failed.stash(samples)); XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testDisposalFailureReleasesOwnershipAndReportsRemainingAudio() throws {
        var refuse = false
        let store = RecordingStore(directory: root, keepAll: true, remover: { url in
            if refuse { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let url = try XCTUnwrap(store.stash(samples)), authority = try XCTUnwrap(store.captureDisposal(for: url))
        refuse = true
        XCTAssertFalse(store.discard(authority)); XCTAssertNotNil(store.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        refuse = false
        XCTAssertTrue(store.delete(url))
    }
    func testSecureRefusalStillPurgesCorpusAndDefaultSuccessfulDisposalIsIdempotent() throws {
        for keepAll in [false, true] {
            let store = RecordingStore(directory: root, keepAll: keepAll)
            let url = try XCTUnwrap(store.stash(samples)), authority = try XCTUnwrap(store.captureDisposal(for: url))
            store.resolve(url, transcript: "recognized", secure: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(store.discard(authority))
        }
    }
    func testReplacedRecordingAndIndependentLeaseCannotBeDeletedByOldCapture() throws {
        let store = RecordingStore(directory: root, keepAll: false)
        let url = try XCTUnwrap(store.stash(samples)), authority = try XCTUnwrap(store.captureDisposal(for: url))
        store.resolve(url, transcript: nil, secure: false)
        let lease = try store.acquire(url)
        XCTAssertFalse(store.discard(authority)); XCTAssertTrue(store.isActive(lease))
        store.release(lease)
        try RecordingStore.writeWAV(Array(samples.prefix(4000)), to: url)
        XCTAssertFalse(store.discard(authority)); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
