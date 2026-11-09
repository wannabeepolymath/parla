import AVFoundation
import XCTest
@testable import ParlaCore

final class RecordingRecoveryTests: XCTestCase {
    private var root: URL!
    private var store: RecordingStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var tone: [Float] { (0..<8_000).map { Float(sin(Double($0) * 0.05)) * 0.5 } }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-recovery-2c4-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recordTestFixture(root, "created")
        store = RecordingStore(directory: root.appendingPathComponent("recordings"), keepAll: false)
    }
    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
        try recordTestFixture(root, "removed")
    }
    private func failed(_ store: RecordingStore? = nil) throws -> URL {
        let s = store ?? self.store!
        let url = try XCTUnwrap(s.stash(tone))
        s.resolve(url, transcript: nil, secure: false)
        return url
    }
    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
    }
    func testCaptureOwnershipStartsBeforeWriterAndResolveFailureReleasesIt() throws {
        var s: RecordingStore!
        var observed = false
        s = RecordingStore(directory: store.directory, keepAll: false, writer: { [unowned self] samples, url in
            try RecordingStore.writeWAV(samples, to: url)
            observed = true
            XCTAssertTrue(s.recordings().isEmpty)
            XCTAssertTrue(s.descriptors().isEmpty)
            XCTAssertEqual(s.clear().busy, 1)
            XCTAssertFalse(s.delete(url))
            XCTAssertEqual(s.prune(now: self.now.addingTimeInterval(90 * 86_400)), 0)
        })
        let url = try XCTUnwrap(s.stash(tone)); XCTAssertTrue(observed)
        XCTAssertTrue(s.recordings().isEmpty)
        s.resolve(url, transcript: nil, secure: false)
        XCTAssertEqual(s.descriptors().map(\.url), [url])
    }
    func testRecoveryLeaseExcludesListClearPruneAndSecondAcquisition() throws {
        let url = try failed()
        let lease = try store.acquire(url)
        XCTAssertTrue(store.descriptors().isEmpty); XCTAssertEqual(store.summary().count, 0)
        XCTAssertThrowsError(try store.acquire(url))
        XCTAssertFalse(store.delete(url)); XCTAssertEqual(store.clear().busy, 1)
        XCTAssertEqual(store.prune(now: Date().addingTimeInterval(60 * 86_400)), 0)
        store.release(lease); XCTAssertEqual(store.descriptors().count, 1)
    }
    func testExpiryBoundaryAndExpiredActionsAndLeaseUse() throws {
        let boundary = try failed(); try age(boundary, days: 7)
        XCTAssertEqual(store.prune(now: now), 0)
        let row = try XCTUnwrap(store.descriptors(now: now).first)
        XCTAssertEqual(row.expiry, now); XCTAssertNotNil(row.duration); XCTAssertGreaterThan(row.bytes, 44)
        let lease = try store.acquire(boundary, now: now)
        XCTAssertNoThrow(try store.validate(lease, now: now))
        XCTAssertThrowsError(try store.validate(lease, now: now.addingTimeInterval(0.01)))
        store.release(lease)
        XCTAssertThrowsError(try store.acquire(boundary, now: now.addingTimeInterval(0.01)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertEqual(store.prune(now: now.addingTimeInterval(0.01)), 0)
    }
    func testMissingChangedAndOutsideFilesCannotBeUsed() throws {
        let url = try failed(); let lease = try store.acquire(url)
        try RecordingStore.writeWAV(Array(tone.prefix(4_000)), to: url)
        XCTAssertThrowsError(try store.samples(lease)); store.release(lease)
        let second = try store.acquire(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.samples(second)); store.release(second)
        XCTAssertThrowsError(try store.acquire(url))
        let outside = root.appendingPathComponent("outside.wav"); try RecordingStore.writeWAV(tone, to: outside)
        XCTAssertThrowsError(try store.acquire(outside)); XCTAssertFalse(store.delete(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
    func testInvalidWAVsListedWithReasonsAndSafeSymlinkDeletion() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.wav"); try RecordingStore.writeWAV(tone, to: outside)
        let link = store.directory.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for name in ["empty.wav", "corrupt.wav"] { try Data(name == "empty.wav" ? [] : Array("invalid".utf8)).write(to: store.directory.appendingPathComponent(name)) }
        let zero = store.directory.appendingPathComponent("zero.wav")
        try RecordingStore.writeWAV([], to: zero)
        let rows = store.descriptors(); XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.available && $0.reason != nil })
        for row in rows { XCTAssertThrowsError(try store.acquire(row.url)) }
        XCTAssertTrue(store.delete(link)); XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(store.clear().removed, 3)
    }
    func testUnsupportedAndOversizedInputNeverActionable() throws {
        let url = try failed()
        // WAV format tag 6 is A-law, explicitly outside supported PCM recovery.
        var bytes = try Data(contentsOf: url)
        if let range = bytes.range(of: Data("fmt ".utf8)) { bytes[range.lowerBound + 8] = 6 }
        try bytes.write(to: url)
        XCTAssertFalse(try XCTUnwrap(store.descriptors().first).available)
        XCTAssertThrowsError(try store.acquire(url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RecordingStore.maximumBytes + 1)); try handle.close()
        XCTAssertFalse(try XCTUnwrap(store.descriptors().first).available)
    }
    func testStableLocalIDsAcrossRelaunchAndCorpusMarkerExclusion() throws {
        let url = try failed()
        let first = try XCTUnwrap(store.descriptors().first)
        let fresh = RecordingStore(directory: store.directory, keepAll: true)
        XCTAssertEqual(fresh.descriptors().first?.id, first.id)
        let lease = try fresh.acquire(url); fresh.complete(lease, transcript: "raw ASR")
        XCTAssertTrue(fresh.descriptors().isEmpty)
        XCTAssertEqual(fresh.summary().count, 1)
        XCTAssertTrue(fresh.delete(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("hyp.txt").path))
    }
    func testAudioOffStopsNewStashesIncludingCorpusAndKeepsExistingManageable() throws {
        let s = RecordingStore(directory: store.directory, keepAll: true)
        let url = try failed(s)
        var settings = Settings(); settings.recoveryAudioEnabled = false
        s.configure(settings: settings, error: nil)
        XCTAssertNil(s.stash(tone)); XCTAssertEqual(s.descriptors().count, 1)
        let lease = try s.acquire(url); s.complete(lease, transcript: "recovered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testColdSettingsFailureDefersPruneAndStashThenValidPolicySurvivesErrors() throws {
        let url = try failed(); try age(url, days: 20)
        let s = RecordingStore(directory: store.directory, requireValidatedPolicy: true)
        s.configure(settings: Settings(), error: "bad", now: now)
        XCTAssertNil(s.policy); XCTAssertNotNil(s.policyStatus)
        XCTAssertEqual(s.prune(now: now), 0); XCTAssertNil(s.stash(tone, now: now))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); XCTAssertFalse(try XCTUnwrap(s.descriptors(now: now).first).available)
        var settings = Settings(); settings.recoveryAudioDays = 30; settings.recoveryAudioEnabled = false
        s.configure(settings: settings, error: nil, now: now)
        s.configure(settings: Settings(), error: "bad later", now: now)
        XCTAssertEqual(s.policy, .init(enabled: false, days: 30)); XCTAssertNotNil(s.policyStatus)
        XCTAssertNil(s.stash(tone, now: now)); XCTAssertTrue(s.delete(url, now: now))
    }
    func testProductionSettingsStashContractMissingDefaultsCorruptNoFallback() throws {
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        let s = RecordingStore(directory: store.directory, requireValidatedPolicy: true)
        let url = try XCTUnwrap(s.stash(tone, settings: settings))
        XCTAssertEqual(s.policy, .init()); s.resolve(url, transcript: nil, secure: false)
        var off = Settings(); off.recoveryAudioEnabled = false; try settings.save(off)
        XCTAssertNil(s.stash(tone, settings: settings))
        try Data("broken".utf8).write(to: settings.url)
        XCTAssertNil(s.stash(tone, settings: settings)); XCTAssertNotNil(s.policyStatus)
        XCTAssertEqual(s.policy?.enabled, false)
    }
    func testPartialWriteCleanupAndWriteFailureReportedWithoutThrowingDictation() throws {
        let s = RecordingStore(directory: store.directory, writer: { _, url in
            try Data("partial".utf8).write(to: url); throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertNil(s.stash(tone)); XCTAssertNotNil(s.lastError); XCTAssertTrue(s.recordings().isEmpty)
        let stuck = RecordingStore(directory: store.directory, writer: { _, url in
            try Data("partial".utf8).write(to: url); throw CocoaError(.fileWriteOutOfSpace)
        }, remover: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertNil(stuck.stash(tone)); XCTAssertTrue(stuck.lastError?.contains("partial") == true)
        XCTAssertFalse(try XCTUnwrap(stuck.descriptors().first).available)
    }
    func testRemovePruneClearFailuresHaveTruthfulCountersAndSecureFailureIsVisible() throws {
        let url = try failed(); try age(url, days: 8)
        let s = RecordingStore(directory: store.directory, remover: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(s.prune(now: now), 0); XCTAssertNotNil(s.lastError)
        XCTAssertFalse(s.delete(url, now: now))
        let outcome = s.clear(now: now); XCTAssertEqual(outcome.removed, 0); XCTAssertEqual(outcome.failed, 1)
        s.resolve(url, transcript: nil, secure: true)
        XCTAssertTrue(s.lastError?.contains("password field") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testSecureRevokesRecoveryBeforeRemovingInBothCorpusModes() throws {
        for corpus in [false, true] {
            let s = RecordingStore(directory: store.directory, keepAll: corpus)
            let url = try failed(s); var revoked = false
            let lease = try s.acquire(url, onRevoke: {
                revoked = true
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            })
            let alias = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.uppercased())
            s.resolve(alias, transcript: "secure", secure: true)
            XCTAssertTrue(revoked); XCTAssertFalse(s.isActive(lease))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testUnreadableRootCannotReportSuccessfulClearOrScanAlias() throws {
        try Data("not a folder".utf8).write(to: store.directory)
        XCTAssertEqual(store.clear().failed, 1); XCTAssertNotNil(store.lastError)
        try FileManager.default.removeItem(at: store.directory)
        let outside = root.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("voice.wav"); try RecordingStore.writeWAV(tone, to: sentinel)
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: outside)
        XCTAssertTrue(store.recordings().isEmpty); XCTAssertEqual(store.clear().failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
    func testPolicyPersistenceBoundsAndIndependence() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(missing.recoveryAudioEnabled); XCTAssertEqual(missing.recoveryAudioDays, 7)
        var s = missing; s.recoveryAudioEnabled = false; s.recoveryAudioDays = 30; s.historyEnabled = true; s.historyTextCount = 1
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)), s)
        s.recoveryAudioDays = 0; XCTAssertEqual(s.recoveryAudioDays, 1)
        s.recoveryAudioDays = 99; XCTAssertEqual(s.recoveryAudioDays, 30)
        for data in [#"{"recoveryAudioDays":0}"#, #"{"recoveryAudioDays":31}"#, #"{"recoveryAudioEnabled":"yes"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(data.utf8)))
        }
    }
    func testFailedCompleteWriteRemainsNonviableAfterRelaunchWhenRemovalFails() throws {
        let s = RecordingStore(directory: store.directory, writer: { samples, url in
            try RecordingStore.writeWAV(samples, to: url)
            throw CocoaError(.fileWriteOutOfSpace)
        }, remover: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertNil(s.stash(tone))
        let relaunched = RecordingStore(directory: store.directory)
        let row = try XCTUnwrap(relaunched.descriptors().first)
        XCTAssertFalse(row.available); XCTAssertTrue(row.reason?.contains("incomplete") == true)
        XCTAssertThrowsError(try relaunched.acquire(row.url))
        XCTAssertTrue(relaunched.delete(row.url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }
    func testSuccessfulDisposalFailureAndOrphanSidecarClearRemainTruthful() throws {
        let url = try failed()
        let s = RecordingStore(directory: store.directory, remover: { _ in throw CocoaError(.fileWriteNoPermission) })
        let lease = try s.acquire(url); s.complete(lease, transcript: "successful text")
        XCTAssertNotNil(s.lastError); XCTAssertFalse(s.isActive(lease))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let hyp = url.deletingPathExtension().appendingPathExtension("hyp.txt")
        try Data("hypothesis".utf8).write(to: hyp)
        let sidecarFailure = RecordingStore(directory: store.directory, remover: { path in
            if path == hyp { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: path)
        })
        XCTAssertFalse(sidecarFailure.delete(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hyp.path))
        XCTAssertEqual(store.clear().removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hyp.path))
    }
    func testRepeatedReadFailureNotificationsAreBoundedAndCaseAliasCannotDeleteLease() throws {
        let url = try failed(); let lease = try store.acquire(url)
        let alternate = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.uppercased())
        XCTAssertFalse(store.delete(alternate)); XCTAssertThrowsError(try store.acquire(alternate))
        XCTAssertTrue(store.isActive(lease)); store.release(lease)
        let badRoot = root.appendingPathComponent("bad-root"); try Data().write(to: badRoot)
        let bad = RecordingStore(directory: badRoot)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: RecordingStore.didChange, object: bad, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<5 { _ = bad.descriptors(); _ = bad.summary() }
        XCTAssertEqual(notifications, 1)
    }

    func testDanglingSettingsAliasIsAnErrorAndNeverAuthorizesColdPolicy() throws {
        let settingsURL = root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: root.appendingPathComponent("missing.json"))
        let settings = SettingsStore(url: settingsURL, credentials: testCredentialStore())
        let s = RecordingStore(directory: store.directory, requireValidatedPolicy: true)
        XCTAssertNil(s.stash(tone, settings: settings))
        XCTAssertNotNil(settings.lastError); XCTAssertNil(s.policy); XCTAssertNotNil(s.policyStatus)
        let danglingRoot = root.appendingPathComponent("dangling-recordings")
        let target = root.appendingPathComponent("missing-folder")
        try FileManager.default.createSymbolicLink(at: danglingRoot, withDestinationURL: target)
        let unsafe = RecordingStore(directory: danglingRoot)
        XCTAssertNil(unsafe.stash(tone)); XCTAssertNotNil(unsafe.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testIdentityDetectsReplacementWithSameBytesAndModificationDate() throws {
        let url = try failed(); let lease = try store.acquire(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = try Data(contentsOf: url)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.validate(lease))
        store.release(lease)
        let new = try store.acquire(url); store.release(new)
    }

}
