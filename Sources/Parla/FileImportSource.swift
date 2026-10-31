import Darwin
import Foundation
import ParlaCore

/// Selected descriptor ownership is distinct from an active reader's borrow.
/// Cancellation never closes an fd underneath read; no pathname is reopened.
final class FileImportSource: @unchecked Sendable {
    enum Failure: Error {
        case unavailable, unsafe, changed, read
        var message: String {
            switch self {
            case .unavailable: return "Choose a readable, locally resident WAV file."
            case .unsafe: return "Use a regular local WAV without links, aliases or cloud placeholders."
            case .changed: return "The selected file changed. Choose it again before Start."
            case .read: return "The complete file could not be read. Choose it again to retry."
            }
        }
    }
    struct Access {
        var conversion = ImportedAudio.Native()
        var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var metadata: (URL, Int32) throws -> Void = { url, fd in
            let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isUbiquitousItemKey, .volumeIsLocalKey])
            var volume = statfs()
            guard values.isAliasFile == false, values.isUbiquitousItem != true,
                  values.volumeIsLocal == true, fstatfs(fd, &volume) == 0,
                  volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.unsafe }
        }
        var read: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
    }
    // Darwin UF_DATALESS is not exposed by every Swift SDK overlay.
    private static let datalessFlag: UInt32 = 0x4000_0000
    private struct Binding {
        let parent: Int32, name: String, identity: stat
    }
    let displayName: String
    let byteCount: Int
    /// Destination protection only; recognition never reopens this pathname.
    var originalURL: URL { url }
    private let url: URL, access: Access, scoped: Bool
    private let descriptors: [Int32], bindings: [Binding], identity: stat
    private let fd: Int32
    private let lock = NSLock()
    private var borrowed = false, closed = false, revoked = false
    var isClosed: Bool { lock.withLock { closed } }

    init(url: URL, access: Access = .init()) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0), url.pathExtension.lowercased() == "wav" else { throw Failure.unsafe }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { throw Failure.unsafe }
        let scoped = access.start(url)
        var opened: [Int32] = [], bindings: [Binding] = []
        do {
            var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard parent >= 0 else { throw Failure.unavailable }; opened.append(parent)
            for (i, name) in parts.enumerated() {
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (i == parts.count - 1 ? 0 : O_DIRECTORY)
                let child = openat(parent, name, flags)
                guard child >= 0 else { throw Failure.unsafe }
                opened.append(child)
                var st = stat()
                guard fstat(child, &st) == 0 else { throw Failure.unavailable }
                bindings.append(.init(parent: parent, name: name, identity: st)); parent = child
            }
            var st = stat()
            guard fstat(parent, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  st.st_flags & Self.datalessFlag == 0 else { throw Failure.unsafe }
            guard st.st_size > 0, st.st_size <= ImportedWAV.maximumBytes else { throw ImportedWAV.Failure.size }
            try access.metadata(url, parent)
            try Self.validate(fd: parent, identity: st, bindings: bindings)
            self.url = url; self.access = access; self.scoped = scoped
            self.fd = parent; self.descriptors = opened; self.bindings = bindings; self.identity = st
            byteCount = Int(st.st_size)
            // Escape controls and bidi format characters; retain ordinary Unicode/spaces.
            displayName = String(url.lastPathComponent.unicodeScalars.prefix(160).map { scalar in
                CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar)
                    || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                    ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
            }.joined().prefix(640))
        } catch {
            for descriptor in opened.reversed() { Darwin.close(descriptor) }
            if scoped { access.stop(url) }
            throw error
        }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec && a.st_flags == b.st_flags
    }
    private func validate() throws { try Self.validate(fd: fd, identity: identity, bindings: bindings) }
    private static func validate(fd: Int32, identity: stat, bindings: [Binding]) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, Self.same(st, identity) else { throw Failure.changed }
        for (i, binding) in bindings.enumerated() {
            var named = stat()
            guard fstatat(binding.parent, binding.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == binding.identity.st_dev, named.st_ino == binding.identity.st_ino,
                  named.st_mode & S_IFMT == binding.identity.st_mode & S_IFMT else { throw Failure.changed }
            if i == bindings.count - 1, !Self.same(named, identity) { throw Failure.changed }
        }
    }
    struct Validated {
        let decoded: ImportedAudio.Decoded
        let encodedData: Data?
        let original: SavedAudioImportStore.Original?
        let startedUptime: TimeInterval, workCredits: Int
    }
    var originalIdentity: SavedAudioImportStorage.Identity { .init(device: identity.st_dev, inode: identity.st_ino) }
    func samples(canceled: () -> Bool) throws -> ImportedAudio.Decoded {
        try readValidated(retainEncoded: false, canceled: canceled).decoded
    }
    /// Only explicit retained entry can extend the exact validated buffer's life.
    func readValidated(retainEncoded: Bool, canceled: () -> Bool) throws -> Validated {
        try lock.withLock {
            guard !revoked, !closed, !borrowed else { throw CancellationError() }
            borrowed = true
        }
        defer { lock.withLock { borrowed = false; closeLocked() } }
        let started = ProcessInfo.processInfo.systemUptime
        var iterations = retainEncoded ? bindings.count * 4 + 64 : 0
        func check() throws {
            if canceled() || lock.withLock({ revoked }) { throw CancellationError() }
            if retainEncoded {
                iterations += 1
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard iterations <= 65_536, elapsed.isFinite, elapsed >= 0, elapsed <= 30 else { throw Failure.read }
            }
        }
        try check(); try validate()
        var bytes = Data(); bytes.reserveCapacity(byteCount)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while bytes.count < byteCount {
            try check()
            let count = buffer.withUnsafeMutableBytes { access.read(fd, $0.baseAddress!, min($0.count, byteCount - bytes.count)) }
            guard count > 0, count <= min(buffer.count, byteCount - bytes.count) else { throw Failure.read }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try check()
        let tail = buffer.withUnsafeMutableBytes { access.read(fd, $0.baseAddress!, 1) }
        guard tail == 0 else { throw Failure.changed }
        let samples = try ImportedAudio.decode(bytes, canceled: { canceled() || self.lock.withLock { self.revoked } }, native: access.conversion)
        try validate(); try check()
        var resolvedPath: String?
        if retainEncoded {
            var path = [CChar](repeating:0,count:Int(PATH_MAX))
            guard path.withUnsafeMutableBytes({fcntl(fd,F_GETPATH,$0.baseAddress!)}) == 0 else {throw Failure.changed}
            resolvedPath = String(cString:path)
        }
        let original: SavedAudioImportStore.Original? = retainEncoded ? .init(
            lexical: url.standardizedFileURL.path, resolved: resolvedPath!,
            identity: originalIdentity, bytes: identity.st_size,
            modifiedSeconds: Int64(identity.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(identity.st_mtimespec.tv_nsec),
            changedSeconds: Int64(identity.st_ctimespec.tv_sec), changedNanoseconds: Int64(identity.st_ctimespec.tv_nsec), flags: identity.st_flags,
            birthSeconds: Int64(identity.st_birthtimespec.tv_sec), birthNanoseconds: Int64(identity.st_birthtimespec.tv_nsec)) : nil
        if retainEncoded {try validate(); try check()}
        return Validated(decoded: samples, encodedData: retainEncoded ? bytes : nil, original: original, startedUptime: started, workCredits: iterations)
    }
    func cancel() { lock.withLock { revoked = true; if !borrowed { closeLocked() } } }
    private func closeLocked() {
        guard !closed else { return }; closed = true
        for descriptor in descriptors.reversed() { Darwin.close(descriptor) }
        if scoped { access.stop(url) }
    }
    deinit { cancel() }
}
