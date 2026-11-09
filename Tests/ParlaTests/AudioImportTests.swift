import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import ParlaCore
@testable import Parla

private func importWAV(frames: Int = 8000, silent: Bool = false) -> Data {
    func le(_ n: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    var pcm = Data(); pcm.reserveCapacity(frames * 2)
    for i in 0..<frames { pcm += le(silent ? 0 : [Int(Int16.min), Int(Int16.max), -1, 0][i % 4], 2) }
    let format = le(1, 2) + le(1, 2) + le(16_000, 4) + le(32_000, 4) + le(2, 2) + le(16, 2)
    let chunks = Data("fmt ".utf8) + le(16, 4) + format + Data("data".utf8) + le(pcm.count, 4) + pcm
    return Data("RIFF".utf8) + le(chunks.count + 4, 4) + Data("WAVE".utf8) + chunks
}

private final class ImportDisk { var failWrite = false; var copies: [String] = [] }

/// Reaches the production C mapper/abort box with fake C getters and full entry.
private final class ImportTimedNative: @unchecked Sendable {
    let cueText: [String]
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    var starts: [Int64] = [100, 700], ends: [Int64] = [200, 800]
    var calls = 0, constructions = 0, releases = 0, probes = 0
    var timed: [Bool] = []
    var hold: (() -> Void)?
    init(cueText: [String]? = nil) {
        self.cueText = cueText ?? ["A & B --> <v X>", "NOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻"]
        for text in self.cueText {
            let bytes = Array(text.utf8CString), pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (i, byte) in bytes.enumerated() { pointer[i] = byte }
            pointers.append(pointer)
        }
    }
    deinit { for pointer in pointers { pointer.deallocate() } }
    func context() -> WhisperCContext {
        constructions += 1
        var api = WhisperCContext.API(); api.multilingual = true
        api.knowsLanguage = { ["hi", "en"].contains($0) }
        api.spokenLanguage = { self.probes += 1; return "en" }
        api.full = { params, _, count in
            self.calls += 1; self.timed.append(!params.no_timestamps)
            XCTAssertEqual(count, 128_000); XCTAssertEqual(String(cString: params.language), "hi")
            XCTAssertEqual(params.initial_prompt.map { String(cString: $0) }, "Parla")
            self.hold?(); return 0
        }
        api.count = { 2 }
        api.text = { UnsafePointer(self.pointers[Int($0)]) }
        api.start = { self.starts[Int($0)] }; api.end = { self.ends[Int($0)] }
        api.release = { self.releases += 1 }
        return WhisperCContext(api: api)
    }
    func factory() -> RecognitionFactory {
        RecognitionFactory(native: { _, _ in self.context() }, runtime: { .init(nativeVersion: "fake", buildScope: "wave7c1") },
            metadata: { _ in nil }, admit: { _, _ in })
    }
    static let expectedVTT = Data("WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nA &amp; B --&gt; &lt;v X&gt;\n\n2\n00:00:07.000 --> 00:00:08.000\nNOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻\n\n".utf8)
    static let srtCueText = [" Q&A: 5 & 6; AT&T", "NOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻"]
    static let expectedSRT = Data("1\n00:00:01,000 --> 00:00:02,000\n Q&A: 5 & 6; AT&T\n\n2\n00:00:07,000 --> 00:00:08,000\nNOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻\n\n".utf8)
    static let expectedRaw = "A & B --> <v X>NOTE STYLE REGION مرحبا 123 שלום 45 नमस्ते 👩🏽‍💻"
}

@MainActor private final class ImportRig {
    let root: URL, store: SettingsStore, history: HistoryStore, hub: HubModel
    let owner = AudioImportOwner(), admission = LocalCleanupAdmission(), probe = FoundationNativeProbe()
    let backend = FakeCredentialBackend()
    let disk = ImportDisk()
    var chain: Task<Void, Never>?, reads = 0, scopes = 0, stops = 0
    private let inode: UInt64
    init() throws {
        // Foundation may canonicalize /private/var back to the /var symlink.
        // POSIX realpath supplies a genuinely component-bound fixture spelling.
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("wave7c1-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        inode = (try FileManager.default.attributesOfItem(atPath: root.path)[.systemFileNumber] as! NSNumber).uint64Value
        try recordWave4BFixture(root, "created")
        try Self.receipt(root, action: "identity")
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        var settings = Settings(); settings.whisperModelPath = "/fake/global.bin"; settings.language = "hi"; settings.dictionary = ["Parla"]
        try store.save(settings)
        let disk = disk
        history = HistoryStore(url: root.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { data, url in
            if disk.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        hub = HubModel(store: store, history: history, clipboard: { disk.copies.append($0) },
            recordings: RecordingStore(directory: root.appendingPathComponent("recordings")), audioImport: owner)
        owner.sourceAccess.start = { [unowned self] _ in self.scopes += 1; return true }
        owner.sourceAccess.stop = { [unowned self] _ in self.stops += 1 }
        owner.sourceAccess.read = { [unowned self] fd, buffer, count in self.reads += 1; XCTAssertLessThanOrEqual(count, 65_536); return Darwin.read(fd, buffer, count) }
        owner.security = { false }
        hub.onDownloadModel = { _ in XCTFail("Import entered model download") }
        hub.onSaved = { XCTFail("Import secretly saved settings") }
        hub.retryFactory = { _, _, _, _ in XCTFail("Import requested cleanup"); throw CancellationError() }
        hub.refreshAudioImportConfiguration()
        bind()
    }
    func bind(factory: RecognitionFactory? = nil, enter: @escaping () async throws -> Void = {}) {
        let factory = factory ?? probe.factory()
        hub.onAudioImport = { [unowned self] job, done in
            if let next = AudioImportExecution.enqueue(previous: self.chain, admission: self.admission, job: job,
                store: self.store, enter: enter, load: { request in
                    try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory,
                        operation: job.operation, selectionEpoch: job.selectionEpoch, preparationEpoch: job.preparationEpoch)
                }, done: done) { self.chain = next }
        }
    }
    func file(_ name: String = "हिन्दी clip 世界.wav", bytes: Data? = nil) throws -> URL {
        let url = root.appendingPathComponent(name); try PCMMOVConnectionFixture.write(bytes ?? importWAV(),to:url); return url
    }
    func run(_ url: URL) async { hub.selectAudioImport(url); hub.startAudioImport(); await chain?.value }
    func close() async throws {
        owner.invalidate(); await chain?.value; hub.flushPendingSave()
        XCTAssertEqual(scopes, stops)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.systemFileNumber] as? NSNumber)?.uint64Value, inode)
        // External task cleanup additionally requires exited-worker/lsof/no-alias
        // evidence. Keep the exclusive root until those checks can run.
        try Self.receipt(root, action: "closed")
    }
    private static func receipt(_ root: URL, action: String) throws {
        var st = stat(); guard lstat(root.path, &st) == 0 else { throw CocoaError(.fileReadUnknown) }
        let data = try JSONSerialization.data(withJSONObject: ["uid": st.st_uid, "inode": st.st_ino,
            "mode": st.st_mode, "birthSec": st.st_birthtimespec.tv_sec, "birthNS": st.st_birthtimespec.tv_nsec,
            "mtimeSec": st.st_mtimespec.tv_sec, "mtimeNS": st.st_mtimespec.tv_nsec], options: [.sortedKeys])
        try recordWave4BFixture(root, action + ":" + String(decoding: data, as: UTF8.self))
    }
}

final class AudioImportTests: XCTestCase {
    @MainActor func testT01SelectionRenderPickerCancelAndExplicitStartUseActualPipeline() async throws {
        let r = try ImportRig(), url = try r.file(), bytes = try Data(contentsOf: url)
        r.hub.audioImportPicker = { url }; r.hub.chooseAudioImport()
        XCTAssertNotNil(r.owner.source, r.owner.message ?? "no selection status"); XCTAssertEqual(r.reads, 0); XCTAssertTrue(r.probe.paths.isEmpty)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.owner.source?.displayName.contains("हिन्दी clip 世界") == true)
        r.hub.audioImportPicker = { nil }; r.hub.chooseAudioImport(); r.hub.refreshAudioImportConfiguration()
        XCTAssertNotNil(r.owner.source); XCTAssertEqual(r.reads, 0)
        r.hub.startAudioImport(); await r.chain?.value
        XCTAssertEqual(r.owner.review?.entry.raw, "native original"); XCTAssertEqual(r.probe.admissions, 1)
        XCTAssertEqual(r.probe.paths, ["/fake/global.bin"]); XCTAssertEqual(r.probe.calls.first?.language, "hi")
        XCTAssertEqual(r.probe.calls.first?.prompt, "Parla"); XCTAssertEqual(r.probe.releases, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertTrue(r.history.entries.isEmpty)
        XCTAssertTrue(r.disk.copies.isEmpty)
        r.hub.copyAudioImport(); XCTAssertEqual(r.disk.copies, ["native original"])
        XCTAssertEqual(r.stops, 1); XCTAssertTrue(try XCTUnwrap(r.owner.job).source.isClosed)
        XCTAssertTrue(try XCTUnwrap(r.owner.job).operation.hasExited)
        try await r.close()
    }
    @MainActor func testT02ExactSourceFramesAndRawOnlyProjectionSnapshotNoPathWatch() async throws {
        let r = try ImportRig(); r.probe.outputs = [.init(status: 0, segments: ["  um, नमस्ते 世界  "])]
        let url = try r.file(); await r.run(url)
        let expected = try ImportedWAV.decode(importWAV())
        XCTAssertEqual(r.probe.calls.first?.samples, expected); XCTAssertEqual(r.probe.calls.count, 1)
        let text = try XCTUnwrap(r.owner.review?.entry.raw)
        XCTAssertTrue(text.contains("um,")); XCTAssertTrue(text.contains("नमस्ते"))
        try Data("later mutable path is unrelated".utf8).write(to: url)
        var copies: [String] = []; r.owner.copy { copies.append($0) }
        XCTAssertEqual(copies, [text]); r.hub.saveAudioImport()
        XCTAssertEqual(r.history.entries.first?.raw, text); XCTAssertNil(r.history.entries.first?.cleaned)
        XCTAssertNil(r.history.entries.first?.appName); XCTAssertNil(r.history.entries.first?.metrics?.cleanupMs)
        XCTAssertEqual(r.probe.calls.count, 1)
        try await r.close()
    }
    @MainActor func testT03FloorAndT04InvalidInputNeverAcquireOrPublishPrefix() async throws {
        let r = try ImportRig()
        for bytes in [importWAV(silent: true), importWAV(frames: 6399), Data("not WAV".utf8), Data(importWAV().dropLast())] {
            await r.run(try r.file(bytes: bytes)); XCTAssertNil(r.owner.review)
            XCTAssertFalse(r.owner.busy); XCTAssertTrue(r.probe.paths.isEmpty)
        }
        r.hub.selectAudioImport(try r.file("other.mp3")); XCTAssertNil(r.owner.source)
        await r.run(try r.file()); XCTAssertEqual(r.probe.calls.count, 1)
        try await r.close()
    }
    @MainActor func testT05DescriptorReplacementMutationSymlinksNonregularAndMetadataRefusal() async throws {
        let r = try ImportRig(), url = try r.file()
        let gate = RecognitionTestLatch(); r.chain = Task { await gate.wait() }
        r.hub.selectAudioImport(url); r.hub.startAudioImport()
        try FileManager.default.removeItem(at: url); try importWAV().write(to: url)
        gate.signal(); await r.chain?.value
        XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        r.hub.selectAudioImport(url)
        let file = try FileHandle(forWritingTo: url); try file.seek(toOffset: 45); try file.write(contentsOf: Data([1, 2])); try file.close()
        r.hub.startAudioImport(); await r.chain?.value
        XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        let link = r.root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        r.hub.selectAudioImport(link); XCTAssertNil(r.owner.source)
        let parent = r.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: r.root)
        r.hub.selectAudioImport(parent.appendingPathComponent(url.lastPathComponent)); XCTAssertNil(r.owner.source)
        // Remove only these two deliberately authored link entries, never their targets.
        try FileManager.default.removeItem(at: link); try FileManager.default.removeItem(at: parent)
        let directory = r.root.appendingPathComponent("directory.wav"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        r.hub.selectAudioImport(directory); XCTAssertNil(r.owner.source)
        let fifo = r.root.appendingPathComponent("pipe.wav"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        r.hub.selectAudioImport(fifo); XCTAssertNil(r.owner.source)
        r.owner.sourceAccess.metadata = { _, _ in throw FileImportSource.Failure.unsafe }
        r.hub.selectAudioImport(url); XCTAssertNil(r.owner.source)
        XCTAssertEqual(r.scopes, r.stops)
        try await r.close()
    }
    @MainActor func testT05ShortProgressReadFailureAndMutationDuringRead() async throws {
        for variant in 0..<4 {
            let r = try ImportRig(), url = try r.file()
            var calls = 0
            r.owner.sourceAccess.read = { fd, buffer, count in
                calls += 1
                if variant == 0 { return Darwin.read(fd, buffer, min(count, 7)) }
                if variant == 1 { return 0 }
                if variant == 2 { return -1 }
                if calls == 1 {
                    let writer = Darwin.open(url.path, O_WRONLY)
                    var value: UInt8 = 0; _ = pwrite(writer, &value, 1, 45); Darwin.close(writer)
                }
                return Darwin.read(fd, buffer, count)
            }
            await r.run(url)
            if variant == 0 { XCTAssertNotNil(r.owner.review); XCTAssertGreaterThan(calls, 2) }
            else { XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty) }
            try await r.close()
        }
    }
    @MainActor func testT05OrdinaryReadableWithoutScopeAndEscapedDisplayMissingAndGrowth() async throws {
        let r = try ImportRig(), url = try r.file("Unicode \u{202e}\n clip.wav")
        r.owner.sourceAccess.start = { _ in false }
        r.owner.sourceAccess.stop = { _ in XCTFail("Unacquired scope was stopped") }
        r.hub.selectAudioImport(url)
        XCTAssertTrue(try XCTUnwrap(r.owner.source).displayName.contains("\\u{202e}"))
        r.hub.startAudioImport(); await r.chain?.value
        XCTAssertNotNil(r.owner.review)
        r.hub.selectAudioImport(r.root.appendingPathComponent("missing.wav")); XCTAssertNil(r.owner.source)
        let growth = try r.file("growth.wav")
        r.hub.selectAudioImport(growth)
        let file = try FileHandle(forWritingTo: growth); try file.seekToEnd(); try file.write(contentsOf: Data([0, 0])); try file.close()
        r.hub.startAudioImport(); await r.chain?.value
        XCTAssertNil(r.owner.review); XCTAssertEqual(r.probe.calls.count, 1)
        let huge = try r.file("large.wav", bytes: Data(repeating: 0, count: ImportedWAV.maximumBytes + 1))
        r.hub.selectAudioImport(huge); XCTAssertNil(r.owner.source)
        XCTAssertEqual(r.scopes, 0); XCTAssertEqual(r.stops, 0)
        try await r.close()
    }
    @MainActor func testT06QueuedCancellationSettlesAndHeldReaderRetainsScopeUntilExit() async throws {
        let r = try ImportRig(), url = try r.file(), gate = RecognitionTestLatch()
        let predecessorHold = MOVTestHold("selected transient predecessor",release:{gate.signal()})
        defer {predecessorHold.release()}
        r.chain = Task { await gate.wait() }
        r.hub.selectAudioImport(url); r.hub.startAudioImport(); let queued = try XCTUnwrap(r.owner.job)
        r.hub.discardAudioImport(); XCTAssertEqual(r.stops, 1); XCTAssertFalse(queued.operation.hasExited)
        predecessorHold.release()
        guard await observeMOVCompletion(self,"selected transient predecessor exit",work:{await r.chain?.value}) else {
            r.owner.invalidate(); try recordWave4BFixture(r.root,"selected-transient-predecessor-exit-unobserved-preserved"); return
        }
        XCTAssertTrue(queued.operation.hasExited); XCTAssertFalse(r.owner.busy); XCTAssertTrue(r.probe.paths.isEmpty)
        let entered = expectation(description: "actual fd read held")
        let readerHold = MOVTestHold("selected transient reader")
        defer {readerHold.release()}
        var first = true
        r.owner.sourceAccess.read = { fd, buffer, count in
            if first { first = false; readerHold.wait(entered:entered) }
            return Darwin.read(fd, buffer, count)
        }
        r.hub.selectAudioImport(url); r.hub.startAudioImport()
        await fulfillment(of: [entered], timeout: 3)
        guard readerHold.hasEntered else {
            readerHold.release(); r.owner.invalidate(); try recordWave4BFixture(r.root,"selected-transient-reader-unobserved-preserved"); return
        }
        let held = try XCTUnwrap(r.owner.job)
        r.hub.discardAudioImport(); XCTAssertFalse(held.source.isClosed); XCTAssertEqual(r.stops, 1)
        r.hub.selectAudioImport(url); XCTAssertNil(r.owner.source)
        var nextEntered = false
        let next = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "ordinary next"), completes: true, work: {
            await MainActor.run { nextEntered = true }
        })
        XCTAssertFalse(nextEntered); readerHold.release()
        guard await observeMOVCompletion(self,"selected transient reader and next exit",work:{await next.value; await r.chain?.value}) else {
            r.owner.invalidate(); try recordWave4BFixture(r.root,"selected-transient-reader-exit-unobserved-preserved"); return
        }
        XCTAssertTrue(nextEntered); XCTAssertTrue(held.source.isClosed); XCTAssertEqual(r.stops, 2)
        XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        try await r.close()
    }
    @MainActor func testT06NoncooperativeConstructorAndNativeDecodeHoldActualBarrier() async throws {
        for constructing in [true, false] {
            let r = try ImportRig(), entered = expectation(description: "native bottom held"), exit = DispatchSemaphore(value: 0)
            let hold = { entered.fulfill(); exit.wait() }
            if constructing { r.probe.construct = hold } else { r.probe.decode = hold }
            await MainActor.run { r.hub.selectAudioImport(try! r.file()); r.hub.startAudioImport() }
            await fulfillment(of: [entered], timeout: 3)
            let job = try XCTUnwrap(r.owner.job)
            r.hub.discardAudioImport(); XCTAssertFalse(job.operation.hasExited); XCTAssertTrue(job.source.isClosed)
            var nextEntered = false
            let next = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "ordinary queued"), completes: true, work: {
                await MainActor.run { nextEntered = true }
            })
            XCTAssertFalse(nextEntered); exit.signal(); await next.value; await r.chain?.value
            XCTAssertTrue(nextEntered); XCTAssertNil(r.owner.review); XCTAssertEqual(r.probe.releases, 1)
            XCTAssertEqual(r.probe.live, 0); XCTAssertEqual(r.probe.peakLive, 1)
            try await r.close()
        }
    }
    @MainActor func testT07DraftAndAwayBackInvalidityNeverReviveButUnchangedRefreshPreserves() async throws {
        let r = try ImportRig(), url = try r.file()
        var deliberateNormalSaves = 0
        r.hub.onSaved = { deliberateNormalSaves += 1 }
        await r.run(url); let token = try XCTUnwrap(r.owner.review?.job.resultID)
        r.hub.refreshAudioImportConfiguration(); XCTAssertEqual(r.owner.review?.job.resultID, token)
        r.hub.settings.language = "en"; r.hub.settings.language = "hi"
        XCTAssertNil(r.owner.review); r.hub.flushPendingSave(); r.hub.refreshAudioImportConfiguration()
        r.hub.copyAudioImport(); r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        await r.run(url); r.hub.words[0].text = "Changed before debounce"
        XCTAssertNil(r.owner.review); r.hub.flushPendingSave()
        await r.run(url)
        let good = try Data(contentsOf: r.store.url); try Data("bad".utf8).write(to: r.store.url)
        r.hub.copyAudioImport(); XCTAssertNil(r.owner.review)
        try good.write(to: r.store.url); r.hub.refreshAudioImportConfiguration(); XCTAssertNil(r.owner.review)
        await r.run(url); r.hub.saveError = "injected normal save failure"; r.hub.saveError = nil
        XCTAssertNil(r.owner.review)
        // An unrelated pending draft blocks Start without flushing or revoking an unchanged selection.
        r.hub.selectAudioImport(url); let bytes = try Data(contentsOf: r.store.url)
        r.hub.settings.showHudAlways.toggle(); r.hub.startAudioImport()
        XCTAssertNotNil(r.owner.source); XCTAssertEqual(try Data(contentsOf: r.store.url), bytes)
        r.hub.flushPendingSave(); r.hub.startAudioImport(); await r.chain?.value
        XCTAssertNotNil(r.owner.review)
        var settings = try r.store.savedRetrySnapshot(); settings.language = "en"; try r.store.save(settings)
        settings.language = "hi"; try r.store.save(settings)
        XCTAssertNil(r.owner.review)
        XCTAssertEqual(deliberateNormalSaves, 2) // explicit normal vocabulary/HUD saves only
        try await r.close()
    }
    @MainActor func testT08ClosedEnginesMissingModelAndFrozenGlobalRequestNoFallback() async throws {
        let r = try ImportRig(), url = try r.file()
        var settings = try r.store.savedRetrySnapshot(); settings.recognitionEngine = .appleSpeech; settings.appleSpeechLocale = "en-US"
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        await r.run(url); XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        settings.recognitionEngine = .parakeet; try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        await r.run(url); XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        settings.recognitionEngine = .whisper; try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        r.probe.admission = { _, _ in throw FileImportSource.Failure.unavailable }
        await r.run(url); XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        r.probe.admission = nil; await r.run(url)
        XCTAssertEqual(r.probe.calls.count, 1); XCTAssertEqual(r.probe.calls.first?.language, "hi")
        XCTAssertEqual(r.owner.job?.configuration.request, RecognitionRequest(settings: settings))
        try await r.close()
    }
    @MainActor func testT09EmptyFailureOversizeAndFinishedHandoffCannotPublishOrCopy() async throws {
        let r = try ImportRig(), url = try r.file()
        for output in [WhisperNativeDecode(status: 0, segments: []), .init(status: 0, segments: ["  \n\t "]),
                       .init(status: -1, segments: ["bad"]), .init(status: 0, segments: [String(repeating: "é", count: 524_289)])] {
            r.probe.outputs = [output]; await r.run(url); XCTAssertNil(r.owner.review); XCTAssertTrue(r.history.entries.isEmpty)
        }
        r.probe.outputs = [.init(status: 0, segments: ["raw"])]
        var publish: (() -> Void)?; r.owner.publication = { publish = $0 }
        await r.run(url); XCTAssertTrue(try XCTUnwrap(r.owner.job).operation.hasExited); XCTAssertNil(r.owner.review)
        r.hub.discardAudioImport(); publish?(); XCTAssertNil(r.owner.review)
        r.owner.publication = { $0() }; await r.run(url)
        XCTAssertNotNil(r.owner.review); r.owner.security = { true }; r.hub.copyAudioImport()
        XCTAssertNil(r.owner.review); r.owner.security = { false }; r.hub.saveAudioImport()
        XCTAssertTrue(r.history.entries.isEmpty)
        try await r.close()
    }
    @MainActor func testT07PreparationEpochAndT09AlreadyObservedStaleSecurityAreIrreversible() async throws {
        let r = try ImportRig(), url = try r.file()
        var epoch: UUID? = UUID()
        r.hub.audioImportPreparationEpoch = { epoch }
        await r.run(url); let original = epoch
        XCTAssertNotNil(r.owner.review)
        epoch = UUID(); r.hub.copyAudioImport(); XCTAssertNil(r.owner.review); XCTAssertTrue(r.disk.copies.isEmpty)
        epoch = original; r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        await r.run(url); XCTAssertNotNil(r.owner.review)
        r.owner.observe(.focusSampled(gen: -100, focus: .secure))
        XCTAssertNil(r.owner.review); r.hub.copyAudioImport(); r.hub.saveAudioImport()
        XCTAssertTrue(r.disk.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await r.close()
    }
    @MainActor func testT10HistoryPolicyDiskOnlyRetryPermanentSavedLatch() async throws {
        let r = try ImportRig(), url = try r.file()
        var settings = try r.store.savedRetrySnapshot(); settings.historyEnabled = false
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration(); await r.run(url)
        let entry = try XCTUnwrap(r.owner.review?.entry); let reads = r.reads
        r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        settings.historyEnabled = true; settings.historyTextCount = 1; try r.store.save(settings)
        r.hub.refreshAudioImportConfiguration(); XCTAssertEqual(r.owner.review?.entry, entry)
        // Real History atomic-write failure, with controller retaining the only retry copy.
        let old = HistoryEntry(raw: "previous committed text"); XCTAssertTrue(r.history.append(old))
        let oldBytes = try Data(contentsOf: r.history.url)
        r.disk.failWrite = true
        r.hub.saveAudioImport(); XCTAssertEqual(r.owner.review?.saveFailed, true)
        XCTAssertEqual(try Data(contentsOf: r.history.url), oldBytes)
        XCTAssertTrue(r.history.pendingEntries.isEmpty); XCTAssertFalse(r.history.retrySave(entry.id))
        r.disk.failWrite = false
        r.hub.saveAudioImport(); r.hub.saveAudioImport()
        XCTAssertEqual(r.history.entries, [entry]); XCTAssertEqual(r.owner.review?.saved, true)
        XCTAssertTrue(r.history.delete(entry.id)); r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        XCTAssertEqual(r.reads, reads); XCTAssertEqual(r.probe.calls.count, 1)
        try await r.close()
    }
    @MainActor func testT11ActualTerminationAndRestartIntentNeverReviveFinishedReview() async throws {
        let r = try ImportRig(), url = try r.file(); await r.run(url)
        let coordinator = TerminationCoordinator(clipboard: { $0(false) }, updater: { $0(true) },
            localCleanup: { r.admission.beginShutdown(chain: { r.chain }, reply: $0) }, cancelLocalCleanup: r.admission.cancelShutdown,
            cancelClipboard: {}, cancelUpdater: {}, reply: { _ in XCTFail("Synchronous canceled intent") }, failure: {},
            onIntent: { r.owner.invalidate("Quit intent") })
        XCTAssertEqual(coordinator.request(), .terminateCancel); XCTAssertNil(r.owner.review)
        await r.run(url); XCTAssertNotNil(r.owner.review)
        r.owner.invalidate("Restart intent"); XCTAssertTrue(r.admission.reserveRestart())
        let updater = UpdateTerminationIntent(); var released = false
        XCTAssertFalse(updater.installFailed(releaseRestart: { r.admission.releaseRestart(); released = true }))
        XCTAssertTrue(released); r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        await r.run(url); XCTAssertNotNil(r.owner.review)
        try await r.close()
    }
    @MainActor func testT11HeldImportComposesWithActualPreparationAndQuitParticipantsOffAndOn() async throws {
        for enabled in [false, true] {
            let r = try ImportRig(), prep = try PreparationAppRig(enabled: enabled)
            var settings = try prep.store.savedRetrySnapshot(); settings.language = "en"
            try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
            r.hub.modelSelectionEpoch = prep.epoch
            r.hub.audioImportPreparationEpoch = { prep.owner.core.admissionEpoch }
            let entered = expectation(description: "held imported native"), exit = DispatchSemaphore(value: 0)
            prep.probe.outputs = [.init(status: 0, segments: ["raw held import"])]
            prep.probe.decode = { entered.fulfill(); exit.wait() }
            r.bind(factory: prep.factory)
            r.hub.selectAudioImport(try r.file()); r.hub.startAudioImport()
            await fulfillment(of: [entered], timeout: 3)
            let job = try XCTUnwrap(r.owner.job)
            let replied = expectation(description: "once-only composed reply")
            var replies: [Bool] = [], clipboard: ((Bool) -> Void)?
            let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { $0(true) },
                preparation: { prep.owner.beginShutdown(chain: { r.chain }, reply: $0) }, cancelPreparation: prep.owner.cancelShutdown,
                localCleanup: { r.admission.beginShutdown(chain: { r.chain }, reply: $0) }, cancelLocalCleanup: r.admission.cancelShutdown,
                cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); replied.fulfill() }, failure: {},
                onIntent: { r.owner.invalidate("Quit intent") })
            XCTAssertEqual(coordinator.request(), .terminateLater); XCTAssertEqual(coordinator.request(), .terminateLater)
            XCTAssertFalse(job.operation.hasExited); XCTAssertFalse(job.current); XCTAssertTrue(replies.isEmpty)
            XCTAssertFalse(r.admission.admit(PendingOperation(name: "late")))
            clipboard?(false)
            await fulfillment(of: [replied], timeout: 3)
            XCTAssertEqual(replies, [false]); XCTAssertFalse(job.operation.hasExited)
            exit.signal(); await r.chain?.value
            XCTAssertNil(r.owner.review); XCTAssertTrue(job.operation.hasExited); XCTAssertEqual(prep.probe.releases, 1)
            r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
            try await prep.close(); try await r.close()
        }
    }
    @MainActor func testT12SavedRawUsesResultTimeAndActualHistoryExportWithoutCleanup() async throws {
        let r = try ImportRig(), url = try r.file(); r.owner.clock = { Date(timeIntervalSinceReferenceDate: 1234) }
        await r.run(url); r.hub.saveAudioImport()
        let entry = try XCTUnwrap(r.history.entries.first)
        XCTAssertEqual(entry.date, Date(timeIntervalSinceReferenceDate: 1234)); XCTAssertNil(entry.appName)
        XCTAssertNil(entry.cleaned); XCTAssertNil(entry.retries); XCTAssertNil(entry.operation)
        r.hub.prepareHistoryExport(rowID: entry.id)
        let exported = r.root.appendingPathComponent("review.txt")
        r.hub.historyExportPanel = { _ in exported }
        r.hub.exportHistory(content: .original, format: .text)
        XCTAssertTrue(try String(contentsOf: exported).contains(entry.raw))
        XCTAssertNil(r.hub.historyExport)
        XCTAssertFalse(String(describing: entry).contains(url.path))
        let diagnostics = try r.hub.diagnostics.snapshot().encoded()
        XCTAssertTrue(String(decoding: diagnostics, as: UTF8.self).contains("fileImport"))
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains(url.path))
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains(url.lastPathComponent))
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains(entry.raw))
        var settings = try r.store.savedRetrySnapshot(); settings.cleanupEnabled = false
        settings.replacements = [.init(source: "native", replacement: "reviewed")]
        try r.store.save(settings); r.hub.retryEnvironment = { [:] }
        r.hub.prepareHistoryRetry(entry.id)
        XCTAssertNil(r.hub.historyRetries[entry.id]?.proposed) // explicit review alone performs no cleanup
        await r.hub.startHistoryRetry(entry.id)
        XCTAssertEqual(r.hub.historyRetries[entry.id]?.proposed, "reviewed original")
        XCTAssertEqual(r.history.entries.first?.raw, entry.raw); XCTAssertNil(r.history.entries.first?.cleaned)
        XCTAssertEqual(r.probe.calls.count, 1)
        try await r.close()
    }
}

private func rateImportWAV(_ rate: Int = 44_100, frames: Int = 17_641) -> Data {
    var bytes = importWAV(frames: frames)
    for (offset, value) in [(24, rate), (28, rate * 2)] {
        bytes.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    return bytes
}

extension AudioImportTests {
    @MainActor private func timedRig(cueText: [String]? = nil) throws -> (ImportRig, ImportTimedNative, URL) {
        let r = try ImportRig(), p = ImportTimedNative(cueText: cueText)
        r.bind(factory: p.factory())
        return (r, p, try r.file(bytes: importWAV(frames: 128_000)))
    }
    @MainActor private func runTimed(_ r: ImportRig, _ url: URL) async {
        r.hub.selectAudioImport(url); r.hub.startTimedAudioImport(); await r.chain?.value
    }
    @MainActor func testB47T5T7T9T13ActualSourceQueueReviewAtomicVTTAndTextOnlyHistory() async throws {
        let (r, p, url) = try timedRig()
        // Connected ordinary positive with exactly the same bottom, source and stores.
        await r.run(url); XCTAssertEqual(p.timed, [false]); XCTAssertNil(r.owner.review?.segments)
        XCTAssertEqual(r.owner.review?.entry.raw, ImportTimedNative.expectedRaw)
        await runTimed(r, url)
        let review = try XCTUnwrap(r.owner.review), reads = r.reads
        XCTAssertEqual(review.job.mode, .experimentalTimed); XCTAssertTrue(review.job.operation.hasExited)
        XCTAssertTrue(review.job.source.isClosed); XCTAssertEqual(p.releases, 2)
        XCTAssertEqual(review.sourceInfo.origin, .strictPCM16k); XCTAssertEqual(review.sourceInfo.sourceFrames, 128_000)
        XCTAssertEqual(review.segments?.sourceSampleCount, 128_000)
        XCTAssertEqual(review.segments?.cues.map(\.text), p.cueText)
        XCTAssertEqual(review.entry.id, review.job.resultID); XCTAssertEqual(p.timed, [false, true]); XCTAssertEqual(p.probes, 0)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.disk.copies.isEmpty)
        // Immutable source PCM already consumed; later pathname edits do not change export.
        try Data("later file contents".utf8).write(to: url)
        var settings = try r.store.savedRetrySnapshot(); settings.historyEnabled = false
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        let destination = r.root.appendingPathComponent("native.vtt")
        r.hub.audioImportExportPanel = { name in XCTAssertEqual(name, "Parla-native-segments.vtt"); return destination }
        r.hub.exportAudioImportVTT()
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedVTT)
        r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        r.hub.copyAudioImport(); XCTAssertEqual(r.disk.copies, [ImportTimedNative.expectedRaw])
        settings.historyEnabled = true; try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        r.disk.failWrite = true; r.hub.saveAudioImport(); XCTAssertEqual(r.owner.review?.saveFailed, true)
        r.disk.failWrite = false; r.hub.saveAudioImport(); r.hub.saveAudioImport()
        XCTAssertEqual(r.history.entries, [review.entry]); XCTAssertEqual(r.owner.review?.saved, true)
        let stored = String(decoding: try Data(contentsOf: r.history.url), as: UTF8.self)
        XCTAssertFalse(stored.contains("segments")); XCTAssertFalse(stored.contains("sourceSampleCount")); XCTAssertFalse(stored.contains(url.path))
        XCTAssertTrue(r.history.delete(review.entry.id)); r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        r.hub.exportAudioImportVTT(); XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedVTT)
        XCTAssertEqual(p.calls, 2); XCTAssertEqual(r.reads, reads)
        r.hub.discardAudioImport(); var panels = 0
        r.hub.audioImportExportPanel = { _ in panels += 1; return destination }; r.hub.exportAudioImportVTT()
        XCTAssertEqual(panels, 0); XCTAssertNil(r.owner.review)
        try await r.close()
    }
    @MainActor func testB47T7CancelFailureExplicitDiskRetryAndInvalidTimingKeepReview() async throws {
        let (r, p, url) = try timedRig(); await runTimed(r, url)
        let token = r.owner.review?.entry.id, destination = r.root.appendingPathComponent("retry.vtt")
        let previous = Data("previous destination bytes".utf8); try previous.write(to: destination)
        let atomic = r.hub.historyExportWriter; var writes = 0
        r.hub.historyExportWriter = { _, _ in writes += 1; throw CocoaError(.fileWriteOutOfSpace) }
        r.hub.audioImportExportPanel = { _ in nil }; r.hub.exportAudioImportVTT(); XCTAssertEqual(writes, 0)
        r.hub.audioImportExportPanel = { _ in destination }; r.hub.exportAudioImportVTT()
        XCTAssertEqual(writes, 1); XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(r.owner.review?.entry.id, token); XCTAssertEqual(p.calls, 1)
        XCTAssertFalse((r.owner.message ?? "").contains(destination.path))
        r.hub.historyExportWriter = atomic; r.hub.exportAudioImportVTT()
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedVTT); XCTAssertEqual(p.calls, 1)
        p.ends[1] = 801; await runTimed(r, url)
        XCTAssertEqual(r.owner.review?.entry.raw, ImportTimedNative.expectedRaw); XCTAssertNil(r.owner.review?.segments)
        var panels = 0; r.hub.audioImportExportPanel = { _ in panels += 1; return destination }
        r.hub.exportAudioImportVTT(); XCTAssertEqual(panels, 0); XCTAssertEqual(p.calls, 2)
        r.hub.copyAudioImport(); XCTAssertEqual(r.disk.copies, [ImportTimedNative.expectedRaw])
        try await r.close()
    }
    @MainActor func testB47T7ActualGuardProtectsSourceSettingsHistoryRecordingAndResolvedAliasesEvenFakeWriter() async throws {
        for srt in [false, true] {
            let (r, p, url) = try timedRig(cueText: srt ? ImportTimedNative.srtCueText : nil); await runTimed(r, url)
            let ext = srt ? "srt" : "vtt"
            let export = { if srt { r.hub.exportAudioImportSRT() } else { r.hub.exportAudioImportVTT() } }
            let sourceBytes = try Data(contentsOf: url), settingsBytes = try Data(contentsOf: r.store.url)
            let historyBytes = Data("existing history".utf8); try historyBytes.write(to: r.history.url)
            let recordings = r.root.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false)
            let recording = recordings.appendingPathComponent("one.wav"); try Data("recording".utf8).write(to: recording)
            var destinations = [url, r.store.url, r.history.url, recording, recordings.appendingPathComponent("new.\(ext)"), r.root.appendingPathComponent("wrong.txt")]
            var links: [URL] = []
            for (index, target) in [url, r.store.url, r.history.url, recordings].enumerated() {
                let link = r.root.appendingPathComponent("alias\(index).\(ext)")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target); links.append(link)
                destinations.append(index == 3 ? link.appendingPathComponent("nested.\(ext)") : link)
            }
            let outward = r.root.appendingPathComponent("outward.\(ext)"); try Data("outward".utf8).write(to: outward)
            let outLink = recordings.appendingPathComponent("outward-link")
            try FileManager.default.createSymbolicLink(at: outLink, withDestinationURL: outward); links.append(outLink); destinations.append(outward)
            var writes = 0; r.hub.historyExportWriter = { _, _ in writes += 1 }
            for destination in destinations {
                var panels = 0
                r.hub.audioImportExportPanel = { _ in panels += 1; return destination }; export()
                XCTAssertEqual(panels, 1)
                XCTAssertEqual(writes, 0); XCTAssertNotNil(r.owner.review)
            }
            // A new filename under a resolved parent alias of the source's parent
            // still cannot replace that original source spelling.
            let parent = r.root.appendingPathComponent("parent")
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: r.root); links.append(parent)
            var parentPanels = 0
            r.hub.audioImportExportPanel = { _ in parentPanels += 1; return parent.appendingPathComponent(url.lastPathComponent) }; export()
            XCTAssertEqual(parentPanels, 1); XCTAssertEqual(writes, 0)
            r.hub.audioImportExportPanel = { _ in r.root.appendingPathComponent("safe.\(ext.uppercased())") }; export()
            XCTAssertEqual(writes, 1, "Connected safe destination reaches the injected writer")
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes); XCTAssertEqual(try Data(contentsOf: r.store.url), settingsBytes)
            XCTAssertEqual(try Data(contentsOf: r.history.url), historyBytes); XCTAssertEqual(try Data(contentsOf: recording), Data("recording".utf8))
            XCTAssertEqual(p.calls, 1)
            for link in links { try FileManager.default.removeItem(at: link) }
            try await r.close()
        }
    }
    @MainActor func testB47T8PostPanelAuthorityRefusesIrreversiblyAcrossActualHubBoundaries() async throws {
        for srt in [false, true] {
            let (r, p, url) = try timedRig(cueText: srt ? ImportTimedNative.srtCueText : nil)
            let ext = srt ? "srt" : "vtt"
            let export = { if srt { r.hub.exportAudioImportSRT() } else { r.hub.exportAudioImportVTT() } }
            var epoch: UUID? = UUID(); r.hub.audioImportPreparationEpoch = { epoch }
            r.hub.onSaved = {}
            let changes: [(ImportRig) throws -> Void] = [
                { $0.hub.settings.language = "en"; $0.hub.settings.language = "hi" },
                { $0.hub.words[0].text = "new draft" },
                { $0.hub.settings.showHudAlways.toggle() },
                { try Data("invalid saved configuration".utf8).write(to: $0.store.url) },
                { $0.owner.security = { true } },
                { $0.owner.observe(.focusSampled(gen: -400, focus: .secure)) },
                { $0.hub.discardAudioImport() },
                { $0.hub.selectAudioImport(url) },
                { _ in epoch = UUID() },
                { rig in
                    let coordinator = TerminationCoordinator(clipboard: { $0(false) }, updater: { $0(true) },
                        cancelClipboard: {}, cancelUpdater: {}, reply: { _ in }, failure: {}, onIntent: { rig.owner.invalidate("Quit intent") })
                    XCTAssertEqual(coordinator.request(), .terminateCancel)
                },
                { $0.owner.invalidate("Window/page/restart intent") }
            ]
            for change in changes {
                let good = try Data(contentsOf: r.store.url), oldEpoch = epoch
                r.owner.security = { false }; await runTimed(r, url); XCTAssertNotNil(r.owner.review)
                var writes = 0, panels = 0, panelError: Error?
                r.hub.historyExportWriter = { _, _ in writes += 1 }
                r.hub.audioImportExportPanel = { _ in
                    panels += 1
                    do { try change(r) } catch { panelError = error }
                    return r.root.appendingPathComponent("stale.\(ext)")
                }
                export(); XCTAssertEqual(panels, 1); XCTAssertNil(panelError); XCTAssertEqual(writes, 0)
                // Revert cannot revive the frozen request or old review.
                r.owner.security = { false }; epoch = oldEpoch
                r.hub.flushPendingSave(); try good.write(to: r.store.url); r.hub.refreshAudioImportConfiguration()
                XCTAssertNil(r.owner.review); export(); XCTAssertEqual(writes, 0)
            }
            // Unchanged refresh during a reentrant panel preserves the same result.
            await runTimed(r, url); let token = r.owner.review?.entry.id; var writes = 0
            r.hub.historyExportWriter = { data, _ in writes += 1; XCTAssertEqual(data, srt ? ImportTimedNative.expectedSRT : ImportTimedNative.expectedVTT) }
            r.hub.audioImportExportPanel = { _ in r.hub.refreshAudioImportConfiguration(); return r.root.appendingPathComponent("current.\(ext)") }
            export(); XCTAssertEqual(writes, 1); XCTAssertEqual(r.owner.review?.entry.id, token)
            XCTAssertEqual(p.probes, 0)
            try await r.close()
        }
    }
    @MainActor func testB47T8NewReviewDuringPanelNeverSubstitutesItsBytes() async throws {
        for srt in [false, true] {
            let (r, p, url) = try timedRig(cueText: srt ? ImportTimedNative.srtCueText : nil); await runTimed(r, url)
            let ext = srt ? "srt" : "vtt"
            let export = { if srt { r.hub.exportAudioImportSRT() } else { r.hub.exportAudioImportVTT() } }
            let old = try XCTUnwrap(r.owner.review); var newerID: UUID?, writes = 0, panels = 0
            r.hub.historyExportWriter = { _, _ in writes += 1 }
            r.hub.audioImportExportPanel = { _ in
                panels += 1
                r.owner.select(url)
                let newer = r.owner.start(settings: r.hub.settings, selectionEpoch: r.hub.modelSelectionEpoch,
                    preparationEpoch: nil, diagnostics: r.hub.diagnostics, mode: .experimentalTimed)!
                newerID = newer.resultID
                newer.source.cancel(); newer.operation.finish()
                r.owner.complete(newer, result: .success(.init(raw: "new review", sourceInfo: old.sourceInfo, segments: old.segments)))
                return r.root.appendingPathComponent("stale.\(ext)")
            }
            export(); XCTAssertEqual(panels, 1); XCTAssertEqual(writes, 0)
            XCTAssertEqual(r.owner.review?.entry.id, newerID); XCTAssertNotEqual(newerID, old.entry.id)
            XCTAssertEqual(r.owner.review?.entry.raw, "new review"); XCTAssertEqual(p.calls, 1)
            r.hub.historyExportWriter = { data, _ in
                writes += 1; XCTAssertEqual(data, srt ? ImportTimedNative.expectedSRT : ImportTimedNative.expectedVTT)
            }
            r.hub.audioImportExportPanel = { _ in r.root.appendingPathComponent("current.\(ext)") }
            export(); XCTAssertEqual(writes, 1); XCTAssertEqual(r.owner.review?.entry.id, newerID)
            try await r.close()
        }
    }
    @MainActor func testB47T6HeldTimedDecodeAndFinishedPublicationRevocationUseActualQueue() async throws {
        let (r, p, url) = try timedRig(), entered = expectation(description: "held timed C full"), exit = DispatchSemaphore(value: 0)
        p.hold = { entered.fulfill(); exit.wait() }
        r.hub.selectAudioImport(url); r.hub.startTimedAudioImport()
        await fulfillment(of: [entered], timeout: 3)
        let job = try XCTUnwrap(r.owner.job)
        r.hub.discardAudioImport(); XCTAssertFalse(job.operation.hasExited); XCTAssertEqual(p.releases, 0)
        var nextEntered = false
        let next = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "after timed"), completes: true) { await MainActor.run { nextEntered = true } }
        XCTAssertFalse(nextEntered); exit.signal(); await next.value; await r.chain?.value
        XCTAssertTrue(nextEntered); XCTAssertEqual(p.releases, 1); XCTAssertNil(r.owner.review)
        p.hold = nil; var publish: (() -> Void)?; r.owner.publication = { publish = $0 }
        await runTimed(r, url); XCTAssertTrue(try XCTUnwrap(r.owner.job).operation.hasExited); XCTAssertNil(r.owner.review)
        r.hub.discardAudioImport(); publish?(); XCTAssertNil(r.owner.review)
        XCTAssertEqual(p.calls, 2); try await r.close()
    }
    @MainActor func testB47T1T5UnsupportedEngineAndConvertedSourcePolicyHaveConnectedPositive() async throws {
        let (r, p, url) = try timedRig()
        var settings = try r.store.savedRetrySnapshot()
        for engine in [RecognitionEngine.appleSpeech, .parakeet] {
            settings.recognitionEngine = engine; settings.appleSpeechLocale = "en-US"
            try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
            await runTimed(r, url); XCTAssertNil(r.owner.review); XCTAssertEqual(p.constructions, 0)
        }
        settings.recognitionEngine = .whisper; try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        // The production post-reader origin gate, with authored conversion facts;
        // no new native conversion experiment is run for timed mode.
        let converted = ImportedAudio.SourceInfo(sourceRate: 44_100, sourceFrames: 352_800, outputFrames: 128_000, origin: .systemPCMConversion, clippedSamples: 0)
        let op = PendingOperation(name: "converted source")
        do {
            _ = try await FileRecognitionBatch.runResult(request: RecognitionRequest(settings: settings), operation: op,
                samples: { try AudioImportExecution.validateSource(converted, mode: .experimentalTimed); return [Float](repeating: 0.2, count: 128_000) },
                validate: {}, active: { true }, authorize: { true }, rawOnly: true, timed: true,
                load: { try await p.factory().acquire(request: $0) })
            XCTFail("Converted source accepted")
        } catch { XCTAssertEqual(p.constructions, 0); XCTAssertEqual(p.calls, 0) }
        op.finish()
        await runTimed(r, url); XCTAssertNotNil(r.owner.review?.segments); XCTAssertEqual(p.calls, 1)
        try await r.close()
    }
    @MainActor func testB47T4T6RealPreparationPermitTimedPositiveRetryOnlyRefusalAndRevocation() async throws {
        let (r, p, url) = try timedRig()
        let consent = UUID(), build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
        let privateRoot = r.root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let core = RecognitionPreparation(storage: { try PrivatePreparationStorage(root: privateRoot.appendingPathComponent("health")) }, build: { build })
        try core.prepareConsent(consent)
        var settings = try r.store.savedRetrySnapshot()
        settings.whisperModelPath = "/owned/" + ModelCatalog.default.filename
        settings.nativePreparationSafeStartEnabled = true; settings.nativePreparationConsent = consent
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        core.configure(enabled: true, consent: consent, selection: r.hub.modelSelectionEpoch)
        r.hub.audioImportPreparationEpoch = { core.admissionEpoch }
        var factory = p.factory(); factory.directory = URL(fileURLWithPath: "/owned")
        factory.metadata = { _ in .init(bytes: ModelCatalog.default.bytes, modified: 7, fileNumber: 4) }
        factory.preparation = core
        factory.guardedNative = { _, _, permit in try permit.nativeEntry { p.context() } }
        r.bind(factory: factory)
        await runTimed(r, url); XCTAssertNotNil(r.owner.review?.segments); XCTAssertEqual(p.calls, 1)
        let request = RecognitionRequest(settings: settings), op = PendingOperation(name: "preparation-only retry")
        try core.retryOnce(token: core.snapshot.token, operation: op, identity: factory.resolve(request))
        let retry = try await factory.acquire(request: request, operation: op,
            selectionEpoch: r.hub.modelSelectionEpoch, preparationEpoch: core.admissionEpoch)
        let refused = await retry.timedFileResult(samples: [Float](repeating: 0.2, count: 128_000))
        XCTAssertNil(refused.text); XCTAssertNil(refused.segments); XCTAssertEqual(p.calls, 1)
        guard case .pass(let pass) = refused.provenance else { return XCTFail("Expected refusal evidence") }
        XCTAssertEqual(pass.native, .failed(.preparationUnavailable))
        core.finishRetry(op); op.finish()
        // Revocation in the actual fake C call is caught after native success,
        // even without a UI callback/epoch observer racing the handle check.
        p.hold = { core.revokeDraft() }
        await runTimed(r, url); XCTAssertNil(r.owner.review); XCTAssertEqual(p.calls, 2)
        p.hold = nil
        try await r.close()
    }
}

private final class ImportConversionObservation: @unchecked Sendable {
    var creations = 0, calls = 0
    weak var converter: AVAudioConverter?
    weak var buffer: AVAudioPCMBuffer?
    var holdMake: (() -> Void)?, holdCall: (() -> Void)?
    func native() -> ImportedAudio.Native {
        let real = ImportedAudio.Native()
        var native = real
        native.make = { from, to in
            self.creations += 1
            let value = real.make(from, to); self.converter = value
            self.holdMake?()
            return value
        }
        native.convert = { converter, buffer, input in
            self.calls += 1; self.buffer = buffer
            self.holdCall?()
            return real.convert(converter, buffer, input)
        }
        return native
    }
}

extension AudioImportTests {
    @MainActor func testP7HeldPCMConstructionAndCallRetainActualSourceAndSerialBarrier() async throws {
        for constructing in [true, false] {
            let r = try ImportRig(), observation = ImportConversionObservation()
            let entered = expectation(description: "PCM native bottom held"), exit = DispatchSemaphore(value: 0)
            let hold = { entered.fulfill(); exit.wait() }
            if constructing { observation.holdMake = hold } else { observation.holdCall = hold }
            r.owner.sourceAccess.conversion = observation.native()
            let url = try r.file(bytes: rateImportWAV())
            r.hub.selectAudioImport(url); r.hub.startAudioImport()
            await fulfillment(of: [entered], timeout: 5)
            let job = try XCTUnwrap(r.owner.job)
            XCTAssertNotNil(observation.converter)
            XCTAssertFalse(job.source.isClosed); XCTAssertEqual(r.stops, 0)
            XCTAssertTrue(r.probe.paths.isEmpty)
            r.hub.discardAudioImport()
            XCTAssertFalse(job.current); XCTAssertFalse(job.operation.hasExited)
            XCTAssertTrue(r.owner.busy); XCTAssertFalse(job.source.isClosed)
            r.hub.selectAudioImport(url); r.hub.startAudioImport()
            XCTAssertNil(r.owner.source); XCTAssertEqual(observation.creations, 1)
            var nextEntered = false
            let next = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "after PCM actual exit"), completes: true, work: {
                await MainActor.run { nextEntered = true }
            })
            XCTAssertFalse(nextEntered)
            exit.signal(); await next.value; await r.chain?.value
            XCTAssertTrue(nextEntered); XCTAssertTrue(job.operation.hasExited); XCTAssertTrue(job.source.isClosed)
            XCTAssertEqual(r.stops, 1); XCTAssertFalse(r.owner.busy)
            XCTAssertNil(observation.converter); XCTAssertNil(observation.buffer)
            XCTAssertEqual(observation.calls, constructing ? 0 : 1)
            XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertNil(r.owner.review)
            try await r.close()
        }
    }

    @MainActor func testP8P9ConvertedRawFactsFactoryAfterExitCopySaveAndDiskOnlyRetry() async throws {
        let r = try ImportRig(), observation = ImportConversionObservation()
        r.owner.sourceAccess.conversion = observation.native()
        let url = try r.file(bytes: rateImportWAV()), bytes = try Data(contentsOf: url)
        var factoryEntries = 0
        r.probe.construct = {
            factoryEntries += 1
            XCTAssertNil(observation.converter); XCTAssertNil(observation.buffer)
            XCTAssertEqual(r.stops, 1)
        }
        var settings = try r.store.savedRetrySnapshot(); settings.historyEnabled = false
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        await r.run(url)
        let review = try XCTUnwrap(r.owner.review)
        XCTAssertEqual(review.sourceInfo.sourceRate, 44_100)
        XCTAssertEqual(review.sourceInfo.sourceFrames, 17_641)
        XCTAssertEqual(review.sourceInfo.origin, .systemPCMConversion)
        XCTAssertEqual(review.sourceInfo.outputFrames, r.probe.calls.first?.samples.count)
        XCTAssertEqual(review.entry.raw, "native original")
        XCTAssertEqual(factoryEntries, 1); XCTAssertEqual(observation.creations, 1)
        XCTAssertTrue(try XCTUnwrap(r.owner.job).source.isClosed)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reads = r.reads, calls = observation.calls
        try Data("path changed after snapshot commit".utf8).write(to: url)
        r.hub.copyAudioImport(); XCTAssertEqual(r.disk.copies, [review.entry.raw])
        r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        settings.historyEnabled = true; try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        XCTAssertEqual(r.owner.review?.sourceInfo, review.sourceInfo)
        r.disk.failWrite = true; r.hub.saveAudioImport(); XCTAssertEqual(r.owner.review?.saveFailed, true)
        XCTAssertTrue(r.history.pendingEntries.isEmpty)
        r.disk.failWrite = false; r.hub.saveAudioImport(); r.hub.saveAudioImport()
        XCTAssertEqual(r.history.entries, [review.entry]); XCTAssertEqual(r.owner.review?.saved, true)
        XCTAssertTrue(r.history.delete(review.entry.id)); r.hub.saveAudioImport(); XCTAssertTrue(r.history.entries.isEmpty)
        XCTAssertEqual(r.reads, reads); XCTAssertEqual(observation.calls, calls)
        XCTAssertEqual(factoryEntries, 1); XCTAssertEqual(r.probe.calls.count, 1)
        let diagnostics = String(decoding: try r.hub.diagnostics.snapshot().encoded(), as: UTF8.self)
        XCTAssertFalse(diagnostics.contains(url.path)); XCTAssertFalse(diagnostics.contains("sourceFrames"))
        r.hub.discardAudioImport(); XCTAssertNil(r.owner.review)
        try await r.close()
    }

    @MainActor func testP2P4RefusalBeforePCMCreationAndPostConversionSourceValidation() async throws {
        let r = try ImportRig(), observation = ImportConversionObservation()
        r.owner.sourceAccess.conversion = observation.native()
        var unsupported = rateImportWAV(); unsupported[24] = 1
        for bytes in [Data("not WAV".utf8), Data(rateImportWAV().dropLast()), rateImportWAV(frames: 17_639), unsupported] {
            await r.run(try r.file(bytes: bytes))
            XCTAssertNil(r.owner.review); XCTAssertEqual(observation.creations, 0)
            XCTAssertTrue(r.probe.paths.isEmpty)
        }
        let huge = try r.file(bytes: Data(repeating: 0, count: ImportedWAV.maximumBytes + 1))
        r.hub.selectAudioImport(huge); XCTAssertNil(r.owner.source); XCTAssertEqual(observation.creations, 0)
        let url = try r.file(bytes: rateImportWAV())
        var mutated = false
        observation.holdCall = {
            if !mutated {
                mutated = true
                let fd = Darwin.open(url.path, O_WRONLY)
                var byte: UInt8 = 1; XCTAssertEqual(pwrite(fd, &byte, 1, 44), 1); Darwin.close(fd)
            }
        }
        await r.run(url)
        XCTAssertTrue(mutated); XCTAssertEqual(observation.creations, 1)
        XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        XCTAssertNil(observation.converter); XCTAssertTrue(try XCTUnwrap(r.owner.job).source.isClosed)
        try await r.close()
    }
}


extension AudioImportTests {
    @MainActor func testTimedWriterProtectsRetainedOriginalAfterSavedReviewIsClosed() async throws {
        for srt in [false, true] {
            let rig = try SavedImportRig(), retained = try await rig.run(), native = ImportTimedNative(cueText: srt ? ImportTimedNative.srtCueText : nil), factory = native.factory()
            let ext = srt ? "srt" : "vtt"
            let export = { if srt { rig.hub.exportAudioImportSRT() } else { rig.hub.exportAudioImportVTT() } }
            rig.hub.onAudioImport = { job,done in
                let next = AudioImportExecution.enqueue(previous:rig.chain,admission:rig.admission,job:job,store:rig.settings,load:{ request in
                    try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
                },done:done)
                if let next { rig.chain = next }
            }
            let timed = rig.root.appendingPathComponent("timed.wav"); try importWAV(frames:128_000).write(to:timed)
            rig.hub.selectAudioImport(timed); rig.hub.startTimedAudioImport(); await rig.chain?.value
            XCTAssertNotNil(rig.transient.review?.segments)
            let alias = rig.root.appendingPathComponent("retained-hardlink.\(ext)"); XCTAssertEqual(link(retained.path,alias.path),0)
            rig.hub.audioImportExportPanel = { _ in alias }; export(); XCTAssertTrue(rig.written.isEmpty)
            rig.hub.audioImportExportPanel = { _ in rig.root.appendingPathComponent("safe.\(ext)") }; export()
            XCTAssertEqual(rig.written,[srt ? ImportTimedNative.expectedSRT : ImportTimedNative.expectedVTT]); XCTAssertEqual(native.calls,1)
            try await rig.close()
        }
    }
}

extension AudioImportTests {
    @MainActor func testAllFiveActualWritersRefuseUnknownModeContendedOverflowAndPostPanelChangeWithPositiveControls() async throws {
        for writer in 0..<5 {
            for context in 0..<5 {
                let rig = try SavedImportRig(); _ = try await rig.run()
                rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
                let entry = try XCTUnwrap(rig.history.entries.first)
                let timed = ImportTimedNative()
                if writer == 4 {
                    let factory = timed.factory()
                    rig.hub.onAudioImport = {job,done in
                        let next = AudioImportExecution.enqueue(previous:rig.chain,admission:rig.admission,job:job,store:rig.settings,load:{request in
                            try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
                        },done:done)
                        if let next {rig.chain = next}
                    }
                    let url = rig.root.appendingPathComponent("timed.wav"); try importWAV(frames:128_000).write(to:url)
                    rig.hub.selectAudioImport(url); rig.hub.startTimedAudioImport(); await rig.chain?.value
                    XCTAssertNotNil(rig.transient.review?.segments)
                }
                let ext = writer == 1 || writer == 2 ? "json" : writer == 4 ? "vtt" : "txt"
                let destination = rig.root.appendingPathComponent("output."+ext)
                var panelChange:(() -> Void)?
                let panel:() -> URL? = {let action = panelChange; panelChange = nil; action?(); return destination}
                rig.hub.historyExportPanel = {_ in panel()}; rig.hub.diagnosticPanel = {_ in panel()}
                rig.hub.vocabularyExportPanel = panel; rig.hub.audioImportExportPanel = {_ in panel()}
                rig.hub.historyExportWriter = {data,_ in rig.written.append(data)}
                rig.hub.diagnosticWriter = {data,_ in rig.written.append(data)}
                rig.hub.vocabularyExportWriter = {data,_ in rig.written.append(data)}
                let invoke:() -> Void = {
                    switch writer {
                    case 0: rig.hub.prepareHistoryExport(rowID:entry.id); rig.hub.exportHistory(content:.original,format:.text)
                    case 1: rig.hub.prepareDiagnostics(); rig.hub.exportDiagnostics()
                    case 2: rig.hub.exportVocabulary()
                    case 3: rig.hub.exportSavedAudioImportText()
                    default: rig.hub.exportAudioImportVTT()
                    }
                }
                invoke(); XCTAssertEqual(rig.written.count,1,"writer \(writer) positive")
                let frozen = try XCTUnwrap(rig.written.first); XCTAssertFalse(frozen.isEmpty)
                if writer == 3 {XCTAssertEqual(frozen,Data("native original".utf8))}
                if writer == 4 {XCTAssertEqual(frozen,ImportTimedNative.expectedVTT)}
                rig.written = []
                let root = rig.saved.store.storage.root
                var other:SavedAudioImportStore?
                switch context {
                case 0: try Data([17]).write(to:root.appendingPathComponent("unclassified"))
                case 1: XCTAssertEqual(chmod(root.path,0o755),0)
                case 2:
                    try rig.saved.store.close()
                    let owner = SavedAudioImportStore(storage:.init(root:root)); _ = try owner.bootstrap(); other = owner
                case 3:
                    for _ in 0..<65 {try Data().write(to:root.appendingPathComponent(UUID().uuidString.lowercased()+".delete"))}
                default: panelChange = {try? Data([31]).write(to:root.appendingPathComponent("panel-change"))}
                }
                invoke(); XCTAssertTrue(rig.written.isEmpty,"writer \(writer), context \(context)")
                XCTAssertEqual(rig.native.calls.count,1)
                if writer == 4 {XCTAssertEqual(timed.calls,1)}
                try other?.close(); try await rig.close()
            }
        }
    }
    @MainActor func testAllFiveWritersProtectOriginalInodeAfterInPlaceMutationAndNewOwner() async throws {
        for writer in 0..<5 {
            let rig = try SavedImportRig(), original = try await rig.run()
            let job = try XCTUnwrap(rig.saved.rows.first?.id)
            rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
            let entry = try XCTUnwrap(rig.history.entries.first)
            let timed = ImportTimedNative()
            if writer == 4 {
                let factory = timed.factory()
                rig.hub.onAudioImport = {job,done in
                    let next = AudioImportExecution.enqueue(previous:rig.chain,admission:rig.admission,job:job,store:rig.settings,load:{request in
                        try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
                    },done:done)
                    if let next {rig.chain = next}
                }
                let url = rig.root.appendingPathComponent("timed.wav"); try importWAV(frames:128_000).write(to:url)
                rig.hub.selectAudioImport(url); rig.hub.startTimedAudioImport(); await rig.chain?.value
            }
            let ext = writer == 1 || writer == 2 ? "json" : writer == 4 ? "vtt" : "txt"
            let alias = rig.root.appendingPathComponent("modified-original."+ext), safe = rig.root.appendingPathComponent("safe."+ext)
            XCTAssertEqual(link(original.path,alias.path),0)
            let fd = Darwin.open(original.path,O_WRONLY|O_NOFOLLOW|O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd,0)
            var byte:UInt8 = 93; XCTAssertEqual(pwrite(fd,&byte,1,55),1); XCTAssertEqual(Darwin.close(fd),0)
            let before = try Data(contentsOf:original)
            rig.saved.invalidate(); await rig.saved.drain(); try rig.saved.store.close()
            let next = SavedAudioImportOwner(root:rig.saved.store.storage.root,clock:{rig.now}); rig.transient.savedImports = next; await next.drain()
            if writer == 3 {rig.hub.openSavedAudioImport(job); await next.drain(); XCTAssertNotNil(next.review)}
            var destination = alias
            rig.hub.historyExportPanel = {_ in destination}; rig.hub.diagnosticPanel = {_ in destination}
            rig.hub.vocabularyExportPanel = {destination}; rig.hub.audioImportExportPanel = {_ in destination}
            rig.hub.historyExportWriter = {data,_ in rig.written.append(data)}; rig.hub.diagnosticWriter = {data,_ in rig.written.append(data)}
            rig.hub.vocabularyExportWriter = {data,_ in rig.written.append(data)}
            let invoke:() -> Void = {
                switch writer {
                case 0: rig.hub.prepareHistoryExport(rowID:entry.id); rig.hub.exportHistory(content:.original,format:.text)
                case 1: rig.hub.prepareDiagnostics(); rig.hub.exportDiagnostics()
                case 2: rig.hub.exportVocabulary()
                case 3: rig.hub.exportSavedAudioImportText()
                default: rig.hub.exportAudioImportVTT()
                }
            }
            invoke(); XCTAssertTrue(rig.written.isEmpty)
            destination = safe; invoke(); XCTAssertEqual(rig.written.count,1)
            XCTAssertEqual(try Data(contentsOf:alias),before); XCTAssertEqual(try Data(contentsOf:original),before)
            XCTAssertEqual(rig.native.calls.count,1)
            next.invalidate(); await next.drain(); try next.store.close(); try await rig.close()
        }
    }
}

extension AudioImportTests {
    @MainActor func testActualWritersRefuseHeldSavedAssociationWithoutBlockingTheMainActor() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run()
        let id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        let entry = try XCTUnwrap(rig.history.entries.first)
        rig.hub.retrySavedAudioImport(id); await rig.chain?.value; await rig.saved.drain()
        let timed = ImportTimedNative(), factory = timed.factory()
        rig.hub.onAudioImport = {job,done in
            let task = AudioImportExecution.enqueue(previous:rig.chain,admission:rig.admission,job:job,store:rig.settings,load:{request in
                try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
            },done:done)
            if let task {rig.chain = task}
        }
        let url = rig.root.appendingPathComponent("timed.wav"); try importWAV(frames:128_000).write(to:url)
        rig.hub.selectAudioImport(url); rig.hub.startTimedAudioImport(); await rig.chain?.value
        rig.hub.openSavedAudioImport(id); await rig.saved.drain()
        XCTAssertNotNil(rig.saved.review); XCTAssertNotNil(rig.transient.review?.segments)
        rig.hub.historyExportPanel = {_ in rig.root.appendingPathComponent("history.txt")}
        rig.hub.diagnosticPanel = {_ in rig.root.appendingPathComponent("diagnostic.json")}
        rig.hub.vocabularyExportPanel = {rig.root.appendingPathComponent("vocabulary.json")}
        rig.hub.audioImportExportPanel = {name in rig.root.appendingPathComponent(name)}
        rig.hub.historyExportWriter = {data,_ in rig.written.append(data)}
        rig.hub.diagnosticWriter = {data,_ in rig.written.append(data)}
        rig.hub.vocabularyExportWriter = {data,_ in rig.written.append(data)}
        func writeAll() {
            rig.hub.prepareHistoryExport(rowID:entry.id); rig.hub.exportHistory(content:.original,format:.text)
            rig.hub.prepareDiagnostics(); rig.hub.exportDiagnostics(); rig.hub.exportVocabulary()
            rig.hub.exportSavedAudioImportText(); rig.hub.exportAudioImportVTT()
        }
        writeAll(); XCTAssertEqual(rig.written.count,5); rig.written = []
        let entered = expectation(description:"association write owns the Store lock"), gate = DispatchSemaphore(value:0)
        var held = false
        rig.faults.event = {boundary,name in if boundary == .write && name == "manifest.next" && !held {held = true; entered.fulfill(); _ = gate.wait(timeout:.now()+5)}}
        rig.hub.saveSavedAudioImportHistory(); await fulfillment(of:[entered],timeout:5)
        let watchdog = Task {do {try await Task.sleep(nanoseconds:4_000_000_000)} catch {return}; XCTFail("Export waited on held saved IO"); gate.signal()}
        defer {watchdog.cancel()}
        XCTAssertTrue(rig.saved.ioBusy); XCTAssertEqual(rig.saved.metadataReadiness,.ready)
        XCTAssertThrowsError(try rig.saved.protection())
        XCTAssertNil(rig.saved.shutdownRefusal) // cached while IO is active, never waits for its lock
        writeAll(); XCTAssertTrue(rig.written.isEmpty)
        rig.faults.event = nil; gate.signal(); await rig.saved.drain()
        XCTAssertEqual(rig.native.calls.count,2); XCTAssertEqual(timed.calls,1)
        try await rig.close()
    }
    @MainActor func testSavedHandoffOriginalStaysProtectedEvenWhenValidationFailsBeforeLedgerAllocation() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let original = rig.root.appendingPathComponent("malformed.wav"); try Data("invalid WAV fixture".utf8).write(to:original)
        let entry = HistoryEntry(raw:"independent existing text"); XCTAssertTrue(rig.history.appendReviewed(entry))
        rig.hub.selectAudioImport(original); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertTrue(rig.native.paths.isEmpty)
        let alias = rig.root.appendingPathComponent("current-original.txt"); XCTAssertEqual(link(original.path,alias.path),0)
        rig.hub.historyExportPanel = {_ in alias}; rig.hub.prepareHistoryExport(rowID:entry.id); rig.hub.exportHistory(content:.original,format:.text)
        XCTAssertTrue(rig.written.isEmpty)
        rig.hub.historyExportPanel = {_ in rig.root.appendingPathComponent("safe.txt")}; rig.hub.exportHistory(content:.original,format:.text)
        XCTAssertEqual(rig.written.count,1); XCTAssertEqual(try Data(contentsOf:original),Data("invalid WAV fixture".utf8))
        try await rig.close()
    }
}

extension AudioImportTests {
    @MainActor func testB47SRTLiteralAtomicWriterCancellationFailureAndExplicitDiskOnlyRetry() async throws {
        let (r, p, url) = try timedRig(cueText: ImportTimedNative.srtCueText)
        await runTimed(r, url)
        let review = try XCTUnwrap(r.owner.review), reads = r.reads
        XCTAssertEqual(review.segments?.cues.map(\.text), ImportTimedNative.srtCueText)
        XCTAssertEqual(review.sourceInfo.origin, .strictPCM16k); XCTAssertTrue(review.job.operation.hasExited)
        XCTAssertTrue(review.job.source.isClosed); XCTAssertEqual(p.calls, 1)
        var settings = try r.store.savedRetrySnapshot(); settings.historyEnabled = false
        try r.store.save(settings); r.hub.refreshAudioImportConfiguration()
        // Export and explicit disk retry consume frozen review bytes, never this pathname again.
        try Data("source pathname changed after recognition".utf8).write(to: url)
        let destination = r.root.appendingPathComponent("literal.srt"), atomic = r.hub.historyExportWriter
        var panels = 0, writes = 0, fail = false
        r.hub.audioImportExportPanel = { name in
            panels += 1; XCTAssertEqual(name, "Parla-native-segments.srt"); return destination
        }
        r.hub.historyExportWriter = { data, url in
            writes += 1; XCTAssertEqual(data, ImportTimedNative.expectedSRT); XCTAssertEqual(data.count, 164)
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try atomic(data, url)
        }
        r.hub.exportAudioImportSRT()
        XCTAssertEqual(writes, 1); XCTAssertEqual(panels, 1)
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedSRT)
        XCTAssertEqual(r.owner.message, "Exported as SRT.")
        r.hub.audioImportExportPanel = { _ in panels += 1; return nil }
        r.hub.exportAudioImportSRT(); XCTAssertEqual(writes, 1); XCTAssertEqual(panels, 2)
        XCTAssertEqual(r.owner.review?.entry.id, review.entry.id)
        let previous = Data("previous destination bytes".utf8); try previous.write(to: destination)
        r.hub.audioImportExportPanel = { _ in panels += 1; return destination }; fail = true
        r.hub.exportAudioImportSRT(); XCTAssertEqual(writes, 2); XCTAssertEqual(panels, 3)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(r.owner.review?.entry.id, review.entry.id)
        XCTAssertEqual(r.owner.message, "Couldn’t export. Choose another location and try again.")
        XCTAssertFalse((r.owner.message ?? "").contains(destination.path))
        fail = false; r.hub.exportAudioImportSRT()
        XCTAssertEqual(writes, 3); XCTAssertEqual(panels, 4)
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedSRT)
        XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.constructions, 1); XCTAssertEqual(p.probes, 0)
        XCTAssertEqual(r.reads, reads); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.disk.copies.isEmpty)
        XCTAssertEqual(r.owner.review?.entry.id, review.entry.id)
        r.hub.discardAudioImport(); r.hub.exportAudioImportSRT()
        XCTAssertEqual(panels, 4); XCTAssertEqual(writes, 3)
        try await r.close()
    }
    @MainActor func testB47SRTMarkupRefusalKeepsReviewAndExplicitWebVTTFallback() async throws {
        let (r, p, url) = try timedRig(); await runTimed(r, url)
        let token = try XCTUnwrap(r.owner.review?.entry.id), reads = r.reads
        let destination = r.root.appendingPathComponent("fallback.vtt"), atomic = r.hub.historyExportWriter
        var panels = 0, writes = 0
        r.hub.audioImportExportPanel = { name in
            panels += 1; XCTAssertEqual(name, "Parla-native-segments.vtt"); return destination
        }
        r.hub.historyExportWriter = { data, url in writes += 1; try atomic(data, url) }
        r.hub.exportAudioImportSRT()
        XCTAssertEqual(panels, 0); XCTAssertEqual(writes, 0); XCTAssertEqual(r.owner.review?.entry.id, token)
        XCTAssertEqual(r.owner.message, "This text has characters SRT can’t show. Export WebVTT instead.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        r.hub.exportAudioImportVTT()
        XCTAssertEqual(panels, 1); XCTAssertEqual(writes, 1)
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedVTT)
        XCTAssertEqual(r.owner.message, "Exported as WebVTT.")
        XCTAssertEqual(r.owner.review?.entry.id, token); XCTAssertEqual(p.calls, 1); XCTAssertEqual(r.reads, reads)
        XCTAssertTrue(r.history.entries.isEmpty)
        try await r.close()
    }
    @MainActor func testB47SRTExtensionsRejectVTTAndTextAcceptUppercaseWithRealWriter() async throws {
        let (r, p, url) = try timedRig(cueText: ImportTimedNative.srtCueText); await runTimed(r, url)
        let token = try XCTUnwrap(r.owner.review?.entry.id), reads = r.reads, atomic = r.hub.historyExportWriter
        var writes = 0, panels = 0
        r.hub.historyExportWriter = { data, url in writes += 1; try atomic(data, url) }
        for name in ["wrong.vtt", "wrong.txt"] {
            let destination = r.root.appendingPathComponent(name)
            r.hub.audioImportExportPanel = { _ in panels += 1; return destination }
            r.hub.exportAudioImportSRT()
            XCTAssertEqual(writes, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(r.owner.message, "Choose a filename ending in .srt.")
        }
        XCTAssertEqual(panels, 2)
        let destination = r.root.appendingPathComponent("safe.SRT")
        r.hub.audioImportExportPanel = { _ in panels += 1; return destination }
        r.hub.exportAudioImportSRT(); XCTAssertEqual(writes, 1); XCTAssertEqual(panels, 3)
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedSRT)
        r.hub.exportAudioImportVTT(); XCTAssertEqual(writes, 1); XCTAssertEqual(panels, 4)
        XCTAssertEqual(r.owner.message, "Choose a filename ending in .vtt.")
        XCTAssertEqual(try Data(contentsOf: destination), ImportTimedNative.expectedSRT)
        XCTAssertEqual(r.owner.review?.entry.id, token); XCTAssertEqual(p.calls, 1); XCTAssertEqual(r.reads, reads)
        try await r.close()
    }
    @MainActor func testB47SRTSharedPayloadAndMissingTimingRefuseBeforePanel() async throws {
        let (r, p, url) = try timedRig(cueText: ["one\n\ntwo", ImportTimedNative.srtCueText[1]])
        await runTimed(r, url); let token = try XCTUnwrap(r.owner.review?.entry.id)
        XCTAssertNotNil(r.owner.review?.segments)
        var panels = 0, writes = 0
        r.hub.audioImportExportPanel = { _ in panels += 1; return r.root.appendingPathComponent("refused.srt") }
        r.hub.historyExportWriter = { _, _ in writes += 1 }
        r.hub.exportAudioImportSRT()
        XCTAssertEqual(r.owner.message, "This text can’t be exported as SRT. Copy or save it instead.")
        XCTAssertEqual(r.owner.review?.entry.id, token); XCTAssertEqual(panels, 0); XCTAssertEqual(writes, 0)
        p.ends[1] = 801; await runTimed(r, url)
        XCTAssertNotNil(r.owner.review); XCTAssertNil(r.owner.review?.segments)
        r.hub.exportAudioImportSRT()
        XCTAssertEqual(r.owner.message, "No timestamps for this file. Copy or save the text instead.")
        XCTAssertEqual(panels, 0); XCTAssertEqual(writes, 0); XCTAssertEqual(p.calls, 2)
        try await r.close()
    }
}


extension AudioImportTests {
    @MainActor func testConnectedMOVSelectionRawStartUsesRealBatchAndLiteralPCMOnly() async throws {
        let r = try ImportRig(), bytes = PCMMOVConnectionFixture.bytes(), url = try r.file("inert.MOV",bytes:bytes)
        var converterEntries = 0; var native = ImportedAudio.Native()
        native.make = {_,_ in converterEntries += 1; XCTFail("MOV entered WAV conversion"); return nil}
        r.owner.sourceAccess.conversion = native
        var selected: FileImportSource?
        r.probe.construct = {XCTAssertTrue(selected?.isClosed == true); XCTAssertEqual(r.stops,1)}
        r.hub.audioImportPicker = {url}; r.hub.chooseAudioImport(); selected = r.owner.source
        XCTAssertNotNil(selected); XCTAssertEqual(selected?.format,.mov); XCTAssertEqual(r.reads,0)
        XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.disk.copies.isEmpty)
        r.hub.refreshAudioImportConfiguration(); r.hub.audioImportPicker = {nil}; r.hub.chooseAudioImport()
        XCTAssertTrue(r.owner.source === selected); XCTAssertEqual(r.reads,0)
        r.hub.startAudioImport(); await r.chain?.value
        let review = try XCTUnwrap(r.owner.review,r.owner.message ?? "missing raw review")
        XCTAssertEqual(review.sourceInfo.origin,.directMOVPCM16k); XCTAssertEqual(review.sourceInfo.profile,.qtPCM16kV1)
        XCTAssertNil(review.segments); XCTAssertEqual(r.probe.calls.count,1)
        XCTAssertEqual(r.probe.calls.first?.samples,PCMMOVConnectionFixture.samples)
        XCTAssertEqual(converterEntries,0); XCTAssertEqual(r.probe.admissions,1)
        XCTAssertTrue(selected?.isClosed == true); XCTAssertEqual(r.scopes,r.stops)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.disk.copies.isEmpty)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        r.hub.copyAudioImport(); XCTAssertEqual(r.disk.copies,["native original"])
        r.hub.saveAudioImport(); XCTAssertEqual(r.history.entries.first?.raw,"native original")
        try await r.close()
    }
    @MainActor func testConnectedMOVSelectionRenamingLimitsAndSilenceNeverLoadPrefix() async throws {
        let r = try ImportRig(), valid = PCMMOVConnectionFixture.bytes()
        for ext in ["mp4","aac","bin"] {
            r.hub.selectAudioImport(try r.file("unsupported."+ext,bytes:valid))
            XCTAssertNil(r.owner.source); XCTAssertEqual(r.scopes,0); XCTAssertEqual(r.reads,0)
        }
        let invalid = [importWAV(),Data(valid.dropLast()),valid + Data([0]),Data(repeating:0,count:20_971_521),PCMMOVConnectionFixture.bytes(silent:true)]
        for (i,bytes) in invalid.enumerated() {
            await r.run(try r.file("refusal-\(i).mov",bytes:bytes))
            XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertFalse(r.owner.busy)
        }
        await r.run(try r.file("renamed.wav",bytes:valid)); XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty)
        await r.run(try r.file("positive.mov",bytes:valid))
        XCTAssertEqual(r.probe.calls.count,1); XCTAssertEqual(r.probe.calls.first?.samples,PCMMOVConnectionFixture.samples)
        try await r.close()
    }
    @MainActor func testConnectedMOVTimedOwnerAndDirectQueuedJobRefuseBeforeRead() async throws {
        let r = try ImportRig(), url = try r.file("timed.mov",bytes:PCMMOVConnectionFixture.bytes())
        r.hub.selectAudioImport(url); let selected = try XCTUnwrap(r.owner.source)
        r.hub.startTimedAudioImport()
        XCTAssertTrue(r.owner.source === selected); XCTAssertNil(r.owner.job); XCTAssertFalse(r.owner.busy)
        XCTAssertEqual(r.reads,0); XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertFalse(selected.isClosed)
        let settings = try r.store.savedRetrySnapshot()
        let direct = AudioImportOwner.Job(source:selected,settings:settings,selectionEpoch:UUID(),preparationEpoch:nil,diagnostics:r.hub.diagnostics,mode:.experimentalTimed)
        var completed = false, succeeded = false
        let queued = AudioImportExecution.enqueue(previous:nil,admission:r.admission,job:direct,store:r.store,
            load:{_ in XCTFail("Queued MOV timing reached factory"); throw CancellationError()},done:{result in completed = true; if case .success = result {succeeded = true}})
        await queued?.value
        XCTAssertTrue(completed); XCTAssertFalse(succeeded); XCTAssertEqual(r.reads,0)
        XCTAssertTrue(selected.isClosed); XCTAssertTrue(direct.operation.hasExited); XCTAssertTrue(r.probe.paths.isEmpty)
        // Raw positive and original-WAV timing positive prove both gates are live.
        r.hub.selectAudioImport(url); r.hub.startAudioImport(); await r.chain?.value
        XCTAssertEqual(r.probe.calls.count,1); XCTAssertNil(r.owner.review?.segments)
        let facts = try ImportedAudio.decodeSource(PCMMOVConnectionFixture.bytes(),format:.mov).transientSourceInfo
        XCTAssertThrowsError(try AudioImportExecution.validateSource(facts,mode:.experimentalTimed))
        try await r.close()
        let (wav, timed, wavURL) = try timedRig(); await runTimed(wav,wavURL)
        XCTAssertEqual(timed.calls,1); XCTAssertNotNil(wav.owner.review?.segments); try await wav.close()
    }
    @MainActor func testConnectedMOVBindingEOFMetadataPathAndAliasesRefuseBeforeFactory() async throws {
        for cut in 0..<6 {
            let r = try ImportRig(), bytes = PCMMOVConnectionFixture.bytes(), url = try r.file("binding.mov",bytes:bytes)
            var first = true
            r.owner.sourceAccess.read = {fd,buffer,count in
                r.reads += 1
                if cut == 0 {return 0}
                if cut == 1 {return -1}
                let n = Darwin.read(fd,buffer,count)
                if count == 1, n == 0, cut == 2 {buffer.storeBytes(of:UInt8(1),as:UInt8.self); return 1}
                if first, cut == 3 {
                    first = false
                    do {let replacement = try r.file("replacement.mov",bytes:bytes); XCTAssertEqual(rename(replacement.path,url.path),0)} catch {XCTFail("Replacement seam: \(error)")}
                }
                if count == 1, n == 0, cut == 4 {let writer = Darwin.open(url.path,O_WRONLY); if writer >= 0 {var changed: UInt8 = 0x33; _ = pwrite(writer,&changed,1,40); Darwin.close(writer)}}
                return n
            }
            if cut == 5 {r.owner.sourceAccess.metadata = {_,_ in throw FileImportSource.Failure.unsafe}}
            r.hub.selectAudioImport(url); r.hub.startAudioImport(); await r.chain?.value
            XCTAssertNil(r.owner.review); XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertEqual(r.scopes,r.stops)
            try await r.close()
        }
        let r = try ImportRig(), url = try r.file("source.mov",bytes:PCMMOVConnectionFixture.bytes()), alias = r.root.appendingPathComponent("alias.mov")
        XCTAssertEqual(symlink(url.path,alias.path),0); r.hub.selectAudioImport(alias); XCTAssertNil(r.owner.source)
        await r.run(url); XCTAssertEqual(r.probe.calls.count,1); try await r.close()
    }
}


extension AudioImportTests {
    @MainActor func testConnectedMOVBindingPureCheckpointCancellationAndOriginalMutationCannotEscape() async throws {
        for cancel in [false,true] {
            let r = try ImportRig(), bytes = PCMMOVConnectionFixture.bytes(), url = try r.file("checkpoint.mov",bytes:bytes)
            var structuralChecks = 0
            _ = try ImportedPCMMOV.inspect(bytes,canceled:{structuralChecks += 1; return false})
            let boundary = structuralChecks + 3 // First extraction chunk, after parser-owned copy/validation.
            let state = NSLock(); var eof = false, checkpoints = 0, revoked = false
            let entered = expectation(description:"pure MOV extraction checkpoint"), hold = MOVTestHold("pure MOV extraction")
            defer {hold.release()}
            r.owner.sourceAccess.read = {fd,buffer,count in
                r.reads += 1; let n = Darwin.read(fd,buffer,count)
                if count == 1, n == 0 {state.withLock {eof = true}}
                return n
            }
            r.hub.selectAudioImport(url); let source = try XCTUnwrap(r.owner.source)
            let reader = Task.detached { () -> Result<FileImportSource.Validated,Error> in
                do {
                    return .success(try source.readValidated(retainEncoded:true,canceled:{
                        let atBoundary = state.withLock { () -> Bool in
                            guard eof else {return false}; checkpoints += 1; return checkpoints == boundary
                        }
                        if atBoundary {hold.wait(entered:entered)}
                        return state.withLock {revoked}
                    }))
                } catch {return .failure(error)}
            }
            await fulfillment(of:[entered],timeout:3)
            guard hold.hasEntered else {
                hold.release(); source.cancel(); try recordWave4BFixture(r.root,"MOV-pure-checkpoint-unobserved-preserved"); return
            }
            XCTAssertFalse(source.isClosed); XCTAssertEqual(r.stops,0)
            if cancel {state.withLock {revoked = true}; source.cancel()}
            else {
                let writer = Darwin.open(url.path,O_WRONLY); XCTAssertGreaterThanOrEqual(writer,0)
                if writer >= 0 {var value: UInt8 = 0x5a; XCTAssertEqual(pwrite(writer,&value,1,40),1); XCTAssertEqual(Darwin.close(writer),0)}
            }
            hold.release()
            var observed: Result<FileImportSource.Validated,Error>?
            guard await observeMOVCompletion(self,"pure MOV extraction reader exit",work:{observed = await reader.value}) else {
                source.cancel(); try recordWave4BFixture(r.root,"MOV-pure-reader-exit-unobserved-preserved"); return
            }
            let result = try XCTUnwrap(observed)
            switch result {
            case .success: XCTFail("Canceled or postdecode-mutated original escaped as a validated source")
            case .failure(let error):
                if cancel {XCTAssertEqual(error as? ImportedPCMMOV.Failure,.canceled)}
                else {
                    if let failure = error as? FileImportSource.Failure, case .changed = failure {}
                    else {XCTFail("Expected postdecode binding refusal, got \(error)")}
                }
            }
            XCTAssertTrue(source.isClosed); XCTAssertEqual(r.stops,1); XCTAssertTrue(r.probe.paths.isEmpty)
            try await r.close()
        }
    }

    @MainActor func testConnectedMOVBindingFailedSavedHandoffStillProtectsOriginalAndAlias() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let url = try rig.movSource(), alias = rig.root.appendingPathComponent("failed-handoff.txt")
        XCTAssertEqual(link(url.path,alias.path),0)
        rig.transient.sourceAccess.read = {_,_,_ in 0}
        rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertEqual(rig.faults.factoryEntries,0)
        XCTAssertThrowsError(try rig.hub.validateExportDestination(alias,fileExtension:"txt"))
        XCTAssertThrowsError(try rig.hub.validateExportDestination(url,fileExtension:"mov"))
        XCTAssertNoThrow(try rig.hub.validateExportDestination(rig.root.appendingPathComponent("safe.txt"),fileExtension:"txt"))
        try await rig.close()
    }
}
