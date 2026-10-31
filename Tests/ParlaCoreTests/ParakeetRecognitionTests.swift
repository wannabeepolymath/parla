import XCTest
import Foundation
import CryptoKit
@testable import ParlaCore

actor ParakeetTestLatch {
    private var open = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { continuations.append($0) } } }
    func release() { open = true; let all = continuations; continuations = []; for c in all { c.resume() } }
}
actor ParakeetTestExit {
    var status: Int32?
    var waiters: [CheckedContinuation<Int32, Never>] = []
    func wait() async -> Int32 { if let status { return status }; return await withCheckedContinuation { waiters.append($0) } }
    func release(_ value: Int32 = 0) { guard status == nil else { return }; status = value; let all = waiters; waiters = []; for c in all { c.resume(returning: value) } }
}
actor ParakeetTestPipe: ParakeetChannel {
    var data = Data()
    var written = Data()
    var closed = false
    var pending: (Int, CheckedContinuation<Data, Error>)?
    let fragment: Int
    let onWrite: (@Sendable (Data) async throws -> Void)?
    let onClose: (@Sendable () async -> Void)?
    var joins = 0
    init(fragment: Int = 65_536, onWrite: (@Sendable (Data) async throws -> Void)? = nil, onClose: (@Sendable () async -> Void)? = nil) {
        self.fragment = fragment; self.onWrite = onWrite; self.onClose = onClose
    }
    func read(upTo count: Int) async throws -> Data {
        if !data.isEmpty { let part = data.prefix(min(count, fragment)); data.removeFirst(part.count); return part }
        if closed { return Data() }
        return try await withCheckedThrowingContinuation { pending = (count, $0) }
    }
    func write(_ bytes: Data) async throws {
        guard !closed else { throw ParakeetWire.Failure.io }
        written.append(bytes); try await onWrite?(bytes)
    }
    func feed(_ bytes: Data) { data.append(bytes); wake() }
    func close() async { if !closed { closed = true; wake(); await onClose?() } }
    func join() { joins += 1 }
    private func wake() {
        guard let (count, continuation) = pending, !data.isEmpty || closed else { return }
        pending = nil; let part = data.prefix(min(count, fragment)); data.removeFirst(part.count); continuation.resume(returning: part)
    }
}
struct ParakeetFakeOptions: Sendable {
    var text = "local result"
    var wrongNonce = false, duplicate = false, missing = false, truncated = false, trailing = false
    var nonzero = false, holdExit = false, holdIO = false, holdHello = false
}
actor ParakeetFakeState {
    let output: ParakeetTestPipe, errors: ParakeetTestPipe
    let exit: ParakeetTestExit
    let options: ParakeetFakeOptions
    var request: ParakeetWire.Record?
    var frames = Data()
    var samples: [Float] = []
    var cancellationCount = 0
    var finishedInput = false
    let inputEntered = ParakeetTestLatch(), canceled = ParakeetTestLatch(), exitObserved = ParakeetTestLatch(), controlCanceled = ParakeetTestLatch()
    init(output: ParakeetTestPipe, errors: ParakeetTestPipe, exit: ParakeetTestExit, options: ParakeetFakeOptions) {
        self.output = output; self.errors = errors; self.exit = exit; self.options = options
    }
    func control(_ data: Data) async throws {
        let (kind, count) = try ParakeetWire.parseHeader(data.prefix(8))
        guard count == data.count - 8 else { throw ParakeetWire.Failure.bounds }
        let record = try ParakeetWire.decode(data.dropFirst(8), kind: kind)
        if kind == .cancel { await controlCanceled.release() }
        if kind == .request {
            request = record
            if !options.holdHello { try await output.feed(ParakeetWire.encode(.init(identity: record.identity), kind: .hello)) }
        }
    }
    func pcm(_ data: Data) { frames.append(data) }
    func finishInput() async {
        guard !finishedInput else { return }; finishedInput = true
        do {
            var input = frames
            while !input.isEmpty {
                let (kind, count) = try ParakeetWire.parseHeader(input.prefix(8)); input.removeFirst(8)
                guard input.count >= count else { throw ParakeetWire.Failure.malformed }
                if kind == .pcm { samples += try ParakeetWire.samples(input.prefix(count)) }
                input.removeFirst(count)
            }
            if let request, !options.holdHello {
                let identity = options.wrongNonce ? ParakeetWire.Identity(helperBuild: request.identity.helperBuild, osScope: request.identity.osScope) : request.identity
                let terminal = try ParakeetWire.encode(.init(identity: identity, code: .completed, text: options.text), kind: .terminal)
                if !options.missing { await output.feed(options.truncated ? terminal.dropLast() : terminal) }
                if options.duplicate { await output.feed(terminal) }
                if options.trailing { await output.feed(Data([1])) }
            }
        } catch { /* the production driver must refuse incomplete input */ }
        await inputEntered.release()
        if !options.holdIO { await output.close(); await errors.close() }
        if !options.holdExit { await exit.release(options.nonzero ? 256 : 0) }
    }
    func cancel() async { cancellationCount += 1; await canceled.release() }
    func releaseIO() async { await output.close(); await errors.close() }
}
actor ParakeetTestWriteGate {
    let entered = ParakeetTestLatch(), resumed = ParakeetTestLatch()
    func block() async { await entered.release(); await resumed.wait() }
}
final class ParakeetFakeChild: ParakeetChild {
    let control: any ParakeetChannel, pcm: any ParakeetChannel, output: any ParakeetChannel, errors: any ParakeetChannel
    let state: ParakeetFakeState, exit: ParakeetTestExit
    init(_ options: ParakeetFakeOptions = .init(), fragment: Int = 65_536, pcmGate: ParakeetTestWriteGate? = nil) {
        let output = ParakeetTestPipe(fragment: fragment), errors = ParakeetTestPipe(), exit = ParakeetTestExit()
        let state = ParakeetFakeState(output: output, errors: errors, exit: exit, options: options)
        self.output = output; self.errors = errors; self.exit = exit; self.state = state
        control = ParakeetTestPipe(onWrite: { try await state.control($0) })
        pcm = ParakeetTestPipe(onWrite: { data in await pcmGate?.block(); await state.pcm(data) }, onClose: { await state.finishInput() })
    }
    func actualExit() async -> Int32 { let value = await exit.wait(); await state.exitObserved.release(); return value }
    func requestCancellation() async { await state.cancel() }
}
/// Narrow synchronized counter/clock used only by fake native/IO boundaries.
final class ParakeetTestCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var time: UInt64 = 1_000_000_000
    func add(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
    func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ nanos: UInt64) { lock.lock(); time += nanos; lock.unlock() }
}
struct ParakeetTestRig {
    let counters = ParakeetTestCounters()
    let binary: Data
    let resource = Data("resource fixture".utf8)
    let identity: ParakeetProductIdentity
    init() {
        var binary = Data()
        for n: UInt32 in [0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, 0x000e0000, 0, 0] {
            binary.append(contentsOf: [UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8(n >> 24)])
        }
        self.binary = binary
        identity = .init(protocolVersion: 1, adapterRevision: 1, sdk: ParakeetWire.sdk,
            helperSHA256: SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined(), sourceSHA256: String(repeating: "b", count: 64),
            resources: ["Contents/Resources/fixture": SHA256.hash(data: resource).map { String(format: "%02x", $0) }.joined()], team: "TESTTEAM123")
    }
    var trust: ParakeetTrustBottom {
        .init(host: { counters.add("host") }, read: { url, _ in
            counters.add("codeRead")
            if url.lastPathComponent == "parakeet-product.json" { return try JSONEncoder().encode(identity) }
            if url.lastPathComponent == "ParlaParakeetHelper" { return binary }
            if url.lastPathComponent == "fixture" { return resource }
            throw ParakeetRefusal.codeIdentity
        }, signature: { _, team in XCTAssertEqual(team, identity.team); counters.add("signature") })
    }
    func factory(_ child: ParakeetFakeChild, logicalClock: Bool = false) -> RecognitionFactory {
        let clock = logicalClock ? ParakeetClock(now: { counters.now() }, tick: { await Task.yield() }) : ParakeetClock()
        return RecognitionFactory(parakeetPreparedUse: { _, _ in
            counters.add("lease")
            return .init(directory: URL(fileURLWithPath: "/owned/leased"), product: identity, osScope: "fixture-os", release: { counters.add("release") })
        }, parakeetTrust: trust, parakeetApp: URL(fileURLWithPath: "/fixed/Parla.app"),
        parakeetWorker: .init(launch: { _ in counters.add("launch"); return child }, clock: clock),
        appleBottom: .init(available: { counters.add("apple"); throw ParakeetRefusal.configuration }, session: { _ in counters.add("apple"); throw ParakeetRefusal.configuration }),
        appleInstalledUse: { _, _ in counters.add("apple"); throw ParakeetRefusal.configuration },
        native: { _, _ in counters.add("whisper"); throw ParakeetRefusal.configuration },
        guardedNative: { _, _, _ in counters.add("whisper"); throw ParakeetRefusal.configuration },
        runtime: { counters.add("runtime"); return .init(nativeVersion: "forbidden", buildScope: "forbidden") },
        metadata: { _ in counters.add("metadata"); return nil }, admit: { _, _ in counters.add("admit") })
    }
    var settings: Settings {
        var settings = Settings(); settings.recognitionEngine = .parakeet; settings.parakeetLanguageFilter = "pl"
        settings.language = "hi"; settings.dictionary = ["PRIVATE_WORD"]; settings.whisperModelPath = "/PRIVATE_PATH"
        return settings
    }
}
final class ParakeetRecognitionTests: XCTestCase {
    func testActualFactoryTrustClientDriverAndIOProduceFinalCommandAndEmptyWithoutOtherPorts() async throws {
        for (pass, text) in [(RecognitionHandle.Pass.fullFinal, "local result"), (.command, ""), (.command, "command result")] {
            let rig = ParakeetTestRig(); var options = ParakeetFakeOptions(); options.text = text
            let child = ParakeetFakeChild(options, fragment: 1)
            let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings))
            XCTAssertTrue(handle.client is ParakeetRecognition); XCTAssertEqual(handle.identity?.engine, .parakeet)
            XCTAssertFalse(handle.identity?.reusable ?? true)
            let samples = [Float](repeating: 0.25, count: 16_000)
            let result = await handle.recognize(samples, pass: pass)
            XCTAssertEqual(result.text, text); XCTAssertEqual(result.native, .completed(.init(text: text)))
            let received = await child.state.samples; XCTAssertEqual(received, samples)
            let request = await child.state.request; XCTAssertEqual(request?.filter, "pl")
            XCTAssertEqual(request?.identity.sdk, ParakeetWire.sdk)
            XCTAssertEqual(rig.counters.value("launch"), 1); XCTAssertEqual(rig.counters.value("signature"), 1)
            for port in ["whisper", "apple", "metadata", "admit", "runtime"] { XCTAssertEqual(rig.counters.value(port), 0, port) }
        }
    }
    func testPromptPreviewAndInvalidPCMAreRefusedBeforeLaunchAndDefaultIsUnavailable() async throws {
        let rig = ParakeetTestRig(), child = ParakeetFakeChild()
        let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings))
        let prompt = await handle.recognize([0.5], pass: .fullFinal, initialPrompt: "REQUIRED")
        XCTAssertEqual(prompt.native, .failed(.unsupportedCapability))
        let preview = await handle.recognize([0.5], pass: .streamHead("FOREIGN_PREFIX"))
        XCTAssertEqual(preview.native, .failed(.unsupportedCapability))
        let bad = await handle.recognize([.nan], pass: .fullFinal)
        XCTAssertNil(bad.text); XCTAssertEqual(rig.counters.value("launch"), 0)
        do { _ = try await RecognitionFactory().acquire(request: .init(settings: rig.settings)); XCTFail("default must refuse") }
        catch { XCTAssertEqual(error as? ParakeetRefusal, .needsPreparation) }
        do { _ = try await rig.factory(child).acquire(request: .init(settings: rig.settings), policy: .readOnlyCatalog); XCTFail("B57 must refuse") }
        catch { XCTAssertEqual(error as? ParakeetRefusal, .configuration) }
        XCTAssertEqual(rig.counters.value("lease"), 1)
    }
    func testSettingsProfileNoneInheritanceLegacyConflictAndUnknownFilter() throws {
        let rig = ParakeetTestRig(); var settings = rig.settings
        settings.parakeetLanguageFilter = "fr"
        var profile = DictationProfile(); profile.name = "fixture"; profile.target = "com.fixture.editor"
        settings.profiles = [profile]
        let destination = ProfileDestination(bundleID: profile.target)
        XCTAssertEqual(ProfileResolver.resolve(settings, at: destination).settings.parakeetLanguageFilter, "fr")
        profile.parakeetLanguageFilter = "none"; settings.profiles = [profile]
        XCTAssertNil(ProfileResolver.resolve(settings, at: destination).settings.parakeetLanguageFilter)
        profile.language = "hi"; settings.profiles = [profile]
        XCTAssertEqual(RecognitionRequest(settings: ProfileResolver.resolve(settings, at: destination).settings).selection, .invalid)
        profile.recognitionEngine = .whisper; settings.profiles = [profile]
        XCTAssertEqual(RecognitionRequest(settings: ProfileResolver.resolve(settings, at: destination).settings).selection.engine, .whisper)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).recognitionEngine, .whisper)
        for bad in ["hi", "none", "bs", "EN", ""] {
            let data = try JSONSerialization.data(withJSONObject: ["recognitionEngine": "parakeet", "parakeetLanguageFilter": bad])
            XCTAssertEqual(RecognitionRequest(settings: try JSONDecoder().decode(Settings.self, from: data)).selection, .invalid)
        }
    }
    func testCapabilitiesPrivacyAndTextOnlyEntryHaveNoASRSideEffects() async throws {
        let rig = ParakeetTestRig(); var options = ParakeetFakeOptions(); options.text = "PRIVATE_TRANSCRIPT_CANARY"
        let child = ParakeetFakeChild(options), store = DiagnosticStore(now: { 1 })
        let diagnostics = store.start(id: UUID(), origin: .dictation)
        let request = RecognitionRequest(settings: rig.settings)
        XCTAssertFalse(CanceledCaptureLimits.accepts(request)) // before any B57 offer/RAM retention
        let factory = rig.factory(child)
        let eval = EvalRecognition()
        try await eval.acquire(needsASR: false, request: { XCTFail("text-only evaluated request"); return request }, factory: factory)
        XCTAssertEqual(rig.counters.value("lease"), 0); XCTAssertEqual(rig.counters.value("codeRead"), 0)
        let handle = try await factory.acquire(request: request, diagnostics: diagnostics)
        let result = await handle.recognize([0.5], pass: .fullFinal, diagnostics: diagnostics)
        XCTAssertEqual(result.text, options.text)
        XCTAssertFalse(handle.client.capabilities.manualTextPrompt); XCTAssertFalse(handle.client.capabilities.shadowWindows)
        XCTAssertFalse(handle.client.capabilities.automaticLanguage); XCTAssertFalse(handle.client.capabilities.wordTiming)
        let json = String(decoding: try store.snapshot().encoded(), as: UTF8.self)
        for secret in ["PRIVATE_TRANSCRIPT_CANARY", "PRIVATE_WORD", "PRIVATE_PATH", "/owned/leased", "fixture-os", "TESTTEAM123"] { XCTAssertFalse(json.contains(secret), secret) }
        XCTAssertTrue(json.contains("parakeet")); XCTAssertTrue(json.contains("provisionalMixedMetadata"))
    }

}
