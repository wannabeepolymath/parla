import XCTest
@testable import ParlaCore

final class RecognitionExportTests: XCTestCase {
    private let path = "/Users/someone/private/ggml-base.en.bin", scope = UUID(), instance = UUID()
    private let sha = String(repeating: "a", count: 64)
    private func identity(_ artifact: RecognitionArtifact) -> RecognitionIdentity {
        RecognitionIdentity(engine: .whisper, selection: .whisper(localPath: path), artifact: artifact, generation: nil,
                            runtime: RecognitionRuntime(nativeVersion: "1.9.1", buildScope: scope.uuidString), unknownRevisionScope: nil)
    }
    private func result(_ artifact: RecognitionArtifact = .admittedCatalog(id: "base.en", expectedSHA256: String(repeating: "a", count: 64), expectedBytes: 1),
                        timed: Bool = true) throws -> RecognitionFinalResult {
        let segments = timed ? try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 160_000,
                                                      cues: [.init(text: " Hello", start: 0, end: 250)]) : nil
        let pass = RecognitionPassResult(identity: identity(artifact), instance: instance, pass: .fullFinal, sampleRange: 0..<160_000,
                                         native: .completed(.init(text: "Hello", detectedLanguage: "en", segments: segments)), canceled: false)
        return RecognitionFinalResult(text: "Hello", provenance: .pass(pass))
    }
    private func decoded(_ data: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary) }

    func testCatalogResultWithSegmentsMatchesKeyForKey() throws {
        let json = try decoded(RecognitionExport.encoded(result: result(), requestedLanguage: nil))
        let expected: NSDictionary = [
            "schema": "parla.recognition.v1", "rawText": "Hello", "cleanedText": NSNull(), "engine": "whisper",
            "model": ["kind": "catalog", "id": "base.en", "expectedSHA256": sha],
            "runtime": ["nativeVersion": "1.9.1"],
            "language": ["requested": NSNull(), "detected": "en"],
            "source": ["sampleRate": 16_000, "sampleCount": 160_000],
            "segments": ["clock": "whisper-1.9.1-pcm-10ms", "cues": [["text": " Hello", "start": 0, "end": 250]]],
        ]
        XCTAssertEqual(json, expected)
    }
    func testCustomModelLeavesIdentityNullAndUntimedSegmentsAreNull() throws {
        let json = try decoded(RecognitionExport.encoded(result: result(.customRevisionUnknown, timed: false), requestedLanguage: "en"))
        XCTAssertEqual(json["model"] as? NSDictionary, ["kind": "custom", "id": NSNull(), "expectedSHA256": NSNull()])
        XCTAssertEqual(json["segments"] as? NSNull, NSNull())
        XCTAssertEqual((json["language"] as? NSDictionary)?["requested"] as? String, "en")
    }
    func testCanceledSkippedAndNilTextAreRefused() throws {
        let pass = RecognitionPassResult(identity: nil, instance: instance, pass: .fullFinal, sampleRange: nil, native: .canceled, canceled: true)
        for refused in [RecognitionFinalResult(text: "x", provenance: .canceled), RecognitionFinalResult(text: nil, provenance: .skipped(.silence)),
                        RecognitionFinalResult(text: nil, provenance: .pass(pass))] {
            XCTAssertThrowsError(try RecognitionExport.encoded(result: refused, requestedLanguage: nil))
        }
    }
    func testPrivateFieldsNeverAppear() throws {
        let text = String(decoding: try RecognitionExport.encoded(result: result(), requestedLanguage: nil), as: UTF8.self)
        for secret in [path, scope.uuidString, instance.uuidString, "ggml-base.en.bin"] { XCTAssertFalse(text.contains(secret), secret) }
    }
    func testCleanedTextIsASeparateKey() throws {
        let raw = try decoded(RecognitionExport.encoded(result: result(), requestedLanguage: nil)).mutableCopy() as! NSMutableDictionary
        let cleaned = try decoded(RecognitionExport.encoded(result: result(), requestedLanguage: nil, cleanedText: "Hello."))
        XCTAssertEqual(cleaned["cleanedText"] as? String, "Hello.")
        raw["cleanedText"] = "Hello."
        XCTAssertEqual(cleaned, raw)
    }
    func testSizeCapRefuses() throws {
        XCTAssertThrowsError(try RecognitionExport.encoded(result: result(), requestedLanguage: nil, cleanedText: nil, maximumBytes: 64))
        XCTAssertEqual(RecognitionExport.suggestedFilename(now: Date(timeIntervalSince1970: 0)), "parla-recognition-1970-01-01.json")
    }
}
