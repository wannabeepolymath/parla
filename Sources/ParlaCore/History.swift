import Foundation

/// What one dictation cost in time and tokens. Every field is optional and the
/// whole struct is optional on the entry: a history.json written before this
/// existed, a leg that never ran cleanup, and a dictation that ended early all
/// have to load, so "we don't know" is a value rather than a decode failure.
///
/// The timings are derived from `Trace.Stamp`s — the same vocabulary the
/// env-gated latency trace prints, so the two can't drift apart. The difference
/// is only that these persist.
public struct PipelineMetrics: Codable, Equatable, Sendable {
    public var captureMs: Int?      // fn-down → fn-up: how long the user spoke
    public var asrMs: Int?          // fn-up → final whisper pass done
    public var insertMs: Int?       // final pass → keystrokes landed
    public var cleanupMs: Int?      // landed → cleaned text swapped in
    public var totalMs: Int?        // fn-down → last stamp of the dictation
    public var model: String?       // whisper model that produced `raw`
    public var cleanupModel: String? // LLM that produced `cleaned`
    public var promptTokens: Int?
    public var completionTokens: Int?
    public init() {}
    public var isEmpty: Bool { self == PipelineMetrics() }
}

/// One recorded dictation. `cleaned` is nil when cleanup failed, was skipped
/// (secure field), or produced text identical to `raw`. Codable Date rides the
/// default JSONEncoder representation — roundtrips with the matching decoder.
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var date: Date
    public let raw: String
    public var cleaned: String?
    public var appName: String?
    public var metrics: PipelineMetrics?
    public var operation: TransformProvenance?
    public var retries: [HistoryRetryProvenance]?
    // Only used by the store to decide whether a legacy file needs migration.
    var needsIDMigration = false
    private enum CodingKeys: String, CodingKey { case id, date, raw, cleaned, appName, metrics, operation, retries }

    public init(id: UUID = UUID(), date: Date = Date(), raw: String, cleaned: String? = nil, appName: String? = nil,
                metrics: PipelineMetrics? = nil, operation: TransformProvenance? = nil, retries: [HistoryRetryProvenance]? = nil) {
        self.id = id; self.date = date; self.raw = raw; self.cleaned = cleaned; self.appName = appName
        self.metrics = metrics; self.operation = operation; self.retries = retries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decodeIfPresent(UUID.self, forKey: .id)
        id = decodedID ?? UUID()
        needsIDMigration = decodedID == nil
        date = try c.decode(Date.self, forKey: .date)
        raw = try c.decode(String.self, forKey: .raw)
        cleaned = try c.decodeIfPresent(String.self, forKey: .cleaned)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        metrics = try c.decodeIfPresent(PipelineMetrics.self, forKey: .metrics)
        operation = try c.decodeIfPresent(TransformProvenance.self, forKey: .operation)
        retries = try c.decodeIfPresent([HistoryRetryProvenance].self, forKey: .retries)
    }

    func identified(by id: UUID) -> Self {
        Self(id: id, date: date, raw: raw, cleaned: cleaned, appName: appName, metrics: metrics, operation: operation, retries: retries)
    }

    /// What to paste/show: the polished text when we have it, else the raw.
    public var best: String { cleaned ?? raw }
}

/// Synchronous, main-thread store shared by the interpreter, Hub and menu.
/// Committed rows change only after an atomic write succeeds. Unsaved results
/// live separately in memory until explicitly saved, discarded or cleared.
public final class HistoryStore: NSObject {
    public static let cap = 50 // legacy/default count
    public static let countRange = 1...1000
    public static let didChange = Notification.Name("ParlaHistoryDidChange")
    public static func boundedCount(_ count: Int) -> Int { min(max(count, countRange.lowerBound), countRange.upperBound) }

    /// Injectable disk boundary. writeAtomically must leave old bytes untouched
    /// on failure; the production implementation uses Foundation's atomic write.
    public struct Persistence {
        public var read: (URL) throws -> Data
        public var writeAtomically: (Data, URL) throws -> Void
        public init(read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
                    writeAtomically: @escaping (Data, URL) throws -> Void = { data, url in
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                    }) {
            self.read = read; self.writeAtomically = writeAtomically
        }
    }

    public let url: URL
    /// nil defers retention until settings provide a valid policy.
    public private(set) var countLimit: Int?
    private enum Failure {
        case load, migration, save, delete, clear, trim
        var message: String {
            switch self {
            case .load: return "Couldn't load history. Original file is unchanged. Repair it, then Retry Load."
            case .migration: return "Couldn't migrate history. Retry Load before changing rows."
            case .save: return "Couldn't save result. Saved text is unchanged; retry explicitly."
            case .delete: return "Couldn't delete text. Saved text is unchanged; retry explicitly."
            case .clear: return "Couldn't clear text history. Saved text is unchanged; retry explicitly."
            case .trim: return "Couldn't trim history. Count policy has not been applied; retry explicitly."
            }
        }
    }
    private var failure: Failure?
    public var lastError: String? {
        guard let failure else { return nil }
        return failure.message + (loadBlocked && failure != .load && failure != .migration
            ? " Retry Load before changing rows." : "")
    }
    public private(set) var loadBlocked = false
    public private(set) var pendingEntries: [HistoryEntry] = [] // newest first, never silently evicted
    private var items: [HistoryEntry] = [] // oldest first
    private let persistence: Persistence
    private var diskData: Data?
    private var rowVersions: [UUID: UUID] = [:]
    private var versionRows: [UUID: HistoryEntry] = [:]
    private enum PersistenceError: Error { case changedOnDisk }

    public init(url: URL? = nil, countLimit: Int? = HistoryStore.cap, persistence: Persistence = .init()) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/history.json")
        self.countLimit = countLimit.map(Self.boundedCount)
        self.persistence = persistence
        super.init()
        reload()
    }

    public convenience init(settings: SettingsStore, url: URL? = nil) {
        let current = settings.load()
        self.init(url: url, countLimit: settings.lastError == nil ? current.historyTextCount : nil)
    }

    public var entries: [HistoryEntry] { items.reversed() }
    public var needsAttention: Bool { lastError != nil || !pendingEntries.isEmpty }

    /// A missing file is a new log. Every other read/decode failure blocks ALL
    /// writes until an explicit successful reload, preserving the original bytes.
    @discardableResult public func reload(countLimit: Int? = nil) -> Bool {
        if let countLimit { self.countLimit = Self.boundedCount(countLimit) }
        defer { changed() }
        let mutationFailure = failure == .save || failure == .delete || failure == .clear ? failure : nil
        do {
            let data: Data
            do { data = try persistence.read(url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                items = []; diskData = nil; loadBlocked = false
                failure = mutationFailure
                return true
            }
            let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
            var seen = Set<UUID>()
            var migration = false
            let normalized = decoded.map { entry -> HistoryEntry in
                // Preserve the first occurrence; reidentify subsequent collisions.
                // No row ever aliases another row, even in a hand-edited file.
                var id = entry.id
                if seen.contains(id) { repeat { id = UUID() } while seen.contains(id) }
                seen.insert(id)
                migration = migration || entry.needsIDMigration || id != entry.id
                return entry.identified(by: id)
            }
            if diskData != data { rowVersions.removeAll() }
            diskData = data
            loadBlocked = false
            let retained = self.countLimit.map { Array(normalized.suffix($0)) } ?? normalized
            if migration || retained.count != normalized.count {
                do { try write(retained) }
                catch {
                    // Rows read successfully remain readable; failed migrations
                    // are blocked so their temporary IDs cannot become addresses.
                    items = normalized
                    loadBlocked = loadBlocked || migration
                    failure = mutationFailure ?? (migration ? .migration : .trim)
                    return false
                }
            }
            items = retained; loadBlocked = false
            // Merely opening Hub must not erase a failed menu Delete/Clear or
            // Save. A successful repair/migration/trim resolves its own error.
            failure = mutationFailure
            // A reopened file may contain a previously pending save. Reconcile IDs.
            pendingEntries.removeAll { pending in items.contains(pending) }
            var used = Set(items.map(\.id))
            pendingEntries = pendingEntries.map { pending in
                var id = pending.id
                if used.contains(id) { repeat { id = UUID() } while used.contains(id) }
                used.insert(id)
                return pending.identified(by: id)
            }
            return true
        } catch {
            loadBlocked = true
            failure = mutationFailure ?? .load
            return false
        }
    }

    /// Identical ID+content is idempotent. A conflicting ID is reidentified;
    /// returned results are never overwritten, including pending results.
    @discardableResult public func append(_ entry: HistoryEntry) -> Bool {
        if items.contains(entry) { return true }
        if pendingEntries.contains(entry) { return retrySave(entry.id) }
        let collision = items.contains { $0.id == entry.id } || pendingEntries.contains { $0.id == entry.id }
        let entry = collision ? entry.identified(by: UUID()) : entry.identified(by: entry.id)
        pendingEntries.insert(entry, at: 0)
        return retrySave(entry.id)
    }

    /// Explicit reviewed-result storage. The caller owns unsaved text and retry
    /// authority; failure must never create an ordinary pending Save escape.
    @discardableResult public func appendReviewed(_ entry: HistoryEntry) -> Bool {
        defer { changed() }
        guard !loadBlocked else { failure = .save; return false }
        if let existing = items.first(where: { $0.id == entry.id }) {
            guard existing == entry else { failure = .save; return false }
            // Even an idempotent click must not endorse a stale disk projection.
            return commit(items, action: .save)
        }
        guard !pendingEntries.contains(where: { $0.id == entry.id }) else { failure = .save; return false }
        return commit(items + [entry.identified(by: entry.id)], action: .save)
    }

    /// A process-local identity for this exact committed row. External reloads
    /// invalidate identities even if a replacement happens to reuse ID+content.
    public func version(of id: UUID) -> UUID? { rowVersions[id] }
    public func matches(_ expected: HistoryEntry, version: UUID) -> Bool {
        rowVersions[expected.id] == version && items.first { $0.id == expected.id } == expected
    }
    public enum UpdateOutcome { case saved, stale, failed }
    /// Conditional UPDATE only. Failure never creates a pending APPEND.
    @discardableResult public func updateResult(expected: HistoryEntry, version: UUID,
                                               text: String, retry: HistoryRetryProvenance) -> UpdateOutcome {
        defer { changed() }
        guard matches(expected, version: version), let index = items.firstIndex(where: { $0.id == expected.id }) else { return .stale }
        if let countLimit, index < items.count - countLimit { return .stale }
        var next = items
        next[index].cleaned = text
        next[index].retries = (expected.retries ?? []) + [retry]
        return commit(next, action: .save) ? .saved : .failed
    }

    /// Storage only: no ASR, cleanup, insertion or metrics collection on retry.
    @discardableResult public func retrySave(_ id: UUID) -> Bool {
        defer { changed() }
        guard let entry = pendingEntries.first(where: { $0.id == id }) else { return false }
        let next = items + [entry]
        guard commit(next, action: .save) else { return false }
        pendingEntries.removeAll { $0.id == id }
        return true
    }

    public func discard(_ id: UUID) {
        pendingEntries.removeAll { $0.id == id }
        if pendingEntries.isEmpty, !loadBlocked, failure == .save { failure = nil }
        changed()
    }

    @discardableResult public func delete(_ id: UUID) -> Bool {
        defer { changed() }
        guard items.contains(where: { $0.id == id }) else { return false }
        return commit(items.filter { $0.id != id }, action: .delete)
    }

    /// Failed clear retains both committed rows AND unsaved results. Successful
    /// clear discards the current pending set; later new results remain new.
    @discardableResult public func clear() -> Bool {
        defer { changed() }
        guard commit([], action: .clear) else { return false }
        pendingEntries = []
        return true
    }

    @discardableResult public func applyCountLimit(_ count: Int) -> Bool {
        defer { changed() }
        let limit = Self.boundedCount(count)
        countLimit = limit
        if items.count > limit { return commit(Array(items.suffix(limit)), action: .trim) }
        if !loadBlocked, failure == .trim { failure = nil }
        return !loadBlocked
    }

    @discardableResult private func commit(_ next: [HistoryEntry], action: Failure) -> Bool {
        guard !loadBlocked else {
            failure = action
            return false
        }
        do {
            // Any successful mutation also satisfies the configured count. A
            // later Delete must not hide an earlier failed trim while still
            // leaving too many committed rows.
            let retained = countLimit.map { Array(next.suffix($0)) } ?? next
            try write(retained)
            items = retained; failure = nil
            return true
        } catch {
            failure = action
            return false
        }
    }

    private func write(_ entries: [HistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        // Refuse to overwrite external edits/deletions or a now-unreadable file
        // with a cached array. Retry Load explicitly reconciles disk and memory.
        do {
            let current: Data?
            do { current = try persistence.read(url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
            guard current == diskData else { throw PersistenceError.changedOnDisk }
        } catch {
            loadBlocked = true
            throw error
        }
        try persistence.writeAtomically(data, url)
        diskData = data
    }

    private func changed() {
        var versions: [UUID: UUID] = [:]
        var rows: [UUID: HistoryEntry] = [:]
        for entry in items {
            versions[entry.id] = versionRows[entry.id] == entry ? (rowVersions[entry.id] ?? UUID()) : UUID()
            rows[entry.id] = entry
        }
        rowVersions = versions; versionRows = rows
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// Accumulates the current dictation's metrics until the history entry is
/// written. A singleton for the same reason `Trace` is one: the numbers arrive
/// from the interpreter, from whisper's leg and from inside the cleanup client,
/// none of which share a value to thread them through — and `CleanupProviding`
/// returns a String, so tokens have no other way home.
///
/// Unlike `Trace` it cannot simply reset on `.fnDown`. The cleanup POST is
/// issued *after* the raw text lands, and the user is free to start the next
/// dictation while it is still out — a reset there drops the first dictation's
/// stamps and bills its tokens to the second. So the outgoing dictation is
/// parked instead of dropped, and the polish result follows it home.
///
/// ponytail: the park is one deep and needs no explicit generation — the
/// processTask chain serializes the legs, so only one cleanup POST is ever in
/// flight. Key by a real generation if that ever stops being true.
public final class Metrics: @unchecked Sendable {
    public static let shared = Metrics()

    /// One dictation's raw material. A struct so the outgoing dictation can be
    /// parked whole, by value, the instant the next one starts.
    private struct Bucket {
        var stamps: [Trace.Stamp: UInt64] = [:]
        var pending = PipelineMetrics()
        /// Set by the history write — the only signal that a dictation is done
        /// with this collector.
        var snapshotted = false
        /// Reached the field. Also the proof that any *earlier* dictation's
        /// polish leg has returned: landing happens inside the leg that the
        /// processTask chain runs one at a time, and the previous leg holds the
        /// chain across its polish await and its `.cleanedSwapped` send.
        var hasLanded: Bool { stamps[.landed] != nil }
        /// Landed, but no history row yet: the cleanup POST that fills in the
        /// tokens may still be out, so this bucket must survive the next fn-down.
        var awaitingHistory: Bool { hasLanded && !snapshotted }
        /// The polish came back — nothing further is owed to this dictation.
        var polishResolved: Bool { stamps[.cleanedSwapped] != nil }

        init() { stamps.reserveCapacity(8) }

        /// First stamp wins, the same rule `Trace.mark` follows.
        mutating func mark(_ stamp: Trace.Stamp, at ns: UInt64) {
            if stamps[stamp] == nil { stamps[stamp] = ns }
        }

        func snapshot() -> PipelineMetrics? {
            func delta(_ from: Trace.Stamp, _ to: Trace.Stamp) -> Int? {
                guard let a = stamps[from], let b = stamps[to], b >= a else { return nil }
                return Int((b - a) / 1_000_000)
            }
            var m = pending
            m.captureMs = delta(.fnDown, .fnUp)
            m.asrMs = delta(.fnUp, .finalPassDone)
            m.insertMs = delta(.finalPassDone, .landed)
            m.cleanupMs = delta(.landed, .cleanedSwapped)
            // Two stamps minimum: a "total" spanning one stamp is 0, which reads
            // as a measurement rather than as the absence of one.
            if stamps.count > 1, let start = stamps[.fnDown], let end = stamps.values.max(),
               end >= start {
                m.totalMs = Int((end - start) / 1_000_000)
            }
            return m.isEmpty ? nil : m
        }
    }

    private let lock = NSLock()
    private var current = Bucket()
    /// The previous dictation, held back by fn-down because its history row
    /// hadn't been written yet. Retired by that write, or dropped at an fn-down
    /// that can prove nothing more is owed to it — see the table in `mark`.
    private var parked: Bucket?

    public init() {}

    /// First stamp wins, and `.fnDown` starts a fresh dictation. The one that
    /// just ended is parked when its cleanup can still be in flight, and the
    /// late `.cleanedSwapped` is routed to it rather than to the new dictation.
    public func mark(_ stamp: Trace.Stamp, at ns: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        if stamp == .fnDown {
            // Eviction table. The park exists for exactly one thing — a cleanup
            // POST that outlives the dictation that issued it — so the only
            // question here is whether the park can still be owed one. Two facts
            // answer it, and nothing else does:
            //   (1) its own `.cleanedSwapped` already came back, or
            //   (2) the dictation ending here reached `.landed`, which the
            //       processTask chain permits only after the park's polish leg
            //       returned (see `hasLanded`).
            //
            //   how the dictation ending here ended | park is           | action
            //   ------------------------------------|-------------------|------------------
            //   landed, its row already written     | owed nothing (2)  | drop the park
            //   landed, row still to come           | owed nothing (2)  | park this one
            //   cancelled (Esc / short tap)         | unknown, no (2)   | keep unless (1)
            //   refused (focus went secure)         | unknown, no (2)   | keep unless (1)
            //   mic failed to start                 | unknown, no (2)   | keep unless (1)
            //   no transcript (silence / too short) | unknown, no (2)   | keep unless (1)
            //
            // The four "unknown" rows are why this is not "replace the park on
            // every fn-down": those dictations never land, so they say nothing
            // about a POST that is still out, and evicting on them throws away
            // the numbers and re-bills the late swap to the wrong dictation.
            //
            // ponytail: "row still to come" also matches a dictation that landed
            // while history was disabled — no row is ever written for it, so it
            // parks as if a polish were out. Nothing reads metrics while history
            // is off; if that ever has to be exact, have the polish leg say a
            // POST is outstanding instead of inferring it from a missing write.
            if current.hasLanded || parked?.polishResolved == true { parked = nil }
            // `awaitingHistory` alone would also park a dictation whose polish
            // already came back — owed nothing by test (1) above. That is the
            // same predicate only while history is on; with it off no row is
            // ever written, so a resolved bucket would park and then be handed
            // to whatever row is written next, permanently one behind.
            if current.awaitingHistory, !current.polishResolved { parked = current }
            current = Bucket()
        }
        // Only the polish result belongs to the parked dictation, and only while
        // that dictation's own polish is still outstanding — the same rule
        // `update` routes by. Every other stamp is the one being recorded now.
        if stamp == .cleanedSwapped, var p = parked, !p.polishResolved {
            p.mark(stamp, at: ns)
            parked = p
        } else {
            current.mark(stamp, at: ns)
        }
    }

    /// The cleanup model and its token counts arrive from inside the POST, which
    /// can outlive the dictation that issued it, so they follow the parked
    /// dictation until its polish comes back.
    public func update(_ mutate: (inout PipelineMetrics) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if var p = parked, !p.polishResolved {
            mutate(&p.pending)
            parked = p
        } else {
            mutate(&current.pending)
        }
    }

    /// Timings folded together with whatever was recorded, or nil when nothing
    /// is known — an all-nil blob on every entry would be noise in the file.
    /// Writing the entry is what retires a parked dictation; the live one is
    /// left intact, so a leg can append history more than once.
    public func snapshot() -> PipelineMetrics? {
        lock.lock()
        defer { lock.unlock() }
        // Only the parked dictation's own write may claim the park, and that write
        // is identifiable: `cleanReady` emits `.trace(.cleanedSwapped)` immediately
        // before `.appendHistory` in one ordered effect list, so a resolved park is
        // the row being written right now. An unresolved park is still waiting on
        // its POST, which means this row belongs to the live dictation — handing it
        // the park would bill it the wrong numbers and, since `current` would never
        // be marked snapshotted, park it again and lock in a permanent off-by-one.
        if let p = parked, p.polishResolved {
            parked = nil
            return p.snapshot()
        }
        current.snapshotted = true
        return current.snapshot()
    }
}
