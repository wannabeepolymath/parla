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
    }

    // The per-word test this replaced tokenized "(upbeat music)" into
    // ["(upbeat", "music)"] — neither a marker — so the whole hallucination was
    // typed into the user's field.
    func testMultiWordMarkersStripped() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(upbeat music)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[typing sounds]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("*clears throat*"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] (upbeat music)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("  (soft piano music)  "), "")
    }

    func testRealSpeechUntouched() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello world."), "Hello world.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Array [0] is empty"), "Array [0] is empty")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech(""), "")
    }

    // Real words alongside a marker must survive verbatim — including the
    // marker, since we cannot tell a hallucination from spoken punctuation here.
    func testSpeechWithMarkerReturnedUnchanged() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(upbeat music) ship it friday"),
                       "(upbeat music) ship it friday")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("call fn(x) twice"), "call fn(x) twice")
    }
}
