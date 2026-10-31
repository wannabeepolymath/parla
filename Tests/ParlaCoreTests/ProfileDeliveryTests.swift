import XCTest
@testable import ParlaCore

final class ProfileDeliveryTests: XCTestCase {
    private final class Client: CleanupProviding {
        var context: CleanupContext?
        var instruction: String?
        var result = "cat\nnext"
        func clean(transcript: String, context: CleanupContext) async throws -> String {
            self.context = context; instruction = transcript
            await Task.yield()
            return result
        }
    }

    private func settings() -> Settings {
        var s = Settings(); s.anthropicApiKey = "fake-key"
        s.dictionary = ["Global"]
        s.replacements = [.init(source: "cat", replacement: "dog")]
        var capture = DictationProfile(); capture.name = "Capture"; capture.target = "capture"
        capture.language = "hi"; capture.whisperModelPath = "/capture.bin"; capture.dictionary = ["CaptureWord"]
        var output = DictationProfile(); output.name = "Output"; output.target = "output"
        output.style = .formal; output.cleanupModel = "output-model"; output.dictionary = ["OutputWord"]
        var off = DictationProfile(); off.name = "Local"; off.target = "local"; off.cleanup = .off
        s.profiles = [capture, output, off]
        return s
    }

    private func start(_ m: DictationSession, settings: Settings) -> DictationSession.Session {
        _ = m.handle(.startDictation(settings: settings, cleanupConfigured: true, live: false,
                                    recognitionDestination: .init(bundleID: "capture")))
        _ = m.handle(.recorderStarted(gen: m.gen))
        _ = m.handle(.focusSampled(gen: m.gen, focus: .editable))
        guard case .recording(let s) = m.state else { fatalError("not recording") }
        return s
    }

    func testDestinationWinnerIsResolvedBeforeReducerAndFactoryUsesFrozenOutput() async throws {
        var globals = settings()
        let m = DictationSession(), client = Client()
        let captured = start(m, settings: globals)
        let fx = m.handle(.transcribed(captured, raw: "cat", probe: .init(focus: .editable, bundleID: "output", deferInsertionUntilClean: true, singleLine: true)))
        guard case .polish(let s, let landed)? = fx.first(where: { if case .polish = $0 { return true }; return false }) else { return XCTFail("missing output leg") }
        XCTAssertEqual(s.recognitionProfileName, "Capture"); XCTAssertEqual(s.output?.name, "Output")
        XCTAssertEqual(s.recognition.language, "hi"); XCTAssertEqual(s.recognition.modelPath, "/capture.bin")
        XCTAssertEqual(s.effectiveSettings.dictionary, ["OutputWord", "Global"])
        XCTAssertNil(s.effectiveSettings.language) // never composes capture language
        XCTAssertNil(s.effectiveSettings.whisperModelPath)
        XCTAssertFalse(fx.contains { if case .insertText = $0 { return true }; return false })
        globals.profiles[1].cleanupModel = "later-model"; globals.profiles[1].style = .conversational
        var factories = 0
        let pipeline = Pipeline(outputSettings: s.effectiveSettings, bundleID: landed.bundleID, singleLine: landed.singleLine) { effective in
            factories += 1
            XCTAssertEqual(effective.cleanupModel, "output-model")
            XCTAssertEqual(effective.cleanupStyle, .formal)
            return client
        }
        let result = await pipeline.clean(transcript: landed.raw)
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(client.context?.dictionary, ["OutputWord", "Global"])
        XCTAssertEqual(client.context?.style, .formal)
        let done = m.handle(.cleanReady(s, landed, text: result.text, failure: result.failure, focus: .editable))
        XCTAssertTrue(done.contains(.insertText("dog next")))
        XCTAssertTrue(done.contains(.appendHistory(raw: "cat", cleaned: "dog\nnext", appName: nil)))
    }

    func testOffSkipsFactoryAndWarmDespiteCredentialsAndKeepsLockedLocalRules() async {
        var globals = settings(); globals.snippets = ["shortcut": "cat\nlocked"]
        let m = DictationSession()
        let startFX = m.handle(.startDictation(settings: globals, cleanupConfigured: true, live: false))
        XCTAssertFalse(startFX.contains(.warmCleanupEndpoint))
        let s = start(m, settings: globals)
        for (raw, expected) in [("cat", "dog"), ("Shortcut!", "cat\nlocked")] {
            let fx = m.handle(.transcribed(s, raw: raw, probe: .init(focus: .editable, bundleID: "local", deferInsertionUntilClean: true)))
            XCTAssertTrue(fx.contains(.insertText(expected)))
            XCTAssertFalse(fx.contains { if case .polish = $0 { return true }; return false })
            XCTAssertTrue(fx.contains(.appendHistory(raw: raw, cleaned: expected, appName: nil)))
        }
        let off = s.resolvingOutput(at: .init(bundleID: "local")).effectiveSettings
        XCTAssertFalse(cleanupIsConfigured(settings: off, env: ["ANTHROPIC_API_KEY": "configured"]))
        XCTAssertNil(cleanupWarmURL(settings: off, env: ["ANTHROPIC_API_KEY": "configured"]))
        var factories = 0
        let pipeline = Pipeline(outputSettings: off, bundleID: "local") { _ in factories += 1; return Client() }
        let local = await pipeline.clean(transcript: "cat")
        let locked = await pipeline.clean(transcript: "Shortcut!")
        XCTAssertEqual(local.text, "dog"); XCTAssertEqual(locked.text, "cat\nlocked")
        XCTAssertEqual(factories, 0)
    }

    func testProfileStyleComesBeforeTerminalChatSingleLineAndDoesNotLeakDestination() {
        let url = "https://secret.example.com/path?secret=private"
        for bundle in ["com.apple.Terminal", "com.hnc.Discord", "com.apple.Safari", "unknown.app"] {
            let context = CleanupContext(dictionary: [], snippets: [:], appName: "PRIVATE NAME", bundleID: bundle, browserURL: url, singleLine: true, style: .formal)
            let prompt = PromptBuilder.system(context: context)
            XCTAssertFalse(prompt.contains("PRIVATE NAME")); XCTAssertFalse(prompt.contains("secret.example.com"))
            XCTAssertFalse(prompt.contains("private")); XCTAssertFalse(prompt.contains("/path"))
            XCTAssertLessThan(prompt.range(of: "Use complete sentences and polished grammar")!.lowerBound,
                              prompt.range(of: "The destination is a single-line field")!.lowerBound)
            if bundle == "com.apple.Terminal" {
                XCTAssertLessThan(prompt.range(of: "Use complete sentences and polished grammar")!.lowerBound,
                                  prompt.range(of: "This will be inserted into a terminal")!.lowerBound)
            }
        }
    }

    func testSecureChangedAndStaleDestinationsStillWithholdProfileOutput() {
        let m = DictationSession(), globals = settings()
        let s = start(m, settings: globals)
        let secure = m.handle(.transcribed(s, raw: "secret", probe: .init(focus: .secure, bundleID: "output")))
        XCTAssertFalse(secure.contains { if case .polish = $0 { return true }; if case .appendHistory = $0 { return true }; if case .insertText = $0 { return true }; return false })
        let pending = m.handle(.transcribed(s, raw: "cat", probe: .init(focus: .editable, bundleID: "output", deferInsertionUntilClean: true)))
        guard case .polish(let output, let landed)? = pending.first(where: { if case .polish = $0 { return true }; return false }) else { return XCTFail("missing output") }
        let changed = m.handle(.cleanReady(output, landed, text: "result", failure: nil, focus: .none))
        XCTAssertFalse(changed.contains(.insertText("result")))
        _ = start(m, settings: globals)
        let stale = m.handle(.cleanReady(output, landed, text: "result", failure: nil, focus: .editable))
        XCTAssertFalse(stale.contains(.insertText("result")))
        XCTAssertTrue(stale.contains(.appendHistory(raw: "cat", cleaned: "result", appName: nil)))
    }

    func testCommandUsesOutputModelAndWordsButPreservesSelectedTransformSemantics() async throws {
        let globals = settings(), m = DictationSession(), client = Client()
        _ = m.handle(.startCommand(settings: globals, cleanupConfigured: true, focus: .editable, selection: "selected cat",
                                  recognitionDestination: .init(bundleID: "capture")))
        _ = m.handle(.recorderStarted(gen: m.gen))
        guard case .recording(let captured) = m.state else { return XCTFail("no command") }
        let output = captured.resolvingOutput(at: .init(bundleID: "output"))
        let text = try await output.transform(instruction: "put this in quotes") { effective in
            XCTAssertEqual(effective.cleanupModel, "output-model")
            return client
        }
        XCTAssertEqual(text, "cat\nnext") // no literal replacement on selected transforms
        XCTAssertEqual(client.context?.selection, "selected cat")
        XCTAssertEqual(client.context?.dictionary, ["OutputWord", "Global"])
        XCTAssertTrue(client.context!.snippets.isEmpty)
        XCTAssertFalse(PromptBuilder.system(context: client.context!).contains("Use complete sentences and polished grammar"))
        XCTAssertEqual(captured.recognition.language, "hi")
        do {
            _ = try await captured.resolvingOutput(at: .init(bundleID: "local")).transform(instruction: "x") { _ in
                XCTFail("off must never construct a client"); return client
            }
            XCTFail("off should refuse the transform")
        } catch { XCTAssertTrue(String(describing: error).contains("Cleanup off")) }
    }
}
