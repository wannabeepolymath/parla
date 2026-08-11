import XCTest
import AVFoundation
@testable import ParlaCore

final class EvalNormalizeTests: XCTestCase {
    // Repro for the Int16-WAV read path: AVAudioFile.read(into:) throws at EOF
    // for this format instead of returning 0 frames; loadSamples must guard.
    func testLoadSamplesInt16Wav() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-load-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        // Write inside a scope so the AVAudioFile writer deallocs (flushes/closes)
        // before we read the file back.
        try {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let frames: AVAudioFrameCount = 3200 // 0.2s @ 16kHz
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) {
                buf.floatChannelData![0][i] = sinf(2 * .pi * 440 * Float(i) / 16_000) * 0.5
            }
            try file.write(from: buf)
        }()

        let samples = try Eval.loadSamples(url: url)
        XCTAssert(abs(samples.count - 3200) <= 100, "got \(samples.count) samples")
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(Eval.normalize("  Hello,\n  world.  "), "Hello, world.")
    }
    func testCaseAndPunctuationPreserved() {
        XCTAssertEqual(Eval.normalize("Let's meet at 6."), "Let's meet at 6.")
        XCTAssertNotEqual(Eval.normalize("let's meet at 6"), "Let's meet at 6.")
    }

    // MARK: - WER normalizer

    func testWERNormalizerFoldsCasePunctuationAndWhitespace() {
        XCTAssertEqual(Eval.normalizeForWER("  Let's MEET,  at the office!\n"),
                       "let's meet at the office")
    }

    // Curly apostrophes must fold before anything else, or every smart-quoted
    // contraction scores as a substitution against a straight-quoted golden.
    func testWERNormalizerFoldsCurlyApostrophes() {
        XCTAssertEqual(Eval.werTokens("don\u{2019}t"), Eval.werTokens("don't"))
        XCTAssertEqual(Eval.wer(reference: "don\u{2019}t stop", hypothesis: "don't stop").edits, 0)
    }

    func testWERNormalizerMapsNumberWords() {
        XCTAssertEqual(Eval.werTokens("Meet at six."), ["meet", "at", "6"])
        XCTAssertEqual(Eval.wer(reference: "at 6", hypothesis: "at six").rate, 0)
    }

    func testWERNormalizerIsAppliedToBothSides() {
        // The classic lie: one side normalized, the other not. Same function,
        // same result, whichever way round the arguments go.
        let a = "The Timeout Is Ten Seconds!"
        let b = "the timeout is 10 seconds"
        XCTAssertEqual(Eval.wer(reference: a, hypothesis: b).rate, 0)
        XCTAssertEqual(Eval.wer(reference: b, hypothesis: a).rate, 0)
    }

    // MARK: - WER

    func testWERCountsSubstitutionInsertionDeletion() {
        // substitution
        XCTAssertEqual(Eval.wer(reference: "ship it on friday",
                                hypothesis: "ship it on monday").edits, 1)
        // deletion
        XCTAssertEqual(Eval.wer(reference: "ship it on friday",
                                hypothesis: "ship it friday").edits, 1)
        // insertion
        XCTAssertEqual(Eval.wer(reference: "ship it on friday",
                                hypothesis: "ship it on next friday").edits, 1)
    }

    func testWERRate() {
        let w = Eval.wer(reference: "one two three four", hypothesis: "one two three")
        XCTAssertEqual(w.referenceWords, 4)
        XCTAssertEqual(w.rate, 0.25, accuracy: 1e-9)
    }

    // A hallucination on silence must not divide by zero into a free pass.
    func testWEREmptyReference() {
        XCTAssertEqual(Eval.wer(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(Eval.wer(reference: "", hypothesis: "thank you").rate, 1)
        XCTAssertEqual(Eval.wer(reference: "thank you", hypothesis: "").rate, 1)
    }

    func testEditDistanceIsSymmetric() {
        let a = ["a", "b", "c", "d"], b = ["a", "x", "c"]
        XCTAssertEqual(Eval.editDistance(a, b), Eval.editDistance(b, a))
        XCTAssertEqual(Eval.editDistance(a, b), 2)
    }

    // MARK: - Percentiles

    func testPercentileNearestRank() {
        let v = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
        XCTAssertEqual(Eval.percentile(v, 0.5), 0.4, accuracy: 1e-9)
        XCTAssertEqual(Eval.percentile(v, 0.9), 0.8, accuracy: 1e-9)
        XCTAssertEqual(Eval.percentile(v, 1.0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(Eval.percentile([], 0.9), 0)
        XCTAssertEqual(Eval.percentile([2.0], 0.5), 2.0)
    }

    // The reason p90 is reported next to the corpus number: two broken cases in
    // ten leave the mean looking fine and light up the tail.
    func testPercentileExposesTailAMeanHides() {
        let rates = Array(repeating: 0.0, count: 8) + [0.9, 1.0]
        let mean = rates.reduce(0, +) / Double(rates.count)
        XCTAssertEqual(mean, 0.19, accuracy: 1e-9)
        XCTAssertEqual(Eval.percentile(rates, 0.9), 0.9, accuracy: 1e-9)
    }
}
