import Foundation
import Darwin

/// Descriptor-relative, private, bounded namespace. Unknown objects are refused and preserved.
/// Fixed files only: lock, health.json, quarantine, replacement. No sweep or installed-model access.
public final class PrivatePreparationStorage: PreparationStorage {
    private var directory: Int32 = -1, processLock: Int32 = -1
    private let root: URL
    public enum Boundary: CaseIterable { case read, createTemp, write, fileSync, rename, directorySync, quarantine, reset }
    private let fault: (Boundary) throws -> Void
    public init(root: URL, fault: @escaping (Boundary) throws -> Void = { _ in }) throws {
        self.root = root; self.fault = fault
        do {
            // Only the final namespace may be created. Parent must already be an owned private app directory.
            let parent = root.deletingLastPathComponent()
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw PreparationRefusal.trackingUnavailable }
            defer { close(parentFD) }
            try Self.validateDirectory(parentFD)
            let name = root.lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { throw PreparationRefusal.trackingUnavailable }
            if mkdirat(parentFD, name, 0o700) != 0, errno != EEXIST { throw PreparationRefusal.trackingUnavailable }
            directory = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw PreparationRefusal.trackingUnavailable }
            try Self.validateDirectory(directory)
            try validateNamespace()
            processLock = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard processLock >= 0 else { throw PreparationRefusal.trackingUnavailable }
            try validateFile(processLock, limit: 0)
            guard flock(processLock, LOCK_EX | LOCK_NB) == 0 else { throw PreparationRefusal.trackingUnavailable }
            // Persist directory/lock creation before any permission can be issued.
            guard fsync(directory) == 0, fsync(parentFD) == 0 else { throw PreparationRefusal.trackingUnavailable }
        } catch { if processLock >= 0 { close(processLock); processLock = -1 }; if directory >= 0 { close(directory); directory = -1 }; throw error }
    }
    deinit { if processLock >= 0 { flock(processLock, LOCK_UN); close(processLock) }; if directory >= 0 { close(directory) } }
    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o7777 == 0o700 else { throw PreparationRefusal.trackingUnavailable }
    }
    private func validateFile(_ fd: Int32, limit: Int = 16_384) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o7777 == 0o600, info.st_size >= 0, info.st_size <= limit else {
            throw PreparationRefusal.trackingUnavailable
        }
    }
    private func exists(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw PreparationRefusal.trackingUnavailable }; return false
    }
    private func checked(_ name: String) throws -> Int32? {
        var before = stat()
        if fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw PreparationRefusal.trackingUnavailable }; return nil
        }
        guard before.st_uid == geteuid(), before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600, before.st_size >= 0,
              before.st_size <= (name == "lock" ? 0 : 16_384) else { throw PreparationRefusal.trackingUnavailable }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw PreparationRefusal.trackingUnavailable }; return nil
        }
        do {
            try validateFile(fd, limit: name == "lock" ? 0 : 16_384)
            var held = stat()
            guard fstat(fd, &held) == 0, held.st_dev == before.st_dev, held.st_ino == before.st_ino else { throw PreparationRefusal.trackingUnavailable }
            return fd
        }
        catch { close(fd); throw error }
    }
    private func validateNamespace() throws {
        try Self.validateDirectory(directory)
        // Check the held descriptor still names our directory, rather than writing into a replaced namespace.
        var held = stat(), named = stat()
        guard fstat(directory, &held) == 0, lstat(root.path, &named) == 0,
              held.st_ino == named.st_ino, held.st_dev == named.st_dev else { throw PreparationRefusal.trackingUnavailable }
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw PreparationRefusal.trackingUnavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var count = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 4, ["lock", "health.json", "quarantine", "replacement"].contains(name) else { throw PreparationRefusal.trackingUnavailable }
            if let fd = try checked(name) { close(fd) }
        }
    }
    public func read() throws -> Data? {
        try fault(.read); try validateNamespace()
        // A durable poison rename is deliberately unavailable, not a new unresolved record.
        guard !(try exists("quarantine")), !(try exists("replacement")) else { throw PreparationRefusal.trackingUnavailable }
        guard let fd = try checked("health.json") else { return nil }; defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 16_385)
        let capacity = bytes.count
        var offset = 0
        while offset < capacity {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), capacity - offset) }
            if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw PreparationRefusal.trackingUnavailable }
            offset += n
        }
        guard offset <= 16_384 else { throw PreparationRefusal.trackingUnavailable }
        return Data(bytes.prefix(offset))
    }
    public func replace(_ data: Data, authorized: () -> Bool = { true }) throws {
        guard data.count <= 16_384 else { throw PreparationRefusal.trackingUnavailable }
        try validateNamespace()
        if let fd = try checked("health.json") { close(fd) }
        guard !(try exists("replacement")), !(try exists("quarantine")) else { throw PreparationRefusal.trackingUnavailable }
        try fault(.createTemp)
        let fd = openat(directory, "replacement", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PreparationRefusal.trackingUnavailable }
        var renamed = false
        defer {
            // Only our exclusive temp with the original inode may be removed on failure.
            if !renamed {
                var owned = stat(), named = stat()
                if fstat(fd, &owned) == 0, fstatat(directory, "replacement", &named, AT_SYMLINK_NOFOLLOW) == 0,
                   owned.st_ino == named.st_ino, owned.st_dev == named.st_dev { _ = unlinkat(directory, "replacement", 0) }
            }
            close(fd)
        }
        try validateFile(fd)
        try fault(.write)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw PreparationRefusal.trackingUnavailable }; offset += n
            }
        }
        try fault(.fileSync); guard fsync(fd) == 0 else { throw PreparationRefusal.trackingUnavailable }
        try validateNamespace()
        guard authorized() else { throw PreparationRefusal.revoked }
        try fault(.rename)
        guard renameat(directory, "replacement", directory, "health.json") == 0 else { throw PreparationRefusal.trackingUnavailable }
        renamed = true
        try fault(.directorySync); guard fsync(directory) == 0 else { throw PreparationRefusal.trackingUnavailable }
    }
    public func quarantine() throws {
        try fault(.quarantine); try validateNamespace()
        guard !(try exists("quarantine")), !(try exists("replacement")), let fd = try checked("health.json") else {
            throw PreparationRefusal.trackingUnavailable
        }
        defer { close(fd) }
        guard renameat(directory, "health.json", directory, "quarantine") == 0, fsync(directory) == 0 else { throw PreparationRefusal.trackingUnavailable }
    }
    /// Explicit action only. Owned bounded corruption can occupy ONE quarantine slot; nothing unknown is removed.
    public func reset(_ data: Data) throws {
        try fault(.reset); try validateNamespace()
        guard !(try exists("replacement")) else { throw PreparationRefusal.trackingUnavailable }
        if let fd = try checked("health.json") {
            close(fd)
            guard !(try exists("quarantine")) else { throw PreparationRefusal.trackingUnavailable }
            try quarantine()
        }
        // Preserve quarantine while publishing clean state. replace requires a poison-free namespace,
        // so use the same durable protocol with a fresh storage publication below.
        try publishReset(data)
    }
    private func publishReset(_ data: Data) throws {
        guard data.count <= 16_384, !(try exists("health.json")), !(try exists("replacement")) else { throw PreparationRefusal.trackingUnavailable }
        // The quarantine is validated and bounded; explicitly reset is the sole operation allowed to retire it.
        if let fd = try checked("quarantine") {
            close(fd)
            guard unlinkat(directory, "quarantine", 0) == 0, fsync(directory) == 0 else { throw PreparationRefusal.trackingUnavailable }
        }
        try replace(data)
    }
}
