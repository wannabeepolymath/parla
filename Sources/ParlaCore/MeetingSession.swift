import CryptoKit
import Foundation

/// Inert, closed meeting metadata. A decoded row is prior acknowledgment, never file authority.
public enum MeetingSession {
    public enum Failure: Error, Equatable { case schema, bounds, detailExhausted, clock, stale, unavailable, held, nondurableIntent }
    public static let maximumChunks = 240, maximumFrames: UInt64 = 480_000
    public static let maximumTrackFrames: UInt64 = 57_600_000
    public static let sourceBytes = 960_044, resultBytes = 65_536, resultAggregate = 1_048_576
    public static let ordinaryBytes = 458_752, terminalBytes = 491_520, deletionBytes = 524_288
    public static let reservation: Int64 = 232_581_440, quota: Int64 = 268_435_456
    public static let lifetime: Int64 = 604_800_000_000_000
    // Bounded pure timing pass: normalize <=480 events (32), sort (32), frontiers (64).
    // Storage precharges each invocation inside the unchanged 2048 fixed-credit cap.
    static let timingValidationCredits = 128
    public enum SourceKind: UInt64, Hashable, Sendable { case microphone, selectedApplication, disclosedSystem }
    public enum Mapping: UInt64, Sendable { case unknown, validated }
    public enum State: UInt64, Sendable { case active, stopped, interrupted, deleting, authorityDead }
    public enum Stage: UInt64, Sendable { case registered, interrupted, written, sealed, tooShort, unavailable }
    public enum Reason: UInt64, Sendable {
        case normalStop, expiry, interrupted, cancel, invalidTail, slotExhaustion, frameCeiling, detailExhaustion
        case invalidClock, duplicate, reordered, missing, overlap, crossEpoch, overflow, invalidRate
        case invalidPTS, ioRefusal, budgetRefusal, headroom, namespace, ownership, identity, hash
        case sync, close, unsupported, provenanceFull, resultCap, firstIntentFailure, lifecycleHeld, unknownCoverage
    }
    public struct Selection: Equatable, Sendable {
        public let instance: UUID, kind: SourceKind, label: String, generation: UInt64
        public init(instance: UUID, kind: SourceKind, label: String, generation: UInt64) {
            self.instance = instance; self.kind = kind; self.label = label; self.generation = generation
        }
    }
    public struct Timing: Equatable, Sendable {
        public let pts: Int64, denominator: UInt64, sample: UInt64, rate: UInt64, epoch: UUID, mapping: Mapping
        public init(pts: Int64, denominator: UInt64, sample: UInt64, rate: UInt64, epoch: UUID, mapping: Mapping) {
            self.pts = pts; self.denominator = denominator; self.sample = sample; self.rate = rate; self.epoch = epoch; self.mapping = mapping
        }
        func validate() throws {
            try require((1...1_000_000).contains(denominator) && (1...192_000).contains(rate))
        }
        /// Exact rational comparison. Reduction precedes checked cross products; no rounding or arrival-time substitution.
        func end(after frames: UInt64) throws -> (Int64, UInt64) {
            try validate(); let divisor = gcd(denominator, 16_000)
            let left = try multiply(pts, Int64(16_000 / divisor))
            guard let frameCount = Int64(exactly:frames) else { throw Failure.bounds }
            let right = try multiply(frameCount, Int64(denominator / divisor))
            return (try add(left, right), try multiply(denominator, 16_000 / divisor))
        }
    }
    public struct Segment: Equatable, Sendable {
        public let id: UUID, track: Int, generation: UInt64, timing: Timing, canonicalStart: UInt64
        public init(id: UUID, track: Int, generation: UInt64, timing: Timing, canonicalStart: UInt64) {
            self.id = id; self.track = track; self.generation = generation; self.timing = timing; self.canonicalStart = canonicalStart
        }
    }
    public struct Gap: Equatable, Sendable {
        public enum Kind: UInt64, Sendable { case measured, unknown }
        public let id: UUID, track: Int, segment: Int, sequence: UInt64, kind: Kind
        public let start: Int64, startDenominator: UInt64, extent: Int64, extentDenominator: UInt64
        public init(id: UUID, track: Int, segment: Int, sequence: UInt64, kind: Kind,
                    start: Int64, startDenominator: UInt64, extent: Int64, extentDenominator: UInt64) {
            self.id = id; self.track = track; self.segment = segment; self.sequence = sequence; self.kind = kind
            self.start = start; self.startDenominator = startDenominator; self.extent = extent; self.extentDenominator = extentDenominator
        }
    }
    public struct Projection: Equatable, Sendable {
        public let session: UUID?, state: State?, acknowledgedChunks: Int, acceptedResults: Int, expired: Bool, unavailable: Bool
        public func refusingUse() -> Self { .init(session:session,state:state,acknowledgedChunks:acknowledgedChunks,acceptedResults:acceptedResults,expired:expired,unavailable:true) }
        public static let idle = Projection(session: nil, state: nil, acknowledgedChunks: 0, acceptedResults: 0, expired: false, unavailable: false)
    }
    /// Conversion is explicit; no Date or wall-clock query occurs inside the model.
    public static func nanoseconds(seconds: Double) throws -> Int64 {
        let value = seconds * 1_000_000_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw Failure.clock }
        return Int64(value.rounded(.towardZero))
    }
    static func require(_ condition: Bool) throws { if !condition { throw Failure.schema } }
    static func add<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let value = a.addingReportingOverflow(b); guard !value.overflow else { throw Failure.bounds }; return value.partialValue
    }
    static func multiply<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let value = a.multipliedReportingOverflow(by: b); guard !value.overflow else { throw Failure.bounds }; return value.partialValue
    }
    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 { var x = a, y = b; while y != 0 { (x,y) = (y,x % y) }; return x }
    static func ordered(_ a: (Int64,UInt64), _ b: (Int64,UInt64)) throws -> Bool {
        try require(a.1 > 0 && b.1 > 0)
        let divisor = gcd(a.1,b.1)
        guard let left = Int64(exactly:b.1/divisor),let right = Int64(exactly:a.1/divisor) else { throw Failure.bounds }
        return try multiply(a.0,left) <= multiply(b.0,right)
    }
    static func text(_ value: String, cap: Int) throws {
        try require(value.utf8.count <= cap && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }
    static func hash(_ value: String, empty: Bool = false) throws {
        try require((empty && value.isEmpty) || (value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }))
    }
    enum AllocationRole: UInt8 { case attempt = 1, result = 2, retirement = 3 }
    static func allocationPrefix(_ session: UUID) -> String { String(SavedAudioImportStorage.digest(Data(uuid(session).utf8)).prefix(14)) }
    static func allocation(_ session: UUID, role: AllocationRole, generation: UInt64) -> UUID {
        let raw = allocationPrefix(session) + String(format:"%02x",role.rawValue) + String(format:"%016llx",generation)
        let a = Array(raw); let value = String(a[0..<8])+"-"+String(a[8..<12])+"-"+String(a[12..<16])+"-"+String(a[16..<20])+"-"+String(a[20..<32])
        // The string is constructed from exactly 32 lowercase hex digits.
        return UUID(uuidString:value)!
    }
    static func allocatedGeneration(_ id: UUID, session: UUID, role: AllocationRole) -> UInt64? {
        let raw = uuid(id).replacingOccurrences(of:"-",with:"")
        guard raw.hasPrefix(allocationPrefix(session)+String(format:"%02x",role.rawValue)) else { return nil }; return UInt64(raw.suffix(16),radix:16)
    }
    static func reserved(_ id: UUID, session: UUID) -> Bool { [AllocationRole.attempt,.result,.retirement].contains { allocatedGeneration(id,session:session,role:$0) != nil } }
    static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
}

// Closed positional records intentionally do not use JSONDecoder, which accepts duplicate keys.
indirect enum MeetingJSON: Equatable {
    case string(String), integer(String), boolean(Bool), array([MeetingJSON]), object([(String, MeetingJSON)])
    static func == (a: Self, b: Self) -> Bool {
        switch (a,b) {
        case (.string(let a),.string(let b)),(.integer(let a),.integer(let b)): return a == b
        case (.boolean(let a),.boolean(let b)): return a == b
        case (.array(let a),.array(let b)): return a == b
        case (.object(let a),.object(let b)):
            let x = a.sorted { $0.0 < $1.0 }, y = b.sorted { $0.0 < $1.0 }
            return x.count == y.count && zip(x,y).allSatisfy { $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 }
        default: return false
        }
    }
    static func n<T: BinaryInteger>(_ x: T) -> Self { .integer(String(x)) }
    static func u(_ x: UUID) -> Self { .string(MeetingSession.uuid(x)) }
    func emit(_ byte: (UInt8) throws -> Void) rethrows {
        switch self {
        case .string(let s): try byte(34); for c in s.utf8 { if c == 34 || c == 92 { try byte(92) }; try byte(c) }; try byte(34)
        case .integer(let s): for c in s.utf8 { try byte(c) }
        case .boolean(let b): for c in (b ? "true" : "false").utf8 { try byte(c) }
        case .array(let a):
            try byte(91); for (i,v) in a.enumerated() { if i > 0 { try byte(44) }; try v.emit(byte) }; try byte(93)
        case .object(let a):
            try byte(123); for (i,v) in a.sorted(by:{$0.0 < $1.0}).enumerated() { if i > 0 { try byte(44) }; try Self.string(v.0).emit(byte); try byte(58); try v.1.emit(byte) }; try byte(125)
        }
    }
    var bytes: Data { var out = Data(); emit { out.append($0) }; return out }
    func encoded(cap: Int) throws -> Data {
        var out = Data(); try emit { c in guard out.count < cap else { throw MeetingSession.Failure.bounds }; out.append(c) }; return out
    }
    var digest: String {
        var hash = SHA256(), buffer = Data()
        emit { c in buffer.append(c); if buffer.count == 65_536 { hash.update(data:buffer); buffer.removeAll(keepingCapacity:true) } }
        hash.update(data:buffer); return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func matches(_ bytes: Data) -> Bool {
        var i = 0, equal = true
        emit { c in if i >= bytes.count || bytes[i] != c { equal = false }; i += 1 }; return equal && i == bytes.count
    }
    func list(_ count: Int? = nil, maximum: Int = 240) throws -> [Self] {
        guard case .array(let a) = self, a.count <= maximum, count == nil || count == a.count else { throw MeetingSession.Failure.schema }; return a
    }
    func fields(_ keys: [String]) throws -> [String: Self] {
        guard case .object(let values) = self, values.map(\.0).sorted() == keys.sorted() else { throw MeetingSession.Failure.schema }
        return Dictionary(uniqueKeysWithValues: values)
    }
    func s(_ cap: Int) throws -> String {
        guard case .string(let s) = self else { throw MeetingSession.Failure.schema }; try MeetingSession.text(s, cap: cap); return s
    }
    func id() throws -> UUID {
        let s = try s(36); guard let u = UUID(uuidString: s), MeetingSession.uuid(u) == s else { throw MeetingSession.Failure.schema }; return u
    }
    func uint(_ cap: UInt64 = .max) throws -> UInt64 {
        guard case .integer(let s) = self, let v = UInt64(s), v <= cap else { throw MeetingSession.Failure.schema }; return v
    }
    func int() throws -> Int64 {
        guard case .integer(let s) = self, let v = Int64(s) else { throw MeetingSession.Failure.schema }; return v
    }
    func index(_ cap: Int) throws -> Int { Int(try uint(UInt64(cap))) }
    func flag() throws -> Bool { guard case .boolean(let b) = self else { throw MeetingSession.Failure.schema }; return b }
    static func parse(_ data: Data, cap: Int) throws -> Self {
        guard data.count <= cap else { throw MeetingSession.Failure.bounds }
        guard data.startIndex == 0 else { throw MeetingSession.Failure.schema }
        var parser = Parser(data: data); let value = try parser.value(depth: 0)
        guard parser.index == data.count, value.matches(data) else { throw MeetingSession.Failure.schema }; return value
    }
    private struct Parser {
        let data: Data; var index = 0, tokens = 0
        mutating func take(_ c: UInt8) throws { guard index < data.count, data[index] == c else { throw MeetingSession.Failure.schema }; index += 1 }
        mutating func value(depth: Int) throws -> MeetingJSON {
            tokens += 1; guard tokens <= 65_536, depth < 8, index < data.count else { throw MeetingSession.Failure.bounds }
            switch data[index] {
            case 34: return .string(try string())
            case 91:
                index += 1; var a: [MeetingJSON] = []
                if index < data.count, data[index] == 93 { index += 1; return .array(a) }
                while true {
                    guard a.count < 240 else { throw MeetingSession.Failure.bounds }
                    a.append(try value(depth: depth + 1)); guard index < data.count else { throw MeetingSession.Failure.schema }
                    if data[index] == 93 { index += 1; return .array(a) }; try take(44)
                }
            case 123:
                index += 1; var a: [(String,MeetingJSON)] = []; var seen = Set<String>()
                while true {
                    guard a.count < 18 else { throw MeetingSession.Failure.bounds }
                    let key = try string(); guard seen.insert(key).inserted else { throw MeetingSession.Failure.schema }
                    try take(58); a.append((key,try value(depth: depth + 1)))
                    guard index < data.count else { throw MeetingSession.Failure.schema }
                    if data[index] == 125 { index += 1; return .object(a) }; try take(44)
                }
            case 116,102:
                let b = data[index] == 116; for c in (b ? "true" : "false").utf8 { try take(c) }; return .boolean(b)
            default:
                let start = index; if data[index] == 45 { index += 1 }
                guard index < data.count, (48...57).contains(data[index]) else { throw MeetingSession.Failure.schema }
                if data[index] == 48 { index += 1 } else { while index < data.count, (48...57).contains(data[index]) { index += 1 } }
                guard index - start <= 20, let s = String(bytes: data[start..<index], encoding: .utf8), s != "-0" else { throw MeetingSession.Failure.schema }
                return .integer(s)
            }
        }
        mutating func string() throws -> String {
            try take(34); var b: [UInt8] = []
            while index < data.count {
                let c = data[index]; index += 1
                if c == 34 { guard let s = String(bytes: b, encoding: .utf8) else { throw MeetingSession.Failure.schema }; try MeetingSession.text(s, cap: 256); return s }
                if c == 92 { guard index < data.count, data[index] == 34 || data[index] == 92 else { throw MeetingSession.Failure.schema }; b.append(data[index]); index += 1 }
                else { guard c >= 32 else { throw MeetingSession.Failure.schema }; b.append(c) }
                guard b.count <= 256 else { throw MeetingSession.Failure.bounds }
            }
            throw MeetingSession.Failure.schema
        }
    }
}

extension SavedAudioImportStorage.Member {
    init(meeting value: MeetingJSON, cap: Int64) throws {
        let a = try value.list(10)
        let device = try a[0].int(); guard let device = Int32(exactly: device) else { throw MeetingSession.Failure.schema }
        identity = .init(device: device, inode: try a[1].uint()); bytes = try a[2].int()
        birthSeconds = try a[3].int(); birthNanoseconds = try a[4].int()
        modifiedSeconds = try a[5].int(); modifiedNanoseconds = try a[6].int()
        changedSeconds = try a[7].int(); changedNanoseconds = try a[8].int(); flags = UInt32(try a[9].uint(UInt64(UInt32.max)))
        try MeetingSession.require(bytes >= 0 && bytes <= cap && flags & 0x4000_0000 == 0)
        for n in [birthNanoseconds, modifiedNanoseconds, changedNanoseconds] { try MeetingSession.require((0...999_999_999).contains(n)) }
    }
    var meetingJSON: MeetingJSON { .array([.n(identity.device),.n(identity.inode),.n(bytes),.n(birthSeconds),.n(birthNanoseconds),.n(modifiedSeconds),.n(modifiedNanoseconds),.n(changedSeconds),.n(changedNanoseconds),.n(flags)]) }
    func sameBirth(_ other: Self) -> Bool { identity == other.identity && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds }
    func renamedFrom(_ old: Self) -> Bool {
        sameBirth(old) && bytes == old.bytes && modifiedSeconds == old.modifiedSeconds && modifiedNanoseconds == old.modifiedNanoseconds && flags == old.flags
    }
}

extension MeetingSession {
    typealias J = MeetingJSON
    public typealias Member = SavedAudioImportStorage.Member
    struct Track: Equatable {
        let selection: Selection; var epoch: UUID, captured: UInt64, sequence: UInt64, segment: Int
        var json: J { .array([.u(selection.instance),.n(selection.kind.rawValue),.string(selection.label),.n(selection.generation),.u(epoch),.n(captured),.n(sequence),.n(segment)]) }
        init(selection: Selection, epoch: UUID, captured: UInt64, sequence: UInt64, segment: Int) {
            self.selection = selection; self.epoch = epoch; self.captured = captured; self.sequence = sequence; self.segment = segment
        }
        init(_ value: J) throws {
            let a = try value.list(8)
            guard let kind = SourceKind(rawValue: try a[1].uint(2)) else { throw Failure.schema }
            selection = .init(instance: try a[0].id(), kind: kind, label: try a[2].s(128), generation: try a[3].uint())
            epoch = try a[4].id(); captured = try a[5].uint(maximumTrackFrames); sequence = try a[6].uint(); segment = try a[7].index(239)
        }
    }
    public struct Provenance: Equatable, Sendable {
        public enum Role: UInt64, Sendable { case requested, observed }
        public enum Engine: UInt64, Sendable { case unknown, whisper, appleSpeech, parakeet }
        public enum Artifact: UInt64, Sendable { case unknown, catalog, customUnknown, systemUnknown, parakeet }
        public let id: UUID, generation: UInt64, role: Role, engine: Engine, artifact: Artifact
        public let catalogID: String, language: String, model: String, filter: String, nativeVersion: String
        public let buildScope: String, systemScope: String, verification: String, computeScope: String
        public let digest: String, helperDigest: String, releaseDigest: String, sdkRevision: String, modelRevision: String
        public let expectedBytes: UInt64, fileGeneration: Member?, adapter: UInt64, compute: UInt64, hints: Bool
        public init(id: UUID, generation: UInt64, role: Role, engine: Engine, artifact: Artifact,
                    catalogID: String, language: String, model: String, filter: String, nativeVersion: String,
                    buildScope: String, systemScope: String, verification: String, computeScope: String,
                    digest: String, helperDigest: String, releaseDigest: String, sdkRevision: String, modelRevision: String,
                    expectedBytes: UInt64, fileGeneration: Member?, adapter: UInt64, compute: UInt64, hints: Bool) throws {
            self.id = id; self.generation = generation; self.role = role; self.engine = engine; self.artifact = artifact
            self.catalogID = catalogID; self.language = language; self.model = model; self.filter = filter; self.nativeVersion = nativeVersion
            self.buildScope = buildScope; self.systemScope = systemScope; self.verification = verification; self.computeScope = computeScope
            self.digest = digest; self.helperDigest = helperDigest; self.releaseDigest = releaseDigest; self.sdkRevision = sdkRevision; self.modelRevision = modelRevision
            self.expectedBytes = expectedBytes; self.fileGeneration = fileGeneration; self.adapter = adapter; self.compute = compute; self.hints = hints
            try validate()
        }
        func validate() throws {
            for (s,cap) in zip([catalogID,language,model,filter,nativeVersion,buildScope,systemScope,verification,computeScope],[128,64,128,32,96,128,128,96,128]) { try text(s,cap:cap) }
            let unknown = artifact == .unknown || artifact == .customUnknown || artifact == .systemUnknown
            for s in [digest,helperDigest,releaseDigest] { try hash(s,empty:unknown) }
            for s in [sdkRevision,modelRevision] {
                try require((unknown && s.isEmpty) || ((s.utf8.count == 40 || s.utf8.count == 64) && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }))
            }
            try require(adapter <= 1_000_000 && compute <= 1_000_000)
            if let m = fileGeneration { _ = try Member(meeting: m.meetingJSON, cap: .max) }
        }
        var json: J { .array([.u(id),.n(generation),.n(role.rawValue),.n(engine.rawValue),.n(artifact.rawValue),.string(catalogID),.string(language),.string(model),.string(filter),.string(nativeVersion),.string(buildScope),.string(systemScope),.string(verification),.string(computeScope),.string(digest),.string(helperDigest),.string(releaseDigest),.string(sdkRevision),.string(modelRevision),.n(expectedBytes),fileGeneration?.meetingJSON ?? .array([]),.n(adapter),.n(compute),.boolean(hints)]) }
        init(_ value: J) throws {
            let a = try value.list(24)
            guard let role = Role(rawValue: try a[2].uint(1)), let engine = Engine(rawValue: try a[3].uint(3)), let artifact = Artifact(rawValue: try a[4].uint(4)) else { throw Failure.schema }
            try self.init(id: a[0].id(), generation: a[1].uint(), role: role, engine: engine, artifact: artifact,
                catalogID: a[5].s(128), language: a[6].s(64), model: a[7].s(128), filter: a[8].s(32), nativeVersion: a[9].s(96),
                buildScope: a[10].s(128), systemScope: a[11].s(128), verification: a[12].s(96), computeScope: a[13].s(128),
                digest: a[14].s(64), helperDigest: a[15].s(64), releaseDigest: a[16].s(64), sdkRevision: a[17].s(64), modelRevision: a[18].s(64),
                expectedBytes: a[19].uint(), fileGeneration: a[20].list(maximum:10).isEmpty ? nil : Member(meeting:a[20],cap:.max),
                adapter: a[21].uint(1_000_000), compute: a[22].uint(1_000_000), hints: a[23].flag())
        }
    }
    struct Attempt: Equatable {
        enum State: UInt64 { case pending, canceled, completed, failed }
        let id: UUID, generation: UInt64, requested: Int; var state: State
        var json: J { .array([.u(id),.n(generation),.n(requested),.n(state.rawValue)]) }
        init(id: UUID, generation: UInt64, requested: Int, state: State) { self.id = id; self.generation = generation; self.requested = requested; self.state = state }
        init(_ j: J) throws { let a = try j.list(4); id = try a[0].id(); generation = try a[1].uint(); requested = try a[2].index(31); guard let s = State(rawValue:try a[3].uint(3)) else { throw Failure.schema }; state = s }
    }
    struct Result: Equatable {
        let id: UUID, generation: UInt64, attempt: UUID, source: UUID, sourceGeneration: UInt64, sourceHash: String, bytes: Int, hash: String
        var member: Member; let requested: Int, observed: Int, created: Int64
        var json: J { .array([.u(id),.n(generation),.u(attempt),.u(source),.n(sourceGeneration),.string(sourceHash),.n(bytes),.string(hash),member.meetingJSON,.n(requested),.n(observed),.n(created)]) }
        init(id: UUID, generation: UInt64, attempt: UUID, source: UUID, sourceGeneration: UInt64, sourceHash: String, bytes: Int, hash: String, member: Member, requested: Int, observed: Int, created: Int64) {
            self.id = id; self.generation = generation; self.attempt = attempt; self.source = source; self.sourceGeneration = sourceGeneration; self.sourceHash = sourceHash
            self.bytes = bytes; self.hash = hash; self.member = member; self.requested = requested; self.observed = observed; self.created = created
        }
        init(_ j: J) throws {
            let a = try j.list(12); id = try a[0].id(); generation = try a[1].uint(); attempt = try a[2].id(); source = try a[3].id(); sourceGeneration = try a[4].uint(); sourceHash = try a[5].s(64)
            bytes = try a[6].index(resultBytes); hash = try a[7].s(64); member = try .init(meeting:a[8],cap:Int64(resultBytes)); requested = try a[9].index(31); observed = try a[10].index(31); created = try a[11].int()
        }
    }
    struct Chunk: Equatable {
        let id: UUID, generation: UInt64, track: Int, sourceGeneration: UInt64, segment: Int, sequence: UInt64, start: UInt64, frames: UInt64, bytes: Int, hash: String, timing: Timing
        var member: Member, stage: Stage, accepted: Result?, attempt: Attempt?
        var json: J { .array([.u(id),.n(generation),.n(track),.n(sourceGeneration),.n(segment),.n(sequence),.n(start),.n(frames),.n(bytes),.string(hash),member.meetingJSON,.n(stage.rawValue),timing.json,accepted?.json ?? .array([]),attempt?.json ?? .array([])]) }
        init(id: UUID, generation: UInt64, track: Int, sourceGeneration: UInt64, segment: Int, sequence: UInt64, start: UInt64, frames: UInt64, bytes: Int, hash: String, timing: Timing, member: Member, stage: Stage, accepted: Result?, attempt: Attempt?) {
            self.id = id; self.generation = generation; self.track = track; self.sourceGeneration = sourceGeneration; self.segment = segment; self.sequence = sequence; self.start = start; self.frames = frames; self.bytes = bytes; self.hash = hash; self.timing = timing; self.member = member; self.stage = stage; self.accepted = accepted; self.attempt = attempt
        }
        init(_ j: J) throws {
            let a = try j.list(15); id = try a[0].id(); generation = try a[1].uint(); track = try a[2].index(1); sourceGeneration = try a[3].uint(); segment = try a[4].index(239); sequence = try a[5].uint(); start = try a[6].uint(maximumTrackFrames); frames = try a[7].uint(maximumFrames); bytes = try a[8].index(sourceBytes); hash = try a[9].s(64); member = try .init(meeting:a[10],cap:Int64(sourceBytes))
            guard let s = Stage(rawValue:try a[11].uint(5)) else { throw Failure.schema }; stage = s; timing = try .init(a[12])
            accepted = try a[13].list(maximum:12).isEmpty ? nil : Result(a[13]); attempt = try a[14].list(maximum:4).isEmpty ? nil : Attempt(a[14])
        }
        var pending: String { uuid(id) + ".source.pending" }; var final: String { uuid(id) + ".source.wav" }
        var name: String { stage == .sealed || stage == .tooShort ? final : pending }
    }
    struct Extra: Equatable {
        enum Kind: UInt64 { case candidate, retired }
        let kind: Kind, chunk: Int; var result: Result; var stage: UInt64; let authority: UUID
        var json: J { .array([.n(kind.rawValue),.n(chunk),result.json,.n(stage),.u(authority)]) }
        init(kind: Kind, chunk: Int, result: Result, stage: UInt64, authority: UUID) { self.kind = kind; self.chunk = chunk; self.result = result; self.stage = stage; self.authority = authority }
        init(_ j: J) throws { let a = try j.list(5); guard let k = Kind(rawValue:try a[0].uint(1)) else { throw Failure.schema }; kind = k; chunk = try a[1].index(239); result = try Result(a[2]); stage = try a[3].uint(5); authority = try a[4].id() }
        var name: String { uuid(result.id) + (kind == .candidate && stage < 3 ? ".result.pending" : ".raw.txt") }
    }
    struct Terminal: Equatable {
        let reason: Reason, mask: UInt64, generation: UInt64, frames: [UInt64], epoch: UInt64, flags: UInt64, errors: [Reason]
        var json: J { .array([.n(reason.rawValue),.n(mask),.n(generation),.array(frames.map(J.n)),.n(epoch),.n(flags),.array(errors.map { .n($0.rawValue) })]) }
        init(reason: Reason, mask: UInt64, generation: UInt64, frames: [UInt64], epoch: UInt64, flags: UInt64, errors: [Reason]) { self.reason = reason; self.mask = mask; self.generation = generation; self.frames = frames; self.epoch = epoch; self.flags = flags; self.errors = errors }
        init(_ j: J) throws {
            let a = try j.list(7); guard let r = Reason(rawValue:try a[0].uint(31)) else { throw Failure.schema }; reason = r; mask = try a[1].uint(3); generation = try a[2].uint(); frames = try a[3].list(2).map { try $0.uint(maximumTrackFrames) }; epoch = try a[4].uint(); flags = try a[5].uint(65_535)
            errors = try a[6].list(maximum:16).map { guard let r = Reason(rawValue:try $0.uint(31)) else { throw Failure.schema }; return r }
        }
    }
    struct Deletion: Equatable {
        let id: UUID, freeze: UInt64, digest: String, count: Int, member: Member, sources: String
        var cursor: Int, phase: UInt64
        var bitmap: String { (0..<61).map { i in String(format:"%02x", (0..<8).reduce(0) { $0 | (i * 8 + $1 < cursor ? 1 << $1 : 0) }) }.joined() }
        var json: J { .array([.u(id),.n(freeze),.string(digest),.n(count),.n(cursor),.n(2),.n(phase),member.meetingJSON,.string(sources),.string(bitmap)]) }
        init(id: UUID, freeze: UInt64, digest: String, count: Int, member: Member, sources: String, cursor: Int, phase: UInt64) { self.id = id; self.freeze = freeze; self.digest = digest; self.count = count; self.member = member; self.sources = sources; self.cursor = cursor; self.phase = phase }
        init(_ j: J) throws {
            let a = try j.list(10); id = try a[0].id(); freeze = try a[1].uint(); digest = try a[2].s(64); count = try a[3].index(481); cursor = try a[4].index(count); try require(a[5].uint() == 2); phase = try a[6].uint(3); member = try .init(meeting:a[7],cap:4096); sources = try a[8].s(64); try require(a[9].s(122) == bitmap)
        }
    }
    struct Ledger: Equatable {
        let owner: UUID, session: UUID, root: SavedAudioImportStorage.Identity, admitted: Int64, expires: Int64
        var revision: UInt64, clock: Int64, state: State, tracks: [Track], segments: [Segment], gaps: [Gap], provenance: [Provenance], chunks: [Chunk], extra: Extra?, terminal: Terminal?, deletion: Deletion?
        var json: J { .object([("d",.string("parla.meeting.1")),("v",.n(1)),("owner",.u(owner)),("session",.u(session)),("root",.array([.n(root.device),.n(root.inode)])),("revision",.n(revision)),("admitted",.n(admitted)),("expires",.n(expires)),("clock",.n(clock)),("state",.n(state.rawValue)),("tracks",.array(tracks.map(\.json))),("segments",.array(segments.map(\.json))),("gaps",.array(gaps.map(\.json))),("provenance",.array(provenance.map(\.json))),("chunks",.array(chunks.map(\.json))),("extra",extra?.json ?? .array([])),("terminal",terminal?.json ?? .array([])),("deletion",deletion?.json ?? .array([]))]) }
        var sourceDigest: String { J.array(tracks.map { .u($0.selection.instance) }).digest }
        var targets: [J] {
            var rows: [J] = []
            for c in chunks {
                rows.append(.array([.u(c.id),.n(c.generation),.n(sourceBytes),.string(c.hash),c.member.meetingJSON,.n(0),.n(c.stage.rawValue)]))
                if let r = c.accepted { rows.append(.array([.u(r.id),.n(r.generation),.n(resultBytes),.string(r.hash),r.member.meetingJSON,.n(1),.n(3)])) }
            }
            if let e = extra { let r = e.result; rows.append(.array([.u(r.id),.n(r.generation),.n(resultBytes),.string(r.hash),r.member.meetingJSON,.n(1),.n(e.stage)])) }; return rows
        }
        var targetDigest: String { J.array(targets).digest }
        func encoded(tier: Int) throws -> Data {
            try validate(); return try json.encoded(cap:tier)
        }
        static func decode(_ bytes: Data) throws -> Self {
            let f = try J.parse(bytes,cap:deletionBytes).fields(["d","v","owner","session","root","revision","admitted","expires","clock","state","tracks","segments","gaps","provenance","chunks","extra","terminal","deletion"])
            func get(_ key: String) throws -> J { guard let v = f[key] else { throw Failure.schema }; return v }
            try require(get("d").s(32) == "parla.meeting.1" && get("v").uint() == 1)
            let root = try get("root").list(2); guard let device = Int32(exactly:try root[0].int()), let state = State(rawValue:try get("state").uint(4)) else { throw Failure.schema }
            let value = try Self(owner:get("owner").id(),session:get("session").id(),root:.init(device:device,inode:root[1].uint()),admitted:get("admitted").int(),expires:get("expires").int(),revision:get("revision").uint(),clock:get("clock").int(),state:state,
                tracks:get("tracks").list(maximum:2).map(Track.init),segments:get("segments").list().map(Segment.init),gaps:get("gaps").list().map(Gap.init),provenance:get("provenance").list(maximum:32).map(Provenance.init),chunks:get("chunks").list().map(Chunk.init),
                extra:get("extra").list(maximum:5).isEmpty ? nil : Extra(get("extra")),terminal:get("terminal").list(maximum:7).isEmpty ? nil : Terminal(get("terminal")),deletion:get("deletion").list(maximum:10).isEmpty ? nil : Deletion(get("deletion")))
            try value.validate(); let tier = value.state == .deleting || value.state == .authorityDead ? deletionBytes : value.terminal == nil ? ordinaryBytes : terminalBytes
            try require(bytes.count <= tier); return value
        }
        typealias ChunkTiming = (track: Int, sourceGeneration: UInt64, segment: Int, sequence: UInt64, start: UInt64, frames: UInt64, timing: Timing)
        /// Declared source-relative coverage only. Track identity/generation is fixed by the ledger;
        /// segment IDs do not reset an epoch. Unknown records neither add nor erase known extents.
        func validateTiming(adding candidate: ChunkTiming? = nil) throws {
            try require(tracks.count <= 2 && segments.count <= 240 && gaps.count <= 240 && chunks.count <= (candidate == nil ? 240 : 239))
            typealias Rational = (Int64,UInt64)
            typealias Event = (track: Int, sequence: UInt64, epoch: UUID, start: Rational, end: Rational, sample: (start: UInt64, end: UInt64, rate: UInt64)?)
            var events: [Event] = []
            events.reserveCapacity(chunks.count + gaps.count + (candidate == nil ? 0 : 1))
            func append(_ c: ChunkTiming) throws {
                try c.timing.validate()
                try require(tracks.indices.contains(c.track) && segments.indices.contains(c.segment))
                let s = segments[c.segment]
                try require(c.sourceGeneration == tracks[c.track].selection.generation && s.track == c.track && s.generation == c.sourceGeneration && c.timing.epoch == s.timing.epoch && c.timing.mapping == s.timing.mapping && c.timing.rate == s.timing.rate)
                try require(c.frames > 0 && c.frames <= maximumFrames && add(c.start,c.frames) <= maximumTrackFrames)
                try require(c.start >= s.canonicalStart && c.timing.sample >= s.timing.sample)
                guard c.timing.mapping == .validated else { return }
                let product = try multiply(c.frames,c.timing.rate)
                try require(product % 16_000 == 0)
                let sampleEnd = try add(c.timing.sample,product/16_000), end = try c.timing.end(after:c.frames)
                try require(ordered((s.timing.pts,s.timing.denominator),(c.timing.pts,c.timing.denominator)))
                events.append((c.track,c.sequence,c.timing.epoch,(c.timing.pts,c.timing.denominator),end,(c.timing.sample,sampleEnd,c.timing.rate)))
            }
            for c in chunks { try append((c.track,c.sourceGeneration,c.segment,c.sequence,c.start,c.frames,c.timing)) }
            if let candidate { try append(candidate) }
            for g in gaps where g.kind == .measured {
                try require(tracks.indices.contains(g.track) && segments.indices.contains(g.segment))
                let s = segments[g.segment]
                try require(s.track == g.track && s.generation == tracks[g.track].selection.generation && s.timing.mapping == .validated)
                let end = try g.end()
                try require(ordered((s.timing.pts,s.timing.denominator),(g.start,g.startDenominator)))
                events.append((g.track,g.sequence,s.timing.epoch,(g.start,g.startDenominator),end,nil))
            }
            events.sort { $0.track == $1.track ? $0.sequence < $1.sequence : $0.track < $1.track }
            var pts: [Int:[UUID:Rational]] = [:]
            var samples: [Int:[UUID:[UInt64:UInt64]]] = [:]
            for e in events {
                if let end = pts[e.track]?[e.epoch] { try require(ordered(end,e.start)) }
                pts[e.track,default:[:]][e.epoch] = e.end
                if let sample = e.sample {
                    if let end = samples[e.track]?[e.epoch]?[sample.rate] { try require(sample.start >= end) }
                    samples[e.track,default:[:]][e.epoch,default:[:]][sample.rate] = sample.end
                }
            }
        }
        func validate() throws {
            try require(admitted >= 0 && expires == add(admitted,lifetime) && clock >= admitted && clock <= expires)
            try require(tracks.count <= 2 && !tracks.isEmpty && chunks.count <= 240 && segments.count <= 240 && gaps.count <= 240 && provenance.count <= 32)
            try require(Set(tracks.map { $0.selection.instance }).count == tracks.count && Set(tracks.map { $0.selection.kind }).count == tracks.count)
            try require(!(tracks.contains { $0.selection.kind == .selectedApplication } && tracks.contains { $0.selection.kind == .disclosedSystem }))
            var ids = Set<UUID>()
            func unique(_ id: UUID, allocated: Bool = false) throws { try require(ids.insert(id).inserted && (allocated || !reserved(id,session:session))) }
            try unique(owner); try unique(session)
            var attemptBindings: [UUID:UUID] = [:]
            func attemptReference(_ id: UUID, chunk: UUID) throws {
                guard let generation = allocatedGeneration(id,session:session,role:.attempt) else { throw Failure.schema }
                try require(generation <= revision && (attemptBindings[id] == nil || attemptBindings[id] == chunk)); attemptBindings[id] = chunk
            }
            for (i,t) in tracks.enumerated() {
                try unique(t.selection.instance); try text(t.selection.label,cap:128); try require(t.captured <= maximumTrackFrames && segments.indices.contains(t.segment))
                let s = segments[t.segment]; try require(s.track == i && s.generation == t.selection.generation && s.timing.epoch == t.epoch && s.canonicalStart <= t.captured)
            }
            for (i,s) in segments.enumerated() {
                try unique(s.id); try s.timing.validate(); try require(tracks.indices.contains(s.track) && s.generation == tracks[s.track].selection.generation && s.canonicalStart <= maximumTrackFrames)
                if tracks[s.track].segment == i { try require(tracks[s.track].epoch == s.timing.epoch) }
            }
            for g in gaps {
                try unique(g.id); try require(tracks.indices.contains(g.track) && segments.indices.contains(g.segment) && segments[g.segment].track == g.track)
                try require((1...1_000_000).contains(g.startDenominator) && (1...1_000_000).contains(g.extentDenominator))
                try require(g.kind == .unknown ? g.extent == 0 : g.extent > 0)
                if g.kind == .measured {
                    let s = segments[g.segment]; try require(s.timing.mapping == .validated)
                    _ = try g.end(); try require(ordered((s.timing.pts,s.timing.denominator),(g.start,g.startDenominator)))
                }
            }
            for p in provenance { try unique(p.id); try p.validate() }
            var totals = [UInt64](repeating:0,count:tracks.count), acceptedBytes = 0, liveAttempts = 0
            var previous: [Int:Chunk] = [:]
            func checkResult(_ r: Result, chunk: Chunk, complete: Bool) throws {
                _ = try Member(meeting:r.member.meetingJSON,cap:Int64(resultBytes))
                try unique(r.id,allocated:true); try hash(r.hash); try hash(r.sourceHash)
                try require(r.id == allocation(session,role:.result,generation:r.generation) && r.generation <= revision); try attemptReference(r.attempt,chunk:chunk.id)
                try require(r.member.identity.device == root.device && r.bytes > 0 && r.bytes <= resultBytes && r.source == chunk.id && r.sourceGeneration == chunk.generation && r.sourceHash == chunk.hash)
                try require(chunk.stage == .sealed && provenance.indices.contains(r.requested) && provenance.indices.contains(r.observed) && r.requested != r.observed)
                try require(provenance[r.requested].role == .requested && provenance[r.observed].role == .observed && r.created >= admitted && r.created < expires)
                if complete { try require(r.member.bytes == Int64(r.bytes)) }
                else { try require(r.member.bytes == 0 || r.member.bytes == Int64(r.bytes)) }
            }
            for c in chunks {
                try unique(c.id); try hash(c.hash); try c.timing.validate()
                try require(tracks.indices.contains(c.track) && segments.indices.contains(c.segment)); let s = segments[c.segment]
                try require(c.sourceGeneration == tracks[c.track].selection.generation && s.track == c.track && s.generation == c.sourceGeneration && c.timing.epoch == s.timing.epoch && c.timing.mapping == s.timing.mapping && c.timing.rate == s.timing.rate)
                try require(c.frames > 0 && c.frames <= maximumFrames && c.bytes == Int(add(UInt64(44),multiply(c.frames,2))) && add(c.start,c.frames) <= maximumTrackFrames)
                try require(c.member.identity.device == root.device && c.member.bytes >= 0 && c.member.bytes <= Int64(c.bytes)); _ = try Member(meeting:c.member.meetingJSON,cap:Int64(sourceBytes))
                if c.stage == .registered { try require(c.member.bytes == 0) }
                if c.stage == .written || c.stage == .sealed || c.stage == .tooShort { try require(c.member.bytes == Int64(c.bytes)) }
                if c.stage == .sealed { try require(c.frames >= 6400) }; if c.stage == .tooShort { try require(c.frames < 6400) }
                if let p = previous[c.track] {
                    try require(c.sequence > p.sequence && c.start >= add(p.start,p.frames))
                }
                try require(c.start >= s.canonicalStart && c.timing.sample >= s.timing.sample)
                previous[c.track] = c; totals[c.track] = try add(totals[c.track],c.frames)
                if let r = c.accepted { try checkResult(r,chunk:c,complete:true); acceptedBytes = try add(acceptedBytes,r.bytes) }
                if let a = c.attempt { try unique(a.id,allocated:true); try require(a.id == allocation(session,role:.attempt,generation:a.generation)); try attemptReference(a.id,chunk:c.id); try require(provenance.indices.contains(a.requested) && provenance[a.requested].role == .requested); if a.state == .pending { liveAttempts += 1 } }
            }
            try validateTiming()
            try require(acceptedBytes <= resultAggregate && liveAttempts <= 1)
            for (i,t) in tracks.enumerated() {
                try require(totals[i] == t.captured)
                let events = chunks.filter { $0.track == i }.map(\.sequence) + gaps.filter { $0.track == i }.map(\.sequence)
                try require(Set(events).count == events.count)
                if let first = events.min(),let last = events.max() {
                    for (n,sequence) in events.sorted().enumerated() { try require(sequence == add(first,UInt64(n))) }
                    try require(t.sequence == add(last,1))
                }
            }
            if let e = extra {
                try unique(e.authority,allocated:true); try require(chunks.indices.contains(e.chunk));
                let authorityGeneration = e.kind == .candidate ? e.result.generation : chunks[e.chunk].accepted?.generation
                try require(authorityGeneration != nil && e.authority == allocation(session,role:.retirement,generation:authorityGeneration!)); try checkResult(e.result,chunk:chunks[e.chunk],complete:e.kind == .retired || e.stage >= 2)
                try require(e.kind == .retired ? e.stage == 3 : (e.stage == 0 || e.stage == 2))
                if e.kind == .candidate {
                    let old = chunks[e.chunk].accepted?.bytes ?? 0; try require(try add(acceptedBytes - old,e.result.bytes) <= resultAggregate)
                    guard let a = chunks[e.chunk].attempt else { throw Failure.schema }; try require(a.id == e.result.attempt && a.requested == e.result.requested)
                }
            }
            if let d = deletion {
                try require(Deletion(d.json) == d && d.member.bytes > 0 && d.member.identity.device == root.device)
                try unique(d.id)
                try require(state == .deleting || state == .authorityDead); try hash(d.digest); try hash(d.sources)
                try require(d.count == targets.count && d.digest == targetDigest && d.sources == sourceDigest && d.freeze < revision && d.cursor <= d.count && d.phase <= 3)
                try require(state != .authorityDead || (d.cursor == d.count && d.phase == 3))
            } else { try require(state != .deleting && state != .authorityDead) }
            if let t = terminal {
                try require(Terminal(t.json) == t)
                let frames = (0..<2).map { tracks.indices.contains($0) ? tracks[$0].captured : 0 }
                try require(t.frames == frames && t.mask & ~UInt64((1 << tracks.count)-1) == 0)
            }
            if state != .active { try require(terminal != nil) }
            if deletion == nil { try require(revision <= UInt64.max - (terminal == nil ? 245 : 244)) }
        }
    }
}
extension MeetingSession.Timing {
    var json: MeetingJSON { .array([.n(pts),.n(denominator),.n(sample),.n(rate),.u(epoch),.n(mapping.rawValue)]) }
    init(_ j: MeetingJSON) throws {
        let a = try j.list(6); guard let m = MeetingSession.Mapping(rawValue:try a[5].uint(1)) else { throw MeetingSession.Failure.schema }
        self.init(pts:try a[0].int(),denominator:try a[1].uint(1_000_000),sample:try a[2].uint(),rate:try a[3].uint(192_000),epoch:try a[4].id(),mapping:m); try validate()
    }
}
extension MeetingSession.Segment {
    var json: MeetingJSON { .array([.u(id),.n(track),.n(generation),.u(timing.epoch),.n(timing.pts),.n(timing.sample),.n(timing.rate),.n(timing.denominator),.n(timing.mapping.rawValue),.n(canonicalStart)]) }
    init(_ j: MeetingJSON) throws {
        let a = try j.list(10); guard let m = MeetingSession.Mapping(rawValue:try a[8].uint(1)) else { throw MeetingSession.Failure.schema }
        self.init(id:try a[0].id(),track:try a[1].index(1),generation:try a[2].uint(),timing:.init(pts:try a[4].int(),denominator:try a[7].uint(1_000_000),sample:try a[5].uint(),rate:try a[6].uint(192_000),epoch:try a[3].id(),mapping:m),canonicalStart:try a[9].uint(MeetingSession.maximumTrackFrames))
    }
}
extension MeetingSession.Gap {
    var json: MeetingJSON { .array([.u(id),.n(track),.n(segment),.n(sequence),.n(kind.rawValue),.n(start),.n(startDenominator),.n(extent),.n(extentDenominator)]) }
    func end() throws -> (Int64,UInt64) {
        try MeetingSession.require(kind == .measured && extent > 0 && (1...1_000_000).contains(startDenominator) && (1...1_000_000).contains(extentDenominator))
        let divisor = MeetingSession.gcd(startDenominator,extentDenominator)
        let left = try MeetingSession.multiply(start,Int64(extentDenominator/divisor)), right = try MeetingSession.multiply(extent,Int64(startDenominator/divisor))
        return (try MeetingSession.add(left,right),try MeetingSession.multiply(startDenominator,extentDenominator/divisor))
    }
    init(_ j: MeetingJSON) throws {
        let a = try j.list(9); guard let k = Kind(rawValue:try a[4].uint(1)) else { throw MeetingSession.Failure.schema }
        self.init(id:try a[0].id(),track:try a[1].index(1),segment:try a[2].index(239),sequence:try a[3].uint(),kind:k,start:try a[5].int(),startDenominator:try a[6].uint(1_000_000),extent:try a[7].int(),extentDenominator:try a[8].uint(1_000_000))
    }
}
