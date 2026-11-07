import Foundation

/// Inert meeting foundation. All synchronous filesystem phases are explicitly invoked by an off-actor caller.
public final class MeetingSessionStore: @unchecked Sendable {
    public typealias Failure = MeetingSession.Failure
    public enum Phase: String, Sendable {
        case admission, bootstrap, chunkA, chunkB, chunkC, resultReserve, resultWrite, resultPromote, resultRetire
        case keep, rawIntent, rawDelete, boundary, attemptBegin, attemptFinish, resultRead, stop, interrupted, expiry, deleteIntent, deleteSlice, deleteAuthority, deleteClose, borrowAcquire, borrowRelease, detach
    }
    public struct Cost: Equatable, Sendable {
        public let domain: MeetingRegistryDomain
        public let hashes: Int, hashBytes: UInt64, syncAttempts: Int, publications: Int
        public let validates: Int, enumerations: Int, fixed: Int, progress: Int, interrupts: Int, retirement: Int, path: Int
        public let opens: Int, closes: Int, carryIn: Int, carryOut: Int, peak: Int
        public var credits: Int { validates * 1600 + enumerations * 550 + fixed + progress + interrupts * 2 + retirement + path }
        init(_ r: SavedAudioImportStorage.MeetingLease.Receipt) { domain = r.domain; hashes = r.hashes; hashBytes = r.hashBytes; syncAttempts = r.syncAttempts; publications = r.publications; validates = r.validates; enumerations = r.enumerations; fixed = r.fixed; progress = r.progress; interrupts = r.interrupts; retirement = r.retirement; path = r.path; opens = r.opens; closes = r.closes; carryIn = r.carryIn; carryOut = r.carryOut; peak = r.peak }
    }
    public struct Receipt: Equatable, Sendable {
        fileprivate let context: MeetingStorageContext, epoch: UInt64
        public let session: UUID, sources: [UUID], revision: UInt64, phase: Phase, object: UUID?, generation: UInt64?, member: SavedAudioImportStorage.Member?, hash: String?, reservedBytes: Int64, deletionRemaining: Int?, cost: Cost
    }
    /// Diagnostic only; it never supplies publication/read/deletion authority.
    public struct FailureDiagnostic: Sendable {
        public let phase: Phase, cost: Cost, quarantined: Bool, borrowRetained: Bool, reservedBytes: Int64
    }
    public struct ChunkInput: Sendable {
        public let session: UUID, source: UUID, id: UUID, generation: UInt64, track: Int, sourceGeneration: UInt64, segment: UUID, sequence: UInt64, start: UInt64, frames: UInt64, timing: MeetingSession.Timing, bytes: Data, hash: String
        public init(session: UUID, source: UUID, id: UUID, generation: UInt64, track: Int, sourceGeneration: UInt64, segment: UUID, sequence: UInt64, start: UInt64, frames: UInt64, timing: MeetingSession.Timing, bytes: Data) throws {
            guard bytes.count <= MeetingSession.sourceBytes else { throw Failure.bounds }
            hash = SavedAudioImportStorage.digest(bytes)
            self.session = session; self.source = source; self.id = id; self.generation = generation; self.track = track; self.sourceGeneration = sourceGeneration; self.segment = segment; self.sequence = sequence; self.start = start; self.frames = frames; self.timing = timing; self.bytes = bytes
        }
    }
    /// Frozen bounded ingress, hashed outside the filesystem phase. It grants no storage authority.
    public struct ResultInput: Sendable {
        public let bytes: Data, hash: String
        public init(_ bytes: Data) throws {
            guard bytes.count > 0,bytes.count <= MeetingSession.resultBytes,let text = String(data:bytes,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw Failure.schema }
            self.bytes = bytes; hash = SavedAudioImportStorage.digest(bytes)
        }
    }
    public struct AttemptToken: Equatable, Sendable { fileprivate let context: MeetingStorageContext, epoch: UInt64; public let session: UUID, chunk: UUID, generation: UInt64, attempt: UUID, attemptGeneration: UInt64 }
    public struct BorrowToken: Equatable, Sendable { fileprivate let context: MeetingStorageContext, epoch: UInt64, serial: UInt64; public let session: UUID, chunk: UUID, generation: UInt64; fileprivate let attempt: UUID }
    public enum Worker: Hashable, Sendable { case microphone, system, microphoneCallback, systemCallback, writer, output }
    public struct Hold: Equatable, Sendable { fileprivate let context: MeetingStorageContext, epoch: UInt64, serial: UInt64, kind: Worker }
    public struct AcceptedMetadata: Equatable, Sendable {
        public let id: UUID, generation: UInt64, sourceHash: String, hash: String, bytes: Int
        public let requested: UUID, observed: UUID
    }
    public struct ChunkMetadata: Equatable, Sendable {
        public let id: UUID, generation: UInt64, source: UUID, sourceGeneration: UInt64
        public let track: Int, sequence: UInt64, canonicalStart: UInt64, frames: UInt64
        public let audioRemoved: Bool
        public let stage: MeetingSession.Stage, accepted: AcceptedMetadata?, lastAttempt: UInt64?
    }
    public struct Metadata: Equatable, Sendable {
        public enum Retirement: Equatable, Sendable { case none, retired, candidateUnavailable }
        public let session: UUID, owner: UUID, revision: UInt64, created: Int64, expires: Int64
        public let selections: [MeetingSession.Selection], chunks: [ChunkMetadata], provenance: [MeetingSession.Provenance]
        public let terminal: MeetingSession.Reason?, unknownCoverage: Bool, expired: Bool, deleting: Bool, unavailable: Bool
        public let kept: Bool, rawExpires: Int64?
        public let retirement: Retirement
    }
    /// Exclusion facts only; neither a payload grant nor reusable file authority.
    public struct Protection {
        public let root: URL, bindings: [URL], files: [URL], identities: Set<SavedAudioImportStorage.Identity>
        fileprivate let operation: UUID
    }
    private var protectionUncertain = false
    public var protectionQuarantined: Bool { lock.withLock { protectionUncertain || lease.poisoned } }
    public func metadata() throws -> Metadata? {
        try lock.withLock {
            guard let l = ledger else { if issue { throw Failure.unavailable }; return nil }
            guard l.chunks.count <= 240,l.provenance.count <= 32,l.tracks.count <= 2 else { throw Failure.bounds }
            // Bottom-up merge: <=8 passes and <=1920 comparisons/moves per buffer.
            var order = Array(l.chunks.indices), scratch = order, width = 1
            func before(_ a: Int,_ b: Int) throws -> Bool {
                let x = l.chunks[a], y = l.chunks[b]
                guard x.track != y.track || x.sequence != y.sequence else { throw Failure.schema }
                return x.track < y.track || (x.track == y.track && x.sequence < y.sequence)
            }
            while width < order.count {
                var start = 0
                while start < order.count {
                    let middle = min(start+width,order.count), end = min(start+width*2,order.count)
                    var a = start, b = middle
                    for out in start..<end {
                        let takeLeft: Bool
                        if a == middle { takeLeft = false } else if b == end { takeLeft = true } else { takeLeft = try before(order[a],order[b]) }
                        if takeLeft { scratch[out] = order[a]; a += 1 } else { scratch[out] = order[b]; b += 1 }
                    }
                    start = end
                }
                swap(&order,&scratch); width *= 2
            }
            let chunks = try order.map { i -> ChunkMetadata in
                let c = l.chunks[i]
                let accepted = try c.accepted.map { r -> AcceptedMetadata in
                    guard l.provenance.indices.contains(r.requested),l.provenance.indices.contains(r.observed) else { throw Failure.schema }
                    return .init(id:r.id,generation:r.generation,sourceHash:r.sourceHash,hash:r.hash,bytes:r.bytes,
                        requested:l.provenance[r.requested].id,observed:l.provenance[r.observed].id)
                }
                return .init(id:c.id,generation:c.generation,source:l.tracks[c.track].selection.instance,sourceGeneration:c.sourceGeneration,
                    track:c.track,sequence:c.sequence,canonicalStart:c.start,frames:c.frames,audioRemoved:c.audioRemoved,stage:c.stage,accepted:accepted,lastAttempt:c.attempt?.state.rawValue)
            }
            return .init(session:l.session,owner:l.owner,revision:l.revision,created:l.admitted,expires:l.expires,
                selections:l.tracks.map(\.selection),chunks:chunks,provenance:l.provenance,terminal:l.terminal?.reason,
                unknownCoverage:l.terminal.map { $0.mask != 0 } ?? false,expired:expired,
                deleting:l.state == .deleting || l.state == .authorityDead,unavailable:issue || interruptionPending,
                kept:l.retention?.keep ?? false,rawExpires:try rawDeadline(l),retirement:l.extra.map { $0.kind == .retired ? .retired : .candidateUnavailable } ?? .none)
        }
    }
    @discardableResult public func retireAcceptedReplacementIfNeeded(authorized: () -> Bool) throws -> Receipt? {
        let needed = try lock.withLock { () throws -> Bool in
            guard !issue,let l = ledger else { throw Failure.unavailable }
            guard let extra = l.extra else { return false }
            guard extra.kind == .retired else { throw Failure.unavailable }; return true
        }
        return needed ? try resultRetire(authorized:authorized) : nil
    }
    /// One synchronous action, two metadata passes, one Work through actual writer return.
    public func withExportProtection<T>(operation: UUID, authorized: () -> Bool,
        validateDestination: (Protection) throws -> Void, perform: () throws -> T) throws -> T {
        try lock.withLock {
            guard !issue,!protectionUncertain,!interruptionPending,!expired else { throw Failure.unavailable }
            if let l = ledger {
                guard l.state != .active,l.state != .deleting,l.state != .authorityDead,l.extra?.kind != .candidate,
                      let ownerMember,let ledgerMember else { throw Failure.held }
                return try lease.withLoadedProtection(authorized:authorized,catalog:{ names,lockMember in
                    let all = self.targets(l)
                    guard all.count <= 481,all.allSatisfy(\.exact) else { throw Failure.unavailable }
                    try self.audit(names,l)
                    var members: [String:Member] = ["lock":lockMember,"owner.json":ownerMember,"manifest.json":ledgerMember]
                    for t in all {
                        for name in t.aliases where names.contains(name) {
                            guard members.updateValue(t.member,forKey:name) == nil else { throw Failure.schema }
                        }
                    }
                    guard members.count == names.count,members.count <= 512 else { throw Failure.bounds }; return members
                },validate:{ bindings,files,identities in
                    try validateDestination(.init(root:self.lease.root,bindings:bindings,files:files,identities:identities,operation:operation))
                },perform:perform)
            }
            do {
                return try lease.withColdProtection(authorized:authorized,validate:{ bindings in
                    try validateDestination(.init(root:self.lease.root,bindings:bindings,files:[],identities:[],operation:operation))
                },perform:perform)
            } catch { if lease.coldProtectionUncertain { protectionUncertain = true }; throw error }
        }
    }
    private typealias Lease = SavedAudioImportStorage.MeetingLease
    private typealias Ledger = MeetingSession.Ledger
    private typealias J = MeetingJSON
    private typealias Member = SavedAudioImportStorage.Member
    private let lock = NSLock(), wallClock: () throws -> Int64
    private var lease: Lease, recoveryAvailable = false
    private var ledger: Ledger?, ledgerMember: Member?, ownerMember: Member?, issue = false, expired = false, interruptionPending = false
    private var lastClock: Int64?
    private var operationReceipt: Receipt?, failureDiagnostic: FailureDiagnostic?
    public var lastOperation: Receipt? { lock.withLock { operationReceipt } }
    public var lastFailure: FailureDiagnostic? { lock.withLock { failureDiagnostic } }
    public init(root: URL, profile: MeetingStorageProfile, bottom: MeetingStorageBottom, wallClock: @escaping () throws -> Int64) {
        lease = .init(root:root,profile:profile,bottom:bottom); self.wallClock = wallClock
    }
    public var projection: MeetingSession.Projection {
        lock.withLock {
            guard let l = ledger else { return issue ? .init(session:nil,state:nil,acknowledgedChunks:0,acceptedResults:0,expired:expired,unavailable:true) : .idle }
            return .init(session:l.session,state:interruptionPending && l.state == .active ? .interrupted : l.state,acknowledgedChunks:l.chunks.filter { $0.stage == .sealed || $0.stage == .tooShort }.count,
                acceptedResults:l.chunks.filter { $0.accepted != nil }.count,expired:expired,unavailable:issue)
        }
    }
    private func now(_ l: Ledger?, usable: Bool) throws -> Int64 {
        let n = try wallClock(); guard n >= 0, lastClock == nil || n >= lastClock! else { throw Failure.clock }
        if let l { guard n >= l.admitted, n >= l.clock else { throw Failure.clock }; if n >= l.expires && l.retention?.keep != true { expired = true; lease.fence(allWorkers:true); if usable { throw Failure.unavailable } } }
        lastClock = n; return n
    }
    /// Explicit evaluation only. Cached projection itself reads neither clocks nor storage.
    public func evaluate() throws { try lock.withLock { _ = try now(ledger,usable:false) } }
    private func ownerJSON(_ l: Ledger) -> J { .object([("d",.string("parla.meeting.1")),("v",.n(1)),("owner",.u(l.owner)),("session",.u(l.session)),("root",.array([.n(l.root.device),.n(l.root.inode)])),("created",.n(l.admitted)),("expires",.n(l.expires))]) }
    private func intentJSON(_ l: Ledger, id: UUID, freeze: UInt64) throws -> J {
        .object([("d",.string("parla.meeting.delete.1")),("v",.n(1)),("owner",.u(l.owner)),("session",.u(l.session)),("root",.array([.n(l.root.device),.n(l.root.inode)])),("generation",.n(try MeetingSession.add(freeze,1))),("freeze",.n(freeze)),("sources",.array(l.tracks.map { .u($0.selection.instance) })),("targetDigest",.string(l.targetDigest)),("count",.n(l.targets.count)),("slice",.n(2))])
    }
    private func authority(_ l: Ledger, usable: Bool, authorized: () -> Bool) throws {
        guard authorized() else { throw SavedAudioImportStorage.Failure.revoked }
        if usable { guard l.state != .deleting,l.state != .authorityDead else { throw Failure.unavailable } }
        _ = try now(l,usable:usable)
    }
    private func fresh(_ b: Lease.Work) throws -> (Ledger,Member,Set<String>) {
        try lease.checkpoint("entry",name:nil,fixed:33,b); try lease.validate(b)
        let names = try lease.names(b)
        guard names.contains("owner.json"), names.contains("manifest.json"), !names.contains("manifest.next") else { throw Failure.unavailable }
        let owner = try lease.read("owner.json",expected:ownerMember,cap:4096,hash:nil,collect:true,authorized:{},b)
        let current = try lease.read("manifest.json",expected:ledgerMember,cap:Int64(MeetingSession.deletionBytes),hash:nil,collect:true,authorized:{},b)
        try lease.checkpoint("closed-schema",name:"manifest.json",fixed:32,b)
        try b.charge(f:MeetingSession.timingValidationCredits)
        let l = try Ledger.decode(current.1)
        guard l.root == lease.identity, try J.parse(owner.1,cap:4096) == ownerJSON(l), ledger == nil || ledger == l else { throw Failure.unavailable }
        try audit(names,l)
        if let d = l.deletion {
            let intent = try lease.read(MeetingSession.uuid(l.session)+".delete",expected:d.member,cap:4096,hash:nil,collect:true,authorized:{},b)
            guard try J.parse(intent.1,cap:4096) == intentJSON(l,id:d.id,freeze:d.freeze) else { throw Failure.unavailable }
        }
        ownerMember = owner.0
        return (l,current.0,names)
    }
    private struct Target {
        let id: UUID, generation: UInt64, cap: Int64, hash: String, member: Member, aliases: [String], exact: Bool
    }
    private func targets(_ l: Ledger) -> [Target] {
        var out: [Target] = []
        for c in l.chunks {
            let aliases = c.aliases
            if !c.audioRemoved { out.append(.init(id:c.id,generation:c.generation,cap:Int64(MeetingSession.sourceBytes),hash:c.hash,member:c.member,aliases:aliases,exact:c.stage == .sealed || c.stage == .tooShort)) }
            if let r = c.accepted { out.append(.init(id:r.id,generation:r.generation,cap:Int64(MeetingSession.resultBytes),hash:r.hash,member:r.member,aliases:[MeetingSession.uuid(r.id)+".raw.txt"],exact:true)) }
        }
        if let e = l.extra {
            let r = e.result, aliases = e.kind == .candidate && e.stage == 2 ? [MeetingSession.uuid(r.id)+".result.pending",MeetingSession.uuid(r.id)+".raw.txt"] : [e.name]
            out.append(.init(id:r.id,generation:r.generation,cap:Int64(MeetingSession.resultBytes),hash:r.hash,member:r.member,aliases:aliases,exact:e.kind == .retired))
        }; return out
    }
    private func audit(_ names: Set<String>, _ l: Ledger) throws {
        var expected = Set(["lock","owner.json","manifest.json"])
        if l.deletion != nil { expected.insert(MeetingSession.uuid(l.session)+".delete") }
        let all = targets(l)
        for (i,t) in all.enumerated() {
            let present = t.aliases.filter { names.contains($0) }
            let mayBeMissing: Bool
            if let d = l.deletion { mayBeMissing = i < min(d.count,d.cursor+2) || l.retention?.removing == t.id } else { mayBeMissing = (l.extra?.kind == .retired && i == all.count-1) || l.retention?.removing == t.id }
            if let d = l.deletion, i < d.cursor { guard present.isEmpty else { throw Failure.unavailable } }
            else { guard present.count == 1 || (present.isEmpty && mayBeMissing) else { throw Failure.unavailable } }
            expected.formUnion(present)
        }
        guard expected == names else { throw Failure.unavailable }
    }
    private func publish(_ next: Ledger, replacing old: Member?, tier: Int, authorized: () -> Bool, usable: Bool, _ b: Lease.Work) throws -> Member {
        try lease.checkpoint("encode-ledger",name:"manifest.next",fixed:32,b)
        let bytes = try next.encoded(tier:tier)
        let (token,registered) = try lease.create("manifest.next",cap:Int64(MeetingSession.deletionBytes),b)
        let inputHash = try lease.write(bytes,token:token,name:"manifest.next",registered:registered,metadata:true,authorized:{ try self.authority(next,usable:usable,authorized:authorized) },b)
        let written = try lease.syncClose(token,name:"manifest.next",registered:registered,cap:Int64(bytes.count),authorized:{ try self.authority(next,usable:usable,authorized:authorized) },b)
        guard written.bytes == Int64(bytes.count) else { throw Failure.schema }
        let verified = try lease.read("manifest.next",expected:written,cap:Int64(bytes.count),hash:inputHash,collect:true,authorized:{ try self.authority(next,usable:usable,authorized:authorized) },b)
        // The writer already validated and canonically encoded next. Exact byte equality verifies the round trip without a second untrusted decode.
        guard verified.1 == bytes else { throw Failure.schema }
        let current = try lease.rename("manifest.next",member:written,to:"manifest.json",replacing:old,authorized:{ try self.authority(next,usable:usable,authorized:authorized) },b)
        try lease.checkpoint("publication",name:"manifest.json",fixed:18,b); try lease.validate(b); try authority(next,usable:usable,authorized:authorized); return current
    }
    private func receipt(_ l: Ledger, phase: Phase, object: UUID?, generation: UInt64?, member: Member?, hash: String?, cost: Lease.Receipt) -> Receipt {
        let result = Receipt(context:lease.context,epoch:lease.currentEpoch,session:l.session,sources:l.tracks.map { $0.selection.instance },revision:l.revision,phase:phase,object:object,generation:generation,member:member,hash:hash,reservedBytes:MeetingSession.reservation,deletionRemaining:l.deletion.map { $0.count - $0.cursor },cost:.init(cost))
        operationReceipt = result; return result
    }
    private func recordFailure(_ phase: Phase, _ b: Lease.Work) {
        failureDiagnostic = .init(phase:phase,cost:.init(lease.snapshot(b)),quarantined:lease.poisoned,borrowRetained:lease.hasBorrow,reservedBytes:MeetingSession.reservation)
    }
    private func current(_ receipt: Receipt, _ l: Ledger, phase: Phase? = nil) throws {
        guard receipt.context == lease.context,receipt.epoch == lease.currentEpoch,receipt.session == l.session, receipt.sources == l.tracks.map({$0.selection.instance}), receipt.revision == l.revision, phase == nil || receipt.phase == phase else { throw Failure.stale }
    }
    private func transaction(_ phase: Phase, token: Receipt?, usable: Bool, tier: Int, authorized: () -> Bool,
                             mutate: (inout Ledger,Lease.Work,Set<String>) throws -> (UUID?,UInt64?,Member?,String?)) throws -> Receipt {
        try lock.withLock {
            guard !issue, !interruptionPending || phase == .interrupted || phase == .deleteIntent || phase == .expiry else { throw Failure.unavailable }
            if phase == .deleteSlice || phase == .deleteAuthority { guard lease.drained else { throw Failure.held } }
            let b = try lease.begin()
            var cleanEntry: Ledger?
            do {
                let (old,member,names) = try fresh(b)
                cleanEntry = old
                try authority(old,usable:usable,authorized:authorized)
                if old.deletion != nil { guard phase == .deleteSlice || phase == .deleteAuthority else { throw Failure.stale } }
                if let token { try current(token,old) }
                var next = old
                let object = try mutate(&next,b,names)
                next.revision = try MeetingSession.add(old.revision,1)
                if tier == MeetingSession.ordinaryBytes { guard next.revision <= UInt64.max - 245 else { throw Failure.bounds } }
                next.clock = min(try now(old,usable:usable),old.expires)
                try b.charge(f:MeetingSession.timingValidationCredits)
                let written = try publish(next,replacing:member,tier:tier,authorized:authorized,usable:usable,b)
                try audit(lease.names(b),next)
                let cost = try lease.finish(b)
                ledger = next; ledgerMember = written; interruptionPending = false
                return receipt(next,phase:phase,object:object.0,generation:object.1,member:object.2,hash:object.3,cost:cost)
            } catch {
                let original = error
                if !b.mutated,!lease.poisoned,let cleanEntry {
                    do { try audit(lease.names(b),cleanEntry); _ = try lease.finish(b) }
                    catch { lease.fail(b); issue = true; throw error }
                } else { lease.fail(b); issue = true; recordFailure(phase,b) }
                throw original
            }
        }
    }
    public func admit(owner: UUID, session: UUID, selections: [MeetingSession.Selection], segments: [MeetingSession.Segment], authorized: () -> Bool) throws -> Receipt {
        try lock.withLock {
            guard ledger == nil, !issue, !selections.isEmpty, selections.count <= 2, segments.count == selections.count else { throw Failure.bounds }
            let n = try now(nil,usable:false), end = try MeetingSession.add(n,MeetingSession.RecordingPolicy.transcriptRetention)
            let b = try lease.begin(cold:true)
            do {
                guard try lease.acquire(create:true,b), let root = lease.identity else { throw Failure.unavailable }
                guard try lease.names(b) == Set(["lock"]) else { throw Failure.unavailable }
                let tracks = selections.enumerated().map { i,s in MeetingSession.Track(selection:s,epoch:segments[i].timing.epoch,captured:0,sequence:0,segment:i) }
                var l = Ledger(owner:owner,session:session,root:root,admitted:n,expires:end,revision:0,clock:n,state:.active,tracks:tracks,segments:segments,gaps:[],provenance:[],chunks:[],extra:nil,terminal:nil,deletion:nil)
                l.retention = .init()
                try b.charge(f:MeetingSession.timingValidationCredits)
                let marker = ownerJSON(l).bytes; _ = try l.encoded(tier:MeetingSession.ordinaryBytes)
                let (token,registered) = try lease.create("owner.json",cap:4096,b)
                let auth = { try self.authority(l,usable:true,authorized:authorized) }
                let inputHash = try lease.write(marker,token:token,name:"owner.json",registered:registered,metadata:true,authorized:auth,b)
                let ownerMember = try lease.syncClose(token,name:"owner.json",registered:registered,cap:4096,authorized:auth,b)
                _ = try lease.read("owner.json",expected:ownerMember,cap:4096,hash:inputHash,collect:false,authorized:auth,b)
                try lease.syncDirectory(b)
                try b.charge(f:MeetingSession.timingValidationCredits)
                let current = try publish(l,replacing:nil,tier:MeetingSession.ordinaryBytes,authorized:authorized,usable:true,b)
                try audit(lease.names(b),l); let cost = try lease.finish(b)
                ledger = l; ledgerMember = current; self.ownerMember = ownerMember; expired = false; interruptionPending = false
                return receipt(l,phase:.admission,object:nil,generation:nil,member:nil,hash:nil,cost:cost)
            } catch { lease.fail(b,cold:true); issue = true; recordFailure(.admission,b); throw error }
        }
    }
    /// Metadata only. Discard an unpublished next generation only after auditing the committed authority.
    public func bootstrap() throws -> MeetingSession.Projection {
        try lock.withLock {
            guard ledger == nil, !issue else { throw Failure.unavailable }
            let b = try lease.begin(cold:true)
            do {
                guard try lease.acquire(create:false,recoveringEmpty:true,b) else { _ = try lease.finish(b); return .idle }
                // Acquisition already performed the entry V; omit the duplicate warm-entry charge/validation.
                let names = try lease.names(b)
                if names == ["lock"] {
                    try lease.unlinkLock(b); try lease.syncDirectory(b); try lease.finalClose(b)
                    _ = try lease.finish(b); return .idle
                }
                guard names.contains("owner.json"),names.contains("manifest.json") else { throw Failure.unavailable }
                let owner = try lease.read("owner.json",expected:nil,cap:4096,hash:nil,collect:true,authorized:{},b)
                let current = try lease.read("manifest.json",expected:nil,cap:Int64(MeetingSession.deletionBytes),hash:nil,collect:true,authorized:{},b)
                try lease.checkpoint("closed-schema",name:nil,fixed:32,b)
                try b.charge(f:MeetingSession.timingValidationCredits)
                let l = try Ledger.decode(current.1)
                guard l.root == lease.identity, try J.parse(owner.1,cap:4096) == ownerJSON(l) else { throw Failure.unavailable }
                try audit(names.subtracting(["manifest.next"]),l)
                if names.contains("manifest.next") {
                    // Full namespace/committed manifest validation precedes this one bounded unlink.
                    let next = try lease.inspect("manifest.next",cap:Int64(MeetingSession.deletionBytes),b)
                    try lease.unlink("manifest.next",member:next,cap:next.bytes,exact:true,missingAllowed:false,b)
                    try lease.syncDirectory(b)
                }
                _ = try now(l,usable:false)
                try lease.validate(b); try audit(lease.names(b),l); let cost = try lease.finish(b)
                _ = receipt(l,phase:.bootstrap,object:nil,generation:nil,member:nil,hash:nil,cost:cost)
                ledger = l; ledgerMember = current.0; ownerMember = owner.0; interruptionPending = l.state == .active || l.chunks.contains { $0.attempt?.state == .pending }
                return .init(session:l.session,state:interruptionPending && l.state == .active ? .interrupted : l.state,acknowledgedChunks:l.chunks.filter { $0.stage == .sealed || $0.stage == .tooShort }.count,acceptedResults:l.chunks.filter { $0.accepted != nil }.count,expired:expired,unavailable:false)
            } catch { lease.fail(b,cold:true); issue = true; recoveryAvailable = true; recordFailure(.bootstrap,b); throw error }
        }
    }
    /// Explicit destructive recovery is available only after a cold failure retired all descriptors.
    public var canDeleteUnavailableMeetingData: Bool {
        lock.withLock { recoveryAvailable && issue && ledger == nil && lease.drained && lease.rawCount == 0 && !lease.poisoned && !protectionUncertain }
    }
    public func deleteAllUnavailableMeetingData(authorized: () -> Bool) throws {
        try lock.withLock {
            guard recoveryAvailable,issue,ledger == nil,lease.drained,lease.rawCount == 0,!lease.poisoned,!protectionUncertain,authorized() else { throw Failure.held }
            // A clean cold failure closed the old lease. Acquire and lock the same private root anew.
            lease = Lease(root:lease.root,profile:lease.profile,bottom:lease.bottom)
            var work = try lease.begin(cold:true)
            do {
                guard try lease.acquire(create:false,recoveringEmpty:true,work) else {
                    _ = try lease.finish(work); issue = false; recoveryAvailable = false; return
                }
                let names = try lease.names(work)
                if names == ["lock"] {
                    guard authorized() else { throw Failure.stale }
                    try lease.unlinkLock(work); try lease.syncDirectory(work); try lease.finalClose(work)
                    _ = try lease.finish(work); issue = false; recoveryAvailable = false; return
                }
                guard names.contains("owner.json") else { throw Failure.unavailable }
                let owner = try lease.read("owner.json",expected:nil,cap:4096,hash:nil,collect:true,authorized:{ guard authorized() else { throw Failure.stale } },work)
                let f = try J.parse(owner.1,cap:4096).fields(["d","v","owner","session","root","created","expires"])
                guard f["d"] == .string("parla.meeting.1"),f["v"] == .n(1),let identity = lease.identity,
                      f["root"] == .array([.n(identity.device),.n(identity.inode)]) else { throw Failure.unavailable }
                _ = try f["owner"]!.id(); let session = try f["session"]!.id()
                let created = try f["created"]!.int(), expires = try f["expires"]!.int()
                guard created >= 0,expires > created else { throw Failure.schema }
                _ = try lease.finish(work)
                // Preflight EVERY name and private regular-file identity before the first unlink.
                // Never infer targets from an invalid manifest, recurse, or remove unknown contents.
                var members: [(String,Member)] = []
                for name in names.subtracting(["lock"]).sorted() {
                    let cap: Int64
                    if name == "owner.json" { cap = 4096 }
                    else if name == "manifest.json" || name == "manifest.next" { cap = Int64(MeetingSession.deletionBytes) }
                    else if name == MeetingSession.uuid(session)+".delete" { cap = 4096 }
                    else {
                        let suffixes = [".source.pending",".source.wav",".result.pending",".raw.txt"]
                        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }),
                              let id = UUID(uuidString:String(name.dropLast(suffix.count))),
                              name == MeetingSession.uuid(id)+suffix else { throw Failure.unavailable }
                        cap = Int64(suffix.hasPrefix(".source") ? MeetingSession.sourceBytes : MeetingSession.resultBytes)
                    }
                    work = try lease.begin()
                    let member = try lease.inspect(name,cap:cap,work)
                    members.append((name,member)); _ = try lease.finish(work)
                }
                // Preserve authority metadata until all payloads are gone so an interrupted wipe can retry.
                let ordered = members.filter { $0.0 != "owner.json" && $0.0 != "manifest.json" } + members.filter { $0.0 == "manifest.json" } + members.filter { $0.0 == "owner.json" }
                for (name,member) in ordered {
                    guard authorized() else { throw Failure.stale }
                    work = try lease.begin()
                    try lease.unlink(name,member:member,cap:member.bytes,exact:true,missingAllowed:false,work)
                    try lease.syncDirectory(work); _ = try lease.finish(work)
                }
                work = try lease.begin()
                guard try lease.names(work) == ["lock"],authorized() else { throw Failure.unavailable }
                try lease.unlinkLock(work); try lease.syncDirectory(work); try lease.finalClose(work); _ = try lease.finish(work)
                issue = false; recoveryAvailable = false; expired = false; lastClock = nil
                ledgerMember = nil; ownerMember = nil; interruptionPending = false
            } catch { lease.fail(work,final:true); recordFailure(.deleteClose,work); throw error }
        }
    }
    private func canonical(_ input: ChunkInput) throws {
        guard input.frames > 0, input.frames <= MeetingSession.maximumFrames, input.bytes.count == Int(44 + input.frames * 2) else { throw Failure.bounds }
        let b = input.bytes
        func little(_ offset: Int, _ width: Int) -> UInt64 { (0..<width).reduce(0) { $0 | UInt64(b[offset+$1]) << ($1*8) } }
        guard b.prefix(4) == Data("RIFF".utf8), b[8..<16] == Data("WAVEfmt ".utf8), little(4,4) == UInt64(b.count-8),
            little(16,4) == 16, little(20,2) == 1, little(22,2) == 1, little(24,4) == 16_000, little(28,4) == 32_000,
            little(32,2) == 2, little(34,2) == 16, b[36..<40] == Data("data".utf8), little(40,4) == input.frames*2 else { throw Failure.schema }
    }
    public func chunkA(_ input: ChunkInput, authorized: () -> Bool) throws -> Receipt {
        try canonical(input)
        return try transaction(.chunkA,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            guard l.state == .active, l.chunks.count < 240, l.tracks.indices.contains(input.track), let segment = l.segments.firstIndex(where:{$0.id == input.segment}) else { throw Failure.bounds }
            let t = l.tracks[input.track]
            guard input.session == l.session,input.source == t.selection.instance,input.sourceGeneration == t.selection.generation, input.sequence == t.sequence, input.start == t.captured, segment == t.segment,
                input.timing.epoch == t.epoch, try MeetingSession.add(t.captured,input.frames) <= MeetingSession.maximumTrackFrames,
                !MeetingSession.reserved(input.id,session:l.session),!l.chunks.contains(where:{$0.id == input.id}) else { throw Failure.stale }
            // Known timing refusal must precede exclusive allocation, leaving clean authority usable.
            try b.charge(f:MeetingSession.timingValidationCredits)
            try l.validateTiming(adding:(input.track,input.sourceGeneration,segment,input.sequence,input.start,input.frames,input.timing))
            let name = MeetingSession.uuid(input.id)+".source.pending"
            let (token,registered) = try self.lease.create(name,cap:Int64(MeetingSession.sourceBytes),b)
            let zero = try self.lease.syncClose(token,name:name,registered:registered,cap:0,authorized:{try self.authority(l,usable:true,authorized:authorized)},b)
            l.chunks.append(.init(id:input.id,generation:input.generation,track:input.track,sourceGeneration:input.sourceGeneration,segment:segment,sequence:input.sequence,start:input.start,frames:input.frames,bytes:input.bytes.count,hash:input.hash,timing:input.timing,member:zero,stage:.registered,accepted:nil,attempt:nil))
            l.tracks[input.track].captured = try MeetingSession.add(t.captured,input.frames); l.tracks[input.track].sequence = try MeetingSession.add(t.sequence,1)
            try self.lease.checkpoint("allocation-registered",name:name,fixed:34,b)
            return (input.id,input.generation,zero,input.hash)
        }
    }
    private func chunkIndex(_ receipt: Receipt, _ l: Ledger, stage: MeetingSession.Stage) throws -> Int {
        guard let i = l.chunks.firstIndex(where:{$0.id == receipt.object}), l.chunks[i].generation == receipt.generation,
            l.chunks[i].member == receipt.member, l.chunks[i].hash == receipt.hash, l.chunks[i].stage == stage else { throw Failure.stale }; return i
    }
    public func chunkB(_ receipt: Receipt, bytes: Data, authorized: () -> Bool) throws -> Receipt {
        guard receipt.phase == .chunkA else { throw Failure.stale }
        return try transaction(.chunkB,token:receipt,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            let i = try self.chunkIndex(receipt,l,stage:.registered), c = l.chunks[i]
            guard bytes.count == c.bytes, !self.lease.isBorrowed(c.member) else { throw Failure.stale }
            let token = try self.lease.writeOpen(c.pending,member:c.member,cap:Int64(c.bytes),b), auth = { try self.authority(l,usable:true,authorized:authorized) }
            let inputHash = try self.lease.write(bytes,token:token,name:c.pending,registered:c.member,metadata:false,authorized:auth,b)
            guard inputHash == c.hash else { throw Failure.schema }
            let m = try self.lease.syncClose(token,name:c.pending,registered:c.member,cap:Int64(c.bytes),authorized:auth,b)
            guard m.bytes == Int64(c.bytes) else { throw Failure.schema }
            _ = try self.lease.read(c.pending,expected:m,cap:Int64(c.bytes),hash:c.hash,collect:false,authorized:auth,b)
            l.chunks[i].member = m; l.chunks[i].stage = .written; return (c.id,c.generation,m,c.hash)
        }
    }
    public func chunkC(_ receipt: Receipt, authorized: () -> Bool) throws -> Receipt {
        guard receipt.phase == .chunkB else { throw Failure.stale }
        return try transaction(.chunkC,token:receipt,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            let i = try self.chunkIndex(receipt,l,stage:.written), c = l.chunks[i], auth = { try self.authority(l,usable:true,authorized:authorized) }
            _ = try self.lease.read(c.pending,expected:c.member,cap:Int64(c.bytes),hash:c.hash,collect:false,authorized:auth,b)
            let m = try self.lease.rename(c.pending,member:c.member,to:c.final,replacing:nil,authorized:auth,b)
            l.chunks[i].member = m; l.chunks[i].stage = c.frames < 6400 ? .tooShort : .sealed; return (c.id,c.generation,m,c.hash)
        }
    }
    /// Explicit segment/gap metadata uses the same single-publication bound as a terminal phase.
    public func boundary(session: UUID, source: UUID, segment: MeetingSession.Segment?, gap: MeetingSession.Gap?, evidence: MeetingSession.Timing?, authorized: () -> Bool) throws -> Receipt {
        guard segment != nil || gap != nil else { throw Failure.schema }
        return try transaction(.boundary,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,_,_ in
            guard l.session == session,l.state == .active else { throw Failure.stale }
            if let s = segment {
                guard l.segments.count < 240 else { throw Failure.detailExhausted }
                guard l.tracks.indices.contains(s.track),s.generation == l.tracks[s.track].selection.generation,l.tracks[s.track].selection.instance == source,s.canonicalStart == l.tracks[s.track].captured else { throw Failure.bounds }
                l.segments.append(s); l.tracks[s.track].segment = l.segments.count-1; l.tracks[s.track].epoch = s.timing.epoch
            }
            if let g = gap {
                guard l.gaps.count < 240 else { throw Failure.detailExhausted }
                guard l.tracks.indices.contains(g.track),g.segment == l.tracks[g.track].segment,l.tracks[g.track].selection.instance == source,g.sequence == l.tracks[g.track].sequence else { throw Failure.bounds }
                let s = l.segments[g.segment]
                if s.timing.mapping == .validated {
                    guard let evidence,evidence.epoch == s.timing.epoch,evidence.mapping == .validated,evidence.rate == s.timing.rate,evidence.sample >= s.timing.sample,evidence.pts == g.start,evidence.denominator == g.startDenominator else { throw Failure.schema }
                    try evidence.validate()
                }
                if g.kind == .measured { guard s.timing.mapping == .validated else { throw Failure.schema }; _ = try g.end() }
                l.gaps.append(g); l.tracks[g.track].sequence = try MeetingSession.add(g.sequence,1)
            }
            return (nil,nil,nil,nil)
        }
    }
    public func terminal(reason: MeetingSession.Reason, unknownMask: UInt64, generation: UInt64, holdEpoch: UInt64, flags: UInt64, authorized: () -> Bool) throws -> Receipt {
        let phase: Phase = reason == .expiry ? .expiry : reason == .interrupted ? .interrupted : .stop
        return try transaction(phase,token:nil,usable:false,tier:MeetingSession.terminalBytes,authorized:authorized) { l,_,_ in
            guard l.state != .deleting,l.state != .authorityDead,self.lease.drained else { throw Failure.held }
            let frames = (0..<2).map { l.tracks.indices.contains($0) ? l.tracks[$0].captured : 0 }
            if reason == .interrupted {
                for i in l.chunks.indices where l.chunks[i].attempt?.state == .pending { l.chunks[i].attempt?.state = .canceled }
                // Interrupted recognition cannot rewrite an already committed capture's terminal coverage.
                if l.state != .active { return (nil,nil,nil,nil) }
            }
            l.terminal = .init(reason:reason,mask:unknownMask & UInt64((1 << l.tracks.count)-1),generation:generation,frames:frames,epoch:holdEpoch,flags:flags,errors:reason == .normalStop ? [] : [reason])
            l.state = reason == .normalStop ? .stopped : .interrupted
            return (nil,nil,nil,nil)
        }
    }
    private func registry(_ p: MeetingSession.Provenance, _ l: inout Ledger) throws -> Int {
        try p.validate()
        if let i = l.provenance.firstIndex(of:p) { return i }
        guard !MeetingSession.reserved(p.id,session:l.session),l.provenance.count < 32, !l.provenance.contains(where:{$0.id == p.id}) else { throw Failure.bounds }; l.provenance.append(p); return l.provenance.count-1
    }
    public func beginAttempt(chunk: UUID, requested: MeetingSession.Provenance, authorized: () -> Bool) throws -> AttemptToken {
        let receipt = try transaction(.attemptBegin,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,_,_ in
            guard l.state != .active,l.state != .deleting,l.state != .authorityDead,l.extra == nil,!l.chunks.contains(where:{$0.attempt?.state == .pending}),requested.role == .requested,
                let i = l.chunks.firstIndex(where:{$0.id == chunk && !$0.audioRemoved && l.retention?.removing != $0.id}),l.chunks[i].stage == .sealed else { throw Failure.stale }
            let registry = try self.registry(requested,&l)
            let generation = try MeetingSession.add(l.revision,1), attempt = MeetingSession.allocation(l.session,role:.attempt,generation:generation)
            l.chunks[i].attempt = .init(id:attempt,generation:generation,requested:registry,state:.pending)
            return (attempt,generation,nil,nil)
        }
        guard let l = lock.withLock({ledger}),let c = l.chunks.first(where:{$0.id == chunk}),let a = c.attempt,receipt.object == a.id else { throw Failure.stale }
        return .init(context:receipt.context,epoch:receipt.epoch,session:receipt.session,chunk:chunk,generation:c.generation,attempt:a.id,attemptGeneration:a.generation)
    }
    private func attemptIndex(_ token: AttemptToken, _ l: Ledger) throws -> Int {
        guard token.context == lease.context,token.epoch == lease.currentEpoch,token.session == l.session,let i = l.chunks.firstIndex(where:{$0.id == token.chunk}),l.chunks[i].generation == token.generation,
            let a = l.chunks[i].attempt,a.id == token.attempt,a.generation == token.attemptGeneration,a.state == .pending else { throw Failure.stale }; return i
    }
    public func cancelAttempt(_ token: AttemptToken, authorized: () -> Bool) throws -> Receipt { try finishAttempt(token,canceled:true,authorized:authorized) }
    public func finishAttempt(_ token: AttemptToken, canceled: Bool, authorized: () -> Bool) throws -> Receipt {
        try transaction(.attemptFinish,token:nil,usable:false,tier:MeetingSession.terminalBytes,authorized:authorized) { l,_,_ in
            let i = try self.attemptIndex(token,l); l.chunks[i].attempt?.state = canceled ? .canceled : .failed; return (token.chunk,token.generation,nil,nil)
        }
    }
    public func resultReserve(_ token: AttemptToken, borrow: BorrowToken, input: ResultInput, observed: MeetingSession.Provenance, authorized: () -> Bool) throws -> Receipt {
        let bytes = input.bytes
        guard observed.role == .observed else { throw Failure.schema }
        return try transaction(.resultReserve,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            let i = try self.attemptIndex(token,l)
            guard l.extra == nil, borrow.session == l.session, borrow.chunk == token.chunk, borrow.generation == token.generation, borrow.attempt == token.attempt, self.lease.matchesBorrow(.init(context:borrow.context,epoch:borrow.epoch,serial:borrow.serial),member:l.chunks[i].member) else { throw Failure.bounds }
            let accepted = l.chunks.reduce(0) { $0 + ($1.accepted?.bytes ?? 0) }, old = l.chunks[i].accepted?.bytes ?? 0
            guard try MeetingSession.add(accepted-old,bytes.count) <= MeetingSession.resultAggregate else { throw Failure.bounds }
            let generation = try MeetingSession.add(l.revision,1), result = MeetingSession.allocation(l.session,role:.result,generation:generation), retirementAuthority = MeetingSession.allocation(l.session,role:.retirement,generation:generation)
            let observed = try self.registry(observed,&l), name = MeetingSession.uuid(result)+".result.pending", c = l.chunks[i]
            let (fd,registered) = try self.lease.create(name,cap:Int64(MeetingSession.resultBytes),b)
            let zero = try self.lease.syncClose(fd,name:name,registered:registered,cap:0,authorized:{try self.authority(l,usable:true,authorized:authorized)},b)
            let r = MeetingSession.Result(id:result,generation:generation,attempt:token.attempt,source:c.id,sourceGeneration:c.generation,sourceHash:c.hash,bytes:bytes.count,hash:input.hash,member:zero,requested:c.attempt!.requested,observed:observed,created:try self.now(l,usable:true))
            l.extra = .init(kind:.candidate,chunk:i,result:r,stage:0,authority:retirementAuthority)
            try self.lease.checkpoint("allocation-registered",name:name,fixed:34,b); return (result,generation,zero,r.hash)
        }
    }
    private func candidate(_ receipt: Receipt, _ l: Ledger, stage: UInt64) throws -> MeetingSession.Extra {
        guard let e = l.extra,e.kind == .candidate,e.stage == stage,e.result.id == receipt.object,e.result.generation == receipt.generation,e.result.member == receipt.member,e.result.hash == receipt.hash,
            l.chunks[e.chunk].attempt?.state == .pending else { throw Failure.stale }; return e
    }
    public func resultWrite(_ receipt: Receipt, bytes: Data, authorized: () -> Bool) throws -> Receipt {
        guard receipt.phase == .resultReserve else { throw Failure.stale }
        return try transaction(.resultWrite,token:receipt,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            let e = try self.candidate(receipt,l,stage:0), r = e.result
            guard bytes.count == r.bytes else { throw Failure.stale }
            let fd = try self.lease.writeOpen(e.name,member:r.member,cap:Int64(r.bytes),b), auth = {try self.authority(l,usable:true,authorized:authorized)}
            let inputHash = try self.lease.write(bytes,token:fd,name:e.name,registered:r.member,metadata:false,authorized:auth,b)
            guard inputHash == r.hash else { throw Failure.schema }
            let member = try self.lease.syncClose(fd,name:e.name,registered:r.member,cap:Int64(r.bytes),authorized:auth,b)
            guard member.bytes == Int64(r.bytes) else { throw Failure.schema }
            _ = try self.lease.read(e.name,expected:member,cap:Int64(r.bytes),hash:r.hash,collect:false,authorized:auth,b)
            l.extra?.result.member = member; l.extra?.stage = 2; return (r.id,r.generation,member,r.hash)
        }
    }
    public func resultPromote(_ receipt: Receipt, authorized: () -> Bool) throws -> Receipt {
        guard receipt.phase == .resultWrite else { throw Failure.stale }
        return try transaction(.resultPromote,token:receipt,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,_ in
            let e = try self.candidate(receipt,l,stage:2); var r = e.result
            let accepted = l.chunks.reduce(0) { $0 + ($1.accepted?.bytes ?? 0) }, old = l.chunks[e.chunk].accepted
            guard try MeetingSession.add(accepted-(old?.bytes ?? 0),r.bytes) <= MeetingSession.resultAggregate else { throw Failure.bounds }
            let auth = {try self.authority(l,usable:true,authorized:authorized)}
            _ = try self.lease.read(e.name,expected:r.member,cap:Int64(r.bytes),hash:r.hash,collect:false,authorized:auth,b)
            r.member = try self.lease.rename(e.name,member:r.member,to:MeetingSession.uuid(r.id)+".raw.txt",replacing:nil,authorized:auth,b)
            l.chunks[e.chunk].accepted = r; l.chunks[e.chunk].attempt?.state = .completed
            if l.retention != nil,l.chunks.contains(where: { $0.accepted != nil }),
               l.chunks.allSatisfy({ $0.accepted != nil || $0.stage == .tooShort }) {
                let completed = try self.now(l,usable:true); l.retention?.completed = completed
            }
            l.extra = old.map { .init(kind:.retired,chunk:e.chunk,result:$0,stage:3,authority:e.authority) }
            return (r.id,r.generation,r.member,r.hash)
        }
    }
    public func resultRetire(authorized: () -> Bool) throws -> Receipt {
        try transaction(.resultRetire,token:nil,usable:false,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,names in
            guard let e = l.extra,e.kind == .retired else { throw Failure.stale }; let r = e.result
            if names.contains(e.name) { _ = try self.lease.read(e.name,expected:r.member,cap:Int64(r.bytes),hash:r.hash,collect:false,authorized:{try self.authority(l,usable:false,authorized:authorized)},b) }
            try self.lease.unlink(e.name,member:r.member,cap:Int64(r.bytes),exact:true,missingAllowed:true,b); try self.lease.syncDirectory(b)
            l.extra = nil; return (r.id,r.generation,r.member,r.hash)
        }
    }
    public func borrow(_ token: AttemptToken, authorized: () -> Bool) throws -> (BorrowToken,Data,Receipt) {
        try lock.withLock {
            guard !issue,!interruptionPending,!lease.hasBorrow,!expired,let cached = ledger,cached.state != .deleting,cached.state != .authorityDead else { throw Failure.unavailable }
            _ = try attemptIndex(token,cached)
            let b = try lease.begin()
            do {
                let (l,_,_) = try fresh(b)
                try authority(l,usable:true,authorized:authorized)
                let i = try attemptIndex(token,l), c = l.chunks[i]
                guard !c.audioRemoved,l.retention?.removing != c.id else { throw Failure.unavailable }
                let data = try lease.read(c.name,expected:c.member,cap:Int64(c.bytes),hash:c.hash,collect:true,authorized:{try self.authority(l,usable:true,authorized:authorized)},b).1
                let held = try lease.borrow(c.name,member:c.member,generation:c.generation,b)
                try audit(lease.names(b),l); let cost = try lease.finish(b)
                let receipt = self.receipt(l,phase:.borrowAcquire,object:c.id,generation:c.generation,member:c.member,hash:c.hash,cost:cost)
                return (.init(context:held.context,epoch:held.epoch,serial:held.serial,session:l.session,chunk:c.id,generation:c.generation,attempt:token.attempt),data,receipt)
            } catch { lease.fail(b,undeliveredBorrow:true); issue = true; recordFailure(.borrowAcquire,b); throw error }
        }
    }
    /// Explicit selected result access. A projection/name alone supplies no read authority.
    public func readAccepted(session: UUID, chunk: UUID, result: UUID, authorized: () -> Bool) throws -> Data {
        try lock.withLock {
            guard !issue,!interruptionPending,!expired,let cached = ledger,cached.state != .deleting,cached.state != .authorityDead else { throw Failure.unavailable }; let b = try lease.begin()
            do {
                let (l,_,_) = try fresh(b)
                try authority(l,usable:true,authorized:authorized)
                guard l.session == session,l.state != .deleting,l.state != .authorityDead,let c = l.chunks.first(where:{$0.id == chunk}),let r = c.accepted,r.id == result else { throw Failure.stale }
                let data = try lease.read(MeetingSession.uuid(r.id)+".raw.txt",expected:r.member,cap:Int64(r.bytes),hash:r.hash,collect:true,authorized:{try self.authority(l,usable:true,authorized:authorized)},b).1
                guard let text = String(data:data,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw Failure.schema }
                try audit(lease.names(b),l); let cost = try lease.finish(b); _ = receipt(l,phase:.resultRead,object:r.id,generation:r.generation,member:r.member,hash:r.hash,cost:cost); return data
            } catch { lease.fail(b); issue = true; recordFailure(.resultRead,b); throw error }
        }
    }
    @discardableResult public func actualBorrowExit(_ token: BorrowToken) throws -> Receipt {
        try lock.withLock {
            guard let l = ledger,token.session == l.session,l.chunks.contains(where:{$0.id == token.chunk && $0.generation == token.generation}) else { throw Failure.stale }
            guard let chunk = l.chunks.first(where:{$0.id == token.chunk}),lease.matchesBorrow(.init(context:token.context,epoch:token.epoch,serial:token.serial),member:chunk.member) else { throw Failure.stale }
            let b = try lease.begin(retirementOnly:true)
            do { try lease.release(.init(context:token.context,epoch:token.epoch,serial:token.serial),b); return receipt(l,phase:.borrowRelease,object:chunk.id,generation:chunk.generation,member:chunk.member,hash:chunk.hash,cost:lease.snapshot(b)) }
            catch { lease.fail(b); issue = true; recordFailure(.borrowRelease,b); throw error }
        }
    }
    private func rawDeadline(_ l: Ledger) throws -> Int64? {
        guard let policy = l.retention,!policy.keep,l.chunks.contains(where: { !$0.audioRemoved }) else { return nil }
        return try MeetingSession.add(policy.completed ?? l.admitted,policy.completed == nil ? MeetingSession.RecordingPolicy.failedAudioRetention : MeetingSession.RecordingPolicy.successfulAudioRetention)
    }
    @discardableResult public func setKeep(_ keep: Bool,authorized: () -> Bool) throws -> Receipt {
        try transaction(.keep,token:nil,usable:false,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,_,_ in
            guard self.lease.drained,l.state != .active,l.retention != nil,l.retention?.removing == nil else { throw Failure.held }
            let now = try self.now(l,usable:false)
            guard !keep || l.retention?.keep == true || now < l.expires else { throw Failure.unavailable }
            l.retention?.keep = keep; return (nil,nil,nil,nil)
        }
    }
    /// Each source unlink has a durable intent and a separate completion publication.
    /// Restart accepts only the exact missing source named by that intent; results remain intact.
    public func sweepRawAudio(authorized: () -> Bool) throws {
        for _ in 0..<MeetingSession.maximumChunks {
            let target = try lock.withLock { () throws -> UUID? in
                guard let l = ledger,!issue,l.state != .active,l.deletion == nil,lease.drained else { return nil }
                // Whole-meeting deletion resolves any raw intent once the transcript expires.
                let current = try now(l,usable:false)
                guard !expired else { return nil }
                if let removing = l.retention?.removing { return removing }
                guard let deadline = try rawDeadline(l),current >= deadline else { return nil }
                return l.chunks.first(where: { !$0.audioRemoved })?.id
            }
            guard let target else { return }
            _ = try transaction(.rawIntent,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,_,_ in
                guard self.lease.drained,l.state != .active,l.retention?.keep == false,
                      l.retention?.removing == nil || l.retention?.removing == target else { throw Failure.held }
                l.retention?.removing = target; return (target,nil,nil,nil)
            }
            _ = try transaction(.rawDelete,token:nil,usable:true,tier:MeetingSession.ordinaryBytes,authorized:authorized) { l,b,names in
                guard self.lease.drained,l.retention?.removing == target,
                      let i = l.chunks.firstIndex(where: { $0.id == target && !$0.audioRemoved }) else { throw Failure.stale }
                let c = l.chunks[i]
                // chunkC may have renamed a written source before publishing its ledger.
                for name in c.aliases where names.contains(name) {
                    try self.lease.unlink(name,member:c.member,cap:Int64(c.bytes),exact:c.stage == .sealed || c.stage == .tooShort,missingAllowed:true,b)
                }
                try self.lease.syncDirectory(b)
                l.chunks[i].audioRemoved = true; l.retention?.removing = nil
                return (target,nil,nil,nil)
            }
        }
    }
    public func deleteIntent(id: UUID, terminalGeneration: UInt64, holdEpoch: UInt64, authorized: () -> Bool) throws -> Receipt {
        lease.fence(allWorkers:true)
        do {
            return try transaction(.deleteIntent,token:nil,usable:false,tier:MeetingSession.deletionBytes,authorized:authorized) { l,b,_ in
                guard l.deletion == nil,l.state != .authorityDead else { throw Failure.stale }
                let freeze = l.revision, data = try self.intentJSON(l,id:id,freeze:freeze).bytes
                guard data.count <= 4096 else { throw Failure.bounds }; let name = MeetingSession.uuid(l.session)+".delete"
                let (fd,registered) = try self.lease.create(name,cap:4096,b), auth = {try self.authority(l,usable:false,authorized:authorized)}
                let inputHash = try self.lease.write(data,token:fd,name:name,registered:registered,metadata:true,authorized:auth,b)
                let m = try self.lease.syncClose(fd,name:name,registered:registered,cap:4096,authorized:auth,b)
                _ = try self.lease.read(name,expected:m,cap:4096,hash:inputHash,collect:false,authorized:auth,b); try self.lease.syncDirectory(b)
                try self.lease.checkpoint("intent-durable",name:name,fixed:17,b)
                l.terminal = .init(reason:.cancel,mask:UInt64((1 << l.tracks.count)-1),generation:terminalGeneration,frames:(0..<2).map { l.tracks.indices.contains($0) ? l.tracks[$0].captured : 0 },epoch:holdEpoch,flags:1,errors:[])
                l.deletion = .init(id:id,freeze:freeze,digest:l.targetDigest,count:l.targets.count,member:m,sources:l.sourceDigest,cursor:0,phase:0); l.state = .deleting
                return (id,freeze,m,inputHash)
            }
        } catch { throw Failure.nondurableIntent }
    }
    /// Explicit metadata-only resumption. This reads the durable intent; a name or cached projection never reconstructs authority.
    /// It is the read-only prefix of the existing intent/authority schedule, with no publication or revision consumption.
    public func resumeDeletion(authorized: () -> Bool) throws -> Receipt {
        try lock.withLock {
            guard !issue else { throw Failure.unavailable }; lease.fence(allWorkers:true); let b = try lease.begin()
            do {
                let (l,_,_) = try fresh(b)
                try authority(l,usable:false,authorized:authorized)
                guard let d = l.deletion,l.state == .deleting || l.state == .authorityDead else { throw Failure.stale }
                try audit(lease.names(b),l); let cost = try lease.finish(b)
                return receipt(l,phase:l.state == .authorityDead ? .deleteAuthority : .deleteIntent,object:d.id,generation:d.freeze,member:d.member,hash:d.digest,cost:cost)
            } catch { lease.fail(b); issue = true; recordFailure(.deleteIntent,b); throw error }
        }
    }
    public func deleteSlice(_ receipt: Receipt, authorized: () -> Bool) throws -> Receipt {
        try transaction(.deleteSlice,token:receipt,usable:false,tier:MeetingSession.deletionBytes,authorized:authorized) { l,b,names in
            guard self.lease.drained,l.state == .deleting,let d = l.deletion,d.cursor < d.count else { throw Failure.held }
            let all = self.targets(l), end = min(d.count,d.cursor+2)
            for i in d.cursor..<end {
                let t = all[i], present = t.aliases.filter { names.contains($0) }
                guard present.count <= 1 else { throw Failure.unavailable }
                if let name = present.first {
                    if t.exact { _ = try self.lease.read(name,expected:t.member,cap:t.cap,hash:t.hash,collect:false,authorized:{try self.authority(l,usable:false,authorized:authorized)},b) }
                    try self.lease.unlink(name,member:t.member,cap:t.cap,exact:t.exact,missingAllowed:true,b)
                }
            }
            try self.lease.syncDirectory(b); l.deletion?.cursor = end; l.deletion?.phase = end == d.count ? 2 : 1
            return (d.id,d.freeze,d.member,d.digest)
        }
    }
    public func deleteAuthority(_ receipt: Receipt, authorized: () -> Bool) throws -> Receipt {
        try transaction(.deleteAuthority,token:receipt,usable:false,tier:MeetingSession.deletionBytes,authorized:authorized) { l,_,_ in
            guard self.lease.drained,l.state == .deleting,let d = l.deletion,d.cursor == d.count else { throw Failure.held }
            l.state = .authorityDead; l.deletion?.phase = 3; return (d.id,d.freeze,d.member,d.digest)
        }
    }
    public func deleteClose(_ receipt: Receipt, authorized: () -> Bool) throws -> Receipt {
        try lock.withLock {
            guard !issue,lease.drained,let cached = ledger,cached.state == .authorityDead else { throw Failure.held }
            try current(receipt,cached,phase:.deleteAuthority)
            let b = try lease.begin()
            do {
                let (l,m,_) = try fresh(b); try authority(l,usable:false,authorized:authorized); try current(receipt,l,phase:.deleteAuthority)
                guard lease.drained,l.state == .authorityDead,let d = l.deletion,let ownerMember else { throw Failure.held }
                for (name,member) in [(MeetingSession.uuid(l.session)+".delete",d.member),("manifest.json",m),("owner.json",ownerMember)] { try lease.unlink(name,member:member,cap:member.bytes,exact:true,missingAllowed:false,b) }
                try lease.unlinkLock(b); try lease.syncDirectory(b); guard try lease.names(b).isEmpty else { throw Failure.unavailable }
                try lease.finalClose(b); let cost = try lease.finish(b)
                ledger = nil; ledgerMember = nil; self.ownerMember = nil; lastClock = nil; expired = false; interruptionPending = false
                return self.receipt(l,phase:.deleteClose,object:d.id,generation:d.freeze,member:nil,hash:d.digest,cost:cost)
            } catch { lease.fail(b,final:true); issue = true; recordFailure(.deleteClose,b); throw error }
        }
    }
    @discardableResult public func detach() throws -> Receipt? {
        try lock.withLock {
            guard !lease.poisoned,lease.drained else { throw Failure.held }
            lease.fence(allWorkers:true)
            let b = try lease.begin(retirementOnly:true)
            do { try lease.detach(b); return ledger.map { receipt($0,phase:.detach,object:nil,generation:nil,member:nil,hash:nil,cost:lease.snapshot(b)) } } catch { lease.fail(b,final:true); issue = true; recordFailure(.detach,b); throw error }
        }
    }
    private func worker(_ kind: Worker) -> Lease.Worker {
        switch kind { case .microphone:return .microphone; case .system:return .system; case .microphoneCallback:return .microphoneCallback; case .systemCallback:return .systemCallback; case .writer:return .writer; case .output:return .output }
    }
    public func register(_ kind: Worker) throws -> Hold { let token = try lease.register(worker(kind)); return .init(context:token.context,epoch:token.epoch,serial:token.serial,kind:kind) }
    public func actualExit(_ token: Hold) throws { try lease.actualExit(.init(context:token.context,epoch:token.epoch,serial:token.serial,kind:worker(token.kind))) }
    public func fence() { lease.fence() }
    public func reserveQuit() { lease.reserveQuit() }
    public func cancelQuit() { lease.cancelQuit() }
    public var shutdownReady: Bool { lock.withLock { !issue && ledger?.state != .active && ledger?.state != .deleting && ledger?.state != .authorityDead && lease.ready } }
    public var actualHoldsDrained: Bool { lock.withLock { lease.drained } }
}
