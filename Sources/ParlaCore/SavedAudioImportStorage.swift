import CryptoKit
import Darwin
import Foundation

/// Private, flat, descriptor-bound storage. This checks process-crash publication;
/// it makes no power-loss or hostile same-UID race guarantee.
public final class SavedAudioImportStorage: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case unavailable, changed, unknown, contended, bounds, clock, space, io, uncertain, revoked
        public var message: String {
            switch self {
            case .contended: return "Saved files are in use. Try again in a moment."
            case .unknown: return "Saved files couldn’t be read. They haven’t been changed."
            case .bounds: return "Too many saved files. Delete one first."
            case .clock: return "Saved files are unavailable because the system clock looks wrong."
            case .space: return "Not enough free space. Free up at least 512 MB."
            case .revoked: return "This is out of date. Try again."
            case .uncertain: return "Couldn’t confirm the change. Some files may remain."
            case .changed: return "Saved files changed. Try again."
            case .io, .unavailable: return "Saved files are unavailable right now."
            }
        }
    }
    public struct Identity: Codable, Equatable, Hashable, Sendable {
        public let device: Int32, inode: UInt64
        public init(device: Int32, inode: UInt64) { self.device = device; self.inode = inode }
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino }
    }
    public struct Member: Codable, Equatable, Sendable {
        public let identity: Identity
        public var bytes: Int64
        public let birthSeconds: Int64, birthNanoseconds: Int64
        public let modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
        public let flags: UInt32
        init(_ s: stat) {
            identity = Identity(s); bytes = s.st_size
            birthSeconds = Int64(s.st_birthtimespec.tv_sec); birthNanoseconds = Int64(s.st_birthtimespec.tv_nsec)
            modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(s.st_mtimespec.tv_nsec)
            changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanoseconds = Int64(s.st_ctimespec.tv_nsec); flags = s.st_flags
        }
        func matches(_ s: stat, size: Bool = true) -> Bool {
            identity == Identity(s) && (!size || bytes == s.st_size)
                && birthSeconds == s.st_birthtimespec.tv_sec && birthNanoseconds == s.st_birthtimespec.tv_nsec
                && (!size || (modifiedSeconds == s.st_mtimespec.tv_sec && modifiedNanoseconds == s.st_mtimespec.tv_nsec
                    && changedSeconds == s.st_ctimespec.tv_sec && changedNanoseconds == s.st_ctimespec.tv_nsec && flags == s.st_flags))
        }
    }
    public enum Boundary: String, CaseIterable, Sendable {
        case allocation, registered, payloadRetired, authorityRetired, tombstoneRetired, allocationRetired, created, borrowRelease, bootstrap, enumerate, metadataRead, payloadRead, create, write, hash, fileSync, close, verify, rename, directorySync, unlink, freeSpace, binding
    }
    public struct System {
        public var checkpoint: (Boundary) throws -> Void = { _ in }
        /// Exact member/phase fault seam; production performs the same checked IO.
        public var event: (Boundary, String?) throws -> Void = { _,_ in }
        public var inspect: (Int32, UnsafeMutablePointer<stat>) -> Int32 = {Darwin.fstat($0,$1)}
        public var read: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
        public var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        public var sync: (Int32) -> Int32 = { Darwin.fsync($0) }
        /// A fault close must retire its descriptor even when returning failure.
        public var close: (Int32) -> Int32 = { Darwin.close($0) }
        public var readDirectory: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = {Darwin.readdir($0)}
        public var closeDirectory: (UnsafeMutablePointer<DIR>) -> Int32 = { Darwin.closedir($0) }
        public var freeBytes: (Int32) throws -> Int64 = { fd in
            var s = statfs(); guard fstatfs(fd, &s) == 0, s.f_bsize > 0 else { throw Failure.space }
            let value = UInt64(s.f_bavail).multipliedReportingOverflow(by: UInt64(s.f_bsize))
            guard !value.overflow, value.partialValue <= UInt64(Int64.max) else { throw Failure.space }
            return Int64(value.partialValue)
        }
        public var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public init() {}
    }
    final class Budget {
        let start: TimeInterval
        var calls = 0, interrupts = 0
        init(_ system: System, started: TimeInterval? = nil, credits: Int = 0) { start = started ?? system.uptime(); calls = credits }
        func check(_ system: System, interrupted: Bool = false, cost: Int = 1) throws {
            calls += cost; if interrupted { interrupts += 1 }
            let elapsed = system.uptime() - start
            guard calls <= 65_536, interrupts <= 128, elapsed.isFinite, elapsed >= 0, elapsed <= 30 else { throw Failure.bounds }
        }
    }
    private struct Binding { let parent: Int32, fd: Int32, name: String, identity: Identity }
    private static let registryLock = NSLock()
    private static var registry = Set<Identity>()
    public let root: URL
    private let system: System
    private var descriptors: [Int32] = [], bindings: [Binding] = []
    private var directory: Int32 = -1, lockFD: Int32 = -1
    private var registered: Identity?, lockMember: Member?
    private var uncertainClose = false
    var failure: Failure? { uncertainClose ? .uncertain : nil }
    public var identity: Identity? { registered }
    public init(root: URL, system: System = .init()) { self.root = root; self.system = system }
    func step(_ boundary: Boundary, _ budget: Budget, name: String? = nil) throws {
        // Conservative syscall credits cover each helper's bounded fixed work.
        // Directory walks reserve 256 per component (including <=64 ACL entries).
        try budget.check(system, cost: 16); try system.checkpoint(boundary); try system.event(boundary,name); try budget.check(system)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validName(_ name: String) -> Bool {
        if ["owner.json", "lock", "manifest.json", "manifest.next"].contains(name) { return true }
        for suffix in [".source.pending", ".source.wav", ".source.mov", ".result.pending", ".raw.txt", ".delete"] where name.hasSuffix(suffix) {
            let id = String(name.dropLast(suffix.count))
            return UUID(uuidString: id)?.uuidString.lowercased() == id
        }
        return false
    }
    private func retire(_ fd: Int32, _ budget: Budget, name: String? = nil) throws {
        // close is issued once, including EINTR: never close a potentially reused fd.
        let result = system.close(fd)
        // The opening/read/create helper reserved retirement credits. Always
        // retire once even after its cooperative budget expires; budget expiry
        // is not a failed close and must not prevent descriptor retirement.
        do { try system.checkpoint(.close); try system.event(.close,name) } catch { uncertainClose = true; throw Failure.uncertain }
        guard result == 0 else { uncertainClose = true; throw Failure.uncertain }
    }
    private func directoryInfo(_ fd: Int32, privateRoot: Bool, budget: Budget? = nil) throws -> stat {
        var s = stat(), volume = statfs()
        guard system.inspect(fd, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
              (s.st_uid == geteuid() || (!privateRoot && s.st_uid == 0)),
              s.st_mode & 0o022 == 0, !privateRoot || s.st_mode & 0o7777 == 0o700,
              s.st_flags & 0x4000_0000 == 0,
              fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.unavailable }
        let filesystem = withUnsafePointer(to: volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString:$0) }
        }
        guard filesystem == "apfs" || filesystem == "hfs" else { throw Failure.unavailable }
        // Deny-only ACLs on ancestors are acceptable; private roots/members have no ACL entries.
        try Self.checkAlias(fd)
        try Self.checkACL(fd, empty: privateRoot, credits: {try budget?.check(self.system,cost:$0)})
        return s
    }
    private static func checkAlias(_ fd: Int32) throws {
        var info = [UInt8](repeating:0,count:32)
        let count = info.withUnsafeMutableBytes {fgetxattr(fd,"com.apple.FinderInfo",$0.baseAddress,$0.count,0,0)}
        if count < 0 {guard errno == ENOATTR else {throw Failure.changed}; return}
        guard count == 32, info[8] & 0x80 == 0 else {throw Failure.changed}
    }
    private static func checkACL(_ fd: Int32, empty: Bool, credits: (Int) throws -> Void = {_ in}) throws {
        try credits(2)
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw Failure.unavailable }; return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var flag = ACL_FIRST_ENTRY
        var count = 0
        while true {
            try credits(2)
            let result = acl_get_entry(acl, Int32(flag.rawValue), &entry)
            if result == -1, errno == EINVAL { break } // Darwin end-of-list
            guard result == 0, let entry else { throw Failure.unavailable }
            count += 1; guard !empty, count <= 64 else { throw Failure.unavailable }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { throw Failure.unavailable }
            flag = ACL_NEXT_ENTRY
        }
    }
    private func fileInfo(_ fd: Int32, cap: Int64) throws -> stat {
        var s = stat()
        guard system.inspect(fd, &s) == 0 else {throw Failure.changed}
        try validateFileStat(s,cap:cap)
        try Self.checkAlias(fd)
        try Self.checkACL(fd, empty: true)
        return s
    }
    private func validateFileStat(_ s: stat,cap: Int64) throws {
        guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid(),
              s.st_nlink == 1, s.st_mode & 0o7777 == 0o600, s.st_size >= 0, s.st_size <= cap,
              s.st_flags & 0x4000_0000 == 0, s.st_dev == registered?.device else { throw Failure.changed }
    }
    /// Absent storage remains absent until explicit retained admission.
    func open(create: Bool, budget: Budget) throws -> Bool {
        if directory >= 0 { try validate(budget); return true }
        try step(.bootstrap, budget)
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              root.query == nil, root.fragment == nil, root.path.utf8.count <= 4096,
              !root.path.utf8.contains(0), root.path.hasPrefix("/") else { throw Failure.unavailable }
        let parts = root.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 64, !parts.contains("."), !parts.contains("..") else { throw Failure.unavailable }
        do {
            var rootCreated = false
            var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard parent >= 0 else { throw Failure.unavailable }; descriptors.append(parent)
            // Public system ancestors /private and /tmp can be sticky; the owned
            // application parent itself must pass the strict non-writable policy.
            for (i, name) in parts.enumerated() {
                try budget.check(system, cost: 256)
                let final = i == parts.count - 1
                var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                var created = false
                if child < 0, errno == ENOENT {
                    if !create { try close(); return false }
                    // Only the app parent and final namespace may be created.
                    guard i >= parts.count - 2 else { throw Failure.unavailable }
                    _ = try directoryInfo(parent, privateRoot: false, budget: budget)
                    guard mkdirat(parent, name, 0o700) == 0 else { throw Failure.io }
                    child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    created = true
                }
                guard child >= 0 else { throw Failure.unavailable }; descriptors.append(child)
                var s = stat(); guard fstat(child, &s) == 0 else { throw Failure.io }
                bindings.append(Binding(parent: parent, fd: child, name: name, identity: Identity(s)))
                if final || i == parts.count - 2 { _ = try directoryInfo(child, privateRoot: final, budget: budget) }
                else {
                    // Ancestors need trusted ownership, no writable non-sticky directories, and deny-only ACLs.
                    guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == 0 || s.st_uid == geteuid(),
                          s.st_mode & 0o022 == 0 || (s.st_uid == 0 && s.st_mode & S_ISVTX != 0) else { throw Failure.unavailable }
                    try Self.checkACL(child, empty: false)
                }
                if created {
                    if final {rootCreated = true}
                    try sync(child, budget); try sync(parent, budget)
                }
                parent = child
            }
            directory = parent
            let key = Identity(try directoryInfo(directory, privateRoot: true, budget: budget))
            guard Self.registryLock.withLock({ Self.registry.insert(key).inserted }) else { throw Failure.contended }
            registered = key
            let names = try enumerate(budget)
            let new = names.isEmpty && rootCreated
            guard !new || create else { throw Failure.unknown }
            if new {
                lockFD = openat(directory, "lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            } else {
                guard names.contains("lock"), names.contains("owner.json"), names.contains("manifest.json") else { throw Failure.unknown }
                lockFD = openat(directory, "lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard lockFD >= 0 else { throw Failure.unavailable }
            lockMember = Member(try fileInfo(lockFD, cap: 0))
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.contended }
            try validate(budget)
            return true
        } catch {
            try? close(); throw error
        }
    }
    func validate(_ budget: Budget) throws {
        try step(.binding, budget)
        try budget.check(system, cost: bindings.count * 2 + 32)
        guard !uncertainClose, directory >= 0, let registered else { throw Failure.unavailable }
        guard Identity(try directoryInfo(directory, privateRoot: true, budget: budget)) == registered else { throw Failure.changed }
        for (i,binding) in bindings.enumerated() {
            try budget.check(system)
            var held = stat(), named = stat()
            guard fstat(binding.fd, &held) == 0,
                  fstatat(binding.parent, binding.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(held) == binding.identity, Identity(named) == binding.identity,
                  named.st_mode & S_IFMT == S_IFDIR else { throw Failure.changed }
            if i >= bindings.count - 2 { _ = try directoryInfo(binding.fd, privateRoot: i == bindings.count - 1, budget: budget) }
            else {
                guard held.st_uid == 0 || held.st_uid == geteuid(), held.st_mode & 0o022 == 0 || (held.st_uid == 0 && held.st_mode & S_ISVTX != 0),
                      held.st_flags & 0x4000_0000 == 0 else {throw Failure.changed}
                try Self.checkACL(binding.fd,empty:false,credits:{try budget.check(self.system,cost:$0)})
            }
        }
        if let lockMember {
            var named = stat()
            guard lockMember.matches(try fileInfo(lockFD, cap: 0)),
                  fstatat(directory, "lock", &named, AT_SYMLINK_NOFOLLOW) == 0, lockMember.matches(named) else { throw Failure.changed }
        }
    }
    func enumerate(_ budget: Budget) throws -> [String] {
        try step(.enumerate, budget)
        let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw Failure.io }
        guard let stream = fdopendir(duplicate) else { try retire(duplicate, budget); throw Failure.io }
        var names: [String] = []
        do {
            rewinddir(stream)
            while true {
                try budget.check(system); errno = 0
                guard let entry = system.readDirectory(stream) else { guard errno == 0 else { throw Failure.io }; break }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                names.append(name)
                guard names.count <= 64, Self.validName(name), Set(names.map { $0.lowercased() }).count == names.count else { throw Failure.unknown }
            }
        } catch { let result = system.closeDirectory(stream); if result != 0 { uncertainClose = true; throw Failure.uncertain }; throw error }
        guard system.closeDirectory(stream) == 0 else { uncertainClose = true; throw Failure.uncertain }
        return names
    }
    func named(_ name: String, cap: Int64, budget: Budget) throws -> Member? {
        try validate(budget); guard Self.validName(name) else { throw Failure.unknown }
        var s = stat()
        if fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.io }; return nil
        }
        try validateFileStat(s,cap:cap)
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changed }
        var retired = false
        do {
            let held = try fileInfo(fd, cap: cap)
            guard Member(s).matches(held) else { throw Failure.changed }
            retired = true; try retire(fd, budget); try budget.check(system)
            return Member(held)
        } catch { if !retired { try retire(fd, budget) }; throw error }
    }
    func requireSpace(_ remaining: Int64, budget: Budget) throws {
        try step(.freeSpace, budget)
        let sum = Int64(536_870_912).addingReportingOverflow(remaining)
        guard remaining >= 0, !sum.overflow, try system.freeBytes(directory) >= sum.partialValue else { throw Failure.space }
    }
    func create(_ name: String, cap: Int64, budget: Budget) throws -> (Int32, Member) {
        try validate(budget); _ = try enumerate(budget)
        guard Self.validName(name), try enumerate(budget).count < 64 else { throw Failure.bounds }
        try step(.create, budget, name:name); try validate(budget)
        guard try enumerate(budget).count < 64 else {throw Failure.bounds}
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        do { let member = Member(try fileInfo(fd, cap: cap)); try step(.created,budget,name:name); return (fd,member) }
        catch { try retire(fd, budget); throw error }
    }
    func write(_ data: Data, fd: Int32, name: String, allocated: Member, remaining: Int64,
               authorized: () -> Bool, budget: Budget) throws -> Member {
        var retired = false
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard authorized() else { throw Failure.revoked }
                    try requireSpace(max(0, remaining - Int64(offset)), budget: budget)
                    try step(.write, budget, name:name); try validate(budget)
                    guard authorized() else {throw Failure.revoked}
                    let held = try fileInfo(fd,cap:Int64(data.count)); var named = stat()
                    guard allocated.matches(held,size:false), fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW) == 0,
                          Member(held).matches(named) else {throw Failure.changed}
                    let amount = min(65_536, bytes.count - offset)
                    let n = system.write(fd, bytes.baseAddress!.advanced(by: offset), amount)
                    if n < 0, errno == EINTR { try budget.check(system, interrupted: true); continue }
                    guard n > 0, n <= amount else { throw Failure.io }; offset += n
                }
            }
            let member = Member(try fileInfo(fd, cap: Int64(data.count)))
            guard allocated.matches(try fileInfo(fd, cap: Int64(data.count)), size: false), member.bytes == data.count else { throw Failure.changed }
            try step(.fileSync, budget, name:name); guard system.sync(fd) == 0 else { throw Failure.uncertain }
            retired = true; try retire(fd, budget, name:name)
            try step(.verify, budget, name:name)
            _ = try read(name, expected: member, cap: Int64(data.count), expectedHash: Self.digest(data), payload: true, collect: false, authorized:authorized, budget: budget)
            guard authorized() else { throw Failure.revoked }
            return member
        } catch {
            if !retired { try retire(fd, budget) }
            throw error
        }
    }
    func read(_ name: String, expected: Member?, cap: Int64, expectedHash: String? = nil,
              payload: Bool, collect: Bool = true, authorized: () -> Bool = {true}, budget: Budget) throws -> Data {
        try validate(budget); try step(payload ? .payloadRead : .metadataRead, budget, name:name); try validate(budget)
        guard authorized() else {throw Failure.revoked}
        guard Self.validName(name) else { throw Failure.unknown }
        var before = stat()
        guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
        try validateFileStat(before,cap:cap)
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        var retired = false
        do {
            let s = try fileInfo(fd, cap: cap), member = Member(s)
            guard Member(before).matches(s), expected?.matches(s) ?? true else { throw Failure.changed }
            var data = Data(), hash = SHA256(), total: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try budget.check(system)
                guard authorized() else {throw Failure.revoked}
                let count = buffer.withUnsafeMutableBytes { system.read(fd, $0.baseAddress!, min(65_536, Int(cap - total + 1))) }
                if count < 0, errno == EINTR { try budget.check(system, interrupted: true); continue }
                guard count >= 0, count <= buffer.count else { throw Failure.io }
                if count == 0 { break }
                total += Int64(count); guard total <= cap else { throw Failure.bounds }
                if expectedHash != nil { buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) } }
                if collect { data.append(contentsOf: buffer.prefix(count)) }
            }
            var named = stat()
            guard total == member.bytes, member.matches(try fileInfo(fd, cap: cap)),
                  fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, member.matches(named) else { throw Failure.changed }
            if let expectedHash {
                try step(.hash, budget, name:name)
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else { throw Failure.changed }
            }
            try validate(budget)
            retired = true; try retire(fd, budget, name:name); try budget.check(system)
            return data
        } catch { if !retired { try retire(fd, budget) }; throw error }
    }
    func sync(_ fd: Int32? = nil, _ budget: Budget, name: String? = nil) throws {
        try step(.directorySync, budget, name:name); guard system.sync(fd ?? directory) == 0 else { throw Failure.uncertain }
    }
    func rename(_ from: String, member: Member, to: String, replacing: Member?, authorized: () -> Bool, budget: Budget) throws {
        try step(.rename,budget,name:from); try validate(budget)
        guard try named(from,cap:member.bytes,budget:budget) == member,
              try named(to,cap:65_536,budget:budget) == replacing else {throw Failure.changed}
        guard authorized() else {throw Failure.revoked}
        guard renameat(directory,from,directory,to) == 0 else {throw Failure.uncertain}
        try sync(nil,budget,name:to)
    }
    struct Held { let fd: Int32, name: String, member: Member }
    func hold(_ name: String, member: Member, budget: Budget) throws -> Held {
        try validate(budget)
        guard try named(name,cap:member.bytes,budget:budget) == member else { throw Failure.changed }
        let fd = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        do {
            let held = Held(fd:fd,name:name,member:member)
            try validateHeld(held,budget:budget); return held
        } catch { try retire(fd,budget); throw error }
    }
    func validateHeld(_ held: Held, budget: Budget) throws {
        try validate(budget)
        guard held.member.matches(try fileInfo(held.fd,cap:held.member.bytes)),
              try named(held.name,cap:held.member.bytes,budget:budget) == held.member else { throw Failure.changed }
    }
    func release(_ held: Held, budget: Budget) throws {
        var boundaryFailed = false
        do {try system.checkpoint(.borrowRelease)} catch {boundaryFailed = true}
        try retire(held.fd,budget)
        if boundaryFailed {uncertainClose = true; throw Failure.uncertain}
    }
    func qualify(_ name: String, member: Member, budget: Budget) throws {
        try validate(budget)
        guard try named(name, cap: member.bytes, budget: budget) == member else { throw Failure.changed }
        let fd = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        var retired = false
        do {
            guard member.matches(try fileInfo(fd,cap:member.bytes)) else { throw Failure.changed }
            try step(.fileSync,budget,name:name); guard system.sync(fd) == 0 else { throw Failure.uncertain }
            retired = true; try retire(fd,budget)
            guard try named(name,cap:member.bytes,budget:budget) == member else { throw Failure.changed }
            try sync(nil,budget)
        } catch { if !retired { try retire(fd,budget) }; throw error }
    }
    func unlink(_ name: String, member: Member, budget: Budget) throws {
        try validate(budget)
        guard let current = try named(name, cap: max(member.bytes, 20_971_520), budget: budget) else { return }
        guard current.identity == member.identity, current.birthSeconds == member.birthSeconds,
              current.birthNanoseconds == member.birthNanoseconds else { throw Failure.changed }
        try step(.unlink, budget,name:name); try validate(budget)
        guard let checked = try named(name,cap:max(member.bytes,20_971_520),budget:budget),
              checked.identity == member.identity, checked.birthSeconds == member.birthSeconds,
              checked.birthNanoseconds == member.birthNanoseconds else {throw Failure.changed}
        guard unlinkat(directory, name, 0) == 0 else { throw Failure.uncertain }
    }
    public func close() throws {
        let budget = Budget(system)
        var failed = false
        if lockFD >= 0 { let fd = lockFD; lockFD = -1; do { try retire(fd, budget) } catch { failed = true } }
        for fd in descriptors.reversed() { do { try retire(fd, budget) } catch { failed = true } }
        descriptors = []; bindings = []; directory = -1; lockMember = nil
        if failed || uncertainClose { throw Failure.uncertain }
        if let registered { _ = Self.registryLock.withLock { Self.registry.remove(registered) } }; registered = nil
    }
    func budget(started: TimeInterval? = nil, credits: Int = 0) -> Budget { Budget(system,started:started,credits:credits) }
    deinit { try? close() }
}

// Meeting-only primitives. The import constructor, static grammar and all import operations above are unchanged.
public struct MeetingStorageProfile: Equatable, Sendable {
    public let members = 512, metadata = 524_288, pathComponents = 12
    public init() {}
}
/// Pure process identity, retained by receipts so allocator address reuse cannot authenticate a foreign exit.
public final class MeetingStorageContext: Hashable, @unchecked Sendable {
    public init() {}
    public static func == (a: MeetingStorageContext, b: MeetingStorageContext) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
public enum MeetingRegistryDomain: Hashable, Sendable { case physical, virtual(MeetingStorageContext) }
public enum MeetingStorageFault: Error { case missing, interrupted, io }
public enum MeetingOpenMode: Equatable { case directory, read, write, exclusive }
public struct MeetingVolume { public let local: Bool, name: String; public init(local: Bool, name: String) { self.local = local; self.name = name } }
/// Every OS query is injected. A virtual bottom implements every method; there is no Darwin fallback.
public protocol MeetingStorageBottom: AnyObject {
    var registryDomain: MeetingRegistryDomain { get }
    var uid: uid_t { get }
    func uptime() -> TimeInterval
    func checkpoint(_ operation: String, name: String?) throws
    func open(parent: Int32?, name: String, mode: MeetingOpenMode) throws -> Int32
    func mkdir(parent: Int32, name: String) throws
    func excludeFromBackup(_ fd: Int32) throws
    func inspect(_ fd: Int32) throws -> stat
    func named(parent: Int32, name: String) throws -> stat?
    func volume(_ fd: Int32) throws -> MeetingVolume
    func finderAlias(_ fd: Int32) throws -> Bool
    func denyACLCount(_ fd: Int32, maximum: Int, check: () throws -> Void) throws -> Int
    func flock(_ fd: Int32) throws
    func duplicate(_ fd: Int32) throws -> Int32
    func makeStream(_ fd: Int32) throws
    func nextName(_ stream: Int32) throws -> String?
    func closeStream(_ stream: Int32) throws
    func read(_ fd: Int32, maximum: Int) throws -> Data
    func write(_ fd: Int32, bytes: Data) throws -> Int
    func freeBytes(_ fd: Int32) throws -> Int64
    func sync(_ fd: Int32) throws
    func rename(parent: Int32, from: String, to: String) throws
    func unlink(parent: Int32, name: String, directory: Bool) throws
    /// Must consume the raw descriptor once even when the close result is unknown.
    func close(_ fd: Int32) throws
}

public extension MeetingStorageBottom {
    /// Virtual bottoms have no OS backup service. Physical bottoms must implement the exclusion.
    func excludeFromBackup(_ fd: Int32) throws {
        guard case .virtual = registryDomain else { throw MeetingStorageFault.io }
    }
}

private func meetingExclusiveLock(_ fd: Int32) -> Int32 { flock(fd,LOCK_EX | LOCK_NB) }

/// Explicit real bottom, never constructed by the store or owner. Initializing this object does no IO.
public final class MeetingDarwinBottom: MeetingStorageBottom {
    private let tick: () -> TimeInterval, fault: (String,String?) throws -> Void
    private var streams: [Int32:UnsafeMutablePointer<DIR>] = [:]
    public init(uptime: @escaping () -> TimeInterval, checkpoint: @escaping (String,String?) throws -> Void) { tick = uptime; fault = checkpoint }
    public var registryDomain: MeetingRegistryDomain { .physical }
    public var uid: uid_t { geteuid() }
    public func uptime() -> TimeInterval { tick() }
    public func checkpoint(_ operation: String, name: String?) throws { try fault(operation,name) }
    private func error() -> MeetingStorageFault { errno == ENOENT ? .missing : errno == EINTR ? .interrupted : .io }
    public func open(parent: Int32?, name: String, mode: MeetingOpenMode) throws -> Int32 {
        let flags: Int32
        switch mode { case .directory: flags = O_RDONLY | O_DIRECTORY; case .read: flags = O_RDONLY; case .write: flags = O_RDWR; case .exclusive: flags = O_RDWR | O_CREAT | O_EXCL }
        let safe = flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let fd: Int32
        if let parent { fd = openat(parent,name,safe,0o600) } else { guard name == "/", mode == .directory else { throw MeetingStorageFault.io }; fd = Darwin.open(name,safe) }
        guard fd >= 0 else { throw error() }; return fd
    }
    public func mkdir(parent: Int32, name: String) throws { guard mkdirat(parent,name,0o700) == 0 else { throw error() } }
    public func excludeFromBackup(_ fd: Int32) throws {
        let value = try PropertyListSerialization.data(fromPropertyList:"com.apple.backupd",format:.binary,options:0)
        let result = value.withUnsafeBytes { fsetxattr(fd,"com.apple.metadata:com_apple_backup_excludeItem",$0.baseAddress,$0.count,0,0) }
        guard result == 0 else { throw error() }
    }
    public func inspect(_ fd: Int32) throws -> stat { var s = stat(); guard fstat(fd,&s) == 0 else { throw error() }; return s }
    public func named(parent: Int32, name: String) throws -> stat? { var s = stat(); if fstatat(parent,name,&s,AT_SYMLINK_NOFOLLOW) == 0 { return s }; guard errno == ENOENT else { throw error() }; return nil }
    public func volume(_ fd: Int32) throws -> MeetingVolume {
        var v = statfs(); guard fstatfs(fd,&v) == 0 else { throw error() }
        let name = withUnsafePointer(to:v.f_fstypename) { $0.withMemoryRebound(to:CChar.self,capacity:16) { String(cString:$0) } }
        return .init(local:v.f_flags & UInt32(MNT_LOCAL) != 0,name:name)
    }
    public func finderAlias(_ fd: Int32) throws -> Bool {
        var b = [UInt8](repeating:0,count:32); let n = b.withUnsafeMutableBytes { fgetxattr(fd,"com.apple.FinderInfo",$0.baseAddress,$0.count,0,0) }
        if n < 0 { guard errno == ENOATTR else { throw error() }; return false }; guard n == 32 else { throw MeetingStorageFault.io }; return b[8] & 0x80 != 0
    }
    public func denyACLCount(_ fd: Int32, maximum: Int, check: () throws -> Void) throws -> Int {
        guard maximum == 0 || maximum == 64 else { throw MeetingStorageFault.io }
        try check()
        guard let acl = acl_get_fd_np(fd,ACL_TYPE_EXTENDED) else { guard errno == ENOENT else { throw error() }; return 0 }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?, flag = ACL_FIRST_ENTRY, count = 0
        while true {
            try check()
            let status = acl_get_entry(acl,Int32(flag.rawValue),&entry)
            if status == -1, errno == EINVAL { return count }
            guard status == 0, let entry else { throw MeetingStorageFault.io }
            count += 1; guard count <= maximum else { throw MeetingStorageFault.io }
            var tag = acl_tag_t(0); guard acl_get_tag_type(entry,&tag) == 0, tag == ACL_EXTENDED_DENY else { throw MeetingStorageFault.io }
            flag = ACL_NEXT_ENTRY
        }
    }
    public func flock(_ fd: Int32) throws { guard meetingExclusiveLock(fd) == 0 else { throw SavedAudioImportStorage.Failure.contended } }
    public func duplicate(_ fd: Int32) throws -> Int32 { let copy = fcntl(fd,F_DUPFD_CLOEXEC,0); guard copy >= 0 else { throw error() }; return copy }
    public func makeStream(_ fd: Int32) throws { guard streams[fd] == nil, let stream = fdopendir(fd) else { throw MeetingStorageFault.io }; streams[fd] = stream; rewinddir(stream) }
    public func nextName(_ stream: Int32) throws -> String? {
        guard let p = streams[stream] else { throw MeetingStorageFault.io }; errno = 0
        guard let e = readdir(p) else { guard errno == 0 else { throw error() }; return nil }
        let b = withUnsafePointer(to:e.pointee.d_name) { $0.withMemoryRebound(to:UInt8.self,capacity:Int(MAXNAMLEN)+1) { Array(UnsafeBufferPointer(start:$0,count:Int(MAXNAMLEN)+1)) } }
        guard let end = b.firstIndex(of:0), let value = String(bytes:b[..<end],encoding:.utf8) else { throw MeetingStorageFault.io }; return value
    }
    public func closeStream(_ stream: Int32) throws { guard let p = streams.removeValue(forKey:stream) else { throw MeetingStorageFault.io }; guard closedir(p) == 0 else { throw MeetingStorageFault.io } }
    public func read(_ fd: Int32, maximum: Int) throws -> Data {
        guard maximum > 0, maximum <= 65_536 else { throw MeetingStorageFault.io }
        var bytes = Data(count:maximum); let n = bytes.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!,maximum) }
        guard n >= 0 else { throw error() }; bytes.count = n; return bytes
    }
    public func write(_ fd: Int32, bytes: Data) throws -> Int { let n = bytes.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!,bytes.count) }; guard n >= 0 else { throw error() }; return n }
    public func freeBytes(_ fd: Int32) throws -> Int64 {
        var s = statfs(); guard fstatfs(fd,&s) == 0, s.f_bsize > 0 else { throw MeetingStorageFault.io }
        let product = UInt64(s.f_bavail).multipliedReportingOverflow(by:UInt64(s.f_bsize)); guard !product.overflow, product.partialValue <= UInt64(Int64.max) else { throw MeetingStorageFault.io }; return Int64(product.partialValue)
    }
    public func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw error() } }
    public func rename(parent: Int32, from: String, to: String) throws { guard renameat(parent,from,parent,to) == 0 else { throw error() } }
    public func unlink(parent: Int32, name: String, directory: Bool) throws { guard unlinkat(parent,name,directory ? AT_REMOVEDIR : 0) == 0 else { throw error() } }
    public func close(_ fd: Int32) throws { guard Darwin.close(fd) == 0 else { throw error() } }
}

extension SavedAudioImportStorage {
    /// A retained meeting epoch. Store serialization surrounds every public phase; raw descriptors never escape.
    final class MeetingLease {
        typealias Member = SavedAudioImportStorage.Member
        typealias Failure = SavedAudioImportStorage.Failure
        struct Receipt: Equatable, Sendable {
            let domain: MeetingRegistryDomain
            let hashes: Int, hashBytes: UInt64, syncAttempts: Int, publications: Int
            let validates: Int, enumerations: Int, fixed: Int, progress: Int, interrupts: Int, retirement: Int, path: Int, opens: Int, closes: Int, carryIn: Int, carryOut: Int, peak: Int
            var credits: Int { validates * 1600 + enumerations * 550 + fixed + progress + interrupts * 2 + retirement + path }
        }
        final class Work {
            let bottom: MeetingStorageBottom, started: TimeInterval, carry: Int
            var hashes = 0, hashBytes: UInt64 = 0, syncAttempts = 0, publications = 0
            var mutated = false
            var validates = 0, enumerations = 0, fixed = 0, progress = 0, interrupts = 0, retirement = 0, path = 0, opens = 0, closes = 0, peak: Int
            init(_ bottom: MeetingStorageBottom, carry: Int) { self.bottom = bottom; started = bottom.uptime(); self.carry = carry; peak = carry }
            func charge(v: Int = 0, e: Int = 0, f: Int = 0, io: Int = 0, interrupt: Bool = false) throws {
                let nv = validates + v, ne = enumerations + e, nf = fixed + f, ni = progress + io, nt = interrupts + (interrupt ? 1 : 0)
                let current = bottom.uptime(), elapsed = current - started
                // Denied precharges perform no primitive. Reserve once-only unwind and its failure fence first.
                guard nv <= 32, ne <= 2, nf <= 2048 - 17, ni <= 1024, nt <= 128,
                    nv * 1600 + ne * 550 + nf + ni + nt * 2 + path + 512 + 17 <= 65_536,
                    started.isFinite, started >= 0, current.isFinite, elapsed.isFinite, elapsed >= 0, elapsed <= 30 else { throw Failure.bounds }
                validates = nv; enumerations = ne; fixed = nf; progress = ni; interrupts = nt
            }
            func hashed(_ bytes: Int) throws {
                guard bytes >= 0 else { throw Failure.bounds }
                hashBytes = try MeetingSession.add(hashBytes,UInt64(bytes)); hashes += 1
            }
            func checkTime() throws {
                let current = bottom.uptime(), elapsed = current-started
                guard started.isFinite,started >= 0,current.isFinite,elapsed.isFinite,elapsed >= 0,elapsed <= 30 else { throw Failure.bounds }
            }
            func opened() throws { opens += 1; peak = max(peak,carry + opens - closes); guard peak <= 17, opens <= 64 else { throw Failure.bounds } }
            func closed() { closes += 1; retirement += 8 }
            func result(carryOut: Int, domain: MeetingRegistryDomain) -> Receipt { .init(domain:domain,hashes:hashes,hashBytes:hashBytes,syncAttempts:syncAttempts,publications:publications,validates:validates,enumerations:enumerations,fixed:fixed,progress:progress,interrupts:interrupts,retirement:retirement,path:path,opens:opens,closes:closes,carryIn:carry,carryOut:carryOut,peak:peak) }
        }
        struct Token: Equatable, Hashable { let context: MeetingStorageContext, epoch: UInt64, serial: UInt64 }
        struct Owned { let token: Token, fd: Int32; var stream: Bool }
        struct Binding { let parent: Int32, fd: Int32, name: String, identity: Identity }
        struct Borrow { let owned: Owned, member: Member, name: String, generation: UInt64 }
        enum Worker: Hashable, Sendable { case microphone, system, microphoneCallback, systemCallback, writer, output }
        struct Hold: Equatable, Sendable { let context: MeetingStorageContext, epoch: UInt64, serial: UInt64, kind: Worker }
        let context = MeetingStorageContext()
        var currentEpoch: UInt64 { epoch }
        private var registryDomain: MeetingRegistryDomain?
        let root: URL, profile: MeetingStorageProfile, bottom: MeetingStorageBottom
        private var epoch: UInt64 = 0, serial: UInt64 = 0
        private var base: [Owned] = [], temporary: [Owned] = [], bindings: [Binding] = []
        private var lockToken: Owned?, lockMember: Member?, registered: Identity?
        private var borrowed: Borrow?, active = false
        private var retiredValue = true
        private var retired: Bool { get { holdLock.withLock { retiredValue } } set { holdLock.withLock { retiredValue = newValue } } }
        private var poisonValue = false, unavailableValue = false
        private(set) var poisoned: Bool { get { holdLock.withLock { poisonValue } } set { holdLock.withLock { poisonValue = newValue } } }
        private(set) var unavailable: Bool { get { holdLock.withLock { unavailableValue } } set { holdLock.withLock { unavailableValue = newValue } } }
        private let holdLock = NSRecursiveLock(); private var workers: [Worker:Hold] = [:]
        private var quit = false, revoked = false, outputRevoked = false
        var identity: Identity? { registered }
        var directory: Int32 { base.last?.fd ?? -1 }
        var rawCount: Int { base.count + temporary.count + (lockToken == nil ? 0 : 1) + (borrowed == nil ? 0 : 1) }
        var hasBorrow: Bool { borrowed != nil }
        var drained: Bool { holdLock.withLock { workers.isEmpty } && borrowed == nil }
        var ready: Bool { quit && drained && !active && !poisoned && !unavailable && !retired && lockToken != nil }
        init(root: URL, profile: MeetingStorageProfile, bottom: MeetingStorageBottom) { self.root = root; self.profile = profile; self.bottom = bottom }
        func register(_ kind: Worker) throws -> Hold {
            try holdLock.withLock {
                guard (!revoked || (kind == .output && !quit && !outputRevoked)), !retired, !poisoned, !unavailable, workers[kind] == nil else { throw Failure.revoked }
                serial = try MeetingSession.add(serial,1); let token = Hold(context:context,epoch:epoch,serial:serial,kind:kind); workers[kind] = token; return token
            }
        }
        func actualExit(_ hold: Hold) throws { try holdLock.withLock { guard workers[hold.kind] == hold, hold.epoch == epoch else { throw Failure.changed }; workers.removeValue(forKey:hold.kind) } }
        func fence(allWorkers: Bool = false) { holdLock.withLock { revoked = true; if allWorkers { outputRevoked = true } } }
        func reserveQuit() { holdLock.withLock { quit = true; revoked = true } }
        func cancelQuit() { holdLock.withLock { quit = false } }
        func begin(cold: Bool = false, retirementOnly: Bool = false) throws -> Work {
            try holdLock.withLock {
            guard (serial <= UInt64.max - 128 || retirementOnly), !active, !poisoned || retirementOnly, !unavailable || retirementOnly else { throw Failure.unavailable }
            if cold { guard base.isEmpty, lockToken == nil, borrowed == nil, registered == nil, holdLock.withLock({workers.isEmpty}) else { throw Failure.contended }; epoch = try MeetingSession.add(epoch,1); retired = false }
            else { guard !retired, !base.isEmpty, lockToken != nil, registered != nil else { throw Failure.unavailable } }
            active = true; return Work(bottom,carry:rawCount)
            }
        }
        func checkpoint(_ label: String, name: String?, fixed: Int, _ b: Work) throws { try b.charge(f:fixed); try bottom.checkpoint(label,name:name) }
        private func acquired(_ fd: Int32, base isBase: Bool, isLock: Bool = false, _ b: Work) throws -> Owned {
            let owned = try holdLock.withLock { () throws -> Owned in
                serial = try MeetingSession.add(serial,1); return Owned(token:.init(context:context,epoch:epoch,serial:serial),fd:fd,stream:false)
            }
            if isLock { lockToken = owned } else if isBase { base.append(owned) } else { temporary.append(owned) }
            try b.opened(); try bottom.checkpoint(isBase ? "base-open" : "temporary-open",name:nil); return owned
        }
        private func consume(_ owned: Owned, _ b: Work) throws {
            // Remove ownership BEFORE observing either close or injected post-close failure. Never retry the raw integer.
            if let i = temporary.firstIndex(where:{$0.token == owned.token}) { temporary.remove(at:i) }
            else if let i = base.firstIndex(where:{$0.token == owned.token}) { base.remove(at:i) }
            else if lockToken?.token == owned.token { lockToken = nil }
            else if borrowed?.owned.token == owned.token { borrowed = nil }
            else { throw Failure.changed }
            b.closed()
            var failed = false; do { if owned.stream { try bottom.closeStream(owned.fd) } else { try bottom.close(owned.fd) } } catch { failed = true }
            do { try bottom.checkpoint("close-observed",name:nil) } catch { failed = true }
            if failed { poisoned = true; unavailable = true; throw Failure.uncertain }
        }
        func fail(_ b: Work, cold: Bool = false, undeliveredBorrow: Bool = false, final: Bool = false) {
            unavailable = true; b.fixed += 17
            while let token = temporary.last { try? consume(token,b) }
            if undeliveredBorrow, let token = borrowed?.owned { try? consume(token,b) }
            if cold || final { retireBase(b) }
            active = false
        }
        func snapshot(_ b: Work) -> Receipt { b.result(carryOut:rawCount,domain:registryDomain!) }
        func finish(_ b: Work) throws -> Receipt {
            guard temporary.isEmpty else { throw Failure.uncertain }
            try checkpoint("phase-exit",name:nil,fixed:17,b); try bottom.checkpoint("before-outward-receipt",name:nil)
            active = false; return b.result(carryOut:rawCount,domain:registryDomain!)
        }
        private func retireBase(_ b: Work) {
            while let token = base.last { try? consume(token,b) }
            if let token = lockToken { try? consume(token,b) } // meeting lock is deliberately LAST
            bindings = []; retired = true; lockMember = nil
            if !poisoned, let registered { _ = SelfRegistry.remove(registered,domain:registryDomain!); self.registered = nil }
        }
        // Shared in-process registry with imports; no profile can adopt an already retained physical root.
        private enum SelfRegistry {
            private struct Key: Hashable { let scope: MeetingStorageContext, identity: Identity }
            private static let lock = NSLock(); private static var virtual = Set<Key>()
            static func insert(_ key: Identity, domain: MeetingRegistryDomain) -> Bool {
                switch domain {
                case .physical: return SavedAudioImportStorage.registryLock.withLock { SavedAudioImportStorage.registry.insert(key).inserted }
                case .virtual(let scope): return lock.withLock { virtual.insert(.init(scope:scope,identity:key)).inserted }
                }
            }
            static func remove(_ key: Identity, domain: MeetingRegistryDomain) {
                switch domain {
                case .physical: _ = SavedAudioImportStorage.registryLock.withLock { SavedAudioImportStorage.registry.remove(key) }
                case .virtual(let scope): _ = lock.withLock { virtual.remove(.init(scope:scope,identity:key)) }
                }
            }
        }
        private var protectionUID: uid_t?
        private(set) var coldProtectionUncertain = false
        private func protectionBoundary(_ label: String,_ b: Work,authorized: () -> Bool) throws {
            try checkpoint(label,name:nil,fixed:17,b); guard authorized() else { throw Failure.revoked }
        }
        func withLoadedProtection<T>(authorized: () -> Bool,
            catalog: (Set<String>,Member) throws -> [String:Member],
            validate: ([URL],[URL],Set<Identity>) throws -> Void,perform: () throws -> T) throws -> T {
            guard drained,!hasBorrow else { throw Failure.contended }
            let hold = try register(.output)
            var work: Work?, exitAttempted = false
            do {
                let b = try begin(); work = b
                try checkpoint("protection-entry",name:nil,fixed:33,b)
                guard authorized(),let lockMember else { throw Failure.revoked }
                try b.charge(f:32)
                try self.validate(b); let firstNames = try names(b), members = try catalog(firstNames,lockMember)
                let identities = try protectionMembers(members,b,authorized:authorized)
                let urls = members.keys.map { root.appendingPathComponent($0) }
                let bound = bindings.indices.map { index in
                    bindings.prefix(index+1).reduce(URL(fileURLWithPath:"/",isDirectory:true)) { $0.appendingPathComponent($1.name,isDirectory:true) }
                }
                try protectionBoundary("protection-before-validator",b,authorized:authorized)
                try validate(bound,urls,identities.union(registered.map { [$0] } ?? []))
                try protectionBoundary("protection-before-final",b,authorized:authorized)
                try self.validate(b); guard try names(b) == firstNames else { throw Failure.changed }
                guard try protectionMembers(members,b,authorized:authorized) == identities,authorized() else { throw Failure.changed }
                let result = try perform() // actual synchronous return, including reentrancy and throws
                guard authorized() else { throw Failure.revoked }
                _ = try finish(b); exitAttempted = true; try actualExit(hold); return result
            } catch {
                if let b = work { fail(b) }
                if exitAttempted { poisoned = true; unavailable = true }
                else { exitAttempted = true; do { try actualExit(hold) } catch { poisoned = true; unavailable = true } }
                throw error
            }
        }
        private func protectionMembers(_ members: [String:Member],_ b: Work,authorized: () -> Bool) throws -> Set<Identity> {
            guard members.count <= profile.members,let uid = protectionUID,let registered else { throw Failure.unavailable }
            var identities = Set<Identity>()
            for (name,expected) in members {
                var observed: stat?
                while true {
                    try b.charge(f:1); guard authorized() else { throw Failure.revoked }
                    do { observed = try bottom.named(parent:directory,name:name); break }
                    catch MeetingStorageFault.interrupted { try b.charge(interrupt:true); try b.charge() }
                }
                guard let s = observed,s.st_mode & S_IFMT == S_IFREG,s.st_uid == uid,s.st_mode & 0o7777 == 0o600,
                      s.st_nlink == 1,s.st_size >= 0,s.st_flags & 0x4000_0000 == 0,s.st_dev == registered.device,
                      expected.matches(s) else { throw Failure.changed }
                identities.insert(expected.identity); try b.charge(io:1)
            }
            return identities
        }
        /// Independent cold ownership; never activates or borrows the retired lease.
        private final class ColdProtectionProbe {
            private enum AttemptFailure: Error { case missing }
            struct Held { let fd: Int32, identity: Identity, url: URL }
            let lease: MeetingLease, work: Work, parts: [String]
            var raw: [Int32] = [], held: [Held] = [], missing: String?, uncertain = false
            init(_ lease: MeetingLease,parts: [String]) { self.lease = lease; self.parts = parts; work = Work(lease.bottom,carry:0); raw.reserveCapacity(13); held.reserveCapacity(12) }
            func open(parent: Int32?,name: String,authorized: () -> Bool) throws -> Int32 {
                while true {
                    try work.charge(f:3); guard authorized() else { throw Failure.revoked }
                    try lease.bottom.checkpoint("protection-path-open",name:name)
                    let fd: Int32
                    do { fd = try lease.bottom.open(parent:parent,name:name,mode:.directory) }
                    catch MeetingStorageFault.interrupted { try work.charge(interrupt:true); try work.charge(); continue }
                    catch MeetingStorageFault.missing { throw AttemptFailure.missing }
                    raw.append(fd) // actual raw return is tracked before every fallible check
                    try work.opened(); try lease.bottom.checkpoint("base-open",name:nil); return fd
                }
            }
            func classify(_ fd: Int32,index: Int,url: URL) throws {
                let s = try lease.directoryInfo(fd,privateRoot:false,strictParent:index == parts.count-1,budget:work,checkVolume:false)
                held.append(.init(fd:fd,identity:Identity(s),url:url))
            }
            func initial(authorized: () -> Bool) throws {
                work.path = 3072; try lease.checkpoint("protection-entry",name:nil,fixed:33,work); try work.charge(v:2)
                let fd = try open(parent:nil,name:"/",authorized:authorized)
                try classify(fd,index:0,url:URL(fileURLWithPath:"/",isDirectory:true))
                for (i,name) in parts.enumerated() {
                    guard authorized(),let parent = held.last else { throw Failure.revoked }
                    let child: Int32
                    do { child = try open(parent:parent.fd,name:name,authorized:authorized) }
                    catch AttemptFailure.missing {
                        missing = name; try absence(parent.fd,name:name); try volume(parent.fd); try work.checkTime(); return
                    }
                    guard i != parts.count-1 else { throw Failure.unknown }
                    let url = parent.url.appendingPathComponent(name,isDirectory:true)
                    try classify(child,index:i+1,url:url)
                    guard let s = try lease.bottom.named(parent:parent.fd,name:name),Identity(s) == held.last!.identity,
                          s.st_mode & S_IFMT == S_IFDIR else { throw Failure.changed }
                }
                throw Failure.unknown
            }
            func absence(_ parent: Int32,name: String) throws {
                guard try lease.bottom.named(parent:parent,name:name) == nil else { throw Failure.changed }
            }
            func volume(_ fd: Int32) throws {
                let v = try lease.bottom.volume(fd); guard v.local,v.name == "apfs" || v.name == "hfs" else { throw Failure.unavailable }
            }
            func final(authorized: () -> Bool) throws {
                try work.charge(v:2); guard let missing,!held.isEmpty else { throw Failure.unavailable }
                for (i,h) in held.enumerated() {
                    guard authorized(),Identity(try lease.directoryInfo(h.fd,privateRoot:false,strictParent:i == parts.count-1,budget:work,checkVolume:false)) == h.identity else { throw Failure.changed }
                    if i > 0 {
                        guard let s = try lease.bottom.named(parent:held[i-1].fd,name:parts[i-1]),Identity(s) == h.identity,
                              s.st_mode & S_IFMT == S_IFDIR else { throw Failure.changed }
                    }
                }
                try absence(held.last!.fd,name:missing); try volume(held.last!.fd); try work.checkTime()
            }
            func closeAll() {
                while let fd = raw.popLast() {
                    work.closed(); var failed = false
                    do { try lease.bottom.close(fd) } catch { failed = true }
                    do { try lease.bottom.checkpoint("close-observed",name:nil) } catch { failed = true }
                    if failed { uncertain = true }
                }
            }
        }
        func withColdProtection<T>(authorized: () -> Bool,validate: ([URL]) throws -> Void,perform: () throws -> T) throws -> T {
            guard retired,!active,!poisoned,!unavailable,!coldProtectionUncertain,rawCount == 0,drained else { throw Failure.unavailable }
            guard root.isFileURL,root.host == nil || root.host == "" || root.host == "localhost",root.query == nil,root.fragment == nil,
                  root.path.utf8.count <= 4096,!root.path.utf8.contains(0),root.path.hasPrefix("/") else { throw Failure.bounds }
            let parts = root.path.split(separator:"/").map(String.init)
            guard !parts.isEmpty,parts.count <= profile.pathComponents,!parts.contains("."),!parts.contains("..") else { throw Failure.bounds }
            let probe = ColdProtectionProbe(self,parts:parts), b = probe.work
            var closing = false
            do {
                try probe.initial(authorized:authorized)
                try protectionBoundary("protection-before-validator",b,authorized:authorized)
                try validate(probe.held.map(\.url))
                try protectionBoundary("protection-before-final",b,authorized:authorized)
                try probe.final(authorized:authorized); guard authorized() else { throw Failure.revoked }
                let result = try perform()
                try checkpoint("phase-exit",name:nil,fixed:17,b)
                closing = true; probe.closeAll(); guard !probe.uncertain else { throw Failure.uncertain }
                try b.checkTime(); try bottom.checkpoint("before-outward-receipt",name:nil)
                guard authorized() else { throw Failure.revoked }; return result
            } catch {
                b.fixed += 17; probe.closeAll()
                if probe.uncertain || closing { coldProtectionUncertain = true }
                throw error
            }
        }
        private func directoryInfo(_ fd: Int32, privateRoot: Bool, strictParent: Bool, budget b: Work, checkVolume: Bool = true) throws -> stat {
            let s = try bottom.inspect(fd), acl = try bottom.denyACLCount(fd,maximum:privateRoot ? 0 : 64,check:{try b.checkTime()})
            guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == bottom.uid || (!privateRoot && s.st_uid == 0),
                s.st_flags & 0x4000_0000 == 0, acl >= 0, acl <= 64, !privateRoot || acl == 0,
                !privateRoot || s.st_mode & 0o7777 == 0o700,
                s.st_mode & 0o022 == 0 || (!privateRoot && !strictParent && s.st_uid == 0 && s.st_mode & S_ISVTX != 0),
                try !bottom.finderAlias(fd) else { throw Failure.changed }
            if checkVolume && (privateRoot || strictParent) { let v = try bottom.volume(fd); guard v.local, v.name == "apfs" || v.name == "hfs" else { throw Failure.unavailable } }; return s
        }
        private func fileInfo(_ fd: Int32, cap: Int64, budget b: Work) throws -> Member {
            let s = try bottom.inspect(fd)
            guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == bottom.uid, s.st_mode & 0o7777 == 0o600, s.st_nlink == 1,
                s.st_size >= 0, s.st_size <= cap, s.st_flags & 0x4000_0000 == 0, s.st_dev == registered?.device,
                try bottom.denyACLCount(fd,maximum:0,check:{try b.checkTime()}) == 0, try !bottom.finderAlias(fd) else { throw Failure.changed }
            return Member(s)
        }
        private func namedMatch(_ name: String, _ member: Member) throws {
            guard let named = try bottom.named(parent:directory,name:name), member.matches(named) else { throw Failure.changed }
        }
        func validate(_ b: Work, retirementOnly: Bool = false) throws {
            try b.charge(v:1); try bottom.checkpoint("binding",name:nil); try validateBody(b,retirementOnly:retirementOnly)
        }
        private func validateBody(_ b: Work, retirementOnly: Bool = false) throws {
            guard !poisoned, let registered, !base.isEmpty else { throw Failure.unavailable }
            let rootInfo = try directoryInfo(directory,privateRoot:true,strictParent:false,budget:b)
            guard Identity(rootInfo) == registered else { throw Failure.changed }; protectionUID = rootInfo.st_uid
            for (i,binding) in bindings.enumerated() {
                let held = try directoryInfo(binding.fd,privateRoot:i == bindings.count-1,strictParent:i == bindings.count-2,budget:b)
                guard Identity(held) == binding.identity, let named = try bottom.named(parent:binding.parent,name:binding.name), Identity(named) == binding.identity, named.st_mode & S_IFMT == S_IFDIR else { throw Failure.changed }
            }
            if retirementOnly { guard try bottom.named(parent:directory,name:"lock") == nil else { throw Failure.changed }; return }
            guard let token = lockToken, let lockMember, try fileInfo(token.fd,cap:0,budget:b) == lockMember else { throw Failure.changed }
            try namedMatch("lock",lockMember); try b.checkTime()
        }
        /// Noncreating recovery may retire a verified empty root left after lock unlink.
        /// Admission still never adopts an existing root.
        func acquire(create: Bool, recoveringEmpty: Bool = false, _ b: Work) throws -> Bool {
            registryDomain = bottom.registryDomain
            b.path = 3072; try b.charge(v:1,f:33); try bottom.checkpoint("cold-acquire",name:nil)
            guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost", root.query == nil, root.fragment == nil,
                root.path.utf8.count <= 4096, !root.path.utf8.contains(0), root.path.hasPrefix("/") else { throw Failure.bounds }
            let parts = root.path.split(separator:"/").map(String.init)
            guard !parts.isEmpty, parts.count <= profile.pathComponents, !parts.contains("."), !parts.contains("..") else { throw Failure.bounds }
            var parent = try acquired(bottom.open(parent:nil,name:"/",mode:.directory),base:true,b).fd, rootCreated = false
            for (i,name) in parts.enumerated() {
                let child: Int32
                do { child = try bottom.open(parent:parent,name:name,mode:.directory) }
                catch MeetingStorageFault.missing {
                    if !create {
                        retireBase(b)
                        guard !poisoned,!unavailable else { throw Failure.uncertain }
                        return false
                    }
                    guard i >= parts.count-2 else { throw Failure.unavailable }; _ = try directoryInfo(parent,privateRoot:false,strictParent:true,budget:b)
                    try checkpoint("mkdir-and-sync",name:name,fixed:38,b); b.mutated = true; try bottom.mkdir(parent:parent,name:name)
                    child = try bottom.open(parent:parent,name:name,mode:.directory)
                    _ = try acquired(child,base:true,b); b.syncAttempts += 1; try bottom.sync(child); b.syncAttempts += 1; try bottom.sync(parent)
                    let s = try directoryInfo(child,privateRoot:i == parts.count-1,strictParent:i == parts.count-2,budget:b)
                    bindings.append(.init(parent:parent,fd:child,name:name,identity:Identity(s))); parent = child
                    if i == parts.count-1 { rootCreated = true }; continue
                }
                _ = try acquired(child,base:true,b)
                let s = try directoryInfo(child,privateRoot:i == parts.count-1,strictParent:i == parts.count-2,budget:b)
                bindings.append(.init(parent:parent,fd:child,name:name,identity:Identity(s))); parent = child
            }
            try bottom.excludeFromBackup(directory)
            let key = Identity(try directoryInfo(directory,privateRoot:true,strictParent:false,budget:b))
            guard SelfRegistry.insert(key,domain:registryDomain!) else { throw Failure.contended }; registered = key; try bottom.checkpoint("root-registered",name:nil)
            if create { guard rootCreated else { throw Failure.unknown }; holdLock.withLock { revoked = false; quit = false; outputRevoked = false } }
            if rootCreated { b.mutated = true }
            if !create,recoveringEmpty,try bottom.named(parent:directory,name:"lock") == nil {
                // No payload or lock may be inferred from missing authority. rmdir also
                // refuses any content appearing after this bounded, no-follow audit.
                guard try names(b).isEmpty else { throw Failure.unknown }
                try finalClose(b); return false
            }
            let fd = try bottom.open(parent:directory,name:"lock",mode:rootCreated ? .exclusive : .write)
            _ = try acquired(fd,base:false,isLock:true,b)
            try bottom.checkpoint("lock-open-before-classification",name:"lock"); lockMember = try fileInfo(fd,cap:0,budget:b)
            try bottom.checkpoint("lock-classified-before-flock",name:"lock"); try bottom.flock(fd); try bottom.checkpoint("flock-acquired",name:"lock")
            try validateBody(b); return true
        }
        func names(_ b: Work) throws -> Set<String> {
            try b.charge(e:1); try bottom.checkpoint("enumerate",name:nil)
            let owned = try acquired(bottom.duplicate(directory),base:false,b)
            try bottom.makeStream(owned.fd)
            guard let i = temporary.firstIndex(where:{$0.token == owned.token}) else { throw Failure.uncertain }; temporary[i].stream = true
            let stream = temporary[i]; try bottom.checkpoint("fdopendir-transfer",name:nil)
            var names = Set<String>(), folded = Set<String>(), iterations = 0
            while true {
                try b.checkTime(); guard let name = try bottom.nextName(stream.fd) else { break }
                iterations += 1; guard iterations <= 514 else { throw Failure.bounds }
                if name == "." || name == ".." { continue }
                guard names.count < profile.members, SavedAudioImportStorage.validName(name), names.insert(name).inserted, folded.insert(name.lowercased()).inserted else { throw Failure.unknown }
            }
            try consume(stream,b); return names
        }
        func create(_ name: String, cap: Int64, _ b: Work) throws -> (Owned,Member) {
            try checkpoint("exclusive-create",name:name,fixed:46,b); try validate(b)
            guard SavedAudioImportStorage.validName(name) else { throw Failure.unknown }
            b.mutated = true
            let token = try acquired(bottom.open(parent:directory,name:name,mode:.exclusive),base:false,b)
            let m = try fileInfo(token.fd,cap:cap,budget:b); try namedMatch(name,m); guard m.bytes == 0 else { throw Failure.changed }
            try bottom.checkpoint("created",name:name); return (token,m)
        }
        func writeOpen(_ name: String, member: Member, cap: Int64, _ b: Work) throws -> Owned {
            try checkpoint("write-open",name:name,fixed:29,b); try validate(b); try namedMatch(name,member)
            let token = try acquired(bottom.open(parent:directory,name:name,mode:.write),base:false,b)
            guard try fileInfo(token.fd,cap:cap,budget:b) == member else { throw Failure.changed }; return token
        }
        func write(_ bytes: Data, token: Owned, name: String, registered member: Member, metadata: Bool, authorized: () throws -> Void, _ b: Work) throws -> String {
            var offset = 0
            while offset < bytes.count {
                // Full primitive precharge precedes every interior fault edge, including the space query.
                try b.charge(v:1,f:49)
                try bottom.checkpoint("free-space",name:name)
                let sum = try MeetingSession.add(Int64(536_870_912),MeetingSession.reservation)
                guard try bottom.freeBytes(directory) >= sum else { throw Failure.space }
                try bottom.checkpoint("write",name:name); try bottom.checkpoint("binding",name:nil)
                try validateBody(b); try authorized()
                let current = try fileInfo(token.fd,cap:Int64(bytes.count),budget:b); guard current.sameBirth(member) else { throw Failure.changed }; try namedMatch(name,current)
                let count = min(metadata ? profile.metadata : 65_536,bytes.count-offset)
                do {
                    b.mutated = true
                    try b.checkTime()
                    let n = try bottom.write(token.fd,bytes:bytes.subdata(in:offset..<offset+count))
                    try b.charge(io:1); guard n > 0, n <= count else { throw Failure.io }; offset += n
                } catch MeetingStorageFault.interrupted { try b.charge(interrupt:true); try b.charge(); continue }
            }
            try checkpoint("input-hash",name:name,fixed:17,b); try b.hashed(bytes.count); return SavedAudioImportStorage.digest(bytes)
        }
        func syncClose(_ token: Owned, name: String, registered: Member, cap: Int64, authorized: () throws -> Void, _ b: Work) throws -> Member {
            try checkpoint("file-sync",name:name,fixed:28,b); try validate(b); try authorized()
            let m = try fileInfo(token.fd,cap:cap,budget:b); guard m.sameBirth(registered) else { throw Failure.changed }; try namedMatch(name,m)
            b.syncAttempts += 1; try bottom.sync(token.fd); try consume(token,b); return m
        }
        func read(_ name: String, expected: Member?, cap: Int64, hash: String?, collect: Bool, authorized: () throws -> Void, _ b: Work) throws -> (Member,Data) {
            try checkpoint("read-open",name:name,fixed:29,b); try validate(b); try authorized()
            guard SavedAudioImportStorage.validName(name), let before = try bottom.named(parent:directory,name:name) else { throw Failure.changed }
            let token = try acquired(bottom.open(parent:directory,name:name,mode:.read),base:false,b)
            let m = try fileInfo(token.fd,cap:cap,budget:b); guard m.matches(before), expected == nil || expected == m else { throw Failure.changed }
            var data = Data(), digest = SHA256(), total: Int64 = 0
            while true {
                try b.charge(f:1,io:1); try authorized()
                do {
                    let amount = Int(min(65_536,try MeetingSession.add(cap-total,1)))
                    let bytes = try bottom.read(token.fd,maximum:amount); guard bytes.count <= amount else { throw Failure.io }
                    if bytes.isEmpty { break }; total = try MeetingSession.add(total,Int64(bytes.count)); guard total <= cap else { throw Failure.bounds }
                    digest.update(data:bytes); if collect { data.append(bytes) }
                } catch MeetingStorageFault.interrupted { try b.charge(interrupt:true); try b.charge(); continue }
            }
            try checkpoint("read-hash-end",name:name,fixed:27,b)
            guard total == m.bytes, try fileInfo(token.fd,cap:cap,budget:b) == m else { throw Failure.changed }; try namedMatch(name,m)
            try b.hashed(Int(total))
            let actual = digest.finalize().map { String(format:"%02x",$0) }.joined(); if let hash { guard actual == hash else { throw Failure.changed } }
            try validate(b); try consume(token,b); return (m,data)
        }
        func rename(_ from: String, member: Member, to: String, replacing: Member?, authorized: () throws -> Void, _ b: Work) throws -> Member {
            try checkpoint("rename",name:from,fixed:replacing == nil ? 59 : 69,b); try validate(b); try authorized()
            let source = try acquired(bottom.open(parent:directory,name:from,mode:.read),base:false,b)
            guard try fileInfo(source.fd,cap:member.bytes,budget:b) == member else { throw Failure.changed }; try namedMatch(from,member)
            if let replacing {
                guard to == "manifest.json", replacing.bytes <= profile.metadata else { throw Failure.changed }
                let target = try acquired(bottom.open(parent:directory,name:to,mode:.read),base:false,b)
                guard try fileInfo(target.fd,cap:Int64(profile.metadata),budget:b) == replacing else { throw Failure.changed }; try namedMatch(to,replacing)
                try b.checkTime(); b.mutated = true; try bottom.rename(parent:directory,from:from,to:to)
                let changed = try fileInfo(source.fd,cap:member.bytes,budget:b); guard changed.renamedFrom(member) else { throw Failure.changed }; try namedMatch(to,changed)
                b.syncAttempts += 1; try bottom.sync(directory); b.publications += 1; try consume(target,b); try consume(source,b); return changed
            }
            guard try bottom.named(parent:directory,name:to) == nil else { throw Failure.changed }
            try b.checkTime(); b.mutated = true; try bottom.rename(parent:directory,from:from,to:to)
            let changed = try fileInfo(source.fd,cap:member.bytes,budget:b); guard changed.renamedFrom(member) else { throw Failure.changed }; try namedMatch(to,changed)
            b.syncAttempts += 1; try bottom.sync(directory); if to == "manifest.json" { b.publications += 1 }; try consume(source,b); return changed
        }
        func inspect(_ name: String, cap: Int64, _ b: Work) throws -> Member {
            try checkpoint("inspect-member",name:name,fixed:29,b); try validate(b)
            guard SavedAudioImportStorage.validName(name) else { throw Failure.unknown }
            let token = try acquired(bottom.open(parent:directory,name:name,mode:.read),base:false,b)
            let member = try fileInfo(token.fd,cap:cap,budget:b)
            try namedMatch(name,member); try consume(token,b); return member
        }
        func unlink(_ name: String, member: Member, cap: Int64, exact: Bool, missingAllowed: Bool, _ b: Work) throws {
            try checkpoint("unlink",name:name,fixed:32,b); try validate(b)
            guard borrowed?.member.sameBirth(member) != true else { throw MeetingSession.Failure.held }
            guard let named = try bottom.named(parent:directory,name:name) else { guard missingAllowed else { throw Failure.changed }; return }
            let token = try acquired(bottom.open(parent:directory,name:name,mode:.read),base:false,b), current = try fileInfo(token.fd,cap:cap,budget:b)
            guard current.matches(named), exact ? current == member : current.sameBirth(member) else { throw Failure.changed }
            try namedMatch(name,current); try b.checkTime(); b.mutated = true; try bottom.unlink(parent:directory,name:name,directory:false); try consume(token,b)
        }
        func syncDirectory(_ b: Work) throws { try checkpoint("directory-sync",name:nil,fixed:18,b); b.syncAttempts += 1; try bottom.sync(directory) }
        func borrow(_ name: String, member: Member, generation: UInt64, _ b: Work) throws -> Token {
            guard borrowed == nil else { throw MeetingSession.Failure.held }
            try checkpoint("borrow-open",name:name,fixed:29,b); try validate(b); try namedMatch(name,member)
            let owned = try acquired(bottom.open(parent:directory,name:name,mode:.read),base:false,b)
            guard try fileInfo(owned.fd,cap:member.bytes,budget:b) == member else { throw Failure.changed }
            try checkpoint("borrow-transfer",name:name,fixed:34,b)
            temporary.removeAll { $0.token == owned.token }; borrowed = .init(owned:owned,member:member,name:name,generation:generation)
            try bottom.checkpoint("borrow-registered-before-receipt",name:name); return owned.token
        }
        func release(_ token: Token, _ b: Work) throws {
            guard let owned = borrowed?.owned, owned.token == token else { throw Failure.changed }
            // This matching actual-exit path is legal even under quarantine. No authorization IO or pre-close budget check.
            b.fixed += 17; try consume(owned,b); try bottom.checkpoint("before-outward-receipt",name:nil); active = false
        }
        func detach(_ b: Work) throws {
            guard drained, !poisoned else { throw MeetingSession.Failure.held }; try checkpoint("detach",name:nil,fixed:34,b)
            retireBase(b); guard !poisoned else { throw Failure.uncertain }; active = false
        }
        func unlinkLock(_ b: Work) throws {
            guard let lockMember else { throw Failure.changed }
            try unlink("lock",member:lockMember,cap:0,exact:true,missingAllowed:false,b)
        }
        func finalClose(_ b: Work) throws {
            guard drained, !poisoned else { throw MeetingSession.Failure.held }
            try checkpoint("retirement-guard",name:nil,fixed:36,b); try validate(b,retirementOnly:true)
            guard let binding = bindings.last else { throw Failure.changed }
            try checkpoint("rmdir-parent-sync",name:binding.name,fixed:20,b)
            try bottom.unlink(parent:binding.parent,name:binding.name,directory:true); b.syncAttempts += 1; try bottom.sync(binding.parent)
            retireBase(b); guard !poisoned else { throw Failure.uncertain }; active = false
        }
        func matchesBorrow(_ token: Token, member: Member) -> Bool { borrowed?.owned.token == token && borrowed?.member == member }
        func isBorrowed(_ member: Member) -> Bool { borrowed?.member.sameBirth(member) == true }
    }
}
