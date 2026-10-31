import Darwin
import Foundation
import ParlaCore

struct CatalogDownloadFailure: Error {}

/// Only canonical catalog metadata is durable. Redirect URLs and response bodies
/// never enter the journal. The full SHA is also the artifact revision.
struct CatalogDownloadManifest: Codable, Equatable {
    var version = 1
    let artifactID: String
    let canonicalURL: String
    let bytes: Int64
    let sha256: String
    var committed: Int64
    var validator: CatalogDownloadValidator?
    var generation: UUID
    let staging: String

    func matches(_ model: ModelCatalog.Model) -> Bool {
        artifactID == model.id && canonicalURL == model.url.absoluteString && bytes == model.bytes && sha256 == model.sha256
    }
}

enum CatalogDownloadValidator: Codable, Equatable {
    case etag(String), modified(String)
    var value: String {
        switch self { case .etag(let s), .modified(let s): return s }
    }
    static func date(_ s: String?) -> Date? {
        guard let s, s.utf8.count == 29 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: s), formatter.string(from: date) == s else { return nil }
        return date
    }
    static func strong(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (2...256).contains(b.count) && b.first == 34 && b.last == 34 && b.dropFirst().dropLast().allSatisfy { $0 == 33 || (35...126).contains($0) }
    }
    var valid: Bool {
        switch self { case .etag(let s): return Self.strong(s)
        case .modified(let s): return Self.date(s) != nil }
    }
    static func response(_ http: HTTPURLResponse) -> Self? {
        // A weak/malformed ETag must not fall through to a weaker date rule.
        if let tag = http.value(forHTTPHeaderField: "ETag") { return strong(tag) ? .etag(tag) : nil }
        if let text = http.value(forHTTPHeaderField: "Last-Modified"), let modified = date(text),
           let serverDate = date(http.value(forHTTPHeaderField: "Date")), serverDate.timeIntervalSince(modified) >= 60 {
            return .modified(text)
        }
        return nil
    }
}

/// Private directory + no-follow descriptor operations. Unknown files are never
/// swept. Descriptor checks reject symlinks, hardlinks, foreign ownership and
/// oversized files before reading. Counts include unknown names and are bounded.
final class CatalogDownloadStorage {
    enum Checkpoint { case append, synchronize, manifest, install, publication }
    let root: URL
    let catalog: [ModelCatalog.Model]
    var fault: (Checkpoint) throws -> Void = { _ in }
    private let fm = FileManager.default
    private var directory: Int32 = -1
    private let maximumFiles = 16
    private var maximumBytes: Int64 { catalog.map(\.bytes).max() ?? 0 }
    init(root: URL, catalog: [ModelCatalog.Model]) {
        self.root = root; self.catalog = catalog
    }
    deinit { if directory >= 0 { close(directory) } }

    private func openDirectory(create: Bool) throws -> Bool {
        if directory >= 0 { try checkDirectory(); return true }
        if !fm.fileExists(atPath: root.path) {
            guard create else { return false }
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw CatalogDownloadFailure() }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogDownloadFailure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw CatalogDownloadFailure() }
        directory = fd
        try checkDirectory()
        return true
    }
    func checkDirectory(reserving: Int = 0) throws {
        var held = stat(), named = stat()
        guard directory >= 0, fstat(directory, &held) == 0, lstat(root.path, &named) == 0,
              held.st_ino == named.st_ino, held.st_dev == named.st_dev,
              named.st_mode & S_IFMT == S_IFDIR, named.st_uid == getuid(), named.st_mode & 0o077 == 0 else { throw CatalogDownloadFailure() }
        guard let entries = fdopendir(dup(directory)) else { throw CatalogDownloadFailure() }
        defer { closedir(entries) }
        rewinddir(entries)
        var count = 0
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { count += 1 }
            guard count <= maximumFiles - reserving else { throw CatalogDownloadFailure() }
        }
    }
    private func name(for model: ModelCatalog.Model) throws -> String {
        guard catalog.contains(model), model.id.utf8.count <= 64,
              model.id.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else { throw CatalogDownloadFailure() }
        return model.id + ".json"
    }
    private func owned(_ name: String, limit: Int64, write: Bool = false) throws -> FileHandle {
        try checkDirectory()
        guard !name.contains("/"), name != ".", name != ".." else { throw CatalogDownloadFailure() }
        let fd = openat(directory, name, (write ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogDownloadFailure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= limit else {
            close(fd); throw CatalogDownloadFailure()
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private func size(_ handle: FileHandle) throws -> Int64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw CatalogDownloadFailure() }
        return info.st_size
    }
    func read(_ model: ModelCatalog.Model) throws -> CatalogDownloadManifest? {
        guard try openDirectory(create: false) else { return nil }
        let filename = try name(for: model)
        var info = stat()
        if fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CatalogDownloadFailure() }; return nil
        }
        let handle = try owned(filename, limit: 4096)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw CatalogDownloadFailure() }
        let m = try JSONDecoder().decode(CatalogDownloadManifest.self, from: data)
        guard m.version == 1, m.artifactID == model.id, m.bytes > 0, m.bytes <= maximumBytes,
              m.sha256.count == 64, m.canonicalURL.utf8.count <= 256,
              m.committed >= 0, m.committed <= m.bytes, m.validator?.valid != false,
              m.staging.hasPrefix("part-"), UUID(uuidString: String(m.staging.dropFirst(5))) != nil,
              m.staging.count == 41 else { throw CatalogDownloadFailure() }
        return m
    }
    func inspect(_ model: ModelCatalog.Model) throws -> CatalogDownloadManifest? {
        guard let m = try read(model) else { return nil }
        guard m.matches(model) else { throw CatalogDownloadFailure() }
        let handle = try owned(m.staging, limit: m.bytes)
        defer { try? handle.close() }
        guard try size(handle) >= m.committed else { throw CatalogDownloadFailure() }
        return m
    }
    func prepare(_ model: ModelCatalog.Model, generation: UUID) throws -> CatalogDownloadManifest {
        _ = try openDirectory(create: true)
        if var m = try read(model) {
            guard m.matches(model) else { throw CatalogDownloadFailure() }
            let handle = try owned(m.staging, limit: m.bytes, write: true)
            defer { try? handle.close() }
            guard try size(handle) >= m.committed else { throw CatalogDownloadFailure() }
            // Bytes written before a crash but not journaled are never trusted.
            try handle.truncate(atOffset: UInt64(m.committed))
            try handle.synchronize()
            m.generation = generation
            try save(m, model)
            return m
        }
        try checkDirectory(reserving: 2)
        let staging = "part-" + UUID().uuidString
        let fd = openat(directory, staging, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CatalogDownloadFailure() }; close(fd)
        let m = CatalogDownloadManifest(artifactID: model.id, canonicalURL: model.url.absoluteString,
            bytes: model.bytes, sha256: model.sha256, committed: 0, validator: nil, generation: generation, staging: staging)
        do { try save(m, model) } catch { unlinkat(directory, staging, 0); throw error }
        return m
    }
    func save(_ m: CatalogDownloadManifest, _ model: ModelCatalog.Model,
              publish: (() throws -> Void) throws -> Void = { try $0() }) throws {
        try fault(.manifest)
        try checkDirectory(reserving: 1)
        let data = try JSONEncoder().encode(m)
        guard data.count <= 4096 else { throw CatalogDownloadFailure() }
        let temporary = "journal-" + UUID().uuidString
        let fd = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CatalogDownloadFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directory, temporary, 0) }
        try handle.write(contentsOf: data); try handle.synchronize()
        try publish {
            guard renameat(directory, temporary, directory, try name(for: model)) == 0 else { throw CatalogDownloadFailure() }
        }
    }
    func reset(_ m: inout CatalogDownloadManifest, _ model: ModelCatalog.Model,
               commit: (() throws -> Void) throws -> Void = { try $0() }) throws {
        m.committed = 0; m.validator = nil
        try save(m, model, publish: commit) // zero commitment precedes destructive truncation
        let file = try owned(m.staging, limit: m.bytes, write: true)
        defer { try? file.close() }
        try file.truncate(atOffset: 0); try file.synchronize()
    }
    func chunk() throws -> URL {
        try checkDirectory(reserving: 1)
        let name = "chunk-" + UUID().uuidString
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CatalogDownloadFailure() }; close(fd)
        return root.appendingPathComponent(name)
    }
    func chunkSize(_ url: URL, maximum: Int64) throws -> Int64 {
        let f = try owned(url.lastPathComponent, limit: maximum)
        defer { try? f.close() }; return try size(f)
    }
    func removeChunk(_ url: URL) {
        guard url.deletingLastPathComponent() == root, url.lastPathComponent.hasPrefix("chunk-"),
              let handle = try? owned(url.lastPathComponent, limit: maximumBytes) else { return }
        try? handle.close(); unlinkat(directory, url.lastPathComponent, 0)
    }
    func append(_ chunk: URL, to m: inout CatalogDownloadManifest, count: Int64,
                validator: CatalogDownloadValidator?, model: ModelCatalog.Model,
                commit: (() throws -> Void) throws -> Void = { try $0() }) throws {
        let source = try owned(chunk.lastPathComponent, limit: count)
        let target = try owned(m.staging, limit: m.bytes, write: true)
        defer { try? source.close(); try? target.close() }
        guard try size(source) == count, try size(target) == m.committed, count <= m.bytes - m.committed else { throw CatalogDownloadFailure() }
        try fault(.append)
        try target.seek(toOffset: UInt64(m.committed))
        var remaining = count
        while remaining > 0 {
            guard let data = try source.read(upToCount: Int(min(remaining, 64 << 10))), !data.isEmpty else { throw CatalogDownloadFailure() }
            try target.write(contentsOf: data); remaining -= Int64(data.count)
        }
        guard try source.read(upToCount: 1)?.isEmpty != false else { throw CatalogDownloadFailure() }
        try fault(.synchronize)
        try target.synchronize()
        var next = m; next.committed += count; next.validator = validator
        try save(next, model, publish: commit) // failed journal leaves the previous offset authoritative
        m = next
    }
    func stageIsMissing(_ m: CatalogDownloadManifest) throws -> Bool {
        try checkDirectory()
        var info = stat()
        if fstatat(directory, m.staging, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw CatalogDownloadFailure() }
        return true
    }
    func stage(_ m: CatalogDownloadManifest) throws -> URL {
        let f = try owned(m.staging, limit: m.bytes)
        defer { try? f.close() }
        guard m.committed == m.bytes, try size(f) == m.bytes else { throw CatalogDownloadFailure() }
        return root.appendingPathComponent(m.staging)
    }
    func finish(_ model: ModelCatalog.Model) throws {
        try checkDirectory()
        guard unlinkat(directory, try name(for: model), 0) == 0 || errno == ENOENT else { throw CatalogDownloadFailure() }
    }
    func discard(_ model: ModelCatalog.Model) throws {
        guard let m = try read(model) else { return }
        // Retired identity is removable only with valid bounded provenance and
        // a private regular staging file. Malformed/unknown state is left alone.
        if try stageIsMissing(m) {
            guard m.committed == m.bytes else { throw CatalogDownloadFailure() }
            try finish(model); return
        }
        let handle = try owned(m.staging, limit: m.bytes)
        try handle.close()
        guard unlinkat(directory, m.staging, 0) == 0 else { throw CatalogDownloadFailure() }
        try finish(model)
    }
}
