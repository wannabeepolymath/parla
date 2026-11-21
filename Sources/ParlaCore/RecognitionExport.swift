import Foundation

/// One recognition result as `parla.recognition.v1` JSON, for editor integrations and reproducible
/// diagnosis. Separate from `TranscriptExport`, which keeps its smaller history boundary.
/// Unknown stays null: no digest is computed, no timestamps, speakers or words are synthesized.
/// Never includes the model path, build scope, operation/capture UUIDs, prompts, settings or diagnostics.
public enum RecognitionExport {
    public enum Refusal: Error { case canceled, skipped, noText, limit }
    public static let maximumBytes = SubtitleExport.maximumBytes
    public static let schema = "parla.recognition.v1"

    public static func encoded(result: RecognitionFinalResult, requestedLanguage: String?,
                               cleanedText: String? = nil) throws -> Data {
        try encoded(result: result, requestedLanguage: requestedLanguage, cleanedText: cleanedText, maximumBytes: maximumBytes)
    }

    static func encoded(result: RecognitionFinalResult, requestedLanguage: String?, cleanedText: String?,
                        maximumBytes: Int) throws -> Data {
        let pass: RecognitionPassResult?, passRange: Range<Int>?
        switch result.provenance {
        case .canceled: throw Refusal.canceled
        case .skipped: throw Refusal.skipped
        case .pass(let p): pass = p; passRange = p.sampleRange
        // The tail's range covers only the tail, not the assembled rawText: source stays null.
        case .assembled(_, _, let tail, _): pass = tail; passRange = nil
        }
        guard let text = result.text else { throw Refusal.noText }
        let identity = pass?.identity
        var detected: String?
        if case .completed(let payload)? = pass?.native { detected = payload.detectedLanguage }
        let segments = result.segments
        let sampleCount = segments?.sourceSampleCount ?? passRange?.count

        // ponytail: JSONSerialization, as the spec allows; NSNull keeps every unknown key explicit.
        var object: [String: Any] = [
            "schema": schema,
            "rawText": text,
            "cleanedText": orNull(cleanedText),
            "engine": orNull(identity?.engine.rawValue),
            "model": orNull(identity.map { model($0.artifact) }),
            "runtime": orNull(identity?.runtime.map { ["nativeVersion": $0.nativeVersion] }),
            "language": ["requested": orNull(requestedLanguage), "detected": orNull(detected)],
            "source": orNull(sampleCount.map { ["sampleRate": 16_000, "sampleCount": $0] }),
            "segments": NSNull(),
            "words": NSNull(),
        ]
        if let segments {
            object["segments"] = [
                "clock": segments.clock == .whisper191PCM10ms ? "whisper-1.9.1-pcm-10ms" : "unknown",
                "cues": segments.cues.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
            ] as [String: Any]
        }
        // Heuristic estimates; `estimate: true` is the machine-readable form of that.
        if let words = result.words {
            object["words"] = [
                "clock": "whisper-1.9.1-pcm-10ms", "estimate": true,
                "items": words.words.map { ["text": $0.text, "start": $0.start, "end": $0.end, "segment": $0.segment] as [String: Any] },
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw Refusal.limit }
        return data
    }

    private static func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    /// `expectedSHA256` is the catalog pin admission accepted, not a hash of the file.
    private static func model(_ artifact: RecognitionArtifact) -> [String: Any] {
        switch artifact {
        case .admittedCatalog(let id, let sha, _): return ["kind": "catalog", "id": id, "expectedSHA256": sha]
        case .customRevisionUnknown: return ["kind": "custom", "id": NSNull(), "expectedSHA256": NSNull()]
        case .systemAssetsRevisionUnknown: return ["kind": "system", "id": NSNull(), "expectedSHA256": NSNull()]
        case .parakeet: return ["kind": "parakeet", "id": NSNull(), "expectedSHA256": NSNull()]
        }
    }

    public static func suggestedFilename(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return "parla-recognition-\(formatter.string(from: now)).json"
    }
}
