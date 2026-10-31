import XCTest
@testable import ParlaCore

private final class PreferenceMemory {
    var bytes: Data?
    var reads = 0, writes = 0
    var failRead = false, failWrite = false
    var beforeRead: ((Int) -> Void)?
    var io: ScratchpadPreferenceIO { .init(read: { _ in
        self.reads += 1; self.beforeRead?(self.reads)
        if self.failRead { throw ScratchpadPreferenceFailure() }
        return self.bytes
    }, write: { bytes, _ in
        self.writes += 1
        if self.failWrite { throw ScratchpadPreferenceFailure() }
        self.bytes = bytes
    }) }
}

final class ScratchpadPreferenceTests: XCTestCase {
    private func store(_ memory: PreferenceMemory, _ backend: FakeCredentialBackend) -> SettingsStore {
        SettingsStore(url: URL(fileURLWithPath: "/unused-wave4e1-\(UUID())/settings.json"),
            credentials: CredentialStore(backend: backend), scratchpadIO: memory.io)
    }
    private func noCredentials(_ backend: FakeCredentialBackend, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0, file: file, line: line)
    }
    func testCodableDefaultMissingNullWrongTypeAndExport() throws {
        XCTAssertFalse(Settings().scratchpadDictionaryAlternativesEnabled)
        for json in ["{}", "{\"scratchpadDictionaryAlternativesEnabled\":null}"] {
            XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).scratchpadDictionaryAlternativesEnabled)
        }
        for value in ["1", "\"true\"", "[]", "{}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data("{\"scratchpadDictionaryAlternativesEnabled\":\(value)}".utf8)))
        }
        var settings = Settings(); settings.scratchpadDictionaryAlternativesEnabled = true
        settings.anthropicApiKey = "synthetic-secret"; settings.cleanup.apiKey = "synthetic-other"
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: data).scratchpadDictionaryAlternativesEnabled)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic"))
        let vocabulary = try VocabularyDocument(settings: settings).encoded()
        XCTAssertFalse(String(decoding: vocabulary, as: UTF8.self).contains("scratchpad"))
    }
    func testPassiveOperationPreservesUnknownLegacyAndBindingsWithoutCredentials() throws {
        for provider in ["anthropic", "openai-compatible", "apple-intelligence"] {
            let memory = PreferenceMemory(), backend = FakeCredentialBackend()
            let original: [String: Any] = ["unknown": ["nested": [1, 2, 3]], "dictionary": ["OpenAI"],
                "anthropicApiKey": "synthetic-anthropic", "historyEnabled": false,
                "cleanup": ["provider": provider, "baseURL": "invalid inactive binding", "apiKey": "synthetic-compatible", "model": "retained"]]
            memory.bytes = try JSONSerialization.data(withJSONObject: original)
            let store = store(memory, backend)
            XCTAssertTrue(try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
            var result = try XCTUnwrap(JSONSerialization.jsonObject(with: memory.bytes!) as? [String: Any])
            XCTAssertEqual(result.removeValue(forKey: "scratchpadDictionaryAlternativesEnabled") as? Bool, true)
            XCTAssertEqual(result as NSDictionary, original as NSDictionary)
            XCTAssertTrue(try store.scratchpadDictionaryConfiguration().enabled)
            noCredentials(backend)
        }
    }
    func testMissingSeedAndPostUnlockReentrantContentFreeNotification() throws {
        let memory = PreferenceMemory(), backend = FakeCredentialBackend(); let store = store(memory, backend)
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: SettingsStore.scratchpadPreferenceDidChange, object: store, queue: nil) { note in
            notices += 1
            XCTAssertEqual(note.userInfo?.count, 1)
            XCTAssertEqual(note.userInfo?["enabled"] as? Bool, true)
            XCTAssertTrue(try! store.scratchpadDictionaryConfiguration().enabled) // Would deadlock under lock.
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
        XCTAssertEqual(notices, 1); XCTAssertEqual(memory.writes, 1); noCredentials(backend)
    }
    func testCorruptRecoveredOversizeWrongTypeUnreadableConflictAndWriteFaultPreserveOriginal() throws {
        let inputs: [Data?] = [Data("bad".utf8), Data("{\"profiles\":42}".utf8),
            Data("{\"scratchpadDictionaryAlternativesEnabled\":\"true\"}".utf8),
            Data(repeating: 32, count: 1_048_577), Data("{\"scratchpadDictionaryAlternativesEnabled\":true}".utf8)]
        for input in inputs {
            let memory = PreferenceMemory(), backend = FakeCredentialBackend(); memory.bytes = input
            let store = store(memory, backend)
            XCTAssertThrowsError(try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
            XCTAssertEqual(memory.bytes, input); XCTAssertEqual(memory.writes, 0); noCredentials(backend)
        }
        for readFault in [false, true] {
            let memory = PreferenceMemory(), backend = FakeCredentialBackend(); memory.bytes = Data("{}".utf8)
            memory.failRead = readFault; memory.failWrite = !readFault
            let store = store(memory, backend)
            XCTAssertThrowsError(try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
            XCTAssertEqual(memory.bytes, Data("{}".utf8)); noCredentials(backend)
        }
    }
    func testByteRecheckRejectsExternalChangeAndFreshProjectionIgnoresStamp() throws {
        let memory = PreferenceMemory(), backend = FakeCredentialBackend(); memory.bytes = Data("{}".utf8)
        let store = store(memory, backend)
        memory.beforeRead = { read in if read == 2 { memory.bytes = Data("{\"unknown\":1}".utf8) } }
        XCTAssertThrowsError(try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
        XCTAssertEqual(memory.writes, 0); XCTAssertEqual(memory.bytes, Data("{\"unknown\":1}".utf8))
        memory.beforeRead = nil
        memory.bytes = Data("{\"dictionary\":[\"OpenAI\"]}".utf8)
        let first = try store.scratchpadDictionaryConfiguration()
        memory.bytes = Data("{\"dictionary\":[\"OPENAI\"]}".utf8)
        let second = try store.scratchpadDictionaryConfiguration()
        XCTAssertNotEqual(first.signature, second.signature); noCredentials(backend)
    }
    func testActualBoundedRegularReaderAndAllFullWritersPreserveFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wave4e1-preference-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try record(root)
        let url = root.appendingPathComponent("settings.json"), backend = FakeCredentialBackend()
        let store = SettingsStore(url: url, credentials: CredentialStore(backend: backend))
        XCTAssertNil(try ScratchpadPreferenceIO.application.read(url))
        try Data("{\"cleanup\":{\"provider\":\"apple-intelligence\"},\"historyEnabled\":false}".utf8).write(to: url)
        var stale = store.load(); let base = stale
        try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false)
        stale.showHudAlways = false
        try store.save(stale, replacing: base)
        XCTAssertTrue(store.load().scratchpadDictionaryAlternativesEnabled)
        XCTAssertFalse(store.load().historyEnabled); XCTAssertFalse(store.load().showHudAlways)
        var incoming = Settings(); incoming.dictionary = ["OpenAI"]
        let preview = try VocabularyImportPreview(data: VocabularyDocument(settings: incoming).encoded(), settings: store.load())
        try store.importVocabulary(preview, mode: .merge)
        XCTAssertTrue(store.load().scratchpadDictionaryAlternativesEnabled)
        XCTAssertEqual(store.load().dictionary, ["OpenAI"])
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        let first = try store.scratchpadDictionaryConfiguration()
        var bytes = try Data(contentsOf: url)
        let string = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "OpenAI", with: "OPENAI")
        bytes = Data(string.utf8); try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        XCTAssertNotEqual(first.signature, try store.scratchpadDictionaryConfiguration().signature)
        try Data(repeating: 32, count: 1_048_577).write(to: url)
        XCTAssertThrowsError(try ScratchpadPreferenceIO.application.read(url))
        XCTAssertThrowsError(try store.setScratchpadDictionaryAlternativesEnabled(false, expected: true))
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ScratchpadPreferenceIO.application.read(directory))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try ScratchpadPreferenceIO.application.read(link))
        noCredentials(backend)
        // Wrapper verifies PID exit and ownership before removing this recorded root.
    }
    private func record(_ root: URL) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { throw ScratchpadPreferenceFailure() }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("created\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
    }
}
