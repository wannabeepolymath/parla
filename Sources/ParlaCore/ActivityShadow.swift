import Foundation

/// Revocable scalar authority only. Normal STOP does not revoke this permission.
public final class ActivityShadowPermission: Equatable, @unchecked Sendable {
    public let generation: Int
    public let operationID: UUID
    public let revision = ActivityShadow.revision
    private let lock = NSLock()
    private var valid = true
    public init(generation: Int, operationID: UUID) { self.generation = generation; self.operationID = operationID }
    public var isCurrent: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
    public static func == (lhs: ActivityShadowPermission, rhs: ActivityShadowPermission) -> Bool { lhs === rhs }
}

/// Finite, content-free facts. Never an audio selection or speech label.
public struct DiagnosticActivityShadow: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case complete, noDecision, notRun }
    public enum Reason: String, Codable, Sendable {
        case activity, digitalZero, empty, overLimit, captureIncomplete, acquisitionUnavailable
        case nonfiniteInput, clipped, outOfScale, dcDominated, numerical, lowContrast, runLimit, shortRetained
        case canceled, deadline, invalidClock, invalidResult
    }
    public struct Envelope: Codable, Equatable, Sendable {
        public var start: Int
        public var end: Int
        public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
        func valid(_ n: Int) -> Bool { start >= 0 && end > start && end <= n }
    }
    public struct Actual: Codable, Equatable, Sendable {
        public enum Selection: String, Codable, Sendable { case fullPass, ownedWindowAssembly, fullFloorSkip, canceled, unavailable }
        public enum Native: String, Codable, Sendable { case completed, failed, canceled, notRun }
        public enum Text: String, Codable, Sendable { case present, absent, unknown }
        public var selection: Selection = .unavailable
        public var native: Native = .notRun
        public var text: Text = .unknown
        public var skip: RecognitionSkip?
        public var prefixSamples = 0
        public var selectedRange: Envelope?
        public var separatePreview = false
        public init(separatePreview: Bool = false) { self.separatePreview = separatePreview }
    }
    public var revision = ActivityShadow.revision
    public var state: State
    public var reason: Reason
    public var originalSamples: Int
    public var frames = 0
    public var runs = 0
    public var sampleVisits = 0
    public var classifiedFrames = 0
    public var histogramVisits = 0
    public var roundingClamped = false
    public var activity: Envelope?
    public var retained: Envelope?
    public var removedLeading = 0
    public var removedTrailing = 0
    public var wouldRejectProxy = false
    public var suggestionApplied = false
    public var actual = Actual()
    public init(state: State = .noDecision, reason: Reason, originalSamples: Int) {
        self.state = state; self.reason = reason; self.originalSamples = originalSamples
    }

    /// Validate injected producers before allowing any range to reach Diagnostics.
    public func validated(originalCount n: Int) -> Self {
        func invalid() -> Self { Self(reason: .invalidResult, originalSamples: max(0, n)) }
        guard revision == ActivityShadow.revision, originalSamples == n, n >= 0,
              !suggestionApplied, (0...ActivityShadow.maximumFrames).contains(frames),
              (0...128).contains(runs), (0...min(n, ActivityShadow.maximumSamples)).contains(sampleVisits),
              (0...frames).contains(classifiedFrames), (0...128).contains(histogramVisits),
              activity.map({ $0.valid(n) }) ?? true, retained.map({ $0.valid(n) }) ?? true,
              removedLeading >= 0, removedTrailing >= 0 else { return invalid() }
        if state == .complete {
            guard n > 0, n <= ActivityShadow.maximumSamples, frames == (n + 319) / 320,
                  sampleVisits == n, classifiedFrames == frames else { return invalid() }
            if reason == .digitalZero {
                guard wouldRejectProxy, activity == nil, retained == nil, runs == 0,
                      removedLeading == 0, removedTrailing == 0 else { return invalid() }
            } else {
                guard reason == .activity, !wouldRejectProxy, runs > 0, let a = activity, let r = retained,
                      r.start <= a.start, r.end >= a.end, r.end - r.start >= 6400,
                      removedLeading == r.start, removedTrailing == n - r.end,
                      removedLeading == 0 || removedLeading >= 8000,
                      removedTrailing == 0 || removedTrailing >= 8000 else { return invalid() }
                var paddedStart = max(0, a.start - 4000), paddedEnd = min(n, a.end + 4000)
                if paddedStart < 8000 { paddedStart = 0 }
                if n - paddedEnd < 8000 { paddedEnd = n }
                guard a.start.isMultiple(of: 320), a.end == n || a.end.isMultiple(of: 320),
                      r == Envelope(paddedStart, paddedEnd) else { return invalid() }
            }
        } else if activity != nil || retained != nil || wouldRejectProxy || removedLeading != 0 || removedTrailing != 0 {
            return invalid()
        }
        if state == .notRun && reason != .acquisitionUnavailable { return invalid() }
        if state == .noDecision && (reason == .activity || reason == .digitalZero || reason == .acquisitionUnavailable) { return invalid() }
        let a = actual
        guard a.prefixSamples >= 0, a.prefixSamples <= n, a.selectedRange.map({ $0.valid(n) }) ?? true else { return invalid() }
        switch a.selection {
        case .fullPass:
            guard a.prefixSamples == 0, a.skip == nil, a.selectedRange == Envelope(0, n), a.native != .notRun, a.text != .unknown else { return invalid() }
        case .ownedWindowAssembly:
            // Empty tails are represented by nil, with prefix == original count.
            guard a.selectedRange == (a.prefixSamples == n ? nil : Envelope(a.prefixSamples, n)),
                  (a.skip != nil) == (a.native == .notRun), a.text != .unknown else { return invalid() }
        case .fullFloorSkip:
            guard a.prefixSamples == 0, a.skip != nil, a.native == .notRun, a.text == .absent,
                  a.selectedRange == (n == 0 ? nil : Envelope(0, n)) else { return invalid() }
        case .canceled, .unavailable:
            guard a.prefixSamples == 0, a.selectedRange == nil, a.skip == nil else { return invalid() }
        }
        guard let data = try? JSONEncoder().encode(self), data.count <= 2048 else { return invalid() }
        return self
    }

    /// Immediate projection of the actual selected pass. No result/text/identity escapes.
    public static func project(_ result: RecognitionFinalResult, handle: RecognitionHandle,
                               originalCount n: Int, separatePreview: Bool) -> Actual? {
        var a = Actual(separatePreview: separatePreview)
        a.text = result.text.map { $0.isEmpty ? .absent : .present } ?? .absent
        func native(_ pass: RecognitionPassResult) -> Actual.Native {
            switch pass.native { case .completed: return .completed; case .failed: return .failed; case .canceled: return .canceled }
        }
        func matches(_ pass: RecognitionPassResult, _ kind: RecognitionPassKind, _ range: Range<Int>) -> Bool {
            pass.pass == kind && pass.sampleRange == range && pass.instance == handle.instance && pass.identity == handle.identity
        }
        switch result.provenance {
        case .pass(let pass):
            guard n > 0, matches(pass, .fullFinal, 0..<n) else { return nil }
            a.selection = .fullPass; a.native = native(pass); a.selectedRange = Envelope(0, n)
        case let .assembled(ownership, prefix, tail, skipped):
            guard handle.client.capabilities.shadowWindows, prefix.lowerBound == 0, prefix.upperBound <= n,
                  prefix.upperBound >= 0, handle.owns(StreamWindow(confirmedText: "", cutSample: prefix.upperBound, ownership: ownership)),
                  (tail == nil) == (skipped != nil) else { return nil }
            if let tail { guard matches(tail, .windowedFinal, prefix.upperBound..<n) else { return nil }; a.native = native(tail) }
            a.selection = .ownedWindowAssembly; a.prefixSamples = prefix.upperBound; a.skip = skipped
            a.selectedRange = prefix.upperBound == n ? nil : Envelope(prefix.upperBound, n)
        case .skipped(let skip):
            a.selection = .fullFloorSkip; a.skip = skip; a.selectedRange = n == 0 ? nil : Envelope(0, n)
        case .canceled: a.selection = .canceled; a.native = .canceled
        }
        return a
    }
}

public enum ActivityShadow {
    public static let revision = 1
    public static let maximumSamples = 9_600_000
    public static let maximumFrames = 30_000
    public static let declaredArrayPayloadBytes = 241_024 // 30,000 Double + 128 Int on 64-bit; not process RAM.
    public typealias Analyzer = (UnsafeBufferPointer<Float>, () -> Bool) -> DiagnosticActivityShadow

    /// Fixed bin width 48/128 octaves. Exact boundaries belong to the upper bin;
    /// reference is its upper edge. Percentile rank = ceil(frameCount/5), 1-based.
    static func bin(_ power: Double) -> Int {
        if power <= 0 { return 0 }
        return min(127, max(0, Int(floor((log2(power) + 48) * 128 / 48))))
    }
    static func upperEdge(_ bin: Int) -> Double { max(pow(2, -48), pow(2, -48 + Double(bin + 1) * 48 / 128)) }

    /// One read-only PCM pass, one summary classification pass, no frame/audio copies.
    /// Cooperative 50 ms elapsed budget: neither preemption nor a completion guarantee.
    public static func analyze(_ samples: UnsafeBufferPointer<Float>, shouldAbort: () -> Bool,
                               clock: () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) -> DiagnosticActivityShadow {
        let n = samples.count
        var f = DiagnosticActivityShadow(reason: .empty, originalSamples: n)
        guard n > 0 else { return f }
        guard n <= maximumSamples else { f.reason = .overLimit; return f } // Read no clipped prefix.
        let start = clock(); var previous = start
        func poll() -> DiagnosticActivityShadow.Reason? {
            if shouldAbort() { return .canceled }
            let time = clock()
            guard start.isFinite, time.isFinite, time >= previous else { return .invalidClock }
            previous = time
            return time - start >= 0.050 ? .deadline : nil
        }
        if let reason = poll() { f.reason = reason; return f }
        let count = (n + 319) / 320
        var powers = [Double](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 128)
        var allZero = true
        for frame in 0..<count {
            if let reason = poll() { f.reason = reason; return f }
            let begin = frame * 320, end = min(n, begin + 320)
            var sum = 0.0, squares = 0.0, frameZero = true
            for i in begin..<end {
                let x = Double(samples[i]); f.sampleVisits += 1
                guard x.isFinite else { f.reason = .nonfiniteInput; return f }
                guard abs(x) <= 1 else { f.reason = .outOfScale; return f }
                guard abs(x) < 1 else { f.reason = .clipped; return f }
                if x != 0 { frameZero = false; allZero = false }
                sum += x; squares += x * x
            }
            let denominator = Double(end - begin), mean = sum / denominator, meanSquare = mean * mean
            let uncentered = squares / denominator
            var power = uncentered - meanSquare
            guard sum.isFinite, squares.isFinite, power.isFinite else { f.reason = .numerical; return f }
            if power < 0 {
                guard power >= -Double.ulpOfOne * max(uncentered, meanSquare) * 8 else { f.reason = .numerical; return f }
                power = 0; f.roundingClamped = true
            }
            if !frameZero {
                guard uncentered >= pow(2, -48) else { f.reason = .numerical; return f }
                guard meanSquare < power else { f.reason = .dcDominated; return f }
                guard power >= pow(2, -48) else { f.reason = .numerical; return f }
            }
            powers[frame] = power; histogram[bin(power)] += 1; f.frames += 1
        }
        if let reason = poll() { f.reason = reason; return f }
        var accumulated = 0, reference = upperEdge(0)
        let rank = (count + 4) / 5
        for b in 0..<128 {
            if let reason = poll() { f.reason = reason; return f }
            f.histogramVisits += 1; accumulated += histogram[b]
            if accumulated >= rank { reference = upperEdge(b); break }
        }
        let high = reference * 4, low = reference * 2
        var first: Int?, last = 0, highAnchor = false, active = false
        for frame in 0..<count {
            if let reason = poll() { f.reason = reason; return f }
            f.classifiedFrames += 1
            let p = powers[frame]
            // Equality is possible activity. Band-only energy extends either edge.
            if p >= high {
                highAnchor = true
                if !active { f.runs += 1 }
                active = true
            } else if p < low { active = false }
            if p >= low {
                if first == nil { first = frame * 320 }
                last = min(n, (frame + 1) * 320)
            }
            guard f.runs <= 128 else { f.runs = 128; f.reason = .runLimit; return f }
        }
        if let reason = poll() { f.reason = reason; return f }
        if allZero { f.state = .complete; f.reason = .digitalZero; f.wouldRejectProxy = true; return f }
        guard highAnchor, let first else { f.reason = .lowContrast; return f }
        guard n >= 6400 else { f.reason = .shortRetained; return f }
        var begin = max(0, first - 4000), end = min(n, last + 4000)
        if begin < 8000 { begin = 0 }
        if n - end < 8000 { end = n }
        guard end - begin >= 6400 else { f.reason = .shortRetained; return f }
        f.state = .complete; f.reason = .activity
        f.activity = .init(first, last); f.retained = .init(begin, end)
        f.removedLeading = begin; f.removedTrailing = n - end
        return f
    }
}
