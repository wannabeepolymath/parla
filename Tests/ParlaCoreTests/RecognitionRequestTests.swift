import XCTest
@testable import ParlaCore

final class RecognitionRequestTests: XCTestCase {
    private final class Client: RecognitionClient {
        struct Call { let samples: Int; let prompt: String?; let language: String? }
        var calls: [Call] = []
        var result: String? = "tail"
        func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
            calls.append(.init(samples: samples.count, prompt: initialPrompt, language: language))
            return shouldAbort?() == true ? nil : result
        }
    }

    private let audio = [Float](repeating: 0.1, count: 16_000)

    func testActualFinalCommandAndStreamSeamsUseFrozenRequest() async throws {
        var s = Settings(); s.whisperModelPath = "/old.bin"; s.language = "hi"; s.dictionary = ["OldName"]
        let client = Client()
        var profile = DictationProfile()
        profile.name = "Capture"; profile.target = "capture"; profile.language = "hi"
        profile.whisperModelPath = "/old.bin"; profile.dictionary = ["OldName"]
        s.profiles = [profile]
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: s, cleanupConfigured: true,
                                              recognitionDestination: .init(bundleID: "capture"))
        let handle = try RecognitionHandle(request: session.recognition) { path in
            XCTAssertEqual(path, "/old.bin"); return client
        }
        // Subsequent preference changes must not enter any old request.
        s.language = "en"; s.whisperModelPath = "/new.bin"; s.dictionary = ["NewName"]
        recognitionAssertEqual(await handle.transcribe(audio, pass: .streamHead("prefix")), "tail")
        recognitionAssertEqual(await handle.transcribe(audio, pass: .streamTail("prefix")), "tail")
        recognitionAssertEqual(await handle.finalTranscript(samples: audio, window: handle.window(confirmedText: "prefix", cutSample: 8000)), "prefix tail")
        recognitionAssertEqual(await handle.finalTranscript(samples: audio, window: nil), "tail")
        recognitionAssertEqual(await handle.commandInstruction(samples: audio), "tail")
        XCTAssertEqual(client.calls.count, 5)
        XCTAssertTrue(client.calls.allSatisfy { $0.language == "hi" && $0.prompt?.contains("OldName") == true && $0.prompt?.contains("NewName") == false })
        XCTAssertEqual(client.calls.map(\.samples), [16000, 16000, 8000, 16000, 16000])
        XCTAssertEqual(handle.request.modelPath, "/old.bin")
        XCTAssertEqual(client.calls.suffix(2).map(\.prompt), ["OldName", "OldName"])
    }

    func testQueuedOldAndNewSessionsKeepTheirOwnModelAndExplicitAuto() async throws {
        var s = Settings(); s.whisperModelPath = "/old.bin"; s.language = "hi"
        let oldClient = Client(), newClient = Client()
        let old = try RecognitionHandle(request: RecognitionRequest(settings: s), residentPath: "/old.bin", resident: oldClient) { _ in
            XCTFail("resident should be retained"); return newClient
        }
        s.whisperModelPath = "/new.bin"; s.language = nil
        let next = try RecognitionHandle(request: RecognitionRequest(settings: s), residentPath: "/old.bin", resident: oldClient) { path in
            XCTAssertEqual(path, "/new.bin"); return newClient
        }
        let audio = audio
        let first = Task { _ = await old.commandInstruction(samples: audio) }
        let second = Task { await first.value; _ = await next.finalTranscript(samples: audio, window: nil) }
        let third = Task { await second.value; _ = await old.finalTranscript(samples: audio, window: nil) }
        await third.value
        XCTAssertEqual(oldClient.calls.map(\.language), ["hi", "hi"])
        XCTAssertEqual(newClient.calls.count, 1); XCTAssertNil(newClient.calls.first?.language)
        XCTAssertEqual(old.request.modelPath, "/old.bin"); XCTAssertEqual(next.request.modelPath, "/new.bin")
    }

    func testUnavailableModelNeverFallsBackToResidentAndSilenceDoesNotDecode() async throws {
        let client = Client()
        var s = Settings(); s.whisperModelPath = "/missing.bin"
        XCTAssertThrowsError(try RecognitionHandle(request: RecognitionRequest(settings: s), residentPath: "/global.bin", resident: client) { _ in
            throw TranscriberError(description: "missing")
        })
        XCTAssertTrue(client.calls.isEmpty)
        let handle = try RecognitionHandle(request: RecognitionRequest(settings: s)) { _ in client }
        recognitionAssertNil(await handle.finalTranscript(samples: [Float](repeating: 0, count: 16000), window: nil))
        recognitionAssertEqual(await handle.commandInstruction(samples: []), "")
        recognitionAssertEqual(await handle.finalTranscript(samples: [], window: handle.window(confirmedText: "confirmed", cutSample: 0)), "confirmed")
        XCTAssertTrue(client.calls.isEmpty)
        client.result = nil
        recognitionAssertEqual(await handle.finalTranscript(samples: audio, window: handle.window(confirmedText: "confirmed", cutSample: 0)), "confirmed")
    }
}
