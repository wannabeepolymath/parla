import Foundation
import Testing
@testable import ParakeetHelper

actor HelperMemoryChannel: ParakeetChannel {
    private var data: Data
    private var ended: Bool
    private var pending: (Int, CheckedContinuation<Data, Error>)?
    private var reads = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func waitForReads(_ count: Int) async {
        if reads < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }
    init(_ data: Data = Data(), ended: Bool = false) { self.data = data; self.ended = ended }
    func read(upTo count: Int) async throws -> Data {
        reads += 1
        let ready = observers.filter { $0.0 <= reads }; observers.removeAll { $0.0 <= reads }
        for observer in ready { observer.1.resume() }
        if !data.isEmpty { let result = data.prefix(count); data.removeFirst(result.count); return result }
        if ended { return Data() }
        return try await withCheckedThrowingContinuation { pending = (count, $0) }
    }
    func write(_ value: Data) { data.append(value); wake() }
    func bytes() -> Data { data }
    func close() { ended = true; wake() }
    func join() {}
    private func wake() {
        guard let (count, continuation) = pending, !data.isEmpty || ended else { return }
        pending = nil
        let result = data.prefix(count); data.removeFirst(result.count); continuation.resume(returning: result)
    }
}
private enum HelperNativeFailure: Error { case failed }
private actor HelperSession: LocalASRSession {
    var calls: [[Float]] = []
    var cleaned = 0
    var configurations: [LocalModelConfiguration] = []
    var hold = false
    var entered = false
    private var outcome: ParakeetWire.Code = .completed
    private var latch: CheckedContinuation<Void, Never>?
    func open(_ c: LocalModelConfiguration) { configurations.append(c) }
    func transcribe(_ samples: [Float], filter: String?) async throws -> String {
        calls.append(samples); entered = true
        if hold { await withCheckedContinuation { latch = $0 } }
        if outcome == .failed { throw HelperNativeFailure.failed }
        if outcome == .canceled { throw CancellationError() }
        return "tiny local result"
    }
    func cleanup() { cleaned += 1 }
    func setHold(outcome: ParakeetWire.Code = .completed) { hold = true; self.outcome = outcome }
    func release() { latch?.resume(); latch = nil }
}
private actor HelperCompletion {
    var done = false
    func finish() { done = true }
}
private actor HelperLoadGate {
    var entered = false
    var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func release() { opened = true; for c in waiters { c.resume() }; waiters = [] }
}
/// Only the synchronous parent-loss bottom is shared across receiver/test tasks.
private final class HelperLossCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
struct HelperRunnerTests {
    private func identity() -> ParakeetWire.Identity { .init(helperBuild: String(repeating: "a", count: 64), osScope: "fixture-os") }
    @Test func actualRunnerDrivesLocalSessionAndEmitsOneBoundedTerminal() async throws {
        for mode in [ParakeetWire.Mode.recognizeBatch, .prepareLoad] {
            let id = identity(), session = HelperSession()
            let samples: [Float] = mode == .prepareLoad ? [] : [0, -0.5, 1]
            let request = ParakeetWire.Record(identity: id, mode: mode, directory: "/owned/fixture", sampleCount: samples.count, filter: "pl")
            let control = HelperMemoryChannel(try ParakeetWire.encode(request, kind: .request))
            let frames = try (samples.isEmpty ? Data() : ParakeetWire.pcm(samples[...])) + ParakeetWire.header(.end, count: 0)
            let pcm = HelperMemoryChannel(frames, ended: true), output = HelperMemoryChannel()
            let runner = HelperRunner(driver: FluidAudioDriver(open: { c in await session.open(c); return session }),
                runtimeScope: { "fixture-os" }, validateDirectory: { #expect($0.path == "/owned/fixture") }, parentLost: { Issue.record("normal run lost its parent") })
            #expect(await runner.run(control: control, pcm: pcm, output: output) == 0)
            guard let (hello, helloBytes) = try await ParakeetWire.readFrame(from: output),
                  let (terminal, result) = try await ParakeetWire.readFrame(from: output) else { Issue.record("missing result"); return }
            #expect(hello == .hello); #expect(try ParakeetWire.decode(helloBytes, kind: hello).identity == id)
            let record = try ParakeetWire.decode(result, kind: terminal)
            #expect(record.identity == id); #expect(record.code == .completed)
            #expect(record.text == (mode == .prepareLoad ? "" : "tiny local result"))
            #expect(try await ParakeetWire.readFrame(from: output) == nil)
            #expect(await session.calls == (mode == .prepareLoad ? [] : [samples]))
            #expect(await session.cleaned == 1)
            #expect(await session.configurations == [LocalModelConfiguration(directory: URL(fileURLWithPath: "/owned/fixture"))])
        }
    }
    @Test func cancelCannotReturnBeforeNoncooperativeSessionAndCleanupExit() async throws {
        for expected in [ParakeetWire.Code.completed, .failed, .canceled] {
            let id = identity(), session = HelperSession(), completion = HelperCompletion()
            await session.setHold(outcome: expected)
            let request = ParakeetWire.Record(identity: id, mode: .recognizeBatch, directory: "/owned/fixture", sampleCount: 1)
            let control = HelperMemoryChannel(try ParakeetWire.encode(request, kind: .request))
            let pcm = HelperMemoryChannel(try ParakeetWire.pcm([Float(0.5)][...]) + ParakeetWire.header(.end, count: 0), ended: true)
            let output = HelperMemoryChannel()
            let runner = HelperRunner(driver: .init(open: { _ in session }), runtimeScope: { "fixture-os" }, validateDirectory: { _ in }, parentLost: {})
            let owned = Task { let status = await runner.run(control: control, pcm: pcm, output: output); await completion.finish(); return status }
            while !(await session.entered) { await Task.yield() }
            await control.write(try ParakeetWire.encode(.init(identity: id), kind: .cancel))
            await control.waitForReads(5) // next header read occurs after actual work.cancel()
            #expect(!(await completion.done)); #expect(await session.cleaned == 0)
            await session.release()
            #expect(await owned.value == 0); #expect(await session.cleaned == 1)
            _ = try await ParakeetWire.readFrame(from: output)
            let frame = try #require(await ParakeetWire.readFrame(from: output))
            let terminal = try ParakeetWire.decode(frame.1, kind: frame.0)
            #expect(terminal.code == expected)
            #expect(terminal.text == (expected == .completed ? "tiny local result" : nil))
        }
    }
    @Test func malformedPCMNeverEntersModelBottom() async throws {
        let id = identity(), session = HelperSession()
        let request = ParakeetWire.Record(identity: id, mode: .recognizeBatch, directory: "/owned/fixture", sampleCount: 1)
        let control = HelperMemoryChannel(try ParakeetWire.encode(request, kind: .request))
        // A NaN is rejected, never normalized or decoded as a successful prefix.
        let bad = try ParakeetWire.header(.pcm, count: 4) + Data([0, 0, 0xc0, 0x7f])
        let runner = HelperRunner(driver: .init(open: { c in await session.open(c); return session }), runtimeScope: { "fixture-os" }, validateDirectory: { _ in }, parentLost: {})
        #expect(await runner.run(control: control, pcm: HelperMemoryChannel(bad, ended: true), output: HelperMemoryChannel()) == 0)
        #expect(await session.configurations.isEmpty); #expect(await session.calls.isEmpty)
    }
    @Test func parentEOFIsObservedDuringHeldLoadAndAllModelOwnershipStillJoins() async throws {
        let id = identity(), session = HelperSession(), gate = HelperLoadGate(), completion = HelperCompletion(), lost = HelperLossCounter()
        let request = ParakeetWire.Record(identity: id, mode: .prepareLoad, directory: "/owned/fixture", sampleCount: 0)
        let control = HelperMemoryChannel(try ParakeetWire.encode(request, kind: .request))
        let pcm = HelperMemoryChannel(try ParakeetWire.header(.end, count: 0), ended: true)
        let runner = HelperRunner(driver: .init(open: { c in await gate.wait(); await session.open(c); return session }),
            runtimeScope: { "fixture-os" }, validateDirectory: { _ in }, parentLost: { lost.record() })
        let owned = Task { let status = await runner.run(control: control, pcm: pcm, output: HelperMemoryChannel()); await completion.finish(); return status }
        while !(await gate.entered) { await Task.yield() }
        await control.close()
        while lost.value == 0 { await Task.yield() }
        #expect(!(await completion.done)); #expect(await session.cleaned == 0)
        await gate.release()
        #expect(await owned.value == 0); #expect(await session.cleaned == 1)
        #expect(await session.calls.isEmpty); #expect(lost.value == 1)
    }

}
