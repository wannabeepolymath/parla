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
        /// Landed, but no history row yet: the cleanup POST that fills in the
        /// tokens may still be out, so this bucket must survive the next fn-down.
        var awaitingHistory: Bool { stamps[.landed] != nil && !snapshotted }
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
    /// hadn't been written yet. Retired by that write.
    private var parked: Bucket?

    public init() {}

    /// First stamp wins, and `.fnDown` starts a fresh dictation. The one that
    /// just ended is parked when its cleanup can still be in flight, and the
    /// late `.cleanedSwapped` is routed to it rather than to the new dictation.
    public func mark(_ stamp: Trace.Stamp, at ns: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        if stamp == .fnDown {
            // A park whose polish already came back is owed nothing more; drop it
            // so it can't outlive its dictation and swallow the next one's write.
            if parked?.polishResolved == true { parked = nil }
            if current.awaitingHistory { parked = current }
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
        if let p = parked {
            parked = nil
            return p.snapshot()
        }
        current.snapshotted = true
        return current.snapshot()
    }
}
