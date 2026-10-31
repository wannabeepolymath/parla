import Foundation

/// Native segment estimates, separate from the legacy marker-filtered raw text.
/// This declares the exact source contract, not qualification of the linked binary
/// or acoustic accuracy. No words, speakers, coverage or converted-source map.
public struct RecognitionSegments: Equatable, Sendable {
    public enum Clock: Equatable, Sendable {
        /// whisper.cpp v1.9.1 f049fff95a089aa9969deb009cdd4892b3e74916:
        /// 10 ms ticks from supplied PCM zero, internal window offsets included.
        case whisper191PCM10ms
        case unknown
    }
    public struct Cue: Equatable, Sendable {
        public let text: String
        public let start: Int64
        public let end: Int64
        public init(text: String, start: Int64, end: Int64) {
            self.text = text; self.start = start; self.end = end
        }
    }
    public enum Refusal: Error { case clock, source, bounds, order, limit }
    public static let maximumCount = 10_000
    public static let maximumNativeBytes = 1_048_576
    public let clock: Clock
    public let sourceSampleCount: Int
    public let cues: [Cue]

    public init(clock: Clock, sourceSampleCount: Int, cues: [Cue]) throws {
        guard clock == .whisper191PCM10ms else { throw Refusal.clock }
        guard sourceSampleCount > 0 else { throw Refusal.source }
        guard cues.count <= Self.maximumCount else { throw Refusal.limit }
        var bytes = 0, previous: Int64 = 0
        for cue in cues {
            let size = bytes.addingReportingOverflow(cue.text.utf8.count)
            guard !size.overflow, size.partialValue <= Self.maximumNativeBytes else { throw Refusal.limit }
            bytes = size.partialValue
            guard cue.start >= 0, cue.end > cue.start else { throw Refusal.bounds }
            let start = cue.start.multipliedReportingOverflow(by: 160)
            let end = cue.end.multipliedReportingOverflow(by: 160)
            guard !start.overflow, !end.overflow, start.partialValue <= sourceSampleCount,
                  end.partialValue <= sourceSampleCount else { throw Refusal.bounds }
            guard cue.start >= previous else { throw Refusal.order }
            previous = cue.start
        }
        self.clock = clock; self.sourceSampleCount = sourceSampleCount; self.cues = cues
    }
}
