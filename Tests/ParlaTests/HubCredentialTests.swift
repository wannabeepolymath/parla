import XCTest
import SwiftUI
import ParlaCore
@testable import Parla

private final class CredentialHTTP: HTTPPosting {
    var requests: [URLRequest] = []
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(#"{"choices":[{"message":{"content":"polished"}}]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class HubCredentialTests: XCTestCase {
    private var root: URL!
    private var backend: FakeCredentialBackend!
    private var credentials: CredentialStore!
    private var store: SettingsStore!
    private var hub: HubModel!
    private var failWrite = false
    private var http: CredentialHTTP!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave3a-hub-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recordWave4BFixture(root, "created")
        backend = FakeCredentialBackend(); credentials = CredentialStore(backend: backend)
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: credentials, atomicWrite: { [unowned self] data, url in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to: url, options: .atomic)
        })
        try store.save(Settings())
        http = CredentialHTTP()
        hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")),
                       clipboard: { _ in XCTFail("No clipboard") }, recordings: RecordingStore(directory: root.appendingPathComponent("recordings")), retryHTTP: self.http)
        hub.credentialEnvironment = { [:] }; hub.retryEnvironment = { [:] }; hub.refresh()
    }
    override func tearDownWithError() throws {
        hub.flushPendingSave(); hub = nil
        try FileManager.default.removeItem(at: root)
        try recordWave4BFixture(root, "removed")
    }
    func testRefreshNeverHydratesAndBlankSaveDoesNotMutate() {
        backend.values[.anthropic] = "stored-secret"
        hub.refresh(); XCTAssertEqual(hub.credentialDraft, ""); XCTAssertTrue(hub.credentialStatus.contains("stored"))
        let reads = backend.reads; hub.saveCredential(); hub.flushPendingSave()
        XCTAssertEqual(backend.reads, reads); XCTAssertEqual(backend.updates, 0); XCTAssertEqual(backend.deletes, 0)
        XCTAssertFalse(hub.credentialStatus.contains("stored-secret")); XCTAssertNil(hub.settings.anthropicApiKey)
    }
    func testRenderingOnlyUsesPublishedStatusAndDraft() {
        backend.values[.anthropic] = "not-for-render"
        hub.refreshCredentialStatus(); let reads = backend.reads; let statuses = backend.statuses
        for _ in 0..<5 { _ = CleanupPage(model: hub).body }
        XCTAssertEqual(backend.reads, reads); XCTAssertEqual(backend.statuses, statuses)
    }
    func testScopeChangesClearDraftAndNeverMoveOrDeleteOldKey() throws {
        backend.values[.anthropic] = "anthropic"
        hub.credentialDraft = "discard-draft"
        hub.credentialMessage = "old scope action failure"
        hub.settings.cleanup.provider = "openai-compatible"
        XCTAssertEqual(hub.credentialDraft, ""); XCTAssertNil(hub.credentialMessage)
        hub.settings.cleanup.baseURL = "https://a.test/v1"
        hub.credentialDraft = "a-key"; hub.saveCredential(); hub.flushPendingSave()
        let a = try CredentialScope.compatible("https://a.test/v1")
        XCTAssertEqual(backend.values[a], "a-key")
        hub.credentialDraft = "do-not-carry"; hub.settings.cleanup.baseURL = "https://a.test/v2"
        XCTAssertEqual(hub.credentialDraft, ""); XCTAssertTrue(hub.credentialStatus.contains("No key saved"))
        hub.saveCredential(); hub.flushPendingSave()
        XCTAssertNil(backend.values[try .compatible("https://a.test/v2")])
        XCTAssertEqual(backend.values[a], "a-key"); XCTAssertEqual(backend.values[.anthropic], "anthropic")
        XCTAssertEqual(backend.deletes, 0)
        let actual = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(actual.contains("a-key")); XCTAssertFalse(actual.contains("anthropicApiKey"))
    }
    func testExplicitReplaceAndRemoveRemainIndependentOfEnvironmentOverride() {
        backend.values[.anthropic] = "old"
        hub.credentialEnvironment = { ["ANTHROPIC_API_KEY": "env-secret"] }; hub.refreshCredentialStatus()
        XCTAssertTrue(hub.credentialStatus.contains("environment variable"))
        hub.credentialDraft = "replacement"; hub.saveCredential(); hub.flushPendingSave()
        XCTAssertEqual(backend.values[.anthropic], "replacement"); XCTAssertEqual(hub.credentialDraft, "")
        hub.removeCredential(); hub.flushPendingSave()
        XCTAssertNil(backend.values[.anthropic]); XCTAssertTrue(hub.credentialStatus.contains("environment variable"))
        XCTAssertFalse(hub.credentialStatus.contains("env-secret"))
    }
    func testDeniedCanceledUpdateDeleteAreVisibleAndDraftIsRetainedForRetry() {
        backend.values[.anthropic] = "old"; backend.statusState = .denied
        hub.refreshCredentialStatus(); XCTAssertTrue(hub.credentialIssue?.contains("denied") == true)
        backend.updateResult = .canceled; hub.credentialDraft = "new"
        hub.saveCredential(); XCTAssertTrue(hub.credentialMessage?.contains("canceled") == true)
        XCTAssertEqual(hub.credentialDraft, "new"); XCTAssertEqual(backend.values[.anthropic], "old")
        backend.updateResult = nil; hub.saveCredential(); hub.flushPendingSave()
        XCTAssertEqual(backend.values[.anthropic], "new")
        backend.deleteResult = .denied; hub.removeCredential()
        XCTAssertTrue(hub.credentialMessage?.contains("denied") == true); XCTAssertEqual(backend.values[.anthropic], "new")
    }
    func testFailedLegacyMigrationSurvivesActualHubDebounceAndFlushThenExplicitReplace() throws {
        let original = Data(#"{ "anthropicApiKey":"legacy-only", "dictionary":["old"] }"#.utf8)
        try original.write(to: store.url); backend.readState = .denied
        hub.refresh(); XCTAssertNotNil(hub.credentialMessage); XCTAssertEqual(hub.credentialDraft, "")
        hub.words.append(.init(text: "new")); hub.settings.whisperModelPath = "downloaded-model"
        hub.flushPendingSave()
        XCTAssertNotNil(hub.saveError); XCTAssertEqual(try Data(contentsOf: store.url), original)
        backend.readState = nil; backend.statusState = nil
        hub.credentialDraft = "chosen"; hub.saveCredential(); hub.flushPendingSave()
        XCTAssertEqual(backend.values[.anthropic], "chosen")
        XCTAssertNil(hub.credentialMessage); XCTAssertNil(hub.saveError)
        XCTAssertFalse(try String(contentsOf: store.url, encoding: .utf8).contains("anthropicApiKey"))
        XCTAssertEqual(store.load().whisperModelPath, "downloaded-model")
        XCTAssertEqual(store.load().dictionary, ["old", "new"])
    }
    func testConflictIsActionableAndExplicitRemoveDoesNotRemigrateLegacy() throws {
        let original = Data(#"{"anthropicApiKey":"legacy"}"#.utf8)
        try original.write(to: store.url); backend.values[.anthropic] = "existing"
        hub.refresh(); XCTAssertTrue(hub.credentialMessage?.contains("different key") == true)
        hub.removeCredential(); hub.flushPendingSave()
        XCTAssertNil(backend.values[.anthropic]); XCTAssertNil(store.load().anthropicApiKey)
        hub.refresh(); XCTAssertNil(backend.values[.anthropic]); XCTAssertNil(hub.credentialMessage)
    }
    func testLoadAndSaveErrorsGateCredentialMutation() throws {
        try Data("invalid".utf8).write(to: store.url); hub.refresh()
        hub.credentialDraft = "must-not-write"; hub.saveCredential(); hub.removeCredential()
        XCTAssertEqual(backend.adds, 0); XCTAssertEqual(backend.deletes, 0); XCTAssertNotNil(hub.credentialMessage)
        try Data("{}".utf8).write(to: store.url); hub.refresh()
        failWrite = true; hub.settings.cleanupModel = "edited"; hub.flushPendingSave()
        XCTAssertNotNil(hub.saveError)
        hub.credentialDraft = "blocked-by-save"; hub.saveCredential()
        XCTAssertEqual(backend.adds, 0); XCTAssertTrue(hub.credentialMessage?.contains("settings error") == true)
    }
    func testCredentialDiskFailurePreservesLegacyBytesAndRetriesWithoutLosingSource() throws {
        let original = Data(#"{"anthropicApiKey":"legacy"}"#.utf8)
        try original.write(to: store.url); backend.values[.anthropic] = "conflicting"
        hub.refresh(); failWrite = true
        hub.credentialDraft = "replacement"; hub.saveCredential()
        XCTAssertEqual(backend.values[.anthropic], "replacement"); XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertNotNil(hub.credentialMessage); XCTAssertEqual(hub.credentialDraft, "replacement")
        failWrite = false; hub.saveCredential(); hub.flushPendingSave()
        XCTAssertNil(hub.credentialMessage); XCTAssertNil(store.load().anthropicApiKey)
    }
    @MainActor func testDefaultRetryFactoryUsesPreparedCredentialDespiteLaterEndpointAndKeyChanges() async throws {
        hub.settings.cleanup.provider = "openai-compatible"; hub.settings.cleanup.baseURL = "https://old.test/v1"
        hub.settings.cleanup.model = "chosen"; hub.credentialDraft = "prepared-key"; hub.saveCredential(); hub.flushPendingSave()
        let entry = HistoryEntry(raw: "source"); hub.history.append(entry)
        hub.prepareHistoryRetry(entry.id)
        let reads = backend.reads
        backend.values[try .compatible("https://old.test/v1")] = "changed-key"; backend.readState = .denied
        hub.settings.cleanup.baseURL = "https://new.test/v1"; hub.flushPendingSave()
        await hub.startHistoryRetry(entry.id)
        XCTAssertEqual(backend.reads, reads)
        XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://old.test/v1/chat/completions")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer prepared-key")
        XCTAssertEqual(hub.historyRetries[entry.id]?.proposed, "polished")
        let provenance = try XCTUnwrap(hub.historyRetries[entry.id]?.provenance)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self).contains("prepared-key"))
    }
    func testRefreshRetryMigrationRemovesBothFieldsWithoutHydration() throws {
        let original = Data(#"{"anthropicApiKey":"anthropic","cleanup":{"provider":"openai-compatible","baseURL":"http://localhost:80/v1/","apiKey":"compatible"}}"#.utf8)
        try original.write(to: store.url); backend.readState = .canceled; hub.refresh()
        XCTAssertNotNil(hub.credentialMessage)
        backend.readState = nil; hub.retryCredentialMigration()
        XCTAssertNil(hub.credentialMessage); XCTAssertEqual(hub.credentialDraft, "")
        XCTAssertNil(hub.settings.anthropicApiKey); XCTAssertNil(hub.settings.cleanup.apiKey)
        XCTAssertEqual(backend.values[try .compatible("http://localhost/v1")], "compatible")
        XCTAssertFalse(try String(contentsOf: store.url, encoding: .utf8).contains("apiKey"))
    }
}
