import Foundation
import Darwin

/// One bounded retained-import ledger. No Settings, History or recognition schema
/// is serialized here; requests and delivery authority exist only in the caller.
public final class SavedAudioImportStore: @unchecked Sendable {
    public typealias Failure = SavedAudioImportStorage.Failure
    public typealias Identity = SavedAudioImportStorage.Identity
    typealias Member = SavedAudioImportStorage.Member
    public static let maximumJobs = 10, maximumSource = 20_971_520, maximumResult = 1_048_576
    public static let maximumLedger = 65_536
    public static let quota: Int64 = 268_435_456
    public struct Original: Codable, Equatable, Sendable {
        public let lexical: String, resolved: String
        public let identity: Identity
        public let bytes: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64
        public let changedSeconds: Int64, changedNanoseconds: Int64, flags: UInt32
        public let birthSeconds: Int64, birthNanoseconds: Int64
        public init(lexical: String, resolved: String, identity: Identity, bytes: Int64,
                    modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64, flags: UInt32, birthSeconds: Int64 = 0, birthNanoseconds: Int64 = 0) {
            self.lexical = lexical; self.resolved = resolved; self.identity = identity; self.bytes = bytes
            self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
            self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds; self.flags = flags
            self.birthSeconds = birthSeconds; self.birthNanoseconds = birthNanoseconds
        }
        func validate() throws {
            for path in [lexical, resolved] {
                guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
                      !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else { throw Failure.bounds }
            }
            guard bytes > 0, bytes <= maximumSource, (0..<1_000_000_000).contains(modifiedNanoseconds),
                  (0..<1_000_000_000).contains(changedNanoseconds), (0..<1_000_000_000).contains(birthNanoseconds) else { throw Failure.bounds }
        }
    }
    public struct Facts: Codable, Equatable, Sendable {
        public let rate: Int, frames: Int, outputFrames: Int, clipped: Int
        public init(_ info: ImportedAudio.SourceInfo) {
            rate = info.sourceRate; frames = info.sourceFrames; outputFrames = info.outputFrames; clipped = info.clippedSamples
        }
        func validate() throws {
            guard [8000,16000,22050,24000,32000,44100,48000].contains(rate), frames >= rate * 2 / 5,
                  frames <= rate * 600, outputFrames >= 6400, outputFrames <= 9_600_000,
                  clipped >= 0, clipped <= outputFrames else { throw Failure.bounds }
        }
    }
    public struct Provenance: Codable, Equatable, Sendable {
        public enum Artifact: String, Codable, Sendable { case unknown, catalog, customRevisionUnknown, systemAssetsRevisionUnknown, parakeet }
        public let engine: String, artifact: Artifact
        public var catalogID: String?, digest: String?, expectedBytes: Int64?, generation: RecognitionFileGeneration?
        public var language: String?, model: String?, filter: String?, hints: Bool
        public var nativeVersion: String?, buildScope: String?, adapter: Int?, compute: Int?
        public var helperDigest: String?, releaseDigest: String?, systemScope: String?
        public var sdkRevision: String?, modelRevision: String?, verification: String?, computeScope: String?
        public init(request: RecognitionRequest) throws {
            engine = request.selection.engine.rawValue
            if request.selection.engine == .whisper, let catalog = ModelCatalog.model(atPath:request.modelPath) {
                artifact = .catalog; catalogID = catalog.id
            } else { artifact = request.selection.engine == .whisper ? .customRevisionUnknown : request.selection.engine == .appleSpeech ? .systemAssetsRevisionUnknown : .parakeet }
            hints = !request.dictionary.isEmpty; language = request.language
            switch request.selection {
            case .appleSpeech(let locale): language = locale
            case .parakeet(let selected, let selectedFilter): model = selected; filter = selectedFilter
            default: break
            }
            try validate()
        }
        public init(observed: RecognitionIdentity?) throws {
            guard let observed else { engine = "unknown"; artifact = .unknown; hints = false; return }
            engine = observed.engine.rawValue; hints = false; generation = observed.generation
            switch observed.artifact {
            case .admittedCatalog(let id, let hash, let bytes): artifact = .catalog; catalogID = id; digest = hash; expectedBytes = bytes
            case .customRevisionUnknown: artifact = .customRevisionUnknown
            case .systemAssetsRevisionUnknown: artifact = .systemAssetsRevisionUnknown
            case .parakeet(let identity):
                artifact = .parakeet; helperDigest = identity.helperBuild; releaseDigest = identity.manifest; systemScope = identity.osScope
                model = identity.model; sdkRevision = identity.sdk; modelRevision = identity.modelRevision
                verification = identity.verification; computeScope = identity.compute
            }
            if case .appleSpeech(let locale) = observed.selection { language = locale }
            if let runtime = observed.runtime {
                nativeVersion = runtime.nativeVersion; buildScope = runtime.buildScope; adapter = runtime.adapterRevision; compute = runtime.compute.defaultsRevision
            }
            try validate()
        }
        func validate() throws {
            guard ["whisper","appleSpeech","parakeet","unknown"].contains(engine) else { throw Failure.unknown }
            for (value, cap) in [(catalogID,128),(language,64),(model,128),(filter,32),(nativeVersion,96),(buildScope,128),(systemScope,128),(verification,96),(computeScope,128)] {
                if let value { guard !value.isEmpty, value.utf8.count <= cap, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.bounds } }
            }
            for hash in [digest,helperDigest,releaseDigest].compactMap({ $0 }) { try Self.hash(hash) }
            for revision in [sdkRevision,modelRevision].compactMap({$0}) {
                guard [40,64].contains(revision.utf8.count),revision.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else {throw Failure.bounds}
            }
            if let expectedBytes { guard expectedBytes > 0 else { throw Failure.bounds } }
            if let generation { guard generation.bytes >= 0, generation.modified.isFinite, generation.changed?.isFinite ?? true else { throw Failure.bounds } }
            guard adapter.map({ (1...1_000_000).contains($0) }) ?? true, compute.map({ (1...1_000_000).contains($0) }) ?? true,
                  try JSONEncoder().encode(self).count <= 2048 else { throw Failure.bounds }
        }
        static func hash(_ s: String) throws {
            guard s.utf8.count == 64, s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.unknown }
        }
    }
    public enum State: String, Codable, Sendable { case staging, committed, queued, running, failed, canceled, interrupted, deleting }
    public enum Association: String, Codable, Sendable { case notSaved, savingIntent, saved, unknown }
    struct Payload: Codable, Equatable {
        let id: UUID, hash: String, bytes: Int64
        var member: Member?
        var published: Bool
        var pending: String { id.uuidString.lowercased() + (kind == .source ? ".source.pending" : ".result.pending") }
        var final: String { id.uuidString.lowercased() + (kind == .source ? ".source.wav" : ".raw.txt") }
        enum Kind: String, Codable { case source, result }
        let kind: Kind
    }
    public struct Accepted: Codable, Equatable, Sendable {
        public let id: UUID, attempt: UUID, revision: UInt64, date: TimeInterval
        public let sourceGeneration: UUID, sourceHash: String, requested: Provenance, observed: Provenance
        public var association: Association
        fileprivate var payload: Payload
    }
    struct Attempt: Codable, Equatable {
        let id: UUID, revision: UInt64, requested: Provenance
    }
    struct Job: Codable, Equatable {
        let id: UUID, label: String, created: TimeInterval, expires: TimeInterval, original: Original, facts: Facts
        var source: Payload, state: State, attempt: Attempt?, accepted: Accepted?, candidate: Accepted?, retired: Payload?
        var tombstone: Member?
        var resourcesRetired = false
        var tombstoneName: String { id.uuidString.lowercased() + ".delete" }
    }
    struct Ledger: Codable, Equatable {
        let schema: Int, owner: UUID, root: Identity
        var revision: UInt64, jobs: [Job]
    }
    struct Marker: Codable, Equatable { let schema: Int, owner: UUID, root: Identity }
    struct Tombstone: Codable, Equatable { let schema: Int, owner: UUID, root: Identity, job: UUID, generation: UUID }
    public struct Row: Identifiable, Sendable {
        public let id: UUID, label: String, created: Date, expires: Date, sourceBytes: Int64, state: State
        public let result: Accepted?, sourceAvailable: Bool, deleting: Bool
    }
    public struct Protection: Sendable {
        public let root: URL
        public let files: [URL], identities: Set<Identity>
        fileprivate let revision: UInt64?, identity: Identity?
    }
    public struct AttemptToken: Equatable, Sendable {
        public let job: UUID, source: UUID, id: UUID, revision: UInt64
    }
    public final class Borrow: @unchecked Sendable {
        private var owner: SavedAudioImportStore?
        public let job: UUID
        fileprivate let id = UUID()
        private let lock = NSLock(); private var ended = false
        fileprivate init(_ owner: SavedAudioImportStore, job: UUID) { self.owner = owner; self.job = job }
        public func end() { lock.withLock { if !ended { ended = true; owner?.endBorrow(job,id:id); owner = nil } } }
        deinit { end() }
    }
    public let storage: SavedAudioImportStorage
    private let lock = NSRecursiveLock()
    private var ledger: Ledger?, manifest: Member?, marker: Member?
    private var tombstones: [UUID: Member] = [:], borrows: [UUID: Int] = [:], fenced = Set<UUID>()
    private var tombstoneCandidates: [UUID:Member] = [:]
    private var heldSources: [UUID:[UUID:SavedAudioImportStorage.Held]] = [:]
    private var issue: Failure?, lastClock: TimeInterval?
    public init(storage: SavedAudioImportStorage) { self.storage = storage }
    public var failure: Failure? { lock.withLock { issue ?? storage.failure } }
    private func encode<T: Encodable>(_ value: T, cap: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value); guard data.count <= cap else { throw Failure.bounds }; return data
    }
    private func decode<T: Codable>(_ type: T.Type, _ bytes: Data, cap: Int) throws -> T {
        guard bytes.count <= cap else { throw Failure.bounds }
        let value = try JSONDecoder().decode(type, from: bytes)
        // Reject extra keys, explicit nulls, invalid enum fallbacks, and noncanonical value shapes.
        let original = try JSONSerialization.jsonObject(with: bytes)
        let encoded = try JSONSerialization.jsonObject(with: encode(value, cap: cap))
        guard (original as? NSDictionary)?.isEqual(encoded) == true else { throw Failure.unknown }
        return value
    }
    private func clock(_ now: Date) throws -> TimeInterval {
        let value = now.timeIntervalSince1970
        guard value.isFinite, value >= 0, (value + 604_800).isFinite, (value + 604_800) - value == 604_800, lastClock.map({ value >= $0 }) ?? true,
              ledger?.jobs.allSatisfy({ value >= $0.created }) ?? true else { throw Failure.clock }
        lastClock = value; return value
    }
    private func validate(_ value: Ledger) throws {
        guard value.schema == 1, value.root == storage.identity, value.jobs.count <= Self.maximumJobs,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              value.jobs.reduce(0, { $0 + ($1.candidate == nil ? 0 : 1) + ($1.retired == nil ? 0 : 1) }) <= 1 else { throw Failure.unknown }
        var names = Set<String>()
        for job in value.jobs {
            try job.original.validate(); try job.facts.validate()
            guard !job.resourcesRetired || job.state == .deleting else { throw Failure.unknown }
            guard job.source.published || job.state == .staging || job.state == .deleting,
                  job.accepted == nil || (job.source.published && job.accepted!.payload.published) else { throw Failure.unknown }
            guard !job.label.isEmpty, job.label.utf8.count <= 640, job.created.isFinite, job.created >= 0,
                  job.expires == job.created + 604_800, job.expires.isFinite, job.expires - job.created == 604_800,
                  job.source.kind == .source, job.source.bytes > 0, job.source.bytes <= Self.maximumSource, job.source.bytes >= Int64(job.facts.frames * 2 + 44) else { throw Failure.unknown }
            for payload in [job.source, job.accepted?.payload, job.candidate?.payload, job.retired].compactMap({ $0 }) {
                try Provenance.hash(payload.hash)
                guard payload.bytes > 0, payload.bytes <= (payload.kind == .source ? Self.maximumSource : Self.maximumResult),
                      names.insert(payload.pending).inserted, names.insert(payload.final).inserted,
                      payload.member.map({ $0.identity.device == value.root.device && $0.bytes >= 0 && $0.bytes <= payload.bytes }) ?? !payload.published else { throw Failure.unknown }
            }
            if let attempt = job.attempt { try attempt.requested.validate(); guard attempt.revision > 0 else { throw Failure.unknown } }
            for result in [job.accepted,job.candidate].compactMap({ $0 }) {
                try result.requested.validate(); try result.observed.validate()
                guard result.id == result.payload.id, result.payload.kind == .result,
                      result.sourceGeneration == job.source.id, result.sourceHash == job.source.hash,
                      result.revision > 0, result.date.isFinite, result.date >= job.created,
                      result.date < job.expires else { throw Failure.unknown }
            }
        }
        guard try charge(value) <= Self.quota else { throw Failure.bounds }
        _ = try encode(value, cap: Self.maximumLedger)
    }
    /// Peak logical charge includes source allocations, all accepted results and
    /// a global candidate, both ledgers, owner, lock and every tombstone reserve.
    private func charge(_ ledger: Ledger) throws -> Int64 {
        var sum: Int64 = 2 * 65_536 + 4096 + 10 * 4096 + 1_048_576
        for job in ledger.jobs {
            for value in [job.source.bytes,job.accepted?.payload.bytes ?? 0] {
                let next = sum.addingReportingOverflow(value); guard !next.overflow, value >= 0 else { throw Failure.bounds }; sum = next.partialValue
            }
        }
        return sum
    }
    private func remaining(_ value: Ledger,budget: SavedAudioImportStorage.Budget) throws -> Int64 {
        var backed: Int64 = 0
        for name in try storage.enumerate(budget) {
            let cap: Int64 = name == "lock" ? 0 : name == "owner.json" || name.hasSuffix(".delete") ? 4096
                : name.hasPrefix("manifest.") ? 65_536 : name.hasSuffix(".raw.txt") || name.hasSuffix(".result.pending") ? 1_048_576 : 20_971_520
            guard let member = try storage.named(name,cap:cap,budget:budget) else { throw Failure.changed }
            let next = backed.addingReportingOverflow(member.bytes); guard !next.overflow else { throw Failure.bounds }; backed = next.partialValue
        }
        return max(0,try charge(value) - backed)
    }
    private func inspect(_ budget: SavedAudioImportStorage.Budget) throws {
        guard let ledger else { throw Failure.unavailable }
        try storage.validate(budget); try validate(ledger)
        if let marker { guard try storage.named("owner.json",cap:4096,budget:budget) == marker else { throw Failure.changed } }
        if let manifest { guard try storage.named("manifest.json",cap:65_536,budget:budget) == manifest else { throw Failure.changed } }
        var allowed = Set(["owner.json","lock","manifest.json"])
        for job in ledger.jobs {
            for payload in [job.source,job.accepted?.payload,job.candidate?.payload,job.retired].compactMap({ $0 }) {
                let pending = try storage.named(payload.pending, cap: payload.bytes, budget: budget)
                let final = try storage.named(payload.final, cap: payload.bytes, budget: budget)
                if let pending {
                    guard !job.resourcesRetired else { throw Failure.unknown }
                    guard let expected = payload.member, pending.identity == expected.identity,
                          pending.birthSeconds == expected.birthSeconds, pending.birthNanoseconds == expected.birthNanoseconds,
                          !payload.published, final == nil else { throw Failure.unknown }
                    allowed.insert(payload.pending)
                }
                if let final {
                    guard !job.resourcesRetired else { throw Failure.unknown }
                    guard let expected = payload.member, final.identity == expected.identity,
                          final.birthSeconds == expected.birthSeconds, final.birthNanoseconds == expected.birthNanoseconds,
                          !payload.published || final == expected, pending == nil else { throw Failure.unknown }
                    allowed.insert(payload.final)
                }
            }
            if let member = try storage.named(job.tombstoneName, cap: 4096, budget: budget) {
                let bytes = try storage.read(job.tombstoneName, expected: member, cap: 4096, payload: false, budget: budget)
                let tombstone = try decode(Tombstone.self, bytes, cap: 4096)
                guard tombstone == Tombstone(schema: 1, owner: ledger.owner, root: ledger.root, job: job.id, generation: job.source.id) else { throw Failure.unknown }
                tombstones[job.id] = member; allowed.insert(job.tombstoneName)
            }
        }
        // A last synced tombstone can outlive ledger retirement. It carries no
        // payload deletion authority; keep it unavailable rather than adopting it.
        guard Set(try storage.enumerate(budget)) == allowed else { throw Failure.unknown }
    }
    @discardableResult public func bootstrap() throws -> [Row] {
        try lock.withLock {
            let budget = storage.budget()
            do {
                guard try storage.open(create: false, budget: budget) else { return [] }
                guard let member = try storage.named("owner.json", cap: 4096, budget: budget),
                      let manifest = try storage.named("manifest.json", cap: 65_536, budget: budget) else { throw Failure.unknown }
                let owner = try decode(Marker.self, storage.read("owner.json", expected: member, cap: 4096, payload: false, budget: budget), cap: 4096)
                let ledger = try decode(Ledger.self, storage.read("manifest.json", expected: manifest, cap: 65_536, payload: false, budget: budget), cap: 65_536)
                guard owner.schema == 1, owner.owner == ledger.owner, owner.root == ledger.root else { throw Failure.unknown }
                self.ledger = ledger; self.manifest = manifest; marker = member
                try inspect(budget)
                return rowsLocked(budget)
            } catch {
                ledger = nil; manifest = nil; marker = nil; tombstones = [:]
                issue = (error as? Failure) ?? .unknown; throw issue!
            }
        }
    }
    private func initialize(_ budget: SavedAudioImportStorage.Budget) throws {
        if ledger != nil { try inspect(budget); return }
        do {
        guard issue == nil, try storage.open(create: true, budget: budget), try storage.enumerate(budget) == ["lock"], let root = storage.identity else { throw Failure.unknown }
        let value = Ledger(schema: 1, owner: UUID(), root: root, revision: 0, jobs: [])
        let bytes = try encode(Marker(schema: 1, owner: value.owner, root: root), cap: 4096)
        try storage.requireSpace(2 * 65_536 + 4096, budget: budget)
        let (fd, allocated) = try storage.create("owner.json", cap: 4096, budget: budget)
        marker = try storage.write(bytes, fd: fd, name: "owner.json", allocated: allocated, remaining: 2 * 65_536 + 4096, authorized: { true }, budget: budget)
        try storage.sync(nil, budget)
        ledger = value
        try publish(value, authorized: { true }, budget: budget)
        } catch { issue = (error as? Failure) ?? .unknown; throw error }
    }
    private func publish(_ next: Ledger, authorized: () -> Bool, budget: SavedAudioImportStorage.Budget) throws {
        try validate(next)
        let bytes = try encode(next, cap: 65_536)
        let reservation = try remaining(next,budget:budget)
        try storage.requireSpace(reservation, budget: budget)
        guard try storage.named("manifest.next", cap: 65_536, budget: budget) == nil else { throw Failure.unknown }
        let (fd, allocated) = try storage.create("manifest.next", cap: 65_536, budget: budget)
        var publicationStarted = false
        do {
            let written = try storage.write(bytes, fd: fd, name: "manifest.next", allocated: allocated, remaining: reservation, authorized: authorized, budget: budget)
            publicationStarted = true
            try storage.rename("manifest.next", member: written, to: "manifest.json", replacing: manifest, authorized: authorized, budget: budget)
            guard let published = try storage.named("manifest.json", cap: 65_536, budget: budget) else { throw Failure.uncertain }
            ledger = next; manifest = published
        } catch {
            if !publicationStarted, let failure = error as? Failure, failure == .io || failure == .revoked || failure == .space {
                // Current-process authority only: this exact exclusive control
                // generation failed before rename, and the old ledger is bound.
                // A crash loses this proof and preserves manifest.next instead.
                do {
                    guard try storage.named("manifest.json",cap:65_536,budget:budget) == manifest else { throw Failure.changed }
                    try storage.unlink("manifest.next",member:allocated,budget:budget); try storage.sync(nil,budget)
                } catch { issue = .uncertain; throw Failure.uncertain }
            } else if (error as? Failure) == .revoked {
                do { try storage.unlink("manifest.next",member:allocated,budget:budget); try storage.sync(nil,budget) }
                catch {issue = .uncertain; throw Failure.uncertain}
            } else { issue = .uncertain }
            throw error
        }
    }

    private func update(_ budget: SavedAudioImportStorage.Budget, authorized: () -> Bool = { true }, _ mutate: (inout Ledger) throws -> Void) throws {
        guard var next = ledger, next.revision < UInt64.max else { throw Failure.bounds }
        next.revision += 1; try mutate(&next); try publish(next, authorized: authorized, budget: budget)
    }
    private func index(_ job: UUID) throws -> Int {
        guard let index = ledger?.jobs.firstIndex(where: { $0.id == job }) else { throw Failure.unavailable }; return index
    }
    private func current(_ token: AttemptToken, now: Date, budget: SavedAudioImportStorage.Budget, recovery: Bool = false) throws -> Int {
        let i = try index(token.job), job = ledger!.jobs[i]
        guard issue == nil || (recovery && issue == .uncertain && storage.failure == nil) else {throw Failure.unavailable}
        guard !fenced.contains(job.id), tombstones[job.id] == nil, job.state != .deleting,
              job.source.id == token.source, job.attempt?.id == token.id, job.attempt?.revision == token.revision,
              try clock(now) < job.expires else { throw Failure.revoked }
        try inspect(budget)
        for held in heldSources[job.id]?.values ?? [:].values { try storage.validateHeld(held,budget:budget) }
        return i
    }
    public func admit(id: UUID, bytes: Data, original: Original, facts: Facts, label: String,
                      requested: Provenance, now: Date, startedUptime: TimeInterval? = nil, priorWorkCredits: Int = 0, authorized: () -> Bool) throws -> AttemptToken {
        try lock.withLock {
            guard (0...65_536).contains(priorWorkCredits) else {throw Failure.bounds}
            let budget = storage.budget(started:startedUptime,credits:priorWorkCredits)
            try original.validate(); try facts.validate(); try requested.validate()
            guard bytes.count == original.bytes, bytes.count <= Self.maximumSource, authorized() else { throw Failure.bounds }
            try initialize(budget)
            let date = try clock(now)
            guard ledger!.jobs.count < 10, !ledger!.jobs.contains(where: { $0.candidate != nil || $0.retired != nil || $0.state == .staging || $0.state == .queued || $0.state == .running || $0.state == .deleting || $0.resourcesRetired }),
                  issue == nil, !hasPendingStorage else { throw Failure.bounds }
            let source = Payload(id: UUID(), hash: SavedAudioImportStorage.digest(bytes), bytes: Int64(bytes.count), member: nil, published: false, kind: .source)
            let job = Job(id: id, label: label, created: date, expires: date + 604_800, original: original, facts: facts, source: source, state: .staging, attempt: nil, accepted: nil, candidate: nil, retired: nil)
            try update(budget, authorized: authorized) { $0.jobs.append(job) }
            try storage.step(.allocation,budget,name:source.pending)
            let i = try index(id)
            try writePayload(bytes, job: i, result: false, authorized: authorized, budget: budget)
            return try beginLocked(id, requested: requested, now: now, authorized: authorized, budget: budget)
        }
    }
    private func writePayload(_ bytes: Data, job i: Int, result: Bool, authorized: () -> Bool, budget: SavedAudioImportStorage.Budget) throws {
        do {
        var payload = result ? ledger!.jobs[i].candidate!.payload : ledger!.jobs[i].source
        let (fd, member) = try storage.create(payload.pending, cap: payload.bytes, budget: budget)
        let reservedRemaining: Int64
        // Register exclusive allocation identity before the first payload byte.
        do {
            try update(budget, authorized: authorized) { value in
                if result { value.jobs[i].candidate!.payload.member = member } else { value.jobs[i].source.member = member }
            }
            try storage.step(.registered,budget,name:payload.pending)
            // Keep throwing reservation checks inside the allocation's cleanup
            // scope until the consuming writer takes ownership of its fd.
            reservedRemaining = try remaining(ledger!,budget:budget)
        } catch { // write(empty) retires the exclusive fd; no payload/adoption/cleanup.
            _ = try? storage.write(Data(), fd: fd, name: payload.pending, allocated: member, remaining: 0, authorized: { false }, budget: budget)
            issue = .uncertain; throw error
        }
        let written = try storage.write(bytes, fd: fd, name: payload.pending, allocated: member, remaining: reservedRemaining, authorized: authorized, budget: budget)
        try storage.rename(payload.pending, member: written, to: payload.final, replacing: nil, authorized: authorized, budget: budget)
        payload.member = try storage.named(payload.final, cap: payload.bytes, budget: budget); payload.published = true
        try update(budget, authorized: authorized) { value in
            if result { value.jobs[i].candidate!.payload = payload } else { value.jobs[i].source = payload; value.jobs[i].state = .committed }
        }
        } catch {
            if let failure = error as? Failure, failure == .uncertain || failure == .changed || failure == .unknown {issue = .uncertain}
            throw error
        }
    }
    private func beginLocked(_ id: UUID, requested: Provenance, now: Date, authorized: () -> Bool, budget: SavedAudioImportStorage.Budget) throws -> AttemptToken {
        let i = try index(id), job = ledger!.jobs[i]
        guard issue == nil, !hasPendingStorage, !fenced.contains(id), tombstones[id] == nil, job.state != .deleting, job.source.published,
              ledger!.jobs.allSatisfy({ $0.candidate == nil && $0.retired == nil }), try clock(now) < job.expires,
              (job.attempt?.revision ?? 0) < UInt64.max else { throw Failure.revoked }
        let attempt = Attempt(id: UUID(), revision: (job.attempt?.revision ?? 0) + 1, requested: requested)
        try update(budget, authorized: authorized) { $0.jobs[i].attempt = attempt; $0.jobs[i].state = .queued }
        return AttemptToken(job: id, source: job.source.id, id: attempt.id, revision: attempt.revision)
    }
    public func begin(_ id: UUID, requested: Provenance, now: Date, authorized: () -> Bool) throws -> AttemptToken {
        try lock.withLock { let b = storage.budget(); try inspect(b); return try beginLocked(id, requested: requested, now: now, authorized: authorized, budget: b) }
    }
    public func borrow(_ token: AttemptToken, now: Date) throws -> Borrow {
        try lock.withLock {
            let b = storage.budget(), i = try current(token,now:now,budget:b), payload = ledger!.jobs[i].source
            guard payload.published, let member = payload.member else { throw Failure.unavailable }
            let held = try storage.hold(payload.final,member:member,budget:b)
            let borrow = Borrow(self,job:token.job)
            heldSources[token.job,default:[:]][borrow.id] = held
            borrows[token.job,default:0] += 1
            return borrow
        }
    }
    private func endBorrow(_ job: UUID,id: UUID) {
        lock.withLock {
            guard let held = heldSources[job]?[id] else { return }
            do { try storage.release(held,budget:storage.budget()) }
            catch { issue = .uncertain; return } // uncertain close never frees a deletion/exit barrier
            heldSources[job]?[id] = nil; borrows[job] = max(0,borrows[job,default:0] - 1)
        }
    }
    public func source(_ token: AttemptToken, now: Date, authorized: () -> Bool = {true}) throws -> Data {
        try lock.withLock {
            let b = storage.budget(), i = try current(token, now: now, budget: b), payload = ledger!.jobs[i].source
            guard payload.published, let member = payload.member else { throw Failure.unavailable }
            return try storage.read(payload.final, expected: member, cap: payload.bytes, expectedHash: payload.hash, payload: true, authorized:authorized, budget: b)
        }
    }
    public func validateRAMReview(_ token: AttemptToken, now: Date) throws {
        try lock.withLock {
            let i = try index(token.job), job = ledger!.jobs[i]
            guard !fenced.contains(job.id), tombstones[job.id] == nil, job.state != .deleting,
                  token.source == job.source.id, job.attempt?.id == token.id, job.attempt?.revision == token.revision,
                  try clock(now) < job.expires else {throw Failure.revoked}
        }
    }
    public func validateReview(_ id: UUID, resultID: UUID, token: AttemptToken?, now: Date) throws {
        try lock.withLock {
            let b = storage.budget(), i = try index(id), job = ledger!.jobs[i]
            guard !fenced.contains(id), tombstones[id] == nil, job.state != .deleting, try clock(now) < job.expires else { throw Failure.revoked }
            if job.accepted?.id != resultID {
                guard let token, token.job == id, token.source == job.source.id,
                      job.attempt?.id == token.id, job.attempt?.revision == token.revision else { throw Failure.revoked }
            }
            try inspect(b)
        }
    }
    public func validateAttempt(_ token: AttemptToken, now: Date) throws {
        try lock.withLock { _ = try current(token,now:now,budget:storage.budget()) }
    }
    public func running(_ token: AttemptToken, now: Date) throws {
        try lock.withLock { let b = storage.budget(), i = try current(token, now: now, budget: b); try update(b) { $0.jobs[i].state = .running } }
    }
    public func finish(_ token: AttemptToken, canceled: Bool) throws {
        try lock.withLock {
            let b = storage.budget(), i = try index(token.job)
            guard !fenced.contains(token.job), tombstones[token.job] == nil, ledger!.jobs[i].state != .deleting,
                  !ledger!.jobs[i].resourcesRetired, ledger!.jobs[i].attempt?.id == token.id else { return }
            try update(b) { $0.jobs[i].state = canceled ? .canceled : .failed }
        }
    }
    public func saveResult(_ token: AttemptToken, resultID: UUID, bytes: Data, observed: Provenance,
                           now: Date, resultDate: Date? = nil, authorized: () -> Bool) throws -> Accepted {
        try lock.withLock {
            let b = storage.budget(), i = try current(token, now: now, budget: b,recovery:true), job = ledger!.jobs[i]
            guard bytes.count > 0, bytes.count <= Self.maximumResult, let text = String(data: bytes, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.bounds }
            try observed.validate()
            if let accepted = job.accepted, accepted.id == resultID {
                guard accepted.payload.hash == SavedAudioImportStorage.digest(bytes) else { throw Failure.changed }
                try retirePrevious(i,budget:b)
                if !hasPendingStorage, storage.failure == nil {issue = nil}
                return ledger!.jobs[i].accepted!
            }
            guard job.retired == nil else { throw Failure.unavailable }
            guard ledger!.jobs.allSatisfy({ $0.id == job.id || ($0.candidate == nil && $0.retired == nil) }) else { throw Failure.bounds }
            if let pending = job.candidate {
                guard pending.id == resultID, pending.attempt == token.id, pending.payload.hash == SavedAudioImportStorage.digest(bytes) else { throw Failure.changed }
                // Storage-only retry retires just this known candidate, then writes
                // the same result ID/revision/bytes. No source or ASR is involved.
                if let member = pending.payload.member {
                    for name in [pending.payload.pending,pending.payload.final] { try storage.unlink(name, member: member, budget: b) }
                    try storage.sync(nil, b)
                }
                try update(b) { $0.jobs[i].candidate = nil }
            }
            let payload = Payload(id: resultID, hash: SavedAudioImportStorage.digest(bytes), bytes: Int64(bytes.count), member: nil, published: false, kind: .result)
            let result = Accepted(id: resultID, attempt: token.id, revision: token.revision, date: (resultDate ?? now).timeIntervalSince1970, sourceGeneration: job.source.id,
                sourceHash: job.source.hash, requested: job.attempt!.requested, observed: observed, association: .notSaved, payload: payload)
            try update(b, authorized: authorized) { $0.jobs[i].candidate = result }
            try writePayload(bytes, job: i, result: true, authorized: authorized, budget: b)
            guard authorized() else { throw Failure.revoked }
            try update(b, authorized: authorized) { value in
                value.jobs[i].retired = value.jobs[i].accepted?.payload
                value.jobs[i].accepted = value.jobs[i].candidate; value.jobs[i].candidate = nil; value.jobs[i].state = .committed
            }
            try retirePrevious(i,budget:b)
            if !hasPendingStorage, storage.failure == nil {issue = nil}
            return ledger!.jobs[i].accepted!
        }
    }
    private func retirePrevious(_ i: Int,budget b: SavedAudioImportStorage.Budget) throws {
        if let retired = ledger!.jobs[i].retired, let member = retired.member {
            try storage.unlink(retired.final,member:member,budget:b); try storage.sync(nil,b)
            try update(b) { $0.jobs[i].retired = nil }
        }
    }
    public func openResult(_ id: UUID, now: Date, authorized: () -> Bool = {true}) throws -> (Accepted, Data) {
        try lock.withLock {
            let b = storage.budget(); try inspect(b)
            let i = try index(id), job = ledger!.jobs[i]
            guard !fenced.contains(id), tombstones[id] == nil, job.state != .deleting, try clock(now) < job.expires,
                  let result = job.accepted, result.payload.published, let member = result.payload.member else { throw Failure.revoked }
            let bytes = try storage.read(result.payload.final, expected: member, cap: Int64(Self.maximumResult), expectedHash: result.payload.hash, payload: true, authorized:authorized, budget: b)
            guard let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.changed }
            try storage.qualify(result.payload.final,member:member,budget:b)
            if let manifest {try storage.qualify("manifest.json",member:manifest,budget:b)}
            if let marker {try storage.qualify("owner.json",member:marker,budget:b)}
            if !hasPendingStorage, storage.failure == nil {issue = nil}
            return (result,bytes)
        }
    }
    public func association(_ id: UUID, resultID: UUID, state: Association, now: Date, authorized: () -> Bool) throws {
        try lock.withLock {
            let b = storage.budget(), i = try index(id), job = ledger!.jobs[i]
            guard issue == nil, storage.failure == nil, authorized(), !fenced.contains(id), tombstones[id] == nil,
                  job.state != .deleting, !job.resourcesRetired, try clock(now) < job.expires,
                  job.accepted?.id == resultID else { throw Failure.revoked }
            try update(b, authorized: authorized) { $0.jobs[i].accepted!.association = state }
        }
    }
    public func intentDelete(_ id: UUID) throws {
        try lock.withLock {
            let b = storage.budget(), i = try index(id), job = ledger!.jobs[i]
            fenced.insert(id)
            if tombstones[id] != nil { return }
            if job.resourcesRetired {
                guard job.state == .deleting else { throw Failure.unknown }
                try inspect(b)
                return // durable authority retirement already forbids every admission
            }
            do {
                let data = try encode(Tombstone(schema: 1, owner: ledger!.owner, root: ledger!.root, job: id, generation: job.source.id), cap: 4096)
                if let candidate = tombstoneCandidates[id], let current = try storage.named(job.tombstoneName,cap:4096,budget:b) {
                    guard candidate.identity == current.identity, candidate.birthSeconds == current.birthSeconds,
                          candidate.birthNanoseconds == current.birthNanoseconds else { throw Failure.changed }
                    let bytes = try storage.read(job.tombstoneName,expected:current,cap:4096,payload:false,budget:b)
                    if bytes == data {
                        try storage.qualify(job.tombstoneName,member:current,budget:b)
                        tombstones[id] = current
                        try update(b) { $0.jobs[i].state = .deleting; $0.jobs[i].tombstone = current }
                        tombstoneCandidates[id] = nil; return
                    }
                    // Only this process remembers the exact exclusive generation.
                    // A relaunched owner never adopts or removes a partial intent.
                    try storage.unlink(job.tombstoneName,member:candidate,budget:b); try storage.sync(nil,b)
                    tombstoneCandidates[id] = nil
                }
                try inspect(b)
                try storage.requireSpace(4096, budget: b)
                let (fd, allocation) = try storage.create(job.tombstoneName, cap: 4096, budget: b)
                tombstoneCandidates[id] = allocation
                let member = try storage.write(data, fd: fd, name: job.tombstoneName, allocated: allocation, remaining: 4096, authorized: { true }, budget: b)
                try storage.sync(nil, b); tombstones[id] = member; tombstoneCandidates[id] = nil
                try update(b) { $0.jobs[i].state = .deleting; $0.jobs[i].tombstone = member }
            } catch { issue = .uncertain; throw error }
        }
    }
    public func finishDelete(_ id: UUID) throws {
        try lock.withLock {
            let b = storage.budget(), i = try index(id), job = ledger!.jobs[i]
            guard tombstones[id] != nil || (job.state == .deleting && job.resourcesRetired),
                  borrows[id, default: 0] == 0 else { throw Failure.unavailable }
            do {
                try inspect(b)
                for payload in [job.source,job.accepted?.payload,job.candidate?.payload,job.retired].compactMap({ $0 }) {
                    if let member = payload.member {
                        for name in [payload.pending,payload.final] { try storage.unlink(name, member: member, budget: b) }
                    }
                }
                try storage.sync(nil, b)
                try storage.step(.payloadRetired,b,name:job.tombstoneName)
                if !job.resourcesRetired { try update(b) { $0.jobs[i].state = .deleting; $0.jobs[i].resourcesRetired = true } }
                try storage.step(.authorityRetired,b,name:job.tombstoneName)
                if let tombstone = tombstones[id] {
                    try storage.unlink(job.tombstoneName, member: tombstone, budget: b); try storage.sync(nil, b)
                }
                try storage.step(.tombstoneRetired,b,name:job.tombstoneName)
                // Keep the deleting slot and its reservations charged through
                // tombstone retirement; a crash before this final ledger write
                // remains deleting, never a reopened ready job.
                try update(b) { $0.jobs.remove(at:i) }
                try storage.step(.allocationRetired,b,name:job.tombstoneName)
                tombstones[id] = nil; tombstoneCandidates[id] = nil; fenced.remove(id)
                if !hasPendingStorage, storage.failure == nil {issue = nil}
            } catch { issue = .uncertain; throw error }
        }
    }
    private var hasPendingStorage: Bool {
        !fenced.isEmpty || !tombstones.isEmpty || !tombstoneCandidates.isEmpty || (ledger?.jobs.contains(where:{
            $0.state == .staging || $0.state == .deleting || $0.candidate != nil || $0.retired != nil
        }) ?? false)
    }
    public func maintenance(now: Date) throws {
        try lock.withLock {
            guard ledger != nil else { return }
            let time = try clock(now)
            let ids = ledger!.jobs.filter { ($0.expires <= time || tombstones[$0.id] != nil || $0.state == .deleting) && borrows[$0.id,default:0] == 0 }.map(\.id)
            for id in ids { try intentDelete(id); try finishDelete(id) }
        }
    }
    private func rowsLocked(_ b: SavedAudioImportStorage.Budget) -> [Row] {
        (ledger?.jobs ?? []).map { job in
            let source = (try? storage.named(job.source.final, cap: job.source.bytes, budget: b)) != nil
            let deleting = job.state == .deleting || fenced.contains(job.id) || tombstones[job.id] != nil
            return Row(id: job.id, label: job.label, created: Date(timeIntervalSince1970: job.created), expires: Date(timeIntervalSince1970: job.expires),
                sourceBytes: job.source.bytes, state: job.state == .running || job.state == .queued ? .interrupted : job.state,
                result: deleting ? nil : job.accepted, sourceAvailable: source && job.source.published && !deleting, deleting: deleting)
        }
    }
    public func rows() -> [Row] { lock.withLock { rowsLocked(storage.budget()) } }
    public func protection() throws -> Protection {
        try lock.withLock {
            guard issue == nil else { throw issue! }
            guard let ledger else {
                var named = stat()
                guard lstat(storage.root.path,&named) != 0, errno == ENOENT else { throw Failure.unknown }
                return Protection(root: storage.root, files: [], identities: [], revision:nil,identity:nil)
            }
            let b = storage.budget(); try inspect(b)
            var files: [URL] = [], identities = Set<Identity>()
            for name in try storage.enumerate(b) {
                guard let member = try storage.named(name, cap: 20_971_520, budget: b) else { throw Failure.changed }
                files.append(storage.root.appendingPathComponent(name)); identities.insert(member.identity)
            }
            for job in ledger.jobs {
                files += [URL(fileURLWithPath: job.original.lexical),URL(fileURLWithPath: job.original.resolved)]
                identities.insert(job.original.identity)
            }
            return Protection(root: storage.root, files: files, identities: identities,revision:ledger.revision,identity:ledger.root)
        }
    }
    public func validateProtection(_ projection: Protection) throws {
        try lock.withLock {
            guard issue == nil, projection.revision == ledger?.revision, projection.identity == ledger?.root else {throw Failure.changed}
            if ledger != nil {try inspect(storage.budget())}
            else {var s = stat(); guard lstat(storage.root.path,&s) != 0, errno == ENOENT else {throw Failure.unknown}}
        }
    }
    public func close() throws { try lock.withLock { guard borrows.values.allSatisfy({ $0 == 0 }) else { throw Failure.unavailable }; try storage.close() } }
}
