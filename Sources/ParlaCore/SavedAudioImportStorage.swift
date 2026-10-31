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
            case .contended: return "Saved imports are in use by another owner."
            case .unknown: return "Saved storage is unrecognized or incomplete. Its files have been preserved."
            case .bounds: return "Saved storage reached a supported limit. No other saved job was removed."
            case .clock: return "The clock could not be validated. Saved imports are unavailable."
            case .space: return "Saved imports need 512 MiB of free space plus space reserved for this write."
            case .revoked: return "This saved action is no longer current."
            case .uncertain: return "Saved storage could not confirm a write or deletion. Private files may remain."
            case .changed: return "Saved storage changed. Its files have been preserved."
            case .io, .unavailable: return "Saved storage is unavailable. Its files have been preserved."
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
        for suffix in [".source.pending", ".source.wav", ".result.pending", ".raw.txt", ".delete"] where name.hasSuffix(suffix) {
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
