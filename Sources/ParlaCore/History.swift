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
/// ponytail: no per-dictation identity. The processTask chain serializes the
/// legs, so only one dictation is ever between fn-down and its history write;
/// add a generation if that ever stops being true.
public final class Metrics: @unchecked Sendable {
    public static let shared = Metrics()

    private let lock = NSLock()
    private var stamps: [Trace.Stamp: UInt64] = [:]
    private var pending = PipelineMetrics()

    public init() { stamps.reserveCapacity(8) }

    /// First stamp wins, and `.fnDown` starts a fresh dictation — the same rule
    /// `Trace.mark` follows, because these are the same stamps.
    public func mark(_ stamp: Trace.Stamp, at ns: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        if stamp == .fnDown {
            stamps.removeAll(keepingCapacity: true)
            pending = PipelineMetrics()
        }
        if stamps[stamp] == nil { stamps[stamp] = ns }
    }

    public func update(_ mutate: (inout PipelineMetrics) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&pending)
    }

    /// Timings folded together with whatever was recorded, or nil when nothing
    /// is known — an all-nil blob on every entry would be noise in the file.
    /// Non-destructive: a leg can append history more than once.
    public func snapshot() -> PipelineMetrics? {
        lock.lock()
        defer { lock.unlock() }
        func delta(_ from: Trace.Stamp, _ to: Trace.Stamp) -> Int? {
            guard let a = stamps[from], let b = stamps[to], b >= a else { return nil }
            return Int((b - a) / 1_000_000)
        }
        var m = pending
        m.captureMs = delta(.fnDown, .fnUp)
        m.asrMs = delta(.fnUp, .finalPassDone)
        m.insertMs = delta(.finalPassDone, .landed)
        m.cleanupMs = delta(.landed, .cleanedSwapped)
        // Two stamps minimum: a "total" spanning one stamp is 0, which reads as
        // a measurement rather than as the absence of one.
        if stamps.count > 1, let start = stamps[.fnDown], let end = stamps.values.max(), end >= start {
            m.totalMs = Int((end - start) / 1_000_000)
        }
        return m.isEmpty ? nil : m
    }
}
