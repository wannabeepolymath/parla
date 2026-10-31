import XCTest
import Foundation
@testable import ParlaCore

private actor ParakeetResultBox {
    var result: RecognitionPassResult?
    func store(_ result: RecognitionPassResult) { self.result = result }
}
final class ParakeetWorkerTests: XCTestCase {
    func testMalformedTerminalOrNonzeroExitNeverPublishesPrefix() async throws {
        for variant in 0..<6 {
            let rig = ParakeetTestRig(); var options = ParakeetFakeOptions()
            switch variant {
            case 0: options.wrongNonce = true
            case 1: options.duplicate = true
            case 2: options.missing = true
            case 3: options.truncated = true
            case 4: options.trailing = true
            default: options.nonzero = true
            }
            let child = ParakeetFakeChild(options)
            let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings))
            let result = await handle.recognize([0.25], pass: .fullFinal)
            XCTAssertNil(result.text, "variant \(variant)")
            XCTAssertEqual(result.native, .failed(.parakeet))
        }
    }
    func testCancellationJoinsActualExitAndIndependentIODrainBeforeLeaseOrQueueSuccessor() async {
        let rig = ParakeetTestRig(); var options = ParakeetFakeOptions(); options.holdExit = true; options.holdIO = true
        let child = ParakeetFakeChild(options), box = ParakeetResultBox()
        let operation = PendingOperation(name: "fake Parakeet held native exit")
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            do {
                let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings), operation: operation)
                let result = await handle.recognize([0.25], pass: .fullFinal, shouldAbort: { operation.shouldAbort })
                await box.store(result)
            } catch { XCTFail("positive held fixture acquisition: \(error)") }
        })
        let next = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "successor"), work: { rig.counters.add("successor") })
        await child.state.inputEntered.wait()
        operation.revoke(); operation.requestAbort()
        await child.state.canceled.wait()
        XCTAssertEqual(rig.counters.value("release"), 0); XCTAssertEqual(rig.counters.value("successor"), 0)
        XCTAssertFalse(operation.hasExited)
        await child.exit.release()
        await child.state.exitObserved.wait()
        XCTAssertEqual(rig.counters.value("successor"), 0); XCTAssertEqual(rig.counters.value("release"), 0)
        await child.state.releaseIO()
        await first.value; await next.value
        let result = await box.result
        XCTAssertTrue(result?.canceled == true); XCTAssertNil(result?.text)
        XCTAssertEqual(result?.native, .completed(.init(text: "local result")))
        XCTAssertTrue(operation.hasExited); XCTAssertEqual(rig.counters.value("release"), 1)
        XCTAssertEqual(rig.counters.value("successor"), 1)
        let count = await child.state.cancellationCount; XCTAssertEqual(count, 1)
        for channel in [child.control, child.pcm, child.output, child.errors] {
            let pipe = channel as! ParakeetTestPipe
            let joined = await pipe.joins; XCTAssertEqual(joined, 1)
        }
    }
    func testLogicalDeadlineEqualityExpiresWhileActualExitRemainsOwned() async throws {
        for hello in [false, true] {
            let rig = ParakeetTestRig(); var options = ParakeetFakeOptions()
            options.holdExit = true; options.holdIO = hello; options.holdHello = hello
            let child = ParakeetFakeChild(options)
            let handle = try await rig.factory(child, logicalClock: true).acquire(request: .init(settings: rig.settings))
            let owned = Task { await handle.recognize([0.25], pass: .fullFinal) }
            await child.state.inputEntered.wait()
            rig.counters.advance(hello ? 5_000_000_000 : 120_000_000_000)
            await child.state.canceled.wait()
            XCTAssertEqual(rig.counters.value("release"), 0)
            await child.exit.release(); await child.state.releaseIO()
            let result = await owned.value
            XCTAssertNil(result.text); XCTAssertEqual(result.native, .failed(.deadline))
        }
    }
    func testRealExitArbiterRetriesEINTRAndRetiresSignalAuthorityBeforePIDReuse() {
        var observations: [ParakeetExitArbiter.Observation] = [.interrupted, .running, .running, .running, .reaped(0)]
        var waits: [Int32] = [], signals: [(Int32, Int32)] = []
        let arbiter = ParakeetExitArbiter(pid: 12345, wait: { pid in waits.append(pid); return observations.removeFirst() }, signal: { signals.append(($0, $1)) })
        arbiter.cancel(now: 0); arbiter.cancel(now: 1)
        arbiter.tick(now: 1_999_999_999); XCTAssertTrue(signals.isEmpty)
        arbiter.tick(now: 2_000_000_000); XCTAssertEqual(signals.map(\.1), [SIGTERM])
        arbiter.tick(now: 4_000_000_000); XCTAssertEqual(signals.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertTrue(arbiter.forcedTerminationRequested)
        arbiter.tick(now: 4_000_000_001); XCTAssertEqual(arbiter.status, 0)
        arbiter.cancel(now: 8_000_000_000); arbiter.tick(now: UInt64.max)
        XCTAssertEqual(waits, [12345, 12345, 12345, 12345, 12345])
        XCTAssertEqual(signals.map(\.0), [12345, 12345])
        let uncertain = ParakeetExitArbiter(pid: 10, wait: { _ in .unknown }, signal: { _, _ in XCTFail("unknown exit cannot authorize a signal") })
        uncertain.cancel(now: 0); uncertain.tick(now: UInt64.max); uncertain.tick(now: UInt64.max)
        XCTAssertTrue(uncertain.uncertain); XCTAssertNil(uncertain.status)
    }
    func testDedicatedCancelControlAndWriterJoinWhilePCMIsBlocked() async throws {
        let rig = ParakeetTestRig(), gate = ParakeetTestWriteGate(), box = ParakeetResultBox()
        var options = ParakeetFakeOptions(); options.holdExit = true; options.holdIO = true
        let child = ParakeetFakeChild(options, pcmGate: gate)
        let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings))
        let owned = Task { let result = await handle.recognize([0.25], pass: .fullFinal); await box.store(result); return result }
        await gate.entered.wait()
        owned.cancel()
        await child.state.controlCanceled.wait() // actual Cancel frame arrived while PCM write stays held
        let before = await box.result; XCTAssertNil(before)
        await child.exit.release(); await child.state.releaseIO(); await child.state.exitObserved.wait()
        let afterExit = await box.result; XCTAssertNil(afterExit)
        await gate.resumed.release()
        let result = await owned.value
        XCTAssertTrue(result.canceled); XCTAssertNil(result.text)
    }
    func testOneAcquiredSessionCannotLaunchConcurrentWorkersWithTheSameNonce() async throws {
        let rig = ParakeetTestRig(); var options = ParakeetFakeOptions(); options.holdExit = true
        let child = ParakeetFakeChild(options)
        let handle = try await rig.factory(child).acquire(request: .init(settings: rig.settings))
        let first = Task { await handle.recognize([0.25], pass: .fullFinal) }
        await child.state.inputEntered.wait()
        let duplicate = await handle.recognize([0.5], pass: .command)
        XCTAssertEqual(duplicate.native, .failed(.unsupportedCapability)); XCTAssertEqual(rig.counters.value("launch"), 1)
        await child.exit.release()
        let result = await first.value; XCTAssertEqual(result.text, "local result")
    }

}
