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


public protocol ParakeetChild: Sendable {
    var control: any ParakeetChannel { get }
    var pcm: any ParakeetChannel { get }
    var output: any ParakeetChannel { get }
    var errors: any ParakeetChannel { get }
    func requestCancellation() async
    func actualExit() async -> Int32
    func forcedTerminationRequested() async -> Bool
}
public extension ParakeetChild { func forcedTerminationRequested() async -> Bool { false } }

/// Called only on the native owner's serialized queue; tests replace precisely
/// wait/signal bottoms. Polling retires signal authority before wait can reap.
final class ParakeetExitArbiter {
    enum Observation: Equatable { case running, interrupted, reaped(Int32), unknown }
    private let pid: Int32
    private let wait: (Int32) -> Observation
    private let signal: (Int32, Int32) -> Void
    private var live = true
    private var polling = false
    private var grace: UInt64?
    private var killAt: UInt64?
    private var termSent = false
    private var killSent = false
    private(set) var uncertain = false
    private(set) var status: Int32?
    var forcedTerminationRequested: Bool { termSent || killSent }
    init(pid: Int32, wait: @escaping (Int32) -> Observation, signal: @escaping (Int32, Int32) -> Void) {
        self.pid = pid; self.wait = wait; self.signal = signal
    }
    func cancel(now: UInt64) {
        guard live, !polling, !uncertain, grace == nil else { return }
        grace = deadline(now)
    }
    private func deadline(_ now: UInt64) -> UInt64 {
        let value = now.addingReportingOverflow(2_000_000_000)
        return value.overflow ? UInt64.max : value.partialValue
    }
    func tick(now: UInt64) {
        guard live, !polling, !uncertain else { return }
        polling = true // no signal authority during a syscall that can reap/reuse
        var observation: Observation
        repeat { observation = wait(pid) } while observation == .interrupted
        switch observation {
        case .reaped(let value):
            live = false; grace = nil; killAt = nil; status = value
            return
        case .unknown:
            uncertain = true; grace = nil; killAt = nil
            return // actual exit is unestablished; keep admission/ownership closed
        case .running: polling = false
        case .interrupted: return
        }
        if let grace, now >= grace, !termSent {
            termSent = true; killAt = deadline(now); signal(pid, SIGTERM)
        }
        if let killAt, now >= killAt, !killSent {
            killSent = true; self.killAt = nil; signal(pid, SIGKILL)
        }
    }
}

/// One owned child. The same queue serializes nonblocking IO, waitpid and all
/// signals. A PID is never looked up/persisted and no callback outlives retirement.
final class ParakeetPOSIXChild: ParakeetChild, @unchecked Sendable {
    let control: any ParakeetChannel
    let pcm: any ParakeetChannel
    let output: any ParakeetChannel
    let errors: any ParakeetChannel
    private let hub: ParakeetIOHub
    private let arbiter: ParakeetExitArbiter
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private init(pid: pid_t, hub: ParakeetIOHub, control: ParakeetPipe, pcm: ParakeetPipe, output: ParakeetPipe, errors: ParakeetPipe) {
        arbiter = ParakeetExitArbiter(pid: pid, wait: { pid in
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return .reaped(status) }
            if result == 0 { return .running }
            return errno == EINTR ? .interrupted : .unknown
        }, signal: { pid, value in _ = kill(pid, value) })
        self.hub = hub; self.control = control; self.pcm = pcm; self.output = output; self.errors = errors
        hub.queue.async { hub.onTick = { self.observe() } }
    }
    static func launch(_ product: ParakeetTrustedProduct) throws -> any ParakeetChild {
        let hub = ParakeetIOHub()
        var fds: [Int32] = []
        var owned = true
        defer { if owned { hub.closeAll(); for fd in fds where fd >= 0 { Darwin.close(fd) } } }
        for _ in 0..<4 {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw ParakeetWire.Failure.io }
            fds += pair
        }
        // Move every original pipe descriptor above the fixed child slots before
        // any dup2: otherwise FD3 aliasing can close another channel's source.
        for i in fds.indices {
            let moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 4)
            guard moved >= 0 else { throw ParakeetWire.Failure.io }
            Darwin.close(fds[i]); fds[i] = moved
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ParakeetWire.Failure.io }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ParakeetWire.Failure.io }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw ParakeetWire.Failure.io }
        for (source, destination) in [(fds[0], Int32(0)), (fds[3], Int32(1)), (fds[5], Int32(2)), (fds[6], Int32(3))] {
            guard posix_spawn_file_actions_adddup2(&actions, source, destination) == 0 else { throw ParakeetWire.Failure.io }
        }
        for fd in fds { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw ParakeetWire.Failure.io } }
        // Fixed app-owned absolute code path; no shell, PATH, user argv or inherited
        // provider/credential/proxy environment. The SDK local bridge enforces offline.
        let executable = strdup(product.executable.path)!
        defer { free(executable) }
        var argv: [UnsafeMutablePointer<CChar>?] = [executable, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        // Complete all potentially throwing descriptor configuration before spawn.
        let control = try ParakeetPipe(fd: fds[1], direction: .write, hub: hub)
        fds[1] = -1
        let output = try ParakeetPipe(fd: fds[2], direction: .read, hub: hub)
        fds[2] = -1
        let errors = try ParakeetPipe(fd: fds[4], direction: .read, hub: hub)
        fds[4] = -1
        let pcm = try ParakeetPipe(fd: fds[7], direction: .write, hub: hub)
        fds[7] = -1
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, &argv, &environment)
        guard status == 0 else { throw ParakeetWire.Failure.io }
        for i in [0, 3, 5, 6] { Darwin.close(fds[i]); fds[i] = -1 }
        owned = false
        return ParakeetPOSIXChild(pid: child, hub: hub, control: control, pcm: pcm, output: output, errors: errors)
    }
    func requestCancellation() async {
        await withCheckedContinuation { continuation in
            hub.queue.async {
                self.arbiter.cancel(now: DispatchTime.now().uptimeNanoseconds)
                continuation.resume()
            }
        }
    }
    func actualExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            hub.queue.async {
                if let status = self.exitStatus { continuation.resume(returning: status) }
                else { self.waiters.append(continuation) }
            }
        }
    }
    func forcedTerminationRequested() async -> Bool {
        await withCheckedContinuation { continuation in
            hub.queue.async { continuation.resume(returning: self.arbiter.forcedTerminationRequested) }
        }
    }
    private func observe() {
        arbiter.tick(now: DispatchTime.now().uptimeNanoseconds)
        guard let status = arbiter.status, exitStatus == nil else { return }
        hub.onTick = nil; hub.retireIfIdle()
        exitStatus = status
        let all = waiters; waiters = []
        for waiter in all { waiter.resume(returning: status) }
    }
}
