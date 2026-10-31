import Foundation
import Dispatch

public struct ParakeetClock: Sendable {
    public var now: @Sendable () -> UInt64
    public var tick: @Sendable () async -> Void
    public init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                tick: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 10_000_000) }) {
        self.now = now; self.tick = tick
    }
}
/// Synchronous task-cancellation mailbox only; never holds a native object/PCM.
final class ParakeetRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func revoke() { lock.lock(); value = true; lock.unlock() }
    var revoked: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private actor ParakeetWorkerState {
    var hello = false
    var input = false
    var fault = false
    var expired = false
    var finished = false
    func accepted() { hello = true }
    func written() { input = true }
    func fail() { fault = true }
    func expire() { expired = true }
    func finish() { finished = true }
}
public struct ParakeetWorkerResult: Sendable {
    public let terminal: ParakeetWire.Record?
    public let deliveryRevoked: Bool
    public let expired: Bool
    public let cleanExit: Bool
    public let forcedTerminationRequested: Bool
}

public struct ParakeetWorker {
    public var launch: (ParakeetTrustedProduct) throws -> any ParakeetChild
    public var clock: ParakeetClock
    public init(launch: @escaping (ParakeetTrustedProduct) throws -> any ParakeetChild = ParakeetWorker.nativeLaunch,
                clock: ParakeetClock = ParakeetClock()) { self.launch = launch; self.clock = clock }
    public static func nativeLaunch(_ product: ParakeetTrustedProduct) throws -> any ParakeetChild { try ParakeetPOSIXChild.launch(product) }
    public func run(product: ParakeetTrustedProduct, request: ParakeetWire.Record, samples: [Float],
                    shouldAbort: (() -> Bool)? = nil) async -> ParakeetWorkerResult {
        let admitted = clock.now()
        let state = ParakeetWorkerState(), revoked = ParakeetRevocation()
        do {
            try request.validate(.request)
            guard request.sampleCount == samples.count, samples.count <= ParakeetWire.maximumSamples,
                  samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
                  request.identity.helperBuild == product.identity.helperSHA256 else { throw ParakeetWire.Failure.identity }
            guard shouldAbort?() != true, !Task.isCancelled else { throw CancellationError() }
            let child = try launch(product)
            return await withTaskCancellationHandler(operation: {
                // Owned tasks have a single join path below, including all errors.
                let watchdog = Task {
                    var sentCancel = false
                    while !(await state.finished) {
                        let now = clock.now(), hello = await state.hello
                        let lifetime: UInt64 = request.mode == .prepareLoad ? 180_000_000_000 : 120_000_000_000
                        if now < admitted || now - admitted >= lifetime || !hello && now - admitted >= 5_000_000_000 {
                            await state.expire(); revoked.revoke()
                        }
                        if shouldAbort?() == true { revoked.revoke() }
                        let fault = await state.fault
                        if revoked.revoked || fault, !sentCancel {
                            sentCancel = true
                            // Start owned escalation before a possibly blocked control write.
                            await child.requestCancellation()
                            try? await child.control.write(ParakeetWire.encode(.init(identity: request.identity), kind: .cancel))
                        }
                        await clock.tick()
                    }
                }
                let writer = Task {
                    do {
                        try await child.control.write(ParakeetWire.encode(request, kind: .request))
                        for offset in stride(from: 0, to: samples.count, by: ParakeetWire.maximumPCM / 4) {
                            guard !revoked.revoked else { throw CancellationError() }
                            let end = min(samples.count, offset + ParakeetWire.maximumPCM / 4)
                            try await child.pcm.write(ParakeetWire.pcm(samples[offset..<end]))
                        }
                        try await child.pcm.write(ParakeetWire.header(.end, count: 0))
                        await child.pcm.close(); await state.written()
                    } catch { await state.fail(); await child.pcm.close() }
                }
                let reader = Task { () -> ParakeetWire.Record? in
                    do {
                        guard let (kind, bytes) = try await ParakeetWire.readFrame(from: child.output), kind == .hello,
                              try ParakeetWire.decode(bytes, kind: kind).identity == request.identity else { throw ParakeetWire.Failure.identity }
                        let helloTime = clock.now()
                        guard helloTime >= admitted, helloTime - admitted < 5_000_000_000 else {
                            await state.expire(); revoked.revoke(); throw ParakeetWire.Failure.deadline
                        }
                        await state.accepted()
                        guard let (terminalKind, payload) = try await ParakeetWire.readFrame(from: child.output), terminalKind == .terminal else { throw ParakeetWire.Failure.order }
                        let terminal = try ParakeetWire.decode(payload, kind: terminalKind)
                        guard terminal.identity == request.identity,
                              request.mode != .prepareLoad || terminal.code != .completed || terminal.text == "",
                              try await ParakeetWire.readFrame(from: child.output) == nil else { throw ParakeetWire.Failure.identity }
                        return terminal
                    } catch { await state.fail(); await child.output.close(); return nil }
                }
                let stderr = Task {
                    do { while !(try await child.errors.read(upTo: ParakeetWire.maximumPCM)).isEmpty {} }
                    catch { await state.fail() }
                    // Deliberately discard every byte; never forward SDK free-form logs.
                }
                let status = await child.actualExit()
                let forced = await child.forcedTerminationRequested()
                await child.control.close(); await child.pcm.close()
                await writer.value
                let terminal = await reader.value
                await stderr.value
                await child.output.close(); await child.errors.close()
                await child.control.join(); await child.pcm.join(); await child.output.join(); await child.errors.join()
                let now = clock.now()
                let lifetime: UInt64 = request.mode == .prepareLoad ? 180_000_000_000 : 120_000_000_000
                if now < admitted || now - admitted >= lifetime { await state.expire(); revoked.revoke() }
                await state.finish(); await watchdog.value
                let input = await state.input, fault = await state.fault, expired = await state.expired
                return ParakeetWorkerResult(terminal: input && !fault && status == 0 && !forced ? terminal : nil,
                    deliveryRevoked: revoked.revoked || shouldAbort?() == true, expired: expired, cleanExit: status == 0 && !forced, forcedTerminationRequested: forced)
            }, onCancel: { revoked.revoke() })
        } catch {
            return .init(terminal: nil, deliveryRevoked: Task.isCancelled || shouldAbort?() == true, expired: false, cleanExit: false, forcedTerminationRequested: false)
        }
    }
}
