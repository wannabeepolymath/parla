import Darwin
import Foundation
import XCTest
@testable import ParlaCore

/// Typed virtual descriptors, not physical descriptor/flock/durability evidence. Large bodies are recipes, never retained payloads.
final class MeetingVirtualBottom: MeetingStorageBottom {
    enum Cut: Error { case injected }
    final class Node {
        enum Body { case metadata(Data), source(Data,Int), raw(UInt8,Int) }
        var s = stat(), body: Body = .metadata(Data()), name: String, locked = false, privateRoot = false
        var children: [String:Node] = [:] { didSet { cachedDirectoryNames = nil } }
        private var cachedDirectoryNames: [String]?
        var directoryNames: [String] {
            if let names = cachedDirectoryNames { return names }
            let names = [".",".."] + children.keys.sorted()
            if children.count <= 512 { cachedDirectoryNames = names }
            return names
        }
        init(name: String, inode: UInt64, directory: Bool) {
            self.name = name; s.st_dev = 1; s.st_ino = inode; s.st_uid = 501; s.st_nlink = 1
            s.st_mode = directory ? mode_t(S_IFDIR | 0o700) : mode_t(S_IFREG | 0o600)
            s.st_birthtimespec.tv_sec = 1; s.st_mtimespec.tv_sec = 1; s.st_ctimespec.tv_sec = 1
        }
        var length: Int { switch body { case .metadata(let d):return d.count; case .source(_,let n),.raw(_,let n):return n } }
        func bytes(_ offset: Int, _ maximum: Int) -> Data {
            let n = min(maximum,max(0,length-offset))
            switch body {
            case .metadata(let d): return d.subdata(in:offset..<offset+n)
            case .raw(let c,_): return Data(repeating:c,count:n)
            case .source(let header,_):
                var data = Data(repeating:0,count:n)
                if offset < header.count { let end = min(header.count,offset+n); data.replaceSubrange(0..<end-offset,with:header[offset..<end]) }; return data
            }
        }
    }
    final class Descriptor { let node: Node; var position = 0, stream = false, flocked = false; init(_ node: Node) { self.node = node } }
    private static let counterLock = NSLock(); private static var counter: UInt64 = 100
    let registryScope = MeetingStorageContext()
    var registryDomain: MeetingRegistryDomain { .virtual(registryScope) }
    let uid: uid_t = 501, rootURL: URL, top: Node
    private var nextInode: UInt64, nextFD: Int32 = 100
    var descriptors: [Int32:Descriptor] = [:], rootNode: Node?
    var backupExclusions = 0
    func excludeFromBackup(_ fd: Int32) throws {
        guard descriptors[fd] != nil else { throw MeetingStorageFault.io }; backupExclusions += 1
    }
    var tick: TimeInterval = 0, space = Int64.max, ancestorACL = 0, writeLimit = Int.max, interruptWrites = false
    var closeFailureAt: Int?, closeCount = 0, closes: [Int32] = [], payloadReads = 0, writes = 0, calls = 0
    var events: [(String,String?)] = [], cut: Int?, advanceAtWrite = false
    init(depth: Int = 12) {
        let base = Self.counterLock.withLock { Self.counter += 1; return Self.counter * 1_000_000 }
        nextInode = base; top = Node(name:"/",inode:base,directory:true)
        let parts = (0..<depth-1).map { "p\($0)" } + ["meeting"]
        rootURL = URL(fileURLWithPath:"/"+parts.joined(separator:"/"),isDirectory:true)
        var node = top
        for name in parts.dropLast() { nextInode += 1; let child = Node(name:name,inode:nextInode,directory:true); node.children[name] = child; node = child }
    }
    func uptime() -> TimeInterval { tick }
    func checkpoint(_ operation: String, name: String?) throws {
        events.append((operation,name)); if advanceAtWrite && operation == "write" { tick += 31 }
        if events.count-1 == cut { throw Cut.injected }
    }
    func reset(cut: Int? = nil) { events.removeAll(); self.cut = cut }
    func open(parent: Int32?, name: String, mode: MeetingOpenMode) throws -> Int32 {
        calls += 1; let node: Node
        if let parent {
            guard let p = descriptors[parent]?.node else { throw MeetingStorageFault.io }
            if mode == .exclusive {
                guard p.children[name] == nil else { throw MeetingStorageFault.io }; nextInode += 1
                let child = Node(name:name,inode:nextInode,directory:false)
                if name.hasSuffix(".source.pending") { child.body = .source(Data(),0) }
                if name.hasSuffix(".result.pending") { child.body = .raw(81,0) }
                p.children[name] = child; node = child
            } else { guard let existing = p.children[name] else { throw MeetingStorageFault.missing }; node = existing }
        } else { guard name == "/",mode == .directory else { throw MeetingStorageFault.io }; node = top }
        nextFD += 1; descriptors[nextFD] = .init(node); return nextFD
    }
    func mkdir(parent: Int32, name: String) throws {
        calls += 1; guard let p = descriptors[parent]?.node,p.children[name] == nil else { throw MeetingStorageFault.io }
        nextInode += 1; let node = Node(name:name,inode:nextInode,directory:true); p.children[name] = node
        if name == "meeting" { node.privateRoot = true; rootNode = node }
    }
    func inspect(_ fd: Int32) throws -> stat { calls += 1; guard let node = descriptors[fd]?.node else { throw MeetingStorageFault.io }; return node.s }
    func named(parent: Int32, name: String) throws -> stat? { calls += 1; guard let p = descriptors[parent]?.node else { throw MeetingStorageFault.io }; return p.children[name]?.s }
    func volume(_ fd: Int32) throws -> MeetingVolume { calls += 1; guard descriptors[fd] != nil else { throw MeetingStorageFault.io }; return .init(local:true,name:"apfs") }
    func finderAlias(_ fd: Int32) throws -> Bool { calls += 1; guard descriptors[fd] != nil else { throw MeetingStorageFault.io }; return false }
    func denyACLCount(_ fd: Int32, maximum: Int, check: () throws -> Void) throws -> Int { calls += 1; guard let n = descriptors[fd]?.node else { throw MeetingStorageFault.io }; let count = n.s.st_mode & S_IFMT == S_IFDIR && !n.privateRoot ? ancestorACL : 0; guard count >= 0,count <= maximum else { throw MeetingStorageFault.io }; for _ in 0...count { try check() }; return count }
    func flock(_ fd: Int32) throws { calls += 1; guard let d = descriptors[fd],!d.node.locked else { throw SavedAudioImportStorage.Failure.contended }; d.node.locked = true; d.flocked = true }
    func duplicate(_ fd: Int32) throws -> Int32 { calls += 1; guard let d = descriptors[fd] else { throw MeetingStorageFault.io }; nextFD += 1; descriptors[nextFD] = .init(d.node); return nextFD }
    func makeStream(_ fd: Int32) throws { calls += 1; guard let d = descriptors[fd] else { throw MeetingStorageFault.io }; d.stream = true; d.position = 0 }
    func nextName(_ stream: Int32) throws -> String? {
        calls += 1; guard let d = descriptors[stream],d.stream else { throw MeetingStorageFault.io }
        let names = d.node.directoryNames; guard d.position < names.count else { return nil }; defer { d.position += 1 }; return names[d.position]
    }
    func closeStream(_ stream: Int32) throws { try close(stream) }
    func read(_ fd: Int32, maximum: Int) throws -> Data {
        calls += 1; guard let d = descriptors[fd],maximum <= 65_536 else { throw MeetingStorageFault.io }
        if d.node.name.hasSuffix(".wav") || d.node.name.hasSuffix(".pending") || d.node.name.hasSuffix(".raw.txt") { payloadReads += 1 }
        let bytes = d.node.bytes(d.position,maximum); d.position += bytes.count; return bytes
    }
    func write(_ fd: Int32, bytes: Data) throws -> Int {
        calls += 1; writes += 1; if interruptWrites { throw MeetingStorageFault.interrupted }
        guard let d = descriptors[fd],d.position == d.node.length else { throw MeetingStorageFault.io }
        let n = min(writeLimit,bytes.count), data = bytes.prefix(n)
        switch d.node.body {
        case .metadata(var prior): prior.append(data); d.node.body = .metadata(prior)
        case .raw(_,let count): let c = data.first ?? UInt8(81); guard data.allSatisfy({$0 == c}) else { throw MeetingStorageFault.io }; d.node.body = .raw(c,count+n)
        case .source(var header,let count):
            let headerCount = min(n,max(0,44-header.count)); header.append(data.prefix(headerCount))
            guard data.dropFirst(headerCount).allSatisfy({$0 == 0}) else { throw MeetingStorageFault.io }; d.node.body = .source(header,count+n)
        }
        d.position += n; d.node.s.st_size = off_t(d.node.length); d.node.s.st_mtimespec.tv_sec += 1; d.node.s.st_ctimespec.tv_sec += 1; return n
    }
    func freeBytes(_ fd: Int32) throws -> Int64 { calls += 1; guard descriptors[fd] != nil else { throw MeetingStorageFault.io }; return space }
    func sync(_ fd: Int32) throws { calls += 1; guard descriptors[fd] != nil else { throw MeetingStorageFault.io } }
    func rename(parent: Int32, from: String, to: String) throws {
        calls += 1; guard let p = descriptors[parent]?.node,let source = p.children.removeValue(forKey:from) else { throw MeetingStorageFault.io }
        p.children[to] = source; source.name = to; source.s.st_ctimespec.tv_sec += 1
    }
    func unlink(parent: Int32, name: String, directory: Bool) throws {
        calls += 1; guard let p = descriptors[parent]?.node,let child = p.children[name],!directory || child.children.isEmpty else { throw MeetingStorageFault.io }
        p.children.removeValue(forKey:name); child.s.st_nlink = 0; child.s.st_ctimespec.tv_sec += 1
    }
    func close(_ fd: Int32) throws {
        calls += 1; guard let d = descriptors.removeValue(forKey:fd) else { throw MeetingStorageFault.io }; if d.flocked { d.node.locked = false }
        closes.append(fd); closeCount += 1; if closeCount == closeFailureAt { throw MeetingStorageFault.io }
    }
    func add(_ name: String, data: Data = Data()) throws {
        guard let rootNode else { throw MeetingStorageFault.io }; nextInode += 1; let node = Node(name:name,inode:nextInode,directory:false); node.body = .metadata(data); node.s.st_size = off_t(data.count); rootNode.children[name] = node
    }
    var names: Set<String> { Set(rootNode?.children.keys.map { $0 } ?? []) }
    var metadata: Data { rootNode?.children["manifest.json"]?.bytes(0,524_288) ?? Data() }
}
func meetingWAV(_ frames: Int) -> Data {
    func le(_ n: Int,_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
    let size = frames*2
    var bytes = Data("RIFF".utf8)
    bytes.append(le(size+36,4))
    bytes.append(Data("WAVEfmt ".utf8))
    bytes.append(le(16,4))
    bytes.append(le(1,2))
    bytes.append(le(1,2))
    bytes.append(le(16_000,4))
    bytes.append(le(32_000,4))
    bytes.append(le(2,2))
    bytes.append(le(16,2))
    bytes.append(Data("data".utf8))
    bytes.append(le(size,4))
    bytes.append(Data(repeating:0,count:size))
    return bytes
}
final class MeetingVirtualRig {
    let bottom: MeetingVirtualBottom, store: MeetingSessionStore, session = meetingID(2)
    let selections: [MeetingSession.Selection], segments: [MeetingSession.Segment]
    var clock: Int64 = 1_000_000_000_000
    init(depth: Int = 12) {
        bottom = .init(depth:depth)
        let clock = MeetingTestClock(); self.testClock = clock
        store = .init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{clock.value})
        selections = [.init(instance:meetingID(3),kind:.microphone,label:"",generation:7),.init(instance:meetingID(4),kind:.selectedApplication,label:"",generation:9)]
        segments = (0..<2).map { .init(id:meetingID(UInt64(100+$0)),track:$0,generation:$0 == 0 ? 7 : 9,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:meetingID(UInt64(200+$0)),mapping:.validated),canonicalStart:0) }
    }
    let testClock: MeetingTestClock
    func admit() throws -> MeetingSessionStore.Receipt { try store.admit(owner:meetingID(1),session:session,selections:selections,segments:segments,authorized:{true}) }
    func input(_ n: Int, frames: Int = 480_000, start: UInt64? = nil, bytes: Data? = nil) throws -> MeetingSessionStore.ChunkInput {
        let track = n%2, offset = start ?? UInt64(n/2)*UInt64(frames)
        return try .init(session:session,source:selections[track].instance,id:meetingID(UInt64(1000+n)),generation:UInt64(n+1),track:track,sourceGeneration:selections[track].generation,segment:segments[track].id,sequence:UInt64(n/2),start:offset,frames:UInt64(frames),timing:.init(pts:Int64(offset),denominator:16_000,sample:offset,rate:16_000,epoch:segments[track].timing.epoch,mapping:.validated),bytes:bytes ?? meetingWAV(frames))
    }
    @discardableResult func seal(_ input: MeetingSessionStore.ChunkInput) throws -> MeetingSessionStore.Receipt {
        let a = try store.chunkA(input,authorized:{true}), b = try store.chunkB(a,bytes:input.bytes,authorized:{true}); return try store.chunkC(b,authorized:{true})
    }
    func stop() throws { _ = try store.terminal(reason:.normalStop,unknownMask:0,generation:1,holdEpoch:1,flags:0x7f,authorized:{true}) }
    func result(_ chunk: UUID, count: Int = 4096) throws -> MeetingSessionStore.Receipt {
        let token = try store.beginAttempt(chunk:chunk,requested:meetingProvenance(0,role:.requested),authorized:{true})
        let borrow = try store.borrow(token,authorized:{true}), input = try MeetingSessionStore.ResultInput(Data(repeating:81,count:count))
        let a = try store.resultReserve(token,borrow:borrow.0,input:input,observed:meetingProvenance(1,role:.observed),authorized:{true})
        let b = try store.resultWrite(a,bytes:input.bytes,authorized:{true}), c = try store.resultPromote(b,authorized:{true})
        try store.actualBorrowExit(borrow.0); return c
    }
}
final class MeetingTestClock: @unchecked Sendable { var value: Int64 = 1_000_000_000_000 }

final class MeetingSessionStoreTests: XCTestCase {
    func fits(_ r: MeetingSessionStore.Receipt, file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertLessThanOrEqual(r.cost.credits,65_536,file:file,line:line); XCTAssertLessThanOrEqual(r.cost.validates,32,file:file,line:line)
        XCTAssertLessThanOrEqual(r.cost.enumerations,2,file:file,line:line); XCTAssertLessThanOrEqual(r.cost.peak,17,file:file,line:line)
        XCTAssertLessThanOrEqual(r.cost.retirement,512,file:file,line:line); XCTAssertEqual(r.cost.carryIn+r.cost.opens,r.cost.closes+r.cost.carryOut,file:file,line:line)
        XCTAssertEqual(r.reservedBytes,232_581_440,file:file,line:line)
    }
    func testConstructorAndProjectionMakeZeroBottomOrClockCalls() throws {
        let bottom = MeetingVirtualBottom(); var clocks = 0
        let store = MeetingSessionStore(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{clocks += 1; return 0})
        XCTAssertEqual(store.projection,.idle); XCTAssertEqual(bottom.calls,0); XCTAssertTrue(bottom.events.isEmpty); XCTAssertEqual(clocks,0)
        XCTAssertEqual(try store.bootstrap(),.idle); XCTAssertNil(bottom.rootNode); XCTAssertTrue(bottom.descriptors.isEmpty)
    }
    func testFullVirtual240By240AndBothExtraPeaksWithoutPayloadAllocation() throws {
        let rig = MeetingVirtualRig(); rig.bottom.ancestorACL = 64; fits(try rig.admit()); let bytes = meetingWAV(480_000)
        for n in 0..<240 { fits(try rig.seal(rig.input(n,bytes:bytes))) }
        let names = rig.bottom.names; XCTAssertThrowsError(try rig.store.chunkA(rig.input(240,bytes:bytes),authorized:{true})); XCTAssertEqual(rig.bottom.names,names)
        try rig.stop()
        var first: MeetingSessionStore.Receipt?
        for n in 0..<240 { let r = try rig.result(meetingID(UInt64(1000+n))); fits(r); if n == 0 { first = r } }
        XCTAssertEqual(rig.store.projection.acceptedResults,240); XCTAssertEqual(rig.bottom.names.count,483)
        let replacement = try rig.result(meetingID(1000),count:65_536); fits(replacement); XCTAssertEqual(rig.bottom.names.count,484)
        XCTAssertNotEqual(first?.object,replacement.object)
        let before = rig.bottom.metadata
        XCTAssertThrowsError(try rig.store.beginAttempt(chunk:meetingID(1001),requested:meetingProvenance(0,role:.requested),authorized:{true}))
        XCTAssertEqual(rig.bottom.metadata,before)
        fits(try rig.store.resultRetire(authorized:{true})); XCTAssertEqual(rig.bottom.names.count,483)
        var deletion = try rig.store.deleteIntent(id:meetingID(90_000),terminalGeneration:1,holdEpoch:1,authorized:{true}); fits(deletion)
        XCTAssertEqual(deletion.deletionRemaining,480)
        for _ in 0..<240 { deletion = try rig.store.deleteSlice(deletion,authorized:{true}); fits(deletion) }
        XCTAssertEqual(deletion.deletionRemaining,0)
        let dead = try rig.store.deleteAuthority(deletion,authorized:{true}); fits(dead); fits(try rig.store.deleteClose(dead,authorized:{true}))
        XCTAssertEqual(rig.store.projection,.idle); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    func testABCReceiptsStaleRefusalTailAndSelectedHash() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); let input = try rig.input(0,frames:1), a = try rig.store.chunkA(input,authorized:{true})
        XCTAssertEqual(rig.bottom.rootNode?.children[MeetingSession.uuid(input.id)+".source.pending"]?.length,0)
        let b = try rig.store.chunkB(a,bytes:input.bytes,authorized:{true}); XCTAssertThrowsError(try rig.store.chunkB(a,bytes:input.bytes,authorized:{true}))
        let c = try rig.store.chunkC(b,authorized:{true}); fits(c); XCTAssertEqual(rig.store.projection.acknowledgedChunks,1)
        try rig.stop(); XCTAssertThrowsError(try rig.store.beginAttempt(chunk:input.id,requested:meetingProvenance(0,role:.requested),authorized:{true}))
        try rig.store.detach(); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    func testGuardedShortProgressInterruptSpaceAndClockRefusalsRemainCharged() throws {
        for mode in 0..<5 {
            let rig = MeetingVirtualRig(); _ = try rig.admit(); let input = try rig.input(0), a = try rig.store.chunkA(input,authorized:{true})
            switch mode { case 0:rig.bottom.writeLimit = 0; case 1:rig.bottom.writeLimit = 1; case 2:rig.bottom.interruptWrites = true; case 3:rig.bottom.space = 536_870_912+MeetingSession.reservation-1; default:rig.bottom.advanceAtWrite = true }
            XCTAssertThrowsError(try rig.store.chunkB(a,bytes:input.bytes,authorized:{true})); XCTAssertTrue(rig.store.projection.unavailable)
            XCTAssertEqual(rig.bottom.descriptors.count,14); XCTAssertEqual(rig.store.projection.acknowledgedChunks,0)
            rig.bottom.advanceAtWrite = false; rig.bottom.tick = 0; try rig.store.detach(); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
        }
        let rig = MeetingVirtualRig(); _ = try rig.admit(); let input = try rig.input(0)
        rig.bottom.space = 536_870_912+MeetingSession.reservation; fits(try rig.seal(input)); try rig.store.detach()
        let bottom = MeetingVirtualBottom(), budget = SavedAudioImportStorage.MeetingLease.Work(bottom,carry:0)
        for _ in 0..<128 { try budget.charge(interrupt:true) }; XCTAssertThrowsError(try budget.charge(interrupt:true)); XCTAssertEqual(budget.interrupts,128)
    }
    func testEveryActualABCCheckpointCutIncludingLaterChunkHasNoFalseSeal() throws {
        for prior in [0,2] {
            for phase in [0,1,2] {
                func prepared(_ cut: Int?) throws -> (MeetingVirtualRig,MeetingSessionStore.ChunkInput,MeetingSessionStore.Receipt?,MeetingSessionStore.Receipt?) {
                    let rig = MeetingVirtualRig(); _ = try rig.admit()
                    for n in 0..<prior { _ = try rig.seal(rig.input(n,frames:8000)) }
                    let input = try rig.input(prior,frames:8000)
                    let a = phase >= 1 ? try rig.store.chunkA(input,authorized:{true}) : nil
                    let b = phase >= 2 ? try rig.store.chunkB(a!,bytes:input.bytes,authorized:{true}) : nil
                    rig.bottom.reset(cut:cut); return (rig,input,a,b)
                }
                func invoke(_ setup: (MeetingVirtualRig,MeetingSessionStore.ChunkInput,MeetingSessionStore.Receipt?,MeetingSessionStore.Receipt?)) throws {
                    switch phase { case 0:_ = try setup.0.store.chunkA(setup.1,authorized:{true}); case 1:_ = try setup.0.store.chunkB(setup.2!,bytes:setup.1.bytes,authorized:{true}); default:_ = try setup.0.store.chunkC(setup.3!,authorized:{true}) }
                }
                let baseline = try prepared(nil); try invoke(baseline); let count = baseline.0.bottom.events.count; try baseline.0.store.detach()
                for cut in 0..<count {
                    let setup = try prepared(cut); XCTAssertThrowsError(try invoke(setup)); XCTAssertEqual(setup.0.store.projection.acknowledgedChunks,prior)
                    XCTAssertLessThanOrEqual(setup.0.bottom.descriptors.count,14); setup.0.bottom.cut = nil
                    do { try setup.0.store.detach() } catch { XCTAssertTrue(setup.0.store.projection.unavailable) }
                }
            }
        }
    }
    func testBorrowRetiresUnderQuarantineOnceAndActualHoldsFenceDeletion() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop()
        let token = try rig.store.beginAttempt(chunk:meetingID(1000),requested:meetingProvenance(0,role:.requested),authorized:{true}), selected = try rig.store.borrow(token,authorized:{true})
        let held = try rig.store.register(.output); rig.store.reserveQuit(); XCTAssertFalse(rig.store.shutdownReady); rig.store.cancelQuit(); XCTAssertFalse(rig.store.shutdownReady)
        rig.bottom.closeFailureAt = rig.bottom.closeCount+1
        XCTAssertThrowsError(try rig.store.cancelAttempt(token,authorized:{true}))
        let before = rig.bottom.descriptors.count; rig.bottom.closeFailureAt = nil
        try rig.store.actualBorrowExit(selected.0); XCTAssertEqual(rig.bottom.descriptors.count,before-1)
        XCTAssertThrowsError(try rig.store.actualBorrowExit(selected.0)); try rig.store.actualExit(held); XCTAssertThrowsError(try rig.store.actualExit(held))
        XCTAssertFalse(rig.store.shutdownReady); XCTAssertThrowsError(try rig.store.detach())
    }
    func testExpiryFixedDeadlinePriorResultAndMetadataOnlyReopen() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop(); let first = try rig.result(meetingID(1000))
        let token = try rig.store.beginAttempt(chunk:meetingID(1000),requested:meetingProvenance(0,role:.requested),authorized:{true}); _ = try rig.store.cancelAttempt(token,authorized:{true})
        XCTAssertEqual(try rig.store.readAccepted(session:rig.session,chunk:meetingID(1000),result:first.object!,authorized:{true}),Data(repeating:81,count:4096))
        try rig.store.detach(); rig.bottom.payloadReads = 0
        let reopened = MeetingSessionStore(root:rig.bottom.rootURL,profile:.init(),bottom:rig.bottom,wallClock:{rig.testClock.value})
        XCTAssertEqual(try reopened.bootstrap().acknowledgedChunks,1); XCTAssertEqual(rig.bottom.payloadReads,0)
        rig.testClock.value += MeetingSession.RecordingPolicy.transcriptRetention; try reopened.evaluate(); XCTAssertTrue(reopened.projection.expired)
        XCTAssertThrowsError(try reopened.readAccepted(session:rig.session,chunk:meetingID(1000),result:first.object!,authorized:{true}))
        try reopened.detach()
    }
    func testClosedNamespace512And513AndDepth13RefuseWithoutSweep() throws {
        for count in [512,513] {
            let bottom = MeetingVirtualBottom(), lease = SavedAudioImportStorage.MeetingLease(root:bottom.rootURL,profile:.init(),bottom:bottom), b = try lease.begin(cold:true)
            XCTAssertTrue(try lease.acquire(create:true,b))
            for i in 0..<count-1 { try bottom.add(MeetingSession.uuid(meetingID(UInt64(1_000+i)))+".source.pending") }
            if count == 512 { XCTAssertEqual(try lease.names(b).count,512); _ = try lease.finish(b) }
            else { XCTAssertThrowsError(try lease.names(b)); lease.fail(b) }
            XCTAssertEqual(bottom.names.count,count); let close = try lease.begin(retirementOnly:true); try lease.detach(close)
        }
        let rig = MeetingVirtualRig(depth:13); XCTAssertThrowsError(try rig.admit()); XCTAssertTrue(rig.bottom.descriptors.isEmpty); XCTAssertNil(rig.bottom.rootNode)
    }
}

extension MeetingSessionStoreTests {
    func testEveryResultAndDeletionPublicationCutPreservesAuthorityAndCharge() throws {
        enum Operation: CaseIterable { case reserve, write, promote, retire, intent, slice, authority, close }
        typealias Event = (String,String?)
        func eventKey(_ event: Event) -> String { event.0+":"+(event.1 ?? "(none)") }
        // This table describes public operation sites, not private mutation flags or observed availability.
        func cleanRefusalCuts(_ operation: Operation, _ trace: [Event]) throws -> Set<Int> {
            var result = Set<Int>()
            func site(_ label: String, suffix: String, binding: Bool = true) throws {
                let matches = trace.indices.filter { trace[$0].0 == label && trace[$0].1?.hasSuffix(suffix) == true }
                XCTAssertEqual(matches.count,1,"required semantic site \(operation) \(label) \(suffix)")
                let index = try XCTUnwrap(matches.first); result.insert(index)
                if binding {
                    guard trace.indices.contains(index+1) else { XCTFail("missing entry binding"); return }
                    XCTAssertEqual(trace[index+1].0,"binding"); XCTAssertNil(trace[index+1].1); result.insert(index+1)
                }
            }
            switch operation {
            case .reserve: try site("exclusive-create",suffix:".result.pending")
            case .write: try site("write-open",suffix:".result.pending")
            case .promote: try site("read-open",suffix:".result.pending"); try site("rename",suffix:".result.pending")
            case .retire: try site("read-open",suffix:".raw.txt"); try site("unlink",suffix:".raw.txt")
            case .intent: try site("exclusive-create",suffix:".delete")
            case .slice: try site("read-open",suffix:".source.wav"); try site("unlink",suffix:".source.wav")
            case .authority: try site("encode-ledger",suffix:"manifest.next",binding:false); try site("exclusive-create",suffix:"manifest.next")
            case .close: break // Final-close failure always quarantines, including its entry prefix.
            }
            let expected: Int
            switch operation { case .reserve,.write,.intent: expected = 2; case .promote,.retire,.slice: expected = 4; case .authority: expected = 3; case .close: expected = 0 }
            XCTAssertEqual(result.count,expected,"complete semantic-site table for \(operation)"); return result
        }
        func attributes(_ nodes: [String:MeetingVirtualBottom.Node]) -> [String:[Int64]] {
            nodes.mapValues { node in
                let s = node.s
                return [Int64(s.st_dev),Int64(s.st_ino),Int64(s.st_size),Int64(s.st_mode),Int64(s.st_uid),Int64(s.st_nlink),Int64(s.st_flags),Int64(s.st_mtimespec.tv_sec),Int64(s.st_mtimespec.tv_nsec),Int64(s.st_ctimespec.tv_sec),Int64(s.st_ctimespec.tv_nsec)]
            }
        }
        for operation in Operation.allCases {
            func run(cut: Int?, expectedClean: Bool? = nil, baseline: [Event] = []) throws -> (MeetingVirtualRig,Bool) {
                let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop(); _ = try rig.result(meetingID(1000))
                let request = try meetingProvenance(0,role:.requested), observed = try meetingProvenance(1,role:.observed)
                var token: MeetingSessionStore.AttemptToken?, borrow: MeetingSessionStore.BorrowToken?, receipt: MeetingSessionStore.Receipt?
                let body = try MeetingSessionStore.ResultInput(Data(repeating:81,count:1024))
                if operation == .reserve || operation == .write || operation == .promote || operation == .retire {
                    let t = try rig.store.beginAttempt(chunk:meetingID(1000),requested:request,authorized:{true}); token = t
                    borrow = try rig.store.borrow(t,authorized:{true}).0
                    if operation != .reserve { receipt = try rig.store.resultReserve(t,borrow:borrow!,input:body,observed:observed,authorized:{true}) }
                    if operation == .promote || operation == .retire { receipt = try rig.store.resultWrite(receipt!,bytes:body.bytes,authorized:{true}) }
                    if operation == .retire { _ = try rig.store.resultPromote(receipt!,authorized:{true}); try rig.store.actualBorrowExit(borrow!); borrow = nil }
                } else if operation != .intent {
                    receipt = try rig.store.deleteIntent(id:meetingID(90_000),terminalGeneration:1,holdEpoch:1,authorized:{true})
                    if operation == .authority || operation == .close { receipt = try rig.store.deleteSlice(receipt!,authorized:{true}) }
                    if operation == .close { receipt = try rig.store.deleteAuthority(receipt!,authorized:{true}) }
                }
                let payloads = rig.bottom.names.filter { $0.hasSuffix(".wav") || $0.hasSuffix(".raw.txt") }
                let beforeNodes = rig.bottom.rootNode?.children ?? [:] // Retain identities against address reuse.
                let beforeBytes = beforeNodes.mapValues { $0.bytes(0,$0.length) }, beforeAttributes = attributes(beforeNodes)
                let beforeManifest = try XCTUnwrap(MeetingWholeManifestSnapshot(rig.bottom))
                let beforeProjection = rig.store.projection, beforeReceipt = rig.store.lastOperation
                let beforeDescriptors = rig.bottom.descriptors.mapValues { ObjectIdentifier($0.node) }
                XCTAssertFalse(beforeNodes.isEmpty); XCTAssertEqual(beforeReceipt?.reservedBytes,MeetingSession.reservation)
                rig.bottom.reset(cut:cut); var succeeded = false
                let context: String
                if let cut,baseline.indices.contains(cut) {
                    let event = baseline[cut], occurrence = baseline.prefix(cut+1).filter { eventKey($0) == eventKey(event) }.count
                    context = "operation=\(operation) cut=\(cut) site=\(eventKey(event)) occurrence=\(occurrence)"
                } else { context = "operation=\(operation) baseline" }
                do {
                    switch operation {
                    case .reserve:_ = try rig.store.resultReserve(token!,borrow:borrow!,input:body,observed:observed,authorized:{true})
                    case .write:_ = try rig.store.resultWrite(receipt!,bytes:body.bytes,authorized:{true})
                    case .promote:_ = try rig.store.resultPromote(receipt!,authorized:{true})
                    case .retire:_ = try rig.store.resultRetire(authorized:{true})
                    case .intent:_ = try rig.store.deleteIntent(id:meetingID(90_000),terminalGeneration:1,holdEpoch:1,authorized:{true})
                    case .slice:_ = try rig.store.deleteSlice(receipt!,authorized:{true})
                    case .authority:_ = try rig.store.deleteAuthority(receipt!,authorized:{true})
                    case .close:_ = try rig.store.deleteClose(receipt!,authorized:{true})
                    }; succeeded = true
                } catch {
                    guard let cut,let expectedClean else { XCTFail("unexpected baseline error: \(context) \(error)"); throw error }
                    XCTAssertEqual(rig.bottom.events.prefix(cut+1).map(eventKey),baseline.prefix(cut+1).map(eventKey),context)
                    XCTAssertEqual(rig.store.projection.unavailable,!expectedClean,context)
                    if expectedClean {
                        let current = rig.bottom.rootNode?.children ?? [:]
                        XCTAssertEqual(current.mapValues { ObjectIdentifier($0) },beforeNodes.mapValues { ObjectIdentifier($0) },context)
                        XCTAssertEqual(current.mapValues { $0.bytes(0,$0.length) },beforeBytes,context)
                        XCTAssertEqual(attributes(current),beforeAttributes,context)
                        XCTAssertEqual(try XCTUnwrap(MeetingWholeManifestSnapshot(rig.bottom)),beforeManifest,context)
                        XCTAssertEqual(rig.store.projection,beforeProjection,context); XCTAssertEqual(rig.store.lastOperation,beforeReceipt,context)
                        XCTAssertEqual(rig.bottom.descriptors.mapValues { ObjectIdentifier($0.node) },beforeDescriptors,context)
                    } else { XCTAssertTrue(rig.store.projection.unavailable,context); XCTAssertFalse(rig.store.shutdownReady,context) }
                    XCTAssertEqual(rig.store.lastOperation?.reservedBytes,MeetingSession.reservation,context)
                    if let diagnostic = rig.store.lastFailure { XCTAssertEqual(diagnostic.reservedBytes,MeetingSession.reservation,context) }
                    if operation == .intent {
                        XCTAssertEqual(error as? MeetingSession.Failure,.nondurableIntent,context)
                        do { let unexpected = try rig.store.register(.microphone); XCTFail("intent must retain worker fence: \(context)"); try rig.store.actualExit(unexpected) } catch { }
                    }
                }
                if !succeeded,operation == .reserve || operation == .write || operation == .promote || operation == .intent {
                    XCTAssertTrue(Set(payloads).isSubset(of:rig.bottom.names),context); XCTAssertEqual(rig.store.projection.acceptedResults,1,context)
                }
                let events = rig.bottom.events; rig.bottom.cut = nil
                if let borrow { do { try rig.store.actualBorrowExit(borrow) } catch { XCTAssertTrue(rig.store.projection.unavailable,context) } }
                if operation != .close || !succeeded { do { try rig.store.detach() } catch { XCTAssertTrue(rig.store.projection.unavailable,context) } }
                rig.bottom.events = events; return (rig,succeeded)
            }
            let clean = try run(cut:nil); XCTAssertTrue(clean.1)
            let baseline = clean.0.bottom.events, cleanCuts = try cleanRefusalCuts(operation,clean.0.bottom.events)
            for cut in baseline.indices {
                let failed = try run(cut:cut,expectedClean:cleanCuts.contains(cut),baseline:baseline)
                XCTAssertFalse(failed.1,"injected site must not return success: \(operation) cut=\(cut)")
                XCTAssertLessThanOrEqual(failed.0.bottom.descriptors.count,14)
            }
        }
    }
    func testImportProfileAndOversizedMetadataNeverGainMeetingAuthority() throws {
        for size in [0,524_288,524_289] {
            let bottom = MeetingVirtualBottom(), lease = SavedAudioImportStorage.MeetingLease(root:bottom.rootURL,profile:.init(),bottom:bottom), b = try lease.begin(cold:true)
            XCTAssertTrue(try lease.acquire(create:true,b)); let root = try XCTUnwrap(lease.identity)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try bottom.add("owner.json",data:encoder.encode(SavedAudioImportStore.Marker(schema:1,owner:meetingID(1),root:root)))
            let ledger = size == 0 ? try encoder.encode(SavedAudioImportStore.Ledger(schema:1,owner:meetingID(1),root:root,revision:0,jobs:[])) : Data(repeating:32,count:size)
            try bottom.add("manifest.json",data:ledger); _ = try lease.finish(b); let close = try lease.begin(retirementOnly:true); try lease.detach(close)
            let seeded = try XCTUnwrap(MeetingWholeManifestSnapshot(bottom))
            XCTAssertEqual(seeded.bytes,ledger); XCTAssertEqual(seeded.reportedBytes,Int64(ledger.count))
            let names = bottom.names
            let store = MeetingSessionStore(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{1_000_000_000_000})
            XCTAssertThrowsError(try store.bootstrap()); XCTAssertEqual(bottom.payloadReads,0)
            XCTAssertEqual(try XCTUnwrap(MeetingWholeManifestSnapshot(bottom)),seeded)
            XCTAssertEqual(bottom.names,names); XCTAssertEqual(bottom.names.count,3)
        }
    }
    func testDurableIntentWhileBorrowedAndMissingOnlyInCurrentPair() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop()
        let token = try rig.store.beginAttempt(chunk:meetingID(1000),requested:meetingProvenance(0,role:.requested),authorized:{true}), borrow = try rig.store.borrow(token,authorized:{true})
        let intent = try rig.store.deleteIntent(id:meetingID(90_000),terminalGeneration:1,holdEpoch:1,authorized:{true})
        XCTAssertEqual(intent.deletionRemaining,1); XCTAssertThrowsError(try rig.store.deleteSlice(intent,authorized:{true}))
        try rig.store.actualBorrowExit(borrow.0)
        let progress = try rig.store.deleteSlice(intent,authorized:{true}); XCTAssertEqual(progress.deletionRemaining,0)
        let dead = try rig.store.deleteAuthority(progress,authorized:{true}); _ = try rig.store.deleteClose(dead,authorized:{true}); XCTAssertEqual(rig.store.projection,.idle)
    }
}

private struct MeetingRealFixture {
    struct Entry: Codable { let action: String, path: String, root: String, pid: Int32, uid: UInt32, device: Int32, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64, mode: UInt16 }
    let parent: URL, root: URL, manifest: URL, identity: SavedAudioImportStorage.Identity
    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let run = env["PARLA_MEETING_OWNED_RUN_ROOT"],let log = env["PARLA_MEETING_FIXTURE_MANIFEST"],log == run+"/meeting-fixtures.jsonl" else { throw MeetingSession.Failure.unavailable }
        var owned = stat(), receipt = stat()
        guard lstat(run,&owned) == 0,owned.st_uid == geteuid(),owned.st_mode & 0o7777 == 0o700,owned.st_mode & S_IFMT == S_IFDIR,
            lstat(log,&receipt) == 0,receipt.st_uid == geteuid(),receipt.st_nlink == 1,receipt.st_mode & S_IFMT == S_IFREG,receipt.st_mode & 0o7777 == 0o600 else { throw MeetingSession.Failure.unavailable }
        parent = URL(fileURLWithPath:run,isDirectory:true).appendingPathComponent("meeting-positive-"+UUID().uuidString.lowercased(),isDirectory:true)
        guard mkdir(parent.path,0o700) == 0 else { throw MeetingSession.Failure.unavailable }
        var s = stat(); guard lstat(parent.path,&s) == 0 else { throw MeetingSession.Failure.unavailable }
        identity = .init(device:s.st_dev,inode:s.st_ino); root = parent.appendingPathComponent("meeting",isDirectory:true); manifest = URL(fileURLWithPath:log)
        try record("created")
    }
    func record(_ action: String) throws {
        var s = stat(); guard lstat(parent.path,&s) == 0,identity == .init(device:s.st_dev,inode:s.st_ino) else { throw MeetingSession.Failure.unavailable }
        let entry = Entry(action:action,path:parent.path,root:root.path,pid:getpid(),uid:s.st_uid,device:s.st_dev,inode:s.st_ino,birthSeconds:Int64(s.st_birthtimespec.tv_sec),birthNanoseconds:Int64(s.st_birthtimespec.tv_nsec),mode:s.st_mode)
        var data = try JSONEncoder().encode(entry); data.append(10)
        let file = try FileHandle(forWritingTo:manifest); defer { try? file.close() }; try file.seekToEnd(); try file.write(contentsOf:data)
    }
}
extension MeetingSessionStoreTests {
    /// NEW, separate owned-real-file positive. Authored 8000-frame zero PCM only; no capture/model/native recognizer.
    func testSmallOwnedRealMeetingWriteHashRenameSyncCloseAndMetadataReopen() throws {
        let fixture = try MeetingRealFixture(), clock = MeetingTestClock(), session = meetingID(2), source = meetingID(3), segment = meetingID(100), epoch = meetingID(200)
        let bottom = MeetingDarwinBottom(uptime:{ProcessInfo.processInfo.systemUptime},checkpoint:{_,_ in})
        let store = MeetingSessionStore(root:fixture.root,profile:.init(),bottom:bottom,wallClock:{clock.value})
        let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.validated)
        _ = try store.admit(owner:meetingID(1),session:session,selections:[.init(instance:source,kind:.microphone,label:"",generation:1)],segments:[.init(id:segment,track:0,generation:1,timing:timing,canonicalStart:0)],authorized:{true})
        let bytes = meetingWAV(8000), input = try MeetingSessionStore.ChunkInput(session:session,source:source,id:meetingID(1000),generation:1,track:0,sourceGeneration:1,segment:segment,sequence:0,start:0,frames:8000,timing:timing,bytes:bytes)
        let a = try store.chunkA(input,authorized:{true}), b = try store.chunkB(a,bytes:bytes,authorized:{true}); _ = try store.chunkC(b,authorized:{true})
        _ = try store.terminal(reason:.normalStop,unknownMask:0,generation:1,holdEpoch:1,flags:0x7f,authorized:{true})
        let token = try store.beginAttempt(chunk:input.id,requested:meetingProvenance(0,role:.requested),authorized:{true}), borrow = try store.borrow(token,authorized:{true})
        XCTAssertEqual(borrow.1,bytes); try store.actualBorrowExit(borrow.0); _ = try store.cancelAttempt(token,authorized:{true}); try store.detach()
        let next = MeetingSessionStore(root:fixture.root,profile:.init(),bottom:MeetingDarwinBottom(uptime:{ProcessInfo.processInfo.systemUptime},checkpoint:{_,_ in}),wallClock:{clock.value})
        XCTAssertEqual(try next.bootstrap().acknowledgedChunks,1); try next.detach()
        let names = try FileManager.default.contentsOfDirectory(atPath:fixture.root.path), before = try Data(contentsOf:fixture.root.appendingPathComponent("manifest.json"))
        var payloadReads = 0, system = SavedAudioImportStorage.System(); system.event = { boundary,_ in if boundary == .payloadRead { payloadReads += 1 } }
        let wrong = SavedAudioImportStore(storage:.init(root:fixture.root,system:system)); XCTAssertThrowsError(try wrong.bootstrap()); try wrong.close()
        XCTAssertEqual(payloadReads,0); XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent("manifest.json")),before)
        var total = 0
        for name in names { total += try Data(contentsOf:fixture.root.appendingPathComponent(name)).count }
        XCTAssertLessThanOrEqual(total,8_388_608); try fixture.record("closed-preserved-for-owned-review")
    }
}

extension MeetingSessionStoreTests {
    func testForeignContextCannotConsumeWorkerBorrowOrPhaseReceipt() throws {
        let a = MeetingVirtualRig(), b = MeetingVirtualRig(); _ = try a.admit(); _ = try b.admit()
        let ah = try a.store.register(.writer), bh = try b.store.register(.writer)
        XCTAssertThrowsError(try b.store.actualExit(ah)); XCTAssertFalse(b.store.actualHoldsDrained)
        try a.store.actualExit(ah); try b.store.actualExit(bh)
        let ai = try a.input(0,frames:8000), bi = try b.input(0,frames:8000)
        let ar = try a.store.chunkA(ai,authorized:{true}), br = try b.store.chunkA(bi,authorized:{true})
        let before = b.bottom.metadata
        XCTAssertThrowsError(try b.store.chunkB(ar,bytes:bi.bytes,authorized:{true})); XCTAssertEqual(b.bottom.metadata,before)
        let ab = try a.store.chunkB(ar,bytes:ai.bytes,authorized:{true}), bb = try b.store.chunkB(br,bytes:bi.bytes,authorized:{true})
        _ = try a.store.chunkC(ab,authorized:{true}); _ = try b.store.chunkC(bb,authorized:{true}); try a.stop(); try b.stop()
        let at = try a.store.beginAttempt(chunk:ai.id,requested:meetingProvenance(0,role:.requested),authorized:{true}), bt = try b.store.beginAttempt(chunk:bi.id,requested:meetingProvenance(0,role:.requested),authorized:{true})
        XCTAssertThrowsError(try b.store.borrow(at,authorized:{true}))
        let av = try a.store.borrow(at,authorized:{true}), bv = try b.store.borrow(bt,authorized:{true})
        let count = b.bottom.descriptors.count
        XCTAssertThrowsError(try b.store.actualBorrowExit(av.0)); XCTAssertEqual(b.bottom.descriptors.count,count)
        try a.store.actualBorrowExit(av.0); try b.store.actualBorrowExit(bv.0)
        try a.store.detach(); try b.store.detach()
    }
    func testColdDeletionResumeDoesNotMintAuthorityFromANameOrOldReceipt() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); _ = try rig.seal(rig.input(1,frames:8000)); try rig.stop()
        let first = try rig.store.deleteIntent(id:meetingID(90_000),terminalGeneration:1,holdEpoch:1,authorized:{true})
        let progress = try rig.store.deleteSlice(first,authorized:{true}); XCTAssertEqual(progress.deletionRemaining,0); try rig.store.detach()
        let next = MeetingSessionStore(root:rig.bottom.rootURL,profile:.init(),bottom:rig.bottom,wallClock:{rig.testClock.value})
        rig.bottom.payloadReads = 0; XCTAssertEqual(try next.bootstrap().state,.deleting); XCTAssertEqual(rig.bottom.payloadReads,0)
        XCTAssertThrowsError(try next.deleteAuthority(progress,authorized:{true}))
        let resumed = try next.resumeDeletion(authorized:{true}); XCTAssertEqual(resumed.revision,progress.revision); XCTAssertEqual(resumed.cost.publications,0)
        let dead = try next.deleteAuthority(resumed,authorized:{true}); _ = try next.deleteClose(dead,authorized:{true}); XCTAssertEqual(next.projection,.idle)
    }
    func testMeasuredGapNeedsExactEvidenceAndDetailRefusalPreservesPriorAudio() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000))
        let gap = MeetingSession.Gap(id:meetingID(800),track:0,segment:0,sequence:1,kind:.measured,start:1,startDenominator:1,extent:1,extentDenominator:1)
        XCTAssertThrowsError(try rig.store.boundary(session:rig.session,source:rig.selections[0].instance,segment:nil,gap:gap,evidence:nil,authorized:{true}))
        XCTAssertEqual(rig.store.projection.acknowledgedChunks,1)
        let evidence = MeetingSession.Timing(pts:1,denominator:1,sample:16_000,rate:16_000,epoch:rig.segments[0].timing.epoch,mapping:.validated)
        _ = try rig.store.boundary(session:rig.session,source:rig.selections[0].instance,segment:nil,gap:gap,evidence:evidence,authorized:{true})
        XCTAssertThrowsError(try rig.store.boundary(session:rig.session,source:rig.selections[0].instance,segment:nil,gap:gap,evidence:evidence,authorized:{true}))
        try rig.stop(); try rig.store.detach()
    }
}

final class MeetingSessionStoreTimingTests: XCTestCase {
    private typealias M = MeetingSession
    private func input(_ rig: MeetingVirtualRig, sequence: UInt64, start: UInt64, sample: UInt64, pts: Int64,
                       denominator: UInt64 = 16_000, segment: M.Segment? = nil, bytes: Data) throws -> MeetingSessionStore.ChunkInput {
        let s = segment ?? rig.segments[0]
        return try .init(session:rig.session,source:rig.selections[0].instance,id:meetingID(1002),generation:4,track:0,sourceGeneration:7,segment:s.id,sequence:sequence,start:start,frames:8000,
                         timing:.init(pts:pts,denominator:denominator,sample:sample,rate:s.timing.rate,epoch:s.timing.epoch,mapping:s.timing.mapping),bytes:bytes)
    }
    private func gap(_ rig: MeetingVirtualRig, sequence: UInt64, start: Int64, segment: M.Segment? = nil, index: Int = 0) throws -> MeetingSessionStore.Receipt {
        let s = segment ?? rig.segments[0]
        let g = M.Gap(id:meetingID(800+sequence),track:0,segment:index,sequence:sequence,kind:.measured,start:start,startDenominator:16_000,extent:8000,extentDenominator:16_000)
        let evidence = M.Timing(pts:start,denominator:16_000,sample:UInt64(max(0,start)),rate:s.timing.rate,epoch:s.timing.epoch,mapping:.validated)
        return try rig.store.boundary(session:rig.session,source:rig.selections[0].instance,segment:segment,gap:g,evidence:evidence,authorized:{true})
    }
    private func fits(_ r: MeetingSessionStore.Receipt, minimumFixed: Int = 256, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(r.cost.credits,65_536,file:file,line:line)
        XCTAssertGreaterThanOrEqual(r.cost.fixed,minimumFixed,file:file,line:line); XCTAssertLessThanOrEqual(r.cost.fixed,2048,file:file,line:line)
        XCTAssertLessThanOrEqual(r.cost.validates,32,file:file,line:line); XCTAssertLessThanOrEqual(r.cost.enumerations,2,file:file,line:line)
        XCTAssertLessThanOrEqual(r.cost.peak,17,file:file,line:line); XCTAssertLessThanOrEqual(r.cost.retirement,512,file:file,line:line)
        XCTAssertEqual(r.cost.carryIn+r.cost.opens,r.cost.closes+r.cost.carryOut,file:file,line:line)
        XCTAssertEqual(r.reservedBytes,232_581_440,file:file,line:line)
    }
    private func cleanRefusal(_ rig: MeetingVirtualRig, file: StaticString = #filePath, line: UInt = #line,
                              _ action: () throws -> Void) {
        let metadata = rig.bottom.metadata, names = rig.bottom.names, projection = rig.store.projection, receipt = rig.store.lastOperation
        let writes = rig.bottom.writes, reads = rig.bottom.payloadReads, descriptors = Set(rig.bottom.descriptors.keys)
        let identities = rig.bottom.rootNode?.children.mapValues { ObjectIdentifier($0) }, eventStart = rig.bottom.events.count
        XCTAssertThrowsError(try action(),file:file,line:line)
        XCTAssertEqual(rig.bottom.metadata,metadata,file:file,line:line); XCTAssertEqual(rig.bottom.names,names,file:file,line:line)
        XCTAssertEqual(rig.bottom.rootNode?.children.mapValues { ObjectIdentifier($0) },identities,file:file,line:line)
        XCTAssertEqual(rig.store.projection,projection,file:file,line:line); XCTAssertFalse(rig.store.projection.unavailable,file:file,line:line)
        XCTAssertEqual(rig.store.lastOperation,receipt,file:file,line:line); XCTAssertEqual(rig.bottom.writes,writes,file:file,line:line)
        XCTAssertEqual(rig.bottom.payloadReads,reads,file:file,line:line); XCTAssertEqual(Set(rig.bottom.descriptors.keys),descriptors,file:file,line:line)
        let forbidden = Set(["exclusive-create","created","write","rename","publication","allocation-registered"])
        XCTAssertFalse(rig.bottom.events.dropFirst(eventStart).contains { forbidden.contains($0.0) },file:file,line:line)
    }
    func testLiveSampleRefusalPrecedesAllocationAndSameIDRemainsUsable() throws {
        let bytes = meetingWAV(8000)
        for sample in [UInt64(0),7999,8000,8001] {
            let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000,bytes:bytes))
            let next = try input(rig,sequence:1,start:8000,sample:sample,pts:8000,bytes:bytes)
            if sample < 8000 {
                cleanRefusal(rig) { _ = try rig.store.chunkA(next,authorized:{true}) }
                let valid = try input(rig,sequence:1,start:8000,sample:8000,pts:8000,bytes:bytes)
                fits(try rig.seal(valid))
            } else { fits(try rig.seal(next)) }
            XCTAssertEqual(rig.store.projection.acknowledgedChunks,2); try rig.store.detach()
        }
    }
    func testLiveCheckedTimingRefusesBeforeAllocationWithPriorAudioIntact() throws {
        let bytes = meetingWAV(8000)
        for mode in 0..<3 {
            let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000,bytes:bytes))
            let bad = try input(rig,sequence:1,start:8000,sample:mode == 0 ? .max : 8000,pts:mode == 1 ? .max : 8000,denominator:mode == 1 ? 1 : mode == 2 ? 0 : 16_000,bytes:bytes)
            cleanRefusal(rig) { _ = try rig.store.chunkA(bad,authorized:{true}) }
            let good = try input(rig,sequence:1,start:8000,sample:8000,pts:8000,bytes:bytes)
            let a = try rig.store.chunkA(good,authorized:{true}); fits(a,minimumFixed:384)
            let b = try rig.store.chunkB(a,bytes:bytes,authorized:{true}); fits(b)
            fits(try rig.store.chunkC(b,authorized:{true})); XCTAssertEqual(rig.store.projection.acknowledgedChunks,2)
            try rig.store.detach()
        }
    }
    func testLiveMeasuredOverlapAndBackwardOrderRefuseCleanlyInAllDirections() throws {
        let bytes = meetingWAV(8000)
        for direction in 0..<3 {
            for backward in [false,true] {
                let rig = MeetingVirtualRig(); _ = try rig.admit()
                let first: Int64 = backward ? 16_000 : 0, bad: Int64 = backward ? 0 : 4000, adjacent = first+8000
                if direction == 0 {
                    let firstInput = try rig.input(0,frames:8000,bytes:bytes)
                    let timed = try MeetingSessionStore.ChunkInput(session:firstInput.session,source:firstInput.source,id:firstInput.id,generation:firstInput.generation,track:0,sourceGeneration:7,segment:firstInput.segment,sequence:0,start:0,frames:8000,timing:.init(pts:first,denominator:16_000,sample:0,rate:16_000,epoch:firstInput.timing.epoch,mapping:.validated),bytes:bytes)
                    _ = try rig.seal(timed)
                } else { _ = try gap(rig,sequence:0,start:first) }
                if direction == 1 {
                    let next = try input(rig,sequence:1,start:0,sample:0,pts:bad,bytes:bytes)
                    cleanRefusal(rig) { _ = try rig.store.chunkA(next,authorized:{true}) }
                    fits(try rig.seal(input(rig,sequence:1,start:0,sample:0,pts:adjacent,bytes:bytes)))
                } else {
                    cleanRefusal(rig) { _ = try gap(rig,sequence:1,start:bad) }
                    fits(try gap(rig,sequence:1,start:adjacent))
                    fits(try rig.seal(input(rig,sequence:2,start:direction == 0 ? 8000 : 0,sample:direction == 0 ? 8000 : 0,pts:adjacent+8000,bytes:bytes)))
                }
                XCTAssertEqual(rig.store.projection.acknowledgedChunks,direction == 0 ? 2 : 1); try rig.store.detach()
            }
        }
    }
    func testLiveSegmentEpochAndUnknownControlsKeepSourceSemantics() throws {
        let bytes = meetingWAV(8000)
        for mode in 0..<3 {
            let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000,bytes:bytes))
            let s = M.Segment(id:meetingID(102),track:0,generation:7,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:meetingID(mode == 1 ? 202 : 200),mapping:mode == 2 ? .unknown : .validated),canonicalStart:8000)
            fits(try rig.store.boundary(session:rig.session,source:rig.selections[0].instance,segment:s,gap:nil,evidence:nil,authorized:{true}))
            let next = try input(rig,sequence:1,start:8000,sample:0,pts:mode == 0 ? 8000 : 0,segment:s,bytes:bytes)
            if mode == 0 {
                cleanRefusal(rig) { _ = try rig.store.chunkA(next,authorized:{true}) }
                fits(try rig.seal(input(rig,sequence:1,start:8000,sample:8000,pts:8000,segment:s,bytes:bytes)))
            } else { fits(try rig.seal(next)) }
            XCTAssertEqual(rig.store.projection.acknowledgedChunks,2); try rig.store.detach()
        }
    }
    func testLiveSegmentAndGapRefusalPublishesNeitherWhileFreshEpochCanReset() throws {
        let rig = MeetingVirtualRig(); _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000))
        let same = M.Segment(id:meetingID(102),track:0,generation:7,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:meetingID(200),mapping:.validated),canonicalStart:8000)
        cleanRefusal(rig) { _ = try gap(rig,sequence:1,start:4000,segment:same,index:2) }
        let fresh = M.Segment(id:same.id,track:0,generation:7,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:meetingID(202),mapping:.validated),canonicalStart:8000)
        fits(try gap(rig,sequence:1,start:0,segment:fresh,index:2))
        XCTAssertEqual(rig.store.projection.acknowledgedChunks,1); try rig.store.detach()
    }
}

/// A whole virtual-node observation, independent of the production metadata acceptance cap.
private struct MeetingWholeManifestSnapshot: Equatable {
    let node: MeetingVirtualBottom.Node, bytes: Data, reportedBytes: Int64
    init?(_ bottom: MeetingVirtualBottom) {
        guard let node = bottom.rootNode?.children["manifest.json"],case .metadata(let bytes) = node.body else { return nil }
        self.node = node; self.bytes = bytes; reportedBytes = Int64(node.s.st_size)
    }
    static func == (left: Self, right: Self) -> Bool {
        left.node === right.node && left.bytes == right.bytes && left.reportedBytes == right.reportedBytes
    }
}
extension MeetingSessionStoreTests {
    func testWholeManifestObservationDistinguishesBoundaryTailAndIdentityChanges() throws {
        for size in [524_288,524_289] {
            let bottom = MeetingVirtualBottom(), lease = SavedAudioImportStorage.MeetingLease(root:bottom.rootURL,profile:.init(),bottom:bottom)
            let begin = try lease.begin(cold:true); XCTAssertTrue(try lease.acquire(create:true,begin)); _ = try lease.finish(begin)
            let original = Data(repeating:32,count:size)
            try bottom.add("manifest.json",data:original)
            let seeded = try XCTUnwrap(MeetingWholeManifestSnapshot(bottom))
            XCTAssertEqual(seeded,try XCTUnwrap(MeetingWholeManifestSnapshot(bottom)))
            for variant in 0..<4 {
                var changed = original
                switch variant {
                case 0: changed.append(33)
                case 1: changed.removeLast()
                case 2: changed[changed.count-1] = 33
                default: break // Identical bytes on a replacement node are still a different identity.
                }
                if variant == 3 { try bottom.add("manifest.json",data:changed) }
                else { seeded.node.body = .metadata(changed); seeded.node.s.st_size = off_t(changed.count) }
                XCTAssertNotEqual(seeded,try XCTUnwrap(MeetingWholeManifestSnapshot(bottom)))
                // Reset the original node between independent observation controls.
                seeded.node.body = .metadata(original); seeded.node.s.st_size = off_t(original.count)
                bottom.rootNode?.children["manifest.json"] = seeded.node
                XCTAssertEqual(seeded,try XCTUnwrap(MeetingWholeManifestSnapshot(bottom)))
            }
            bottom.rootNode?.children.removeValue(forKey:"manifest.json")
            XCTAssertNil(MeetingWholeManifestSnapshot(bottom))
            let close = try lease.begin(retirementOnly:true); try lease.detach(close)
            XCTAssertTrue(bottom.descriptors.isEmpty)
        }
    }
}

final class MeetingVirtualDirectoryTests: XCTestCase {
    private func root() throws -> (MeetingVirtualBottom,SavedAudioImportStorage.MeetingLease) {
        let bottom = MeetingVirtualBottom()
        let selected = SavedAudioImportStorage.MeetingLease(root:bottom.rootURL,profile:.init(),bottom:bottom)
        let begin = try selected.begin(cold:true); XCTAssertTrue(try selected.acquire(create:true,begin)); _ = try selected.finish(begin)
        return (bottom,selected)
    }
    private func stream(_ bottom: MeetingVirtualBottom, _ lease: SavedAudioImportStorage.MeetingLease) throws -> Int32 {
        let fd = try bottom.duplicate(lease.directory); try bottom.makeStream(fd); return fd
    }
    private func close(_ bottom: MeetingVirtualBottom, _ lease: SavedAudioImportStorage.MeetingLease, streams: [Int32]) throws {
        for fd in streams { try bottom.closeStream(fd) }
        let end = try lease.begin(retirementOnly:true); try lease.detach(end); XCTAssertTrue(bottom.descriptors.isEmpty)
    }
    func testLiveCursorSeesInsertRemoveRenameReplacementAndEOFGrowth() throws {
        let (bottom,lease) = try root(); try bottom.add("charlie")
        let fd = try stream(bottom,lease)
        XCTAssertEqual(try bottom.nextName(fd),"."); XCTAssertEqual(try bottom.nextName(fd),"..")
        try bottom.add("alpha"); XCTAssertEqual(try bottom.nextName(fd),"alpha")
        try bottom.add("bravo"); XCTAssertEqual(try bottom.nextName(fd),"bravo")
        try bottom.unlink(parent:lease.directory,name:"charlie",directory:false)
        XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertNil(try bottom.nextName(fd)); XCTAssertNil(try bottom.nextName(fd))
        try bottom.add("zulu"); XCTAssertEqual(try bottom.nextName(fd),"zulu"); XCTAssertNil(try bottom.nextName(fd))
        try bottom.makeStream(fd)
        for expected in [".","..","alpha"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        try bottom.rename(parent:lease.directory,from:"alpha",to:"delta")
        XCTAssertEqual(try bottom.nextName(fd),"delta") // Numeric cursor is not reset or advanced to 'after last name'.
        XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertEqual(try bottom.nextName(fd),"zulu"); XCTAssertNil(try bottom.nextName(fd))
        try bottom.makeStream(fd)
        for expected in [".","..","bravo"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        let oldZ = try bottom.open(parent:lease.directory,name:"zulu",mode:.read), oldInode = try bottom.inspect(oldZ).st_ino
        try bottom.rename(parent:lease.directory,from:"bravo",to:"zulu")
        XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertEqual(try bottom.nextName(fd),"zulu"); XCTAssertNil(try bottom.nextName(fd))
        XCTAssertEqual(try bottom.inspect(oldZ).st_ino,oldInode)
        XCTAssertNotEqual(try bottom.named(parent:lease.directory,name:"zulu")?.st_ino,oldInode)
        try bottom.close(oldZ)
        try bottom.makeStream(fd)
        for expected in [".","..","delta"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        try bottom.rename(parent:lease.directory,from:"delta",to:"delta")
        XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertEqual(try bottom.nextName(fd),"zulu")
        try close(bottom,lease,streams:[fd])
    }
    func testDirectDictionaryWritesAndNonKeyObservationsStayLive() throws {
        let (bottom,lease) = try root(); let node = try XCTUnwrap(bottom.rootNode), lock = try XCTUnwrap(node.children["lock"])
        node.children["beta"] = .init(name:"not-the-key",inode:9_000_001,directory:false)
        let fd = try stream(bottom,lease)
        for expected in [".","..","beta"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        node.children["aardvark"] = .init(name:"different",inode:9_000_002,directory:false)
        XCTAssertEqual(try bottom.nextName(fd),"beta") // Insertion before the cursor repeats the existing key.
        node.children.removeValue(forKey:"beta"); XCTAssertNil(try bottom.nextName(fd))
        node.children["zulu"] = .init(name:"z",inode:9_000_003,directory:false)
        XCTAssertEqual(try bottom.nextName(fd),"zulu"); XCTAssertNil(try bottom.nextName(fd))
        let saved = node.children; node.children.removeAll()
        try bottom.makeStream(fd); XCTAssertEqual(try bottom.nextName(fd),"."); XCTAssertEqual(try bottom.nextName(fd),".."); XCTAssertNil(try bottom.nextName(fd))
        node.children = saved
        XCTAssertEqual(try bottom.nextName(fd),"aardvark"); XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertEqual(try bottom.nextName(fd),"zulu")
        let old = try XCTUnwrap(node.children["zulu"])
        node.children["zulu"] = .init(name:"replacement",inode:9_000_004,directory:false)
        XCTAssertFalse(node.children["zulu"] === old)
        try bottom.makeStream(fd)
        for expected in [".","..","aardvark"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        let live = try XCTUnwrap(node.children["zulu"]); live.name = "a-different-value"; live.body = .metadata(Data([7,11])); live.s.st_size = 2; live.s.st_mtimespec.tv_sec += 1
        XCTAssertEqual(try bottom.nextName(fd),"lock"); XCTAssertEqual(try bottom.nextName(fd),"zulu"); XCTAssertNil(try bottom.nextName(fd))
        XCTAssertEqual(try bottom.named(parent:lease.directory,name:"zulu")?.st_size,2); XCTAssertEqual(live.bytes(0,2),Data([7,11]))
        XCTAssertTrue(node.children["lock"] === lock)
        try close(bottom,lease,streams:[fd])
    }
    func testDescriptorCursorsResetDuplicateAndCloseIndependently() throws {
        let (bottom,lease) = try root(); try bottom.add("alpha")
        let a = try bottom.duplicate(lease.directory); XCTAssertThrowsError(try bottom.nextName(a)); try bottom.makeStream(a)
        XCTAssertEqual(try bottom.nextName(a),".")
        let b = try bottom.duplicate(a); XCTAssertThrowsError(try bottom.nextName(b)); try bottom.makeStream(b)
        XCTAssertEqual(try bottom.nextName(b),"."); XCTAssertEqual(try bottom.nextName(a),"..")
        XCTAssertEqual(try bottom.nextName(b),".."); XCTAssertEqual(try bottom.nextName(b),"alpha")
        try bottom.makeStream(b); XCTAssertEqual(try bottom.nextName(b),".")
        try bottom.closeStream(a); XCTAssertThrowsError(try bottom.nextName(a)); XCTAssertThrowsError(try bottom.closeStream(a))
        let closes = bottom.closeCount; bottom.closeFailureAt = closes+1
        XCTAssertThrowsError(try bottom.closeStream(b)); XCTAssertEqual(bottom.closeCount,closes+1); XCTAssertNil(bottom.descriptors[b]); XCTAssertThrowsError(try bottom.nextName(b))
        bottom.closeFailureAt = nil
        // makeStream historically permits a regular virtual Node; do not add a new type restriction.
        let regular = try bottom.open(parent:lease.directory,name:"file",mode:.exclusive); try bottom.makeStream(regular)
        XCTAssertEqual(try bottom.nextName(regular),"."); XCTAssertEqual(try bottom.nextName(regular),".."); XCTAssertNil(try bottom.nextName(regular)); try bottom.closeStream(regular)
        try bottom.mkdir(parent:lease.directory,name:"child")
        let child = try bottom.open(parent:lease.directory,name:"child",mode:.directory); try bottom.makeStream(child)
        try bottom.unlink(parent:lease.directory,name:"child",directory:true)
        XCTAssertEqual(try bottom.nextName(child),"."); XCTAssertEqual(try bottom.nextName(child),".."); XCTAssertNil(try bottom.nextName(child))
        try close(bottom,lease,streams:[child])
    }
    func testMember512And513ViewsKeepAllNamesAndProductionRefusal() throws {
        let (bottom,lease) = try root(); var names: [String] = []
        for n in 0..<511 { let name = meetingID(UInt64(1000+n)).uuidString.lowercased()+".raw.txt"; names.append(name); try bottom.add(name) }
        let first = try lease.begin(); XCTAssertEqual(try lease.names(first).count,512); _ = try lease.finish(first)
        let extra = meetingID(1511).uuidString.lowercased()+".raw.txt"; names.append(extra); try bottom.add(extra)
        let fd = try stream(bottom,lease)
        for expected in [".",".."]+names+["lock"] { XCTAssertEqual(try bottom.nextName(fd),expected) }
        XCTAssertNil(try bottom.nextName(fd)); try bottom.closeStream(fd)
        let before = bottom.names, rejecting = try lease.begin()
        XCTAssertThrowsError(try lease.names(rejecting)); lease.fail(rejecting)
        XCTAssertEqual(bottom.names,before)
        let end = try lease.begin(retirementOnly:true); try lease.detach(end); XCTAssertTrue(bottom.descriptors.isEmpty)
    }
}
