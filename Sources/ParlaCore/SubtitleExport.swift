import Foundation

/// Literal native-segment WebVTT or SRT only; accepts no cleaned/history text projection.
public enum SubtitleExport {
    public enum Format: Sendable { case webVTT, srt }
    public enum Refusal: Error { case empty, payload, overflow, limit, markup }
    public static let maximumBytes = 8 * 1_048_576

    public static func timestamp(tick: Int64) throws -> String {
        try timestamp(tick: tick, separator: ".")
    }

    private static func timestamp(tick: Int64, separator: String) throws -> String {
        let value = tick.multipliedReportingOverflow(by: 10)
        guard tick >= 0, !value.overflow else { throw Refusal.overflow }
        let ms = value.partialValue
        func pad(_ n: Int64, _ width: Int) -> String {
            let digits = String(n)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(ms / 3_600_000, 2)):\(pad(ms / 60_000 % 60, 2)):\(pad(ms / 1000 % 60, 2))\(separator)\(pad(ms % 1000, 3))"
    }

    public static func encoded(_ segments: RecognitionSegments, format: Format = .webVTT) throws -> Data {
        try encode(segments, format: format, maximumBytes: maximumBytes)
    }

    // A smaller budget seam tests whole-output accounting without oversized native input.
    static func encode(_ segments: RecognitionSegments, format: Format = .webVTT, maximumBytes: Int) throws -> Data {
        guard !segments.cues.isEmpty else { throw Refusal.empty }
        var data = Data()
        func append(_ text: String) throws {
            let size = data.count.addingReportingOverflow(text.utf8.count)
            guard !size.overflow, size.partialValue <= maximumBytes else { throw Refusal.limit }
            data.append(contentsOf: text.utf8)
        }
        var hasMarkup = false
        if format == .webVTT { try append("WEBVTT\n\n") }
        for (index, cue) in segments.cues.enumerated() {
            guard format != .srt || cue.end < 36_000_000 else { throw Refusal.overflow }
            let separator = format == .srt ? "," : "."
            try append("\(index + 1)\n\(try timestamp(tick: cue.start, separator: separator)) --> \(try timestamp(tick: cue.end, separator: separator))\n")
            let text = cue.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.allSatisfy({ !$0.isEmpty && $0.contains(where: { $0 != " " && $0 != "\t" }) }) else { throw Refusal.payload }
            if format == .srt, text.range(of: #"[<>{}\\]|&[A-Za-z0-9#]+;"#, options: .regularExpression) != nil {
                hasMarkup = true
            }
            for scalar in text.unicodeScalars {
                let n = scalar.value
                // Deliberately stricter product policy than WebVTT's bidi/control grammar.
                guard !(n < 0x20 && n != 9 && n != 10), !(0x7F...0x9F).contains(n),
                      n != 0x2028, n != 0x2029, n != 0x061C, n != 0x200E, n != 0x200F,
                      !(0x202A...0x202E).contains(n), !(0x2066...0x2069).contains(n) else { throw Refusal.payload }
                if format == .srt {
                    try append(String(scalar))
                    continue
                }
                switch n {
                case 38: try append("&amp;")
                case 60: try append("&lt;")
                case 62: try append("&gt;")
                default: try append(String(scalar))
                }
            }
            try append("\n\n")
        }
        // Shared payload, format time and whole-byte checks take precedence.
        if hasMarkup { throw Refusal.markup }
        return data
    }
}
