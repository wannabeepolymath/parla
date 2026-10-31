import Darwin
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class LifecycleMeetingBottom: MeetingStorageBottom {
    enum Cut: Error { case injected }
    final class Node {
        enum Body { case metadata(Data), source(Data,Int), raw(UInt8,Int) }
        var s = stat(), children: [String:Node] = [:], body: Body = .metadata(Data()), name: String, locked = false, privateRoot = false
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
    var tick: TimeInterval = 0, space = Int64.max, ancestorACL = 0, writeLimit = Int.max, interruptWrites = false
    var closeFailureAt: Int?, closeCount = 0, closes: [Int32] = [], payloadReads = 0, writes = 0, calls = 0
    // Opt-in for stream byte oracles. Existing foundation fixtures keep their compact zero-source default.
    var retainSourceBytes = false
    var observe: ((String,String?) -> Void)?
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
        observe?(operation,name); events.append((operation,name)); if advanceAtWrite && operation == "write" { tick += 31 }
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
                if name.hasSuffix(".source.pending"),!retainSourceBytes { child.body = .source(Data(),0) }
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
        let names = [".",".."]+d.node.children.keys.sorted(); guard d.position < names.count else { return nil }; defer { d.position += 1 }; return names[d.position]
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

private func lifecycleID(_ n: UInt64) -> UUID { UUID(uuidString:String(format:"00000000-0000-0000-0000-%012llx",n))! }
private func lifecycleWAV() -> Data {
    func le(_ n: Int,_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
    var bytes = Data("RIFF".utf8)
    bytes.append(le(16_036,4))
    bytes.append(Data("WAVEfmt ".utf8))
    bytes.append(le(16,4))
    bytes.append(le(1,2))
    bytes.append(le(1,2))
    bytes.append(le(16_000,4))
    bytes.append(le(32_000,4))
    bytes.append(le(2,2))
    bytes.append(le(16,2))
    bytes.append(Data("data".utf8))
    bytes.append(le(16_000,4))
    bytes.append(Data(repeating:0,count:16_000))
    return bytes
}
private func lifecycleProvenance(_ observed: Bool) throws -> MeetingSession.Provenance {
    try .init(id:lifecycleID(observed ? 501 : 500),generation:1,role:observed ? .observed : .requested,engine:.unknown,artifact:.unknown,catalogID:"",language:"",model:"",filter:"",nativeVersion:"",buildScope:"",systemScope:"",verification:"",computeScope:"",digest:"",helperDigest:"",releaseDigest:"",sdkRevision:"",modelRevision:"",expectedBytes:0,fileGeneration:nil,adapter:0,compute:0,hints:false)
}
private actor MeetingLifecycleGate {
    private var opened = false, waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}
private final class LifecycleHeldWrite: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value:0)
    private var armed = true, sawIntent = false, deliveredIntent = false
    private var entered = false, timedOut = false
    let enteredExpectation: XCTestExpectation, intentExpectation: XCTestExpectation
    init(entered: XCTestExpectation, intent: XCTestExpectation) { enteredExpectation = entered; intentExpectation = intent }
    func observe(_ operation: String, _ name: String?) {
        let hold = lock.withLock { () -> Bool in
            guard armed,operation == "write",name?.hasSuffix(".source.pending") == true else { return false }
            armed = false; entered = true; return true
        }
        if hold {
            enteredExpectation.fulfill()
            if release.wait(timeout:.now()+10) == .timedOut { lock.withLock { timedOut = true } }
        }
        let intent = lock.withLock { () -> Bool in
            if operation == "exclusive-create",name?.hasSuffix(".delete") == true { sawIntent = true }
            guard sawIntent,!deliveredIntent,operation == "before-outward-receipt" else { return false }
            deliveredIntent = true; return true
        }
        if intent { intentExpectation.fulfill() }
    }
    var didEnter: Bool { lock.withLock { entered } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func open() { release.signal() }
}
private actor MeetingDeadlineGate {
    private var opened = false
    private var waiters: [UUID:(CheckedContinuation<Bool,Never>,Task<Void,Never>)] = [:]
    func wait() async -> Bool {
        if opened { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
                await self?.expire(id)
            }
            waiters[id] = (continuation,timer)
        }
    }
    private func expire(_ id: UUID) { if let pending = waiters.removeValue(forKey:id) { pending.0.resume(returning:false) } }
    func open() {
        opened = true; let pending = waiters.values; waiters.removeAll()
        for (continuation,timer) in pending { timer.cancel(); continuation.resume(returning:true) }
    }
}
private final class LifecycleHeldOperation: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value:0)
    private var armed = true, timedOut = false
    let entered: XCTestExpectation
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func holdOnce() {
        guard lock.withLock({ () -> Bool in if !armed { return false }; armed = false; return true }) else { return }
        entered.fulfill()
        if release.wait(timeout:.now()+10) == .timedOut { lock.withLock { timedOut = true } }
    }
    func open() { release.signal() }
    var didTimeOut: Bool { lock.withLock { timedOut } }
}
private enum LifecycleConsumerFailure: Error { case expected }
@MainActor private final class MeetingLifecycleRig {
    let bottom = LifecycleMeetingBottom(), producerExit = MeetingLifecycleGate(), stopAcknowledged = MeetingLifecycleGate(), stopCalled = MeetingLifecycleGate(), consumerExit = MeetingLifecycleGate(), consumerEntered = MeetingLifecycleGate()
    var clock: Int64 = 1_000_000_000_000, validates = 0, starts = 0, recognitions = 0, cancels = 0, ownerClockCalls = 0
    let session = lifecycleID(2), source = lifecycleID(3), segment = lifecycleID(100), epoch = lifecycleID(200)
    let store: MeetingSessionStore
    let clockBox: LifecycleClock
    var owner: MeetingSessionOwner!
    var onStopRequested: (() -> Void)?
    var validation: (() async -> Bool)?
    var onConsumerEntered: (() -> Void)?, onConsumerReturned: (() -> Void)?
    var consumerFailure = false
    init() {
        let clock = LifecycleClock(); clockBox = clock
        store = .init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{clock.value})
        let producerExit = producerExit, stopAcknowledged = stopAcknowledged, stopCalled = stopCalled, consumerExit = consumerExit, consumerEntered = consumerEntered
        owner = .init(store:store,capture:.init(validate:{[unowned self] _ in validates += 1; if let validation { return await validation() }; return true},start:{[unowned self] selections in
            starts += 1
            func outcome(_ selection: MeetingSession.Selection) -> MeetingSessionOwner.Producer { .init(source:selection.instance,exit:.actual(Task { await producerExit.wait() })) }
            return .init(first:selections.first.map(outcome),second:selections.dropFirst().first.map(outcome))
        },requestStop:{[unowned self] in onStopRequested?(); await stopCalled.open(); await stopAcknowledged.wait()}),recognition:.init(run:{[unowned self] _,_ in
            recognitions += 1
            return Task { [weak self] in
                self?.onConsumerEntered?(); await consumerEntered.open(); await consumerExit.wait()
                self?.onConsumerReturned?()
                if self?.consumerFailure == true { return .failure(LifecycleConsumerFailure.expected) }
                return Result { try MeetingSessionOwner.RawResult(bytes:Data(repeating:81,count:1024),observed:lifecycleProvenance(true)) }
            }
        },requestCancel:{[unowned self] in cancels += 1}),wallClock:{[unowned self] in ownerClockCalls += 1; return clockBox.value},holdEpoch:1)
    }
    var timing: MeetingSession.Timing { .init(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.validated) }
    func start(twoSources: Bool = false) async throws {
        var selections = [MeetingSession.Selection(instance:source,kind:.microphone,label:"",generation:7)]
        var segments = [MeetingSession.Segment(id:segment,track:0,generation:7,timing:timing,canonicalStart:0)]
        if twoSources {
            selections.append(.init(instance:lifecycleID(4),kind:.selectedApplication,label:"",generation:9))
            segments.append(.init(id:lifecycleID(101),track:1,generation:9,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:lifecycleID(201),mapping:.validated),canonicalStart:0))
        }
        try await owner.start(owner:lifecycleID(1),session:session,selections:selections,segments:segments)
    }
    func input(track: Int = 0, session: UUID? = nil, source: UUID? = nil) throws -> MeetingSessionStore.ChunkInput {
        let timing = track == 0 ? self.timing : MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:lifecycleID(201),mapping:.validated)
        return try .init(session:session ?? self.session,source:source ?? (track == 0 ? self.source : lifecycleID(4)),id:lifecycleID(UInt64(1000+track)),generation:1,track:track,sourceGeneration:track == 0 ? 7 : 9,segment:track == 0 ? segment : lifecycleID(101),sequence:0,start:0,frames:8000,timing:timing,bytes:lifecycleWAV())
    }
    func seal() async throws { let ticket = try owner.reserveInput(id:lifecycleID(700),track:0); try await owner.submit(ticket,input:input()) }
    func releaseStop() async { await stopAcknowledged.open(); await producerExit.open() }
    func stop() async throws { await releaseStop(); try await owner.stop() }
}
private final class LifecycleClock: @unchecked Sendable { var value: Int64 = 1_000_000_000_000 }

final class MeetingSessionLifecycleTests: XCTestCase {
    @MainActor func testInertConstructorAndExplicitStartAndStopNeverRunRecognition() async throws {
        let rig = MeetingLifecycleRig()
        XCTAssertEqual(rig.owner.state,.idle); XCTAssertEqual(rig.owner.projection,.idle); XCTAssertEqual(rig.bottom.calls,0); XCTAssertTrue(rig.bottom.events.isEmpty)
        XCTAssertEqual(rig.starts,0); XCTAssertEqual(rig.validates,0); XCTAssertEqual(rig.recognitions,0); XCTAssertEqual(rig.ownerClockCalls,0)
        XCTAssertThrowsError(try rig.owner.reserveInput(id:lifecycleID(700),track:0))
        try await rig.start(); XCTAssertEqual(rig.starts,1); XCTAssertEqual(rig.validates,1)
        try await rig.seal(); try await rig.stop(); try await rig.owner.stop()
        XCTAssertEqual(rig.owner.state,.stopped); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,1); XCTAssertEqual(rig.recognitions,0)
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); rig.owner.cancelQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        XCTAssertThrowsError(try rig.owner.reserveInput(id:lifecycleID(701),track:0)); XCTAssertEqual(rig.starts,1)
        rig.owner.reserveQuit(); try await rig.owner.committedDetach(); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    @MainActor func testStopAcknowledgmentCannotReleaseActualProducerOrUnsubmittedCallback() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(); let ticket = try rig.owner.reserveInput(id:lifecycleID(700),track:0)
        let stopping = Task { try await rig.owner.stop() }; await rig.stopCalled.wait()
        XCTAssertFalse(rig.store.actualHoldsDrained); rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady); rig.owner.cancelQuit()
        await rig.stopAcknowledged.open(); XCTAssertFalse(rig.store.actualHoldsDrained)
        await rig.producerExit.open(); XCTAssertFalse(rig.store.actualHoldsDrained)
        try rig.owner.abandon(ticket); try await stopping.value
        XCTAssertEqual(rig.recognitions,0); XCTAssertEqual(rig.owner.projection.state,.interrupted)
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
    }
    @MainActor func testDeleteWaitsForActualWriterThenDurableIntentBeforeProducerJoin() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(); let ticket = try rig.owner.reserveInput(id:lifecycleID(700),track:0)
        let entered = XCTestExpectation(description:"actual writer held"), intent = XCTestExpectation(description:"intent outward boundary")
        let stopRequested = XCTestExpectation(description:"producer stop requested"), writerDone = XCTestExpectation(description:"submit exited"), deleteDone = XCTestExpectation(description:"delete exited")
        let held = LifecycleHeldWrite(entered:entered,intent:intent)
        rig.bottom.observe = held.observe; rig.onStopRequested = { stopRequested.fulfill() }
        var writerExited = false, deleteExited = false
        let writing = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>
            do { try await rig.owner.submit(ticket,input:rig.input()); result = .success(()) } catch { result = .failure(error) }
            writerExited = true; writerDone.fulfill(); return result
        }
        // Always release test-owned gates, including assertion/error paths. The worker has its own finite deadline.
        defer { held.open(); Task { await rig.releaseStop() } }
        await fulfillment(of:[entered],timeout:5)
        guard held.didEnter else {
            held.open(); await fulfillment(of:[writerDone],timeout:5)
            if writerExited { _ = await writing.value }
            return
        }
        let deleting = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>
            do { try await rig.owner.delete(id:lifecycleID(90_000)); result = .success(()) } catch { result = .failure(error) }
            deleteExited = true; deleteDone.fulfill(); return result
        }
        await fulfillment(of:[stopRequested],timeout:5)
        // Only actor-owned state is observable while the detached writer holds the store lock.
        XCTAssertFalse(rig.owner.shutdownReady)
        held.open(); await fulfillment(of:[intent],timeout:5)
        XCTAssertEqual(rig.recognitions,0)
        await rig.releaseStop()
        await fulfillment(of:[writerDone,deleteDone],timeout:5)
        guard writerExited,deleteExited else { return } // Never join a task whose completion has not been observed.
        _ = await writing.value; try await deleting.value.get()
        rig.bottom.observe = nil; rig.onStopRequested = nil
        XCTAssertFalse(held.didTimeOut)
        XCTAssertEqual(rig.owner.state,.idle); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    @MainActor func testCancelRecognitionPreservesPriorResultAndBorrowUntilActualExit() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(); try await rig.seal(); try await rig.stop()
        let first = Task { try await rig.owner.transcribe(chunk:lifecycleID(1000),requested:lifecycleProvenance(false)) }
        await rig.consumerEntered.wait(); rig.owner.cancelTranscription()
        XCTAssertFalse(rig.store.actualHoldsDrained); XCTAssertEqual(rig.owner.projection.acceptedResults,0)
        rig.owner.reserveQuit(); rig.owner.cancelQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        await rig.consumerExit.open(); _ = try? await first.value
        XCTAssertEqual(rig.owner.state,.stopped); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,1); XCTAssertEqual(rig.owner.projection.acceptedResults,0)
        // A separate explicit action is permitted; rejected quit never restarted it.
        try await rig.owner.transcribe(chunk:lifecycleID(1000),requested:lifecycleProvenance(false)); XCTAssertEqual(rig.owner.projection.acceptedResults,1)
        rig.owner.cancelTranscription(); XCTAssertEqual(rig.owner.projection.acceptedResults,1)
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
    }
    @MainActor func testExpiryRevokesImmediatelyWhileActualConsumerStillOwnsBorrow() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(); try await rig.seal(); try await rig.stop()
        let transcribing = Task { try await rig.owner.transcribe(chunk:lifecycleID(1000),requested:lifecycleProvenance(false)) }; await rig.consumerEntered.wait()
        let intent = expectation(description:"expiry intent has reached its outward boundary"); var seen = false, delivered = false
        rig.bottom.observe = { operation,name in
            if operation == "exclusive-create",name?.hasSuffix(".delete") == true { seen = true }
            if seen,!delivered,operation == "before-outward-receipt" { delivered = true; intent.fulfill() }
        }
        rig.clockBox.value += MeetingSession.lifetime
        let expiring = Task { try await rig.owner.evaluateExpiry(deleteID:lifecycleID(90_000)) }
        await fulfillment(of:[intent],timeout:5); XCTAssertFalse(rig.store.actualHoldsDrained)
        await rig.consumerExit.open(); _ = try? await transcribing.value; try await expiring.value
        XCTAssertEqual(rig.owner.state,.idle); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    @MainActor func testForeignSessionAndSourceCannotConsumeReservedTicket() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(); let ticket = try rig.owner.reserveInput(id:lifecycleID(700),track:0)
        for input in [try rig.input(session:lifecycleID(999)),try rig.input(source:lifecycleID(998))] {
            do { try await rig.owner.submit(ticket,input:input); XCTFail("Foreign event admitted") } catch { XCTAssertEqual(rig.owner.projection.acknowledgedChunks,0) }
        }
        try rig.owner.abandon(ticket); try await rig.stop(); rig.owner.reserveQuit(); try await rig.owner.committedDetach()
    }
}

final class MeetingSessionOwnershipRegressionTests: XCTestCase {
    @MainActor func testAbsentRootCloseUncertaintyCannotReportReadyOrDetach() async throws {
        let rig = MeetingLifecycleRig(); rig.bottom.closeFailureAt = 1
        await rig.owner.refresh()
        XCTAssertEqual(rig.owner.state,.unavailable); XCTAssertEqual(rig.owner.concern,.close)
        rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        do { try await rig.owner.committedDetach(); XCTFail("Uncertain bootstrap must refuse detach") } catch { }
        XCTAssertTrue(rig.bottom.descriptors.isEmpty)
        XCTAssertEqual(Set(rig.bottom.closes).count,rig.bottom.closes.count)
    }
    @MainActor func testCleanAbsentRootCanStillQuitWithoutCreatingStorage() async throws {
        let rig = MeetingLifecycleRig(); await rig.owner.refresh()
        XCTAssertEqual(rig.owner.state,.idle); XCTAssertNil(rig.owner.concern); XCTAssertNil(rig.bottom.rootNode)
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
        XCTAssertTrue(rig.bottom.descriptors.isEmpty); XCTAssertNil(rig.bottom.rootNode)
    }
    @MainActor func testPendingValidationBlocksDetachAndQuitCancellationCannotReviveIt() async throws {
        let rig = MeetingLifecycleRig(), gate = MeetingDeadlineGate()
        let entered = XCTestExpectation(description:"validation entered"), done = XCTestExpectation(description:"start exited")
        var exited = false, validationExpired = false
        rig.validation = { entered.fulfill(); let opened = await gate.wait(); validationExpired = !opened; return opened }
        let starting = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>; do { try await rig.start(); result = .success(()) } catch { result = .failure(error) }
            exited = true; done.fulfill(); return result
        }
        defer { Task { await gate.open(); await rig.releaseStop() } }
        await fulfillment(of:[entered],timeout:2)
        rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        let ready = await rig.owner.beginShutdown(); XCTAssertFalse(ready)
        do { try await rig.owner.committedDetach(); XCTFail("Pending validation must refuse detach") } catch { }
        rig.owner.cancelQuit(); await gate.open(); await fulfillment(of:[done],timeout:2)
        guard exited else { return }
        let startResult = await starting.value; XCTAssertThrowsError(try startResult.get())
        XCTAssertFalse(validationExpired); XCTAssertEqual(rig.starts,0); XCTAssertEqual(rig.bottom.calls,0)
        rig.validation = nil; try await rig.start(); try await rig.stop()
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
    }
    @MainActor func testTwoSourcesCompleteTheirProjectionBeforeSuccessorWriter() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start(twoSources:true)
        let first = try rig.owner.reserveInput(id:lifecycleID(700),track:0), second = try rig.owner.reserveInput(id:lifecycleID(701),track:1)
        let entered = XCTestExpectation(description:"first writer held"), done0 = XCTestExpectation(description:"first submit exited"), done1 = XCTestExpectation(description:"second submit exited")
        let held = LifecycleHeldOperation(entered)
        rig.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() } }
        var exited0 = false, exited1 = false
        let task0 = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>; do { try await rig.owner.submit(first,input:rig.input()); result = .success(()) } catch { result = .failure(error) }
            exited0 = true; done0.fulfill(); return result
        }
        defer { held.open(); Task { await rig.releaseStop() } }
        await fulfillment(of:[entered],timeout:2)
        let task1 = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>; do { try await rig.owner.submit(second,input:rig.input(track:1)); result = .success(()) } catch { result = .failure(error) }
            exited1 = true; done1.fulfill(); return result
        }
        held.open(); await fulfillment(of:[done0,done1],timeout:3)
        guard exited0,exited1 else { return }
        try await task0.value.get(); try await task1.value.get(); rig.bottom.observe = nil
        XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,2); XCTAssertEqual(rig.recognitions,0)
        try await rig.stop(); XCTAssertTrue(rig.store.actualHoldsDrained)
        rig.owner.reserveQuit(); try await rig.owner.committedDetach(); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
    }
    @MainActor func testConsumerExitDuringHeldDeletionIntentRetiresBorrowOnSuccessAndFailure() async throws {
        for consumerFailure in [false,true] {
            let rig = MeetingLifecycleRig(); rig.consumerFailure = consumerFailure
            try await rig.start(); try await rig.seal(); try await rig.stop()
            let consumerEntered = XCTestExpectation(description:"consumer entered"), consumerReturned = XCTestExpectation(description:"consumer returned")
            let heldIntent = XCTestExpectation(description:"intent held"), transcribed = XCTestExpectation(description:"transcription exited"), deleted = XCTestExpectation(description:"deletion exited")
            let earlyExit = XCTestExpectation(description:"no transcription exit before intent settles"); earlyExit.isInverted = true
            let held = LifecycleHeldOperation(heldIntent)
            rig.onConsumerEntered = { consumerEntered.fulfill() }; rig.onConsumerReturned = { consumerReturned.fulfill() }
            var transcriptionExited = false, deletionExited = false, checkingEarly = true
            let transcription = Task { () -> Result<Void,Error> in
                let result: Result<Void,Error>; do { try await rig.owner.transcribe(chunk:lifecycleID(1000),requested:lifecycleProvenance(false)); result = .success(()) } catch { result = .failure(error) }
                transcriptionExited = true; if checkingEarly { earlyExit.fulfill() }; transcribed.fulfill(); return result
            }
            defer { held.open(); Task { await rig.consumerExit.open(); await rig.releaseStop() } }
            await fulfillment(of:[consumerEntered],timeout:2)
            rig.bottom.observe = { operation,name in if operation == "exclusive-create",name?.hasSuffix(".delete") == true { held.holdOnce() } }
            let deletion = Task { () -> Result<Void,Error> in
                let result: Result<Void,Error>; do { try await rig.owner.delete(id:lifecycleID(90_000)); result = .success(()) } catch { result = .failure(error) }
                deletionExited = true; deleted.fulfill(); return result
            }
            await fulfillment(of:[heldIntent],timeout:2)
            await rig.consumerExit.open(); await fulfillment(of:[consumerReturned],timeout:2)
            await fulfillment(of:[earlyExit],timeout:0.05); checkingEarly = false
            held.open(); await fulfillment(of:[transcribed,deleted],timeout:3)
            guard transcriptionExited,deletionExited else { return }
            _ = await transcription.value; try await deletion.value.get(); rig.bottom.observe = nil
            XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.state,.idle); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
            XCTAssertTrue(rig.store.actualHoldsDrained); XCTAssertEqual(Set(rig.bottom.closes).count,rig.bottom.closes.count)
        }
    }
    @MainActor func testCancelingQuitCannotRevivePendingStartAuthority() async throws {
        let rig = MeetingLifecycleRig(), gate = MeetingDeadlineGate()
        let entered = XCTestExpectation(description:"validation entered"), done = XCTestExpectation(description:"start exited")
        var exited = false, validationExpired = false
        rig.validation = { entered.fulfill(); let opened = await gate.wait(); validationExpired = !opened; return opened }
        let starting = Task { () -> Result<Void,Error> in
            let result: Result<Void,Error>; do { try await rig.start(); result = .success(()) } catch { result = .failure(error) }
            exited = true; done.fulfill(); return result
        }
        defer { Task { await gate.open(); await rig.releaseStop() } }
        await fulfillment(of:[entered],timeout:2)
        rig.owner.reserveQuit(); rig.owner.cancelQuit(); await gate.open()
        await fulfillment(of:[done],timeout:2); guard exited else { return }
        let result = await starting.value; XCTAssertThrowsError(try result.get())
        XCTAssertFalse(validationExpired); XCTAssertEqual(rig.starts,0)
        // Finish any wrongly admitted RED-control work without hiding the failed assertions.
        if rig.owner.state == .recording { try await rig.stop() }
        rig.owner.reserveQuit(); if rig.owner.shutdownReady { try await rig.owner.committedDetach() }
    }
}

@MainActor private final class StreamOperation {
    let done = XCTestExpectation(description:"stream operation actually returned")
    private(set) var result: Result<Void,Error>?
    private(set) var task: Task<Void,Never>?
    init(_ operation: @escaping @MainActor () async throws -> Void) {
        task = Task {
            do { try await operation(); result = .success(()) } catch { result = .failure(error) }
            done.fulfill()
        }
    }
}
@MainActor private final class StreamingMeetingRig {
    let bottom = LifecycleMeetingBottom(), clock = LifecycleClock()
    let stopRequested = MeetingDeadlineGate(), allowExit = MeetingDeadlineGate()
    let store: MeetingSessionStore
    var owner: MeetingSessionOwner!, stream: MeetingAudioIngress?
    var starts = 0, recognitions = 0, stopRequests = 0, producerExited = false, gateTimedOut = false
    var initialSlots = 0, initialOpen = false, initialFrames: [Float] = [], tail: [Float] = [], notStarted = false
    var earlyEndFrames: Int?, earlyAccepted = 0
    var validation: (() async -> Bool)?, sourceReturned: XCTestExpectation?
    var sourceError: Error?
    init() {
        bottom.retainSourceBytes = true
        let clock = clock
        store = .init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{clock.value})
        owner = .init(store:store,microphone:.init(validate:{ [unowned self] _ in
            if let validation { return await validation() }; return true
        },start:{ [unowned self] selection,ingress in
            starts += 1; stream = ingress; initialSlots = ingress.facts.slots; initialOpen = ingress.facts.open
            if !initialFrames.isEmpty { do { _ = try input(initialFrames) } catch { sourceError = error } }
            if notStarted { return .init(source:selection.instance,exit:.notStarted) }
            if let frames = earlyEndFrames {
                do {
                    for offset in stride(from:0,to:frames,by:8_192) {
                        earlyAccepted += try input(Array(repeating:0,count:min(8_192,frames-offset)))
                    }
                    _ = try ingress.end(ingress.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0))
                } catch { sourceError = error; ingress.revoke() }
                return .init(source:selection.instance,exit:.actual(Task { [self] in
                    producerExited = true; sourceReturned?.fulfill()
                }))
            }
            return .init(source:selection.instance,exit:.actual(Task { [self] in
                let requested = await stopRequested.wait(), permitted = await allowExit.wait()
                gateTimedOut = !requested || !permitted
                if gateTimedOut { ingress.revoke() }
                do { _ = try tail.withUnsafeBufferPointer { try ingress.end(ingress.fence(),tail:$0) } }
                catch { sourceError = error }
                producerExited = true; sourceReturned?.fulfill()
            }))
        },requestStop:{ [unowned self] in stopRequests += 1; await stopRequested.open() }),recognition:.init(run:{ [unowned self] _,_ in
            recognitions += 1; return Task { .failure(LifecycleConsumerFailure.expected) }
        },requestCancel:{}),wallClock:{clock.value},holdEpoch:1)
    }
    func start() async throws {
        let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:lifecycleID(200),mapping:.unknown)
        try await owner.startMicrophone(owner:lifecycleID(1),session:lifecycleID(2),selection:.init(instance:lifecycleID(3),kind:.microphone,label:"",generation:7),
            segment:.init(id:lifecycleID(100),track:0,generation:7,timing:timing,canonicalStart:0))
    }
    @discardableResult func input(_ samples: [Float]) throws -> Int {
        let ingress = try XCTUnwrap(stream), body = try ingress.enter()
        defer { try? ingress.leave(body) }
        return try samples.withUnsafeBufferPointer { try ingress.receive(body,canonical:$0,input:.init(rate:16_000,channels:1,frames:samples.count)) }
    }
    func fill(_ frames: Int) throws {
        for offset in stride(from:0,to:frames,by:8_192) { let n = min(8_192,frames-offset); XCTAssertEqual(try input(Array(repeating:0,count:n)),n) }
    }
    func release() async { await allowExit.open() }
    var saved: [Data] {
        (bottom.rootNode?.children.values.filter { $0.name.hasSuffix(".wav") }.sorted { $0.name < $1.name } ?? []).map { $0.bytes(0,$0.length) }
    }
}

final class MeetingStreamingIngressLifecycleTests: XCTestCase {
    @MainActor private func completed(_ operation: StreamOperation) async -> Result<Void,Error>? {
        await fulfillment(of:[operation.done],timeout:4)
        guard let result = operation.result else { XCTFail("Operation held; not joining an unobserved exit"); return nil }
        if let task = operation.task { await task.value }
        return result
    }
    @MainActor private func detach(_ rig: StreamingMeetingRig) async throws {
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
        XCTAssertTrue(rig.bottom.descriptors.isEmpty); XCTAssertEqual(rig.recognitions,0); XCTAssertFalse(rig.gateTimedOut)
    }
    @MainActor func testSynchronousFirstPCMHasPrechargedSlotsAndStopSavesIndependentBytes() async throws {
        let rig = StreamingMeetingRig(); rig.initialFrames = [-1,0,0.5,1]; rig.tail = [-0.5]
        XCTAssertEqual(rig.bottom.calls,0); XCTAssertNil(rig.stream); XCTAssertEqual(rig.starts,0)
        try await rig.start(); XCTAssertEqual(rig.initialSlots,2); XCTAssertTrue(rig.initialOpen)
        XCTAssertEqual(rig.stream?.facts.allocated,2); XCTAssertThrowsError(try rig.owner.reserveInput(id:lifecycleID(800),track:0))
        await rig.release(); let stop = StreamOperation { try await rig.owner.stop() }
        guard let result = await completed(stop) else { return }; try result.get()
        XCTAssertNil(rig.sourceError); XCTAssertTrue(rig.producerExited); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,1)
        let file = try XCTUnwrap(rig.saved.first)
        let expected: [UInt8] = [82,73,70,70,46,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,
                                128,62,0,0,0,125,0,0,2,0,16,0,100,97,116,97,10,0,0,0,0,128,0,0,0,64,255,127,0,192]
        XCTAssertEqual(file,Data(expected)); XCTAssertEqual(rig.owner.projection.state,.stopped)
        XCTAssertEqual(rig.stream?.facts.slots,0); try await detach(rig)
    }
    @MainActor func testStopBeforePCMRetiresEmptySlotsWithoutUnknownOrPayload() async throws {
        let rig = StreamingMeetingRig(); try await rig.start(); await rig.release()
        let stopping = StreamOperation { try await rig.owner.stop() }
        guard let result = await completed(stopping) else { return }; try result.get()
        XCTAssertTrue(rig.saved.isEmpty); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,0)
        XCTAssertEqual(rig.owner.projection.state,.stopped); XCTAssertFalse(try XCTUnwrap(rig.stream).facts.unknown)
        XCTAssertEqual(rig.stream?.facts.allocated,2); XCTAssertEqual(rig.stream?.facts.copies,0); try await detach(rig)
    }
    @MainActor func testHeldWriterQuitCancelPreservesOnlySnapshottedDrainAndActualExits() async throws {
        let rig = StreamingMeetingRig(); try await rig.start()
        let entered = XCTestExpectation(description:"stream writer held"), returned = XCTestExpectation(description:"producer actually exited")
        let held = LifecycleHeldOperation(entered); rig.sourceReturned = returned
        rig.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() } }
        defer { held.open(); Task { await rig.release() } }
        try rig.fill(480_000); await fulfillment(of:[entered],timeout:3)
        let stream = try XCTUnwrap(rig.stream), lateBody = try stream.enter()
        // A second precharged slot is active while the writer owns the first; no third slot exists.
        let accepted = try [Float(0.5),-0.5].withUnsafeBufferPointer { try stream.receive(lateBody,canonical:$0,input:.init(rate:16_000,channels:1,frames:2)) }
        XCTAssertEqual(accepted,2); rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        let refused = try [Float(1)].withUnsafeBufferPointer { try stream.receive(lateBody,canonical:$0,input:.init(rate:16_000,channels:1,frames:1)) }
        XCTAssertEqual(refused,0); XCTAssertThrowsError(try stream.enter()); XCTAssertThrowsError(try stream.reserve(id:lifecycleID(900),slot:3))
        rig.owner.cancelQuit(); XCTAssertFalse(stream.facts.open); XCTAssertFalse(rig.owner.shutdownReady)
        let stopping = StreamOperation { try await rig.owner.stop() }
        XCTAssertFalse(rig.producerExited); try stream.leave(lateBody); await rig.release()
        await fulfillment(of:[returned],timeout:3)
        XCTAssertTrue(rig.producerExited); XCTAssertFalse(rig.owner.shutdownReady)
        held.open(); guard let result = await completed(stopping) else { return }; try result.get()
        rig.bottom.observe = nil
        XCTAssertFalse(held.didTimeOut); XCTAssertNil(rig.sourceError); XCTAssertEqual(rig.stopRequests,1)
        XCTAssertEqual(rig.owner.projection.acknowledgedChunks,2); XCTAssertEqual(rig.owner.projection.state,.stopped)
        let payloads = rig.saved.map { Data($0.dropFirst(44)) }
        XCTAssertTrue(payloads.contains(Data(repeating:0,count:960_000))); XCTAssertTrue(payloads.contains(Data([0,64,0,192])))
        XCTAssertEqual(stream.facts.allocated,2); XCTAssertEqual(stream.facts.copies,2); try await detach(rig)
    }
    @MainActor func testHeldWriterNormalStopAndCommittedQuitJoinActualBodies() async throws {
        for quit in [false,true] {
            let rig = StreamingMeetingRig(); try await rig.start()
            let entered = XCTestExpectation(description:"normal or quit writer held"), returned = XCTestExpectation(description:"source callback ownership actually exited")
            let held = LifecycleHeldOperation(entered); rig.sourceReturned = returned
            rig.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() } }
            defer { held.open(); Task { await rig.release() } }
            try rig.fill(480_000); await fulfillment(of:[entered],timeout:3)
            XCTAssertEqual(try rig.input([0.5]),1)
            let stream = try XCTUnwrap(rig.stream), body = try stream.enter()
            let operation = StreamOperation {
                if quit { let ready = await rig.owner.beginShutdown(); XCTAssertTrue(ready) }
                else { try await rig.owner.stop() }
            }
            let requested = await rig.stopRequested.wait(); XCTAssertTrue(requested)
            XCTAssertFalse(stream.facts.open); XCTAssertFalse(rig.producerExited); XCTAssertFalse(rig.owner.shutdownReady)
            XCTAssertThrowsError(try stream.enter())
            // An already entered body has to leave before EOS/producer exit; acknowledgment alone cannot retire it.
            try stream.leave(body); await rig.release(); await fulfillment(of:[returned],timeout:3)
            XCTAssertFalse(rig.owner.shutdownReady); held.open()
            guard let result = await completed(operation) else { return }; try result.get(); rig.bottom.observe = nil
            XCTAssertNil(rig.sourceError); XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,2)
            XCTAssertEqual(stream.facts.allocated,2); XCTAssertTrue(rig.store.actualHoldsDrained)
            if quit {
                XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach(); XCTAssertTrue(rig.bottom.descriptors.isEmpty)
            } else { try await detach(rig) }
        }
    }
    @MainActor func testHeldWriterPressureStopsWithoutThirdSlotAndRetainsPrefixUnknownCoverage() async throws {
        let rig = StreamingMeetingRig(); try await rig.start()
        let entered = XCTestExpectation(description:"pressure writer held"), held = LifecycleHeldOperation(entered)
        rig.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() } }
        defer { held.open(); Task { await rig.release() } }
        try rig.fill(480_000); await fulfillment(of:[entered],timeout:3); try rig.fill(479_999)
        XCTAssertEqual(try rig.input([0.5,1]),1)
        let stream = try XCTUnwrap(rig.stream); XCTAssertTrue(stream.facts.unknown); XCTAssertFalse(stream.facts.open)
        let requested = await rig.stopRequested.wait(); XCTAssertTrue(requested); XCTAssertEqual(rig.stopRequests,1)
        XCTAssertEqual(stream.facts.allocated,2); XCTAssertEqual(stream.facts.rawBytes,1_920_088)
        await rig.release(); let stopping = StreamOperation { try await rig.owner.stop() }; held.open()
        guard let result = await completed(stopping) else { return }; try result.get(); rig.bottom.observe = nil
        XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,2); XCTAssertEqual(rig.owner.projection.state,.interrupted)
        XCTAssertEqual(rig.saved.reduce(0) { $0+max(0,$1.count-44) },1_920_000); try await detach(rig)
    }
    @MainActor func testDeleteAndExpiryRevokeUnsubmittedPositiveTailBeforePublication() async throws {
        for expiry in [false,true] {
            let rig = StreamingMeetingRig(); try await rig.start(); XCTAssertEqual(try rig.input([0.5]),1)
            if expiry { rig.clock.value += MeetingSession.lifetime }
            let deleting = StreamOperation {
                if expiry { try await rig.owner.evaluateExpiry(deleteID:lifecycleID(90_000)) }
                else { try await rig.owner.delete(id:lifecycleID(90_000)) }
            }
            defer { Task { await rig.release() } }
            let requested = await rig.stopRequested.wait(); XCTAssertTrue(requested)
            XCTAssertFalse(try XCTUnwrap(rig.stream).facts.open); XCTAssertFalse(rig.owner.shutdownReady)
            XCTAssertThrowsError(try rig.input([1])); XCTAssertFalse(rig.producerExited)
            await rig.release(); guard let result = await completed(deleting) else { return }; try result.get()
            XCTAssertEqual(rig.owner.state,.idle); XCTAssertTrue(rig.bottom.descriptors.isEmpty); XCTAssertTrue(rig.saved.isEmpty)
            XCTAssertFalse(rig.bottom.events.contains(where:{$0.0 == "exclusive-create" && $0.1?.hasSuffix(".source.pending") == true}))
            XCTAssertEqual(rig.recognitions,0); XCTAssertFalse(rig.gateTimedOut)
        }
    }
    @MainActor func testDeleteDuringHeldStreamWriteRemainsNonpositiveOnStoreUncertainty() async throws {
        let rig = StreamingMeetingRig(); try await rig.start()
        let entered = XCTestExpectation(description:"delete holds existing stream write"), held = LifecycleHeldOperation(entered)
        let returned = XCTestExpectation(description:"revoked producer actually returned"); rig.sourceReturned = returned
        rig.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() } }
        defer { held.open(); Task { await rig.release() } }
        try rig.fill(480_000); await fulfillment(of:[entered],timeout:3); XCTAssertEqual(try rig.input([0.5]),1)
        let deleting = StreamOperation { try await rig.owner.delete(id:lifecycleID(90_000)) }
        let requested = await rig.stopRequested.wait(); XCTAssertTrue(requested)
        XCTAssertFalse(try XCTUnwrap(rig.stream).facts.open); XCTAssertFalse(rig.owner.shutdownReady)
        await rig.release(); await fulfillment(of:[returned],timeout:3)
        XCTAssertTrue(rig.producerExited); held.open()
        guard let result = await completed(deleting) else { return }; XCTAssertThrowsError(try result.get())
        // Revocation inside the existing physical phase is charged uncertainty, never a fabricated successful Delete.
        XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.state,.unavailable); XCTAssertEqual(rig.owner.concern,.firstIntentFailure)
        XCTAssertEqual(rig.owner.projection.acknowledgedChunks,0); rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        do { try await rig.owner.committedDetach(); XCTFail("Uncertain writer cannot detach") } catch { }
        XCTAssertEqual(rig.recognitions,0)
    }
    @MainActor func testQuitDuringValidationNeverStartsOrCollectsAfterCancellation() async throws {
        let rig = StreamingMeetingRig(), gate = MeetingDeadlineGate(), entered = XCTestExpectation(description:"stream validation entered")
        rig.validation = { entered.fulfill(); return await gate.wait() }
        let starting = StreamOperation { try await rig.start() }; defer { Task { await gate.open(); await rig.release() } }
        await fulfillment(of:[entered],timeout:2); rig.owner.reserveQuit(); XCTAssertFalse(rig.owner.shutdownReady)
        rig.owner.cancelQuit(); await gate.open()
        guard let result = await completed(starting) else { return }; XCTAssertThrowsError(try result.get())
        XCTAssertEqual(rig.starts,0); XCTAssertNil(rig.stream); XCTAssertEqual(rig.bottom.calls,0)
        try await detach(rig)
    }
    @MainActor func testDurableEdgesKeepExistingTooShortRuleAndUnknownTiming() async throws {
        for frames in [0,1,6_399,6_400,479_999,480_000] {
            let rig = StreamingMeetingRig(); try await rig.start(); try rig.fill(frames); await rig.release()
            let stopping = StreamOperation { try await rig.owner.stop() }
            guard let result = await completed(stopping) else { return }; try result.get()
            let ledger = try MeetingSession.Ledger.decode(rig.bottom.metadata)
            XCTAssertEqual(ledger.chunks.count,frames == 0 ? 0 : 1)
            if let chunk = ledger.chunks.first {
                XCTAssertEqual(chunk.stage,frames < 6_400 ? .tooShort : .sealed); XCTAssertEqual(chunk.frames,UInt64(frames))
                XCTAssertEqual(chunk.timing.mapping,.unknown); XCTAssertEqual(chunk.timing.pts,0); XCTAssertEqual(chunk.timing.sample,0)
                XCTAssertEqual(chunk.timing.denominator,1); XCTAssertEqual(chunk.start,0)
            }
            try await detach(rig)
        }
    }
    @MainActor func testLegacyReservedInputCannotBorrowStreamDrainAfterQuitCancellation() async throws {
        let rig = MeetingLifecycleRig(); try await rig.start()
        let ticket = try rig.owner.reserveInput(id:lifecycleID(700),track:0), input = try rig.input()
        rig.owner.reserveQuit(); rig.owner.cancelQuit()
        let writing = StreamOperation { try await rig.owner.submit(ticket,input:input) }
        guard let result = await completed(writing) else { return }; XCTAssertThrowsError(try result.get())
        XCTAssertEqual(rig.owner.projection.acknowledgedChunks,0)
        await rig.releaseStop(); let stopping = StreamOperation { try await rig.owner.stop() }
        guard let stopped = await completed(stopping) else { return }; try stopped.get()
        XCTAssertEqual(rig.owner.projection.state,.interrupted); XCTAssertEqual(rig.recognitions,0)
        rig.owner.reserveQuit(); XCTAssertTrue(rig.owner.shutdownReady); try await rig.owner.committedDetach()
    }
    @MainActor func testNotStartedOutcomeRetiresPrechargesAndCannotReviveSource() async throws {
        let rig = StreamingMeetingRig(); rig.notStarted = true
        let starting = StreamOperation { try await rig.start() }
        guard let result = await completed(starting) else { return }; XCTAssertThrowsError(try result.get())
        let stream = try XCTUnwrap(rig.stream); XCTAssertTrue(stream.facts.settled); XCTAssertFalse(stream.facts.open)
        XCTAssertThrowsError(try stream.enter()); XCTAssertTrue(rig.store.actualHoldsDrained); XCTAssertFalse(rig.owner.shutdownReady)
        // A deliberate Delete, rather than readiness or automatic restart, releases this retained failed session.
        let deleting = StreamOperation { try await rig.owner.delete(id:lifecycleID(90_000)) }
        guard let deleted = await completed(deleting) else { return }; try deleted.get()
        XCTAssertTrue(rig.bottom.descriptors.isEmpty); XCTAssertEqual(rig.starts,1)
    }

    @MainActor func testNonexpiredEvaluationWaitsAcrossHeldChunkPhasesWithoutRevokingCapture() async throws {
        let rig = StreamingMeetingRig(); try await rig.start()
        let entered = XCTestExpectation(description:"chunk B held before expiry evaluation")
        let held = LifecycleHeldOperation(entered)
        rig.bottom.observe = { operation,name in
            if operation == "write",name?.hasSuffix(".source.pending") == true { held.holdOnce() }
        }
        defer { held.open(); Task { await rig.release() } }
        try rig.fill(480_000); await fulfillment(of:[entered],timeout:3)
        let evaluating = XCTestExpectation(description:"normal evaluator entered while chunk B is held")
        let evaluation = StreamOperation {
            evaluating.fulfill()
            try await rig.owner.evaluateExpiry(deleteID:lifecycleID(90_000))
        }
        await fulfillment(of:[evaluating],timeout:2)
        held.open()
        guard let result = await completed(evaluation) else { return }
        do { try result.get() } catch { XCTFail("Non-expired evaluation refused: \(error)") }
        XCTAssertFalse(held.didTimeOut); XCTAssertEqual(rig.owner.state,.recording); XCTAssertNil(rig.owner.concern)
        let stream = try XCTUnwrap(rig.stream)
        XCTAssertTrue(stream.facts.open); XCTAssertFalse(stream.facts.unknown)
        if stream.facts.open { XCTAssertEqual(try rig.input([0.5]),1) }
        await rig.release()
        let stopping = StreamOperation { try await rig.owner.stop() }
        guard let stopped = await completed(stopping) else { return }
        do { try stopped.get() } catch { XCTFail("Stop after normal evaluation refused: \(error)") }
        rig.bottom.observe = nil
        if rig.owner.state == .stopped {
            XCTAssertEqual(rig.owner.projection.acknowledgedChunks,2)
            let payloads = rig.saved.map { Data($0.dropFirst(44)) }
            XCTAssertTrue(payloads.contains(Data(repeating:0,count:960_000)))
            XCTAssertTrue(payloads.contains(Data([0,64])))
            XCTAssertFalse(stream.facts.unknown); XCTAssertTrue(rig.store.actualHoldsDrained)
            try await detach(rig)
        }
    }
    @MainActor func testEndedBeforeObservationNeverReportsRecordingAndKeepsActualExitHold() async throws {
        for frames in [0,960_001] {
            let rig = StreamingMeetingRig(); rig.earlyEndFrames = frames
            let returned = XCTestExpectation(description:"early actual source task returned"); rig.sourceReturned = returned
            try await rig.start(); await fulfillment(of:[returned],timeout:2)
            let stream = try XCTUnwrap(rig.stream)
            XCTAssertTrue(stream.facts.ended); XCTAssertFalse(stream.facts.open); XCTAssertTrue(rig.producerExited)
            // Bounded convergence gives the coalesced observer an opportunity; it cannot create the missing state transition.
            for _ in 0..<100 {
                if rig.owner.state != .recording { break }
                try await Task.sleep(nanoseconds:1_000_000)
            }
            XCTAssertEqual(rig.owner.state,.stopping); XCTAssertEqual(rig.stopRequests,0)
            XCTAssertEqual(rig.earlyAccepted,min(frames,960_000)); XCTAssertThrowsError(try stream.enter())
            XCTAssertFalse(rig.owner.shutdownReady)
            let stopping = StreamOperation { try await rig.owner.stop() }
            guard let result = await completed(stopping) else { return }; try result.get()
            XCTAssertNil(rig.sourceError); XCTAssertEqual(rig.owner.projection.acknowledgedChunks,frames == 0 ? 0 : 2)
            XCTAssertEqual(rig.owner.projection.state,frames == 0 ? .stopped : .interrupted)
            XCTAssertEqual(rig.saved.reduce(0) { $0+max(0,$1.count-44) },min(frames,960_000)*2)
            XCTAssertTrue(rig.store.actualHoldsDrained); try await detach(rig)
        }
    }
}
