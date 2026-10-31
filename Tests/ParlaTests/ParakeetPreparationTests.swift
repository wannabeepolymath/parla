import AppKit
import Combine
import CryptoKit
import Darwin
import XCTest
@testable import ParlaCore
@testable import Parla

actor G2aLatch {
    var signaled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !signaled { await withCheckedContinuation { waiters.append($0) } } }
    func signal() { signaled = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
actor G2aHooks {
    var held: ParakeetInstallationStorage.Boundary?, failing: ParakeetInstallationStorage.Boundary?
    let entered = G2aLatch(), released = G2aLatch()
    var visited: [ParakeetInstallationStorage.Boundary] = []
    func arm(_ boundary: ParakeetInstallationStorage.Boundary, fail: Bool = false) { if fail { failing = boundary } else { held = boundary } }
    func hit(_ boundary: ParakeetInstallationStorage.Boundary) async throws {
        visited.append(boundary)
        if failing == boundary { failing = nil; throw ParakeetInstallationRefusal.storage }
        if held == boundary { held = nil; await entered.signal(); await released.wait() }
    }
}
actor G2aTransport: CatalogDownloadTransport {
    let payloads: [String: Data]
    var requests: [URLRequest] = []
    var failAt: Int?, holdAt: Int?, corruptAt: Int?, truncateAt: Int?, oversizeAt: Int?, status = 200
    let entered = G2aLatch(), released = G2aLatch()
    init(_ payloads: [String: Data]) { self.payloads = payloads }
    func configure(fail: Int? = nil, hold: Int? = nil, corrupt: Int? = nil, truncate: Int? = nil, oversize: Int? = nil, status: Int = 200) {
        failAt = fail; holdAt = hold; corruptAt = corrupt; truncateAt = truncate; oversizeAt = oversize; self.status = status
    }
    func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse {
        requests.append(request); let number = requests.count
        let marker = "/resolve/" + ParakeetWire.modelRevision + "/"
        guard let url = request.url, let range = url.path.range(of: marker), let data = payloads[String(url.path[range.upperBound...])] else {
            throw ParakeetInstallationRefusal.transport
        }
        XCTAssertEqual(maximum, Int64(data.count)); XCTAssertEqual(chunkMaximum, maximum)
        XCTAssertNil(request.value(forHTTPHeaderField: "Range")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        if number == holdAt { await entered.signal(); await released.wait() }
        if number == failAt { throw URLError(.networkConnectionLost) }
        var body = number == corruptAt ? Data(repeating: 0, count: data.count) : data
        if number == truncateAt { body = body.dropLast() }
        if number == oversizeAt { body.append(0) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: body); try handle.synchronize(); try handle.close() // actual writer exits first
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!
    }
}
actor G2aPipe: ParakeetChannel {
    var input = Data(), output = Data(), closed = false
    var reader: (Int, CheckedContinuation<Data, Error>)?
    let writeBody: ((Data) async throws -> Void)?, closeBody: (() async -> Void)?
    let joinGate: G2aLatch?, joinEntered: G2aLatch?
    init(write: ((Data) async throws -> Void)? = nil, close: (() async -> Void)? = nil,
         join: G2aLatch? = nil, joined: G2aLatch? = nil) {
        writeBody = write; closeBody = close; joinGate = join; joinEntered = joined
    }
    func read(upTo count: Int) async throws -> Data {
        if !input.isEmpty { let part = input.prefix(count); input.removeFirst(part.count); return part }
        if closed { return Data() }
        return try await withCheckedThrowingContinuation { reader = (count, $0) }
    }
    func feed(_ data: Data) { input.append(data); wake() }
    func write(_ data: Data) async throws { output.append(data); try await writeBody?(data) }
    func close() async { if !closed { closed = true; wake(); await closeBody?() } }
    private func wake() {
        guard let (count, c) = reader, closed || !input.isEmpty else { return }
        reader = nil; let part = input.prefix(count); input.removeFirst(part.count); c.resume(returning: part)
    }
    func join() async { await joinEntered?.signal(); await joinGate?.wait() }
}
actor G2aExit {
    var status: Int32?, waiters: [CheckedContinuation<Int32, Never>] = []
    func wait() async -> Int32 { if let status { return status }; return await withCheckedContinuation { waiters.append($0) } }
    func finish(_ value: Int32 = 0) { status = value; let pending = waiters; waiters = []; pending.forEach { $0.resume(returning: value) } }
}
actor G2aNative {
    let result: G2aPipe, errors: G2aPipe, exit: G2aExit
    let entered = G2aLatch(), canceled = G2aLatch(), loaded = G2aLatch()
    let loadGate: G2aLatch?
    let holdExit: Bool, holdIO: Bool, text: String, exitCode: Int32
    var request: ParakeetWire.Record?, pcm = Data(), samples: [Float] = [], finished = false
    init(result: G2aPipe, errors: G2aPipe, exit: G2aExit, load: G2aLatch?, holdExit: Bool, holdIO: Bool, text: String, code: Int32) {
        self.result = result; self.errors = errors; self.exit = exit; loadGate = load
        self.holdExit = holdExit; self.holdIO = holdIO; self.text = text; exitCode = code
    }
    func control(_ bytes: Data) async throws {
        let (kind, _) = try ParakeetWire.parseHeader(bytes.prefix(8))
        let record = try ParakeetWire.decode(bytes.dropFirst(8), kind: kind)
        if kind == .request {
            request = record
            try await result.feed(ParakeetWire.encode(.init(identity: record.identity), kind: .hello))
        }
        if kind == .cancel { await canceled.signal() }
    }
    func write(_ bytes: Data) { pcm.append(bytes) }
    func complete() async {
        guard !finished else { return }; finished = true
        await entered.signal(); await loadGate?.wait()
        do {
            var bytes = pcm; var end = false
            while !bytes.isEmpty {
                let (kind, count) = try ParakeetWire.parseHeader(bytes.prefix(8)); bytes.removeFirst(8)
                guard count <= bytes.count else { throw ParakeetWire.Failure.malformed }
                if kind == .pcm { samples += try ParakeetWire.samples(bytes.prefix(count)) }
                if kind == .end { end = true }
                bytes.removeFirst(count)
            }
            guard let request, end, samples.count == request.sampleCount else { throw ParakeetWire.Failure.order }
            if request.mode == .prepareLoad { XCTAssertTrue(samples.isEmpty); XCTAssertEqual(request.sampleCount, 0) }
            try await result.feed(ParakeetWire.encode(.init(identity: request.identity, code: .completed, text: request.mode == .prepareLoad ? "" : text), kind: .terminal))
        } catch { XCTFail("invalid test process exchange") }
        await loaded.signal()
        if !holdIO { await finishIO() }
        if !holdExit { await exit.finish(exitCode) }
    }
    func finishIO() async { await result.close(); await errors.close() }
}
final class G2aChild: ParakeetChild {
    let control: any ParakeetChannel, pcm: any ParakeetChannel, output: any ParakeetChannel, errors: any ParakeetChannel
    let native: G2aNative, exit = G2aExit()
    init(load: G2aLatch? = nil, holdExit: Bool = false, holdIO: Bool = false, join: G2aLatch? = nil, joined: G2aLatch? = nil, text: String = "private result", exitCode: Int32 = 0) {
        let result = G2aPipe(join: join, joined: joined), errors = G2aPipe()
        let native = G2aNative(result: result, errors: errors, exit: exit, load: load, holdExit: holdExit, holdIO: holdIO, text: text, code: exitCode)
        self.native = native; output = result; self.errors = errors
        control = G2aPipe(write: { try await native.control($0) })
        pcm = G2aPipe(write: { await native.write($0) }, close: { await native.complete() })
    }
    func actualExit() async -> Int32 { await exit.wait() }
    func requestCancellation() async { await native.canceled.signal() }
}
final class G2aBottoms: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [G2aChild] = []
    private var trustCalls = 0
    func recordTrust() { lock.withLock { trustCalls += 1 } }
    var trustCount: Int { lock.withLock { trustCalls } }
    private var launches = 0, time: UInt64 = 1_000_000_000
    func append(_ child: G2aChild) { lock.withLock { children.append(child) } }
    func launch() throws -> G2aChild {
        try lock.withLock { launches += 1; guard !children.isEmpty else { throw ParakeetRefusal.needsTrustedProduct }; return children.removeFirst() }
    }
    var count: Int { lock.withLock { launches } }
    func now() -> UInt64 { lock.withLock { time } }
    func advance(_ seconds: UInt64) { lock.withLock { time += seconds * 1_000_000_000 } }
}

@MainActor final class G2aRig {
    let root: URL, namespace: URL, payloads: [String: Data], release: ParakeetDataRelease, terms: ParakeetTermsApproval
    let product: ParakeetProductIdentity, binary: Data, resource = Data("tiny source-owned resource".utf8)
    let transport: G2aTransport, hooks = G2aHooks(), bottoms = G2aBottoms()
    var releasePresent = true, termsPresent = true, productPresent = true
    var productOverride: ParakeetProductIdentity?
    var termsOverride: ParakeetTermsApproval?
    var hostEligibility = ParakeetHostEligibility.supported
    var osScope = "g2a-fixture-os"
    var chain: Task<Void, Never>?, handles: [RecognitionHandle] = []
    var settings: Settings
    lazy var clock = ParakeetClock(now: { [bottoms] in bottoms.now() })
    lazy var storage = ParakeetInstallationStorage(root: namespace, transport: transport, hook: { [hooks] in try await hooks.hit($0) })
    var trust: ParakeetTrustBottom {
        .init(host: { [bottoms] in bottoms.recordTrust() }, read: { [self] url, _ in
            bottoms.recordTrust()
            switch url.lastPathComponent {
            case "parakeet-product.json": return try JSONEncoder().encode(product)
            case "ParlaParakeetHelper": return binary
            case "fixture": return resource
            default: throw ParakeetRefusal.codeIdentity
            }
        }, signature: { [self] _, team in bottoms.recordTrust(); XCTAssertEqual(team, product.team) })
    }
    lazy var owner: ParakeetPreparation = makeOwner()
    func makeOwner(closed: Bool = false, applicationInputs: ParakeetPreparationInputs? = nil) -> ParakeetPreparation {
        let inputs = applicationInputs ?? (closed ? ParakeetPreparationInputs.closed : .init(release: { [unowned self] in releasePresent ? release : nil }, terms: { [unowned self] in termsPresent ? (termsOverride ?? terms) : nil }, product: { [unowned self] in productPresent ? (productOverride ?? product) : nil }, os: { [unowned self] in osScope }, host: hostEligibility))
        let result = ParakeetPreparation(inputs: inputs, storage: storage, trust: trust, app: URL(fileURLWithPath: "/g2a/test-app"), worker: .init(launch: { [bottoms] _ in try bottoms.launch() }, clock: clock), clock: clock)
        result.enqueue = { [unowned self] operation, work, finished in
            chain = PendingOperationQueue.enqueue(previous: chain, operation: operation, completes: true, work: work, finished: finished)
        }
        result.retireHandles = { [unowned self] in
            let operation = PendingOperation(name: "g2a retirement")
            let retiring = PendingOperationQueue.enqueue(previous: chain, operation: operation, completes: true, work: { [self] in handles = [] })
            chain = retiring; await retiring.value
        }
        result.configure(settings)
        return result
    }
    init() throws {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        root = base.appendingPathComponent("parla-wave4g2a-\(UUID().uuidString)", isDirectory: true)
        namespace = root.appendingPathComponent("installation", isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw ParakeetInstallationRefusal.storage }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"])
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try log.seekToEnd()
        try log.write(contentsOf: Data("created\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8)); try log.close()
        payloads = Dictionary(uniqueKeysWithValues: ParakeetModelManifest.entries.enumerated().map { ($0.element.path, Data("g2a-tiny-\($0.offset)".utf8)) })
        release = try .init(files: payloads.map { .init(path: $0.key, bytes: $0.value.count, payloadSHA256: ParakeetDataRelease.sha256($0.value)) }, reviewEvidenceSHA256: String(repeating: "a", count: 64), pinnedSizes: false)
        terms = try .init(releaseID: release.id, decisionSHA256: String(repeating: "b", count: 64), deliveredNoticesSHA256: String(repeating: "c", count: 64))
        transport = G2aTransport(payloads)
        var binary = Data()
        for n: UInt32 in [0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, 0x000e0000, 0, 0] {
            binary.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24)])
        }
        self.binary = binary
        product = .init(protocolVersion: 1, adapterRevision: 1, sdk: ParakeetWire.sdk, helperSHA256: ParakeetDataRelease.sha256(binary), sourceSHA256: String(repeating: "d", count: 64), resources: ["Contents/Resources/fixture": ParakeetDataRelease.sha256(resource)], team: "TESTTEAM123")
        var settings = Settings(); settings.recognitionEngine = .parakeet; settings.parakeetLanguageFilter = "pl"
        self.settings = settings
    }
    func cleanup() { XCTAssertFalse(owner.hasWork); try? FileManager.default.removeItem(at: root) }
    func wait() async { var last = chain; while true { await last?.value; if last == chain { return }; last = chain } }
    func act(_ action: ParakeetPreparation.Action) async { owner.act(action, token: owner.snapshot.token); await wait() }
    func install() async throws { await act(.install); XCTAssertEqual(owner.snapshot.phase, .installed, owner.snapshot.message) }
    func prepare(_ child: G2aChild = G2aChild()) async throws { bottoms.append(child); await act(.prepare); XCTAssertEqual(owner.snapshot.phase, .ready, owner.snapshot.message) }
    func factory() -> RecognitionFactory {
        var factory = RecognitionFactory(parakeetTrust: trust, parakeetApp: URL(fileURLWithPath: "/g2a/test-app"), parakeetWorker: .init(launch: { [bottoms] _ in try bottoms.launch() }, clock: clock),
            appleInstalledUse: { _, _ in XCTFail("Apple used"); throw ParakeetRefusal.configuration },
            native: { _, _ in XCTFail("Whisper used"); throw ParakeetRefusal.configuration }, guardedNative: { _, _, _ in XCTFail("B53 used"); throw ParakeetRefusal.configuration },
            runtime: { XCTFail("Whisper runtime used"); return .init(nativeVersion: "", buildScope: "") }, metadata: { _ in XCTFail("Whisper metadata used"); return nil }, admit: { _, _ in XCTFail("Whisper admission used") })
        owner.bindFactory(&factory); return factory
    }
    func record() throws -> ParakeetInstallationRecord { try JSONDecoder().decode(ParakeetInstallationRecord.self, from: Data(contentsOf: namespace.appendingPathComponent("record.json"))) }
    func replaceRecord(_ value: ParakeetInstallationRecord) throws { try JSONEncoder().encode(value).write(to: namespace.appendingPathComponent("record.json")) }
    var audioWriter: ([Float], URL) throws -> Void = RecordingStore.writeWAV
    func hub(atomicWrite: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> HubModel {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore(), atomicWrite: atomicWrite)
        try store.save(settings)
        let model = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")), recordings: RecordingStore(directory: root.appendingPathComponent("recordings"), writer: audioWriter),
            shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }))
        model.refreshPreparationConfiguration(); model.bindParakeet(owner)
        return model
    }
}

@MainActor final class ParakeetPreparationTests: XCTestCase {
    func testG3ApplicationDefaultsArePassiveAndProductAloneLeavesReleaseAndTermsClosed() async throws {
        XCTAssertNil(ParakeetProductBuildInput.expected)
        XCTAssertNil(ParakeetPreparationInputs.application.product())
        XCTAssertNil(ParakeetPreparationInputs.application.release())
        XCTAssertNil(ParakeetPreparationInputs.application.terms())
        let r = try G2aRig(); defer { r.cleanup() }
        var inputs = ParakeetPreparationInputs.application
        inputs.host = .supported
        // Stand-in for compiled material; actual generated variant compilation
        // requires the later real product build. No descriptor supplies it.
        inputs.product = { [unowned r] in r.product }
        r.owner = r.makeOwner(applicationInputs: inputs)
        await r.act(.install)
        XCTAssertEqual(r.owner.snapshot.refusal, .releaseIntegrity)
        inputs.release = { [unowned r] in r.release }
        r.owner = r.makeOwner(applicationInputs: inputs)
        await r.act(.install)
        XCTAssertEqual(r.owner.snapshot.refusal, .terms)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.path))
        let requests = await r.transport.requests
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(r.bottoms.count, 0); XCTAssertEqual(r.bottoms.trustCount, 0)
    }
    func testG3ApplicationCompositionUsesRealInstallPrepareLeaseAndFactoryWithFakeBottoms() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        var inputs = ParakeetPreparationInputs.application
        inputs.product = { [unowned r] in r.product }; inputs.release = { [unowned r] in r.release }; inputs.terms = { [unowned r] in r.terms }
        inputs.host = .supported; inputs.os = { [unowned r] in r.osScope }
        r.owner = r.makeOwner(applicationInputs: inputs)
        try await r.install()
        XCTAssertNotEqual(r.owner.snapshot.phase, .ready); XCTAssertEqual(r.bottoms.count, 0)
        try await r.prepare()
        let child = G2aChild(text: "synthetic application product")
        r.bottoms.append(child)
        var handle: RecognitionHandle? = try await r.factory().acquire(request: .init(settings: r.settings))
        XCTAssertEqual(r.owner.ownership.count, 1)
        let result = await handle!.recognize([0.25], pass: .fullFinal)
        XCTAssertEqual(result.text, "synthetic application product")
        handle = nil
        XCTAssertEqual(r.owner.ownership.count, 0); XCTAssertEqual(r.bottoms.count, 2)
        XCTAssertGreaterThan(r.bottoms.trustCount, 0)
    }
    func testDeleteRefreshProtectsNewEffectiveProfileBeforeMutation() async throws {
        for protective in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
            r.settings.recognitionEngine = .whisper; r.owner.configure(r.settings)
            let hub = try r.hub()
            hub.onPreparationSaved = { r.owner.configure($0) }
            await r.hooks.arm(.hashing(ParakeetModelManifest.entries[0].path))
            hub.onParakeetAction(.delete, hub.parakeetSnapshot.token)
            await r.hooks.entered.wait()
            var profile = DictationProfile(); profile.name = "new reference"; profile.target = "com.g2a.editor"
            profile.recognitionEngine = .parakeet; profile.enabled = protective
            r.settings.profiles = [profile]; try hub.store.save(r.settings)
            hub.refreshPreparationConfiguration()
            XCTAssertTrue(r.owner.hasWork)
            if protective { XCTAssertEqual(r.owner.snapshot.phase, .stopping) }
            await r.hooks.released.signal(); await r.wait()
            XCTAssertEqual(FileManager.default.fileExists(atPath: r.namespace.appendingPathComponent("source").path), protective)
            XCTAssertEqual(try r.record().stage, protective ? .installed : .absent)
        }
    }
    func testPrepareReceiptRevalidatesFullInputsBeforeDurableAndCachedReadiness() async throws {
        for loss in ["unchanged", "release", "terms", "product", "termsDecision", "os"] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
            await r.hooks.arm(.receipt); r.bottoms.append(G2aChild())
            r.owner.act(.prepare, token: r.owner.snapshot.token); await r.hooks.entered.wait()
            switch loss {
            case "release": r.releasePresent = false
            case "terms": r.termsPresent = false
            case "product": r.productPresent = false
            case "termsDecision": r.termsOverride = try .init(releaseID: r.release.id, decisionSHA256: String(repeating: "e", count: 64), deliveredNoticesSHA256: r.terms.deliveredNoticesSHA256)
            case "os": r.osScope = "changed-fixture-os"
            default: break
            }
            await r.hooks.released.signal(); await r.wait()
            XCTAssertEqual(r.owner.snapshot.phase == .ready, loss == "unchanged", loss)
            XCTAssertEqual(try r.record().stage == .ready, loss == "unchanged", loss)
            XCTAssertEqual(try r.record().prepared != nil, loss == "unchanged", loss)
            r.releasePresent = true; r.termsPresent = true; r.productPresent = true; r.termsOverride = nil; r.osScope = "g2a-fixture-os"
            let restored = r.makeOwner(); restored.reconcileOnce(); await r.wait()
            XCTAssertEqual(restored.snapshot.phase == .ready, loss == "unchanged", "reconciliation cannot invent a successful current receipt: \(loss)")
        }
    }
    func testUnchangedHubRefreshPreservesReadyDisplayAndPreparedUse() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let hub = try r.hub()
        hub.onPreparationSaved = { r.owner.configure($0) }
        try await r.install(); try await r.prepare()
        hub.refreshPreparationConfiguration()
        XCTAssertEqual(r.owner.snapshot.phase, .ready); XCTAssertEqual(hub.parakeetSnapshot.phase, .ready)
        var lease: ParakeetInstallationLease? = try await r.owner.preparedUse(.parakeet(model: ParakeetWire.model, filter: nil), operation: nil)
        XCTAssertNotNil(lease); lease = nil
        XCTAssertEqual(r.bottoms.count, 1)
    }
    func testActualHubSafeStartInstallUsesAllPinnedRequestsRealTreeAndNoSelectionOrReadiness() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        let hub = try r.hub(), before = r.settings
        hub.onParakeetAction(.install, hub.parakeetSnapshot.token); await r.wait()
        XCTAssertEqual(hub.parakeetSnapshot.phase, .installed); XCTAssertFalse(r.owner.hasWork)
        XCTAssertEqual(try r.record().stage, .installed); XCTAssertNil(try r.record().prepared)
        XCTAssertEqual(try r.record().completed.count, 21)
        let calls = await r.transport.requests; XCTAssertEqual(calls.count, 21)
        for file in r.release.files {
            XCTAssertEqual(try Data(contentsOf: r.namespace.appendingPathComponent("source/" + file.path)), r.payloads[file.path])
            XCTAssertTrue(calls.contains { $0.url == (try? r.release.request(for: file).url) })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.appendingPathComponent("candidate").path))
        XCTAssertEqual(hub.store.load(), before); XCTAssertEqual(r.bottoms.count, 0)
        do { _ = try await r.factory().acquire(request: .init(settings: r.settings)); XCTFail("install became ready") }
        catch { XCTAssertEqual(error as? ParakeetInstallationRefusal, .needsPreparation) }
    }
    func testClosedDefaultsAndEachIndependentGateRefuseBeforeDiskNetworkHelper() async throws {
        for missing in ["release", "terms", "product", "default"] {
            let r = try G2aRig(); defer { r.cleanup() }
            r.releasePresent = missing != "release"; r.termsPresent = missing != "terms"; r.productPresent = missing != "product"
            let owner = missing == "default" ? r.makeOwner(closed: true) : r.owner
            owner.act(.install, token: owner.snapshot.token); await r.wait()
            XCTAssertEqual(owner.snapshot.refusal, missing == "terms" ? .terms : missing == "product" ? .trustedProduct : .releaseIntegrity)
            XCTAssertFalse(owner.snapshot.canInstall); XCTAssertFalse(owner.snapshot.canPrepare)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.path))
            let requests = await r.transport.requests; XCTAssertTrue(requests.isEmpty); XCTAssertEqual(r.bottoms.count, 0)
        }
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install() // success sibling
        XCTAssertThrowsError(try ParakeetDataRelease(files: r.release.files, reviewEvidenceSHA256: r.release.reviewEvidenceSHA256))
        XCTAssertEqual(ParakeetModelManifest.entries.count, 21); XCTAssertEqual(ParakeetModelManifest.entries.reduce(0) { $0 + $1.bytes }, 335_745_501)
        XCTAssertEqual(ParakeetModelManifest.entries.filter { $0.kind == .gitBlobSHA1 }.count, 9)
    }
    func testCanceledHeldWriterKeepsClaimAndJournalUntilActualExitThenCompletedFileRetry() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        await r.transport.configure(hold: 2)
        r.owner.act(.install, token: r.owner.snapshot.token); await r.transport.entered.wait()
        XCTAssertEqual(try r.record().completed.count, 1)
        r.owner.cancel(token: r.owner.snapshot.token)
        XCTAssertEqual(r.owner.snapshot.phase, .stopping); XCTAssertTrue(r.owner.hasWork)
        r.owner.act(.delete, token: r.owner.snapshot.token); r.owner.act(.install, token: r.owner.snapshot.token)
        let requests = await r.transport.requests; XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try r.record().completed.count, 1, "no checkpoint before the writer exits")
        await r.transport.released.signal(); await r.wait()
        XCTAssertFalse(r.owner.hasWork); XCTAssertEqual(try r.record().completed.count, 1)
        await r.transport.configure(); await r.act(.retry)
        XCTAssertEqual(r.owner.snapshot.phase, .installed)
        let retried = await r.transport.requests; XCTAssertEqual(retried.count, 22)
        XCTAssertEqual(retried[1].url, retried[2].url); XCTAssertNotEqual(retried[0].url, retried[2].url)
    }
    func testHashCommitAndReceiptHoldCancellationNeverPublishesEarlyAndHasPositiveSiblings() async throws {
        for boundary in [ParakeetInstallationStorage.Boundary.hashing(ParakeetModelManifest.entries[0].path), .checkpoint, .commit, .receipt] {
            let r = try G2aRig(); defer { r.cleanup() }; await r.hooks.arm(boundary)
            r.owner.act(.install, token: r.owner.snapshot.token); await r.hooks.entered.wait()
            XCTAssertTrue(r.owner.hasWork); XCTAssertNotEqual(try r.record().stage, .installed)
            r.owner.cancel(token: r.owner.snapshot.token); XCTAssertTrue(r.owner.hasWork)
            await r.hooks.released.signal(); await r.wait()
            XCTAssertNotEqual(try r.record().stage, .installed); XCTAssertNil(try r.record().prepared)
            await r.act(.retry); XCTAssertEqual(r.owner.snapshot.phase, .installed)
        }
    }
    func testTransportTruncationHashStatusAndBoundsFailuresKeepSourceUnpublished() async throws {
        for fault in ["hash", "truncate", "oversize", "status", "transport"] {
            let r = try G2aRig(); defer { r.cleanup() }
            await r.transport.configure(fail: fault == "transport" ? 1 : nil, corrupt: fault == "hash" ? 1 : nil, truncate: fault == "truncate" ? 1 : nil, oversize: fault == "oversize" ? 1 : nil, status: fault == "status" ? 206 : 200)
            await r.act(.install)
            XCTAssertNotEqual(r.owner.snapshot.phase, .installed); XCTAssertEqual(try r.record().completed.count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.appendingPathComponent("source").path))
            XCTAssertNil(try r.record().prepared)
        }
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
    }
    func testExplicitKnownCrashRecoveryRehashesWhilePassivePreservesAndNeverNetworks() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        var value = try r.record(); value.stage = .publishing; try r.replaceRecord(value)
        let recovered = r.makeOwner(); recovered.reconcileOnce(); await r.wait()
        XCTAssertEqual(recovered.snapshot.phase, .interrupted)
        let before = await r.transport.requests.count
        let beforeRecoveryHash = await r.hooks.visited.filter { if case .hashing = $0 { return true }; return false }.count
        recovered.act(.retry, token: recovered.snapshot.token); await r.wait()
        XCTAssertEqual(recovered.snapshot.phase, .installed); XCTAssertNil(try r.record().prepared)
        let after = await r.transport.requests.count; XCTAssertEqual(before, after)
        let afterRecoveryHash = await r.hooks.visited.filter { if case .hashing = $0 { return true }; return false }.count
        XCTAssertEqual(afterRecoveryHash - beforeRecoveryHash, 21)
        XCTAssertEqual(r.bottoms.count, 0)
    }
    func testUnknownCorruptOversizedForeignJournalAndUnsafeTreesPreserveAssets() async throws {
        for fault in ["unknown", "malformed", "oversized", "identity", "symlink", "hardlink", "extraCTC", "changed"] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
            let record = r.namespace.appendingPathComponent("record.json"), first = r.namespace.appendingPathComponent("source/" + r.release.files[0].path)
            switch fault {
            case "unknown": try Data("PRIVATE_CANARY".utf8).write(to: r.namespace.appendingPathComponent("foreign"))
            case "malformed": try Data("{PRIVATE_CANARY".utf8).write(to: record)
            case "oversized": try Data(repeating: 65, count: 65_537).write(to: record)
            case "identity": var value = try r.record(); value.schema = 2; try r.replaceRecord(value)
            case "symlink": try FileManager.default.removeItem(at: first); try FileManager.default.createSymbolicLink(at: first, withDestinationURL: r.root.appendingPathComponent("unknown-target"))
            case "hardlink": XCTAssertEqual(link(first.path, r.root.appendingPathComponent("link").path), 0)
            case "extraCTC": try Data("CTC".utf8).write(to: r.namespace.appendingPathComponent("source/CTC.mlmodelc"))
            default: try Data(repeating: 0, count: r.payloads[r.release.files[0].path]!.count).write(to: first)
            }
            let before = try Data(contentsOf: record)
            let fresh = r.makeOwner(); fresh.reconcileOnce(); await r.wait()
            XCTAssertEqual(fresh.snapshot.refusal, .storage, fault)
            fresh.act(.recheck, token: fresh.snapshot.token); await r.wait()
            XCTAssertEqual(try Data(contentsOf: record), before)
            XCTAssertFalse(fresh.snapshot.canPrepare); XCTAssertEqual(r.bottoms.count, 0)
            let requests = await r.transport.requests; XCTAssertEqual(requests.count, 21)
            XCTAssertFalse(fresh.snapshot.message.contains("PRIVATE_CANARY"))
        }
    }
    func testExplicitPrepareRealTrustWorkerEmptyPCMAndDurableReadyThenReadOnlyRecheck() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        let child = G2aChild(); try await r.prepare(child)
        let request = await child.native.request; XCTAssertEqual(request?.mode, .prepareLoad); XCTAssertEqual(request?.sampleCount, 0)
        let scope = try XCTUnwrap(try r.record().prepared)
        XCTAssertEqual(scope.releaseID, r.release.id); XCTAssertEqual(scope.product, r.product); XCTAssertEqual(scope.installation, try r.record().generation)
        XCTAssertNotEqual(scope.releaseID, request?.identity.manifest)
        XCTAssertEqual(request?.identity.verification, "provisional-mixed-metadata-v1")
        let before = try Data(contentsOf: r.namespace.appendingPathComponent("record.json"))
        await r.act(.recheck); XCTAssertEqual(r.owner.snapshot.phase, .ready); XCTAssertEqual(r.bottoms.count, 1)
        XCTAssertEqual(try Data(contentsOf: r.namespace.appendingPathComponent("record.json")), before)
        let fresh = r.makeOwner(); fresh.reconcileOnce(); await r.wait()
        XCTAssertEqual(fresh.snapshot.phase, .ready, "only a previously persisted, scoped success can reconcile")
        XCTAssertEqual(r.bottoms.count, 1)
    }
    func testPrepareWaitsForLoadExitAllIOAndReceiptAndCancelNeverPrematurelyReady() async throws {
        for boundary in ["load", "exit", "io", "join", "receipt"] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
            let load = G2aLatch(), join = G2aLatch(), joined = G2aLatch()
            let child = G2aChild(load: boundary == "load" ? load : nil, holdExit: boundary == "exit", holdIO: boundary == "io", join: boundary == "join" ? join : nil, joined: boundary == "join" ? joined : nil)
            if boundary == "receipt" { await r.hooks.arm(.receipt) }
            r.bottoms.append(child); r.owner.act(.prepare, token: r.owner.snapshot.token)
            if boundary == "load" { await child.native.entered.wait() }
            else if boundary == "join" { await joined.wait() }
            else if boundary == "receipt" { await r.hooks.entered.wait() }
            else { await child.native.loaded.wait() }
            XCTAssertTrue(r.owner.hasWork); XCTAssertNil(try r.record().prepared)
            r.owner.cancel(token: r.owner.snapshot.token); XCTAssertTrue(r.owner.hasWork)
            await load.signal(); await child.exit.finish(); await child.native.finishIO(); await join.signal(); await r.hooks.released.signal()
            await r.wait(); XCTAssertNotEqual(r.owner.snapshot.phase, .ready); XCTAssertNil(try r.record().prepared)
            try await r.prepare()
        }
    }
    func testEqualityDeadlinesAndPersistenceFailureNeverCreateReadiness() async throws {
        for boundary in ["install", "verify", "prepare", "receipt"] {
            let r = try G2aRig(); defer { r.cleanup() }
            if boundary == "install" {
                await r.transport.configure(hold: 1); r.owner.act(.install, token: r.owner.snapshot.token); await r.transport.entered.wait()
                r.bottoms.advance(3600); await r.transport.released.signal(); await r.wait()
            } else {
                try await r.install()
                if boundary == "verify" {
                    await r.hooks.arm(.hashing(r.release.files[0].path)); r.owner.act(.recheck, token: r.owner.snapshot.token); await r.hooks.entered.wait()
                    r.bottoms.advance(60); await r.hooks.released.signal(); await r.wait()
                } else if boundary == "receipt" {
                    await r.hooks.arm(.receipt, fail: true); r.bottoms.append(G2aChild()); await r.act(.prepare)
                } else {
                    let gate = G2aLatch(), child = G2aChild(load: gate)
                    r.bottoms.append(child); r.owner.act(.prepare, token: r.owner.snapshot.token); await child.native.entered.wait()
                    r.bottoms.advance(180); await gate.signal(); await r.wait()
                }
            }
            XCTAssertNotEqual(r.owner.snapshot.phase, .ready)
            XCTAssertNil(try r.record().prepared)
        }
    }
    func testRealOwnerFactoryFinalCommandEmptyAndUnrelatedDraftKeepsFrozenUse() async throws {
        for (pass, text, supplied) in [(RecognitionHandle.Pass.fullFinal, "final", true), (.command, "command", false), (.fullFinal, "", false)] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
            let child = G2aChild(text: text); r.bottoms.append(child)
            var handle: RecognitionHandle? = try await r.factory().acquire(request: .init(settings: r.settings), operation: supplied ? PendingOperation(name: "origin") : nil)
            XCTAssertEqual(r.owner.ownership.count, 1)
            r.owner.draftChanged() // preparation publication invalidated; the frozen origin remains current
            let result = await handle!.recognize([0.25, -0.5], pass: pass)
            XCTAssertEqual(result.native, .completed(.init(text: text))); XCTAssertEqual(result.text, text)
            let samples = await child.native.samples; XCTAssertEqual(samples, [0.25, -0.5])
            handle = nil; XCTAssertEqual(r.owner.ownership.count, 0)
        }
    }
    func testShutdownRevokesRetainedBeforeStartAndWaitsForPinReleaseWithoutForcedRetirement() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
        var handle: RecognitionHandle? = try await r.factory().acquire(request: .init(settings: r.settings))
        let done = expectation(description: "actual pin retirement"), shutdownEntered = expectation(description: "retirement reached")
        r.owner.retireHandles = { shutdownEntered.fulfill() }
        var replied = false
        r.owner.beginShutdown(chain: { r.chain }) { allowed in replied = allowed; done.fulfill() }
        XCTAssertTrue(r.owner.admissionClosed)
        await fulfillment(of: [shutdownEntered], timeout: 3); XCTAssertFalse(replied); XCTAssertEqual(r.owner.ownership.count, 1)
        let result = await handle!.recognize([0.5], pass: .fullFinal); XCTAssertNil(result.text)
        XCTAssertEqual(r.bottoms.count, 1, "retained handle must not launch after owner close")
        handle = nil; await fulfillment(of: [done], timeout: 3); XCTAssertTrue(replied)
    }
    func testNilAndSuppliedOperationQuitSuppressesLateTextButJoinsExitAndIOBeforePinRetirement() async throws {
        for supplied in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
            let child = G2aChild(holdExit: true, holdIO: true, text: "LATE_PRIVATE_TEXT"); r.bottoms.append(child)
            let operation = PendingOperation(name: "origin")
            var handle: RecognitionHandle? = try await r.factory().acquire(request: .init(settings: r.settings), operation: supplied ? operation : nil)
            r.handles = [handle!]
            var running: Task<RecognitionPassResult, Never>? = Task { [handle = handle!] in await handle.recognize([0.5], pass: .fullFinal) }
            await child.native.loaded.wait()
            let joined = expectation(description: "quit waits for IO and retained lease")
            var replied = false
            r.owner.beginShutdown(chain: { r.chain }) { replied = $0; joined.fulfill() }
            await child.native.canceled.wait(); XCTAssertFalse(replied); XCTAssertTrue(r.owner.hasWork)
            await child.exit.finish(); XCTAssertFalse(replied)
            await child.native.finishIO()
            let result = await running!.value
            XCTAssertEqual(result.native, .completed(.init(text: "LATE_PRIVATE_TEXT"))); XCTAssertNil(result.text)
            r.handles = []
            XCTAssertEqual(r.owner.ownership.count, 1)
            handle = nil; running = nil
            await fulfillment(of: [joined], timeout: 3); XCTAssertTrue(replied)
        }
    }
    func testWriterDeleteAndEnabledProfileProtectionWhileInvalidSettingsPreserve() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
        var lease: ParakeetInstallationLease? = try await r.owner.preparedUse(.parakeet(model: ParakeetWire.model, filter: nil), operation: nil)
        r.settings.recognitionEngine = .whisper
        r.owner.configure(r.settings)
        await r.act(.delete); XCTAssertEqual(r.owner.snapshot.refusal, .protectedInstallation)
        XCTAssertNotNil(lease); lease = nil
        var profile = DictationProfile(); profile.name = "private profile"; profile.target = "com.g2a.editor"; profile.recognitionEngine = .parakeet
        r.settings.profiles = [profile]; r.owner.configure(r.settings)
        await r.act(.delete); XCTAssertEqual(r.owner.snapshot.refusal, .protectedInstallation)
        profile.enabled = false; r.settings.profiles = [profile]; r.owner.configure(r.settings, valid: false)
        await r.act(.delete); XCTAssertTrue(FileManager.default.fileExists(atPath: r.namespace.appendingPathComponent("source").path))
        r.owner.configure(r.settings); await r.act(.delete)
        XCTAssertEqual(r.owner.snapshot.phase, .absent); XCTAssertEqual(try r.record().stage, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.appendingPathComponent("source").path))
    }
    func testIndependentTerminationAndRestartLeavesHoldWriterAndOriginalFailureAcrossQuitAThenB() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; await r.transport.configure(hold: 1)
        r.owner.act(.install, token: r.owner.snapshot.token); await r.transport.entered.wait()
        var clipboard: ((Bool) -> Void)?, replies: [Bool] = [], clipboardOriginal = true
        let done = expectation(description: "once app reply")
        let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { $0(true) }, parakeet: { reply in r.owner.beginShutdown(chain: { r.chain }, reply: reply) }, cancelParakeet: { r.owner.cancelShutdown() }, cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); done.fulfill() }, failure: { XCTAssertTrue(clipboardOriginal) })
        XCTAssertEqual(coordinator.request(), .terminateLater); XCTAssertTrue(r.owner.admissionClosed)
        clipboard?(false); await fulfillment(of: [done], timeout: 3); XCTAssertEqual(replies, [false]); XCTAssertTrue(clipboardOriginal)
        let final = expectation(description: "quit B drain")
        let second = TerminationCoordinator(clipboard: { $0(true) }, updater: { $0(true) }, parakeet: { reply in r.owner.beginShutdown(chain: { r.chain }) { reply($0); final.fulfill() } }, cancelParakeet: { r.owner.cancelShutdown() }, cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0) }, failure: {})
        XCTAssertEqual(second.request(), .terminateLater)
        r.owner.deliberateEntry(); XCTAssertTrue(r.owner.admissionClosed)
        XCTAssertFalse(r.owner.reserveRestart()); r.owner.releaseRestart(); XCTAssertTrue(r.owner.admissionClosed)
        await r.transport.released.signal(); await r.wait(); await fulfillment(of: [final], timeout: 3)
        XCTAssertEqual(replies, [false, true]); XCTAssertTrue(clipboardOriginal)
        clipboardOriginal = false
    }
    func testRestartReservationDrainRejectionAndUpdateFailureReleaseOnlyOwnLeaf() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        XCTAssertTrue(r.owner.reserveRestart()); XCTAssertFalse(r.owner.reserveRestart())
        let drained = await r.owner.drainRestart(chain: { r.chain }); XCTAssertTrue(drained); XCTAssertTrue(r.owner.restartReady())
        let updater = UpdateTerminationIntent()
        _ = updater.installFailed { r.owner.releaseRestart() }
        XCTAssertFalse(r.owner.admissionClosed)
        XCTAssertTrue(r.owner.reserveRestart())
        let quit = expectation(description: "independent quit")
        r.owner.beginShutdown(chain: { r.chain }) { XCTAssertTrue($0); quit.fulfill() }
        _ = updater.installFailed { r.owner.releaseRestart() }
        XCTAssertTrue(r.owner.admissionClosed); await fulfillment(of: [quit], timeout: 3)
        r.owner.cancelShutdown(); r.owner.reconcileOnce(); XCTAssertTrue(r.owner.admissionClosed)
        r.owner.deliberateEntry(); XCTAssertFalse(r.owner.admissionClosed)
    }

    func testAcquisitionPinsBeforeAwaitBlocksWriterAndChecksFreshGatesAfterVerification() async throws {
        for close in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
            await r.hooks.arm(.hashing(r.release.files[0].path))
            let acquiring = Task { try await r.factory().acquire(request: .init(settings: r.settings)) }
            await r.hooks.entered.wait(); XCTAssertEqual(r.owner.ownership.count, 1)
            r.owner.act(.prepare, token: r.owner.snapshot.token)
            XCTAssertEqual(r.owner.snapshot.refusal, .protectedInstallation)
            let retired = close ? expectation(description: "closed acquisition retirement") : nil
            if close { r.owner.beginShutdown(chain: { r.chain }) { XCTAssertTrue($0); retired?.fulfill() } }
            else { r.productPresent = false }
            await r.hooks.released.signal()
            do { _ = try await acquiring.value; XCTFail("acquisition crossed changed admission") }
            catch { XCTAssertTrue(error is ParakeetInstallationRefusal) }
            XCTAssertEqual(r.owner.ownership.count, 0); XCTAssertEqual(r.bottoms.count, 1)
            if let retired { await fulfillment(of: [retired], timeout: 3) }
        }
    }
    func testPassiveBareInstallationAndReadOnlyRecheckCannotCreateLoadSuccessOrWrite() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        let path = r.namespace.appendingPathComponent("record.json"), before = try Data(contentsOf: path)
        let oldHashCount = await r.hooks.visited.filter { if case .hashing = $0 { return true }; return false }.count
        let fresh = r.makeOwner(); fresh.reconcileOnce(); await r.wait()
        let passiveHashCount = await r.hooks.visited.filter { if case .hashing = $0 { return true }; return false }.count
        XCTAssertEqual(oldHashCount, passiveHashCount); XCTAssertEqual(fresh.snapshot.phase, .installed)
        fresh.act(.recheck, token: fresh.snapshot.token); await r.wait()
        XCTAssertEqual(fresh.snapshot.phase, .installed); XCTAssertEqual(r.bottoms.count, 0)
        XCTAssertEqual(try Data(contentsOf: path), before); XCTAssertNil(try r.record().prepared)
    }
    func testLatestPendingRecheckCoalescesAndCompletedProgressIsMeasuredAtMostFourPerSecond() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; await r.transport.configure(hold: 1)
        var measured: [Int] = []
        let observer = r.owner.$snapshot.sink { if let bytes = $0.bytes { measured.append(bytes) } }
        r.owner.act(.install, token: r.owner.snapshot.token); await r.transport.entered.wait()
        for _ in 0..<5 { r.owner.act(.recheck, token: r.owner.snapshot.token) }
        await r.transport.released.signal(); await r.wait()
        let hashes = await r.hooks.visited.filter { if case .hashing = $0 { return true }; return false }.count
        XCTAssertEqual(hashes, 21 + 21 + 21, "one per-file pass, full release pass, and just one pending Recheck")
        XCTAssertEqual(measured.count, 1, "the monotonic clock did not advance by 250ms")
        XCTAssertTrue(measured.allSatisfy { $0 > 0 && $0 <= r.release.bytes })
        XCTAssertEqual(r.owner.snapshot.phase, .installed); XCTAssertEqual(r.bottoms.count, 0)
        withExtendedLifetime(observer) {}
    }
    func testSavedTokenDraftAndMissingProductNeverGrantPrepareAndBadTrustHasCleanSibling() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        let hub = try r.hub(), old = hub.parakeetSnapshot.token
        hub.settings.showHudAlways.toggle()
        hub.onParakeetAction(.prepare, old); await r.wait()
        XCTAssertEqual(r.bottoms.count, 0); XCTAssertFalse(r.owner.snapshot.canPrepare)
        hub.flushPendingSave(); r.owner.configure(hub.store.load())
        hub.words.append(.init(text: "PRIVATE_WORD"))
        XCTAssertEqual(r.owner.snapshot.refusal, .configuration)
        hub.flushPendingSave(); r.owner.configure(hub.store.load())
        hub.snippets.append(.init(trigger: "PRIVATE_TOKEN", expansion: "PRIVATE_TRANSCRIPT"))
        XCTAssertEqual(r.owner.snapshot.refusal, .configuration)
        hub.flushPendingSave(); r.owner.configure(hub.store.load())
        hub.replacements.append(.init(source: "PRIVATE_WORD", replacement: "PRIVATE_TRANSCRIPT"))
        XCTAssertEqual(r.owner.snapshot.refusal, .configuration)
        hub.flushPendingSave(); r.owner.configure(hub.store.load())
        r.productPresent = false; await r.act(.prepare)
        XCTAssertEqual(r.owner.snapshot.refusal, .trustedProduct); XCTAssertEqual(r.bottoms.count, 0)
        r.productPresent = true
        r.productOverride = .init(protocolVersion: 1, adapterRevision: 1, sdk: "WRONG_SDK", helperSHA256: r.product.helperSHA256, sourceSHA256: r.product.sourceSHA256, resources: r.product.resources, team: r.product.team)
        await r.act(.prepare); XCTAssertEqual(r.owner.snapshot.refusal, .trustedProduct); XCTAssertEqual(r.bottoms.count, 0)
        r.productOverride = nil; try await r.prepare()
        let bytes = try Data(contentsOf: r.namespace.appendingPathComponent("record.json"))
        let json = String(decoding: bytes, as: UTF8.self)
        for canary in [r.root.path, "PRIVATE_WORD", "PRIVATE_TRANSCRIPT", "PRIVATE_TOKEN", "\"pid\"", "\"filter\"", "\"url\""] { XCTAssertFalse(json.contains(canary)) }
    }
    func testDraftDuringLoadRevokesPreparationButRequiresAnotherExplicitPrepare() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        let gate = G2aLatch(), child = G2aChild(load: gate); r.bottoms.append(child)
        r.owner.act(.prepare, token: r.owner.snapshot.token); await child.native.entered.wait()
        r.owner.draftChanged(); r.owner.configure(r.settings)
        XCTAssertTrue(r.owner.hasWork); XCTAssertEqual(r.owner.snapshot.phase, .stopping)
        await gate.signal(); await r.wait(); XCTAssertNil(try r.record().prepared)
        try await r.prepare()
    }
    func testNonzeroLoadExitAndInterruptedPrepareReceiptRequireFreshExplicitLoad() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install()
        r.bottoms.append(G2aChild(exitCode: 256)); await r.act(.prepare)
        XCTAssertEqual(r.owner.snapshot.refusal, .loadCheck); XCTAssertNil(try r.record().prepared)
        let fresh = r.makeOwner(); fresh.reconcileOnce(); await r.wait()
        XCTAssertEqual(fresh.snapshot.phase, .installed); XCTAssertTrue(fresh.snapshot.canRetry)
        r.bottoms.append(G2aChild()); fresh.act(.retry, token: fresh.snapshot.token); await r.wait()
        XCTAssertEqual(fresh.snapshot.phase, .ready)
    }
    func testShutdownRechecksQueueAfterExternallyRetainedPinFinallyReleases() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; try await r.install(); try await r.prepare()
        var lease: ParakeetInstallationLease? = try await r.owner.preparedUse(.parakeet(model: ParakeetWire.model, filter: nil), operation: nil)
        let retired = expectation(description: "retirement callback"), reread = expectation(description: "chain reread after pin retirement"), done = expectation(description: "stable actual drain")
        r.owner.retireHandles = { retired.fulfill() }
        var changed = false, readChanged = false, replied = false
        r.owner.beginShutdown(chain: {
            if changed, r.owner.ownership.count == 0, !readChanged { readChanged = true; reread.fulfill() }
            return r.chain
        }) { replied = $0; done.fulfill() }
        await fulfillment(of: [retired], timeout: 3)
        let entered = G2aLatch(), released = G2aLatch(), operation = PendingOperation(name: "late already-owned queue work")
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: operation, completes: true, work: { await entered.signal(); await released.wait() })
        await entered.wait(); changed = true
        XCTAssertNotNil(lease); lease = nil
        await fulfillment(of: [reread], timeout: 3); XCTAssertFalse(replied)
        await released.signal(); await r.wait(); await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue(replied)
    }
    func testSiblingRetirementCallbackIsJoinedBeforeItsIndependentQuitReply() async {
        let rig = AppleOwnerRig(); rig.configure(); await rig.wait()
        let entered = G2aLatch(), released = G2aLatch(), done = expectation(description: "sibling retirement joined")
        rig.owner.retireHandles = { await entered.signal(); await released.wait() }
        var replied = false
        rig.owner.beginShutdown(chain: { rig.chain }) { replied = $0; done.fulfill() }
        await entered.wait(); XCTAssertFalse(replied)
        await released.signal(); await fulfillment(of: [done], timeout: 3); XCTAssertTrue(replied)
    }
}
