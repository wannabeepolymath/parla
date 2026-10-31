import Foundation

/// Bounds a canceled capture as a whole; never keeps a prefix of refused audio.
public enum CanceledCaptureLimits {
    public static func accepts(_ samples: [Float], elapsed: TimeInterval, postStartPCM: Bool = true) -> Bool {
        guard elapsed.isFinite, elapsed >= 0, elapsed <= 10, postStartPCM,
              (6400...160_000).contains(samples.count), samples.allSatisfy(\.isFinite) else { return false }
        let rms = AudioRecorder.rms(samples)
        return rms.isFinite && rms > 1e-4 && TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: rms)
    }
    public static func accepts(_ request: RecognitionRequest) -> Bool {
        request.selection.engine == .whisper && request.modelPath.utf8.count <= 4096 && (request.language?.utf8.count ?? 0) <= 64
            && request.dictionary.count <= 128
            && request.dictionary.reduce(0, { $0 + $1.utf8.count }) <= 16_384
    }
}
