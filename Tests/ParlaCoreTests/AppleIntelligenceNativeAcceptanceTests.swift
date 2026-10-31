// Artifact-only proposal. Native gate is a guard, never runtime authorization.
// Root must separately authorize installation, compilation and each exact check.
import XCTest
import Foundation
import ParlaCore
#if os(macOS)
import Darwin
import CryptoKit

private let b22Input = "Please review the complete proposal before the meeting tomorrow"
private let b22Token = "owned-synthetic-v1"

final class AppleIntelligenceNativeAcceptanceTests: XCTestCase {
    func testOwnedSyntheticSingleCall() async throws {
        // No settings, clocks, IO, runtime or readiness construction before admission.
        let destination: B22Destination
        do {
            destination = try B22Admission.admit(read: B22Admission.namedEnvironment,
                                                  validate: B22Destination.init)
        } catch B22Admission.Refusal.gateOff {
            throw XCTSkip("NOT_RUN_GATE_OFF") // No result file on the gate-off path.
        } catch {
            XCTFail("HARNESS_FAILED: result_root_admission")
            return
        }
        let trace = B22Trace()
        let recordingStart = ProcessInfo.processInfo.systemUptime
        // All bottom functions are explicit; no runtime default can query the OS.
        let native = LocalCleanupRuntime(
            availability: { LocalCleanupNative.availability($0) },
            language: { LocalCleanupNative.language($0) },
            generate: { try await LocalCleanupNative.generate($0, attempted: $1) },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
            appLocale: { "en_US" })
        var result = await B22Harness.run(bottom: native, trace: trace)
        // A joined result cannot regain publication authority after cancellation/expiry.
        let recordingElapsed = ProcessInfo.processInfo.systemUptime - recordingStart
        if Task.isCancelled {
            result = result.nonpositive(.canceled, reason: .canceled, callerCanceled: true)
        } else if result.state == .accepted && recordingElapsed >= 15 {
            result = result.nonpositive(.returnRejected, reason: .deadline)
        }
        result.recordingElapsedMilliseconds = Int(max(0, min(86_400, recordingElapsed)) * 1000)
        do { try destination.write(result) }
        catch {
            XCTFail("HARNESS_FAILED: metadata_capture")
            return // Empty/partial metadata can never qualify an observation.
        }
        switch result.state {
        case .accepted:
            XCTAssertTrue(result.qualifies)
        case .initialRefusal:
            throw XCTSkip("REFUSED_INITIAL") // Metadata distinguishes this from gate off.
        default:
            XCTFail("Native observation nonpositive: \(result.state.rawValue)/\(result.reason)")
        }
    }

    func testGateAndHarnessControls() async throws {
        // Synthetic admission bottoms only; no getenv, filesystem or native wrappers.
        for token in [Optional<String>.none, "wrong", "owned-synthetic-v1 "] {
            var keys: [String] = [], roots = 0, bodies = 0
            do {
                let _: Bool = try B22Admission.admit(read: { key in
                    keys.append(key); return token
                }, validate: { _ in roots += 1; return true })
                bodies += 1
                XCTFail("gate admitted")
            } catch B22Admission.Refusal.gateOff {} catch { XCTFail("unexpected gate state") }
            XCTAssertEqual(keys, ["PARLA_B22_NATIVE_CHECK"])
            XCTAssertEqual(roots, 0)
            XCTAssertEqual(bodies, 0)
        }
        for path in [Optional<String>.none, "relative", "/", "/owned/../root", "/owned//root", "/owned/root/", "/owned/\0root"] {
            var roots = 0, bodies = 0
            do {
                let _: Bool = try B22Admission.admit(read: { key in
                    key == "PARLA_B22_NATIVE_CHECK" ? b22Token : path
                }, validate: { _ in roots += 1; return true })
                bodies += 1
                XCTFail("bad path admitted")
            } catch B22Admission.Refusal.invalidRoot {} catch { XCTFail("unexpected path state") }
            XCTAssertEqual(roots, 0)
            XCTAssertEqual(bodies, 0)
        }
        // A lexical path is insufficient: physical/ownership refusal precedes the body.
        var bodyEntered = false
        do {
            let _: Bool = try B22Admission.admit(read: { key in
                key == "PARLA_B22_NATIVE_CHECK" ? b22Token : "/owned/synthetic"
            }, validate: { _ -> Bool in throw B22Admission.Refusal.invalidRoot })
            bodyEntered = true
        } catch B22Admission.Refusal.invalidRoot {} catch { XCTFail("unexpected root state") }
        XCTAssertFalse(bodyEntered)

        let refusals: [LocalCleanupReason] = [.oldOS, .missingFramework, .ineligible,
            .disabled, .notReady, .unavailable, .unsupportedLanguage]
        for reason in refusals {
            let initial = B22Fake(initial: reason)
            let first = await B22Harness.run(bottom: initial.runtime, trace: B22Trace())
            XCTAssertEqual(first.state, .initialRefusal)
            XCTAssertEqual(first.reason, reason.rawValue)
            XCTAssertEqual(first.events.generations, 0)
            XCTAssertEqual(first.events.languages, 0)
            XCTAssertEqual(first.events.availability, 1)
            XCTAssertFalse(first.events.queueAdmitted)
            XCTAssertFalse(first.qualifies)
            assertTraps(first)

            let changed = B22Fake(request: reason)
            let second = await B22Harness.run(bottom: changed.runtime, trace: B22Trace())
            XCTAssertEqual(second.state, .requestRefusal)
            XCTAssertEqual(second.reason, reason.rawValue)
            XCTAssertEqual(second.events.generations, 0)
            XCTAssertEqual(second.events.attempted, 0)
            XCTAssertEqual(second.events.watchdogEntries, 0)
            XCTAssertTrue(second.events.operationExited && second.events.barrierExited)
            XCTAssertFalse(second.qualifies)
            assertTraps(second)
        }
        let accepted = await B22Harness.run(bottom: B22Fake().runtime, trace: B22Trace())
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertTrue(accepted.qualifies)
        XCTAssertEqual(accepted.events.generations, 1)
        XCTAssertEqual(accepted.events.attempted, 1)
        XCTAssertEqual(accepted.events.attemptedReturned, 1)
        XCTAssertEqual(accepted.events.nativeReturns, 1)
        XCTAssertEqual(accepted.events.generatorExits, 1)
        XCTAssertEqual(accepted.events.providerAccepted, 1)
        XCTAssertEqual(accepted.events.watchdogEntries, 1)
        XCTAssertEqual(accepted.events.watchdogExits, 1)
        XCTAssertEqual(accepted.events.usage, 1) // Injected RAM-only sink; no global usage.
        assertTraps(accepted)

        for (mode, reason) in [(B22Fake.Mode.empty, LocalCleanupReason.empty),
                               (.safety, .refusedOrSafety), (.late, .deadline)] {
            let rejected = await B22Harness.run(bottom: B22Fake(mode: mode).runtime, trace: B22Trace())
            XCTAssertEqual(rejected.state, .returnRejected)
            XCTAssertEqual(rejected.reason, reason.rawValue)
            XCTAssertEqual(rejected.events.generations, 1)
            XCTAssertEqual(rejected.events.attempted, 1)
            XCTAssertEqual(rejected.events.generatorExits, 1)
            XCTAssertEqual(rejected.events.watchdogExits, 1)
            XCTAssertEqual(rejected.events.providerAccepted, 0)
            XCTAssertEqual(rejected.events.usage, 0)
            XCTAssertNil(rejected.output)
            XCTAssertFalse(rejected.qualifies)
            assertTraps(rejected)
        }
        // Valid language/size at the adapter can still fail the real Pipeline ceiling.
        let ceiling = await B22Harness.run(bottom: B22Fake(mode: .pipelineCeiling).runtime, trace: B22Trace())
        XCTAssertEqual(ceiling.state, .returnRejected)
        XCTAssertEqual(ceiling.reason, "pipeline_validation")
        XCTAssertEqual(ceiling.events.providerAccepted, 1)
        XCTAssertEqual(ceiling.events.guardAccepted, 0)
        XCTAssertFalse(ceiling.qualifies)
        assertTraps(ceiling)

        let held = B22Fake(mode: .held), trace = B22Trace()
        let operation = PendingOperation(name: "B22 synthetic held", diagnostics: nil)
        let running = Task { await B22Harness.run(bottom: held.runtime, trace: trace, operation: operation) }
        await held.started.wait()
        operation.revoke(); operation.requestAbort()
        await held.cancelSeen.wait()
        XCTAssertTrue(operation.shouldAbort)
        XCTAssertFalse(operation.hasExited)
        XCTAssertEqual(trace.snapshot.pipelineCompletions, 0)
        XCTAssertFalse(trace.snapshot.barrierExited)
        // Release even if assertions fail. No expectation timeout can abandon held work.
        held.release.open()
        let canceled = await running.value
        XCTAssertEqual(canceled.state, .canceled)
        XCTAssertFalse(canceled.qualifies)
        XCTAssertTrue(canceled.events.operationExited && canceled.events.barrierExited)
        XCTAssertEqual(canceled.events.generatorExits, 1)
        XCTAssertEqual(canceled.events.watchdogExits, 1)
        XCTAssertEqual(canceled.events.guardAccepted, 0)
        XCTAssertEqual(canceled.events.usage, 0)
        assertTraps(canceled)
    }

    private func assertTraps(_ result: B22Record, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.events.environment, 0, file: file, line: line)
        XCTAssertEqual(result.events.credentials, 0, file: file, line: line)
        XCTAssertEqual(result.events.http, 0, file: file, line: line)
    }
}

private enum B22Admission {
    enum Refusal: Error { case gateOff, invalidRoot, capture }
    static func admit<T>(read: (String) -> String?, validate: (String) throws -> T) throws -> T {
        guard read("PARLA_B22_NATIVE_CHECK") == b22Token else { throw Refusal.gateOff }
        guard let path = read("PARLA_B22_RESULT_DIR"), validPath(path) else { throw Refusal.invalidRoot }
        return try validate(path)
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 4096 && !path.utf8.contains(0) && parts.count > 1
            && parts.first == "" && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func namedEnvironment(_ key: String) -> String? {
        // Deliberately avoid ProcessInfo.environment, which enumerates unrelated secrets.
        guard key == "PARLA_B22_NATIVE_CHECK" || key == "PARLA_B22_RESULT_DIR",
              let pointer = getenv(key) else { return nil }
        let limit = key == "PARLA_B22_NATIVE_CHECK" ? 64 : 4097
        let count = strnlen(pointer, limit)
        guard count < limit else { return nil }
        return String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: count), encoding: .utf8)
    }
}

// The supplied directory is traversed physically from / with O_NOFOLLOW on every
// component. Only the final owned 0700 directory is enumerated, never app data.
// It must be empty. Reserve metadata exclusively before constructing native work.
private final class B22Destination {
    private let directory: Int32, file: Int32
    private let path: String
    private let device: dev_t, inode: ino_t
    private let name = "b22-result.json"
    private var written = false

    init(_ path: String) throws {
        let directory = try Self.openDirectory(path)
        var reserved: Int32 = -1
        do {
            try Self.checkEmpty(directory)
            reserved = openat(directory, "b22-result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard reserved >= 0 else { throw B22Admission.Refusal.invalidRoot }
            var value = stat()
            guard fstat(reserved, &value) == 0, Self.ownedFile(value), value.st_size == 0 else { throw B22Admission.Refusal.invalidRoot }
            self.directory = directory; self.file = reserved; self.path = path
            self.device = value.st_dev; self.inode = value.st_ino
        } catch {
            if reserved >= 0 { close(reserved) }
            close(directory)
            throw error // Preserve resources/evidence; never unlink an admitted result.
        }
    }
    deinit { close(file); close(directory) }

    private static func openDirectory(_ path: String) throws -> Int32 {
        guard B22Admission.validPath(path) else { throw B22Admission.Refusal.invalidRoot }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw B22Admission.Refusal.invalidRoot }
        do {
            for part in path.split(separator: "/") {
                let next = String(part).withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { throw B22Admission.Refusal.invalidRoot }
                close(current); current = next
            }
            var value = stat()
            guard fstat(current, &value) == 0, (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  value.st_uid == geteuid(), value.st_mode & mode_t(0o7777) == mode_t(0o700) else { throw B22Admission.Refusal.invalidRoot }
            return current
        } catch { close(current); throw error }
    }
    private static func checkEmpty(_ directory: Int32) throws {
        let copy = dup(directory)
        guard copy >= 0 else { throw B22Admission.Refusal.invalidRoot }
        guard let stream = fdopendir(copy) else { close(copy); throw B22Admission.Refusal.invalidRoot }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            let isDot = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    let name = String(cString: $0)
                    return name == "." || name == ".."
                }
            }
            guard isDot else { throw B22Admission.Refusal.invalidRoot }
            errno = 0
        }
        guard errno == 0 else { throw B22Admission.Refusal.invalidRoot }
    }
    private static func ownedFile(_ value: stat) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && value.st_uid == geteuid()
            && value.st_nlink == 1 && value.st_mode & mode_t(0o7777) == mode_t(0o600)
    }
    func write(_ result: B22Record) throws {
        guard !written, result.state != .accepted || result.qualifies else { throw B22Admission.Refusal.capture }
        written = true
        let data = try JSONEncoder().encode(result)
        guard data.count <= 16 * 1024 else { throw B22Admission.Refusal.capture }
        // Reopen the physical path and require identity with the retained directory.
        let reopened = try Self.openDirectory(path)
        defer { close(reopened) }
        var old = stat(), current = stat(), entry = stat(), output = stat()
        guard fstat(directory, &old) == 0, fstat(reopened, &current) == 0,
              old.st_dev == current.st_dev, old.st_ino == current.st_ino,
              fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(file, &output) == 0, Self.ownedFile(entry), Self.ownedFile(output),
              entry.st_dev == device, entry.st_ino == inode, output.st_dev == device,
              output.st_ino == inode, output.st_size == 0 else { throw B22Admission.Refusal.capture }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw B22Admission.Refusal.capture }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw B22Admission.Refusal.capture }
                offset += count
            }
        }
        guard fsync(file) == 0, fstat(file, &output) == 0, Self.ownedFile(output),
              output.st_size == off_t(data.count),
              fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              Self.ownedFile(entry), entry.st_dev == device, entry.st_ino == inode else { throw B22Admission.Refusal.capture }
    }
}

private struct B22Fingerprint: Codable {
    let bytes: Int
    let sha256: String
    init(_ text: String) {
        let bytes = Data(text.utf8)
        self.bytes = bytes.count
        self.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct B22Events: Codable {
    var availability = 0, languages = 0, generations = 0, attempted = 0, attemptedReturned = 0
    var nativeReturns = 0, generatorExits = 0, watchdogEntries = 0, watchdogExits = 0
    var providerEntries = 0, providerAccepted = 0, pipelineCompletions = 0, guardAccepted = 0
    var environment = 0, credentials = 0, http = 0, usage = 0
    var queueAdmitted = false, operationExited = false, barrierExited = false, revoked = false
    var callerCanceled = false
    var reason: LocalCleanupReason?
    var lastAvailability = "not_checked"
    var nativeOutput: B22Fingerprint?
    var rawOutputOverLimit = false
    var finalOutput: B22Fingerprint?
    var pipelineFailed = false
}
private final class B22Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var value = B22Events()
    var snapshot: B22Events { lock.withLock { value } }
    func update(_ change: (inout B22Events) -> Void) { lock.withLock { change(&value) } }
    func forbidden<T>(_ key: String) -> T {
        update {
            switch key { case "environment": $0.environment += 1
            case "credentials": $0.credentials += 1
            default: $0.http += 1 }
        }
        fatalError("B22 forbidden dependency evaluated") // No fallback/store/session construction.
    }
    func instrument(_ bottom: LocalCleanupRuntime) -> LocalCleanupRuntime {
        LocalCleanupRuntime(availability: { locales in
            self.update { $0.availability += 1 }
            let reason = bottom.availability(locales)
            self.update { $0.lastAvailability = reason?.rawValue ?? "available" }
            return reason
        }, language: { text in
            self.update { $0.languages += 1 }
            return bottom.language(text)
        }, generate: { prompt, attempted in
            self.update { $0.generations += 1 }
            defer { self.update { $0.generatorExits += 1 } }
            do {
                let text = try await bottom.generate(prompt) {
                    self.update { $0.attempted += 1 }
                    try attempted()
                    self.update { $0.attemptedReturned += 1 }
                }
                // At most 32769 bytes traversed before deciding to omit its digest.
                let boundedCount = text.utf8.prefix(32 * 1024 + 1).count
                let digest = boundedCount <= 32 * 1024 ? B22Fingerprint(text) : nil
                self.update {
                    $0.nativeReturns += 1; $0.nativeOutput = digest
                    $0.rawOutputOverLimit = boundedCount > 32 * 1024
                }
                return text
            } catch {
                self.update { $0.reason = LocalCleanupReason.from(error) ?? .unavailable }
                throw error
            }
        }, now: bottom.now, sleep: { duration in
            self.update { $0.watchdogEntries += 1 }
            defer { self.update { $0.watchdogExits += 1 } }
            try await bottom.sleep(duration)
        }, appLocale: bottom.appLocale)
    }
}
private struct B22Provider: CleanupProviding {
    let base: CleanupProviding
    let trace: B22Trace
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        trace.update { $0.providerEntries += 1 }
        do {
            let value = try await base.clean(transcript: transcript, context: context)
            trace.update { $0.providerAccepted += 1 }
            return value
        } catch {
            trace.update { $0.reason = LocalCleanupReason.from(error) ?? .unavailable }
            throw error
        }
    }
}

private struct B22Record: Encodable {
    enum State: String, Codable {
        case initialRefusal = "REFUSED_INITIAL", requestRefusal = "REFUSED_REQUEST"
        case returnRejected = "NATIVE_RETURN_REJECTED", accepted = "NATIVE_ACCEPTED_GUARDED"
        case canceled = "CANCELED_JOINED", failed = "HARNESS_FAILED"
    }
    let schema = "parla-b22-owned-synthetic-v1"
    let state: State
    let reason: String
    let input: B22Fingerprint
    let output: B22Fingerprint?
    let events: B22Events
    let elapsedMilliseconds: Int
    var recordingElapsedMilliseconds: Int? = nil
    let appLocale = "en_US"
    let logicalAcceptanceSeconds = 15
    // Raw XCTest/child exit is intentionally not supplied by this test.
    let processExitAuthority = "external_runner_only"
    func nonpositive(_ state: State, reason: LocalCleanupReason, callerCanceled: Bool = false) -> B22Record {
        var observed = events
        observed.reason = reason; observed.callerCanceled = observed.callerCanceled || callerCanceled
        observed.finalOutput = nil
        return B22Record(state: state, reason: reason.rawValue, input: input, output: nil,
                         events: observed, elapsedMilliseconds: elapsedMilliseconds)
    }
    var qualifies: Bool {
        state == .accepted && reason == "none" && events.queueAdmitted
            && events.operationExited && events.barrierExited && !events.revoked && !events.callerCanceled
            && events.generations == 1 && events.generatorExits == 1
            && events.attempted == 1 && events.attemptedReturned == 1
            && events.nativeReturns == 1 && events.nativeOutput != nil && !events.rawOutputOverLimit
            && events.providerEntries == 1 && events.providerAccepted == 1
            && events.watchdogEntries == 1 && events.watchdogExits == 1
            && events.pipelineCompletions == 1 && events.guardAccepted == 1 && !events.pipelineFailed
            && events.usage == 1 && events.environment == 0 && events.credentials == 0 && events.http == 0
            && events.reason == nil && output != nil && output?.sha256 == events.finalOutput?.sha256
            && events.lastAvailability == "available"
            && elapsedMilliseconds >= 0 && elapsedMilliseconds < 15_000
            && (recordingElapsedMilliseconds.map { $0 >= 0 && $0 < 15_000 } ?? true)
    }
}

private enum B22Harness {
    static func settings() -> Settings {
        var value = Settings()
        value.cleanup.provider = "apple-intelligence"; value.cleanup.localSourceLocale = "en"
        value.cleanup.baseURL = nil; value.cleanup.model = nil
        value.cleanup.apiKey = nil; value.cleanup.apiKeyEnvVar = nil; value.anthropicApiKey = nil
        value.cleanupModel = ""; value.outputMode = .cleanup; value.cleanupEnabled = true
        value.dictionary = []; value.snippets = [:]; value.replacements = []
        value.profiles = []; value.transformPresets = []; value.selectedPresetID = nil
        value.cleanupFailover = nil; value.physicalSurroundingTextGrant = nil
        value.historyEnabled = false; value.recoveryAudioEnabled = false; value.automationEnabled = false
        value.keepLastOriginalEnabled = false; value.warmMic = false; value.streamPreviewEnabled = false
        value.nativePreparationSafeStartEnabled = false; value.nativePreparationConsent = nil
        value.recognitionPreviewModelID = nil
        return value // Value only; never SettingsStore/load/save, recognition or app bootstrap.
    }
    static func run(bottom: LocalCleanupRuntime, trace: B22Trace,
                    operation supplied: PendingOperation? = nil) async -> B22Record {
        let start = bottom.now(), runtime = trace.instrument(bottom), settings = settings()
        let input = B22Fingerprint(b22Input)
        func record(_ state: B22Record.State, _ reason: String) -> B22Record {
            let elapsed = max(0, min(86_400, bottom.now() - start))
            return B22Record(state: state, reason: reason, input: input,
                             output: trace.snapshot.finalOutput, events: trace.snapshot,
                             elapsedMilliseconds: Int(elapsed * 1000))
        }
        if let reason = runtime.recheck(LocalCleanupConfiguration(settings: settings)) {
            trace.update { $0.reason = reason }
            return record(.initialRefusal, reason.rawValue)
        }
        let operation = supplied ?? PendingOperation(name: "B22 owned synthetic", diagnostics: nil)
        trace.update { $0.queueAdmitted = true }
        let barrier = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            var pipe = Pipeline(outputSettings: settings, bundleID: nil, diagnostics: nil,
                                failureLogging: .contentFree) { frozen in
                let base = try makeCleanupClient(settings: frozen,
                    env: trace.forbidden("environment"), credentials: trace.forbidden("credentials"),
                    http: trace.forbidden("http"), localRuntime: runtime, executionPolicy: nil,
                    usage: { _, _, _ in trace.update { $0.usage += 1 } })
                return B22Provider(base: base, trace: trace)
            }
            pipe.log = { _ in } // No global diagnostic/metrics sinks.
            let value = await pipe.clean(transcript: b22Input)
            let accepted = value.failure == nil && !Task.isCancelled && !operation.shouldAbort
                && operation.claimFinalResult()
            let fingerprint = accepted ? B22Fingerprint(value.text) : nil
            trace.update {
                $0.pipelineCompletions += 1; $0.pipelineFailed = value.failure != nil
                $0.guardAccepted = accepted ? 1 : 0; $0.finalOutput = fingerprint
            }
        })
        // Parent cancellation revokes the operation and cancels only its child.
        // Still join the serial barrier; never cancel it or use an early timeout race.
        await withTaskCancellationHandler(operation: { await barrier.value }, onCancel: {
            operation.revoke(); operation.requestAbort()
        })
        trace.update {
            $0.operationExited = operation.hasExited; $0.barrierExited = true
            $0.revoked = operation.shouldAbort; $0.callerCanceled = Task.isCancelled
        }
        let events = trace.snapshot
        guard events.operationExited, events.barrierExited, events.pipelineCompletions == 1,
              events.generatorExits == events.generations, events.watchdogExits == events.watchdogEntries,
              events.environment == 0, events.credentials == 0, events.http == 0 else { return record(.failed, "join_or_provenance") }
        if events.revoked || events.callerCanceled || events.reason == .canceled { return record(.canceled, LocalCleanupReason.canceled.rawValue) }
        if let reason = events.reason {
            return record(events.generations == 0 ? .requestRefusal : .returnRejected, reason.rawValue)
        }
        if events.pipelineFailed { return record(.returnRejected, "pipeline_validation") }
        let candidate = record(.accepted, "none")
        return candidate.qualifies ? candidate : record(.failed, "acceptance_provenance")
    }
}

// One-shot fake signals. No XCTest expectations, task handles or owner callbacks
// are retained in these objects; every admitted fake worker is explicitly joined.
private final class B22Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if opened { return true }; waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let callbacks = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !opened else { return [] }; opened = true
            let callbacks = waiters; waiters = []; return callbacks
        }
        for callback in callbacks { callback.resume() }
    }
}
private final class B22CancellableWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var canceled = false
    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let stopped = lock.withLock { () -> Bool in
                    if canceled { return true }; self.continuation = continuation; return false
                }
                if stopped { continuation.resume(throwing: CancellationError()) }
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        let callback = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            canceled = true
            let callback = continuation; continuation = nil; return callback
        }
        callback?.resume(throwing: CancellationError())
    }
}
private final class B22Fake: @unchecked Sendable {
    enum Mode { case ordinary, empty, safety, late, held, pipelineCeiling }
    let started = B22Latch(), release = B22Latch(), cancelSeen = B22Latch()
    private let watchdog = B22CancellableWait(), lock = NSLock()
    private var time: TimeInterval = 100
    private var checks = 0
    private let initial: LocalCleanupReason?, request: LocalCleanupReason?, mode: Mode
    init(initial: LocalCleanupReason? = nil, request: LocalCleanupReason? = nil, mode: Mode = .ordinary) {
        self.initial = initial; self.request = request; self.mode = mode
    }
    var runtime: LocalCleanupRuntime {
        LocalCleanupRuntime(availability: { _ in
            self.lock.withLock { self.checks += 1; return self.checks == 1 ? self.initial : self.request }
        }, language: { _ in ["en": 0.99, "hi": 0.01] }, generate: { _, attempted in
            try attempted()
            if self.mode == .held {
                return await withTaskCancellationHandler(operation: {
                    self.started.open(); await self.release.wait(); return b22Input + "."
                }, onCancel: { self.cancelSeen.open() })
            }
            if self.mode == .safety { throw LocalCleanupReason.refusedOrSafety }
            if self.mode == .empty { return "" }
            if self.mode == .late { self.lock.withLock { self.time = 115 } }
            if self.mode == .pipelineCeiling { return String(repeating: b22Input + " ", count: 8) }
            return b22Input + "."
        }, now: { self.lock.withLock { self.time } }, sleep: { _ in
            try await self.watchdog.wait()
        }, appLocale: { "en_US" })
    }
}
#endif
