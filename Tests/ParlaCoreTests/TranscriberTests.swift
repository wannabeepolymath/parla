import XCTest
@testable import ParlaCore

final class TranscriberTests: XCTestCase {
    func testTranscribeSilenceProducesNoCrash() throws {
        let path = WhisperTranscriber.defaultModelPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no whisper model — run scripts/download-model.sh")
        let t = try WhisperTranscriber(modelPath: path)
        // 1s of silence: must not crash; output may be empty or hallucinated punctuation.
        let out = t.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: "Kubernetes")
        XCTAssertNotNil(out)
    }

    func testMissingModelThrows() {
        XCTAssertThrowsError(try WhisperTranscriber(modelPath: "/nonexistent.bin"))
    }


    func testBlankAudioMarkerStripped() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(silence)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("*sigh*"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] [BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC]\n[BLANK_AUDIO]"), "")
    }

    func testRealSpeechUntouched() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello world."), "Hello world.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Array [0] is empty"), "Array [0] is empty")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech(""), "")
    }

    func testMarkerStrippedFromMixedContent() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello there. [BLANK_AUDIO]"), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] Hello there."), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello [MUSIC] there."), "Hello there.")
        // Marker on its own line: never seen as a token when splitting on " " alone.
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello there.\n[BLANK_AUDIO]"), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[BLANK_AUDIO]\n\nHello\tthere."), "Hello there.")
    }
}
