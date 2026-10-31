import Foundation
import Darwin
import Dispatch

/// All mutable fields, descriptor operations and callbacks are confined to queue.
/// This narrow IO owner is Sendable; no model/session/framework object crosses it.
final class ParakeetIOHub: @unchecked Sendable {
    let queue = DispatchQueue(label: "parla.parakeet.owned-io-exit")
    private var pipes: [ParakeetPipe] = []
    private var timer: DispatchSourceTimer?
    var onTick: (@Sendable () -> Void)? // queue confined; installed before admission
    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for pipe in self.pipes { pipe.pump() }
            self.onTick?()
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.resume()
    }
    func add(_ pipe: ParakeetPipe) { queue.async { self.pipes.append(pipe) } }
    func remove(_ pipe: ParakeetPipe) {
        pipes.removeAll { $0 === pipe }
        retireIfIdle()
    }
    func retireIfIdle() {
        if pipes.isEmpty && onTick == nil { timer?.cancel(); timer = nil }
    }
    func closeAll() {
        queue.sync {
            for pipe in self.pipes { pipe.closeOnQueue() }
            self.onTick = nil; self.retireIfIdle()
        }
    }
    deinit { timer?.cancel() }
}

/// Exactly one pending IO per channel. Reads and writes are nonblocking, one
/// <=64KiB syscall per tick; control progresses independently of a full PCM pipe.
final class ParakeetPipe: ParakeetChannel, @unchecked Sendable {
    enum Direction { case read, write }
    private let hub: ParakeetIOHub
    private let direction: Direction
    private var fd: Int32?
    private var reader: (Int, CheckedContinuation<Data, Error>)?
    private var writer: (Data, Int, CheckedContinuation<Void, Error>)?
    init(fd: Int32, direction: Direction, hub: ParakeetIOHub) throws {
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw ParakeetWire.Failure.io }
        if direction == .write {
            var disabled: Int32 = 1
            guard fcntl(fd, F_SETNOSIGPIPE, disabled) != -1 else { throw ParakeetWire.Failure.io }
            disabled = 0
        }
        self.fd = fd; self.direction = direction; self.hub = hub
        hub.add(self)
    }
    func read(upTo count: Int) async throws -> Data {
        guard count > 0, count <= ParakeetWire.maximumPCM else { throw ParakeetWire.Failure.bounds }
        return try await withCheckedThrowingContinuation { continuation in
            hub.queue.async {
                guard self.direction == .read, self.reader == nil else { continuation.resume(throwing: ParakeetWire.Failure.order); return }
                guard self.fd != nil else { continuation.resume(returning: Data()); return }
                self.reader = (count, continuation); self.pump()
            }
        }
    }
    func write(_ data: Data) async throws {
        guard data.count <= ParakeetWire.maximumRecord + 8 else { throw ParakeetWire.Failure.bounds }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            hub.queue.async {
                guard self.direction == .write, self.writer == nil, self.fd != nil else { continuation.resume(throwing: ParakeetWire.Failure.io); return }
                self.writer = (data, 0, continuation); self.pump()
            }
        }
    }
    func close() async {
        await withCheckedContinuation { continuation in
            hub.queue.async { self.closeOnQueue(); continuation.resume() }
        }
    }
    func join() async {
        await withCheckedContinuation { continuation in hub.queue.async { continuation.resume() } }
    }
    fileprivate func closeOnQueue() {
        if let fd { Darwin.close(fd); self.fd = nil }
        if let reader { self.reader = nil; reader.1.resume(throwing: ParakeetWire.Failure.io) }
        if let writer { self.writer = nil; writer.2.resume(throwing: ParakeetWire.Failure.io) }
        hub.remove(self)
    }
    fileprivate func pump() {
        guard let fd else { return }
        if let (count, continuation) = reader {
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            if n >= 0 { reader = nil; continuation.resume(returning: data.prefix(n)) }
            else if errno != EAGAIN && errno != EINTR { reader = nil; continuation.resume(throwing: ParakeetWire.Failure.io) }
        }
        if let (data, offset, continuation) = writer {
            if offset == data.count { writer = nil; continuation.resume(); return }
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), min(ParakeetWire.maximumPCM, data.count - offset)) }
            if n >= 0 { writer = (data, offset + n, continuation) }
            else if errno != EAGAIN && errno != EINTR { writer = nil; continuation.resume(throwing: ParakeetWire.Failure.io) }
        }
    }
}

public enum ParakeetExecutable {
    public static func run() async -> Int32 {
        let hub = ParakeetIOHub()
        do {
            let control = try ParakeetPipe(fd: STDIN_FILENO, direction: .read, hub: hub)
            let pcm = try ParakeetPipe(fd: 3, direction: .read, hub: hub)
            let output = try ParakeetPipe(fd: STDOUT_FILENO, direction: .write, hub: hub)
            let runner = HelperRunner(validateDirectory: { try ParakeetModelManifest.verify(directory: $0) }, parentLost: { _exit(1) })
            return await runner.run(control: control, pcm: pcm, output: output)
        } catch { return 1 }
    }
}
