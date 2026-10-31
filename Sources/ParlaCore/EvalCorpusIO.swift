import Foundation
import CryptoKit
import Darwin

/// Read-only, descriptor-rooted snapshots. All errors deliberately omit paths.
/// This detects observed changes; a set of filesystem reads is not a transaction.
final class EvalCorpusIO {
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t, links: nlink_t, size: off_t
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; uid = value.st_uid
            links = value.st_nlink; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
        func sameDirectory(_ other: Identity) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode && uid == other.uid
        }
    }
    struct Snapshot {
        let digest: String, bytes: Int, data: Data
    }
    private struct Directory {
        let fd: Int32, parent: Int32, name: String, identity: Identity
    }
    private struct File {
        let parent: Int32, name: String, identity: Identity, digest: String, limit: Int
    }
    private var directories: [Directory] = []
    private var files: [File] = []
    private var identities = Set<String>()
    private var aliases = Set<String>()
    /// Internal deterministic race seam. No command-line or environment bypass.
    var afterRead: (() throws -> Void)?
    private let root: Int32
    private let corpus: Int32

    static func components(_ path: String, absolute: Bool = false) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= (absolute ? 4096 : 256),
              !path.hasSuffix("/"), absolute == path.hasPrefix("/"), !path.hasPrefix("//") else {
            throw EvalCorpusError.path
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let selected = absolute ? Array(parts.dropFirst()) : parts
        guard !selected.isEmpty, selected.allSatisfy({ part in
            !part.isEmpty && !part.hasPrefix(".") && !part.hasSuffix(".") && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 46].contains($0)
            }
        }) else { throw EvalCorpusError.path }
        return selected
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func identity(_ fd: Int32) throws -> Identity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw EvalCorpusError.unreadable }
        return Identity(value)
    }
    private static func directory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EvalCorpusError.path }
        return fd
    }
    init(manifest: String) throws {
        let absolute = manifest.hasPrefix("/") ? manifest : FileManager.default.currentDirectoryPath + "/" + manifest
        let parts = try Self.components(absolute, absolute: true)
        guard parts.last?.hasSuffix(".json") == true else { throw EvalCorpusError.path }
        root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw EvalCorpusError.unreadable }
        var opened: [Directory] = []
        var parent = root
        do {
            for name in parts.dropLast() {
                let fd = try Self.directory(parent, name)
                let identity: Identity
                do { identity = try Self.identity(fd) } catch { close(fd); throw error }
                opened.append(Directory(fd: fd, parent: parent, name: name, identity: identity))
                parent = fd
            }
        } catch {
            for item in opened.reversed() { close(item.fd) }; close(root)
            throw error
        }
        directories = opened; corpus = parent
    }
    deinit {
        for item in directories.reversed() { close(item.fd) }
        close(root)
    }
    func manifest(_ path: String) throws -> Snapshot {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let parts = try Self.components(absolute, absolute: true)
        return try read(parent: corpus, name: parts.last!, limit: 1_048_576, retain: true)
    }
    func payload(_ path: String, extension suffix: String, limit: Int, retain: Bool) throws -> Snapshot {
        let parts = try Self.components(path)
        guard path.hasSuffix(suffix), aliases.insert(path.lowercased()).inserted else { throw EvalCorpusError.path }
        var parent = corpus
        for name in parts.dropLast() { parent = try descend(parent, name) }
        return try read(parent: parent, name: parts.last!, limit: limit, retain: retain)
    }
    func run(_ path: String) throws -> Snapshot {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let parts = try Self.components(absolute, absolute: true)
        guard path.hasSuffix(".json") else { throw EvalCorpusError.path }
        var parent = root
        for name in parts.dropLast() { parent = try descend(parent, name) }
        return try read(parent: parent, name: parts.last!, limit: 33_554_432, retain: true)
    }
    private func descend(_ parent: Int32, _ name: String) throws -> Int32 {
        if let item = directories.first(where: { $0.parent == parent && $0.name == name }) { return item.fd }
        let fd = try Self.directory(parent, name)
        do {
            let identity = try Self.identity(fd)
            directories.append(Directory(fd: fd, parent: parent, name: name, identity: identity))
            return fd
        } catch { close(fd); throw error }
    }
    private func read(parent: Int32, name: String, limit: Int, retain: Bool) throws -> Snapshot {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EvalCorpusError.unreadable }
        defer { close(fd) }
        let before = try Self.identity(fd)
        guard before.mode & S_IFMT == S_IFREG, before.links == 1 else { throw EvalCorpusError.fileKind }
        guard before.size >= 0, before.size <= limit else { throw EvalCorpusError.bounds }
        let key = "\(before.device):\(before.inode)"
        guard identities.insert(key).inserted else { throw EvalCorpusError.duplicate }
        let result = try stream(fd, limit: limit, retain: retain)
        try afterRead?()
        guard before == (try Self.identity(fd)), result.bytes == before.size else { throw EvalCorpusError.changed }
        try binding(parent: parent, name: name, expected: before)
        files.append(File(parent: parent, name: name, identity: before, digest: result.digest, limit: limit))
        return result
    }
    private func stream(_ fd: Int32, limit: Int, retain: Bool) throws -> Snapshot {
        var hash = SHA256(), data = Data(), total = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit - total + 1))
            guard count >= 0 else { throw EvalCorpusError.unreadable }
            if count == 0 { break }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, next <= limit else { throw EvalCorpusError.bounds }
            total = next
            let chunk = Data(buffer.prefix(count)); hash.update(data: chunk)
            if retain { data.append(chunk) }
        }
        return Snapshot(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total, data: data)
    }
    private func binding(parent: Int32, name: String, expected: Identity) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(value) == expected else { throw EvalCorpusError.changed }
    }
    func revalidate() throws {
        for item in directories {
            let fd = try Self.directory(item.parent, item.name)
            defer { close(fd) }
            guard item.identity.sameDirectory(try Self.identity(fd)),
                  item.identity.sameDirectory(try Self.identity(item.fd)) else { throw EvalCorpusError.changed }
        }
        for item in files {
            let fd = openat(item.parent, item.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw EvalCorpusError.changed }
            defer { close(fd) }
            guard try Self.identity(fd) == item.identity else { throw EvalCorpusError.changed }
            let snapshot = try stream(fd, limit: item.limit, retain: false)
            guard snapshot.digest == item.digest, try Self.identity(fd) == item.identity else { throw EvalCorpusError.changed }
            try binding(parent: item.parent, name: item.name, expected: item.identity)
        }
        // Recheck directory names after file rehashing as well. No atomicity claim.
        for item in directories {
            let fd = try Self.directory(item.parent, item.name)
            defer { close(fd) }
            guard item.identity.sameDirectory(try Self.identity(fd)) else { throw EvalCorpusError.changed }
        }
    }
}
