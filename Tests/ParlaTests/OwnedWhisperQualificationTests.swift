// Correction/control candidate: UNCOMPILED / UNREVIEWED / NONEXECUTED. Historical native evidence unchanged.
// B53 first-request delta: UNCOMPILED / UNREVIEWED / NONEXECUTED; separate future root grants required.
// Selector: OwnedWhisperQualificationTests/testOwnedNativeTimedImport
// One app timed request, not measured C-internal invocation count or acoustic qualification.
// Root must stage the manifest/composite and supervise ONE child externally:
// 120s logical deadline -> SIGUSR1 -> 5s actual-exit grace -> owned-group SIGKILL;
// bounded exit/EOF observation, no successor/retry/cleanup after unsettled work.
// Construction is noncancellable; no process RSS, GPU/cache, or OS-IO containment promise.
import CryptoKit
import Darwin
import Foundation
import MachO
import XCTest
@testable import ParlaCore
@testable import Parla

final class OwnedWhisperQualificationTests: XCTestCase {
    // Artifact only: UNCOMPILED / UNREVIEWED / NONEXECUTED. Exact-stage supervision required.
    @MainActor func testOwnedGuardedInferenceCancellation() async throws {
        guard let gate = ownedControl(OwnedCancellationGate.owner) else {
            throw XCTSkip("Owned callback cancellation is off.")
        }
        try OwnedCancellationGate.validate(gate, owner: true)
        let config = try OwnedConfiguration()
        try OwnedCancellationGate.ownerRoot(config.runRoot)
        let counts = OwnedCounts()
        let files = try OwnedOutputs(root: config.runRoot, counts: counts, cancellation: true)
        let observer = OwnedCallbackInterval()
        let abort = try OwnedAbortPort(onRequest: { observer.invalidate() })
        var rig: OwnedImportRig?
        var health: OwnedCancellationHealth?
        var input: OwnedPrepared?
        var controller: OwnedCancellationController?
        var positive = false
        var closing = false
        var chainReturned = false
        var sentinelReturned = false
        do {
            let prepared = try await OwnedPrepared.read(config, files: files, abort: abort,
                requiredCompositeSHA256: OwnedFirstRequestHealth.compositeSHA256, retainReference: false)
            input = prepared
            let journal = try OwnedCancellationHealth(files: files)
            health = journal
            let connected = try OwnedImportRig(config: config, input: prepared, files: files,
                abort: abort, counts: counts, cancellationHealth: journal,
                nativeDecorator: { OwnedCallbackContext($0, observer: observer) })
            rig = connected
            let control = OwnedCancellationController(rig: connected, health: journal, observer: observer)
            controller = control
            observer.install { [weak control] token in
                Task { @MainActor [weak control] in control?.intervene(token) }
            }
            await connected.run() // yields main; native callback alone triggers the intervention.
        } catch { observer.invalidate() } // fixed nonpositive metadata only; never error text.
        // Retain the rig, context and control through the actual production chain's return.
        // No timeout/cancel task is accepted as an exit observation.
        if let chain = rig?.chain { await chain.value; chainReturned = true }
        if let sentinel = controller?.sentinel { await sentinel.value; sentinelReturned = true }
        observer.disposeNotification()
        if let input {
            do { try await input.verifyClosing(config); closing = true }
            catch { observer.invalidate() }
        }
        let restored = await abort.close()
        if abort.requested || !restored { observer.invalidate() }
        if let rig, let health, let controller {
            do {
                try require(chainReturned && sentinelReturned && closing && restored && !abort.requested)
                try controller.verifyReturned()
                try rig.verifyCancellation(health: health)
                try observer.requirePositive()
                positive = true
            } catch { observer.invalidate() }
        }
        let proof = OwnedCancellationProof(positive: positive, callback: observer.snapshot,
            publications: health?.publications ?? [], link: controller?.link,
            chainReturned: chainReturned, sentinelReturned: sentinelReturned,
            operationExited: rig?.owner.job?.operation.hasExited == true,
            sourceClosed: rig?.owner.job?.source.isClosed == true,
            coreActive: health?.core.hasActiveEntry ?? false,
            nativeCanceled: rig?.diagnosticOutcome == "canceled",
            deliveryCanceled: rig?.diagnostics.snapshot().records.first?.recognition?.deliveryCanceled == true,
            closingVerified: closing, safetyRequested: abort.requested, safetyRestored: restored,
            zeroSideEffects: rig?.cancellationSideEffectsAreZero == true)
        try files.json(proof, name: "cancellation-proof.json")
        if positive, let health, let controller, let link = controller.link {
            let receipt = try health.receipt(root: config.runRoot, link: link,
                proofSHA256: digest(try boundedRead(config.runRoot.appendingPathComponent("cancellation-proof.json"), maximum: 16_384)))
            try files.json(receipt, name: "cancellation-owner.json")
        }
        XCTAssertTrue(positive, "UNAVAILABLE: preserve owned artifacts; no retry, reader or successor.")
        // Only an external supervisor can subsequently attest OS exit, both EOFs and group settlement.
    }

    @MainActor func testOwnedGuardedCancellationFreshReader() async throws {
        guard let gate = ownedControl(OwnedCancellationGate.reader) else {
            throw XCTSkip("Owned cancellation reader is off.")
        }
        try OwnedCancellationGate.validate(gate, owner: false)
        try OwnedCancellationReader.run() // no asset configuration, native query or fresh-state initializer.
    }

    func testOwnedCancellationDecoratorControls() throws {
        try OwnedCancellationGate.deterministic()
        try OwnedCallbackControls.run() // safe Swift protocol spies only; never C/user-data pointers.
    }

    @MainActor func testOwnedNativeTimedImport() async throws {
        // Absolutely first executable gate: no test-owned loader, path stat/read, or native query.
        // Frameworks linked by the XCTest host may already be mapped before test entry.
        guard ownedControl("PARLA_RUN_OWNED_WHISPER_NATIVE") == "1" else {
            throw XCTSkip("Owned Whisper native test is off.")
        }
        let config = try OwnedConfiguration()
        let counts = OwnedCounts()
        let files = try OwnedOutputs(root: config.runRoot, counts: counts)
        let abort = try OwnedAbortPort() // only SIG_IGN in the C handler; Swift runs on Dispatch.
        var prepared: OwnedPrepared?
        var rig: OwnedImportRig?
        var status = "REFUSED"
        var closingVerified = false
        do {
            try files.json(OwnedReceipt(status: "BEFORE", counts: counts.values, modelSHA256: OwnedPins.modelSHA), name: "before.json")
            let input = try await OwnedPrepared.read(config, files: files, abort: abort)
            prepared = input
            try abort.check()
            let connected = try OwnedImportRig(config: config, input: input, files: files,
                                              abort: abort, counts: counts)
            rig = connected
            await connected.run()
            try abort.check()
            try connected.verifyReviewAndExport()
            status = "NATIVE_BOUNDARY_OBSERVED" // syntax/clock smoke only; never quality PASS.
        } catch is CancellationError {
            status = "CANCELED"
        } catch {
            status = rig == nil ? "REFUSED" : "INCOMPLETE"
            // Never serialize raw NSError, paths, environment, query, or credential details.
        }
        // This is an actual queue barrier, not XCTest timeout or Task.cancel as exit proof.
        // If native work never returns, this await remains pending for the external supervisor.
        if let rig { await rig.chain?.value }
        if let input = prepared {
            do { try await input.verifyClosing(config); closingVerified = true }
            catch { status = "INCOMPLETE_IMMUTABILITY" }
        }
        let controlClosed = await abort.close() // drain before checked restoration; false is nonpositive.
        if abort.requested { status = "CANCELED" }
        if let rig {
            if rig.owner.job?.operation.hasExited != true || rig.owner.job?.source.isClosed != true {
                status = "INCOMPLETE_EXIT"
            }
            if !rig.isolationIsIntact { status = "INCOMPLETE_ISOLATION" }
        }
        if !controlClosed { status = "INCOMPLETE_CONTROL_RESTORE" }
        let receipt = OwnedReceipt(status: status, counts: counts.values,
            frames: prepared == nil ? nil : 640_000, clock: rig?.owner.review?.segments == nil ? nil : "whisper191PCM10ms",
            outcome: rig?.diagnosticOutcome, modelSHA256: prepared == nil ? nil : OwnedPins.modelSHA,
            compositeSHA256: prepared?.manifest.compositeSHA256, imageSHA256: prepared?.image.sha256,
            closingVerified: closingVerified, cueCount: rig?.owner.review?.segments?.cues.count,
            timingBeyond30s: rig?.owner.review?.segments?.cues.contains { $0.start > 3000 || $0.end > 3000 })
        try files.json(receipt, name: "after.json")
        XCTAssertEqual(status, "NATIVE_BOUNDARY_OBSERVED", "Owned native attempt ended: \(status); retain receipts, do not retry.")
    }

    @MainActor func testOwnedGuardedFirstRealRequest() async throws {
        // First executable gate precedes every test-owned query/storage/native API.
        // Linked host frameworks can already be mapped before this gate.
        guard ownedControl("PARLA_RUN_OWNED_WHISPER_B53_FIRST_REQUEST") == "1" else {
            throw XCTSkip("Owned guarded first request is off.")
        }
        try require(ownedControl("PARLA_RUN_OWNED_WHISPER_NATIVE") == nil
            && ownedControl("PARLA_RUN_OWNED_WHISPER_CONTROL") == nil, .configuration)
        let config = try OwnedConfiguration()
        let prefix = "whisper-b53-first-request-"
        try require(config.runRoot.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(config.runRoot.lastPathComponent.dropFirst(prefix.count))) != nil, .configuration)
        let counts = OwnedCounts()
        let files = try OwnedOutputs(root: config.runRoot, counts: counts, firstRequest: true)
        let abort = try OwnedAbortPort() // ordinary outer supervision safety, never an abort experiment.
        var prepared: OwnedPrepared?
        var rig: OwnedImportRig?
        var health: OwnedFirstRequestHealth?
        var status = "REFUSED"
        var closingVerified = false
        var healthVerified = false
        var queueBarrierReturned = false
        do {
            try files.json(OwnedReceipt(status: "B53_BEFORE", counts: counts.values), name: "before.json")
            let input = try await OwnedPrepared.read(config, files: files, abort: abort,
                requiredCompositeSHA256: OwnedFirstRequestHealth.compositeSHA256)
            prepared = input
            try abort.check()
            let journal = try OwnedFirstRequestHealth(files: files)
            health = journal
            let connected = try OwnedImportRig(config: config, input: input, files: files,
                abort: abort, counts: counts, firstRequestHealth: journal)
            rig = connected
            await connected.run()
            try abort.check()
            status = "RETURNED"
        } catch is CancellationError { status = "CANCELED" }
        catch { status = rig == nil ? "REFUSED" : "INCOMPLETE" }
        // Actual queue barrier; timeout/cancel is never exit proof or permission to retry.
        if let chain = rig?.chain { await chain.value; queueBarrierReturned = true }
        if let input = prepared {
            do { try await input.verifyClosing(config); closingVerified = true }
            catch { status = "INCOMPLETE_IMMUTABILITY" }
        }
        if abort.requested { status = "CANCELED" }
        if status == "RETURNED", closingVerified, let rig {
            do {
                try require(queueBarrierReturned)
                try rig.verifyFirstRequestHealth()
                healthVerified = true
                try rig.verifyReviewAndExport() // secondary B47 no-regression; never the health oracle.
                status = "GUARDED_FIRST_REAL_ENVELOPE_OBSERVED"
            } catch { status = "INCOMPLETE" }
        }
        let controlClosed = await abort.close() // retain ordinary safety through secondary export checks.
        if abort.requested { status = "CANCELED"; healthVerified = false }
        if !controlClosed { status = "INCOMPLETE_CONTROL_RESTORE"; healthVerified = false }
        if let health { try files.json(health.proof(rig: rig, verified: healthVerified, queueBarrierReturned: queueBarrierReturned), name: "health-proof.json") }
        try files.json(OwnedReceipt(status: status, counts: counts.values,
            frames: prepared == nil ? nil : 640_000, outcome: rig?.diagnosticOutcome,
            modelSHA256: prepared == nil ? nil : OwnedPins.modelSHA,
            compositeSHA256: prepared?.manifest.compositeSHA256, imageSHA256: prepared?.image.sha256,
            closingVerified: closingVerified), name: "after.json")
        XCTAssertEqual(status, "GUARDED_FIRST_REAL_ENVELOPE_OBSERVED",
            "Nonpositive owned first request; preserve evidence, no retry or successor.")
        // Child exit/EOF/settlement is external evidence; this assertion cannot attest it.
    }

    // One exact selector per future supervised child; no model/native-mode fallback.
    @MainActor func testOwnedAbortControl() async throws {
        guard let selection = ownedControl("PARLA_RUN_OWNED_WHISPER_CONTROL"),
              ["default/no-delivery", "default/attached", "default/late-attach",
               "ignore/no-delivery", "ignore/attached", "ignore/late-attach",
               "install-error", "restore-error"].contains(selection) else {
            throw XCTSkip("Owned abort control is off or selector refused.")
        }
        let counts = OwnedCounts()
        func emit(_ marker: String) { FileHandle.standardOutput.write(Data((marker + "\n").utf8)) }
        func verify(_ condition: Bool, _ message: String) {
            if !condition { counts.add("failures"); XCTFail(message) }
        }
        func wait(_ expected: XCTestExpectation) async -> Bool {
            let completed = await XCTWaiter.fulfillment(of: [expected], timeout: 5) == .completed
            verify(completed, "Owned control stage did not complete within five seconds.")
            return completed
        }
        func hasDisposition(_ expected: sig_t?) -> Bool {
            var action = sigaction()
            guard sigaction(SIGUSR1, nil, &action) == 0 else { return false }
            let observed: sig_t? = action.__sigaction_u.__sa_handler
            return OwnedAbortPort.dispositionBits(observed) == OwnedAbortPort.dispositionBits(expected)
        }
        func close(_ port: OwnedAbortPort) async -> Bool? {
            let closed = expectation(description: "control drained and restoration checked")
            Task {
                let restored = await port.close()
                counts.add(restored ? "restored" : "restoreRefused")
                closed.fulfill()
            }
            guard await wait(closed) else { return nil }
            return counts.value("restored") == 1
        }
        var original = sigaction()
        guard sigaction(SIGUSR1, nil, &original) == 0 else {
            XCTFail("Original disposition unavailable; control refused."); return
        }
        let originalHandler: sig_t? = original.__sigaction_u.__sa_handler
        var mayRestoreOriginal = true
        defer {
            // Never race a timed-out source close with restoration to a default action.
            // A failed close stage leaves cleanup to the future owned child's outer deadline.
            if mayRestoreOriginal {
                verify(sigaction(SIGUSR1, &original, nil) == 0, "Original action cleanup failed.")
                verify(hasDisposition(originalHandler), "Original disposition cleanup was not observed.")
            }
            let status = counts.value("failures") == 0 ? "CHECKED" : "NONPOSITIVE"
            emit("OWNED_WHISPER_CONTROL status=\(status) case=\(selection) ready=\(counts.value("ready")) requests=\(counts.value("requests")) aborts=\(counts.value("aborts")) restored=\(counts.value("restored")) installRefused=\(counts.value("installRefused")) restoreRefused=\(counts.value("restoreRefused")) failures=\(counts.value("failures"))")
        }
        if selection == "install-error" {
            do {
                let unexpected = try OwnedAbortPort(signalCall: { number, action in
                    counts.add("signalCalls")
                    if number != SIGUSR1 || OwnedAbortPort.dispositionBits(action) != OwnedAbortPort.dispositionBits(SIG_IGN) {
                        counts.add("wrongCall")
                    }
                    return SIG_ERR // deterministic call-boundary refusal; no kernel error induced.
                }, onReady: { counts.add("ready") }, onRequest: { counts.add("requests") })
                verify(false, "Installation refusal was not surfaced.")
                mayRestoreOriginal = false
                if await close(unexpected) != nil { mayRestoreOriginal = true }
            } catch OwnedAbortPort.Failure.install {
                counts.add("installRefused")
            } catch { verify(false, "Unexpected fixed control failure category.") }
            verify(counts.value("installRefused") == 1, "Expected explicit installation refusal.")
            verify(counts.value("signalCalls") == 1, "Failed installation reused an old disposition.")
            verify(counts.value("wrongCall") == 0, "Unexpected private signal call.")
            verify(counts.value("ready") == 0 && counts.value("requests") == 0, "Refused installation became ready or requested.")
            verify(hasDisposition(originalHandler), "Refused installation changed the disposition.")
            return
        }
        let restoreError = selection == "restore-error"
        let initial: sig_t? = selection.hasPrefix("ignore/") ? SIG_IGN : SIG_DFL
        let previous: sig_t? = Darwin.signal(SIGUSR1, initial)
        guard !OwnedAbortPort.isSignalError(previous) else {
            verify(false, "Initial disposition installation failed."); return
        }
        verify(OwnedAbortPort.dispositionBits(previous) == OwnedAbortPort.dispositionBits(originalHandler),
               "Setup did not preserve the original nullable disposition.")
        verify(hasDisposition(initial), "Initial disposition was not observed.")
        let delivery = selection.hasSuffix("/attached") || selection.hasSuffix("/late-attach")
        let ready = expectation(description: "Dispatch source registered")
        let requested = delivery ? expectation(description: "Dispatch request latched") : nil
        let aborted = delivery ? expectation(description: "real PendingOperation abort callback") : nil
        requested?.assertForOverFulfill = false; aborted?.assertForOverFulfill = false
        let onReady: @Sendable () -> Void = { counts.add("ready"); ready.fulfill() }
        let onRequest: @Sendable () -> Void = { counts.add("requests"); requested?.fulfill() }
        let port: OwnedAbortPort
        if restoreError {
            port = try OwnedAbortPort(signalCall: { number, action in
                counts.add("signalCalls")
                if number != SIGUSR1 { counts.add("wrongCall") }
                if counts.value("signalCalls") == 1 {
                    if OwnedAbortPort.dispositionBits(action) != OwnedAbortPort.dispositionBits(SIG_IGN) { counts.add("wrongCall") }
                    let old: sig_t? = Darwin.signal(number, action)
                    return old
                }
                if action != nil { counts.add("wrongCall") } // saved SIG_DFL must stay null.
                return SIG_ERR // restoration alone is refused, leaving the actual SIG_IGN intact.
            }, onReady: onReady, onRequest: onRequest)
        } else {
            port = try OwnedAbortPort(onReady: onReady, onRequest: onRequest) // exact real default call port.
        }
        mayRestoreOriginal = false
        let operation = PendingOperation(name: "owned-abort-control")
        let observer = operation.observePreparationRevocation { counts.add("revocations") }
        operation.installAbort { counts.add("aborts"); aborted?.fulfill() }
        let registered = await wait(ready)
        let ignored = hasDisposition(SIG_IGN)
        verify(ignored, "Registered control did not retain SIG_IGN.")
        let late = selection.hasSuffix("/late-attach")
        if registered && ignored && counts.value("failures") == 0 {
            emit("OWNED_WHISPER_CONTROL status=READY case=\(selection) ready=1")
            if !late { port.attach(operation) }
            if delivery {
                // Exactly one fresh own-process signal, only after explicit registration readiness.
                let sent = Darwin.kill(Darwin.getpid(), SIGUSR1) == 0
                verify(sent, "Own-process signal delivery refused.")
                if sent, let requested, await wait(requested) {
                    verify(port.requested, "Request callback preceded the cancellation latch.")
                    if late && counts.value("failures") == 0 {
                        verify(!operation.shouldAbort && counts.value("aborts") == 0, "Unattached operation was already canceled.")
                        port.attach(operation)
                    }
                    if counts.value("failures") == 0, let aborted { _ = await wait(aborted) }
                }
            }
        }
        guard let restored = await close(port) else { return }
        mayRestoreOriginal = true // source is canceled and its serial queue has crossed the close barrier.
        verify(counts.value("ready") == 1, "Registration readiness was not exactly once.")
        verify(restored == !restoreError, "Restoration result did not reflect the signal return.")
        verify(hasDisposition(restoreError ? SIG_IGN : initial), "Actual post-close disposition mismatch.")
        if restoreError {
            verify(counts.value("signalCalls") == 2 && counts.value("wrongCall") == 0, "Unexpected restoration-fault call sequence.")
            verify(counts.value("restoreRefused") == 1 && counts.value("restored") == 0, "Restoration refusal was reported as success.")
        }
        if delivery {
            verify(port.requested && operation.shouldAbort && operation.stage == .discarded, "Real operation was not revoked.")
            verify(counts.value("revocations") == 1 && counts.value("aborts") >= 1, "Real revoke/abort observations missing.")
            verify(!operation.authorizeDispatch() && !operation.claimFinalResult(), "Revoked operation retained delivery authority.")
            do { try port.check(); verify(false, "Canceled control check returned successfully.") }
            catch is CancellationError { counts.add("cancellationObserved") }
            catch { verify(false, "Canceled control check returned an unexpected category.") }
        } else {
            verify(!port.requested && !operation.shouldAbort && operation.stage == .queued, "No-delivery control was canceled.")
            verify(counts.value("requests") == 0 && counts.value("revocations") == 0 && counts.value("aborts") == 0, "Unexpected no-delivery callback.")
            do { try port.check() } catch { verify(false, "No-delivery control check failed.") }
        }
        let callbacks = [counts.value("ready"), counts.value("requests"), counts.value("revocations"), counts.value("aborts")]
        let observedAfterClose = expectation(description: "observation after source cancellation barrier")
        DispatchQueue.global().async { observedAfterClose.fulfill() }
        _ = await wait(observedAfterClose)
        verify(callbacks == [counts.value("ready"), counts.value("requests"), counts.value("revocations"), counts.value("aborts")],
               "Control callbacks changed after close.")
        operation.removePreparationRevocation(observer)
        operation.finish()
        verify(operation.hasExited, "Owned operation did not finish.")
    }
}

private enum OwnedPins {
    static let modelSHA = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
    static let imageSHA = "50e9a18e22098bb673032ccb7205038de2cbd009fb67f969622bb939d0e89497"
    static let originalSHA = "20e10e583b4918e05cea91316f7bde65a345d2756e64abc7f7ee133e2a0547f5"
    static let referenceSHA = "18d4a6b3af0cfdfdf91482dca0b569703d1f2fe1b1b6ec66dc1d462fc8ba6d11"
    static let rootContractSHA = "e534489d4cb414d81c2f0470514b2242694826c532fc87db80a077d0fe860239"
}
private func ownedControl(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }; return String(cString: value)
}
private enum OwnedRefusal: Error { case configuration, path, pin, manifest, bounds, observation, export, isolation }
private func require(_ condition: Bool, _ refusal: OwnedRefusal = .observation) throws {
    if !condition { throw refusal }
}
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func physical(_ path: String) throws -> String {
    guard let p = realpath(path, nil) else { throw OwnedRefusal.path }
    defer { free(p) }; return String(cString: p)
}
private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
    let st = try OwnedStamp(url)
    try require(st.size >= 0 && st.size <= Int64(maximum), .bounds)
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw OwnedRefusal.path }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    let data = try file.read(upToCount: maximum + 1) ?? Data()
    try require(data.count == st.size && data.count <= maximum, .bounds)
    try require(try OwnedStamp(url) == st, .pin)
    return data
}
private struct OwnedStamp: Equatable, Codable {
    let device: Int32, inode: UInt64, size: Int64, mode: UInt16, links: UInt16
    let modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
    init(_ url: URL, directory: Bool = false, immutable: Bool = false) throws {
        try require(try physical(url.path) == url.path, .path)
        var st = stat()
        try require(lstat(url.path, &st) == 0 && st.st_uid == getuid(), .path)
        try require(st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), .path)
        if !directory { try require(st.st_nlink == 1, .path) }
        if immutable { try require(st.st_mode & 0o222 == 0, .path) }
        device = st.st_dev; inode = st.st_ino; size = st.st_size; mode = st.st_mode; links = st.st_nlink
        modified = Int64(st.st_mtimespec.tv_sec); modifiedNS = Int64(st.st_mtimespec.tv_nsec)
        changed = Int64(st.st_ctimespec.tv_sec); changedNS = Int64(st.st_ctimespec.tv_nsec)
    }
}
private struct OwnedConfiguration {
    let assets: URL, runRoot: URL, manifestURL: URL
    var model: URL { assets.appendingPathComponent("ggml-base.en.bin") }
    var original: URL { assets.appendingPathComponent("2277-149896-0000.pcm16.wav") }
    var reference: URL { assets.appendingPathComponent("frozen-reference.json") }
    var composite: URL { assets.appendingPathComponent("timing-composite-40s.wav") }
    init() throws {
        func root(_ key: String) throws -> URL {
            guard let path = ownedControl(key), path.hasPrefix("/"), !path.utf8.contains(0),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  try physical(path) == path else { throw OwnedRefusal.configuration }
            let url = URL(fileURLWithPath: path)
            try require(url.path == path, .path) // reject Foundation /var alias spelling.
            return url
        }
        assets = try root("PARLA_OWNED_WHISPER_ASSET_ROOT")
        runRoot = try root("PARLA_OWNED_WHISPER_RUN_ROOT")
        manifestURL = try root("PARLA_OWNED_WHISPER_MANIFEST")
        _ = try OwnedStamp(assets, directory: true)
        let run = try OwnedStamp(runRoot, directory: true)
        try require(run.mode & 0o777 == 0o700, .path)
        try require(!runRoot.path.hasPrefix(assets.path + "/") && !assets.path.hasPrefix(runRoot.path + "/") && assets != runRoot, .path)
        try require(manifestURL.deletingLastPathComponent() == assets, .path)
        // Root attests exclusive fresh runRoot; only exact planned children are inspected here.
        // No directory-wide inventory, ambient model discovery, or fallback path.
    }
}
// Strict schemaVersion=1. Composite SHA is supplied by root AFTER staging, not guessed here.
private struct OwnedManifest: Decodable {
    let schemaVersion: Int
    let kind: String
    let frames: Int, rate: Int, channels: Int, bits: Int, repetitions: Int, tailZeroFrames: Int
    let compositeBytes: Int, compositeSHA256: String
    let originalWAVSHA256: String, modelSHA256: String, frameworkSHA256: String
    let frozenReferenceSHA256: String, rootContractSHA256: String
    func validate() throws {
        try require(schemaVersion == 1 && kind == "synthetic-timing-composition-not-continuous-human-recording", .manifest)
        try require(frames == 640_000 && rate == 16_000 && channels == 1 && bits == 16 && repetitions == 6 && tailZeroFrames == 7360, .manifest)
        try require(compositeBytes == 1_280_044 && compositeSHA256.count == 64 && compositeSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, .manifest)
        try require(originalWAVSHA256 == OwnedPins.originalSHA && modelSHA256 == OwnedPins.modelSHA && frameworkSHA256 == OwnedPins.imageSHA, .pin)
        try require(frozenReferenceSHA256 == OwnedPins.referenceSHA && rootContractSHA256 == OwnedPins.rootContractSHA, .pin)
    }
}
private struct OwnedLoadedImage {
    let url: URL, sha256: String, stamp: OwnedStamp
    static func inspect() throws -> Self {
        // RTLD_DEFAULT on Darwin. Never dlopen a guessed library or enumerate filesystem images.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "whisper_full") else { throw OwnedRefusal.pin }
        var info = Dl_info()
        try require(dladdr(symbol, &info) != 0, .pin)
        guard let name = info.dli_fname, let base = info.dli_fbase else { throw OwnedRefusal.pin }
        let exact = try physical(String(cString: name))
        var matches = 0
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i), UnsafeRawPointer(header) == UnsafeRawPointer(base),
                  let imageName = _dyld_get_image_name(i) else { continue }
            try require(try physical(String(cString: imageName)) == exact, .pin)
            matches += 1
        }
        try require(matches == 1, .pin)
        let url = URL(fileURLWithPath: exact), stamp = try OwnedStamp(url)
        try require(stamp.size == 5_501_136, .pin)
        let hash = try ModelCatalog.sha256(ofFileAt: url)
        try require(hash == OwnedPins.imageSHA && (try OwnedStamp(url)) == stamp, .pin)
        return Self(url: url, sha256: hash, stamp: stamp)
    }
}
private struct OwnedPrepared {
    let manifest: OwnedManifest, image: OwnedLoadedImage
    let model: ModelCatalog.Model, modelStamp: OwnedStamp, compositeStamp: OwnedStamp
    let originalStamp: OwnedStamp, referenceStamp: OwnedStamp, manifestStamp: OwnedStamp
    let cache: VerifiedCache, cacheURL: URL, cacheData: Data, manifestData: Data
    // Nonisolated async functions leave MainActor; no synchronous native/hash waits on main.
    static func read(_ c: OwnedConfiguration, files: OwnedOutputs, abort: OwnedAbortPort,
                     requiredCompositeSHA256: String? = nil, retainReference: Bool = true) async throws -> Self {
        try require(!Thread.isMainThread, .isolation); try abort.check()
        let manifestStamp = try OwnedStamp(c.manifestURL, immutable: true)
        let manifestData = try boundedRead(c.manifestURL, maximum: 16_384)
        let manifest = try JSONDecoder().decode(OwnedManifest.self, from: manifestData)
        try manifest.validate()
        if let requiredCompositeSHA256 { try require(manifest.compositeSHA256 == requiredCompositeSHA256, .pin) }
        let referenceStamp = try OwnedStamp(c.reference, immutable: true)
        let reference = try boundedRead(c.reference, maximum: 16_384)
        try require(digest(reference) == OwnedPins.referenceSHA, .pin)
        if retainReference { try files.write(reference, name: "frozen-reference.json", maximum: 16_384) }
        let originalStamp = try OwnedStamp(c.original, immutable: true)
        let compositeStamp = try OwnedStamp(c.composite, immutable: true)
        let original = try boundedRead(c.original, maximum: 210_924)
        let composite = try boundedRead(c.composite, maximum: 1_280_044)
        try require(original.count == 210_924 && digest(original) == OwnedPins.originalSHA, .pin)
        try require(composite.count == manifest.compositeBytes && digest(composite) == manifest.compositeSHA256, .pin)
        // Canonical 44-byte WAV header is a fixture contract, not a general WAV parser.
        // Actual ImportedWAV independently validates the complete source before any model load.
        try require(try ImportedWAV.decode(original).count == 105_440, .bounds)
        try require(try ImportedWAV.decode(composite).count == 640_000, .bounds)
        let pcm = original[44...]
        for repeatIndex in 0..<6 {
            let start = 44 + repeatIndex * 210_880
            try require(composite[start..<(start + 210_880)].elementsEqual(pcm), .pin)
        }
        try require(composite[(44 + 632_640 * 2)...].allSatisfy { $0 == 0 }, .pin)
        try abort.check()
        guard let model = ModelCatalog.all.first(where: { $0.id == "base.en" }) else { throw OwnedRefusal.pin }
        try require(model.bytes == 147_964_211 && model.sha256 == OwnedPins.modelSHA && model.filename == c.model.lastPathComponent, .pin)
        let modelStamp = try OwnedStamp(c.model, immutable: true)
        try ModelCatalog.verify(fileAt: c.model, is: model) // REAL production streaming SHA verification.
        try require(try OwnedStamp(c.model) == modelStamp, .pin)
        let cacheURL = files.state.appendingPathComponent("verified.json")
        let cache = VerifiedCache(url: cacheURL)
        files.counts.add("cacheRecordAttempts")
        cache.record(c.model) // exact owned cache, after hash; read-only admission never records.
        let cacheData = try boundedRead(cacheURL, maximum: 4096)
        try require(cache.isVerified(c.model), .pin)
        try abort.check()
        let image = try OwnedLoadedImage.inspect()
        return Self(manifest: manifest, image: image, model: model, modelStamp: modelStamp,
            compositeStamp: compositeStamp, originalStamp: originalStamp, referenceStamp: referenceStamp,
            manifestStamp: manifestStamp, cache: cache, cacheURL: cacheURL, cacheData: cacheData, manifestData: manifestData)
    }
    func verifyClosing(_ c: OwnedConfiguration) async throws {
        try require(!Thread.isMainThread, .isolation)
        try ModelCatalog.verify(fileAt: c.model, is: model)
        try require(try OwnedStamp(c.model) == modelStamp, .pin)
        try require(try OwnedStamp(c.composite) == compositeStamp, .pin)
        try require(digest(try boundedRead(c.composite, maximum: 1_280_044)) == manifest.compositeSHA256, .pin)
        try require(try OwnedStamp(c.original) == originalStamp && OwnedStamp(c.reference) == referenceStamp && OwnedStamp(c.manifestURL) == manifestStamp, .pin)
        try require(digest(try boundedRead(c.original, maximum: 210_924)) == OwnedPins.originalSHA, .pin)
        try require(digest(try boundedRead(c.reference, maximum: 16_384)) == OwnedPins.referenceSHA, .pin)
        try require(try boundedRead(cacheURL, maximum: 4096) == cacheData, .pin)
        try require(try boundedRead(c.manifestURL, maximum: 16_384) == manifestData, .pin)
        let closingImage = try OwnedLoadedImage.inspect()
        try require(closingImage.url == image.url && closingImage.stamp == image.stamp && closingImage.sha256 == image.sha256, .pin)
    }
}

// Successful delegate publications only. Storage performs its actual lock/sync/rename protocol.
// No fault callback, replacement result, native wrapper, or manually invoked permit hook.
private struct OwnedHealthPublication: Encodable {
    let method: String
    let ledger: PreparationLedger
    let bytes: Data
    enum CodingKeys: String, CodingKey { case method, ledger } // never duplicate raw bytes in proof.
}
private final class OwnedObservedPreparationStorage: PreparationStorage, @unchecked Sendable {
    private let delegate: PrivatePreparationStorage
    private let lock = NSLock()
    private var publications: [OwnedHealthPublication] = []
    private var observationRefused = false
    private var quarantines = 0
    init(root: URL) throws { delegate = try PrivatePreparationStorage(root: root) }
    static func decode(_ data: Data) throws -> PreparationLedger {
        try require(!data.isEmpty && data.count <= 16_384, .bounds)
        let ledger = try JSONDecoder().decode(PreparationLedger.self, from: data)
        try ledger.validate() // actual journal type/key validation, not a parallel permissive schema.
        return ledger
    }
    private func record(_ method: String, _ data: Data) {
        let ledger = try? Self.decode(data)
        lock.lock(); defer { lock.unlock() }
        guard publications.count < 5, let ledger else { observationRefused = true; return }
        publications.append(.init(method: method, ledger: ledger, bytes: data))
    }
    func read() throws -> Data? { try delegate.read() }
    func replace(_ data: Data, authorized: () -> Bool) throws {
        try delegate.replace(data, authorized: authorized)
        record("replace", data) // only AFTER file sync, authorized rename and directory sync return.
    }
    func reset(_ data: Data) throws {
        try delegate.reset(data)
        record("reset", data) // distinct from the four envelope replace publications.
    }
    func quarantine() throws {
        try delegate.quarantine()
        lock.lock(); quarantines += 1; lock.unlock()
    }
    var observation: (publications: [OwnedHealthPublication], refused: Bool, quarantines: Int) {
        lock.lock(); defer { lock.unlock() }
        return (publications, observationRefused, quarantines)
    }
}
private struct OwnedFirstRequestHealthProof: Encodable {
    let scope = "loaded test-host shared constructor/first-real envelope; verification-admission adapter; no C/GPU/acoustic or process-settlement attestation"
    let verified: Bool
    let publications: [OwnedHealthPublication]
    let observationRefused: Bool
    let successfulQuarantines: Int
    let finalLedger: PreparationLedger?
    let coreStatus: String
    let active: Bool, persistenceDebt: Bool
    let build: PreparationBuild?
    let nativeOutcome: String?
    let deliveryCanceled: Bool?
    let operationFinished: Bool?, operationExited: Bool?, sourceClosed: Bool?, jobCurrent: Bool?
    let queueBarrierReturned: Bool
    let sourceFrames: Int?, outputFrames: Int?
    let isolationIntact: Bool?
    let counts: [String: Int]
}
private final class OwnedFirstRequestHealth: @unchecked Sendable {
    static let compositeSHA256 = "4c61638c57f68a33dfb44e93cca796acb541b47158872d1d5d6b3566cd0ab8fe"
    let consent = UUID() // explicit NEW task consent; never a build UUID or prior grant.
    let core: RecognitionPreparation
    private let journal: OwnedObservedPreparationStorage
    private var observedBuild: PreparationBuild?
    private var observedSelection: UUID?
    private var observedEpoch: UUID?
    init(files: OwnedOutputs) throws {
        let parent = try OwnedStamp(files.state, directory: true)
        try require(parent.mode & 0o7777 == 0o700, .path)
        let root = files.state.appendingPathComponent("preparation-health", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: root.path), .path)
        let journal = try OwnedObservedPreparationStorage(root: root)
        self.journal = journal
        core = RecognitionPreparation(storage: { journal }, build: PreparationBuildReader.loaded)
    }
    func preflight(saved: Settings, selection: UUID) throws {
        try require(observedBuild == nil && saved.nativePreparationSafeStartEnabled
            && saved.nativePreparationConsent == consent && core.matchesSavedPermission(saved), .configuration)
        try require(core.snapshot.status == .ready && core.snapshot.refusal == nil
            && !core.hasActiveEntry && !core.persistenceFailed && core.admissionEpoch != nil)
        // Real loaded image metadata; unsupported hosts refuse BEFORE acquisition/native construction.
        observedBuild = try PreparationBuildReader.loaded()
        observedSelection = selection; observedEpoch = core.admissionEpoch
        let observation = journal.observation
        try require(!observation.refused && observation.quarantines == 0
            && observation.publications.count == 1 && observation.publications[0].method == "reset")
        let clean = observation.publications[0].ledger
        try require(clean.schema == 2 && clean.consent == consent && clean.entries.isEmpty && !clean.poisoned)
        guard let bytes = try journal.read() else { throw OwnedRefusal.observation }
        _ = try OwnedObservedPreparationStorage.decode(bytes)
        try require(bytes == observation.publications[0].bytes)
    }
    func verify(identity: RecognitionIdentity, job: AudioImportOwner.Job, selection: UUID) throws {
        guard let build = observedBuild, let epoch = observedEpoch else { throw OwnedRefusal.observation }
        try require(try PreparationBuildReader.loaded() == build, .pin)
        try require(observedSelection == selection && job.selectionEpoch == selection
            && job.preparationEpoch == epoch && core.admissionEpoch == epoch
            && job.configuration.safeStart && job.configuration.consent == consent, .configuration)
        try require(core.snapshot.status == .ready && core.snapshot.refusal == nil
            && !core.hasActiveEntry && !core.persistenceFailed)
        let observed = journal.observation
        try require(!observed.refused && observed.quarantines == 0
            && observed.publications.map(\.method) == ["reset", "replace", "replace", "replace", "replace"])
        let ledgers = observed.publications.map(\.ledger)
        guard let clean = ledgers.first else { throw OwnedRefusal.observation }
        try require(ledgers.allSatisfy { $0.schema == 2 && $0.consent == consent
            && $0.generation == clean.generation && !$0.poisoned
            && $0.entries.allSatisfy { $0.unresolved == 0 } })
        let construction = try PreparationKey(identity: identity, build: build, phase: .nativeConstruction)
        let first = try PreparationKey(identity: identity, build: build, phase: .firstRealAudioRequest)
        try require(ledgers.map { $0.entries.map(\.key) } == [[], [construction], [construction],
            [construction, first], [construction, first]])
        guard let constructionPending = ledgers[1].entries[0].pending,
              let firstPending = ledgers[3].entries[1].pending else { throw OwnedRefusal.observation }
        try require(constructionPending.attempt != firstPending.attempt)
        for pending in [constructionPending, firstPending] {
            try require(pending.launch == core.launch && pending.operation == job.operation.id
                && pending.selection == selection)
        }
        for entry in [ledgers[1].entries[0], ledgers[3].entries[1]] {
            try require(entry.pending != nil && entry.consumed == nil && entry.outcome == nil)
        }
        func terminal(_ entry: PreparationEntry, attempt: UUID) throws {
            try require(entry.pending == nil && entry.consumed == attempt
                && entry.outcome == .completed && entry.unresolved == 0)
        }
        try terminal(ledgers[2].entries[0], attempt: constructionPending.attempt)
        try terminal(ledgers[3].entries[0], attempt: constructionPending.attempt)
        try terminal(ledgers[4].entries[0], attempt: constructionPending.attempt)
        try terminal(ledgers[4].entries[1], attempt: firstPending.attempt)
        guard let finalBytes = try journal.read() else { throw OwnedRefusal.observation }
        let final = try OwnedObservedPreparationStorage.decode(finalBytes)
        try require(finalBytes == observed.publications[4].bytes && final.entries.count == 2
            && final.entries.allSatisfy { $0.pending == nil && $0.unresolved == 0 } && !final.poisoned)
        // Per-resident synthetic warmth is neither performed nor claimed by core.snapshot.ready.
    }
    @MainActor func proof(rig: OwnedImportRig?, verified: Bool, queueBarrierReturned: Bool) throws -> OwnedFirstRequestHealthProof {
        let observed = journal.observation
        let record = rig?.diagnostics.snapshot().records.first
        let job = rig?.owner.job
        let info = rig?.owner.review?.sourceInfo
        let finalBytes = try? journal.read()
        let final = finalBytes.flatMap { try? OwnedObservedPreparationStorage.decode($0) }
        if verified {
            try require(final != nil && finalBytes == observed.publications.last?.bytes
                && core.snapshot.status == .ready && !core.hasActiveEntry && !core.persistenceFailed)
        }
        return .init(verified: verified, publications: observed.publications, observationRefused: observed.refused,
            successfulQuarantines: observed.quarantines, finalLedger: final,
            coreStatus: core.snapshot.status.rawValue, active: core.hasActiveEntry, persistenceDebt: core.persistenceFailed,
            build: observedBuild, nativeOutcome: record?.recognition?.nativeOutcome?.rawValue,
            deliveryCanceled: record?.recognition?.deliveryCanceled, operationFinished: record?.operationFinished,
            operationExited: job?.operation.hasExited, sourceClosed: job?.source.isClosed, jobCurrent: job?.current,
            queueBarrierReturned: queueBarrierReturned, sourceFrames: info?.sourceFrames, outputFrames: info?.outputFrames,
            isolationIntact: rig?.isolationIsIntact, counts: rig?.counts.values ?? [:])
    }
}

private final class OwnedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = ["insertionCalls": 0, "corpusCalls": 0, "credentialCalls": 0, "historyWrites": 0, "providerCalls": 0, "clipboardCalls": 0]
    func add(_ key: String) { lock.lock(); defer { lock.unlock() }; storage[key, default: 0] += 1 }
    var values: [String: Int] { lock.lock(); defer { lock.unlock() }; return storage }
    func value(_ key: String) -> Int { values[key, default: 0] }
    func refuse(_ key: String) throws { add(key); throw OwnedRefusal.isolation }
}
private final class OwnedOutputs: @unchecked Sendable {
    let root: URL, state: URL, exports: URL, recordings: URL, counts: OwnedCounts
    private let lock = NSLock()
    private var written = Set<String>()
    private var bytes = 0
    private let firstRequest: Bool
    private let cancellation: Bool
    init(root: URL, counts: OwnedCounts, firstRequest: Bool = false, cancellation: Bool = false) throws {
        self.cancellation = cancellation
        self.firstRequest = firstRequest
        self.root = root; self.counts = counts
        state = root.appendingPathComponent("state"); exports = root.appendingPathComponent("exports")
        recordings = root.appendingPathComponent("recordings")
        for directory in [state, exports, recordings] {
            try require(!FileManager.default.fileExists(atPath: directory.path), .path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            counts.add("plannedDirectories")
        }
    }
    func write(_ data: Data, name: String, maximum: Int) throws {
        let allowed = ["before.json", "after.json", "frozen-reference.json", "raw.txt", "cues.json"]
        try require(cancellation ? ["cancellation-proof.json", "cancellation-owner.json"].contains(name)
            : (allowed.contains(name) || (firstRequest && name == "health-proof.json")), .isolation)
        lock.lock(); defer { lock.unlock() }
        try require(!written.contains(name) && data.count <= maximum && bytes + data.count <= (cancellation ? 32_768 : 7 * 1_048_576), .bounds)
        let url = root.appendingPathComponent(name)
        try require(!FileManager.default.fileExists(atPath: url.path), .path)
        try data.write(to: url, options: .atomic)
        written.insert(name); bytes += data.count; counts.add("artifactWrites")
    }
    func json<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(value), name: name, maximum: name == "cues.json" ? 6 * 1_048_576 : 16_384)
    }
}
// Only allowed fake: rejecting credential bottom, never SecurityCredentialBackend/shared store.
private final class OwnedRejectingCredentials: CredentialBackend {
    let counts: OwnedCounts
    init(_ counts: OwnedCounts) { self.counts = counts }
    func status(_ scope: CredentialScope) -> CredentialStatus { counts.add("credentialCalls"); return .denied }
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead { counts.add("credentialCalls"); return .denied }
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { counts.add("credentialCalls"); return .denied }
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { counts.add("credentialCalls"); return .denied }
    func delete(_ scope: CredentialScope) -> CredentialMutation { counts.add("credentialCalls"); return .denied }
}

@MainActor private final class OwnedImportRig {
    let owner: AudioImportOwner, diagnostics: DiagnosticStore, history: HistoryStore, hub: HubModel
    let admission = LocalCleanupAdmission()
    let counts: OwnedCounts, input: OwnedPrepared, config: OwnedConfiguration, files: OwnedOutputs, abort: OwnedAbortPort
    var chain: Task<Void, Never>?
    private let evidence = OwnedEvidence()
    private var selected = false
    private let firstRequestHealth: (any OwnedGuardedHealth)?
    init(config c: OwnedConfiguration, input: OwnedPrepared, files: OwnedOutputs, abort: OwnedAbortPort, counts: OwnedCounts,
         firstRequestHealth: OwnedFirstRequestHealth? = nil,
         cancellationHealth: OwnedCancellationHealth? = nil,
         nativeDecorator: ((any WhisperNativeContext) -> any WhisperNativeContext)? = nil) throws {
        let selectedHealth: (any OwnedGuardedHealth)?
        if let firstRequestHealth { selectedHealth = firstRequestHealth }
        else { selectedHealth = cancellationHealth }
        let firstRequestHealth = selectedHealth
        self.firstRequestHealth = firstRequestHealth
        self.config = c; self.input = input; self.files = files; self.abort = abort; self.counts = counts
        diagnostics = DiagnosticStore(countLimit: 2, byteLimit: 16_384, appVersion: { nil })
        owner = AudioImportOwner()
        var settings = Settings()
        settings.recognitionEngine = .whisper; settings.whisperModelPath = c.model.path
        settings.language = "en"; settings.dictionary = []; settings.cleanupEnabled = false
        settings.historyEnabled = false; settings.recoveryAudioEnabled = false
        settings.nativePreparationSafeStartEnabled = false; settings.nativePreparationConsent = nil
        if let firstRequestHealth {
            // Real reset precedes the sole planned owned settings persistence below.
            try firstRequestHealth.core.prepareConsent(firstRequestHealth.consent)
            settings.nativePreparationSafeStartEnabled = true
            settings.nativePreparationConsent = firstRequestHealth.consent
        }
        settings.streamPreviewEnabled = false; settings.warmMic = false
        let settingsBytes = try JSONEncoder().encode(settings)
        let settingsURL = files.state.appendingPathComponent("settings.json")
        try require(settingsBytes.count <= 131_072 && !FileManager.default.fileExists(atPath: settingsURL.path), .bounds)
        try settingsBytes.write(to: settingsURL, options: .atomic); counts.add("plannedSettingsWrites")
        let store = SettingsStore(url: settingsURL, credentials: CredentialStore(backend: OwnedRejectingCredentials(counts)),
            scratchpadIO: .init(read: { _ in try counts.refuse("scratchpadReads"); return nil },
                               write: { _, _ in try counts.refuse("scratchpadWrites") }),
            atomicWrite: { _, _ in try counts.refuse("settingsWritesRefused") })
        history = HistoryStore(url: files.state.appendingPathComponent("history.json"), persistence: .init(
            read: { url in
                counts.add("historyReads")
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
                return try boundedRead(url, maximum: 4096)
            },
            writeAtomically: { _, _ in try counts.refuse("historyWrites") }))
        let recordings = RecordingStore(directory: files.recordings, keepAll: false, requireValidatedPolicy: true,
            access: { _ in counts.add("recordingAccess") },
            writer: { _, _ in try counts.refuse("recordingWrites") },
            remover: { _ in try counts.refuse("recordingRemoves") })
        // This unrelated display helper must not query TIS or observe system input sources.
        let labels = ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter(lookup: { _ in nil }) })
        hub = HubModel(store: store, history: history, clipboard: { _ in counts.add("clipboardCalls") },
            recordings: recordings, shortcutLabels: labels, diagnostics: diagnostics, audioImport: owner)
        if let firstRequestHealth {
            let saved = try store.savedRetrySnapshot()
            try require(saved == settings && saved.nativePreparationSafeStartEnabled
                && saved.nativePreparationConsent == firstRequestHealth.consent, .configuration)
            firstRequestHealth.core.configure(enabled: saved.nativePreparationSafeStartEnabled,
                consent: saved.nativePreparationConsent, selection: hub.modelSelectionEpoch)
            hub.audioImportPreparationEpoch = { firstRequestHealth.core.admissionEpoch }
            try firstRequestHealth.preflight(saved: saved, selection: hub.modelSelectionEpoch)
        }
        // No full refresh, setup, model selection, bindCatalogDownloads, permission or mic query.
        owner.security = { false } // inert secure-input evidence port, no OS probe.
        owner.sourceAccess.start = { _ in counts.add("scopeStarts"); return false }
        owner.sourceAccess.stop = { _ in counts.add("scopeStops") }
        hub.onDownloadModel = { _ in counts.add("downloadCalls") }
        hub.onSaved = { counts.add("settingsCallbacks") }
        hub.retryEnvironment = { [:] }
        hub.retryFactory = { _, _, _, _ in try counts.refuse("providerCalls"); throw OwnedRefusal.isolation }
        hub.segmentedRetryFactory = { _, _, _, _, _ in try counts.refuse("providerCalls"); throw OwnedRefusal.isolation }
        let atomic = hub.historyExportWriter // retain ACTUAL production atomic writer.
        hub.historyExportWriter = { data, url in
            try abort.check()
            try require([files.exports.appendingPathComponent("native.vtt"), files.exports.appendingPathComponent("native.srt")].contains(url), .path)
            try require(data.count <= 8 * 1_048_576 && !FileManager.default.fileExists(atPath: url.path), .bounds)
            counts.add("exportWrites"); try atomic(data, url)
        }
        // These exact two production wrappers keep their private guard, serializer, and writer.
        hub.audioImportExportPanel = { name in
            counts.add("destinationCalls")
            if name == "Parla-transcript.vtt" { return files.exports.appendingPathComponent("native.vtt") }
            if name == "Parla-transcript.srt" { return files.exports.appendingPathComponent("native.srt") }
            return nil
        }
        let factory: RecognitionFactory
        if let firstRequestHealth {
            factory = RecognitionFactory(native: { _, _ in
                try counts.refuse("unguardedNativeConstructors")
                throw OwnedRefusal.isolation
            }, guardedNative: { path, compute, permit in
                counts.add("guardedNativeConstructors"); counts.add("nativeConstructors")
                try require(counts.value("guardedNativeConstructors") == 1 && !Thread.isMainThread, .isolation)
                let native = try WhisperCContext(path, compute, preparation: permit)
                return nativeDecorator?(native) ?? native
            }, preparation: firstRequestHealth.core, preparationPermission: {
                guard let saved = try? store.savedRetrySnapshot() else { return false }
                return saved.nativePreparationSafeStartEnabled && saved.nativePreparationConsent == firstRequestHealth.consent
                    && firstRequestHealth.core.matchesSavedPermission(saved)
            }, directory: c.assets, catalog: ModelCatalog.all, admit: { path, policy in
                // Test-owned verification adapter, not ambient standard installed-model qualification.
                guard case .standard = policy else { throw OwnedRefusal.configuration }
                try require(path == c.model.path, .path)
                counts.add("ownedStandardAdmissions")
                try RecognitionFactory.admitInstalled(path, .readOnlyCatalog,
                    directory: c.assets, catalog: ModelCatalog.all, cache: input.cache)
            }) // actual default runtime/metadata and real core loaded-build reader.
        } else {
            factory = RecognitionFactory(native: { path, compute in
                counts.add("nativeConstructors")
                try require(!Thread.isMainThread, .isolation)
                return try WhisperCContext(path, compute) // actual constructor; no dummy/wrapper context.
            }, directory: c.assets, catalog: ModelCatalog.all, admit: { path, policy in
                guard case .readOnlyCatalog = policy else { throw OwnedRefusal.configuration }
                try RecognitionFactory.admitInstalled(path, policy, directory: c.assets, catalog: ModelCatalog.all, cache: input.cache)
            }) // actual runtime/metadata/getters, nil preparation, never retain a resident.
        }
        let evidence = evidence
        let expected = RecognitionRequest(settings: settings)
        owner.sourceAccess.read = { fd, buffer, count in
            counts.add("sourceReadCalls")
            let n = Darwin.read(fd, buffer, count)
            if n > 0 { evidence.read(Data(bytes: buffer, count: n)) }
            return n
        }
        hub.onAudioImport = { [weak self] job, done in
            guard let self else { job.revoke(); done(.failure(CancellationError())); return }
            abort.attach(job.operation)
            self.chain = AudioImportExecution.enqueue(previous: nil, admission: self.admission, job: job, store: store,
                load: { request in
                    try await OwnedAcquisition.acquire(request: request, expected: expected, config: c,
                        input: input, factory: factory, job: job, abort: abort, counts: counts, evidence: evidence,
                        firstRequestHealth: firstRequestHealth)
                }, done: done)
        }
        hub.refreshAudioImportConfiguration()
    }
    func run() async {
        guard !selected else { return }; selected = true
        hub.selectAudioImport(config.composite)
        hub.startTimedAudioImport()
        await chain?.value
    }
    var diagnosticOutcome: String? { diagnostics.snapshot().records.first?.recognition?.nativeOutcome?.rawValue }
    var isolationIsIntact: Bool {
        let forbidden = ["credentialCalls", "historyWrites", "scratchpadReads", "scratchpadWrites", "settingsWritesRefused",
                         "providerCalls", "clipboardCalls", "downloadCalls", "settingsCallbacks", "recordingAccess", "recordingWrites", "recordingRemoves", "insertionCalls", "corpusCalls"]
        return forbidden.allSatisfy { counts.value($0) == 0 } && history.entries.isEmpty
    }
    func verifyFirstRequestHealth() throws {
        try abort.check()
        guard let health = firstRequestHealth, let job = owner.job, let identity = evidence.identity,
              let review = owner.review, let record = diagnostics.snapshot().records.first,
              let recognition = record.recognition else { throw OwnedRefusal.observation }
        try health.verify(identity: identity, job: job, selection: hub.modelSelectionEpoch)
        // Native return and delivery are independently observed production diagnostics.
        try require(recognition.nativeOutcome == .completed)
        try require(!recognition.deliveryCanceled)
        try require(record.operationFinished && job.operation.hasExited && job.source.isClosed)
        try require(job.current && !job.operation.shouldAbort && !owner.busy && chain != nil)
        try require(record.timings.first { $0.stage == .asr }?.calls == 1
            && record.timings.first { $0.stage == .acquisition }?.calls == 1)
        try require(review.sourceInfo.origin == .strictPCM16k && review.sourceInfo.sourceFrames == 640_000
            && review.sourceInfo.outputFrames == 640_000 && review.sourceInfo.clippedSamples == 0)
        try require(evidence.matches(OwnedFirstRequestHealth.compositeSHA256), .pin)
        try require(counts.value("factoryAcquisitions") == 1 && counts.value("guardedNativeConstructors") == 1
            && counts.value("nativeConstructors") == 1 && counts.value("unguardedNativeConstructors") == 0
            && counts.value("ownedStandardAdmissions") == 1 && counts.value("plannedSettingsWrites") == 1)
        try require(isolationIsIntact, .isolation)
    }
    func verifyReviewAndExport() throws {
        try abort.check()
        guard let job = owner.job, let review = owner.review, let segments = review.segments,
              let record = diagnostics.snapshot().records.first else { throw OwnedRefusal.observation }
        try require(job.operation.hasExited && job.source.isClosed && job.current && !job.operation.shouldAbort)
        try require(job.mode == .experimentalTimed && job.configuration.request == hub.audioImport.job?.configuration.request)
        try require(evidence.identity?.selection == job.configuration.request.selection && evidence.identity?.runtime != nil)
        try require(record.operationFinished && record.recognition?.nativeOutcome == .completed && record.recognition?.deliveryCanceled == false)
        try require(record.timings.first { $0.stage == .asr }?.calls == 1 && record.timings.first { $0.stage == .acquisition }?.calls == 1)
        try require(!record.providerRequestAttempted && record.delivery == .notAttempted && record.clipboard == nil)
        try require(counts.value("factoryAcquisitions") == 1 && counts.value("nativeConstructors") == 1)
        try require(review.sourceInfo.origin == .strictPCM16k && review.sourceInfo.sourceFrames == 640_000 && review.sourceInfo.outputFrames == 640_000 && review.sourceInfo.clippedSamples == 0)
        try require(segments.clock == .whisper191PCM10ms && segments.sourceSampleCount == 640_000 && !segments.cues.isEmpty)
        try require(!review.entry.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && review.entry.raw.utf8.count <= 1_048_576)
        var previous: Int64 = 0
        for cue in segments.cues {
            let start = cue.start.multipliedReportingOverflow(by: 160), end = cue.end.multipliedReportingOverflow(by: 160)
            try require(!start.overflow && !end.overflow && cue.start >= previous && cue.end > cue.start && start.partialValue >= 0 && end.partialValue <= 640_000)
            previous = cue.start // do not sort, clamp, merge, trim, repair, or infer coverage.
        }
        try require(segments.cues.contains { $0.start > 3000 || $0.end > 3000 })
        try require(isolationIsIntact, .isolation)
        try files.write(Data(review.entry.raw.utf8), name: "raw.txt", maximum: 1_048_576)
        try files.json(segments.cues.enumerated().map { OwnedCue(index: $0.offset, text: $0.element.text, start: $0.element.start, end: $0.element.end) }, name: "cues.json")
        let snapshot = segments // preserve all native cue text, indexes, order, gaps and overlap.
        hub.exportAudioImportVTT()
        hub.exportAudioImportSRT() // unsafe natural SRT is refused as a WHOLE by production.
        // If either wrapper refused, this remains INCOMPLETE; never sanitize to force green.
        let vtt = try boundedRead(files.exports.appendingPathComponent("native.vtt"), maximum: 8 * 1_048_576)
        let srt = try boundedRead(files.exports.appendingPathComponent("native.srt"), maximum: 8 * 1_048_576)
        try OwnedExportOracle.check(vtt, segments: snapshot, srt: false)
        try OwnedExportOracle.check(srt, segments: snapshot, srt: true)
        try require(owner.review?.segments == snapshot && owner.review?.entry.raw == review.entry.raw && owner.review?.entry.id == job.resultID)
        try require(counts.value("exportWrites") == 2 && counts.value("destinationCalls") == 2 && isolationIsIntact, .isolation)
    }
}
// Locked observations contain actual values, never replacement recognition/backend behavior.
private final class OwnedEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    private var bytes = 0
    private var observedIdentity: RecognitionIdentity?
    func read(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes += data.count; hasher.update(data: data) }
    func matches(_ sha: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bytes == 1_280_044 && hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha
    }
    func acquired(_ identity: RecognitionIdentity) { lock.lock(); defer { lock.unlock() }; observedIdentity = identity }
    var identity: RecognitionIdentity? { lock.lock(); defer { lock.unlock() }; return observedIdentity }
}
private enum OwnedAcquisition {
    static func acquire(request: RecognitionRequest, expected: RecognitionRequest, config c: OwnedConfiguration,
                        input: OwnedPrepared, factory: RecognitionFactory, job: AudioImportOwner.Job,
                        abort: OwnedAbortPort, counts: OwnedCounts, evidence: OwnedEvidence,
                        firstRequestHealth: (any OwnedGuardedHealth)? = nil) async throws -> RecognitionHandle {
        try require(!Thread.isMainThread, .isolation); try abort.check()
        counts.add("factoryAcquisitions")
        try require(request == expected && request.dictionary.isEmpty && request.language == "en", .configuration)
        try require(evidence.matches(input.manifest.compositeSHA256), .pin)
        if let health = firstRequestHealth {
            try require(counts.value("factoryAcquisitions") == 1 && job.configuration.safeStart
                && job.configuration.consent == health.consent && job.preparationEpoch != nil
                && job.preparationEpoch == health.core.admissionEpoch, .configuration)
            try require(health.core.cachedRefusal(for: request.selection, operation: job.operation,
                selectionEpoch: job.selectionEpoch, preparationEpoch: job.preparationEpoch) == nil)
        }
        let handle = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory,
            operation: job.operation, policy: firstRequestHealth == nil ? .readOnlyCatalog : .standard,
            selectionEpoch: job.selectionEpoch, preparationEpoch: firstRequestHealth == nil ? nil : job.preparationEpoch)
        if firstRequestHealth != nil { try require(handle.preparationIsCurrent) }
        try require(handle.request == request && handle.identity?.selection == request.selection, .observation)
        guard let identity = handle.identity else { throw OwnedRefusal.observation }
        try require(identity.engine == .whisper && identity.generation == RecognitionFileGeneration.observe(c.model.path), .pin)
        try require(identity.artifact == .admittedCatalog(id: "base.en", expectedSHA256: OwnedPins.modelSHA, expectedBytes: 147_964_211), .pin)
        try require(identity.runtime != nil && identity.runtime?.compute == .nativeDefaults && identity.unknownRevisionScope == nil, .pin)
        evidence.acquired(identity)
        return handle
    }
}
private struct OwnedCue: Encodable { let index: Int, text: String, start: Int64, end: Int64 }
// Independent structural reader: never calls SubtitleExport as its own expected-value oracle.
private enum OwnedExportOracle {
    static func check(_ bytes: Data, segments: RecognitionSegments, srt: Bool) throws {
        guard let text = String(data: bytes, encoding: .utf8), !bytes.starts(with: [0xEF, 0xBB, 0xBF]) else { throw OwnedRefusal.export }
        try require(!text.contains("\r") && text.hasSuffix("\n\n"), .export)
        var blocks = text.components(separatedBy: "\n\n")
        try require(blocks.removeLast().isEmpty, .export)
        if !srt { try require(!blocks.isEmpty && blocks.removeFirst() == "WEBVTT", .export) }
        try require(blocks.count == segments.cues.count, .export)
        for (index, cue) in segments.cues.enumerated() {
            let lines = blocks[index].components(separatedBy: "\n")
            try require(lines.count >= 3 && lines[0] == String(index + 1), .export)
            let times = lines[1].components(separatedBy: " --> ")
            try require(times.count == 2, .export)
            try require(try milliseconds(times[0], srt: srt) == cue.start * 10 && milliseconds(times[1], srt: srt) == cue.end * 10, .export)
            let normalized = cue.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let payload = lines.dropFirst(2).joined(separator: "\n")
            if srt { try require(payload == normalized, .export) }
            else {
                // Decode exactly the serializer's three escapes once, preserving literal entities.
                let restored = payload.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
                try require(!payload.contains("<") && !payload.contains(">") && restored == normalized, .export)
            }
        }
    }
    private static func milliseconds(_ text: String, srt: Bool) throws -> Int64 {
        let p = text.components(separatedBy: CharacterSet(charactersIn: srt ? ":," : ":."))
        try require(p.count == 4 && p[0].count >= 2 && p[1].count == 2 && p[2].count == 2 && p[3].count == 3, .export)
        try require(p.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }, .export)
        guard let h = Int64(p[0]), let m = Int64(p[1]), let s = Int64(p[2]), let ms = Int64(p[3]), h < 100, m < 60, s < 60 else { throw OwnedRefusal.export }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }
}
private struct OwnedReceipt: Encodable {
    let schemaVersion = 1
    let scope = "synthetic public speech timing composition; native boundary smoke; no acoustic quality or B02 claim"
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    let status: String, counts: [String: Int]
    var frames: Int? = nil, clock: String? = nil, outcome: String? = nil
    var modelSHA256: String? = nil, compositeSHA256: String? = nil, imageSHA256: String? = nil
    var closingVerified = false
    var cueCount: Int? = nil, timingBeyond30s: Bool? = nil
}
// SIGUSR1 is reserved for this single owned runner; previous disposition is restored after exit.
// No Swift, file IO, locking or allocation executes from a C signal handler.
private final class OwnedAbortPort: @unchecked Sendable {
    enum Failure: Error { case install }
    private let lock = NSLock()
    private var canceled = false
    private var operation: PendingOperation?
    private let queue = DispatchQueue(label: "parla.owned-whisper.abort")
    private let source: DispatchSourceSignal
    private let oldHandler: sig_t?
    private let signalCall: @Sendable (Int32, sig_t?) -> sig_t?
    private let onRequest: @Sendable () -> Void
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    // UNCOMPILED ABI assumption: nullable @convention(c) sig_t is one pointer-sized word.
    // The pinned SDK defines SIG_DFL as 0, SIG_IGN as 1, SIG_ERR as -1. Never invoke these pointers.
    static func dispositionBits(_ handler: sig_t?) -> UInt {
        if handler == nil { return 0 } // a valid prior SIG_DFL, never an installation error.
        return unsafeBitCast(handler, to: UInt.self)
    }
    static func isSignalError(_ handler: sig_t?) -> Bool {
        let failure: sig_t? = SIG_ERR
        return dispositionBits(handler) == dispositionBits(failure)
    }
    init(signalCall: @escaping @Sendable (Int32, sig_t?) -> sig_t? = { number, action in Darwin.signal(number, action) },
         onReady: @escaping @Sendable () -> Void = {}, onRequest: @escaping @Sendable () -> Void = {}) throws {
        self.signalCall = signalCall; self.onRequest = onRequest
        let previous: sig_t? = signalCall(SIGUSR1, SIG_IGN)
        guard !Self.isSignalError(previous) else { throw Failure.install }
        oldHandler = previous // preserve exact optional return, including nil; never substitute SIG_IGN.
        source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        source.setRegistrationHandler(handler: onReady)
        source.setEventHandler { [weak self] in self?.request() }
        source.resume()
    }
    func check() throws { if requested { throw CancellationError() } }
    func attach(_ op: PendingOperation) {
        lock.lock(); operation = op; let stop = canceled; lock.unlock()
        if stop { op.revoke(); op.requestAbort() }
    }
    private func request() {
        lock.lock(); canceled = true; let op = operation; lock.unlock()
        op?.revoke(); op?.requestAbort()
        onRequest()
    }
    private func detach() { lock.lock(); operation = nil; lock.unlock() }
    // Single close per owned port. Continuation follows cancellation drain and a serial queue barrier.
    func close() async -> Bool {
        let restored = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            source.setCancelHandler { [self] in
                if source.data > 0 { request() }
                let result: sig_t? = signalCall(SIGUSR1, oldHandler)
                let success = !Self.isSignalError(result)
                queue.async { continuation.resume(returning: success) }
            }
            source.cancel()
        }
        detach()
        return restored
    }
}

// MARK: - Selected cancellation candidate (all helpers are private to this one source file)
private enum OwnedCancellationGate {
    static let owner = "PARLA_RUN_OWNED_WHISPER_B53_CANCEL_CALLBACK"
    static let reader = "PARLA_RUN_OWNED_WHISPER_B53_CANCEL_READER"
    static let historical = ["PARLA_RUN_OWNED_WHISPER_NATIVE", "PARLA_RUN_OWNED_WHISPER_CONTROL",
                             "PARLA_RUN_OWNED_WHISPER_B53_FIRST_REQUEST"]
    static func validate(_ value: String, owner isOwner: Bool) throws {
        try require(value == "1" && historical.allSatisfy { ownedControl($0) == nil }
            && ownedControl(isOwner ? reader : owner) == nil, .configuration)
    }
    static func deterministic() throws {
        try require((historical + [owner, reader]).allSatisfy { ownedControl($0) == nil }, .configuration)
    }
    static func ownerRoot(_ root: URL) throws {
        let prefix = "whisper-b53-cancel-"
        try require(root.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil, .configuration)
    }
}

// A shared type contract only; the existing healthy implementation and assertions stay intact.
private protocol OwnedGuardedHealth: AnyObject, Sendable {
    var consent: UUID { get }
    var core: RecognitionPreparation { get }
    func preflight(saved: Settings, selection: UUID) throws
    func verify(identity: RecognitionIdentity, job: AudioImportOwner.Job, selection: UUID) throws
}
extension OwnedFirstRequestHealth: OwnedGuardedHealth {}

private struct OwnedCancellationLink: Codable, Equatable {
    let decode: UUID
    let pending: PreparationPending
    let key: PreparationKey
    let preparationEpoch: UUID
}
private struct OwnedCallbackSnapshot: Codable {
    let invocations: Int, callbacks: Int, late: Int, holds: Int, acknowledgements: Int
    let samples: Int
    let sampleCount: Int, timed: Bool
    let acknowledgementNanoseconds: UInt64?
    let entered: Bool, returned: Bool, unavailable: Bool
    let sampledTrue: Bool, returnedAbortObserved: Bool
    let rawStatus: Int32?
    let token: UUID?
    let link: OwnedCancellationLink?
}
// Lock covers interval classification and terminal invalidation; never a core call/original poll/wait.
// DispatchTime.uptimeNanoseconds and DispatchSemaphore deadlines use monotonic time.
private final class OwnedCallbackInterval: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var active: UUID?
    private var token: UUID?
    private var invocations = 0, callbacks = 0, late = 0, holds = 0, acknowledgements = 0, samples = 0
    private var entered = false, returned = false, unavailable = false, sampledTrue = false
    private var returnedAbortObserved = false
    private var rawStatus: Int32?
    private var sampleCount = 0, timed = false
    private var holdStart: UInt64?
    private var acknowledgementNanoseconds: UInt64?
    private var deadline: DispatchTime?
    private var link: OwnedCancellationLink?
    private var notification: ((UUID) -> Void)?
    // nil-default here means a forwarding-only deterministic observation without a hold.
    init() {}
    func install(_ action: @escaping (UUID) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if invocations != 0 || notification != nil { unavailable = true; return }
        notification = action
    }
    func arm(sampleCount: Int, timed: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        invocations = min(invocations + 1, 9)
        if invocations != 1 || active != nil || returned { unavailable = true }
        self.sampleCount = sampleCount; self.timed = timed
        let value = UUID(); active = value; token = value
        return value
    }
    func isHeld(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == value && entered && holds == 1 && acknowledgements == 0 && !unavailable
            && deadline.map { DispatchTime.now().uptimeNanoseconds < $0.uptimeNanoseconds } == true
    }
    func acknowledge(_ value: OwnedCancellationLink) throws {
        lock.lock(); defer { lock.unlock() }
        guard active == value.decode, holds == 1, acknowledgements == 0, !unavailable,
              let deadline, DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            unavailable = true; throw OwnedRefusal.observation
        }
        guard let holdStart else { unavailable = true; throw OwnedRefusal.observation }
        let elapsed = DispatchTime.now().uptimeNanoseconds - holdStart
        acknowledgementNanoseconds = elapsed
        guard elapsed < 5_000_000_000 else {
            unavailable = true; throw OwnedRefusal.observation
        }
        link = value; acknowledgements = 1
        release.signal()
    }
    func invalidate() {
        lock.lock(); unavailable = true; lock.unlock()
        // Never release the held poll as a successful acknowledgement. Its monotonic bound remains.
    }
    func poll(_ value: UUID, original: () -> Bool) -> Bool {
        var action: ((UUID) -> Void)?
        var holdDeadline: DispatchTime?
        lock.lock()
        if active == value && !returned {
            entered = true; callbacks = min(callbacks + 1, 65)
            if callbacks > 64 { unavailable = true }
            if holds == 0, let notification {
                holds = 1
                let start = DispatchTime.now(); holdStart = start.uptimeNanoseconds
                deadline = start + .seconds(5)
                holdDeadline = deadline; action = notification
            }
        } else { late = min(late + 1, 65); unavailable = true }
        lock.unlock()
        if let holdDeadline {
            action?(value) // schedules weak main-actor control, without holding this lock.
            let wait = release.wait(timeout: holdDeadline)
            lock.lock()
            if wait != .success || acknowledgements != 1 || active != value || unavailable {
                unavailable = true
            }
            lock.unlock()
        }
        let result = original() // Exactly one original sample for every callback, including expired/late.
        lock.lock()
        samples = min(samples + 1, 65)
        if samples > 64 { unavailable = true }
        if active != value || returned { unavailable = true }
        if holdDeadline != nil { sampledTrue = result }
        lock.unlock()
        return result // Never inject true, an abort status or a replacement result.
    }
    func close(_ value: UUID, result: WhisperNativeDecode?) {
        lock.lock(); defer { lock.unlock() }
        if active != value || returned { unavailable = true }
        active = nil; returned = true
        rawStatus = result?.status; returnedAbortObserved = result?.abortObserved == true
        notification = nil // concrete return disposes the observer's weak controller notification.
    }
    func disposeNotification() { lock.lock(); notification = nil; lock.unlock() }
    var snapshot: OwnedCallbackSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(invocations: invocations, callbacks: callbacks, late: late, holds: holds,
            acknowledgements: acknowledgements, samples: samples, sampleCount: sampleCount, timed: timed,
            acknowledgementNanoseconds: acknowledgementNanoseconds, entered: entered, returned: returned,
            unavailable: unavailable, sampledTrue: sampledTrue, returnedAbortObserved: returnedAbortObserved,
            rawStatus: rawStatus, token: token, link: link)
    }
    func requirePositive() throws {
        let s = snapshot
        try require(!s.unavailable && s.invocations == 1 && s.entered && s.returned && s.late == 0
            && (1...64).contains(s.callbacks) && s.samples == s.callbacks && s.holds == 1
            && s.acknowledgements == 1 && s.sampledTrue && s.returnedAbortObserved && s.rawStatus != nil
            && s.sampleCount == 640_000 && s.timed
            && s.acknowledgementNanoseconds.map({ $0 < 5_000_000_000 }) == true
            && s.link?.decode == s.token)
    }
}
// The real-owner factory supplies a real guarded WhisperCContext. This decorator knows no C API.
private final class OwnedCallbackContext: WhisperNativeContext {
    private let delegate: any WhisperNativeContext
    private let observer: OwnedCallbackInterval
    init(_ delegate: any WhisperNativeContext, observer: OwnedCallbackInterval) {
        self.delegate = delegate; self.observer = observer
    }
    var multilingual: Bool { delegate.multilingual }
    func knowsLanguage(_ code: String) -> Bool { delegate.knowsLanguage(code) }
    func spokenLanguage() -> String? { delegate.spokenLanguage() }
    private func predicate(_ original: (() -> Bool)?, token: UUID) -> (() -> Bool)? {
        guard let original else { return nil }
        return { [observer] in observer.poll(token, original: original) }
    }
    func decode(_ samples: [Float], initialPrompt: String?, language: String,
                configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
        let token = observer.arm(sampleCount: samples.count, timed: false)
        let result = delegate.decode(samples, initialPrompt: initialPrompt, language: language,
            configuration: configuration, shouldAbort: predicate(shouldAbort, token: token))
        observer.close(token, result: result)
        return result
    }
    func decodeTimed(_ samples: [Float], initialPrompt: String?, language: String,
                     configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode? {
        let token = observer.arm(sampleCount: samples.count, timed: true)
        let result = delegate.decodeTimed(samples, initialPrompt: initialPrompt, language: language,
            configuration: configuration, shouldAbort: predicate(shouldAbort, token: token))
        observer.close(token, result: result)
        return result
    }
}

private final class OwnedCancellationHealth: OwnedGuardedHealth, @unchecked Sendable {
    let consent = UUID()
    let core: RecognitionPreparation
    private let journal: OwnedObservedPreparationStorage
    private var build: PreparationBuild?
    private var selection: UUID?
    private var epoch: UUID?
    init(files: OwnedOutputs) throws {
        try require(try OwnedStamp(files.state, directory: true).mode & 0o7777 == 0o700, .path)
        let root = files.state.appendingPathComponent("preparation-health", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: root.path), .path)
        let journal = try OwnedObservedPreparationStorage(root: root)
        self.journal = journal
        core = RecognitionPreparation(storage: { journal }, build: PreparationBuildReader.loaded)
    }
    var publications: [OwnedHealthPublication] { journal.observation.publications }
    func preflight(saved: Settings, selection: UUID) throws {
        try require(build == nil && saved.nativePreparationSafeStartEnabled
            && saved.nativePreparationConsent == consent && core.matchesSavedPermission(saved)
            && core.snapshot.status == .ready && core.snapshot.refusal == nil
            && !core.hasActiveEntry && !core.persistenceFailed && core.admissionEpoch != nil)
        build = try PreparationBuildReader.loaded(); self.selection = selection; epoch = core.admissionEpoch
        let p = journal.observation
        try require(!p.refused && p.quarantines == 0 && p.publications.count == 1
            && p.publications[0].method == "reset")
        let clean = p.publications[0].ledger
        try require(clean.schema == 2 && clean.consent == consent && clean.entries.isEmpty && !clean.poisoned)
        try require(try journal.read() == p.publications[0].bytes)
    }
    // Exact real five-publication oracle, independent of the healthy completed-first oracle.
    private func check(identity: RecognitionIdentity, job: AudioImportOwner.Job, selection: UUID,
                       retired: Bool) throws -> PreparationPending {
        guard let build, let epoch else { throw OwnedRefusal.observation }
        try require(self.selection == selection && job.selectionEpoch == selection
            && job.preparationEpoch == epoch && core.admissionEpoch == epoch
            && job.configuration.safeStart && job.configuration.consent == consent, .configuration)
        let observation = journal.observation
        let p = observation.publications
        try require(!observation.refused && observation.quarantines == 0 && p.count == (retired ? 5 : 4))
        try require(p.map(\.method) == (retired
            ? ["reset", "replace", "replace", "replace", "replace"] : ["reset", "replace", "replace", "replace"]))
        let ledgers = p.map(\.ledger)
        let clean = ledgers[0]
        try require(clean.entries.isEmpty && ledgers.allSatisfy { $0.schema == 2 && $0.consent == consent
            && $0.generation == clean.generation && !$0.poisoned && $0.entries.allSatisfy { $0.unresolved == 0 } })
        let construction = try PreparationKey(identity: identity, build: build, phase: .nativeConstruction)
        let first = try PreparationKey(identity: identity, build: build, phase: .firstRealAudioRequest)
        let expected = [[], [construction], [construction], [construction, first]]
            + (retired ? [[construction, first]] : [])
        try require(ledgers.map { $0.entries.map(\.key) } == expected)
        guard let cp = ledgers[1].entries[0].pending, let fp = ledgers[3].entries[1].pending else {
            throw OwnedRefusal.observation
        }
        try require(cp.attempt != fp.attempt && [cp, fp].allSatisfy {
            $0.launch == core.launch && $0.operation == job.operation.id && $0.selection == selection
        })
        for entry in [ledgers[1].entries[0], ledgers[3].entries[1]] {
            try require(entry.consumed == nil && entry.outcome == nil)
        }
        for index in 2..<ledgers.count {
            let entry = ledgers[index].entries[0]
            try require(entry.pending == nil && entry.consumed == cp.attempt && entry.outcome == .completed)
        }
        if retired {
            let entry = ledgers[4].entries[1]
            try require(entry.pending == nil && entry.consumed == fp.attempt && entry.outcome == .canceled)
        }
        try require(try journal.read() == p.last?.bytes)
        return fp
    }
    func pending(identity: RecognitionIdentity, job: AudioImportOwner.Job, selection: UUID,
                 decode: UUID) throws -> OwnedCancellationLink {
        let pending = try check(identity: identity, job: job, selection: selection, retired: false)
        guard let build, let epoch else { throw OwnedRefusal.observation }
        try require(core.hasActiveEntry && !core.persistenceFailed && !job.operation.hasExited)
        return .init(decode: decode, pending: pending,
            key: try PreparationKey(identity: identity, build: build, phase: .firstRealAudioRequest), preparationEpoch: epoch)
    }
    func verifyHeld(link: OwnedCancellationLink, identity: RecognitionIdentity,
                    job: AudioImportOwner.Job, selection: UUID) throws {
        try require(try check(identity: identity, job: job, selection: selection, retired: true) == link.pending)
        try require(core.hasActiveEntry && !core.persistenceFailed && job.operation.shouldAbort
            && !job.operation.hasExited && link.pending.launch == core.launch && link.preparationEpoch == epoch)
        let probe = PendingOperation(name: "owned-cancellation-no-native-admission")
        do {
            _ = try core.authorize(identity: identity, policy: .standard, resident: nil, operation: probe,
                selectionEpoch: selection, preparationEpoch: epoch)
            throw OwnedRefusal.observation
        } catch PreparationRefusal.busy { /* refused before build/native resolution */ }
        do { try core.reset(token: core.snapshot.token); throw OwnedRefusal.observation }
        catch PreparationRefusal.revoked { /* active is still held after canceled retirement */ }
        try require(core.hasActiveEntry && !core.persistenceFailed && publications.count == 5)
        try require(try journal.read() == publications.last?.bytes)
    }
    func verify(identity: RecognitionIdentity, job: AudioImportOwner.Job, selection: UUID) throws {
        _ = try check(identity: identity, job: job, selection: selection, retired: true)
        try require(core.snapshot.status == .ready && core.snapshot.refusal == nil
            && !core.hasActiveEntry && !core.persistenceFailed && job.operation.shouldAbort && job.operation.hasExited)
    }
    func receipt(root: URL, link: OwnedCancellationLink, proofSHA256: String) throws -> OwnedCancellationOwnerReceipt {
        guard let final = publications.last?.bytes, let build else { throw OwnedRefusal.observation }
        let settings = root.appendingPathComponent("state/settings.json")
        let bytes = try boundedRead(settings, maximum: 131_072)
        let saved = try JSONDecoder().decode(Settings.self, from: bytes)
        try require(saved.nativePreparationConsent == consent && saved.nativePreparationSafeStartEnabled)
        let healthURL = root.appendingPathComponent("state/preparation-health/health.json")
        try require(try boundedRead(healthURL, maximum: 16_384) == final)
        return .init(proofSHA256: proofSHA256, identities: try OwnedCancellationIdentity.capture(root),
            settingsSHA256: digest(bytes), healthSHA256: digest(final), ledger: try OwnedObservedPreparationStorage.decode(final),
            build: build, link: link)
    }
}

@MainActor private final class OwnedCancellationController {
    private weak var rig: OwnedImportRig?
    private let health: OwnedCancellationHealth
    private let observer: OwnedCallbackInterval
    private let sentinelCounts = OwnedCounts()
    private var invoked = false
    private(set) var sentinel: Task<Void, Never>?
    private(set) var link: OwnedCancellationLink?
    init(rig: OwnedImportRig, health: OwnedCancellationHealth, observer: OwnedCallbackInterval) {
        self.rig = rig; self.health = health; self.observer = observer
    }
    func intervene(_ token: UUID) {
        guard !invoked else { observer.invalidate(); return }; invoked = true
        do {
            try require(observer.isHeld(token))
            guard let rig, let job = rig.owner.job, let chain = rig.chain,
                  let identity = rig.cancellationIdentity else { throw OwnedRefusal.observation }
            let link = try health.pending(identity: identity, job: job,
                selection: rig.hub.modelSelectionEpoch, decode: token)
            let counts = sentinelCounts, observer = observer
            sentinel = PendingOperationQueue.enqueue(previous: chain,
                operation: PendingOperation(name: "owned-cancellation-no-native-sentinel"), completes: true, work: {
                    if !observer.snapshot.returned { observer.invalidate() }
                    counts.add("sentinelEntered")
                })
            try require(counts.value("sentinelEntered") == 0 && observer.isHeld(token))
            job.revoke() // real operation revocation retires the durable first attempt while C is held.
            try health.verifyHeld(link: link, identity: identity, job: job, selection: rig.hub.modelSelectionEpoch)
            try require(counts.value("sentinelEntered") == 0 && observer.isHeld(token))
            try observer.acknowledge(link) // one matching acknowledgement, only after every observation.
            self.link = link
        } catch { observer.invalidate() } // hold expires; a late control action never upgrades proof.
    }
    func verifyReturned() throws {
        try require(invoked && link != nil && sentinel != nil && sentinelCounts.value("sentinelEntered") == 1
            && observer.snapshot.link == link && observer.snapshot.returned)
    }
}

private extension OwnedImportRig {
    var cancellationIdentity: RecognitionIdentity? { evidence.identity }
    var cancellationSideEffectsAreZero: Bool {
        isolationIsIntact && ["exportWrites", "destinationCalls", "providerCalls", "clipboardCalls", "historyWrites",
            "recordingWrites", "recordingAccess", "insertionCalls", "corpusCalls", "downloadCalls",
            "unguardedNativeConstructors"].allSatisfy { counts.value($0) == 0 }
    }
    func verifyCancellation(health: OwnedCancellationHealth) throws {
        guard let job = owner.job, let identity = evidence.identity,
              let record = diagnostics.snapshot().records.first, let recognition = record.recognition else {
            throw OwnedRefusal.observation
        }
        try health.verify(identity: identity, job: job, selection: hub.modelSelectionEpoch)
        try require(recognition.nativeOutcome == .canceled && recognition.deliveryCanceled
            && record.operationFinished && job.operation.hasExited && job.source.isClosed && !owner.busy
            && job.operation.shouldAbort && !job.current && owner.review == nil && chain != nil)
        try require(record.timings.first { $0.stage == .asr }?.calls == 1
            && record.timings.first { $0.stage == .acquisition }?.calls == 1
            && !record.providerRequestAttempted && record.delivery == .notAttempted && record.clipboard == nil)
        try require(evidence.matches(OwnedFirstRequestHealth.compositeSHA256), .pin)
        try require(counts.value("factoryAcquisitions") == 1 && counts.value("guardedNativeConstructors") == 1
            && counts.value("nativeConstructors") == 1 && counts.value("ownedStandardAdmissions") == 1
            && counts.value("plannedSettingsWrites") == 1 && cancellationSideEffectsAreZero, .isolation)
    }
}
private struct OwnedCancellationProof: Encodable {
    let scope = "controlled real full callback cancellation; no kernel/GPU/acoustic/construction-interruption or OS-settlement claim"
    let positive: Bool
    let callback: OwnedCallbackSnapshot
    let publications: [OwnedHealthPublication]
    let link: OwnedCancellationLink?
    let chainReturned: Bool, sentinelReturned: Bool, operationExited: Bool, sourceClosed: Bool, coreActive: Bool
    let nativeCanceled: Bool, deliveryCanceled: Bool, closingVerified: Bool
    let safetyRequested: Bool, safetyRestored: Bool, zeroSideEffects: Bool
}

private struct OwnedCancellationIdentity: Codable, Equatable {
    enum Name: String, Codable, CaseIterable {
        case root, state, settings, healthDirectory, processLock, health
        var relative: String {
            switch self {
            case .root: return ""
            case .state: return "state"
            case .settings: return "state/settings.json"
            case .healthDirectory: return "state/preparation-health"
            case .processLock: return "state/preparation-health/lock"
            case .health: return "state/preparation-health/health.json"
            }
        }
        var directory: Bool { self == .root || self == .state || self == .healthDirectory }
    }
    let name: Name
    let stamp: OwnedStamp
    static func capture(_ root: URL) throws -> [Self] {
        try Name.allCases.map { name in
            let url = name == .root ? root : root.appendingPathComponent(name.relative)
            let stamp = try OwnedStamp(url, directory: name.directory)
            if name.directory { try require(stamp.mode & 0o7777 == 0o700, .path) }
            else if name == .health || name == .processLock {
                try require(stamp.mode & 0o7777 == 0o600, .path)
                if name == .processLock { try require(stamp.size == 0, .path) }
            } else { try require([0o600, 0o644].contains(Int(stamp.mode & 0o7777)), .path) }
            return .init(name: name, stamp: stamp)
        }
    }
    static func validate(_ current: [Self], against saved: [Self],
                         allowingOwnerReceiptPublication: Bool = false) throws {
        try require(current.map(\.name) == Name.allCases && saved.map(\.name) == Name.allCases, .path)
        for (a, b) in zip(current, saved) {
            if a.name == .root && allowingOwnerReceiptPublication {
                // Only this comparison spans the owner receipt's publication.
                // Directory links/size/times describe contents, not object identity.
                try require(a.stamp.device == b.stamp.device && a.stamp.inode == b.stamp.inode
                    && a.stamp.mode == b.stamp.mode, .path)
            } else { try require(a.stamp == b.stamp, .pin) }
        }
    }
    static func controls() throws {
        func fixture(rootLinks: Int = 2, rootInode: Int = 10, rootChanged: Bool = false,
                     stateLinks: Int = 2, settingsLinks: Int = 1) throws -> [Self] {
            let rows: [[String: Any]] = Name.allCases.enumerated().map { index, name in
                let changed = name == .root && rootChanged
                let stamp: [String: Any] = [
                    "device": 1, "inode": name == .root ? rootInode : 10 + index,
                    "size": changed ? 96 : 64, "mode": name.directory ? 0o40700 : 0o100600,
                    "links": name == .root ? rootLinks : name == .state ? stateLinks : name == .settings ? settingsLinks : name.directory ? 2 : 1,
                    "modified": changed ? 11 : 10, "modifiedNS": 0,
                    "changed": changed ? 11 : 10, "changedNS": 0]
                return ["name": name.rawValue, "stamp": stamp]
            }
            return try JSONDecoder().decode([Self].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        func refused(_ current: [Self], _ saved: [Self], publication: Bool) -> Bool {
            do { try validate(current, against: saved, allowingOwnerReceiptPublication: publication); return false }
            catch { return true }
        }
        let saved = try fixture()
        let published = try fixture(rootLinks: 3, rootChanged: true)
        try validate(saved, against: saved)
        try validate(published, against: saved, allowingOwnerReceiptPublication: true)
        try require(refused(published, saved, publication: false))
        try require(refused(try fixture(rootInode: 99), saved, publication: true))
        try require(refused(try fixture(stateLinks: 3), saved, publication: true))
        try require(refused(try fixture(settingsLinks: 2), saved, publication: true))
    }
}
private struct OwnedCancellationOwnerReceipt: Codable {
    let schemaVersion = 1
    let status = "CALLBACK_CANCELLATION_OBSERVED"
    let proofSHA256: String
    let identities: [OwnedCancellationIdentity]
    let settingsSHA256: String, healthSHA256: String
    let ledger: PreparationLedger
    let build: PreparationBuild
    let link: OwnedCancellationLink
}
private struct OwnedCancellationReadPublication: Decodable {
    let method: String
    let ledger: PreparationLedger
}
// Decode the closed proof schema separately: it intentionally contains no raw journal bytes/payload.
private struct OwnedCancellationReadProof: Decodable {
    let positive: Bool
    let callback: OwnedCallbackSnapshot
    let publications: [OwnedCancellationReadPublication]
    let link: OwnedCancellationLink?
    let chainReturned: Bool, sentinelReturned: Bool, operationExited: Bool, sourceClosed: Bool, coreActive: Bool
    let nativeCanceled: Bool, deliveryCanceled: Bool, closingVerified: Bool
    let safetyRequested: Bool, safetyRestored: Bool, zeroSideEffects: Bool
    func validate(_ owner: OwnedCancellationOwnerReceipt) throws {
        let s = callback
        try require(positive && chainReturned && sentinelReturned && operationExited && sourceClosed && !coreActive
            && nativeCanceled && deliveryCanceled && closingVerified && !safetyRequested && safetyRestored && zeroSideEffects)
        try require(!s.unavailable && s.invocations == 1 && s.entered && s.returned && s.late == 0
            && (1...64).contains(s.callbacks) && s.samples == s.callbacks && s.holds == 1
            && s.acknowledgements == 1 && s.sampledTrue && s.returnedAbortObserved && s.rawStatus != nil
            && s.sampleCount == 640_000 && s.timed
            && s.acknowledgementNanoseconds.map({ $0 < 5_000_000_000 }) == true
            && s.token == owner.link.decode && s.link == owner.link && link == owner.link)
        try require(publications.map(\.method) == ["reset", "replace", "replace", "replace", "replace"])
        let ledgers = publications.map(\.ledger)
        let final = owner.ledger
        try require(final.entries.count == 2)
        let keys = final.entries.map(\.key)
        try require(keys[0].p == .nativeConstruction && keys[1] == owner.link.key
            && keys[1].p == .firstRealAudioRequest)
        try require(ledgers.map { $0.entries.map(\.key) } == [[], [keys[0]], [keys[0]], keys, keys])
        try require(ledgers.allSatisfy { $0.schema == 2 && $0.consent == final.consent
            && $0.generation == final.generation && !$0.poisoned && $0.entries.allSatisfy { $0.unresolved == 0 } })
        for ledger in ledgers { try ledger.validate() }
        guard let construction = ledgers[1].entries[0].pending else { throw OwnedRefusal.observation }
        let first = owner.link.pending
        try require(ledgers[3].entries[1].pending == first && construction.attempt != first.attempt
            && construction.launch == first.launch && construction.operation == first.operation
            && construction.selection == first.selection)
        for entry in [ledgers[1].entries[0], ledgers[3].entries[1]] {
            try require(entry.consumed == nil && entry.outcome == nil)
        }
        for index in 2...4 {
            let c = ledgers[index].entries[0]
            try require(c.pending == nil && c.consumed == construction.attempt && c.outcome == .completed)
        }
        try require(try OwnedCancellationReader.canonical(ledgers[4]) == OwnedCancellationReader.canonical(final))
    }
}
private final class OwnedCancellationReadStorage: PreparationStorage {
    private let delegate: PrivatePreparationStorage
    let counts: OwnedCounts
    init(root: URL, counts: OwnedCounts) throws {
        self.counts = counts
        // Caller has already required the existing root/lock/health/settings identities and modes.
        // EEXIST/open existing + lifetime flock; every production mutation boundary refuses too.
        delegate = try PrivatePreparationStorage(root: root, fault: { boundary in
            switch boundary {
            case .read: counts.add("storageReadBoundaries")
            default: try counts.refuse("storageMutationBoundaries")
            }
        })
    }
    func read() throws -> Data? { counts.add("storageReads"); return try delegate.read() }
    func replace(_ data: Data, authorized: () -> Bool) throws { try counts.refuse("readerReplace") }
    func reset(_ data: Data) throws { try counts.refuse("readerReset") }
    func quarantine() throws { try counts.refuse("readerQuarantine") }
}
private struct OwnedCancellationReaderReceipt: Encodable {
    let schemaVersion = 1
    let status = "EXISTING_CANCELED_STATE_UNCHANGED"
    let ownerReceiptSHA256: String, healthSHA256: String, settingsSHA256: String
    let ownerLaunch: UUID, readerLaunch: UUID, attempt: UUID
    let configurePasses: Int, readPasses: Int
    let exactIdentityUnchanged: Bool, nativeQueries: Int, modelReads: Int, authorizations: Int, mutations: Int
}
private enum OwnedCancellationReader {
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func root(_ control: String) throws -> URL {
        guard let path = ownedControl(control), path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              try physical(path) == path else { throw OwnedRefusal.configuration }
        let root = URL(fileURLWithPath: path)
        let stamp = try OwnedStamp(root, directory: true)
        try require(root.path == path && stamp.mode & 0o7777 == 0o700, .path)
        return root
    }
    private static func absent(_ url: URL) throws {
        var st = stat()
        try require(lstat(url.path, &st) != 0 && errno == ENOENT, .path)
    }
    static func run() throws {
        // This is a required assertion of the future supervisor, not OS-settlement proof from XCTest.
        try require(ownedControl("PARLA_OWNED_WHISPER_CANCEL_OWNER_SETTLED") == "1", .configuration)
        let ownerRoot = try root("PARLA_OWNED_WHISPER_CANCEL_OWNER_ROOT")
        try OwnedCancellationGate.ownerRoot(ownerRoot)
        let receiptRoot = try root("PARLA_OWNED_WHISPER_CANCEL_READER_ROOT")
        let prefix = "whisper-b53-cancel-reader-"
        try require(receiptRoot.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(receiptRoot.lastPathComponent.dropFirst(prefix.count))) != nil
            && receiptRoot != ownerRoot && !receiptRoot.path.hasPrefix(ownerRoot.path + "/")
            && !ownerRoot.path.hasPrefix(receiptRoot.path + "/"), .path)
        let receiptRootStamp = try OwnedStamp(receiptRoot, directory: true)
        guard let expected = ownedControl("PARLA_OWNED_WHISPER_CANCEL_OWNER_RECEIPT_SHA256"),
              expected.count == 64, expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw OwnedRefusal.configuration
        }
        let ownerURL = ownerRoot.appendingPathComponent("cancellation-owner.json")
        let ownerStamp = try OwnedStamp(ownerURL)
        let ownerBytes = try boundedRead(ownerURL, maximum: 16_384)
        try require(digest(ownerBytes) == expected, .pin)
        let owner = try JSONDecoder().decode(OwnedCancellationOwnerReceipt.self, from: ownerBytes)
        // Verify encoded fixed constants, rather than accepting Decodable defaults for them.
        struct Header: Decodable { let schemaVersion: Int; let status: String }
        let header = try JSONDecoder().decode(Header.self, from: ownerBytes)
        try require(header.schemaVersion == 1 && header.status == "CALLBACK_CANCELLATION_OBSERVED")
        let proofURL = ownerRoot.appendingPathComponent("cancellation-proof.json")
        let proofStamp = try OwnedStamp(proofURL)
        let proofBytes = try boundedRead(proofURL, maximum: 16_384)
        try require(digest(proofBytes) == owner.proofSHA256, .pin)
        try JSONDecoder().decode(OwnedCancellationReadProof.self, from: proofBytes).validate(owner)
        let before = try OwnedCancellationIdentity.capture(ownerRoot)
        try OwnedCancellationIdentity.validate(before, against: owner.identities, allowingOwnerReceiptPublication: true)
        let healthRoot = ownerRoot.appendingPathComponent("state/preparation-health", isDirectory: true)
        let healthURL = healthRoot.appendingPathComponent("health.json")
        let settingsURL = ownerRoot.appendingPathComponent("state/settings.json")
        for name in ["quarantine", "replacement"] { try absent(healthRoot.appendingPathComponent(name)) }
        let healthBytes = try boundedRead(healthURL, maximum: 16_384)
        let settingsBytes = try boundedRead(settingsURL, maximum: 131_072)
        try require(digest(healthBytes) == owner.healthSHA256 && digest(settingsBytes) == owner.settingsSHA256, .pin)
        let ledger = try OwnedObservedPreparationStorage.decode(healthBytes)
        let saved = try JSONDecoder().decode(Settings.self, from: settingsBytes)
        try require(try canonical(ledger) == canonical(owner.ledger))
        try require(ledger.schema == 2 && !ledger.poisoned && ledger.entries.count == 2
            && saved.nativePreparationSafeStartEnabled && saved.nativePreparationConsent == ledger.consent
            && saved.recognitionEngine == .whisper && saved.language == "en" && saved.dictionary.isEmpty
            && !saved.historyEnabled && !saved.recoveryAudioEnabled && !saved.cleanupEnabled && !saved.warmMic
            && !saved.streamPreviewEnabled)
        let first = ledger.entries[1]
        try require(ledger.entries.allSatisfy { $0.pending == nil && $0.unresolved == 0 }
            && ledger.entries[0].outcome == .completed && ledger.entries[0].consumed != nil
            && first.key == owner.link.key && first.consumed == owner.link.pending.attempt && first.outcome == .canceled)
        try require(ledger.entries.allSatisfy { $0.key.a == owner.build.app && $0.key.n == owner.build.native
            && $0.key.h == owner.build.architecture && $0.key.m == "base.en"
            && $0.key.s == OwnedPins.modelSHA && $0.key.b == 147_964_211 })
        // All validation above precedes PrivatePreparationStorage's potentially creating initializer.
        let counts = OwnedCounts()
        let storage = try OwnedCancellationReadStorage(root: healthRoot, counts: counts)
        try OwnedCancellationIdentity.validate(OwnedCancellationIdentity.capture(ownerRoot), against: before)
        let core = RecognitionPreparation(storage: { storage }, build: {
            try counts.refuse("readerBuildQueries"); throw OwnedRefusal.isolation
        })
        try require(core.launch != owner.link.pending.launch)
        for _ in 0..<3 {
            core.configure(enabled: saved.nativePreparationSafeStartEnabled,
                consent: saved.nativePreparationConsent, selection: owner.link.pending.selection)
            try require(core.snapshot.status == .ready && core.snapshot.refusal == nil
                && core.matchesSavedPermission(saved) && !core.hasActiveEntry && !core.persistenceFailed)
            try require(try storage.read() == healthBytes)
            try require(try boundedRead(settingsURL, maximum: 131_072) == settingsBytes)
            try require(try boundedRead(healthURL, maximum: 16_384) == healthBytes)
            try OwnedCancellationIdentity.validate(OwnedCancellationIdentity.capture(ownerRoot), against: before)
            for name in ["quarantine", "replacement"] { try absent(healthRoot.appendingPathComponent(name)) }
        }
        let forbidden = ["storageMutationBoundaries", "readerReplace", "readerReset", "readerQuarantine", "readerBuildQueries"]
        try require(forbidden.allSatisfy { counts.value($0) == 0 }
            && counts.value("storageReads") == 4 && counts.value("storageReadBoundaries") == 4)
        try require(try OwnedStamp(ownerURL) == ownerStamp && OwnedStamp(proofURL) == proofStamp, .pin)
        try require(try boundedRead(ownerURL, maximum: 16_384) == ownerBytes
            && boundedRead(proofURL, maximum: 16_384) == proofBytes, .pin)
        try require(try OwnedStamp(receiptRoot, directory: true) == receiptRootStamp, .pin)
        let receiptURL = receiptRoot.appendingPathComponent("cancellation-reader.json")
        try absent(receiptURL)
        let receipt = OwnedCancellationReaderReceipt(ownerReceiptSHA256: expected, healthSHA256: owner.healthSHA256,
            settingsSHA256: owner.settingsSHA256, ownerLaunch: owner.link.pending.launch, readerLaunch: core.launch,
            attempt: owner.link.pending.attempt, configurePasses: 3, readPasses: 4,
            exactIdentityUnchanged: true, nativeQueries: 0, modelReads: 0, authorizations: 0, mutations: 0)
        let bytes = try canonical(receipt)
        try require(bytes.count <= 4096, .bounds)
        let fd = Darwin.open(receiptURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, .path)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: bytes) // sole new reader metadata file, outside owner/journal namespace.
        try file.synchronize()
        try require(try boundedRead(receiptURL, maximum: 4096) == bytes)
    }
}

// Distinct decorator controls: no fake full API, no model/source IO, no C callback/user-data pointer.
private enum OwnedCallbackControls {
    private final class Lifetime {
        let counts: OwnedCounts
        init(_ counts: OwnedCounts) { self.counts = counts }
        deinit { counts.add("lifetimeReleased") }
    }
    private final class Spy: WhisperNativeContext {
        struct Arguments: Equatable {
            let samples: [Float], prompt: String?, language: String, configuration: WhisperDecodeConfiguration
            let nilPredicate: Bool, timed: Bool
        }
        var multilingual: Bool { calls.append("multilingual"); return true }
        var calls: [String] = []
        var arguments: Arguments?
        var result: WhisperNativeDecode? = .init(status: 37, segments: ["safe test value"], abortObserved: true)
        var pollNow = true
        var retain = false
        var retained: (() -> Bool)?
        var sampled: Bool?
        var returned = false
        func knowsLanguage(_ code: String) -> Bool { calls.append(code); return code == "en" }
        func spokenLanguage() -> String? { calls.append("spokenLanguage"); return "fr" }
        private func record(_ samples: [Float], prompt: String?, language: String,
                            configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?, timed: Bool) {
            arguments = .init(samples: samples, prompt: prompt, language: language, configuration: configuration,
                nilPredicate: shouldAbort == nil, timed: timed)
            if retain { retained = shouldAbort }
            if pollNow { sampled = shouldAbort?() }
            returned = true
        }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            record(samples, prompt: initialPrompt, language: language, configuration: configuration,
                shouldAbort: shouldAbort, timed: false)
            return result! // deterministic spy result only, never supplied to real-owner construction.
        }
        func decodeTimed(_ samples: [Float], initialPrompt: String?, language: String,
                         configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode? {
            record(samples, prompt: initialPrompt, language: language, configuration: configuration,
                shouldAbort: shouldAbort, timed: true)
            return result
        }
        func dispose() { retained = nil }
    }
    static func run() throws {
        try OwnedCancellationIdentity.controls()
        let prompts: [String?] = [nil, "", "specific prompt"]
        let timing = try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 320,
            cues: [.init(text: "safe timing value", start: 0, end: 1)])
        for timed in [false, true] {
            for prompt in prompts {
                for nilPredicate in [false, true] {
                    let spy = Spy(), observer = OwnedCallbackInterval(), counts = OwnedCounts()
                    spy.result = .init(status: timed ? -7 : 0, segments: ["safe test value"],
                        abortObserved: timed, timing: timing)
                    let wrapper = OwnedCallbackContext(spy, observer: observer)
                    try require(wrapper.multilingual && wrapper.knowsLanguage("en") && !wrapper.knowsLanguage("xx")
                        && wrapper.spokenLanguage() == "fr")
                    try require(spy.calls == ["multilingual", "en", "xx", "spokenLanguage"])
                    let configuration = WhisperDecodeConfiguration(timed: timed)
                    let samples: [Float] = [0, 0.25, -0.5]
                    let original: (() -> Bool)? = nilPredicate ? nil : { counts.add("original"); return true }
                    let result = timed
                        ? wrapper.decodeTimed(samples, initialPrompt: prompt, language: "en", configuration: configuration, shouldAbort: original)
                        : wrapper.decode(samples, initialPrompt: prompt, language: "en", configuration: configuration, shouldAbort: original)
                    try require(result == spy.result && spy.arguments == .init(samples: samples, prompt: prompt,
                        language: "en", configuration: configuration, nilPredicate: nilPredicate, timed: timed))
                    let s = observer.snapshot
                    try require(counts.value("original") == (nilPredicate ? 0 : 1)
                        && spy.sampled == (nilPredicate ? nil : true) && s.invocations == 1 && s.returned
                        && s.callbacks == (nilPredicate ? 0 : 1) && s.samples == s.callbacks
                        && s.holds == 0 && s.acknowledgements == 0 && s.late == 0 && !s.unavailable
                        && s.rawStatus == spy.result?.status && s.returnedAbortObserved == spy.result?.abortObserved)
                    spy.dispose(); observer.disposeNotification()
                }
            }
        }
        // Optional timed result stays nil, including with a nil predicate.
        for nilPredicate in [false, true] {
            let spy = Spy(), observer = OwnedCallbackInterval(), counts = OwnedCounts()
            spy.result = nil
            let wrapper = OwnedCallbackContext(spy, observer: observer)
            let original: (() -> Bool)? = nilPredicate ? nil : { counts.add("original"); return false }
            let result = wrapper.decodeTimed([], initialPrompt: nil, language: "xx",
                configuration: WhisperDecodeConfiguration(timed: true), shouldAbort: original)
            try require(result == nil && spy.arguments?.nilPredicate == nilPredicate
                && counts.value("original") == (nilPredicate ? 0 : 1)
                && spy.sampled == (nilPredicate ? nil : false) && observer.snapshot.returned
                && observer.snapshot.rawStatus == nil && !observer.snapshot.returnedAbortObserved)
            spy.dispose(); observer.disposeNotification()
        }
        // Safe retained Swift closure is invoked only after decorator return/interval close.
        let spy = Spy(), observer = OwnedCallbackInterval(), counts = OwnedCounts()
        spy.pollNow = false; spy.retain = true
        observer.install { _ in counts.add("notification") }
        let wrapper = OwnedCallbackContext(spy, observer: observer)
        func original() -> () -> Bool {
            let lifetime = Lifetime(counts)
            return { [lifetime] in lifetime.counts.add("original"); return true }
        }
        let before = wrapper.decodeTimed([0.5], initialPrompt: "", language: "en",
            configuration: WhisperDecodeConfiguration(timed: true), shouldAbort: original())
        try require(before == spy.result && spy.returned && observer.snapshot.returned
            && observer.snapshot.callbacks == 0 && counts.value("original") == 0 && counts.value("lifetimeReleased") == 0)
        try require(spy.retained?() == true)
        let late = observer.snapshot
        try require(late.late == 1 && late.callbacks == 0 && late.holds == 0 && late.acknowledgements == 0
            && late.unavailable && counts.value("notification") == 0 && counts.value("original") == 1
            && late.rawStatus == before?.status && late.returnedAbortObserved == before?.abortObserved)
        // An acknowledgement after close cannot reopen/upgrade it, even with an original true.
        // No fabricated owner tuple is needed: isHeld is already false for the actual token.
        try require(late.token.map { !observer.isHeld($0) } == true)
        var refused = false
        do { try observer.requirePositive() }
        catch OwnedRefusal.observation { refused = true }
        try require(refused) // a successful requirePositive must fail this counterexample.
        spy.dispose(); observer.disposeNotification()
        try require(counts.value("lifetimeReleased") == 1)
        // Context lifetime: wrapper retains its delegate, and releases it without a rig/controller cycle.
        var delegate: Spy? = Spy()
        weak var weakDelegate = delegate
        var retainingWrapper: OwnedCallbackContext? = OwnedCallbackContext(delegate!, observer: OwnedCallbackInterval())
        delegate = nil
        try require(weakDelegate != nil)
        _ = retainingWrapper?.decode([0], initialPrompt: nil, language: "en", configuration: WhisperDecodeConfiguration(), shouldAbort: nil)
        try require(weakDelegate?.returned == true)
        retainingWrapper = nil
        try require(weakDelegate == nil)
    }
}
