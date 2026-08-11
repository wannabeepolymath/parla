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
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var raw: String
    public var cleaned: String?
    public var appName: String?
    public var metrics: PipelineMetrics?
    public init(date: Date = Date(), raw: String, cleaned: String? = nil, appName: String? = nil,
                metrics: PipelineMetrics? = nil) {
        self.date = date; self.raw = raw; self.cleaned = cleaned; self.appName = appName
        self.metrics = metrics
    }
    /// What to paste/show: the polished text when we have it, else the raw.
    public var best: String { cleaned ?? raw }
}

/// Local-only dictation log at ~/Library/Application Support/Parla/history.json.
/// Newest-first ring buffer, oldest dropped past the cap. Same save style as
/// SettingsStore. ponytail: no index, no async — a 50-entry array is nothing.
public final class HistoryStore {
    public static let cap = 50 // ponytail: bump if users want a deeper log
    public let url: URL
    private var items: [HistoryEntry] // oldest first internally

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/history.json")
        items = (try? Data(contentsOf: self.url))
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first.
    public var entries: [HistoryEntry] { items.reversed() }

    public func append(_ entry: HistoryEntry) {
        items.append(entry)
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        save()
    }

    public func clear() {
        items = []
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(items).write(to: url, options: .atomic)
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
