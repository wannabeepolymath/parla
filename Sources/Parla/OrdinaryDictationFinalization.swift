import Foundation
import ParlaCore

/// Ordinary origin's real storage boundary. Preview recognition receives none of
/// these ports. The observer lets isolated tests prove entry as well as writes.
final class OrdinaryDictationFinalization {
    enum Entry: Equatable { case stash, resolve }
    private let recordings: RecordingStore
    private let settings: SettingsStore
    private let entered: (Entry) -> Void
    private(set) var recording: URL?
    private var pendingShadow: DiagnosticActivityShadow?
    private var securityAdjudicated = false
    private var secureSeen = false
    private var published = false
    private var shadowPermission: ActivityShadowPermission?
    /// Uses the same start/landing/completion evidence as delivery/storage.
    func observeSecurity(secure: Bool) {
        securityAdjudicated = true
        if secure { secureSeen = true; pendingShadow = nil; shadowPermission?.revoke() }
    }
    init(recordings: RecordingStore, settings: SettingsStore, entered: @escaping (Entry) -> Void = { _ in }) {
        self.recordings = recordings; self.settings = settings; self.entered = entered
    }
    func resolve(transcript: String?, secure: Bool) {
        observeSecurity(secure: secure)
        entered(.resolve)
        recordings.resolve(recording, transcript: transcript, secure: secure)
    }
    /// This is used by AppDelegate.finish, including its ordinary storage-before-
    /// acquisition policy. All provider/history/field ports stay on this branch.
    func run<Context>(operation: PendingOperation, samples: [Float], window: StreamWindow?,
        shadow: ActivityShadowPermission? = nil, separatePreview: Bool = false,
        shadowCurrent: @MainActor () -> Bool = { false },
        analyze: ActivityShadow.Analyzer = { ActivityShadow.analyze($0, shouldAbort: $1) },
        prepare: (URL?, RecordingStore.CaptureDisposal?) async -> RecognitionHandle?,
        recognized: (RecognitionHandle, String?) async -> Context?,
        clean: (Context) async -> (text: String, failure: String?),
        completed: (Context, String, String?) async -> Void,
        drain: () async -> Void = {}) async {
        let sampleCount = samples.count // Publication captures this scalar, never PCM.
        shadowPermission = shadow
        let eligible = shadow?.operationID == operation.id && shadow?.isCurrent == true
        if eligible {
            pendingShadow = DiagnosticActivityShadow(state: .notRun, reason: .acquisitionUnavailable,
                originalSamples: sampleCount)
            pendingShadow?.actual.separatePreview = separatePreview
        }
        await DictationProcessing.final(operation: operation, samples: samples, window: window, prepare: {
            guard !operation.shouldAbort else { return nil }
            entered(.stash)
            recording = recordings.stash(samples, settings: settings)
            // Latch invalidity found by stash's mandatory refresh before prepare can reload.
            if settings.lastError != nil { shadow?.revoke() }
            let handle = await prepare(recording, recordings.captureDisposal(for: recording))
            if handle != nil, eligible, !operation.shouldAbort, shadow?.isCurrent == true, !secureSeen {
                if operation.diagnostics?.activityShadowCaptureIncomplete == true {
                    pendingShadow = DiagnosticActivityShadow(reason: .captureIncomplete,
                        originalSamples: sampleCount)
                } else {
                    // Synchronous borrow: analyzer scratch is destroyed before finalResult/ASR.
                    pendingShadow = samples.withUnsafeBufferPointer {
                        analyze($0, { operation.shouldAbort || shadow?.isCurrent != true })
                    }.validated(originalCount: sampleCount)
                }
                pendingShadow?.actual.separatePreview = separatePreview
            }
            return handle
        }, observed: { handle, result in
            guard eligible, !self.secureSeen, shadow?.isCurrent == true, self.pendingShadow != nil, self.pendingShadow?.reason != .invalidResult else { return }
            if let actual = DiagnosticActivityShadow.project(result, handle: handle,
                originalCount: sampleCount, separatePreview: separatePreview) {
                self.pendingShadow?.actual = actual
            } else {
                self.pendingShadow = DiagnosticActivityShadow(reason: .invalidResult,
                    originalSamples: sampleCount)
            }
        }, recognized: recognized, clean: clean, completed: completed)
        await MainActor.run {
            defer { self.pendingShadow = nil }
            guard !self.published, eligible, self.securityAdjudicated, !self.secureSeen,
                  !operation.shouldAbort, shadow?.isCurrent == true, shadowCurrent(),
                  let fact = self.pendingShadow else { return }
            self.published = true
            let valid = fact.validated(originalCount: sampleCount)
            operation.diagnostics?.update { $0.activityShadow = valid }
        }
        await drain()
    }
}
