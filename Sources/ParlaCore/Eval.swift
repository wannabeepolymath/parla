import Foundation
import AVFoundation

public enum Eval {
    public static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Word tokens for WER. ONE function for reference and hypothesis — a WER
    /// harness that normalizes only one side is the most common way these
    /// numbers lie, so the scorer below never lets a caller pass raw text in.
    /// Curly quotes fold FIRST (before case/punctuation) because otherwise a
    /// smart-quoted "don't" and a straight one score as a substitution.
    // ponytail: number words are mapped one token at a time, so "6" == "six"
    // but "21" != "twenty one". Widen the table if compound numbers ever
    // dominate a case; zero-edit rate still scores digits strictly.
    public static func werTokens(_ s: String) -> [String] {
        var t = s
        for (curly, straight) in [("\u{2019}", "'"), ("\u{2018}", "'"),
                                  ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            t = t.replacingOccurrences(of: curly, with: straight)
        }
        return t.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
    }

    /// Normalized form of what the WER scorer actually compared — for reports.
    public static func normalizeForWER(_ s: String) -> String {
        werTokens(s).joined(separator: " ")
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90",
    ]

    public struct WERScore {
        public let edits: Int
        public let referenceWords: Int
        public init(edits: Int, referenceWords: Int) {
            self.edits = edits
            self.referenceWords = referenceWords
        }
        /// Edits per reference word. An empty reference is 0 when the hypothesis
        /// is empty too (the silence case) and 1 otherwise, so a hallucination
        /// on silence can never divide by zero into a free pass.
        public var rate: Double {
            referenceWords > 0 ? Double(edits) / Double(referenceWords)
                               : (edits == 0 ? 0 : 1)
        }
    }

    public static func wer(reference: String, hypothesis: String) -> WERScore {
        let r = werTokens(reference)
        return WERScore(edits: editDistance(r, werTokens(hypothesis)),
                        referenceWords: r.count)
    }

    /// Levenshtein over word tokens, two rows. O(n·m) is fine on dictations.
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Nearest-rank percentile over a small sample. p in 0...1.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))
        return sorted[idx]
    }

    public static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var all: [Float] = []
        let format = file.processingFormat
        // Guard EOF before reading: for some formats (e.g. Int16 WAV) read(into:)
        // at EOF throws (nilError) instead of returning 0 frames.
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            all.append(contentsOf: AudioRecorder.convert(buf))
        }
        return all
    }
}
