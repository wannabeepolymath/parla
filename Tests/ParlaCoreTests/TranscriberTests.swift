import XCTest
@testable import ParlaCore
import whisper

final class TranscriberTests: XCTestCase {
    /// 51865 vocabularies have 99 languages (id 99 would be the translate token), 51866 has 100.
    func testLanguageCountComesFromTheModelsTokenLayout() throws {
        XCTAssertEqual(WhisperCContext.languageCount(sot: 50258, translate: 50358), 99)
        XCTAssertEqual(WhisperCContext.languageCount(sot: 50258, translate: 50359), 100)
        XCTAssertEqual(WhisperCContext.languageCount(sot: 50258, translate: 50258), 0)
    }
    /// Fake C API: records the params each whisper_full saw, answers with `segments` and fixed evidence.
    private final class ExperimentAPI {
        var params: [whisper_full_params] = [], vadPaths: [String?] = []
        let texts: [UnsafeMutablePointer<CChar>]
        init(segments: [String]) { texts = segments.map { strdup($0)! } }
        deinit { texts.forEach { free($0) } }
        func context(multilingual: Bool = false, detected: String? = nil) -> WhisperCContext {
            var api = WhisperCContext.API()
            api.multilingual = multilingual
            api.knowsLanguage = { ["en", "hi"].contains($0) }
            api.spokenLanguage = { detected }
            api.full = { params, _, _ in
                self.params.append(params); self.vadPaths.append(params.vad_model_path.map { String(cString: $0) }); return 0
            }
            api.count = { Int32(self.texts.count) }
            api.text = { UnsafePointer(self.texts[Int($0)]) }
            api.noSpeechProbability = { Float($0) / 10 }
            api.tokenCount = { $0 + 1 }
            api.tokenProbability = { _, token in token == 0 ? 0.5 : 1 }
            return WhisperCContext(api: api)
        }
    }
    func testExperimentSwitchesReachTheNativeParamsAndDefaultsStayShipping() {
        let fake = ExperimentAPI(segments: ["x"]), context = fake.context()
        _ = context.decode([0.1], initialPrompt: nil, language: "en", configuration: WhisperDecodeConfiguration(), shouldAbort: nil)
        var experiment = WhisperExperiment()
        experiment.suppressNonSpeechTokens = true; experiment.carryInitialPrompt = true
        experiment.beamSize = 5; experiment.vadModelPath = "/models/vad.bin"
        _ = context.decode([0.1], initialPrompt: nil, language: "en",
                           configuration: WhisperDecodeConfiguration(experiment: experiment), shouldAbort: nil)
        let (shipping, varied) = (fake.params[0], fake.params[1])
        XCTAssertEqual(shipping.strategy, WHISPER_SAMPLING_GREEDY)
        XCTAssertFalse(shipping.suppress_nst || shipping.carry_initial_prompt || shipping.vad)
        XCTAssertNil(fake.vadPaths[0])
        XCTAssertEqual(varied.strategy, WHISPER_SAMPLING_BEAM_SEARCH); XCTAssertEqual(varied.beam_search.beam_size, 5)
        XCTAssertTrue(varied.suppress_nst && varied.carry_initial_prompt && varied.vad)
        XCTAssertEqual(fake.vadPaths[1], "/models/vad.bin")
        XCTAssertGreaterThan(varied.temperature_inc, 0); XCTAssertEqual(varied.audio_ctx, 0)
    }
    func testTimedDecodeRefusesAnyExperiment() {
        let fake = ExperimentAPI(segments: ["x"]), context = fake.context()
        for change in [{ $0.suppressNonSpeechTokens = true }, { $0.carryInitialPrompt = true }, { $0.beamSize = 2 },
                       { $0.vadModelPath = "/v" }, { $0.collectEvidence = true }] as [(inout WhisperExperiment) -> Void] {
            var experiment = WhisperExperiment(); change(&experiment)
            XCTAssertNil(context.decodeTimed([0.1], initialPrompt: nil, language: "en",
                                             configuration: WhisperDecodeConfiguration(timed: true, experiment: experiment), shouldAbort: nil))
        }
        XCTAssertTrue(fake.params.isEmpty)
        // A context that once decoded with an experiment stays refused for timed decodes.
        var vad = WhisperExperiment(); vad.vadModelPath = "/v"
        _ = context.decode([0.1], initialPrompt: nil, language: "en", configuration: WhisperDecodeConfiguration(experiment: vad), shouldAbort: nil)
        XCTAssertNil(context.decodeTimed([0.1], initialPrompt: nil, language: "en",
                                         configuration: WhisperDecodeConfiguration(timed: true), shouldAbort: nil))
        XCTAssertEqual(fake.params.count, 1)
    }
    func testEvidenceIsCollectedOnlyWhenAskedAndRecordsTheLanguageRetry() async throws {
        let fake = ExperimentAPI(segments: ["a", "b", "c"])
        let english = try WhisperTranscriber(modelPath: "/m", native: fake.context())
        _ = await english.recognize([0.1], initialPrompt: nil, language: nil, shouldAbort: nil)
        XCTAssertNil(english.lastEvidence)
        english.experiment.collectEvidence = true
        _ = await english.recognize([0.1], initialPrompt: nil, language: nil, shouldAbort: nil)
        let evidence = try XCTUnwrap(english.lastEvidence)
        XCTAssertEqual(evidence.segments, [.init(noSpeechProbability: 0, tokens: 1, meanTokenProbability: 0.5),
                                           .init(noSpeechProbability: 0.1, tokens: 2, meanTokenProbability: 0.75),
                                           .init(noSpeechProbability: 0.2, tokens: 3, meanTokenProbability: 2.5 / 3)])
        XCTAssertFalse(evidence.languageRetry); XCTAssertEqual(evidence.requestedLanguage, "en")

        let hindi = try WhisperTranscriber(modelPath: "/m", native: fake.context(multilingual: true, detected: "hi"))
        hindi.experiment.collectEvidence = true
        _ = await hindi.recognize([0.1], initialPrompt: nil, language: nil, shouldAbort: nil)
        let retried = try XCTUnwrap(hindi.lastEvidence)
        XCTAssertTrue(retried.languageRetry); XCTAssertEqual(retried.requestedLanguage, "en"); XCTAssertEqual(retried.detectedLanguage, "hi")
    }
    func testExperimentListParsingIsStrict() {
        let parsed = WhisperExperiment.parse("suppress-nst,beam=5")
        XCTAssertEqual(parsed?.suppressNonSpeechTokens, true); XCTAssertEqual(parsed?.beamSize, 5)
        XCTAssertEqual(parsed?.label, "suppress-nst+beam=5")
        XCTAssertEqual(WhisperExperiment.parse("vad=/m/vad.bin", fileExists: { _ in true })?.label, "vad=vad.bin")
        for refused in ["beam=99", "beam=1", "foo", "", "suppress-nst,suppress-nst", "suppress-nst=1", "beam", "vad=/missing"] {
            XCTAssertNil(WhisperExperiment.parse(refused, fileExists: { _ in false }), refused)
        }
        XCTAssertEqual(WhisperExperiment().label, "")
    }
    /// Fake timed API: one segment " Hi." over 16 000 samples, tokens " Hi" and ".".
    private final class WordTimingAPI {
        var params: [whisper_full_params] = []
        var tokenEnd: Int64 = 40
        let segment = strdup(" Hi.")!, tokens = [strdup(" Hi")!, strdup(".")!]
        deinit { free(segment); tokens.forEach { free($0) } }
        func context() -> WhisperCContext {
            var api = WhisperCContext.API()
            api.full = { params, _, _ in self.params.append(params); return 0 }
            api.count = { 1 }; api.text = { _ in UnsafePointer(self.segment) }
            api.start = { _ in 0 }; api.end = { _ in 50 }
            api.tokenCount = { _ in 2 }
            api.tokenText = { _, index in UnsafePointer(self.tokens[Int(index)]) }
            api.tokenData = { _, index in
                var data = whisper_token_data(); data.id = index + 1
                data.t0 = index == 0 ? 0 : 30; data.t1 = index == 0 ? 30 : self.tokenEnd; return data
            }
            return WhisperCContext(api: api)
        }
    }
    func testWordTimingIsOptInAndNeverBreaksSegments() throws {
        let fake = WordTimingAPI(), context = fake.context(), samples = [Float](repeating: 0.1, count: 16_000)
        let plain = try XCTUnwrap(context.decodeTimed(samples, initialPrompt: nil, language: "en",
                                                     configuration: WhisperDecodeConfiguration(timed: true), shouldAbort: nil))
        XCTAssertFalse(fake.params[0].token_timestamps); XCTAssertNil(plain.words); XCTAssertNotNil(plain.timing)
        let worded = try XCTUnwrap(context.decodeTimed(samples, initialPrompt: nil, language: "en",
                                                      configuration: WhisperDecodeConfiguration(timed: true, wordTiming: true), shouldAbort: nil))
        XCTAssertTrue(fake.params[1].token_timestamps); XCTAssertEqual(fake.params[1].max_len, 0)
        XCTAssertEqual(worded.words?.words, [.init(text: "Hi.", start: 0, end: 40, segment: 0)])
        XCTAssertEqual(worded.timing, plain.timing)
        XCTAssertFalse(WhisperDecodeConfiguration(timed: false, wordTiming: true).wordTiming)
        fake.tokenEnd = 10_000  // past the source: words drop, segments stay
        let refused = try XCTUnwrap(context.decodeTimed(samples, initialPrompt: nil, language: "en",
                                                       configuration: WhisperDecodeConfiguration(timed: true, wordTiming: true), shouldAbort: nil))
        XCTAssertNil(refused.words); XCTAssertEqual(refused.timing, plain.timing)
    }
    /// Local only: needs the default model and a system voice. If this fails, the per-call
    /// token_timestamps flag perturbs the qualified segment result and word timing must not ship.
    func testSegmentsAreUnchangedByWordTiming() throws {
        let path = WhisperTranscriber.defaultModelPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no default model")
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", wav.path, "--data-format=LEI16@16000", "--channels=1",
                         "Tomorrow at ten I have a meeting with the team. After that, we review the release notes."]
        try say.run(); say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "no Samantha system voice")
        let samples = try Eval.loadSamples(url: wav)
        let context = try WhisperCContext(path, .nativeDefaults)
        let plain = try XCTUnwrap(context.decodeTimed(samples, initialPrompt: nil, language: "en",
                                                     configuration: WhisperDecodeConfiguration(timed: true), shouldAbort: nil))
        let worded = try XCTUnwrap(context.decodeTimed(samples, initialPrompt: nil, language: "en",
                                                      configuration: WhisperDecodeConfiguration(timed: true, wordTiming: true), shouldAbort: nil))
        let cues = try XCTUnwrap(plain.timing?.cues)
        XCTAssertFalse(cues.isEmpty)
        XCTAssertEqual(worded.timing?.cues, cues)
        XCTAssertNotNil(worded.words)
    }
    func testShippedMultilingualModelKeepsCantonese() throws {
        let model = ModelCatalog.path(for: ModelCatalog.all.first { $0.id.hasPrefix("large") }!)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "no large-v3-turbo-q5_0 model installed")
        let context = try WhisperCContext(model, .nativeDefaults)
        XCTAssertTrue(context.knowsLanguage("yue")); XCTAssertFalse(context.knowsLanguage("xx"))
    }
    func testTranscribeSilenceProducesNoCrash() async throws {
        let path = WhisperTranscriber.defaultModelPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no whisper model — run scripts/download-model.sh")
        let t = try WhisperTranscriber(modelPath: path)
        // 1s of silence: must not crash; output may be empty or hallucinated punctuation.
        let out = await t.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: "Kubernetes")
        XCTAssertNotNil(out)
        // Both prompt branches run under the language withCString, and only the prompted
        // one is covered above — a nil prompt takes the other path to whisper_full.
        recognitionAssertNotNil(await t.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: nil))
    }

    /// The decode used to be pinned to English, and a multilingual model told
    /// "this is English" translates: Hindi speech came out as an English
    /// sentence. Now each pass is decoded in the last pass's language and
    /// redone only when the speaker switched — which has to give exactly what
    /// whisper's own detect-then-decode gives, at half its cost when nothing
    /// switched. Local only: it needs the multilingual model and macOS's Hindi
    /// voice, and CI has neither.
    func testMultilingualModelFollowsTheSpeakerLikeWhisperAutoDetect() async throws {
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
        var heard: [String?] = []
        for clip in [hindi, english] {
            let text = await t.transcribe(clip, initialPrompt: nil)
            XCTAssertEqual(text, t.decode(clip, initialPrompt: nil, language: "auto"))
            heard.append(text)
        }
        let devanagari = heard[0]?.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        XCTAssertEqual(devanagari, true, "got: \(heard[0] ?? "nil")")
    }

    /// Local only: needs the default model.
    func testNativePromptBudgetKeepsPriorityTermsWithinTheModelPrompt() throws {
        let path = WhisperTranscriber.defaultModelPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no whisper model — run scripts/download-model.sh")
        let budget = try XCTUnwrap(try WhisperTranscriber(modelPath: path).promptBudget)
        XCTAssertEqual(budget.capacity, 223)
        let words = (0..<200).map { "Name\($0)" }
        XCTAssertGreaterThan(budget.count(words.joined(separator: ", ")), 223)
        let prompt = try XCTUnwrap(VocabularyHints.asrPrompt(words, budget: budget))
        XCTAssertLessThanOrEqual(budget.count(prompt), 223)
        XCTAssertTrue(prompt.hasPrefix("Name0"))
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
