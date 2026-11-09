import Foundation
import ParlaCore

/// Shared actual file batch; recovery retains its original defaults and disposal.
enum FileRecognitionBatch {
    struct Result {
        let raw: String
        let segments: RecognitionSegments?
        let observedIdentity: RecognitionIdentity?
    }
    static func run(request: RecognitionRequest, operation: PendingOperation,
                      samples read: () throws -> [Float], validate: () throws -> Void, active: @escaping () -> Bool,
                      authorize: () -> Bool, rawOnly: Bool = false, enter: () async throws -> Void = {}, load: (RecognitionRequest) async throws -> RecognitionHandle) async throws -> String {
        try await runResult(request: request, operation: operation, samples: read, validate: validate,
            active: active, authorize: authorize, rawOnly: rawOnly, enter: enter, load: load).raw
    }
    static func runResult(request: RecognitionRequest, operation: PendingOperation,
                          samples read: () throws -> [Float], validate: () throws -> Void, active: @escaping () -> Bool,
                          authorize: () -> Bool, rawOnly: Bool = false, timed: Bool = false,
                          enter: () async throws -> Void = {}, load: (RecognitionRequest) async throws -> RecognitionHandle) async throws -> Result {
        guard authorize() else { throw RecordingStore.Failure("Fix settings.json before transcribing.") }
        guard !timed || (rawOnly && request.selection.engine == .whisper) else {
            throw RecordingStore.Failure("Timestamps need Whisper and a 16 kHz mono WAV.")
        }
        let samples = try read()
        guard TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples)) else {
            operation.diagnostics?.update { $0.asr = samples.count < 6400 ? .minimumDuration : .silence }
            throw RecordingStore.Failure("The file is too short to transcribe.")
        }
        if request.selection.engine == .parakeet { try validate() }
        guard !operation.shouldAbort, active() else { throw CancellationError() }
        try await enter()
        if request.selection.engine == .parakeet { try validate() }
        guard authorize(), !operation.shouldAbort, active() else { throw CancellationError() }
        operation.advance(.acquiring)
        let handle = try await load(request)
        guard handle.request == request else { throw RecordingStore.Failure("Choose a speech engine in General.") }
        guard authorize() else { throw RecordingStore.Failure("Settings can’t be read. Fix settings.json and try again.") }
        try validate()
        let recognition = timed
            ? await handle.timedFileResult(samples: samples, shouldAbort: { operation.shouldAbort || !active() }, diagnostics: operation.diagnostics)
            : await handle.finalResult(samples: samples, window: nil, shouldAbort: { operation.shouldAbort || !active() }, diagnostics: operation.diagnostics, rawOnly: rawOnly)
        try validate()
        guard authorize(), !operation.shouldAbort, active() else { throw CancellationError() }
        guard let raw = recognition.text, !raw.isEmpty else { throw RecordingStore.Failure("No speech was recognized.") }
        if rawOnly, raw.utf8.count > 1_048_576 || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RecordingStore.Failure("No usable text was recognized. Choose the file again to retry.")
        }
        let observed: RecognitionIdentity?
        if case .pass(let pass) = recognition.provenance { observed = pass.identity ?? handle.identity }
        else { observed = handle.identity }
        return Result(raw: raw, segments: timed ? recognition.segments : nil, observedIdentity: observed)
    }

}
