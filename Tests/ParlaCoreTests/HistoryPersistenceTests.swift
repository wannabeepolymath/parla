import XCTest
@testable import ParlaCore

final class HistoryPersistenceTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("history.json") }
    private final class Disk {
        var failWrite = false
        var failRead = false
        var writes = 0
        var persistence: HistoryStore.Persistence {
            .init(read: { [self] url in
                if failRead { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            }, writeAtomically: { [self] data, url in
                writes += 1
                if failWrite { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
        }
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-history-2c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recordTestFixture(directory, "created")
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try recordTestFixture(directory, "removed")
    }

    func testLegacyFileMigrationIsStableOnReopenAndPreservesAllFields() throws {
        var usage = PipelineMetrics(); usage.captureMs = 37; usage.promptTokens = 200; usage.cleanupModel = "test"
        let operation = TransformProvenance(origin: .selection, preset: .init(name: "Translate", kind: .translation, targetLanguage: "Hindi"), outcome: .parked)
        let original = HistoryEntry(date: Date(timeIntervalSinceReferenceDate: 123), raw: "source\nहिन्दी", cleaned: "result\n世界", appName: "Editor", metrics: usage, operation: operation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "id")
        try JSONSerialization.data(withJSONObject: [object, object]).write(to: url)
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        XCTAssertNil(store.lastError); XCTAssertEqual(disk.writes, 1)
        XCTAssertEqual(Set(store.entries.map(\.id)).count, 2)
        let ids = store.entries.map(\.id)
        let reopened = HistoryStore(url: url, persistence: disk.persistence)
        XCTAssertEqual(reopened.entries.map(\.id), ids); XCTAssertEqual(disk.writes, 1)
        for entry in reopened.entries {
            XCTAssertEqual(entry.raw, original.raw); XCTAssertEqual(entry.cleaned, original.cleaned)
            XCTAssertEqual(entry.date, original.date); XCTAssertEqual(entry.appName, original.appName)
            XCTAssertEqual(entry.metrics, usage); XCTAssertEqual(entry.operation, operation)
        }
        XCTAssertTrue(store.delete(ids[0])); XCTAssertEqual(store.entries.map(\.id), [ids[1]])
        XCTAssertEqual(HistoryStore(url: url).entries.map(\.id), [ids[1]])
    }

    func testIdenticalTextDateRowsAndDuplicateIDsNeverAlias() throws {
        let a = HistoryEntry(date: Date(timeIntervalSinceReferenceDate: 1), raw: "same")
        try JSONEncoder().encode([a, a]).write(to: url)
        let store = HistoryStore(url: url)
        let ids = store.entries.map(\.id)
        XCTAssertEqual(ids.count, 2); XCTAssertNotEqual(ids[0], ids[1]); XCTAssertEqual(ids[1], a.id)
        XCTAssertEqual(HistoryStore(url: url).entries.map(\.id), ids)
        XCTAssertTrue(store.delete(ids[0])); XCTAssertEqual(store.entries.map(\.id), [ids[1]])
        XCTAssertTrue(store.append(a)); XCTAssertEqual(store.entries.count, 1) // identical ID is idempotent
        let collision = HistoryEntry(id: a.id, date: a.date, raw: "different result")
        XCTAssertTrue(store.append(collision)); XCTAssertEqual(Set(store.entries.map(\.id)).count, 2)
        XCTAssertEqual(store.entries.first?.raw, "different result"); XCTAssertEqual(store.entries.last?.raw, "same")
    }

    func testMalformedAndInvalidIDFilesBlockAllWritesAndPreserveBytes() throws {
        for text in ["{broken", #"[{"id":"invalid","date":1,"raw":"keep"}]"#] {
            let bytes = Data(text.utf8); try bytes.write(to: url)
            let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
            XCTAssertTrue(store.loadBlocked); XCTAssertNotNil(store.lastError)
            XCTAssertFalse(store.append(.init(raw: "new"))); XCTAssertFalse(store.clear())
            XCTAssertFalse(store.applyCountLimit(1)); XCTAssertEqual(disk.writes, 0)
            XCTAssertEqual(store.pendingEntries.first?.raw, "new"); XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testUnreadableExistingFileAndDirectoryAreNotTreatedAsEmpty() throws {
        let bytes = try JSONEncoder().encode([HistoryEntry(raw: "keep")]); try bytes.write(to: url)
        let disk = Disk(); disk.failRead = true
        let store = HistoryStore(url: url, persistence: disk.persistence)
        XCTAssertTrue(store.loadBlocked); XCTAssertFalse(store.append(.init(raw: "new")))
        XCTAssertEqual(disk.writes, 0); XCTAssertEqual(try Data(contentsOf: url), bytes)
        disk.failRead = false; XCTAssertTrue(store.reload()); XCTAssertEqual(store.entries.first?.raw, "keep")
        XCTAssertTrue(store.retrySave(try XCTUnwrap(store.pendingEntries.first?.id)))
        let directoryStore = HistoryStore(url: directory)
        XCTAssertTrue(directoryStore.loadBlocked); XCTAssertFalse(directoryStore.clear())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedMigrationNeverOverwritesBytesAndSuccessfulRetryStabilizesIDs() throws {
        let bytes = Data(#"[{"date":1,"raw":"legacy"},{"date":1,"raw":"legacy"}]"#.utf8)
        try bytes.write(to: url)
        let disk = Disk(); disk.failWrite = true
        let store = HistoryStore(url: url, persistence: disk.persistence)
        XCTAssertTrue(store.loadBlocked); XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.delete(store.entries[0].id)); XCTAssertFalse(store.clear())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        disk.failWrite = false; XCTAssertTrue(store.reload()); XCTAssertFalse(store.loadBlocked)
        XCTAssertEqual(HistoryStore(url: url).entries.map(\.id), store.entries.map(\.id))
    }

    func testFailedAppendRetainsResultWithoutPublishingAndRetryIsIdempotent() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        let old = HistoryEntry(raw: "old"); XCTAssertTrue(store.append(old))
        let bytes = try Data(contentsOf: url)
        var usage = PipelineMetrics(); usage.promptTokens = 42
        let pending = HistoryEntry(raw: "original", cleaned: "result", metrics: usage, operation: .init(origin: .dictation, outcome: .failed))
        disk.failWrite = true
        XCTAssertFalse(store.append(pending)); XCTAssertEqual(store.entries, [old])
        XCTAssertEqual(store.pendingEntries, [pending]); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(store.append(pending)); XCTAssertEqual(store.pendingEntries.count, 1)
        disk.failWrite = false; XCTAssertTrue(store.retrySave(pending.id))
        XCTAssertFalse(store.retrySave(pending.id)); XCTAssertTrue(store.append(pending))
        XCTAssertEqual(store.entries, [pending, old]); XCTAssertTrue(store.pendingEntries.isEmpty)
        XCTAssertEqual(HistoryStore(url: url).entries, store.entries)
    }

    func testFailedDeleteClearAndTrimKeepCommittedRowsAndBytes() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        for i in 0..<3 { XCTAssertTrue(store.append(.init(raw: "\(i)"))) }
        let rows = store.entries, bytes = try Data(contentsOf: url)
        disk.failWrite = true
        XCTAssertFalse(store.delete(rows[1].id)); XCTAssertEqual(store.entries, rows)
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.clear()); XCTAssertEqual(store.entries, rows); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(store.applyCountLimit(1)); XCTAssertEqual(store.entries, rows)
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertNotNil(store.lastError)
        disk.failWrite = false; XCTAssertTrue(store.applyCountLimit(1))
        XCTAssertEqual(store.entries, [rows[0]]); XCTAssertNil(store.lastError)
        XCTAssertTrue(store.delete(rows[0].id)); XCTAssertTrue(store.entries.isEmpty)
    }

    func testLoadTrimFailureExposesUnappliedPolicyWithoutMutatingFile() throws {
        let seed = HistoryStore(url: url)
        for i in 0..<4 { seed.append(.init(raw: "\(i)")) }
        let bytes = try Data(contentsOf: url), disk = Disk(); disk.failWrite = true
        let store = HistoryStore(url: url, countLimit: 2, persistence: disk.persistence)
        XCTAssertEqual(store.entries.count, 4); XCTAssertNotNil(store.lastError); XCTAssertFalse(store.loadBlocked)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        disk.failWrite = false; XCTAssertTrue(store.reload()); XCTAssertEqual(store.entries.map(\.raw), ["3", "2"])
    }

    func testDiscardDeleteClearAndCountCannotResurrectOrSilentlyEvictPending() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        let saved = HistoryEntry(raw: "saved"); store.append(saved)
        disk.failWrite = true
        let first = HistoryEntry(raw: "pending 1"), second = HistoryEntry(raw: "pending 2")
        store.append(first); store.append(second)
        XCTAssertFalse(store.clear()); XCTAssertEqual(store.pendingEntries, [second, first])
        store.discard(first.id); XCTAssertFalse(store.retrySave(first.id))
        disk.failWrite = false
        XCTAssertTrue(store.applyCountLimit(1)); XCTAssertEqual(store.pendingEntries, [second])
        XCTAssertTrue(store.delete(saved.id)); XCTAssertTrue(store.retrySave(second.id))
        XCTAssertTrue(store.clear()); XCTAssertFalse(store.retrySave(second.id)); XCTAssertTrue(store.entries.isEmpty)
        disk.failWrite = true; store.append(first); disk.failWrite = false
        XCTAssertTrue(store.clear()); XCTAssertFalse(store.retrySave(first.id))
        let newer = HistoryEntry(raw: "new after clear"); disk.failWrite = true; store.append(newer)
        XCTAssertEqual(store.pendingEntries, [newer]); XCTAssertFalse(store.retrySave(first.id))
    }

    func testCountDefaultsBoundariesAndSettingsRoundtrip() throws {
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).historyTextCount, 50)
        for (value, expected) in [(-1, 1), (0, 1), (1, 1), (50, 50), (1000, 1000), (Int.max, 1000)] {
            var settings = Settings(); settings.historyTextCount = value
            XCTAssertEqual(settings.historyTextCount, expected)
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{\"historyTextCount\":\(value)}".utf8)).historyTextCount, expected)
            XCTAssertEqual(HistoryStore(url: directory.appendingPathComponent(UUID().uuidString), countLimit: value).countLimit, expected)
        }
        let store = HistoryStore(url: url)
        for i in 0..<55 { store.append(.init(raw: "\(i)")) }
        XCTAssertEqual(store.entries.count, 50); XCTAssertEqual(store.entries.last?.raw, "5")
        XCTAssertTrue(store.applyCountLimit(0)); XCTAssertEqual(store.entries.map(\.raw), ["54"])
        XCTAssertEqual(HistoryStore(url: url, countLimit: 1).entries, store.entries)
    }
    func testExternalCorruptionDeletionAndUnreadabilityCannotBeOverwrittenByCachedState() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        let saved = HistoryEntry(raw: "saved"); store.append(saved)
        let corrupt = Data("{external malformed".utf8); try corrupt.write(to: url)
        XCTAssertFalse(store.append(.init(raw: "new"))); XCTAssertTrue(store.loadBlocked)
        XCTAssertEqual(store.entries, [saved]); XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertFalse(store.reload()); XCTAssertEqual(store.entries, [saved])
        try JSONEncoder().encode([saved]).write(to: url); XCTAssertTrue(store.reload())
        disk.failRead = true; XCTAssertFalse(store.clear()); XCTAssertTrue(store.loadBlocked)
        disk.failRead = false; XCTAssertTrue(store.reload())
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.clear()); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.reload()); XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.pendingEntries.count, 1)
    }

    func testSuccessfulMutationsNotifyOnlyCompletedSavedAndPendingState() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        disk.failWrite = true
        let entry = HistoryEntry(raw: "pending"); store.append(entry)
        var snapshots: [(saved: [UUID], pending: [UUID])] = []
        let observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: store, queue: nil) { _ in
            snapshots.append((store.entries.map(\.id), store.pendingEntries.map(\.id)))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        disk.failWrite = false; XCTAssertTrue(store.retrySave(entry.id))
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(snapshots[0].saved, [entry.id]); XCTAssertTrue(snapshots[0].pending.isEmpty)
        XCTAssertTrue(store.clear()); XCTAssertTrue(snapshots.last!.saved.isEmpty); XCTAssertTrue(snapshots.last!.pending.isEmpty)
    }

    func testPendingCollisionAfterExternalReloadIsReidentifiedWithoutAliasingSavedRow() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        let pending = HistoryEntry(raw: "pending original", cleaned: "pending result")
        disk.failWrite = true; store.append(pending)
        let external = HistoryEntry(id: pending.id, raw: "different saved row")
        try JSONEncoder().encode([external]).write(to: url)
        disk.failWrite = false; XCTAssertTrue(store.reload())
        let reidentified = try XCTUnwrap(store.pendingEntries.first)
        XCTAssertNotEqual(reidentified.id, external.id); XCTAssertEqual(reidentified.raw, pending.raw)
        XCTAssertTrue(store.delete(external.id)); XCTAssertTrue(store.retrySave(reidentified.id))
        XCTAssertEqual(store.entries, [reidentified]); XCTAssertFalse(store.retrySave(pending.id))
    }

    func testPolicyRemainsTruthfulAfterFailedTrimThenDeleteOrRaisedLimit() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        for i in 0..<4 { store.append(.init(raw: "\(i)")) }
        disk.failWrite = true; XCTAssertFalse(store.applyCountLimit(1)); XCTAssertNotNil(store.lastError)
        // Raising the configured count resolves a trim that is no longer needed.
        XCTAssertTrue(store.applyCountLimit(4)); XCTAssertNil(store.lastError)
        XCTAssertFalse(store.applyCountLimit(1))
        disk.failWrite = false; XCTAssertTrue(store.delete(store.entries[0].id))
        XCTAssertEqual(store.entries.count, 1); XCTAssertNil(store.lastError)
        XCTAssertEqual(HistoryStore(url: url, countLimit: 1).entries, store.entries)
    }

    func testStartupDefersRetentionWhenSettingsCannotLoad() throws {
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        var valid = Settings(); valid.historyTextCount = 100
        try settings.save(valid)
        let seed = HistoryStore(settings: settings, url: url)
        for i in 0..<55 { seed.append(.init(raw: "\(i)")) }
        let bytes = try Data(contentsOf: url)
        try Data("{broken settings".utf8).write(to: settings.url)
        let started = HistoryStore(settings: settings, url: url)
        XCTAssertNotNil(settings.lastError)
        XCTAssertNil(started.countLimit)
        XCTAssertEqual(started.entries.count, 55)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(started.append(.init(raw: "new result")))
        XCTAssertEqual(started.entries.count, 56)
        try JSONEncoder().encode(valid).write(to: settings.url) // explicit external repair
        XCTAssertTrue(started.reload(countLimit: settings.load().historyTextCount))
        XCTAssertEqual(started.countLimit, 100)
        XCTAssertEqual(started.entries.count, 56)
        XCTAssertTrue(started.applyCountLimit(50))
        XCTAssertEqual(started.entries.count, 50)
    }

}

extension HistoryPersistenceTests {
    func testReviewedAppendFailureHasNoPendingEscapeAndExactConflictRefuses() throws {
        let disk = Disk(), store = HistoryStore(url: url, persistence: disk.persistence)
        let existing = HistoryEntry(raw: "keep"), reviewed = HistoryEntry(raw: "raw review हिन्दी")
        XCTAssertTrue(store.append(existing)); let bytes = try Data(contentsOf: url)
        disk.failWrite = true
        XCTAssertFalse(store.appendReviewed(reviewed)); XCTAssertTrue(store.pendingEntries.isEmpty)
        XCTAssertFalse(store.retrySave(reviewed.id)); XCTAssertEqual(try Data(contentsOf: url), bytes)
        disk.failWrite = false
        XCTAssertTrue(store.appendReviewed(reviewed)); XCTAssertTrue(store.appendReviewed(reviewed))
        XCTAssertEqual(store.entries.map(\.id), [reviewed.id, existing.id])
        XCTAssertFalse(store.appendReviewed(HistoryEntry(id: reviewed.id, date: reviewed.date, raw: "conflicting")))
        XCTAssertTrue(store.pendingEntries.isEmpty); XCTAssertEqual(store.entries.first, reviewed)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertFalse(store.appendReviewed(reviewed)); XCTAssertEqual(try Data(contentsOf: url), Data("corrupt".utf8))
    }
}
