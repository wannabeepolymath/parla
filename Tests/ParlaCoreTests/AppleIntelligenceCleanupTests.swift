import XCTest
@testable import ParlaCore

private let localSource = "Please review the complete proposal before the meeting tomorrow"
private let localOutput = "Please review the complete proposal before the meeting tomorrow."

private final class LocalBottom: @unchecked Sendable {
    let lock = NSLock()
    var availabilityReason: LocalCleanupReason?
    var languages: (String) -> [String: Double] = { _ in ["en": 0.99, "hi": 0.01] }
    var output = localOutput
    var error: Error?
    var beforeResponse: (() -> Void)?
    var prompts: [LocalCleanupPrompt] = [], localeChecks: [[String]] = []
    var generations = 0, watchdogExits = 0
    var time: TimeInterval = 100
    var started: XCTestExpectation?
    var canceled: XCTestExpectation?
    var held: CheckedContinuation<String, Error>?
    var hold = false
    var sleepOverride: ((TimeInterval) async throws -> Void)?
    var runtime: LocalCleanupRuntime {
        LocalCleanupRuntime(availability: { locales in
            self.lock.withLock { self.localeChecks.append(locales); return self.availabilityReason }
        }, language: { self.languages($0) }, generate: { prompt, attempted in
            self.lock.withLock { self.generations += 1; self.prompts.append(prompt) }
            self.beforeResponse?()
            try attempted()
            if self.hold {
                return try await withTaskCancellationHandler(operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        self.lock.withLock { self.held = continuation }
                        self.started?.fulfill()
                    }
                }, onCancel: { self.canceled?.fulfill() })
            }
            if let error = self.error { throw error }
            return self.output
        }, now: { self.lock.withLock { self.time } }, sleep: { duration in
            defer { self.lock.withLock { self.watchdogExits += 1 } }
            if let sleep = self.sleepOverride { try await sleep(duration) }
            else { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }, appLocale: { "en_US" })
    }
    func release(_ text: String = localOutput) { lock.withLock { held?.resume(returning: text); held = nil } }
}

final class AppleIntelligenceCleanupTests: XCTestCase {
    private func settings() -> Settings {
        var settings = Settings(); settings.cleanup.provider = "apple-intelligence"; settings.cleanup.localSourceLocale = "en"
        settings.cleanup.baseURL = "invalid inactive binding"; settings.cleanup.model = "remote-model"
        settings.anthropicApiKey = "inactive-secret-canary"; settings.cleanup.apiKey = "inactive-compatible-canary"
        return settings
    }
    private func client(_ settings: Settings, _ bottom: LocalBottom) throws -> CleanupProviding {
        try ParlaCore.makeCleanupClient(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials(), http: forbiddenHTTP(), localRuntime: bottom.runtime, usage: { _, _, _ in })
    }
    private func forbiddenEnv() -> [String: String] { XCTFail("local environment evaluated"); return [:] }
    private func forbiddenCredentials() -> CredentialStore { XCTFail("local credentials constructed"); return testCredentialStore() }
    private func forbiddenHTTP() -> HTTPPosting { XCTFail("local HTTP constructed"); return URLSessionPoster() }
    private func pipeline(_ settings: Settings, _ bottom: LocalBottom) -> Pipeline {
        Pipeline(outputSettings: settings, bundleID: nil) { try self.client($0, bottom) }
    }

    func testRealFactoryTypedAccessConfigurationWarmAndOrdinaryPromptHaveNoNetworkDependencies() async throws {
        let settings = settings(), bottom = LocalBottom()
        let access = try prepareCleanupAccess(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials())
        guard case .onDevice = access else { return XCTFail("typed local access required") }
        XCTAssertTrue(ParlaCore.cleanupIsConfigured(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials()))
        XCTAssertNil(cleanupConfigurationIssue(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials()))
        XCTAssertTrue(cleanupCredentialSource(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials()).contains("on this Mac"))
        XCTAssertNil(ParlaCore.cleanupWarmURL(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials()))
        _ = try client(settings, bottom)
        XCTAssertTrue(bottom.localeChecks.isEmpty); XCTAssertEqual(bottom.generations, 0)
        let result = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertNil(result.failure); XCTAssertEqual(result.text, localOutput)
        XCTAssertEqual(bottom.generations, 1); XCTAssertEqual(bottom.watchdogExits, 1)
        XCTAssertEqual(bottom.prompts.first?.user, "<transcript>\n" + localSource)
        XCTAssertTrue(bottom.prompts.first?.system.contains("Keep the speaker's language") == true)
        XCTAssertTrue(bottom.localeChecks.contains(["en", "en", "en_US"]))
        var network = Settings(); network.cleanup.provider = "openai-compatible"; network.cleanup.baseURL = "https://host/v1"
        XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: network, env: [:], credentials: testCredentialStore(), access: access))
        let networkAccess = try prepareCleanupAccess(settings: network, env: [:], credentials: testCredentialStore())
        XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: settings, env: forbiddenEnv(), credentials: forbiddenCredentials(), access: networkAccess, localRuntime: bottom.runtime))
    }

    func testRawOffAndExactSnippetBypassAllLocalAPIsAndPreserveRuleOrder() async {
        var settings = settings(); let bottom = LocalBottom()
        settings.replacements = [.init(source: "proposal", replacement: "document")]
        settings.outputMode = .raw
        let raw = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertEqual(raw.text, localSource)
        settings.outputMode = .cleanup; settings.cleanupEnabled = false
        let off = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertTrue(off.text.contains("document"))
        settings.cleanupEnabled = true; settings.snippets = [localSource: "proposal"]
        let locked = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertEqual(locked.text, "proposal")
        XCTAssertEqual(bottom.generations, 0); XCTAssertTrue(bottom.localeChecks.isEmpty)
    }

    func testEveryAvailabilityAndRequestReadinessChangeIsFiniteWithoutGeneration() async {
        for reason in [LocalCleanupReason.oldOS, .missingFramework, .ineligible, .disabled, .notReady, .unavailable, .unsupportedLanguage] {
            let bottom = LocalBottom(); bottom.availabilityReason = reason
            XCTAssertEqual(bottom.runtime.recheck(LocalCleanupConfiguration(settings: settings())), reason)
            let result = await pipeline(settings(), bottom).clean(transcript: localSource)
            XCTAssertEqual(result.text, localSource); XCTAssertEqual(result.failure, reason.message); XCTAssertEqual(bottom.generations, 0)
        }
        let bottom = LocalBottom()
        XCTAssertNil(bottom.runtime.recheck(LocalCleanupConfiguration(settings: settings())))
        bottom.availabilityReason = .disabled
        let first = await pipeline(settings(), bottom).clean(transcript: localSource)
        XCTAssertNotNil(first.failure)
        bottom.availabilityReason = nil
        let second = await pipeline(settings(), bottom).clean(transcript: localSource)
        XCTAssertNil(second.failure); XCTAssertEqual(bottom.generations, 1)
    }

    func testDeclaredDetectedInstructionHintSnippetOutputAndTailLanguageRefuseWholeRequest() async {
        var settings = settings(); let bottom = LocalBottom()
        settings.cleanup.localSourceLocale = nil
        let checked1 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked1.failure)
        settings.cleanup.localSourceLocale = "hi"
        let checked2 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked2.failure)
        settings.cleanup.localSourceLocale = "en"
        for source in ["Hi", "John Smith", "let foo = bar", "namaste dosto", localSource + ". Hi"] {
            let checked3 = (await pipeline(settings, bottom).clean(transcript: source))
            XCTAssertNotNil(checked3.failure)
        }
        bottom.languages = { _ in ["en": 0.94, "hi": 0.06] }
        let checked4 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked4.failure)
        bottom.languages = { $0.contains("MIXED") ? ["hi": 0.99] : ["en": 0.99] }
        let tail = String(repeating: localSource + " ", count: 40) + "MIXED " + localSource
        let checked5 = (await pipeline(settings, bottom).clean(transcript: tail))
        XCTAssertNotNil(checked5.failure)
        settings.dictionary = ["short-name"]
        let checked6 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked6.failure)
        settings.dictionary = []; settings.snippets = ["short": localSource]
        let checked7 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked7.failure)
        XCTAssertEqual(bottom.generations, 0)
        settings.snippets = [:]; bottom.output = "MIXED " + localSource
        let checked8 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertNotNil(checked8.failure)
        XCTAssertEqual(bottom.generations, 1)
    }

    func testConfirmedSavedRewriteUsesSharedTrimOnlyPolicyWhileOtherActionsNeverGenerate() async throws {
        var settings = settings(); let bottom = LocalBottom()
        var preset = TransformPreset(name: "Concise", instruction: "Please rewrite this text more concisely while preserving its meaning", localPreserveSourceLanguage: true)
        bottom.output = "  \"" + localOutput + "\"  "
        let result = try await IntentionalTransform(source: localSource, instruction: preset.intent, settings: settings, preset: preset).run { try self.client($0, bottom) }
        XCTAssertEqual(result, "\"" + localOutput + "\"")
        XCTAssertTrue(bottom.prompts[0].user.contains("<text>\n" + localSource))
        settings.transformPresets = [preset]; settings.selectedPresetID = preset.id; settings.outputMode = .selectedPreset
        settings.replacements = [.init(source: "proposal", replacement: "WRONG")]
        let dictated = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertEqual(dictated.text, result)
        let count = bottom.generations
        preset.localPreserveSourceLanguage = nil
        for candidate in [Optional(preset), nil, Optional(TransformPreset(name: "Translate", kind: .translation, targetLanguage: "Hindi", localPreserveSourceLanguage: true))] {
            do { _ = try await IntentionalTransform(source: localSource, instruction: preset.intent, settings: settings, preset: candidate).run { try self.client($0, bottom) }; XCTFail("unsupported action admitted") }
            catch { XCTAssertTrue(String(describing: error).contains("unsupportedAction")) }
        }
        XCTAssertEqual(bottom.generations, count)
    }

    func testResourceBoundsFiniteNativeErrorsAndDetailedLoggingCannotEchoCanaries() async {
        var settings = settings(); let bottom = LocalBottom()
        for source in [String(repeating: "a", count: 8193), String(repeating: "🙂", count: 2049)] {
            let checked9 = (await pipeline(settings, bottom).clean(transcript: source))
            XCTAssertEqual(checked9.failure, LocalCleanupReason.inputTooLarge.message)
        }
        settings.snippets = [String(repeating: "b", count: 13 * 1024): localSource]
        let checked10 = (await pipeline(settings, bottom).clean(transcript: localSource))
        XCTAssertEqual(checked10.failure, LocalCleanupReason.inputTooLarge.message)
        XCTAssertEqual(bottom.generations, 0)
        settings.snippets = [:]
        for reason in [LocalCleanupReason.contextLimit, .refusedOrSafety, .notReady, .rateLimited, .unavailable] {
            bottom.error = reason
            let checked11 = (await pipeline(settings, bottom).clean(transcript: localSource))
            XCTAssertEqual(checked11.failure, reason.message)
        }
        bottom.error = CleanupError(description: "private-native-error-canary", userMessage: "private-secret-canary")
        var logs: [String] = []; var pipe = pipeline(settings, bottom); pipe.log = { logs.append($0) }
        let checked12 = (await pipe.clean(transcript: localSource))
        XCTAssertEqual(checked12.failure, LocalCleanupReason.unavailable.message)
        XCTAssertFalse(logs.joined().contains("canary"))
        bottom.error = nil
        for (output, reason) in [("", LocalCleanupReason.empty), (String(repeating: "a", count: 32769), .oversized), ("short", .unknownLanguage)] {
            bottom.output = output
            let checked13 = (await pipeline(settings, bottom).clean(transcript: localSource))
            XCTAssertEqual(checked13.failure, reason.message)
        }
    }

    func testLogicalDeadlineAtEqualityKeepsQueueUntilRealExitAndJoinsWatchdog() async throws {
        let bottom = LocalBottom(); bottom.hold = true; bottom.started = expectation(description: "local response boundary")
        let operation = PendingOperation(name: "local")
        var result: (String, String?)?
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            let value = await self.pipeline(self.settings(), bottom).clean(transcript: localSource)
            result = (value.text, value.failure)
        })
        await fulfillment(of: [bottom.started!], timeout: 2)
        bottom.lock.withLock { bottom.time = 115 }
        var nextEntered = false
        let second = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "next"), completes: true, work: { nextEntered = true })
        XCTAssertFalse(operation.hasExited); XCTAssertNil(result); XCTAssertFalse(nextEntered)
        bottom.release()
        await second.value
        XCTAssertEqual(result?.0, localSource); XCTAssertEqual(result?.1, LocalCleanupReason.deadline.message)
        XCTAssertTrue(operation.hasExited); XCTAssertTrue(nextEntered); XCTAssertEqual(bottom.watchdogExits, 1)
    }

    func testDiscardIgnoredCancellationAndCancelBeforeDequeueNeverPublishOrReleaseEarly() async throws {
        let bottom = LocalBottom(); bottom.hold = true; bottom.started = expectation(description: "held local")
        let operation = PendingOperation(name: "local")
        var published = false
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            let result = await self.pipeline(self.settings(), bottom).clean(transcript: localSource)
            if !operation.shouldAbort { published = result.failure == nil }
        })
        await fulfillment(of: [bottom.started!], timeout: 2)
        operation.revoke(); operation.requestAbort()
        var finished = false
        let canceled = PendingOperation(name: "queued"); canceled.revoke()
        let second = PendingOperationQueue.enqueue(previous: first, operation: canceled, completes: true, work: { XCTFail("canceled work entered") }, finished: { finished = true })
        XCTAssertFalse(operation.hasExited); XCTAssertFalse(finished)
        bottom.release(); await second.value
        XCTAssertFalse(published); XCTAssertTrue(finished); XCTAssertEqual(bottom.generations, 1); XCTAssertEqual(bottom.watchdogExits, 1)
    }

    func testWholeAndWindowEvidenceMustAgreeAndSupportedHindiUsesDeclaredOutput() async throws {
        var settings = settings(); let bottom = LocalBottom()
        bottom.languages = { text in [text.count > 240 ? "en" : "hi": 0.99] }
        let long = String(repeating: localSource + " ", count: 10)
        let refused = await pipeline(settings, bottom).clean(transcript: long)
        XCTAssertEqual(refused.failure, LocalCleanupReason.mixedLanguage.message); XCTAssertEqual(bottom.generations, 0)
        settings.cleanup.localSourceLocale = "hi"
        bottom.languages = { _ in ["hi": 0.99, "en": 0.01] }
        let hindi = "कृपया कल की बैठक से पहले इस पूरे प्रस्ताव की समीक्षा करें"
        bottom.output = hindi
        let output = try await client(settings, bottom).clean(transcript: hindi, context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertEqual(output, hindi)
        XCTAssertTrue(bottom.prompts[0].locales.contains("hi")); XCTAssertTrue(bottom.prompts[0].locales.contains("en"))
    }

    func testExactByteCapsCombinedTransformBudgetAndExistingOrdinaryGuards() async throws {
        let settings = settings(), bottom = LocalBottom()
        let text = String(String(repeating: localSource + " ", count: 200).prefix(8192))
        bottom.output = text
        let provider = try client(settings, bottom), context = CleanupContext(dictionary: [], snippets: [:], appName: nil)
        let accepted = try await provider.clean(transcript: text, context: context)
        XCTAssertEqual(accepted, text)
        do { _ = try await provider.clean(transcript: text + "a", context: context); XCTFail("above byte cap admitted") }
        catch { XCTAssertEqual(LocalCleanupReason.from(error), .inputTooLarge) }
        var transform = context; transform.selection = text; transform.localIntent = .savedSameLanguageRewrite
        do { _ = try await provider.clean(transcript: localSource, context: transform); XCTFail("combined bound omitted instruction") }
        catch { XCTAssertEqual(LocalCleanupReason.from(error), .inputTooLarge) }
        bottom.output = String(String(repeating: localSource + " ", count: 600).prefix(32768))
        let outputAtLimit = try await provider.clean(transcript: localSource, context: context)
        XCTAssertEqual(outputAtLimit.utf8.count, 32768)
        bottom.output += "x"
        do { _ = try await provider.clean(transcript: localSource, context: context); XCTFail("oversized response admitted") }
        catch { XCTAssertEqual(LocalCleanupReason.from(error), .oversized) }
        bottom.output = String(repeating: localSource + " ", count: 20)
        let ceiling = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertEqual(ceiling.failure, "cleanup returned invalid text")
        bottom.output = localOutput
        let floor = await pipeline(settings, bottom).clean(transcript: text)
        XCTAssertEqual(floor.failure, "cleanup returned truncated text")
        bottom.output = "  \"" + localOutput + "\"  "
        let sanitized = await pipeline(settings, bottom).clean(transcript: localSource)
        XCTAssertEqual(sanitized.text, localOutput)
    }

    func testFullPromptCapIncludesEverySnippetAndResponseBoundaryRechecksDeadline() async throws {
        let settings = settings(), bottom = LocalBottom()
        var context = CleanupContext(dictionary: [], snippets: Dictionary(uniqueKeysWithValues: (0..<200).map {
            ("Please review this proposal \($0)", "Please review this full proposal")
        }), appName: nil)
        func promptBytes(_ context: CleanupContext) -> Int {
            let policy = "\n\nPreserve the source language. The explicitly declared source and output locale is en. Never translate."
            return PromptBuilder.system(context: context).utf8.count + policy.utf8.count + PromptBuilder.user(transcript: localSource, context: context).utf8.count
        }
        // Tune one bounded configured snippet to the exact full-prompt boundary.
        while promptBytes(context) > 16384 { context.snippets.removeValue(forKey: context.snippets.keys.sorted().last!) }
        let first = context.snippets.keys.sorted().first!
        context.snippets[first]! += String(repeating: "a", count: 16384 - promptBytes(context))
        XCTAssertEqual(promptBytes(context), 16384)
        XCTAssertLessThanOrEqual(context.snippets.reduce(localSource.utf8.count) { $0 + $1.key.utf8.count + $1.value.utf8.count }, 12288)
        _ = try await client(settings, bottom).clean(transcript: localSource, context: context)
        context.snippets[first]! += "a"
        do { _ = try await client(settings, bottom).clean(transcript: localSource, context: context); XCTFail("full prompt above cap admitted") }
        catch { XCTAssertEqual(LocalCleanupReason.from(error), .inputTooLarge) }
        XCTAssertEqual(bottom.generations, 1)
        let diagnostics = DiagnosticStore(), operation = diagnostics.start(id: UUID(), origin: .dictation)
        bottom.beforeResponse = { bottom.lock.withLock { bottom.time = 115 } }
        let pipe = Pipeline(outputSettings: settings, bundleID: nil, diagnostics: operation) { try self.client($0, bottom) }
        let result = await pipe.clean(transcript: localSource)
        XCTAssertEqual(result.failure, LocalCleanupReason.deadline.message)
        XCTAssertNotEqual(diagnostics.snapshot().records.first?.localGenerationAttempted, true)
    }

    func testDeadlineWatchdogCancelsButRetainsIgnoredWorkerAndNeverRevivesLateText() async throws {
        let bottom = LocalBottom(); bottom.hold = true; bottom.started = expectation(description: "held generation")
        let watchdog = expectation(description: "watchdog started"), expired = expectation(description: "watchdog completed")
        bottom.canceled = expectation(description: "worker cancellation requested")
        let gate = LocalTestWatchdog()
        bottom.sleepOverride = { _ in
            watchdog.fulfill(); try await gate.wait(); expired.fulfill()
        }
        let running = Task { await self.pipeline(self.settings(), bottom).clean(transcript: localSource) }
        await fulfillment(of: [bottom.started!, watchdog], timeout: 2)
        bottom.lock.withLock { bottom.time = 115 }; gate.wake()
        await fulfillment(of: [expired, bottom.canceled!], timeout: 2)
        // Even a clock moved backwards after expiry cannot restore acceptance.
        bottom.lock.withLock { bottom.time = 114 }; bottom.release()
        let result = await running.value
        XCTAssertEqual(result.failure, LocalCleanupReason.deadline.message); XCTAssertEqual(result.text, localSource)
        XCTAssertEqual(bottom.watchdogExits, 1)
    }

    func testCancelBeforeWorkerHandleInstallationIsRememberedByRetainedOwner() async {
        let owner = LocalCleanupOwner()
        owner.stop(.canceled)
        var canceled = false
        owner.install { canceled = true }
        XCTAssertTrue(canceled); XCTAssertEqual(owner.stopped, .canceled)
        owner.stop(.deadline); XCTAssertEqual(owner.stopped, .canceled)
        let bottom = LocalBottom()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.pipeline(self.settings(), bottom).clean(transcript: localSource)
        }
        let result = await task.value
        XCTAssertEqual(result.failure, LocalCleanupReason.canceled.message)
        XCTAssertEqual(bottom.generations, 0); XCTAssertTrue(bottom.localeChecks.isEmpty)
    }

    func testLocalDiagnosticsProvenanceCLIAndLegacyDecodeRemainTruthful() async throws {
        let settings = settings(), bottom = LocalBottom(), diagnostics = DiagnosticStore()
        let operation = diagnostics.start(id: UUID(), origin: .historyRetry)
        var pipe = pipeline(settings, bottom); pipe.diagnostics = operation
        // Use production observation wrapper, not a fake provider.
        pipe = Pipeline(outputSettings: settings, bundleID: nil, diagnostics: operation) { try self.client($0, bottom) }
        let checked14 = (await pipe.clean(transcript: localSource))
        XCTAssertNil(checked14.failure)
        let record = try XCTUnwrap(diagnostics.snapshot().records.first)
        XCTAssertFalse(record.providerRequestAttempted); XCTAssertEqual(record.localGenerationAttempted, true)
        XCTAssertEqual(record.provider, .appleIntelligence); XCTAssertEqual(record.resolvedProviderModel, .appleIntelligence)
        XCTAssertThrowsError(try EvalCleanupSelection.validate(settings: settings, modelOverride: "remote", command: nil))
        XCTAssertNoThrow(try EvalCleanupSelection.validate(settings: settings, modelOverride: "remote", command: "/cmd"))
        XCTAssertEqual(EvalCleanupSelection.label(settings: settings, modelOverride: nil, command: nil), "Apple Intelligence · on-device")
        let request = try HistoryRetryRequest(settings: settings, environment: forbiddenEnv(), source: .init(raw: localSource), applyPreset: false, credentials: forbiddenCredentials())
        XCTAssertFalse(request.configuration.localOnly); XCTAssertEqual(request.configuration.executionKind, .onDevice)
        let (_, provenance) = try await request.run(source: localSource, factory: { frozen, env, access, usage in
            try ParlaCore.makeCleanupClient(settings: frozen, env: env, credentials: self.forbiddenCredentials(), access: access, http: self.forbiddenHTTP(), localRuntime: bottom.runtime, usage: usage)
        })
        XCTAssertNil(provenance.usage?.promptTokens); XCTAssertNil(provenance.usage?.completionTokens)
        XCTAssertEqual(provenance.usage?.cleanupModel, "Apple Intelligence · on-device")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.configuration)) as! [String: Any]
        json.removeValue(forKey: "execution"); json["localOnly"] = true
        let legacy = try JSONDecoder().decode(HistoryRetryConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.executionKind, .deterministic)
    }
}

/// Deterministic fake watchdog below the adapter. Cancellation/installation race
/// also settles once; no real timer or model readiness/classifier is invoked.
private final class LocalTestWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<Void, Error>? in
                    if let result { return result }; self.continuation = continuation; return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    func wake() { finish(.success(())) }
    private func finish(_ result: Result<Void, Error>) {
        let callback = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }; self.result = result
            let callback = continuation; continuation = nil; return callback
        }
        callback?.resume(with: result)
    }
}
