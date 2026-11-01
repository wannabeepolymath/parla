import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

func selectedApplicationTestBinding(source: UUID = UUID(), generation: UInt64 = 7, epoch: UUID = UUID(),
    pid: Int32 = 123, launch: Int64 = 1, bundle: String = "example.application", label: String = "Literal application",
    bundlePath: String = "/Applications/Example.app", executablePath: String = "/Applications/Example.app/Contents/MacOS/Example") -> SelectedApplicationBinding {
    .init(selection:UUID(),source:source,sourceGeneration:generation,captureEpoch:epoch,pid:pid,launchNanoseconds:launch,
          bundleID:bundle,bundlePath:bundlePath,executablePath:executablePath,label:label)
}
func selectedApplicationTestSelection(_ binding: SelectedApplicationBinding) -> MeetingSession.Selection {
    .init(instance:binding.source,kind:.selectedApplication,label:binding.label,generation:binding.sourceGeneration)
}
func selectedApplicationTestIngress(_ binding: SelectedApplicationBinding, source: UUID? = nil,
    generation: UInt64? = nil, epoch: UUID? = nil, charged: Bool = false) throws -> MeetingAudioIngress {
    let ingress = MeetingAudioIngress(context:.init(session:UUID(),ownerGeneration:3,source:source ?? binding.source,
        sourceGeneration:generation ?? binding.sourceGeneration,segment:UUID(),epoch:epoch ?? binding.captureEpoch))
    if charged { try ingress.reserve(id:UUID(),slot:1); try ingress.reserve(id:UUID(),slot:2); try ingress.activate() }
    return ingress
}

/// Finite, synchronous release for defer paths. Cancellation never impersonates body exit.
@MainActor final class SelectedApplicationTestGate {
    private var opened = false
    private var waiter: CheckedContinuation<Bool,Never>?, timer: Task<Void,Never>?
    func wait() async -> Bool {
        if opened { return true }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil); waiter = continuation
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds:8_000_000_000) } catch { return }
                guard let self else { return }
                let pending = waiter; waiter = nil; timer = nil; pending?.resume(returning:false)
            }
        }
    }
    func open() {
        opened = true; timer?.cancel(); timer = nil
        let pending = waiter; waiter = nil; pending?.resume(returning:true)
    }
}
final class SelectedApplicationTestLifetime {
    let binding: SelectedApplicationBinding
    init(_ binding: SelectedApplicationBinding) { self.binding = binding }
}

/// Only an app-port fake. No AppKit/HAL, converter, device, observer or S2 fake implementation.
@MainActor final class SelectedApplicationTestBackend {
    let binding: SelectedApplicationBinding
    private let pure = MeetingApplicationAudioCapture()
    private let stopped = SelectedApplicationTestGate(), bodyExit = SelectedApplicationTestGate(), cleanup = SelectedApplicationTestGate()
    let stopRequested = XCTestExpectation(description:"acquisition stop requested")
    let cleanupEntered = XCTestExpectation(description:"actual cleanup entered after held body exit")
    let completed = XCTestExpectation(description:"actual task completed cleanup and EOS")
    private(set) var pureChecks = 0, contextChecks = 0, starts = 0, stopRequests = 0
    private(set) var ingress: MeetingAudioIngress?, task: Task<Void,Never>?, heldBody: MeetingAudioIngress.Body?
    private(set) var receivedBinding: SelectedApplicationBinding?, checkedContext: MeetingAudioIngress.Context?
    private(set) var events: [String] = [], didComplete = false, timedOut = false, error: Error?
    private(set) weak var lifetime: SelectedApplicationTestLifetime?
    var notStarted = false, initialPCM: [Float] = []
    init(_ binding: SelectedApplicationBinding) { self.binding = binding }
    var port: MeetingSelectedApplicationCapture.CorePort {
        .init(validate:{ [self] binding in
            pureChecks += 1; events.append("pure"); return pure.validate(binding)
        },validateContext:{ [self] binding,context in
            contextChecks += 1; events.append("context"); checkedContext = context
            return pure.validate(binding,context:context)
        },start:{ [self] binding,ingress in begin(binding,ingress) })
    }
    private func begin(_ binding: SelectedApplicationBinding, _ ingress: MeetingAudioIngress) -> MeetingSelectedApplicationCapture.Start {
        starts += 1; events.append("start"); receivedBinding = binding; self.ingress = ingress
        if notStarted { return .notStarted }
        do {
            if !initialPCM.isEmpty {
                let body = try ingress.enter()
                defer { try? ingress.leave(body) }
                _ = try initialPCM.withUnsafeBufferPointer {
                    try ingress.receive(body,canonical:$0,input:.init(rate:16_000,channels:1,frames:initialPCM.count))
                }
            }
            heldBody = try ingress.enter()
        } catch { self.error = error; return .notStarted }
        let lifetime = SelectedApplicationTestLifetime(binding); self.lifetime = lifetime
        let actual = Task { @MainActor [self,lifetime] in
            let stop = await stopped.wait(), body = await bodyExit.wait()
            do { if let heldBody { try ingress.leave(heldBody); self.heldBody = nil } } catch { self.error = error }
            cleanupEntered.fulfill()
            let clean = await cleanup.wait(); timedOut = !stop || !body || !clean
            if timedOut { ingress.revoke() }
            do { _ = try ingress.end(ingress.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0)) }
            catch { self.error = error }
            withExtendedLifetime(lifetime) {}
            didComplete = true; completed.fulfill()
        }
        task = actual
        return .actual(.init(task:actual,requestStop:{ [self,lifetime] in
            withExtendedLifetime(lifetime) { requestStop() }
        }))
    }
    private func requestStop() {
        stopRequests += 1; ingress?.fence(); stopped.open()
        if stopRequests == 1 { stopRequested.fulfill() }
    }
    func releaseBody() { bodyExit.open() }
    func releaseCleanup() { cleanup.open() }
    func releaseAll() { ingress?.fence(); stopped.open(); bodyExit.open(); cleanup.open() }
    func latePCM(_ samples: [Float]) throws -> Int {
        let ingress = try XCTUnwrap(ingress), body = try XCTUnwrap(heldBody)
        return try samples.withUnsafeBufferPointer {
            try ingress.receive(body,canonical:$0,input:.init(rate:16_000,channels:1,frames:samples.count))
        }
    }
}

@MainActor final class SelectedApplicationTestOperation {
    let done = XCTestExpectation(description:"owner operation actually returned")
    private(set) var result: Result<Void,Error>?, task: Task<Void,Never>?
    init(_ work: @escaping @MainActor () async throws -> Void) {
        task = Task { [self] in
            do { try await work(); result = .success(()) } catch { result = .failure(error) }
            done.fulfill()
        }
    }
}
@MainActor func selectedApplicationTestCompleted(_ test: XCTestCase, _ operation: SelectedApplicationTestOperation) async -> Result<Void,Error>? {
    await test.fulfillment(of:[operation.done],timeout:4)
    guard let result = operation.result else { XCTFail("No observed completion; refusing an unbounded join"); return nil }
    if let task = operation.task { await task.value }
    return result
}

final class MeetingSelectedApplicationCaptureTests: XCTestCase {
    @MainActor private func refused(_ producer: MeetingSessionOwner.Producer, source: UUID) {
        XCTAssertEqual(producer.source,source)
        if case .actual = producer.exit { XCTFail("Expected exact-source notStarted") }
    }
    @MainActor func testDefaultOffAndExactPureSelectionValidationNeverStart() throws {
        let binding = selectedApplicationTestBinding(label:"Café"), selection = selectedApplicationTestSelection(binding)
        let backend = SelectedApplicationTestBackend(binding), ingress = try selectedApplicationTestIngress(binding)
        let defaults = [MeetingSelectedApplicationCapture(binding:binding),
                        MeetingSelectedApplicationCapture(binding:binding,core:backend.port)]
        for adapter in defaults {
            XCTAssertFalse(adapter.validate(selection)); adapter.requestStop()
            refused(adapter.start(selection,ingress:ingress),source:selection.instance)
        }
        XCTAssertEqual(backend.pureChecks,0); XCTAssertEqual(backend.contextChecks,0); XCTAssertEqual(backend.starts,0)
        let core = MeetingApplicationAudioCapture(), before = ingress.facts
        XCTAssertTrue(core.validate(binding)); XCTAssertTrue(core.validate(binding,context:ingress.context))
        if case .actual = core.startSelectedApplication(binding:binding,ingress:ingress) { XCTFail("Core default must remain off") }
        XCTAssertEqual(ingress.facts,before)
        let adapter = MeetingSelectedApplicationCapture(binding:binding,core:backend.port,enabled:true)
        XCTAssertTrue(adapter.validate(selection)); XCTAssertTrue(adapter.validate(selection)) // no reservation
        for invalid in [MeetingSession.Selection(instance:binding.source,kind:.microphone,label:binding.label,generation:7),
                        .init(instance:binding.source,kind:.disclosedSystem,label:binding.label,generation:7),
                        .init(instance:UUID(),kind:.selectedApplication,label:binding.label,generation:7),
                        .init(instance:binding.source,kind:.selectedApplication,label:binding.label,generation:8),
                        .init(instance:binding.source,kind:.selectedApplication,label:"Cafe\u{301}",generation:7)] {
            XCTAssertFalse(adapter.validate(invalid))
        }
        XCTAssertEqual(backend.pureChecks,2); XCTAssertEqual(backend.contextChecks,0); XCTAssertEqual(backend.starts,0)
        XCTAssertEqual(backend.stopRequests,0); XCTAssertEqual(ingress.facts,before)
    }
    @MainActor func testInvalidBindingsRefusePurelyBeforeContextAndBackendStart() throws {
        let invalid = [selectedApplicationTestBinding(pid:0),selectedApplicationTestBinding(generation:0),
            selectedApplicationTestBinding(launch:0),selectedApplicationTestBinding(bundle:""),
            selectedApplicationTestBinding(label:""),selectedApplicationTestBinding(label:"bad\nlabel"),
            selectedApplicationTestBinding(label:String(repeating:"x",count:129)),
            selectedApplicationTestBinding(bundlePath:"relative"),selectedApplicationTestBinding(executablePath:"relative")]
        for binding in invalid {
            let backend = SelectedApplicationTestBackend(binding), selection = selectedApplicationTestSelection(binding)
            let adapter = MeetingSelectedApplicationCapture(binding:binding,core:backend.port,enabled:true)
            let ingress = try selectedApplicationTestIngress(binding), before = ingress.facts
            XCTAssertFalse(adapter.validate(selection))
            refused(adapter.start(selection,ingress:ingress),source:selection.instance)
            XCTAssertEqual(backend.contextChecks,0); XCTAssertEqual(backend.starts,0); XCTAssertEqual(ingress.facts,before)
        }
    }
    @MainActor func testForeignActualContextConsumesAttemptWithoutBackendStart() throws {
        let binding = selectedApplicationTestBinding(), selection = selectedApplicationTestSelection(binding)
        let contexts = [try selectedApplicationTestIngress(binding,source:UUID()),
                        try selectedApplicationTestIngress(binding,generation:8),
                        try selectedApplicationTestIngress(binding,epoch:UUID())]
        for ingress in contexts {
            let backend = SelectedApplicationTestBackend(binding)
            let adapter = MeetingSelectedApplicationCapture(binding:binding,core:backend.port,enabled:true)
            refused(adapter.start(selection,ingress:ingress),source:selection.instance)
            XCTAssertEqual(backend.checkedContext,ingress.context); XCTAssertEqual(backend.events,["pure","context"])
            refused(adapter.start(selection,ingress:try selectedApplicationTestIngress(binding)),source:selection.instance)
            XCTAssertEqual(backend.starts,0); XCTAssertEqual(backend.contextChecks,1)
        }
    }
    @MainActor func testBackendRefusalCannotRetryOrRetargetAndStopHasNoRecording() throws {
        let binding = selectedApplicationTestBinding(), backend = SelectedApplicationTestBackend(binding)
        backend.notStarted = true
        let adapter = MeetingSelectedApplicationCapture(binding:binding,core:backend.port,enabled:true)
        let selection = selectedApplicationTestSelection(binding), ingress = try selectedApplicationTestIngress(binding,charged:true)
        refused(adapter.start(selection,ingress:ingress),source:selection.instance)
        for next in [selection,.init(instance:UUID(),kind:.selectedApplication,label:binding.label,generation:8)] {
            refused(adapter.start(next,ingress:ingress),source:next.instance)
        }
        adapter.requestStop(); XCTAssertEqual(backend.starts,1); XCTAssertEqual(backend.stopRequests,0)
        XCTAssertEqual(backend.receivedBinding,binding); XCTAssertEqual(backend.checkedContext,ingress.context)
        XCTAssertEqual(backend.events,["pure","context","start"])
    }
    @MainActor func testActualTaskIdentityCancellationAndCleanupLifetimeHaveNoSuccessor() async throws {
        for cancel in [false,true] {
            let binding = selectedApplicationTestBinding(), backend = SelectedApplicationTestBackend(binding)
            defer { backend.releaseAll() }
            let adapter = MeetingSelectedApplicationCapture(binding:binding,core:backend.port,enabled:true)
            let selection = selectedApplicationTestSelection(binding), ingress = try selectedApplicationTestIngress(binding,charged:true)
            let producer = adapter.start(selection,ingress:ingress)
            XCTAssertEqual(producer.source,selection.instance)
            guard case .actual(let actual) = producer.exit else { XCTFail("Expected actual task"); return }
            let expected = try XCTUnwrap(backend.task)
            guard actual == expected else { XCTFail("Returned task identity changed; not joining"); return }
            XCTAssertEqual(backend.receivedBinding,binding)
            XCTAssertEqual(backend.checkedContext,ingress.context); XCTAssertEqual(backend.events,["pure","context","start"])
            if cancel { actual.cancel(); XCTAssertTrue(try XCTUnwrap(backend.task).isCancelled) }
            adapter.requestStop(); XCTAssertEqual(backend.stopRequests,1)
            XCTAssertFalse(ingress.facts.open); XCTAssertTrue(ingress.facts.bodyEntered); XCTAssertFalse(ingress.facts.ended)
            XCTAssertFalse(backend.didComplete); XCTAssertNotNil(backend.lifetime)
            refused(adapter.start(selection,ingress:ingress),source:selection.instance)
            backend.releaseBody(); await fulfillment(of:[backend.cleanupEntered],timeout:3)
            XCTAssertFalse(ingress.facts.bodyEntered); XCTAssertFalse(backend.didComplete); XCTAssertFalse(ingress.facts.ended)
            XCTAssertNotNil(backend.lifetime); adapter.requestStop(); XCTAssertEqual(backend.stopRequests,2)
            backend.releaseCleanup(); await fulfillment(of:[backend.completed],timeout:3)
            guard backend.didComplete else { XCTFail("No actual completion; not joining"); return }
            await actual.value
            XCTAssertTrue(ingress.facts.ended); XCTAssertNil(backend.error); XCTAssertFalse(backend.timedOut)
            XCTAssertNotNil(backend.lifetime) // adapter retains recording even after actual exit
            refused(adapter.start(selection,ingress:try selectedApplicationTestIngress(binding,charged:true)),source:selection.instance)
            let successor = MeetingSession.Selection(instance:UUID(),kind:.selectedApplication,label:binding.label,generation:8)
            XCTAssertFalse(adapter.validate(successor)); refused(adapter.start(successor,ingress:ingress),source:successor.instance)
            XCTAssertEqual(backend.starts,1)
        }
    }
}
