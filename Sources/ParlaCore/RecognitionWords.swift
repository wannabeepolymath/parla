import Foundation

/// Experimental per-word times for timed file recognition: whisper's heuristic token timestamps,
/// in 10 ms ticks from supplied PCM zero. Estimates with no accuracy claim. Words belong to the
/// raw recognized text, never to cleaned text. No product path requests them yet.
public struct RecognitionWords: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let start: Int64
        public let end: Int64
        public let segment: Int
        public init(text: String, start: Int64, end: Int64, segment: Int) {
            self.text = text; self.start = start; self.end = end; self.segment = segment
        }
    }
    /// One native token: raw UTF-8 bytes (a character may span tokens) and its times.
    public struct Token: Equatable, Sendable {
        public let id: Int32
        public let bytes: [UInt8]
        public let start: Int64
        public let end: Int64
        public let segment: Int
        public init(id: Int32, bytes: [UInt8], start: Int64, end: Int64, segment: Int) {
            self.id = id; self.bytes = bytes; self.start = start; self.end = end; self.segment = segment
        }
    }
    public enum Refusal: Error { case source, bounds, order, limit }
    public static let maximumCount = 100_000
    public let sourceSampleCount: Int
    public let words: [Word]

    public init(sourceSampleCount: Int, words: [Word]) throws {
        guard sourceSampleCount > 0 else { throw Refusal.source }
        guard words.count <= Self.maximumCount else { throw Refusal.limit }
        var bytes = 0, previous: Int64 = 0
        for word in words {
            let size = bytes.addingReportingOverflow(word.text.utf8.count)
            guard !size.overflow, size.partialValue <= RecognitionSegments.maximumNativeBytes else { throw Refusal.limit }
            bytes = size.partialValue
            guard word.start >= 0, word.end >= word.start, word.segment >= 0 else { throw Refusal.bounds }
            let end = word.end.multipliedReportingOverflow(by: 160)
            guard !end.overflow, end.partialValue <= sourceSampleCount else { throw Refusal.bounds }
            guard word.start >= previous else { throw Refusal.order }
            previous = word.start
        }
        self.sourceSampleCount = sourceSampleCount; self.words = words
    }

    /// Pure token → word assembly. Special and timestamp tokens (`id >= eot`) are dropped. A token
    /// starting with a space, or a new segment, starts a word; other tokens extend it; a
    /// punctuation-only token attaches to the previous word of the same segment. Bytes are decoded once per word;
    /// a word that is not valid UTF-8 is dropped.
    public static func assemble(tokens: [Token], eot: Int32) -> [Word] {
        var words: [Word] = []
        var bytes: [UInt8] = [], start: Int64 = 0, end: Int64 = 0, segment = -1
        func flush() {
            defer { bytes = [] }
            guard segment >= 0, let text = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty else { return }
            words.append(Word(text: text, start: start, end: max(start, end), segment: segment))
        }
        for token in tokens where token.id < eot && !token.bytes.isEmpty {
            let trimmed = String(bytes: token.bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
            let punctuation = trimmed.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) } ?? false
            let startsWord = segment < 0 || token.segment != segment || (!punctuation && token.bytes[0] == 0x20)
            if startsWord {
                flush()
                start = token.start; segment = token.segment
            }
            bytes += punctuation && !startsWord ? Array((trimmed ?? "").utf8) : token.bytes
            end = token.end
        }
        flush()
        return words
    }
}
