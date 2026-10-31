import Darwin
import Foundation
import XCTest
@testable import ParlaCore

/// Every path below is new, synthetic and receipt-owned. Never inspect the
/// application's default namespace, preferences, cache or historical fixtures.
final class SavedImportFixture {
    let parent: URL, root: URL
    let identity: SavedAudioImportStorage.Identity
    init() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent("wave7e1-storage-\(UUID().uuidString.lowercased())")
        guard mkdir(parent.path, 0o700) == 0 else { throw SavedAudioImportStorage.Failure.io }
        root = parent.appendingPathComponent("saved-imports")
        var s = stat(); guard lstat(parent.path, &s) == 0 else { throw SavedAudioImportStorage.Failure.io }
        identity = .init(device: s.st_dev, inode: s.st_ino)
        try receipt("created"); try receipt("identity")
    }
    func receipt(_ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { throw SavedAudioImportStorage.Failure.unavailable }
        var s = stat(); guard lstat(parent.path, &s) == 0, s.st_ino == identity.inode, s.st_dev == identity.device else { throw SavedAudioImportStorage.Failure.changed }
        var data = try JSONSerialization.data(withJSONObject: ["path": parent.path,"action":action,"pid":getpid(),"uid":s.st_uid,
            "inode":s.st_ino,"device":s.st_dev,"mode":s.st_mode,"birthSec":s.st_birthtimespec.tv_sec,"birthNS":s.st_birthtimespec.tv_nsec,
            "mtimeSec":s.st_mtimespec.tv_sec,"mtimeNS":s.st_mtimespec.tv_nsec], options:[.sortedKeys]); data.append(10)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf:data)
    }
    func closed() throws { try receipt("closed") }
    func storage(system: SavedAudioImportStorage.System = .init()) -> SavedAudioImportStorage { .init(root: root, system: system) }
}

final class SavedAudioImportStorageTests: XCTestCase {
    func testACLBottomOnOwnedFixture() throws {
        let fixture = try SavedImportFixture()
        let fd = Darwin.open(fixture.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        errno = 0
        let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        print("wave7e1 owned fixture ACL returned=\(acl != nil) errno=\(errno)")
        if let acl {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?; errno = 0
            let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            print("wave7e1 owned fixture first ACL entry result=\(result) errno=\(errno) entry=\(entry != nil)")
        }
        try fixture.closed()
    }

    func testAbsentBootstrapDoesNotCreateNamespace() throws {
        let fixture = try SavedImportFixture(), storage = fixture.storage(), store = SavedAudioImportStore(storage: storage)
        XCTAssertTrue(try store.bootstrap().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertTrue(try store.protection().identities.isEmpty)
        try store.close(); try fixture.closed()
    }
    func testExclusiveLockAndIndependentDescriptorPublication() throws {
        let fixture = try SavedImportFixture(), first = fixture.storage()
        let budget = first.budget(); XCTAssertTrue(try first.open(create: true, budget: budget))
        let second = fixture.storage()
        XCTAssertThrowsError(try second.open(create: true, budget: second.budget()))
        let name = UUID().uuidString.lowercased() + ".source.pending", bytes = Data("synthetic only".utf8)
        let (fd, member) = try first.create(name, cap: 100, budget: budget)
        let written = try first.write(bytes, fd: fd, name: name, allocated: member, remaining: 100, authorized: { true }, budget: budget)
        XCTAssertEqual(try first.read(name, expected: written, cap: 100, expectedHash: SavedAudioImportStorage.digest(bytes), payload: true, budget: budget), bytes)
        try first.close(); try second.close(); try fixture.closed()
    }
    func testShortWritesAndInterruptedWritesUseTheRealDescriptor() throws {
        let fixture = try SavedImportFixture(); var calls = 0
        var system = SavedAudioImportStorage.System()
        system.write = { fd, bytes, count in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return Darwin.write(fd, bytes, min(3,count))
        }
        let storage = fixture.storage(system: system), b = storage.budget()
        XCTAssertTrue(try storage.open(create: true, budget: b))
        let name = UUID().uuidString.lowercased() + ".source.pending", bytes = Data(repeating: 42,count: 97)
        let (fd, allocated) = try storage.create(name, cap: 100, budget: b)
        let member = try storage.write(bytes, fd: fd, name: name, allocated: allocated, remaining: 100, authorized: { true }, budget: b)
        XCTAssertGreaterThan(calls, 30)
        XCTAssertEqual(try storage.read(name, expected: member, cap: 100, payload: true, budget: b), bytes)
        try storage.close(); try fixture.closed()
    }
    func testZeroProgressAndCloseFailureNeverAcknowledgeSaved() throws {
        for closeFailure in [false,true] {
            let fixture = try SavedImportFixture(); var system = SavedAudioImportStorage.System()
            if closeFailure { system.close = { fd in _ = Darwin.close(fd); errno = EIO; return -1 } }
            else { system.write = { _,_,_ in 0 } }
            let storage = fixture.storage(system: system), b = storage.budget()
            XCTAssertTrue(try storage.open(create: true, budget: b))
            let name = UUID().uuidString.lowercased() + ".source.pending"
            let (fd, allocated) = try storage.create(name, cap: 10, budget: b)
            XCTAssertThrowsError(try storage.write(Data([1]), fd: fd, name: name, allocated: allocated, remaining: 10, authorized: { true }, budget: b))
            if closeFailure { XCTAssertThrowsError(try storage.close()); try fixture.receipt("close-uncertain") }
            else { try storage.close(); try fixture.closed() }
        }
    }
    func testOwnedMemberHardlinkIsRefusedAndBothNamesPreserved() throws {
        let fixture = try SavedImportFixture(), storage = fixture.storage(), b = storage.budget()
        XCTAssertTrue(try storage.open(create: true, budget: b))
        let name = UUID().uuidString.lowercased() + ".source.pending"
        let (fd, allocation) = try storage.create(name, cap: 100, budget: b)
        let member = try storage.write(Data([1,2,3]), fd: fd, name: name, allocated: allocation, remaining: 100, authorized: { true }, budget: b)
        let alias = fixture.parent.appendingPathComponent("owned-hardlink")
        XCTAssertEqual(link(fixture.root.appendingPathComponent(name).path,alias.path),0)
        XCTAssertThrowsError(try storage.unlink(name, member: member,budget:b))
        XCTAssertEqual(try Data(contentsOf:alias),Data([1,2,3]))
        try storage.close(); try fixture.closed() // alias deliberately preserved for external safe classification
    }
}


extension SavedAudioImportStorageTests {
    func testEntryLimitRefusesTheSixtyFifthWithoutSweeping() throws {
        let fixture = try SavedImportFixture(), storage = fixture.storage()
        XCTAssertTrue(try storage.open(create:true,budget:storage.budget()))
        for _ in 0..<63 {
            let path = fixture.root.appendingPathComponent(UUID().uuidString.lowercased()+".source.pending").path
            let fd = Darwin.open(path,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
            XCTAssertGreaterThanOrEqual(fd,0); XCTAssertEqual(Darwin.close(fd),0)
        }
        XCTAssertEqual(try storage.enumerate(storage.budget()).count,64)
        let last = fixture.root.appendingPathComponent(UUID().uuidString.lowercased()+".source.pending")
        let fd = Darwin.open(last.path,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        XCTAssertGreaterThanOrEqual(fd,0); XCTAssertEqual(Darwin.close(fd),0)
        XCTAssertThrowsError(try storage.enumerate(storage.budget()))
        XCTAssertEqual(try Data(contentsOf:last),Data())
        try storage.close(); try fixture.closed()
    }
    func testCooperatingProcessCannotAcquireLifetimeLock() throws {
        let fixture = try SavedImportFixture(), storage = fixture.storage()
        XCTAssertTrue(try storage.open(create:true,budget:storage.budget()))
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-B","-c", "import os,fcntl,sys\nfd=os.open(sys.argv[1],os.O_RDWR|os.O_NOFOLLOW)\ntry: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: os.close(fd); sys.exit(0)\nos.close(fd); sys.exit(3)",fixture.root.appendingPathComponent("lock").path]
        try process.run(); process.waitUntilExit()
        print("wave7e1 cooperating-lock child pid=\(process.processIdentifier) waited raw exit=\(process.terminationStatus)")
        XCTAssertEqual(process.terminationStatus,0)
        try storage.close(); try fixture.closed()
    }
    func testInterruptAndCooperativeBudgetsAreFinite() throws {
        for clockBudget in [false,true] {
            let fixture = try SavedImportFixture(); var tick:TimeInterval = 0, calls = 0
            var system = SavedAudioImportStorage.System(); system.uptime = {tick}
            system.write = {_,_,_ in calls += 1; errno = EINTR; return -1}
            if clockBudget { system.checkpoint = { if $0 == .write {tick = 31} } }
            let storage = fixture.storage(system:system), budget = storage.budget()
            XCTAssertTrue(try storage.open(create:true,budget:budget))
            let name = UUID().uuidString.lowercased()+".source.pending"
            let (fd,member) = try storage.create(name,cap:10,budget:budget)
            XCTAssertThrowsError(try storage.write(Data([1]),fd:fd,name:name,allocated:member,remaining:10,authorized:{true},budget:budget))
            XCTAssertLessThanOrEqual(calls,129)
            try storage.close(); try fixture.closed()
        }
    }
}


extension SavedAudioImportStorageTests {
    func testExistingEmptyRootIsNotAdoptedAndDirectoryCloseFailureIsUncertain() throws {
        let fixture = try SavedImportFixture()
        XCTAssertEqual(mkdir(fixture.root.path,0o700),0)
        let storage = fixture.storage()
        XCTAssertThrowsError(try storage.open(create:true,budget:storage.budget()))
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("lock").path))
        try storage.close(); try fixture.closed()
        let fault = try SavedImportFixture(); var system = SavedAudioImportStorage.System(), once = true
        system.closeDirectory = {stream in
            let result = Darwin.closedir(stream)
            if once {once = false; errno = EIO; return -1}; return result
        }
        let uncertain = fault.storage(system:system)
        XCTAssertThrowsError(try uncertain.open(create:true,budget:uncertain.budget()))
        XCTAssertThrowsError(try uncertain.close())
        try fault.receipt("close-uncertain")
    }
    func testUnlinkRechecksAReplacementAfterTheFaultCheckpoint() throws {
        let fixture = try SavedImportFixture(); var replace = false
        let name = UUID().uuidString.lowercased()+".source.pending", url = fixture.root.appendingPathComponent(name)
        var system = SavedAudioImportStorage.System()
        system.checkpoint = {boundary in
            if replace && boundary == .unlink {
                replace = false
                XCTAssertEqual(Darwin.unlink(url.path),0)
                let fd = Darwin.open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
                XCTAssertGreaterThanOrEqual(fd,0); XCTAssertEqual(Darwin.write(fd,[UInt8(99)],1),1); XCTAssertEqual(Darwin.close(fd),0)
            }
        }
        let storage = fixture.storage(system:system), b = storage.budget()
        XCTAssertTrue(try storage.open(create:true,budget:b))
        let (fd,allocated) = try storage.create(name,cap:10,budget:b)
        let member = try storage.write(Data([1,2]),fd:fd,name:name,allocated:allocated,remaining:10,authorized:{true},budget:b)
        replace = true
        XCTAssertThrowsError(try storage.unlink(name,member:member,budget:b))
        XCTAssertEqual(try Data(contentsOf:url),Data([99]))
        try storage.close(); try fixture.closed()
    }
}

extension SavedAudioImportStorageTests {
    func testHeadroomExactBoundaryUnknownSpaceAndOverflowBeforeWrite() throws {
        let fixture = try SavedImportFixture(); var available = Int64.max, fail = false
        var system = SavedAudioImportStorage.System()
        system.freeBytes = {_ in if fail {throw SavedAudioImportStorage.Failure.space}; return available}
        let storage = fixture.storage(system:system), budget = storage.budget()
        XCTAssertTrue(try storage.open(create:true,budget:budget))
        available = 536_870_912+123
        XCTAssertNoThrow(try storage.requireSpace(123,budget:budget))
        XCTAssertThrowsError(try storage.requireSpace(124,budget:budget))
        XCTAssertThrowsError(try storage.requireSpace(Int64.max,budget:budget))
        XCTAssertThrowsError(try storage.requireSpace(-1,budget:budget))
        fail = true; XCTAssertThrowsError(try storage.requireSpace(0,budget:budget))
        try storage.close(); try fixture.closed()
        // Legitimate maximum coexistence stays under the policy quota; no cap is
        // lowered or enormous fixture written merely to manufacture cap+1.
        let plannedPeak: Int64 = 10*20_971_520 + 11*1_048_576 + 2*65_536 + 4096 + 10*4096
        XCTAssertEqual(plannedPeak,221_425_664); XCTAssertLessThan(plannedPeak,SavedAudioImportStore.quota)
    }
    func testParentRootModeAndMemberGenerationChangesRefuseWithoutRepair() throws {
        for mutation in 0..<5 {
            let fixture = try SavedImportFixture(), storage = fixture.storage(), budget = storage.budget()
            XCTAssertTrue(try storage.open(create:true,budget:budget))
            let name = UUID().uuidString.lowercased()+".source.pending"
            let (fd,allocated) = try storage.create(name,cap:100,budget:budget)
            let member = try storage.write(Data([3,7,11]),fd:fd,name:name,allocated:allocated,remaining:100,authorized:{true},budget:budget)
            let moved = fixture.parent.appendingPathComponent("moved")
            switch mutation {
            case 0: XCTAssertEqual(chmod(fixture.parent.path,0o777),0)
            case 1: XCTAssertEqual(chmod(fixture.root.path,0o755),0)
            case 2: XCTAssertEqual(rename(fixture.root.path,moved.path),0); XCTAssertEqual(mkdir(fixture.root.path,0o700),0)
            case 3: XCTAssertEqual(chmod(fixture.root.appendingPathComponent(name).path,0o644),0)
            default:
                let path = fixture.root.appendingPathComponent(name)
                XCTAssertEqual(rename(path.path,moved.path),0)
                try Data([3,7,11]).write(to:path); XCTAssertEqual(chmod(path.path,0o600),0)
            }
            if mutation < 3 {XCTAssertThrowsError(try storage.validate(budget))}
            else {XCTAssertThrowsError(try storage.read(name,expected:member,cap:100,payload:true,budget:budget))}
            try storage.close(); try fixture.closed()
        }
    }
}

extension SavedAudioImportStorageTests {
    func testFinderAliasMarkerIsRefusedOnAnOtherwiseValidPrivateMember() throws {
        let fixture = try SavedImportFixture(), storage = fixture.storage(), budget = storage.budget()
        XCTAssertTrue(try storage.open(create:true,budget:budget))
        let name = UUID().uuidString.lowercased()+".source.pending"
        let (fd,_) = try storage.create(name,cap:16,budget:budget)
        XCTAssertNotNil(try storage.named(name,cap:16,budget:budget))
        var finder = [UInt8](repeating:0,count:32); finder[8] = 0x80
        XCTAssertEqual(finder.withUnsafeBytes {fsetxattr(fd,"com.apple.FinderInfo",$0.baseAddress,$0.count,0,0)},0)
        XCTAssertEqual(Darwin.close(fd),0)
        XCTAssertThrowsError(try storage.named(name,cap:16,budget:budget))
        try storage.close(); try fixture.closed()
    }
    func testOwnedACLClassificationAllowsDenyOnlyParentAndRefusesPrivateGrantWithoutRepair() throws {
        for privateGrant in [false,true] {
            let fixture = try SavedImportFixture(), storage = fixture.storage(), budget = storage.budget()
            XCTAssertTrue(try storage.open(create:true,budget:budget))
            let target = privateGrant ? fixture.root : fixture.parent
            let child = Process(); child.executableURL = URL(fileURLWithPath:"/bin/chmod")
            child.arguments = ["+a","everyone "+(privateGrant ? "allow read" : "deny delete"),target.path]
            try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus,0)
            print("owned ACL chmod child pid=\(child.processIdentifier) waited raw exit=\(child.terminationStatus)")
            if privateGrant {XCTAssertThrowsError(try storage.validate(budget))}
            else {XCTAssertNoThrow(try storage.validate(budget))}
            try storage.close(); try fixture.closed()
        }
    }
    func testActualReaddirErrorRefusesAndClosesItsStreamWithoutChangingMembers() throws {
        let fixture = try SavedImportFixture(); var armed = false, calls = 0
        var system = SavedAudioImportStorage.System()
        system.readDirectory = {stream in
            if armed {calls += 1; if calls == 3 {errno = EIO; return nil}}
            return Darwin.readdir(stream)
        }
        let storage = fixture.storage(system:system), budget = storage.budget()
        XCTAssertTrue(try storage.open(create:true,budget:budget))
        let before = try storage.enumerate(budget); armed = true
        XCTAssertThrowsError(try storage.enumerate(budget)) {XCTAssertEqual($0 as? SavedAudioImportStorage.Failure,.io)}
        XCTAssertEqual(calls,3); armed = false
        XCTAssertEqual(try storage.enumerate(budget),before)
        try storage.close(); try fixture.closed()
    }
}

extension SavedAudioImportStorageTests {
    func testBoundRootAndMemberUIDDeviceDatalessAndTypeClassificationRefuseInjectedConflicts() throws {
        for mutation in 0..<6 {
            let fixture = try SavedImportFixture(); var armed = false, target:UInt64 = 0
            var system = SavedAudioImportStorage.System()
            system.inspect = {fd,value in
                let result = Darwin.fstat(fd,value)
                if result == 0 && armed && value.pointee.st_ino == target {
                    switch mutation {
                    case 0,1: value.pointee.st_uid = geteuid()+1
                    case 2: value.pointee.st_dev += 1
                    case 3: value.pointee.st_flags |= 0x4000_0000
                    case 4: value.pointee.st_mode = (value.pointee.st_mode & 0o7777) | S_IFIFO
                    default: value.pointee.st_nlink = 2
                    }
                }
                return result
            }
            let storage = fixture.storage(system:system), budget = storage.budget()
            XCTAssertTrue(try storage.open(create:true,budget:budget))
            let name = UUID().uuidString.lowercased()+".source.pending"
            let (fd,allocated) = try storage.create(name,cap:10,budget:budget)
            let member = try storage.write(Data([7,11]),fd:fd,name:name,allocated:allocated,remaining:10,authorized:{true},budget:budget)
            XCTAssertEqual(try storage.named(name,cap:10,budget:budget),member)
            target = mutation == 0 ? try XCTUnwrap(storage.identity?.inode) : member.identity.inode; armed = true
            if mutation == 0 {XCTAssertThrowsError(try storage.validate(budget))}
            else {XCTAssertThrowsError(try storage.named(name,cap:10,budget:budget))}
            armed = false; XCTAssertEqual(try storage.named(name,cap:10,budget:budget),member)
            try storage.close(); try fixture.closed()
        }
    }
}

extension SavedAudioImportStorageTests {
    func testMeetingProfileDoesNotBroadenTheImportStaticGrammarOrMetadataDefault() throws {
        let profile = MeetingStorageProfile()
        XCTAssertEqual(profile.members,512); XCTAssertEqual(profile.metadata,524_288); XCTAssertEqual(profile.pathComponents,12)
        XCTAssertEqual(SavedAudioImportStore.maximumLedger,65_536)
        let id = "00000000-0000-0000-0000-000000000001"
        for suffix in [".source.pending",".source.wav",".result.pending",".raw.txt",".delete"] { XCTAssertTrue(SavedAudioImportStorage.validName(id+suffix)) }
        for name in ["../manifest.json","manifest.next/child","meeting.json",id+".scratch",id+".source.wav/extra",String(repeating:"x",count:64)+".raw.txt"] { XCTAssertFalse(SavedAudioImportStorage.validName(name)) }
        XCTAssertFalse(SavedAudioImportStorage.validName("ABCDEFAB-0000-0000-0000-000000000001.source.wav"))
    }
}
