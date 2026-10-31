import Foundation

private actor HelperRunState {
    var complete = false
    var revoked = false
    private var receiverStarted = false
    private var admission: CheckedContinuation<Void, Never>?
    func receiverReady() { receiverStarted = true; admission?.resume(); admission = nil }
    func waitForReceiver() async {
        if !receiverStarted { await withCheckedContinuation { admission = $0 } }
    }
    func revoke() { revoked = true }
    func finish() { complete = true }
}

/// Executable runner, tested below its actual wire/model drivers. Every task and
/// channel is retained and joined. EOF's native bottom exits the entire helper;
/// it is independent of a synchronous model load on the work task.
public struct HelperRunner: Sendable {
    public let driver: FluidAudioDriver
    public var runtimeScope: @Sendable () -> String
    public var validateDirectory: @Sendable (URL) async throws -> Void
    public var parentLost: @Sendable () -> Void
    public init(driver: FluidAudioDriver = FluidAudioDriver(),
                runtimeScope: @escaping @Sendable () -> String = { ProcessInfo.processInfo.operatingSystemVersionString },
                validateDirectory: @escaping @Sendable (URL) async throws -> Void,
                parentLost: @escaping @Sendable () -> Void) {
        self.driver = driver; self.runtimeScope = runtimeScope; self.validateDirectory = validateDirectory; self.parentLost = parentLost
    }
    public func run(control: any ParakeetChannel, pcm: any ParakeetChannel, output: any ParakeetChannel) async -> Int32 {
        let state = HelperRunState()
        do {
            guard let (kind, payload) = try await ParakeetWire.readFrame(from: control), kind == .request else { throw ParakeetWire.Failure.order }
            let request = try ParakeetWire.decode(payload, kind: kind)
            guard request.identity.osScope == runtimeScope() else { throw ParakeetWire.Failure.identity }
            try await output.write(ParakeetWire.encode(.init(identity: request.identity), kind: .hello))
            // Owned, non-detached task: joined below on every path after creation.
            let work = Task { () -> ParakeetWire.Record in
                do {
                    await state.waitForReceiver()
                    let samples = try await readPCM(pcm, request: request)
                    try Task.checkCancellation()
                    guard !(await state.revoked) else { throw CancellationError() }
                    let directory = URL(fileURLWithPath: request.directory!)
                    try await validateDirectory(directory)
                    try Task.checkCancellation()
                    let text = try await driver.run(directory: directory,
                        samples: request.mode == .recognizeBatch ? samples : nil, filter: request.filter)
                    // Preserve the native outcome; the parent separately revokes delivery.
                    guard text.utf8.count <= ParakeetWire.maximumRecord else { throw ParakeetWire.Failure.bounds }
                    return .init(identity: request.identity, code: .completed, text: text)
                } catch {
                    return .init(identity: request.identity, code: error is CancellationError ? .canceled : .failed)
                }
            }
            async let receiver: Void = receive(control, identity: request.identity, state: state, cancel: { work.cancel() })
            let terminal = await work.value // native return + cleanup, never merely a cancel ack
            await state.finish()
            await control.close()
            await receiver
            var status: Int32 = 0
            do { try await output.write(ParakeetWire.encode(terminal, kind: .terminal)) }
            catch { status = 1 }
            await pcm.close(); await output.close()
            await control.join(); await pcm.join(); await output.join()
            return status
        } catch {
            await control.close(); await pcm.close(); await output.close()
            await control.join(); await pcm.join(); await output.join()
            return 1
        }
    }
    private func receive(_ control: any ParakeetChannel, identity: ParakeetWire.Identity,
                         state: HelperRunState, cancel: @Sendable () -> Void) async {
        await state.receiverReady()
        do {
            while let (kind, bytes) = try await ParakeetWire.readFrame(from: control) {
                guard kind == .cancel || kind == .close,
                      try ParakeetWire.decode(bytes, kind: kind).identity == identity else { throw ParakeetWire.Failure.identity }
                await state.revoke(); cancel()
            }
        } catch { /* finite protocol failure has the same ownership treatment as EOF */ }
        if !(await state.complete) {
            await state.revoke(); cancel()
            parentLost() // production _exit: no task cancellation is mistaken for exit
        }
    }
    private func readPCM(_ channel: any ParakeetChannel, request: ParakeetWire.Record) async throws -> [Float] {
        guard let expected = request.sampleCount else { throw ParakeetWire.Failure.malformed }
        var samples: [Float] = []
        while let (kind, bytes) = try await ParakeetWire.readFrame(from: channel) {
            if kind == .end {
                guard samples.count == expected, try await channel.read(upTo: 1).isEmpty else { throw ParakeetWire.Failure.order }
                return samples
            }
            guard kind == .pcm else { throw ParakeetWire.Failure.order }
            let frame = try ParakeetWire.samples(bytes)
            guard frame.count <= expected - samples.count else { throw ParakeetWire.Failure.bounds }
            samples.append(contentsOf: frame)
        }
        throw ParakeetWire.Failure.malformed
    }
}
