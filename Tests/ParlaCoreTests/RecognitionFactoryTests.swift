import XCTest
@testable import ParlaCore

private final class NativeProbe: @unchecked Sendable {
    struct Call { let samples: [Float]; let prompt: String?; let language: String; let configuration: WhisperDecodeConfiguration }
    var multilingual = true
    var outputs = [WhisperNativeDecode(status: 0, segments: [" transcript "])]
    var detected: String?
    var known = ["en", "hi", "es"]
    var calls: [Call] = []
    var constructions: [(String, WhisperComputeConfiguration)] = []
    var releases = 0, detections = 0, admissions = 0
    var duringDecode: (() -> Void)?
    var duringConstruct: (() -> Void)?
    var failConstruct = false, refuseAdmission = false
    var generation = RecognitionFileGeneration(bytes: 8, modified: 1)
    var implementation = RecognitionRuntime(nativeVersion: "native-private-version", buildScope: "private-build")
    func factory() -> RecognitionFactory {
        RecognitionFactory(native: { path, compute in
            self.constructions.append((path, compute)); self.duringConstruct?()
            if self.failConstruct { throw TranscriberError(description: "PRIVATE_ERROR") }
            return Context(self)
        }, runtime: { self.implementation }, metadata: { _ in self.generation },
        directory: URL(fileURLWithPath: "/owned"), admit: { _, _ in
            self.admissions += 1
            if self.refuseAdmission { throw TranscriberError(description: "PRIVATE_ADMISSION") }
        })
    }
    final class Context: WhisperNativeContext {
        let probe: NativeProbe
        init(_ probe: NativeProbe) { self.probe = probe }
        deinit { probe.releases += 1 }
        var multilingual: Bool { probe.multilingual }
        func knowsLanguage(_ code: String) -> Bool { probe.known.contains(code) }
        func spokenLanguage() -> String? { probe.detections += 1; return probe.detected }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            probe.calls.append(.init(samples: samples, prompt: initialPrompt, language: language, configuration: configuration))
            probe.duringDecode?()
            return probe.outputs.count > 1 ? probe.outputs.removeFirst() : probe.outputs[0]
        }
    }
}

final class RecognitionFactoryTests: XCTestCase {
    private let audio = [Float](repeating: 0.2, count: 8000)
    private func request(_ path: String = "/owned/ggml-base.en.bin", language: String? = nil, words: [String] = []) -> RecognitionRequest {
        var settings = Settings(); settings.whisperModelPath = path; settings.language = language; settings.dictionary = words
        return RecognitionRequest(settings: settings)
    }
    func testTimedFactoryReachesProductionCParamsExactlyOnceAndOrdinaryStaysOff() async throws {
        let p = TimedNativeProbe(bytes: [Array("native".utf8)], starts: [1], ends: [2])
        let handle = try await p.factory().acquire(request: request(language: "hi", words: ["Frozen"]))
        let timed = await handle.timedFileResult(samples: audio)
        XCTAssertNotNil(timed.segments); XCTAssertEqual(timed.text, "native")
        XCTAssertTrue(handle.client is WhisperTranscriber); XCTAssertEqual(p.admissions, 1)
        XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 0)
        XCTAssertEqual(p.languages, ["hi"]); XCTAssertEqual(p.prompts, ["Frozen"]); XCTAssertEqual(p.sampleCounts, [8000])
        let params = try XCTUnwrap(p.params.first)
        XCTAssertFalse(params.no_timestamps || params.single_segment || params.token_timestamps || params.translate || params.detect_language || params.vad || params.tdrz_enable)
        XCTAssertEqual(params.offset_ms, 0); XCTAssertEqual(params.duration_ms, 0)
        XCTAssertEqual(params.max_len, 0); XCTAssertEqual(params.max_tokens, 0)
        XCTAssertNil(params.encoder_begin_callback); XCTAssertNil(params.encoder_begin_callback_user_data)
        XCTAssertGreaterThan(params.temperature_inc, 0); XCTAssertEqual(params.audio_ctx, 0)
        XCTAssertFalse(params.print_progress || params.print_realtime || params.print_special || params.print_timestamps)
        let ordinary = await handle.finalResult(samples: audio, window: nil, rawOnly: true)
        XCTAssertEqual(ordinary.text, "native"); XCTAssertNil(ordinary.segments)
        XCTAssertEqual(p.calls, 2); XCTAssertTrue(p.params[1].no_timestamps); XCTAssertFalse(p.params[1].vad)
    }
    func testTimedLanguageRefusalsHaveConnectedOrdinaryAutoPositiveAndEnglishOnlyOverride() async throws {
        for language in [nil, "invalid"] as [String?] {
            let p = TimedNativeProbe(bytes: [Array("native".utf8)], starts: [0], ends: [1])
            let handle = try await p.factory().acquire(request: request(language: language))
            let result = await handle.timedFileResult(samples: audio)
            XCTAssertNil(result.text); XCTAssertNil(result.segments); XCTAssertEqual(p.calls, 0); XCTAssertEqual(p.probes, 0)
            let ordinary = await handle.finalResult(samples: audio, window: nil, rawOnly: true)
            XCTAssertEqual(ordinary.text, "native"); XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 1)
        }
        let p = TimedNativeProbe(bytes: [Array("English".utf8)], starts: [0], ends: [1]); p.multilingual = false
        let handle = try await p.factory().acquire(request: request(language: "invalid"))
        let result = await handle.timedFileResult(samples: audio)
        XCTAssertNotNil(result.segments); XCTAssertEqual(p.languages, ["en"]); XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 0)
    }
    func testTimedExactForcedOffPredicateAndUnsupportedContextNeverFallThrough() async throws {
        for (layers, vocab, accepted) in [(Int32(2), Int32(51_865), false), (2, 51_866, true), (3, 51_865, true)] {
            let p = TimedNativeProbe(bytes: [Array("native".utf8)], starts: [0], ends: [1]); p.layers = layers; p.vocab = vocab
            let handle = try await p.factory().acquire(request: request(language: "hi"))
            let result = await handle.timedFileResult(samples: audio)
            XCTAssertEqual(result.segments != nil, accepted); XCTAssertEqual(p.calls, accepted ? 1 : 0)
            XCTAssertEqual(p.probes, 0)
        }
        let p = NativeProbe(), handle = try await p.factory().acquire(request: request(language: "hi"))
        let refused = await handle.timedFileResult(samples: audio)
        XCTAssertNil(refused.text); XCTAssertNil(refused.segments); XCTAssertTrue(p.calls.isEmpty)
        let ordinary = await handle.finalResult(samples: audio, window: nil, rawOnly: true)
        XCTAssertEqual(ordinary.text, "transcript"); XCTAssertEqual(p.calls.count, 1)
    }
    func testTimedStringOnlyClientsDoNotRunCompatibilityOrUnsupportedBackend() async throws {
        final class StringOnly: RecognitionClient {
            let capabilities: RecognitionCapabilities
            var calls = 0
            init(_ capabilities: RecognitionCapabilities) { self.capabilities = capabilities }
            func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
                calls += 1; return "connected"
            }
        }
        for capabilities in [RecognitionCapabilities(), .appleSpeech, .parakeet] {
            let client = StringOnly(capabilities)
            let handle = try RecognitionHandle(request: request(language: "hi")) { _ in client }
            let refused = await handle.timedFileResult(samples: audio)
            XCTAssertNil(refused.text); XCTAssertEqual(client.calls, 0)
            let ordinary = await handle.finalResult(samples: audio, window: nil, rawOnly: true)
            XCTAssertEqual(ordinary.text, "connected"); XCTAssertEqual(client.calls, 1)
        }
    }
    func testDefaultFactoryReachesRealWhisperAdapterWithInjectedNativeConstructor() async throws {
        let probe = NativeProbe(); probe.multilingual = false
        probe.outputs = [.init(status: 0, segments: ["  Hello.", " [BLANK_AUDIO] \n"])]
        var factory = probe.factory(); factory.directory = ModelCatalog.directory
        let request = RecognitionRequest(settings: Settings())
        let handle = try await factory.acquire(request: request)
        XCTAssertTrue(handle.client is WhisperTranscriber)
        XCTAssertEqual(request.selection, .whisper(localPath: ModelCatalog.path(for: ModelCatalog.default)))
        XCTAssertEqual(probe.constructions.map(\.0), [request.modelPath])
        XCTAssertEqual(probe.constructions.map(\.1), [.nativeDefaults])
        let result = await handle.recognize(audio, pass: .fullFinal)
        XCTAssertEqual(result.native, .completed(.init(text: "Hello.")))
        XCTAssertEqual(probe.calls[0].samples, audio); XCTAssertEqual(probe.calls[0].language, "en")
        let params = probe.calls[0].configuration
        XCTAssertTrue(params.greedySampling && params.noTimestamps && params.nativeTemperatureFallback && params.nativeAudioContext)
        XCTAssertFalse(params.printProgress || params.printRealtime || params.printSpecial)
        XCTAssertEqual(params.threads, Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))))
        let caps = handle.client.capabilities
        XCTAssertEqual(caps.modelLanguages, .englishOnly)
        XCTAssertEqual(caps.sampleRate, 16000); XCTAssertEqual(caps.channels, 1); XCTAssertTrue(caps.float32)
        XCTAssertTrue(caps.batchDecode && caps.manualTextPrompt && caps.cooperativeDecodeAbort)
        XCTAssertFalse(caps.cancellableConstruction || caps.nativeIncrementalStream || caps.acousticEnrollment || caps.wordTiming || caps.confidence || caps.alternatives)
    }
    func testOwnedCatalogIdentityAndUnknownCustomNeverCrossAcquisitionReuse() async throws {
        let probe = NativeProbe(), factory = probe.factory()
        let owned = try await factory.acquire(request: request())
        let borrowed = try await factory.acquire(request: request(), resident: owned.resident)
        XCTAssertEqual(owned.identity, borrowed.identity); XCTAssertEqual(owned.instance, borrowed.instance)
        XCTAssertTrue(owned.client === borrowed.client); XCTAssertEqual(probe.constructions.count, 1)
        let customRequest = request("/elsewhere/ggml-base.en.bin")
        let custom = try await factory.acquire(request: customRequest, resident: owned.resident)
        let next = try await factory.acquire(request: customRequest, resident: custom.resident)
        XCTAssertEqual(custom.identity?.artifact, .customRevisionUnknown)
        XCTAssertFalse(custom.identity!.reusable); XCTAssertNotEqual(custom.identity, next.identity)
        XCTAssertFalse(custom.client === next.client)
        recognitionAssertEqual(await custom.recognize(audio, pass: .fullFinal).instance, custom.instance)
        recognitionAssertEqual(await custom.recognize(audio, pass: .command).instance, custom.instance)
        XCTAssertEqual(probe.constructions.count, 3)
    }
    func testSamePathChangedArtifactRuntimeAdapterComputeCannotBorrowOldResident() async throws {
        let probe = NativeProbe(), factory = probe.factory()
        var handle: RecognitionHandle? = try await factory.acquire(request: request())
        var old: RecognitionResident? = handle!.resident
        handle = nil
        probe.generation = .init(bytes: 9, modified: 2)
        let changed = try await factory.acquire(request: request(), resident: old)
        XCTAssertFalse(changed.client === old!.client); XCTAssertEqual(probe.releases, 0)
        old = nil; XCTAssertEqual(probe.releases, 1)
        for runtime in [
            RecognitionRuntime(nativeVersion: "new", buildScope: "private-build"),
            RecognitionRuntime(nativeVersion: "native-private-version", buildScope: "new"),
            RecognitionRuntime(nativeVersion: "native-private-version", buildScope: "private-build", adapterRevision: 2),
            RecognitionRuntime(nativeVersion: "native-private-version", buildScope: "private-build", compute: .init(defaultsRevision: 2))
        ] {
            probe.implementation = runtime
            let newer = try await factory.acquire(request: request(), resident: changed.resident)
            XCTAssertNotEqual(newer.identity, changed.identity); XCTAssertFalse(newer.client === changed.client)
        }
        var changedPin = factory
        changedPin.catalog = [.init(id: "base.en", displayName: "fixture", bytes: 9, sha256: "different-pin")]
        let newArtifact = try await changedPin.acquire(request: request(), resident: changed.resident)
        XCTAssertNotEqual(newArtifact.identity?.artifact, changed.identity?.artifact)
    }
    func testAdmissionBeforeReuseReadOnlyRefusalAndChangedDuringConstructorRelease() async throws {
        let probe = NativeProbe(), factory = probe.factory(), request = request()
        let owner = try await factory.acquire(request: request)
        probe.refuseAdmission = true
        await recognitionAssertThrows(try await factory.acquire(request: request, resident: owner.resident, policy: .readOnlyCatalog))
        XCTAssertEqual(probe.constructions.count, 1); XCTAssertEqual(probe.admissions, 2)
        probe.refuseAdmission = false
        await recognitionAssertThrows(try await factory.acquire(request: self.request("/custom/ggml-base.en.bin"), policy: .readOnlyCatalog))
        probe.duringConstruct = { probe.generation = .init(bytes: 9, modified: 4) }
        await recognitionAssertThrows(try await factory.acquire(request: request))
        XCTAssertEqual(probe.releases, 1)
        probe.duringConstruct = nil; probe.failConstruct = true
        await recognitionAssertThrows(try await factory.acquire(request: request))
        XCTAssertEqual(probe.constructions.count, 3) // no substitute/default construction
    }
    func testRealWhisperEnglishOnlyAndPinnedNeverClaimDetectedLanguage() async throws {
        for (multilingual, pin, expected) in [(false, "hi", "en"), (true, "hi", "hi")] {
            let probe = NativeProbe(); probe.multilingual = multilingual; probe.detected = "es"
            let handle = try await probe.factory().acquire(request: request(language: pin))
            recognitionAssertEqual(await handle.recognize(audio, pass: .command).native, .completed(.init(text: "transcript")))
            XCTAssertEqual(probe.calls.map(\.language), [expected]); XCTAssertEqual(probe.detections, 0)
        }
    }
    func testRealWhisperAutoInvalidPinDetectionRetryAndExplicitAutoIgnoresMutablePin() async throws {
        for pin in [nil, "invalid-code"] as [String?] {
            let probe = NativeProbe(); probe.detected = "hi"
            probe.outputs = [.init(status: 0, segments: ["first"]), .init(status: 0, segments: ["हिन्दी"])]
            let handle = try await probe.factory().acquire(request: request(language: pin))
            (handle.client as? WhisperTranscriber)?.language = "es"
            recognitionAssertEqual(await handle.recognize(audio, pass: .fullFinal).native, .completed(.init(text: "हिन्दी", detectedLanguage: "hi")))
            XCTAssertEqual(probe.calls.map(\.language), ["en", "hi"])
            _ = await handle.recognize(audio, pass: .streamTail("prefix"))
            XCTAssertEqual(probe.calls.last?.language, "hi")
        }
        for segments in [[], ["[BLANK_AUDIO]"]] as [[String]] {
            let probe = NativeProbe(); probe.detected = "hi"; probe.outputs = [.init(status: 0, segments: segments)]
            let handle = try await probe.factory().acquire(request: request())
            recognitionAssertEqual(await handle.recognize(audio, pass: .fullFinal).native, .completed(.init(text: "")))
            XCTAssertEqual(probe.calls.count, 1); XCTAssertEqual(probe.detections, 0)
        }
        let probe = NativeProbe(), handle = try await probe.factory().acquire(request: request())
        recognitionAssertEqual(await handle.recognize(audio, pass: .fullFinal).native, .completed(.init(text: "transcript")))
        XCTAssertEqual(probe.calls.count, 1) // detection unavailable: no invented language
    }
    func testNativeSuccessEmptyFailureObservedAbortAndLateSuccessPrecedence() async throws {
        let probe = NativeProbe(), handle = try await probe.factory().acquire(request: request())
        var canceled = true
        recognitionAssertEqual(await handle.recognize(audio, pass: .command, shouldAbort: { canceled }).native, .canceled)
        XCTAssertTrue(probe.calls.isEmpty)
        canceled = false; probe.outputs = [.init(status: 0)]
        recognitionAssertEqual(await handle.recognize(audio, pass: .command).native, .completed(.init(text: "")))
        recognitionAssertNil(await handle.finalResult(samples: audio, window: nil).text)
        probe.outputs = [.init(status: 7)]
        recognitionAssertEqual(await handle.recognize(audio, pass: .command).native, .failed(.nativeDecode))
        probe.outputs = [.init(status: 7, abortObserved: true)]
        recognitionAssertEqual(await handle.recognize(audio, pass: .command).native, .canceled)
        probe.outputs = [.init(status: 0, segments: ["late private result"])]
        probe.duringDecode = { canceled = true }
        let late = await handle.recognize(audio, pass: .command, shouldAbort: { canceled })
        XCTAssertEqual(late.native, .completed(.init(text: "late private result")))
        XCTAssertTrue(late.canceled); XCTAssertNil(late.text)
        canceled = false; probe.outputs = [.init(status: 3)]
        let failedLate = await handle.recognize(audio, pass: .command, shouldAbort: { canceled })
        XCTAssertEqual(failedLate.native, .failed(.nativeDecode)); XCTAssertTrue(failedLate.canceled); XCTAssertNil(failedLate.text)
    }
    func testWindowOwnershipFailedTailProvenanceAndForeignRecomputeOriginalAudio() async throws {
        let probe = NativeProbe(), factory = probe.factory(), request = request(words: ["Manual"])
        let handle = try await factory.acquire(request: request)
        let head = await handle.recognize(Array(audio[..<6500]), pass: .streamHead(""), sampleRange: 0..<6500)
        XCTAssertEqual(head.text, "transcript")
        let window = handle.window(confirmedText: "confirmed", cutSample: 1000)
        probe.outputs = [.init(status: 4)]
        let final = await handle.finalResult(samples: audio, window: window)
        XCTAssertEqual(final.text, "confirmed")
        guard case .assembled(let ownership, let confirmed, let tail, let skipped) = final.provenance else { return XCTFail("Expected assembled evidence") }
        XCTAssertEqual(ownership.identity, handle.identity); XCTAssertEqual(ownership.capture, handle.capture)
        XCTAssertEqual(confirmed, 0..<1000); XCTAssertEqual(tail?.native, .failed(.nativeDecode)); XCTAssertNil(skipped)
        XCTAssertEqual(tail?.sampleRange, 1000..<8000)
        XCTAssertEqual(probe.calls.last?.prompt, "Manual confirmed")
        recognitionAssertNil(await handle.recognize(audio, pass: .streamHead("confirmed")).text) // failed head cannot advance
        let skippedTail = await handle.finalResult(samples: audio, window: handle.window(confirmedText: "confirmed", cutSample: 8000))
        XCTAssertEqual(skippedTail.text, "confirmed")
        guard case .assembled(_, _, nil, .minimumDuration?) = skippedTail.provenance else { return XCTFail("Expected skipped tail") }
        probe.outputs = [.init(status: 0, segments: ["fresh"])]
        let otherCapture = try await factory.acquire(request: request, resident: handle.resident)
        XCTAssertEqual(otherCapture.instance, handle.instance); XCTAssertNotEqual(otherCapture.capture, handle.capture)
        for other in [otherCapture, try await factory.acquire(request: request)] {
            recognitionAssertEqual(await other.finalResult(samples: audio, window: window).text, "fresh")
            XCTAssertEqual(probe.calls.last?.samples.count, 8000); XCTAssertEqual(probe.calls.last?.prompt, "Manual")
        }
        recognitionAssertEqual(await handle.finalResult(samples: audio, window: .init(confirmedText: "FOREIGN", cutSample: 2000)).text, "fresh")
        XCTAssertEqual(probe.calls.last?.samples.count, 8000)
        recognitionAssertEqual(await handle.finalResult(samples: audio, window: window, rawOnly: true).text, "fresh")
        XCTAssertEqual(probe.calls.last?.prompt, "Manual")
    }
    func testPromptBudgetsManualOrderAndLegacyProjections() async throws {
        let probe = NativeProbe(), handle = try await probe.factory().acquire(request: request(words: ["Profile", "Global", "profile", String(repeating: "界", count: 500)]))
        _ = await handle.recognize(audio, pass: .command)
        XCTAssertEqual(probe.calls.last?.prompt, "Profile, Global")
        _ = await handle.recognize(audio, pass: .streamTail(String(repeating: "界", count: 1000)))
        XCTAssertLessThanOrEqual(probe.calls.last!.prompt!.utf8.count, 2048 + 801)
        XCTAssertTrue(probe.calls.last!.prompt!.hasPrefix("Profile, Global "))
        let before = probe.calls.count
        recognitionAssertEqual(await handle.commandResult(samples: []).text, "")
        recognitionAssertNil(await handle.finalResult(samples: [], window: nil).text)
        recognitionAssertNil(await handle.finalResult(samples: Array(repeating: 0, count: 8000), window: nil).text)
        XCTAssertEqual(probe.calls.count, before)
        probe.outputs = [.init(status: 0, segments: ["  raw  \n"])]
        recognitionAssertEqual(await handle.finalResult(samples: audio, window: nil).text, "raw")
        probe.outputs = [.init(status: 0)]
        recognitionAssertEqual(await handle.commandResult(samples: audio).text, "")
        recognitionAssertNil(await handle.finalResult(samples: audio, window: nil).text)
    }
    func testProductionProcessingFinalStreamCommandAndPipelineUseRealAdapter() async throws {
        let probe = NativeProbe(), handle = try await probe.factory().acquire(request: request(language: "hi", words: ["frozen"]))
        let operation = PendingOperation(name: "foundation")
        var order: [String] = []
        await DictationProcessing.final(operation: operation, samples: audio, window: nil, prepare: { order.append("prepare"); return handle },
            recognized: { owner, raw in
                order.append("recognized"); XCTAssertEqual(owner.identity, handle.identity); XCTAssertEqual(raw, "transcript"); return raw
            }, clean: { raw in order.append("clean"); return (raw + " clean", nil) },
            completed: { raw, text, _ in order.append("complete"); XCTAssertEqual(raw, "transcript"); XCTAssertEqual(text, "transcript clean") })
        XCTAssertEqual(order, ["prepare", "recognized", "clean", "complete"])
        let head = await DictationProcessing.stream(operation: operation, handle: handle, samples: audio,
            pass: .streamHead("prefix"), sampleRange: 0..<8000, capturing: { true })
        XCTAssertEqual(head, "transcript")
        let command = await DictationProcessing.command(operation: operation, handle: handle, samples: audio)
        XCTAssertEqual(command, "transcript")
        let pipeline = Pipeline(transcribe: { pcm, prompt in await handle.recognize(pcm, pass: .fullFinal, initialPrompt: prompt).text },
            cleanup: { text, _ in text }, settings: { Settings() }, frontBundleID: { nil })
        recognitionAssertEqual(await pipeline.transcript(samples: audio), "transcript")
        XCTAssertTrue(probe.calls.allSatisfy { $0.language == "hi" })
        XCTAssertEqual(probe.calls.map(\.prompt), ["frozen", "frozen prefix", "frozen", "frozen"])
    }
    func testNoncooperativeConstructionCancellationKeepsSerialExitAndReleasesOnce() async throws {
        let probe = NativeProbe(), entered = expectation(description: "construct entered"), exit = DispatchSemaphore(value: 0)
        let operation = PendingOperation(name: "held constructor"), next = PendingOperation(name: "next capture")
        probe.duringConstruct = { entered.fulfill(); exit.wait() }
        let factory = probe.factory(), request = request()
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            do { _ = try await factory.acquire(request: request, shouldAbort: { operation.shouldAbort }); XCTFail("Canceled construction acquired a handle") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [entered], timeout: 3)
        operation.revoke(); operation.requestAbort()
        let after = expectation(description: "next acquisition after actual exit")
        let second = PendingOperationQueue.enqueue(previous: first, operation: next, completes: true) {
            XCTAssertEqual(probe.releases, 1)
            probe.duringConstruct = nil
            let handle = try! await factory.acquire(request: request)
            recognitionAssertEqual(await handle.finalResult(samples: self.audio, window: nil).text, "transcript")
            after.fulfill()
        }
        XCTAssertEqual(probe.constructions.count, 1); XCTAssertEqual(probe.releases, 0)
        exit.signal(); await second.value
        await fulfillment(of: [after], timeout: 3)
        XCTAssertEqual(probe.releases, 2)
    }
    func testNoncooperativeDecodeRetainsOldContextThroughCancelNewModelAndQueuedUnload() async throws {
        let probe = NativeProbe(), entered = expectation(description: "decode entered"), exit = DispatchSemaphore(value: 0)
        probe.duringDecode = { entered.fulfill(); exit.wait() }
        let factory = probe.factory(), request = request(), operation = PendingOperation(name: "old capture")
        var owner: RecognitionResident? = try await factory.acquire(request: request).resident
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) { [owner] in
            let handle = try! await factory.acquire(request: request, resident: owner)
            let result = await handle.recognize(self.audio, pass: .fullFinal, shouldAbort: { operation.shouldAbort })
            XCTAssertTrue(result.canceled); XCTAssertNotNil(result.native.text); XCTAssertNil(result.text)
        }
        await fulfillment(of: [entered], timeout: 3)
        owner = nil; operation.revoke(); operation.requestAbort()
        XCTAssertEqual(probe.releases, 0)
        let second = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "new"), completes: true) {
            XCTAssertEqual(probe.releases, 1)
            probe.duringDecode = nil
            let replacement = try! await factory.acquire(request: self.request("/owned/ggml-small.en-q5_1.bin"))
            recognitionAssertEqual(await replacement.finalResult(samples: self.audio, window: nil).text, "transcript")
        }
        XCTAssertEqual(probe.constructions.count, 1)
        exit.signal(); await second.value
        XCTAssertEqual(probe.releases, 2) // queued unload/last borrow after real exit
    }
    func testEvalActualASREntryReleasesAndOfflineDoesNotEvaluateRequestOrFactory() async throws {
        let probe = NativeProbe(), eval = EvalRecognition()
        var requests = 0
        try await eval.acquire(needsASR: false, request: { requests += 1; return self.request() }, factory: probe.factory())
        XCTAssertEqual(requests, 0); XCTAssertEqual(probe.admissions, 0); XCTAssertTrue(probe.constructions.isEmpty)
        try await eval.acquire(needsASR: true, request: { requests += 1; return self.request() }, factory: probe.factory())
        recognitionAssertEqual(await eval.transcribe(audio, prompt: "fixture"), "transcript")
        XCTAssertEqual(probe.calls.last?.prompt, "fixture")
        probe.outputs = [.init(status: 0)]; recognitionAssertEqual(await eval.transcribe(audio, prompt: nil), "")
        probe.outputs = [.init(status: 1)]; recognitionAssertNil(await eval.transcribe(audio, prompt: nil))
        XCTAssertEqual(probe.releases, 0); eval.release(); XCTAssertEqual(probe.releases, 1)
        recognitionAssertNil(await eval.transcribe(audio, prompt: nil))
    }
    func testReadOnlyInstalledAdmissionUsesOwnedMetadataCacheWithoutWritingOrHashing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4b1-metadata-\(UUID())")
        func record(_ action: String) throws {
            guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
        }
        try record("created")
        defer { try? FileManager.default.removeItem(at: root); try? record("removed") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ModelCatalog.Model(id: "base.en", displayName: "tiny fixture", bytes: 8, sha256: "expected fixture pin")
        let file = root.appendingPathComponent(model.filename), cacheURL = root.appendingPathComponent("verified.json")
        try Data("12345678".utf8).write(to: file)
        let cache = VerifiedCache(url: cacheURL); cache.record(file)
        let before = try Data(contentsOf: cacheURL)
        let probe = NativeProbe(); var factory = probe.factory()
        factory.directory = root; factory.catalog = [model]; factory.metadata = RecognitionFileGeneration.observe
        factory.admit = { path, policy in
            try RecognitionFactory.admitInstalled(path, policy, directory: root, catalog: [model], cache: cache)
        }
        let req = request(file.path)
        let handle = try await factory.acquire(request: req, policy: .readOnlyCatalog)
        let borrowed = try await factory.acquire(request: req, resident: handle.resident, policy: .readOnlyCatalog)
        XCTAssertTrue(borrowed.client === handle.client); XCTAssertEqual(probe.constructions.count, 1)
        XCTAssertEqual(try Data(contentsOf: cacheURL), before)
        try Data("different bytes".utf8).write(to: file)
        await recognitionAssertThrows(try await factory.acquire(request: req, resident: handle.resident, policy: .readOnlyCatalog))
        XCTAssertEqual(probe.constructions.count, 1); XCTAssertEqual(try Data(contentsOf: cacheURL), before)
        await recognitionAssertThrows(try await factory.acquire(request: request(root.appendingPathComponent("missing.bin").path), policy: .readOnlyCatalog))
    }
    func testEvalExecutableOfflineExitsPrecedeFactorySettingsAndCredentials() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/parla-eval/main.swift"))
        let engine = try XCTUnwrap(source.range(of: "// MARK: - Engines"))
        let offline = String(source[..<engine.lowerBound])
        XCTAssertFalse(offline.contains(".acquire(needsASR:")); XCTAssertFalse(offline.contains("SettingsStore("))
        XCTAssertFalse(offline.contains(".migrateCredentials(")); XCTAssertFalse(offline.contains("WhisperTranscriber(modelPath:"))
        for branch in [#"if args.contains("corpus-check")"#, #"if args.contains("--self-check")"#, "if mode == .compare", "if mode == .qualityCheck", "if mode == .verify"] {
            XCTAssertTrue(offline.contains(branch), branch)
        }
        XCTAssertTrue(source.contains("transcriber?.release()\n    transcriber = nil"))
        XCTAssertTrue(source.contains("if needsASR {"))
        XCTAssertTrue(source.contains("try await transcriber?.acquire(needsASR: true"))
        XCTAssertTrue(source.contains("transcriber?.transcribe(samples, prompt: prompt)"))
    }
    func testDiagnosticConsumerExportsFiniteEvidenceWithoutPrivateCanaries() async throws {
        let probe = NativeProbe(), store = DiagnosticStore(), operation = store.start(id: UUID(), origin: .dictation)
        let handle = try await probe.factory().acquire(request: request("/PRIVATE_PATH/ggml-base.en.bin", language: "PRIVATE_LOCALE", words: ["PRIVATE_WORD"]), diagnostics: operation)
        probe.outputs = [.init(status: 0, segments: ["PRIVATE_TRANSCRIPT"])]
        _ = await handle.finalResult(samples: audio, window: nil, diagnostics: operation)
        let data = try store.snapshot().encoded(), text = String(decoding: data, as: UTF8.self)
        for canary in ["PRIVATE", "native-private-version", "private-build", "PRIVATE_ERROR", "ggml-base"] { XCTAssertFalse(text.contains(canary)) }
        let record = try XCTUnwrap(store.snapshot().records.first)
        XCTAssertEqual(record.recognition?.evidence, .customUnknown)
        XCTAssertEqual(record.recognition?.modelLanguages, .multilingual)
        XCTAssertEqual(record.recognition?.nativeOutcome, .completed)
        XCTAssertEqual(record.resolvedASR, .unavailable)
        probe.outputs = [.init(status: 4)]
        _ = await handle.finalResult(samples: audio, window: handle.window(confirmedText: "PRIVATE_PREFIX", cutSample: 1000), diagnostics: operation)
        XCTAssertEqual(store.snapshot().records.first?.recognition?.assembly, .failedTail)
    }
}
