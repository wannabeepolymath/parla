import XCTest
@testable import ParlaCore

final class HistoryRetryStoreTests: XCTestCase {
    func testConditionalUpdatePreservesInitialFieldsAndOnlyCurrentSnapshotCanCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-retry-store-2c2-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
                try recordTestFixture(directory, "removed")
            } catch {
                try? recordTestFixture(directory, "cleanup-uncertain")
            }
        }
        try recordTestFixture(directory, "created")
        var fail = false
        let url = directory.appendingPathComponent("history.json")
        let store = HistoryStore(url: url, persistence: .init(writeAtomically: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to: url, options: .atomic)
        }))
        var metrics = PipelineMetrics(); metrics.model = "initial-asr"; metrics.promptTokens = 3
        let operation = TransformProvenance(origin: .spoken, outcome: .completed)
        let entry = HistoryEntry(date: Date(timeIntervalSince1970: 4), raw: "immutable", cleaned: "previous", metrics: metrics, operation: operation)
        store.append(entry)
        let version = try XCTUnwrap(store.version(of: entry.id)), bytes = try Data(contentsOf: url)
        let request = try HistoryRetryRequest(settings: Settings(), environment: [:], source: HistoryEntry(raw: entry.raw), applyPreset: false)
        let provenance = HistoryRetryProvenance(date: Date(timeIntervalSince1970: 10), configuration: request.configuration, usage: nil)
        fail = true
        XCTAssertEqual(store.updateResult(expected: entry, version: version, text: "new", retry: provenance), .failed)
        XCTAssertEqual(store.entries, [entry]); XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertTrue(store.pendingEntries.isEmpty)
        fail = false
        XCTAssertEqual(store.updateResult(expected: entry, version: version, text: "new", retry: provenance), .saved)
        let saved = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(saved.raw, entry.raw); XCTAssertEqual(saved.date, entry.date); XCTAssertEqual(saved.metrics, metrics)
        XCTAssertEqual(saved.operation, operation); XCTAssertEqual(saved.retries, [provenance])
        XCTAssertEqual(store.updateResult(expected: entry, version: version, text: "again", retry: provenance), .stale)
        XCTAssertEqual(store.entries, [saved]); XCTAssertTrue(store.reload()); XCTAssertEqual(store.entries, [saved])
        store.delete(saved.id)
        XCTAssertEqual(store.updateResult(expected: saved, version: version, text: "resurrect", retry: provenance), .stale)
        XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(store.pendingEntries.isEmpty)
    }

    func testDeleteAndReappendIdenticalIDContentCannotReuseEarlierIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-retry-store-2c2-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
                try recordTestFixture(directory, "removed")
            } catch {
                try? recordTestFixture(directory, "cleanup-uncertain")
            }
        }
        try recordTestFixture(directory, "created")
        let store = HistoryStore(url: directory.appendingPathComponent("history.json"))
        let entry = HistoryEntry(raw: "same ID and content"); store.append(entry)
        let version = try XCTUnwrap(store.version(of: entry.id))
        store.delete(entry.id); store.append(entry)
        XCTAssertFalse(store.matches(entry, version: version))
        XCTAssertEqual(store.entries, [entry])
    }
}
