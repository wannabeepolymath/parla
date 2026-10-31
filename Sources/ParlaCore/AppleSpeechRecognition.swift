import Foundation

public struct AppleSpeechTime: Equatable, Sendable {
    public let value: Int64
    public let scale: Int32
    public init(_ value: Int64, _ scale: Int32) { self.value = value; self.scale = scale }
    public func compared(to other: Self) throws -> ComparisonResult {
        guard value >= 0, scale > 0, other.value >= 0, other.scale > 0 else { throw AppleSpeechRefusal.results }
        let a = value.multipliedReportingOverflow(by: Int64(other.scale))
        let b = other.value.multipliedReportingOverflow(by: Int64(scale))
        guard !a.overflow, !b.overflow else { throw AppleSpeechRefusal.results }
        return a.partialValue == b.partialValue ? .orderedSame : a.partialValue < b.partialValue ? .orderedAscending : .orderedDescending
    }
}
public struct AppleSpeechEvent: Equatable, Sendable {
    public let text: String
    public let start: AppleSpeechTime, end: AppleSpeechTime, finalization: AppleSpeechTime
    public let isFinal: Bool
    public init(text: String, start: AppleSpeechTime, end: AppleSpeechTime, finalization: AppleSpeechTime, isFinal: Bool = true) {
        self.text = text; self.start = start; self.end = end; self.finalization = finalization; self.isFinal = isFinal
    }
}
public struct AppleSpeechFormat: Equatable, Sendable {
    public let rate: Int32, channels: Int, bytesPerFrame: Int
    public init(rate: Int32, channels: Int, bytesPerFrame: Int) { self.rate = rate; self.channels = channels; self.bytesPerFrame = bytesPerFrame }
    public func validate() throws {
        guard (8_000...192_000).contains(rate), (1...8).contains(channels),
              (channels...32).contains(bytesPerFrame), bytesPerFrame <= 1_048_576 else { throw AppleSpeechRefusal.format }
    }
}
/// Native payloads are confined to the conditional bottom. At most one pulled output is pending here.
public final class AppleSpeechBuffer {
    public let frames: Int
    public let bytes: Int
    public let payload: AnyObject
    public init(frames: Int, bytes: Int, payload: AnyObject) { self.frames = frames; self.bytes = bytes; self.payload = payload }
}
public protocol AppleSpeechConverter: AnyObject {
    var format: AppleSpeechFormat { get }
    var consumedSourceSamples: Int { get }
    var sourcePrimingUncertainty: Int { get }
    var ended: Bool { get }
    func next() throws -> AppleSpeechBuffer?
}
public extension AppleSpeechConverter { var sourcePrimingUncertainty: Int { 0 } }
public final class AppleSpeechInput {
    private let converter: AppleSpeechConverter
    private let abort: () -> Bool
    private(set) public var frames: Int64 = 0
    private(set) public var ended = false
    private let expected: Int
    public var format: AppleSpeechFormat { converter.format }
    public init(converter: AppleSpeechConverter, expected: Int, abort: @escaping () -> Bool) throws {
        try converter.format.validate(); self.converter = converter; self.expected = expected; self.abort = abort
    }
    public func next() throws -> (AppleSpeechBuffer, AppleSpeechTime)? {
        guard !ended else { return nil }
        guard !abort() else { throw CancellationError() }
        guard let buffer = try converter.next() else {
            ended = true
            guard converter.ended, converter.consumedSourceSamples == expected else { throw AppleSpeechRefusal.input }
            return nil
        }
        let bytes = buffer.frames.multipliedReportingOverflow(by: format.bytesPerFrame)
        let total = frames.addingReportingOverflow(Int64(buffer.frames))
        guard buffer.frames > 0, !bytes.overflow, bytes.partialValue == buffer.bytes,
              buffer.bytes <= 1_048_576, !total.overflow,
              total.partialValue <= Int64(format.rate) * 602 else { throw AppleSpeechRefusal.conversion }
        let time = AppleSpeechTime(frames, format.rate); frames = total.partialValue
        return (buffer, time)
    }
    public func validateConsumed() throws {
        guard ended, converter.ended, converter.consumedSourceSamples == expected,
              expected == 0 || frames > 0, (0...32_000).contains(converter.sourcePrimingUncertainty) else { throw AppleSpeechRefusal.input }
        // Rational accounting, allowing declared converter priming plus one sample of rounding.
        let observed = frames.multipliedReportingOverflow(by: 16_000)
        let target = Int64(expected).multipliedReportingOverflow(by: Int64(format.rate))
        let tolerance = Int64(converter.sourcePrimingUncertainty + 1) * Int64(format.rate) + 16_000
        guard !observed.overflow, !target.overflow,
              abs(observed.partialValue - target.partialValue) <= tolerance else { throw AppleSpeechRefusal.input }
    }
}
public protocol AppleSpeechSession: AnyObject {
    func converter(samples: [Float]) async throws -> AppleSpeechConverter
    func collect(ready: @escaping () -> Void, _ emit: @escaping (AppleSpeechEvent) throws -> Void) async throws
    func analyze(_ input: AppleSpeechInput) async throws -> AppleSpeechTime?
    func finalize(through: AppleSpeechTime) async throws
    func cancelAndFinish() async
}
public struct AppleSpeechBottom {
    public var available: () throws -> Void
    public var session: (String) throws -> AppleSpeechSession
    public init(available: @escaping () throws -> Void, session: @escaping (String) throws -> AppleSpeechSession) {
        self.available = available; self.session = session
    }
}
/// Owns the single async cancellation call. Signal is synchronous, retirement awaits that exact task.
public final class AppleSpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var revokedValue = false
    private var cancelTask: Task<Void, Never>?
    private let cancel: () async -> Void
    public init(cancel: @escaping () async -> Void) { self.cancel = cancel }
    public var revoked: Bool { lock.withLock { revokedValue } }
    public func revoke() {
        lock.withLock {
            revokedValue = true
            if cancelTask == nil { cancelTask = Task { await cancel() } }
        }
    }
    public func join() async { let task = lock.withLock { cancelTask }; await task?.value }
}
private final class AppleSpeechCollectorStart {
    private let lock = NSLock()
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in started = true; let c = waiter; waiter = nil; return c }
        continuation?.resume()
    }
    func wait() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> Bool in if started { return true }; waiter = c; return false }
            if ready { c.resume() }
        }
    }
}
private final class AppleSpeechResults {
    private let lock = NSLock()
    private var events: [AppleSpeechEvent] = []
    private var count = 0, bytes = 0
    func append(_ event: AppleSpeechEvent) throws {
        try lock.withLock {
            count += 1
            guard count <= 10_000, event.isFinal, event.text.utf8.count <= 1_048_576,
                  try event.start.compared(to: event.end) != .orderedDescending,
                  try event.end.compared(to: event.finalization) != .orderedDescending else { throw AppleSpeechRefusal.results }
            if events.contains(event) { return }
            if let previous = events.last {
                guard try previous.end.compared(to: event.start) != .orderedDescending,
                      try previous.finalization.compared(to: event.finalization) != .orderedDescending else { throw AppleSpeechRefusal.results }
            }
            let total = bytes.addingReportingOverflow(event.text.utf8.count)
            guard !total.overflow, total.partialValue <= 1_048_576 else { throw AppleSpeechRefusal.results }
            bytes = total.partialValue; events.append(event)
        }
    }
    func completed(through end: AppleSpeechTime) throws -> String {
        try lock.withLock {
            for event in events {
                guard try event.end.compared(to: end) != .orderedDescending,
                      try event.finalization.compared(to: end) != .orderedDescending else { throw AppleSpeechRefusal.results }
            }
            return events.map(\.text).joined()
        }
    }
}
/// The production Apple client. Fakes replace only the native bottom and installed lease port.
public final class AppleSpeechRecognition: RecognitionClient {
    public let capabilities = RecognitionCapabilities.appleSpeech
    public let locale: String
    private let bottom: AppleSpeechBottom, clock: AppleSpeechClock
    private let installedUse: (String) async throws -> AppleSpeechLease
    private let preparedLease: AppleSpeechLease?
    private let lock = NSLock()
    private var revokedValue = false, running = false
    public var deliveryRevoked: Bool { lock.withLock { revokedValue } }
    public init(locale: String, bottom: AppleSpeechBottom, clock: AppleSpeechClock = AppleSpeechClock(),
                operation: PendingOperation? = nil, preparedLease: AppleSpeechLease? = nil, installedUse: @escaping (String) async throws -> AppleSpeechLease) {
        self.locale = locale; self.bottom = bottom; self.clock = clock; self.preparedLease = preparedLease; self.installedUse = installedUse
    }
    public func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        guard initialPrompt == nil else { return .failed(.unsupportedCapability) }
        guard samples.count <= 9_600_000, samples.allSatisfy(\.isFinite) else { return .failed(.appleSpeech) }
        guard lock.withLock({ if running { return false }; running = true; revokedValue = false; return true }) else { return .failed(.clientUnavailable) }
        defer { lock.withLock { running = false } }
        if shouldAbort?() == true || Task.isCancelled { return .canceled }
        let lease: AppleSpeechLease
        do { try bottom.available(); lease = try await installedUse(locale) } catch { return .failed(.preparationUnavailable) }
        // Actual admitted recognition begins here. Lease survives all workers and cancellation.
        let operation = lease.operation
        let admitted = clock.now(), deadline = admitted + 60
        let session: AppleSpeechSession
        do { session = try bottom.session(locale) } catch { lease.release(); return .failed(.appleSpeech) }
        let cancel = AppleSpeechCancellation { await session.cancelAndFinish() }
        let revoke = { [self] in
            lock.withLock { revokedValue = true }; operation.revoke(); cancel.revoke()
        }
        let observer = operation.observePreparationRevocation { [self] in lock.withLock { revokedValue = true }; cancel.revoke() }
        let watchdog = Task { [clock] in
            do {
                try await clock.wait(max(0, deadline - clock.now()))
                if !Task.isCancelled, clock.now() >= deadline { revoke() }
            } catch { /* owned cancellation retires this watchdog */ }
        }
        let results = AppleSpeechResults(), start = AppleSpeechCollectorStart()
        // Collector starts before format preparation/input. A failing collector cancels blocked analysis.
        let collector = Task { () -> Result<Void, Error> in
            do { try await session.collect(ready: { start.signal() }) { try results.append($0) }; return .success(()) }
            catch { start.signal(); cancel.revoke(); return .failure(error) }
        }
        let native: RecognitionNativeOutcome = await withTaskCancellationHandler(operation: {
            do {
                await start.wait()
                let converter = try await session.converter(samples: samples)
                let input = try AppleSpeechInput(converter: converter, expected: samples.count, abort: {
                    cancel.revoked || shouldAbort?() == true || self.clock.now() >= deadline
                })
                let last = try await session.analyze(input)
                try input.validateConsumed()
                if clock.now() >= deadline || shouldAbort?() == true { revoke() }
                // Do not authorize a partial prefix after an early input end/cancellation.
                if cancel.revoked { throw CancellationError() }
                if let last {
                    guard try last.compared(to: AppleSpeechTime(input.frames, input.format.rate)) != .orderedDescending else { throw AppleSpeechRefusal.input }
                    try await session.finalize(through: last)
                } else if !samples.isEmpty { throw AppleSpeechRefusal.input }
                else { cancel.revoke(); await cancel.join() }
                try await collector.value.get()
                let text = try results.completed(through: AppleSpeechTime(input.frames, input.format.rate))
                return .completed(.init(text: text, requestedLocale: locale, resolvedLocale: locale))
            } catch {
                cancel.revoke(); await cancel.join(); _ = await collector.value
                return .failed(error is CancellationError ? .clientUnavailable : .appleSpeech)
            }
        }, onCancel: { revoke() })
        if clock.now() >= deadline || shouldAbort?() == true || Task.isCancelled { revoke() }
        watchdog.cancel(); await watchdog.value
        await cancel.join(); _ = await collector.value
        operation.removePreparationRevocation(observer)
        lease.release()
        return native
    }
    public func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        let result = await recognize(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
        return deliveryRevoked ? nil : result.text
    }
}
