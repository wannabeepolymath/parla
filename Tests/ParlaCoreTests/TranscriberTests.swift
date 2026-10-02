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
        // Both prompt branches run under the language withCString, and only the prompted
        // one is covered above — a nil prompt takes the other path to whisper_full.
        XCTAssertNotNil(t.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: nil))
    }

    /// The decode used to be pinned to English, and a multilingual model told
    /// "this is English" translates: Hindi speech came out as an English
    /// sentence. Now each pass is decoded in the last pass's language and
    /// redone only when the speaker switched — which has to give exactly what
    /// whisper's own detect-then-decode gives, at half its cost when nothing
    /// switched. Local only: it needs the multilingual model and macOS's Hindi
    /// voice, and CI has neither.
    func testMultilingualModelFollowsTheSpeakerLikeWhisperAutoDetect() throws {
        let model = ModelCatalog.path(for: ModelCatalog.all.first { $0.id.hasPrefix("large") }!)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "no multilingual model installed")
        func speak(_ voice: String, _ text: String) throws -> [Float] {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", wav.path, "--data-format=LEI16@16000", "--channels=1", text]
            try say.run()
            say.waitUntilExit()
            try XCTSkipUnless(say.terminationStatus == 0, "no \(voice) system voice")
            return try Eval.loadSamples(url: wav)
        }
        let hindi = try speak("Lekha", "कल सुबह दस बजे मेरी टीम के साथ बैठक है।")
        let english = try speak("Samantha", "Tomorrow at ten I have a meeting with the team.")

        let t = try WhisperTranscriber(modelPath: model)
        // A switch each way: the first guess is English, the second is Hindi.
        let heard = [hindi, english].map { clip -> String? in
            let text = t.transcribe(clip, initialPrompt: nil)
            XCTAssertEqual(text, t.decode(clip, initialPrompt: nil, language: "auto"))
            return text
        }
        let devanagari = heard[0]?.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        XCTAssertEqual(devanagari, true, "got: \(heard[0] ?? "nil")")
    }

    func testMissingModelThrows() {
        XCTAssertThrowsError(try WhisperTranscriber(modelPath: "/nonexistent.bin"))
    }

    func testDefaultModelPathIsTheCatalogDefault() {
        XCTAssertEqual(WhisperTranscriber.defaultModelPath(),
                       ModelCatalog.path(for: ModelCatalog.default))
    }

    // MARK: - Unload policy

    func testIdlePolicyUnloadsOnlyPastItsTimeout() {
        let p = ModelUnloadPolicy.afterIdle(seconds: 300)
        XCTAssertFalse(p.shouldUnloadOnTick(idle: 299, recording: false))
        XCTAssertTrue(p.shouldUnloadOnTick(idle: 300, recording: false))
        XCTAssertTrue(p.shouldUnloadOnTick(idle: 10_000, recording: false))
        XCTAssertEqual(ModelUnloadPolicy.default, p)
    }

    /// The rule the whole policy exists to preserve: a dictation longer than the
    /// timeout must never have its own model freed out from under it.
    func testRecordingNeverUnloads() {
        for policy: ModelUnloadPolicy in [.never, .immediately, .afterIdle(seconds: 300)] {
            XCTAssertFalse(policy.shouldUnloadOnTick(idle: 100_000, recording: true))
        }
    }

    func testNeverAndImmediatelyDoNotUnloadOnTheTick() {
        XCTAssertFalse(ModelUnloadPolicy.never.shouldUnloadOnTick(idle: 100_000, recording: false))
        // .immediately is handled after each transcription instead, so the 10s
        // watcher can't fire it between two passes of one dictation.
        XCTAssertFalse(ModelUnloadPolicy.immediately.shouldUnloadOnTick(idle: 100_000, recording: false))
    }

    func testOnlyImmediatelyUnloadsAfterTranscription() {
        XCTAssertTrue(ModelUnloadPolicy.immediately.unloadsAfterTranscription)
        XCTAssertFalse(ModelUnloadPolicy.never.unloadsAfterTranscription)
        XCTAssertFalse(ModelUnloadPolicy.afterIdle(seconds: 0).unloadsAfterTranscription)
    }


    func testBlankAudioMarkerStripped() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(silence)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("*sigh*"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] [BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC]\n[BLANK_AUDIO]"), "")
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

    func testMarkerStrippedFromMixedContent() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello there. [BLANK_AUDIO]"), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] Hello there."), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello [MUSIC] there."), "Hello there.")
        // Marker on its own line: never seen as a token when splitting on " " alone.
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello there.\n[BLANK_AUDIO]"), "Hello there.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[BLANK_AUDIO]\n\nHello\tthere."), "Hello there.")
    }

    // A transcript that is nothing but markers becomes "" even when the markers
    // are multi-word: per-token matching saw "(upbeat music)" as two non-marker
    // tokens and typed the hallucination into the user's field.
    func testMultiWordMarkersAloneBecomeEmpty() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(upbeat music)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[typing sounds] (upbeat music)"), "")
    }

    // Real words alongside a multi-word marker survive verbatim — including the
    // marker, since we cannot tell a hallucination from spoken punctuation here.
    func testSpeechWithMultiWordMarkerReturnedUnchanged() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(upbeat music) ship it friday"),
                       "(upbeat music) ship it friday")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("call fn(x) twice"), "call fn(x) twice")
    }
}
