import Foundation
import CryptoKit
import Darwin
import ParlaCore

/// Synchronous cancellation/publication authority. The short commit and revocation
/// compete under the same lock; a canceled task never abandons its disk worker.
final class ParakeetActionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    let operation: PendingOperation
    let admitted: UInt64, duration: UInt64
    let clock: ParakeetClock
    init(operation: PendingOperation, seconds: UInt64, clock: ParakeetClock) {
        self.operation = operation; self.clock = clock; admitted = clock.now(); duration = seconds * 1_000_000_000
    }
    var expired: Bool { let now = clock.now(); return now < admitted || now - admitted >= duration }
    var current: Bool { lock.withLock { !revoked && !operation.shouldAbort && !expired } }
    func revoke() { lock.withLock { revoked = true } }
    func check() throws {
        guard current else { throw expired ? ParakeetInstallationRefusal.deadline : .revoked }
    }
    func publish<T>(_ work: () throws -> T) throws -> T {
        try lock.withLock {
            guard !revoked, !operation.shouldAbort, !expired else { throw expired ? ParakeetInstallationRefusal.deadline : .revoked }
            return try work()
        }
    }
}

/// Pins are counted synchronously, including deinit. Notification scheduling is
/// never evidence of zero uses. A pin cannot be force-released by shutdown.
final class ParakeetInstallationOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var writer = false, closed = false
    private var uses: [UUID: Use] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    final class Use: @unchecked Sendable {
        let id = UUID(), operation: PendingOperation
        private let lock = NSLock()
        private var revoked = false
        init(_ operation: PendingOperation) { self.operation = operation }
        var current: Bool { lock.withLock { !revoked && !operation.shouldAbort } }
        func revoke() { lock.withLock { revoked = true }; operation.requestAbort() }
    }
    var count: Int { lock.withLock { uses.count } }
    var hasWriter: Bool { lock.withLock { writer } }
    func acquireWriter() throws {
        try lock.withLock {
            guard !closed else { throw ParakeetInstallationRefusal.closed }
            guard !writer, uses.isEmpty else { throw ParakeetInstallationRefusal.protectedInstallation }
            writer = true
        }
    }
    func releaseWriter() { lock.withLock { writer = false } }
    func pin(_ operation: PendingOperation) throws -> Use {
        try lock.withLock {
            guard !closed else { throw ParakeetInstallationRefusal.closed }
            guard !writer else { throw ParakeetInstallationRefusal.busy }
            let use = Use(operation); uses[use.id] = use; return use
        }
    }
    func release(_ use: Use) {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            uses.removeValue(forKey: use.id)
            guard uses.isEmpty else { return [] }
            let pending = waiters; waiters = []; return pending
        }
        pending.forEach { $0.resume() }
    }
    func close() {
        let registered = lock.withLock { closed = true; return Array(uses.values) }
        registered.forEach { $0.revoke() }
    }
    func reopen() { lock.withLock { closed = false } }
    func joinUses() async {
        await withCheckedContinuation { continuation in
            let empty = lock.withLock { if uses.isEmpty { return true }; waiters.append(continuation); return false }
            if empty { continuation.resume() }
        }
    }
}

struct ParakeetFileObservation: Codable, Equatable, Sendable {
    let device: Int32, inode: UInt64, bytes: Int64, modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; bytes = s.st_size
        modified = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
    }
}
struct ParakeetInstallationRecord: Codable, Equatable, Sendable {
    enum Stage: String, Codable { case absent, installing, publishing, installed, preparing, ready, deleting }
    var schema = 1
    let owner: UUID
    let device: Int32
    let inode: UInt64
    let release: String
    var generation: UUID
    var stage: Stage
    var completed: [String] = []
    var current: String?
    var observations: [String: ParakeetFileObservation] = [:]
    var prepared: ParakeetPreparedScope?
}
struct ParakeetStoredInstallation: Sendable {
    let record: ParakeetInstallationRecord?
    let directory: URL
    var installed: Bool { record.map { [.installed, .preparing, .ready].contains($0.stage) } ?? false }
}

/// Only this actor touches its private namespace. No helpers or receipts occur
/// inside source/candidate, whose exact membership is derived from the descriptor.
actor ParakeetInstallationStorage {
    enum Boundary: Equatable { case writerExited(String), hashing(String), checkpoint, commit, receipt, prepareIntent, deleting }
    typealias Hook = (Boundary) async throws -> Void
    let root: URL
    private let transport: any CatalogDownloadTransport
    private let hook: Hook
    private var fd: Int32 = -1
    private var identity: ParakeetFileObservation?
    init(root: URL, transport: any CatalogDownloadTransport = CatalogURLSessionTransport(), hook: @escaping Hook = { _ in }) {
        self.root = root; self.transport = transport; self.hook = hook
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func directory(_ path: String) throws -> Int32 {
        var cursor = dup(fd)
        guard cursor >= 0 else { throw ParakeetInstallationRefusal.storage }
        do {
            for part in path.split(separator: "/") {
                guard part != ".", part != ".." else { throw ParakeetInstallationRefusal.storage }
                let next = openat(cursor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ParakeetInstallationRefusal.storage }
                Darwin.close(cursor); cursor = next; try owned(cursor, directory: true)
            }
            return cursor
        } catch { Darwin.close(cursor); throw error }
    }
    private func owned(_ descriptor: Int32, directory: Bool) throws {
        var s = stat()
        guard fstat(descriptor, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o077 == 0,
              identity.map({ $0.device == s.st_dev }) ?? true,
              s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || s.st_nlink == 1 else {
            throw ParakeetInstallationRefusal.storage
        }
    }
    private func openRoot(create: Bool) throws -> Bool {
        if fd >= 0 { try validateRoot(); return true }
        guard root.isFileURL, root.path.hasPrefix("/"), root.path == root.standardizedFileURL.path else { throw ParakeetInstallationRefusal.storage }
        let components = root.path.split(separator: "/")
        guard let last = components.last, components.count > 1 else { throw ParakeetInstallationRefusal.storage }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ParakeetInstallationRefusal.storage }
        defer { Darwin.close(parent) }
        for part in components.dropLast() {
            guard part != ".", part != ".." else { throw ParakeetInstallationRefusal.storage }
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ParakeetInstallationRefusal.storage }
            Darwin.close(parent); parent = next
        }
        if create, mkdirat(parent, String(last), 0o700) != 0, errno != EEXIST { throw ParakeetInstallationRefusal.storage }
        fd = openat(parent, String(last), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, !create { return false }
        guard fd >= 0 else { throw ParakeetInstallationRefusal.storage }
        try owned(fd, directory: true)
        var s = stat(); guard fstat(fd, &s) == 0 else { throw ParakeetInstallationRefusal.storage }
        identity = .init(s); return true
    }
    private func validateRoot() throws {
        try owned(fd, directory: true)
        var cursor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cursor >= 0 else { throw ParakeetInstallationRefusal.storage }
        defer { Darwin.close(cursor) }
        for part in root.path.split(separator: "/") {
            let next = openat(cursor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ParakeetInstallationRefusal.storage }
            Darwin.close(cursor); cursor = next
        }
        var s = stat(), named = stat()
        guard fstat(fd, &s) == 0, fstat(cursor, &named) == 0,
              s.st_dev == identity?.device, s.st_ino == identity?.inode,
              named.st_dev == s.st_dev, named.st_ino == s.st_ino, named.st_mode & S_IFMT == S_IFDIR else {
            throw ParakeetInstallationRefusal.storage
        }
    }
    private func names(_ directory: Int32, maximum: Int) throws -> Set<String> {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw ParakeetInstallationRefusal.storage }
        defer { closedir(stream) }
        rewinddir(stream)
        var result = Set<String>(); errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum, result.insert(name).inserted else { throw ParakeetInstallationRefusal.storage }
            errno = 0
        }
        guard errno == 0 else { throw ParakeetInstallationRefusal.storage }
        return result
    }
    private func info(_ path: String) throws -> stat? {
        let parts = path.split(separator: "/"); guard let last = parts.last else { throw ParakeetInstallationRefusal.storage }
        let parent = try directory(parts.dropLast().joined(separator: "/")); defer { Darwin.close(parent) }
        var s = stat()
        if fstatat(parent, String(last), &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw ParakeetInstallationRefusal.storage
        }
        return s
    }
    private func file(_ path: String, flags: Int32) throws -> Int32 {
        let parts = path.split(separator: "/"); guard let last = parts.last else { throw ParakeetInstallationRefusal.storage }
        let parent = try directory(parts.dropLast().joined(separator: "/")); defer { Darwin.close(parent) }
        let result = openat(parent, String(last), flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard result >= 0 else { throw ParakeetInstallationRefusal.storage }
        do { try owned(result, directory: false); return result }
        catch { Darwin.close(result); throw error }
    }
    private func record(_ release: ParakeetDataRelease) throws -> ParakeetInstallationRecord {
        try validateRoot()
        let children = try names(fd, maximum: 6)
        guard children.isSubset(of: ["record.json", "candidate", "source", "partial"]), children.contains("record.json") else { throw ParakeetInstallationRefusal.storage }
        let descriptor = try file("record.json", flags: O_RDONLY); defer { Darwin.close(descriptor) }
        var s = stat(); guard fstat(descriptor, &s) == 0, s.st_size > 0, s.st_size <= ParakeetDataRelease.recordLimit else { throw ParakeetInstallationRefusal.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: ParakeetDataRelease.recordLimit + 1) ?? Data()
        guard data.count == s.st_size else { throw ParakeetInstallationRefusal.storage }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schema", "owner", "device", "inode", "release", "generation", "stage", "completed", "current", "observations", "prepared"]) else { throw ParakeetInstallationRefusal.storage }
        let value: ParakeetInstallationRecord
        do { value = try JSONDecoder().decode(ParakeetInstallationRecord.self, from: data) }
        catch { throw ParakeetInstallationRefusal.storage }
        let paths = Set(release.files.map(\.path))
        guard value.schema == 1, value.release == release.id, value.device == identity?.device, value.inode == identity?.inode,
              value.completed.count <= 21, Set(value.completed).count == value.completed.count,
              Set(value.completed).isSubset(of: paths), value.current.map({ paths.contains($0) && !value.completed.contains($0) }) ?? true,
              Set(value.observations.keys).isSubset(of: paths), value.prepared.map({ $0.releaseID == release.id && $0.installation == value.generation }) ?? true else { throw ParakeetInstallationRefusal.storage }
        guard (value.stage == .ready) == (value.prepared != nil),
              [.installed, .preparing, .ready, .publishing].contains(value.stage) || value.observations.isEmpty else { throw ParakeetInstallationRefusal.storage }
        if let partial = try info("partial") {
            guard let current = value.current, let expected = release.files.first(where: { $0.path == current }),
                  partial.st_mode & S_IFMT == S_IFREG, partial.st_nlink == 1, partial.st_uid == getuid(), partial.st_mode & 0o077 == 0,
                  partial.st_size >= 0, partial.st_size <= expected.bytes else { throw ParakeetInstallationRefusal.storage }
        }
        return value
    }
    private func persist(_ value: ParakeetInstallationRecord) throws {
        try validateRoot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= ParakeetDataRelease.recordLimit else { throw ParakeetInstallationRefusal.storage }
        let descriptor = try file("record.next", flags: O_WRONLY | O_CREAT | O_EXCL)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard renameat(fd, "record.next", fd, "record.json") == 0, fsync(fd) == 0 else { throw ParakeetInstallationRefusal.storage }
        } catch { try? handle.close(); throw ParakeetInstallationRefusal.storage } // uncertain files are deliberately preserved
    }
    private var directories: [String] {
        Array(Set(ParakeetModelManifest.entries.flatMap { entry -> [String] in
            let parts = entry.path.split(separator: "/"); return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    }
    private func createCandidate() throws {
        guard mkdirat(fd, "candidate", 0o700) == 0 else { throw ParakeetInstallationRefusal.storage }
        for path in directories {
            let parts = path.split(separator: "/")
            let parent = try directory("candidate/" + parts.dropLast().joined(separator: "/")); defer { Darwin.close(parent) }
            guard mkdirat(parent, String(parts.last!), 0o700) == 0 else { throw ParakeetInstallationRefusal.storage }
        }
        guard fsync(fd) == 0 else { throw ParakeetInstallationRefusal.storage }
    }
    private func inspect(tree: String, release: ParakeetDataRelease, allowed: Set<String>, exact: Bool,
                         hash: Bool, permit: ParakeetActionPermit?) throws -> [String: ParakeetFileObservation] {
        let treeFD = try directory(tree); defer { Darwin.close(treeFD) }
        var observed: [String: ParakeetFileObservation] = [:], visited = 0, bytes: Int64 = 0
        let folders = Set(directories)
        func walk(_ currentFD: Int32, prefix: String) throws {
            var before = stat(); guard fstat(currentFD, &before) == 0 else { throw ParakeetInstallationRefusal.storage }
            for name in try names(currentFD, maximum: 34).sorted() {
                visited += 1; guard visited <= 33 else { throw ParakeetInstallationRefusal.integrity }
                let path = prefix + name
                var s = stat(); guard fstatat(currentFD, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw ParakeetInstallationRefusal.storage }
                if s.st_mode & S_IFMT == S_IFDIR {
                    guard folders.contains(path) else { throw ParakeetInstallationRefusal.integrity }
                    let child = try directory(tree + "/" + path); defer { Darwin.close(child) }
                    try walk(child, prefix: path + "/")
                } else {
                    guard allowed.contains(path), let expected = release.files.first(where: { $0.path == path }),
                          s.st_size == expected.bytes else { throw ParakeetInstallationRefusal.integrity }
                    let child = try file(tree + "/" + path, flags: O_RDONLY); defer { Darwin.close(child) }
                    var opened = stat(); guard fstat(child, &opened) == 0, ParakeetFileObservation(s) == ParakeetFileObservation(opened) else { throw ParakeetInstallationRefusal.integrity }
                    if hash { try verify(child, expected, permit: permit) }
                    observed[path] = .init(opened); bytes += opened.st_size
                    guard bytes <= release.bytes else { throw ParakeetInstallationRefusal.integrity }
                }
            }
            var after = stat(); guard fstat(currentFD, &after) == 0, ParakeetFileObservation(before) == ParakeetFileObservation(after) else { throw ParakeetInstallationRefusal.integrity }
        }
        try walk(treeFD, prefix: "")
        guard !exact || Set(observed.keys) == allowed else { throw ParakeetInstallationRefusal.integrity }
        return observed
    }
    private func verify(_ descriptor: Int32, _ expected: ParakeetDataRelease.File, permit: ParakeetActionPermit?) throws {
        var before = stat(); guard fstat(descriptor, &before) == 0, before.st_size == expected.bytes else { throw ParakeetInstallationRefusal.integrity }
        var hash = SHA256(), bytes = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        repeat {
            try permit?.check()
            let n = Darwin.read(descriptor, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0, n <= expected.bytes - bytes else { throw ParakeetInstallationRefusal.integrity }
            if n == 0 { break }; bytes += n; hash.update(data: Data(buffer.prefix(n)))
        } while true
        var after = stat()
        guard bytes == expected.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.payloadSHA256,
              fstat(descriptor, &after) == 0, ParakeetFileObservation(before) == ParakeetFileObservation(after) else { throw ParakeetInstallationRefusal.integrity }
    }
    private func checked(_ tree: String, release: ParakeetDataRelease, allowed: Set<String>, exact: Bool = true,
                         permit: ParakeetActionPermit) async throws -> [String: ParakeetFileObservation] {
        let check = ParakeetActionPermit(operation: permit.operation, seconds: 60, clock: permit.clock)
        for path in allowed.sorted() { try await hook(.hashing(path)); try permit.check(); try check.check() }
        let result = try inspect(tree: tree, release: release, allowed: allowed, exact: exact, hash: true, permit: check)
        try check.check(); try permit.check(); return result
    }

    /// Passive: bounded records + exact membership + freshness only. No hashes,
    /// network, helper, repair, record creation or cleanup.
    func reconcile(_ release: ParakeetDataRelease) throws -> ParakeetStoredInstallation {
        guard try openRoot(create: false) else { return .init(record: nil, directory: root.appendingPathComponent("source")) }
        let value = try record(release)
        let source = try info("source"), candidate = try info("candidate")
        let all = Set(release.files.map(\.path))
        if [.installed, .preparing, .ready].contains(value.stage) {
            guard source != nil, candidate == nil, value.current == nil, try info("partial") == nil,
                  Set(value.completed) == all, Set(value.observations.keys) == all,
                  try inspect(tree: "source", release: release, allowed: all, exact: true, hash: false, permit: nil) == value.observations else { throw ParakeetInstallationRefusal.storage }
        } else if value.stage == .absent {
            guard source == nil, candidate == nil, try info("partial") == nil, value.completed.isEmpty, value.prepared == nil else { throw ParakeetInstallationRefusal.storage }
        } else {
            guard !(source != nil && candidate != nil) else { throw ParakeetInstallationRefusal.storage }
            if candidate != nil {
                guard value.stage == .installing || value.stage == .publishing || value.stage == .deleting else { throw ParakeetInstallationRefusal.storage }
                _ = try inspect(tree: "candidate", release: release, allowed: Set(value.completed).union(value.current.map { [$0] } ?? []), exact: false, hash: false, permit: nil)
            }
            if source != nil {
                guard value.stage == .publishing || value.stage == .deleting else { throw ParakeetInstallationRefusal.storage }
                _ = try inspect(tree: "source", release: release, allowed: all, exact: true, hash: false, permit: nil)
            }
        }
        return .init(record: value, directory: root.appendingPathComponent("source"))
    }

    func install(_ release: ParakeetDataRelease, retry: Bool, permit: ParakeetActionPermit,
                 progress: @escaping (Int) async -> Void, phase: @escaping (ParakeetSnapshot.Phase) async -> Void) async throws -> ParakeetStoredInstallation {
        try permit.check()
        let existed = try openRoot(create: false)
        var value: ParakeetInstallationRecord
        if !existed {
            _ = try openRoot(create: true)
            guard try names(fd, maximum: 1).isEmpty, let identity else { throw ParakeetInstallationRefusal.storage }
            value = .init(owner: UUID(), device: identity.device, inode: identity.inode, release: release.id, generation: UUID(), stage: .installing)
            try permit.publish { try persist(value) } // durable intent precedes candidate/partial/network
        } else {
            let prior = try reconcile(release); value = prior.record!
            if value.stage == .absent {
                value.generation = UUID(); value.stage = .installing; value.current = nil; value.observations = [:]
                try permit.publish { try persist(value) }
            } else {
                guard retry, [.installing, .publishing].contains(value.stage) else { throw ParakeetInstallationRefusal.interrupted }
            }
        }
        let all = Set(release.files.map(\.path))
        if value.stage == .publishing, try info("source") != nil {
            await phase(.verifying)
            value.observations = try await checked("source", release: release, allowed: all, permit: permit)
        } else {
            if try info("candidate") == nil { guard value.completed.isEmpty else { throw ParakeetInstallationRefusal.storage }; try createCandidate() }
            await phase(.verifying)
            let recovered = try await checked("candidate", release: release, allowed: Set(value.completed).union(value.current.map { [$0] } ?? []), exact: false, permit: permit)
            guard Set(value.completed).isSubset(of: Set(recovered.keys)) else { throw ParakeetInstallationRefusal.integrity }
            if let current = value.current, try info("candidate/" + current) != nil {
                _ = try await checked("candidate", release: release, allowed: Set(value.completed).union([current]), permit: permit)
                value.completed.append(current); value.current = nil; try permit.publish { try persist(value) }
            }
            if try info("partial") != nil { guard value.current != nil else { throw ParakeetInstallationRefusal.storage }; try unlink("partial") }
            for expected in release.files where !value.completed.contains(expected.path) {
                try permit.check()
                value.current = expected.path; try permit.publish { try persist(value) }
                let partial = try file("partial", flags: O_CREAT | O_EXCL | O_WRONLY); Darwin.close(partial)
                await phase(.downloading)
                let response: HTTPURLResponse
                do { response = try await transport.fetch(release.request(for: expected), to: root.appendingPathComponent("partial"), maximum: Int64(expected.bytes), chunkMaximum: Int64(expected.bytes)) }
                catch { throw permit.current ? ParakeetInstallationRefusal.transport : permit.expired ? .deadline : .revoked }
                try await hook(.writerExited(expected.path)); try permit.check()
                guard response.statusCode == 200, let url = response.url, CatalogURLSessionTransport.permitsRedirect(url),
                      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
                      response.value(forHTTPHeaderField: "Content-Type").map({ !$0.lowercased().contains("text/html") }) ?? true,
                      response.expectedContentLength < 0 || response.expectedContentLength == expected.bytes else { throw ParakeetInstallationRefusal.transport }
                await phase(.verifying)
                let verification = ParakeetActionPermit(operation: permit.operation, seconds: 60, clock: permit.clock)
                try await hook(.hashing(expected.path)); try permit.check(); try verification.check()
                let descriptor = try file("partial", flags: O_RDONLY)
                do { try verify(descriptor, expected, permit: verification); try verification.check(); try permit.check(); Darwin.close(descriptor) }
                catch { Darwin.close(descriptor); throw error }
                try await hook(.checkpoint); try permit.check()
                try permit.publish {
                    guard renameat(fd, "partial", fd, "candidate/" + expected.path) == 0 else { throw ParakeetInstallationRefusal.storage }
                    let parent = try directory("candidate/" + expected.path.split(separator: "/").dropLast().joined(separator: "/")); defer { Darwin.close(parent) }
                    guard fsync(parent) == 0 else { throw ParakeetInstallationRefusal.storage }
                    value.completed.append(expected.path); value.current = nil; try persist(value)
                }
                await progress(value.completed.reduce(0) { sum, path in sum + (release.files.first { $0.path == path }?.bytes ?? 0) })
            }
            await phase(.verifying)
            value.observations = try await checked("candidate", release: release, allowed: all, permit: permit)
            value.stage = .publishing; try permit.publish { try persist(value) }
        }
        await phase(.committing); try await hook(.commit); try permit.check()
        try permit.publish {
            if try info("source") == nil { guard renameat(fd, "candidate", fd, "source") == 0, fsync(fd) == 0 else { throw ParakeetInstallationRefusal.storage } }
        }
        // Once rename wins, cancellation can leave only this known publishing
        // transaction. Recovery still requires an explicit full hash, never ready.
        try await hook(.receipt)
        try permit.publish {
            value.stage = .installed; value.prepared = nil; try persist(value)
        }
        return try reconcile(release)
    }
    func verifyInstalled(_ release: ParakeetDataRelease, permit: ParakeetActionPermit) async throws -> ParakeetStoredInstallation {
        let installed = try reconcile(release)
        guard installed.installed else { throw installed.record == nil ? ParakeetInstallationRefusal.absent : .interrupted }
        _ = try await checked("source", release: release, allowed: Set(release.files.map(\.path)), permit: permit)
        return installed
    }
    func prepareIntent(_ release: ParakeetDataRelease, permit: ParakeetActionPermit) async throws -> ParakeetStoredInstallation {
        let installed = try await verifyInstalled(release, permit: permit)
        var value = installed.record!; value.stage = .preparing; value.prepared = nil
        try await hook(.prepareIntent); try permit.publish { try persist(value) }
        return .init(record: value, directory: installed.directory)
    }
    func markPrepared(_ scope: ParakeetPreparedScope, release: ParakeetDataRelease, permit: ParakeetActionPermit,
                      authorize: @MainActor () throws -> Void) async throws -> ParakeetStoredInstallation {
        var value = try record(release)
        guard value.stage == .preparing, value.generation == scope.installation, scope.releaseID == release.id else { throw ParakeetInstallationRefusal.storage }
        guard try inspect(tree: "source", release: release, allowed: Set(release.files.map(\.path)), exact: true, hash: false, permit: nil) == value.observations else { throw ParakeetInstallationRefusal.integrity }
        value.stage = .ready; value.prepared = scope
        try await hook(.receipt)
        try await authorize() // Re-admit after suspended receipt work, before durable publication.
        try permit.publish { try persist(value) }
        return try reconcile(release)
    }
    private func unlink(_ path: String, directory isDirectory: Bool = false) throws {
        let parts = path.split(separator: "/")
        let parent = try directory(parts.dropLast().joined(separator: "/")); defer { Darwin.close(parent) }
        guard unlinkat(parent, String(parts.last!), isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw ParakeetInstallationRefusal.storage }
    }
    func delete(_ release: ParakeetDataRelease, permit: ParakeetActionPermit) async throws {
        let installed = try reconcile(release)
        guard var value = installed.record else { throw ParakeetInstallationRefusal.absent }
        // Full validation establishes exact ownership before explicit recovery/deletion.
        for tree in ["source", "candidate"] where try info(tree) != nil {
            let allowed = tree == "source" ? Set(release.files.map(\.path)) : Set(value.completed).union(value.current.map { [$0] } ?? [])
            _ = try await checked(tree, release: release, allowed: allowed, exact: tree == "source", permit: permit)
        }
        value.stage = .deleting; value.prepared = nil
        try await hook(.deleting); try permit.publish { try persist(value) }
        try permit.publish {
            for tree in ["source", "candidate"] where try info(tree) != nil {
                for expected in release.files where try info(tree + "/" + expected.path) != nil { try unlink(tree + "/" + expected.path) }
                for path in directories.reversed() { if try info(tree + "/" + path) != nil { try unlink(tree + "/" + path, directory: true) } }
                try unlink(tree, directory: true)
            }
            if try info("partial") != nil { try unlink("partial") }
            value.stage = .absent; value.completed = []; value.current = nil; value.observations = [:]
            try persist(value)
        }
    }
}
