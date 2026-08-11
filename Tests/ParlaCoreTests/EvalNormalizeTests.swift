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

    // The regression this fold exists for: whisper heard syn-numbers perfectly,
    // wrote it in numerals, and the harness called it a 57.1% FAILURE. An eval
    // that cries wolf on correct output is worse than no eval.
    func testWERNormalizerFoldsNumeralTranscriptionOfSpokenNumbers() {
        let spoken = "Transfer four hundred and twenty dollars on the fifteenth of March at nine thirty."
        let numerals = "Transfer $420 on the 15th of March at 9.30"
        XCTAssertEqual(Eval.wer(reference: spoken, hypothesis: numerals).rate, 0)
        XCTAssertEqual(Eval.wer(reference: numerals, hypothesis: spoken).rate, 0)
    }

    // The hypothesis exactly as the ASR run produced it. whisper really did drop
    // "the" and "of", so this stays an honest near-miss — but it must be nowhere
    // near the harness's 20% fail threshold.
    func testWERReportedNumbersCaseNoLongerFails() {
        let w = Eval.wer(
            reference: "Transfer four hundred and twenty dollars on the fifteenth of March at nine thirty.",
            hypothesis: "Transfer $420 on 15 March at 9.30")
        XCTAssertEqual(w.edits, 2, "only the dropped \"the\" and \"of\" should be left")
        XCTAssertLessThan(w.rate, 0.20)
    }

    func testWERNormalizerFoldsNumeralForms() {
        for (spoken, numerals) in [("four hundred and twenty", "420"),
                                   ("four hundred twenty", "420"),
                                   ("twenty one", "21"),
                                   ("twenty-one", "21"),
                                   ("nineteen hundred", "1900"),
                                   ("one thousand and one", "1001"),
                                   ("one thousand two hundred and fifty", "1,250"),
                                   ("two million five hundred thousand", "2,500,000"),
                                   ("ninety nine thousand", "99000"),
                                   ("the fifteenth of March", "the 15th of March"),
                                   ("the twenty first", "the 21st"),
                                   ("the second option", "the 2nd option"),
                                   ("one dollar", "$1"),
                                   ("four hundred and twenty dollars", "$420"),
                                   ("nine thirty", "9:30"),
                                   ("nine thirty", "9.30")] {
            XCTAssertEqual(Eval.normalizeForWER(spoken), Eval.normalizeForWER(numerals),
                           "\(spoken) vs \(numerals)")
        }
    }

    // The half that matters more: the fold must never make a WRONG hearing score
    // as right. Every pair here is two different dictations and must stay two.
    func testWERNormalizerNeverInventsANumber() {
        for (a, b) in [("four hundred", "four thousand"),      // 400 is not 4000
                       ("four hundred", "420"),
                       ("one hundred", "one hundred and one"),
                       ("twenty one", "twenty"),
                       ("four and twenty", "24"),              // "and" binds only after a scale
                       ("twenty twenty", "forty"),             // must not sum to 40
                       ("nineteen eighty four", "1984"),       // no year guessing
                       ("nine thirty", "930"),                 // a time is not one number
                       ("one two three", "123"),
                       ("fifteen", "fifty"),
                       ("$420", "420 euros"),                  // currency survives the fold
                       ("north", "9")] {                       // "th" strip needs digits
            XCTAssertNotEqual(Eval.normalizeForWER(a), Eval.normalizeForWER(b), "\(a) vs \(b)")
        }
    }

    // Folding twice must equal folding once. This caught a real bug: a number
    // run that hit a bad scale used to abandon the WHOLE run, so "nine thousand
    // nine billion" dropped its good prefix back to the word "nine". Exhaustive
    // over a small vocabulary rather than random, so it cannot flake — 33 of
    // these 2401 combinations failed before the fix.
    func testWERNormalizerFoldIsStable() {
        let vocab = ["nine", "twenty", "hundred", "thousand", "billion", "fifteenth", "and"]
        for a in vocab {
            for b in vocab {
                for c in vocab {
                    for d in vocab {
                        let once = Eval.normalizeForWER("\(a) \(b) \(c) \(d)")
                        XCTAssertEqual(Eval.normalizeForWER(once), once, "\(a) \(b) \(c) \(d)")
                    }
                }
            }
        }
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
