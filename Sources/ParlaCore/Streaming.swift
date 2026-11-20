import Foundation

/// Windowed re-transcription state for long dictations — the fix for O(n²)
/// full-buffer streaming passes. `confirmedText` is the frozen transcript of
/// samples[0..<cutSample]; later passes re-transcribe only samples[cutSample...]
/// with the confirmed tail as whisper context.
///
/// Ownership: written by the app's stream() loop while recording, then consumed
/// (and cleared) by the finish() queued right after it on the processTask chain
/// — the chain is the synchronization; nothing else may touch it.
public struct StreamWindow {
    public struct Ownership: Equatable, Sendable {
        public let instance: UUID
        public let identity: RecognitionIdentity?
        public let capture: UUID
        public let request: RecognitionRequest
    }
    public let ownership: Ownership?
    public var confirmedText: String
    public var cutSample: Int
    public init(confirmedText: String, cutSample: Int, ownership: Ownership? = nil) {
        self.ownership = ownership
        self.confirmedText = confirmedText
        self.cutSample = cutSample
    }

    /// Un-confirmed audio beyond this many samples triggers a cut (~15s @16kHz).
    public static let threshold = 15 * 16_000
    /// Target cut point inside an over-threshold tail (~10s in, keeping ~5s live).
    public static let cutTarget = threshold - 5 * 16_000

    /// Sample index of the middle of the locally quietest ~100ms window within
    /// ±`radius` of `target` — cheapest proxy for a speech pause, so the cut
    /// doesn't split a word. Falls back to `target` clamped when there's no
    /// room to search.
    // ponytail: plain RMS scan, no VAD — good enough to find a breath; swap in
    // real VAD if cuts audibly split words.
    public static func quietestCut(samples: [Float], near target: Int,
                                   radius: Int = 2 * 16_000, window: Int = 1_600) -> Int {
        let lo = Swift.max(0, target - radius)
        let hi = Swift.min(samples.count, target + radius)
        guard hi - lo >= window else { return Swift.min(Swift.max(0, target), samples.count) }
        var best = lo
        var bestRms = Float.greatestFiniteMagnitude
        var i = lo
        while i + window <= hi {
            let r = AudioRecorder.rms(Array(samples[i ..< i + window]))
            if r < bestRms { bestRms = r; best = i }
            i += window / 2
        }
        return best + window / 2
    }

    public static let confirmedContextBytes = 800

    /// Tokens kept for confirmed context when a budget is known. Starting value,
    /// roughly today's 200-character English context; revisit with lane 12 evidence.
    public static let contextReserveTokens = 64

    /// initial_prompt for a tail pass: dictionary terms plus the tail of the
    /// confirmed transcript (whisper reads initial_prompt as prior context).
    /// With a budget, the tail keeps at most `reserve` tokens and the dictionary
    /// gets the rest. `reserve` is a test seam; production uses the default.
    public static func tailPrompt(dictionary: [String], confirmed: String,
                                  maxContext: Int = 200, budget: PromptBudget? = nil,
                                  reserve: Int = contextReserveTokens) -> String? {
        var tail = ""
        var bytes = 0
        for character in confirmed.suffix(max(0, maxContext)).reversed() {
            let size = String(character).utf8.count
            guard bytes + size <= confirmedContextBytes else { break }
            tail.insert(character, at: tail.startIndex)
            bytes += size
        }
        var terms = VocabularyHints.select(dictionary, budget: nil)
        if let budget {
            let reserve = min(reserve, budget.capacity)
            while !tail.isEmpty, budget.count(tail) > reserve { tail.removeFirst(max(1, tail.count / 8)) }
            let room = max(0, budget.capacity - budget.count(tail) - (tail.isEmpty ? 0 : 1))
            terms = VocabularyHints.select(dictionary, budget: PromptBudget(capacity: room, count: budget.count))
        }
        func joined() -> String? {
            let parts = [terms.isEmpty ? nil : terms.joined(separator: ", "), tail.isEmpty ? nil : tail].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let budget {
            while !terms.isEmpty, let prompt = joined(), budget.count(prompt) > budget.capacity { terms.removeLast() }
        }
        return joined()
    }

    /// confirmed + " " + tail, tolerating either side being empty.
    public static func join(_ confirmed: String, _ tail: String) -> String {
        [confirmed, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
