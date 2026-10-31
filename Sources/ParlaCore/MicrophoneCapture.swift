import AVFoundation

/// Local UI only. Never part of DiagnosticRecord, settings, logging or export.
public struct MicrophoneRoute: Equatable {
    public let name: String?
    public let fallback: Bool?
    public init(name: String? = nil, fallback: Bool? = nil) { self.name = name; self.fallback = fallback }
}

/// Injected engine seam. The production recorder uses its existing AUHAL engine;
/// fixtures supply PCM through the very same resampler/tap path without opening a device.
public protocol MicrophoneCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var route: MicrophoneRoute { get }
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void,
               changed: @escaping () -> Void) throws
    func stop()
}

public struct MicrophoneCaptureSnapshot {
    public let facts: CaptureDiagnosticState?
    public let route: MicrophoneRoute
    public let sampleCount: Int
    public let level: Float
    public let hasSignal: Bool
    public let conversionFailures: Int
    public let ended: AudioRecorder.EndReason?
}

public protocol MicrophoneTestCapturing: AnyObject {
    func start(operation: UUID, lease: CaptureAdmission.Lease) throws
    func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot?
    func stop(operation: UUID) -> [Float]
    func clear(operation: UUID)
}

/// No audio copy is kept here. Stop transfers the recorder's bounded buffer.
public final class RecorderMicrophoneCapture: MicrophoneTestCapturing {
    public let recorder: AudioRecorder
    public init(recorder: AudioRecorder) { self.recorder = recorder }
    public func start(operation: UUID, lease: CaptureAdmission.Lease) throws { try recorder.startMicrophoneTest(operation: operation, lease: lease) }
    public func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot? { recorder.microphoneTestSnapshot(operation: operation) }
    public func stop(operation: UUID) -> [Float] { recorder.stopMicrophoneTest(operation: operation) }
    public func clear(operation: UUID) { recorder.clearMicrophoneTest(operation: operation) }
}


public struct GuidedCaptureResult {
    public let samples: [Float]
    public let route: MicrophoneRoute
    public let complete: Bool
    public init(samples: [Float], route: MicrophoneRoute, complete: Bool) {
        self.samples = samples; self.route = route; self.complete = complete
    }
}

public protocol GuidedTemplateCapturing: AnyObject {
    func reserve(session: UUID, lease: CaptureAdmission.Lease) throws
    func start(session: UUID, capture: UUID, lease: CaptureAdmission.Lease, inputUID: String?) throws
    func stop(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) -> GuidedCaptureResult?
    func clear(session: UUID, capture: UUID, lease: CaptureAdmission.Lease)
    func release(session: UUID, lease: CaptureAdmission.Lease)
}

/// Uses the one production recorder; never borrows the B55 or ordinary handoff.
public final class RecorderGuidedTemplateCapture: GuidedTemplateCapturing {
    public let recorder: AudioRecorder
    public init(recorder: AudioRecorder) { self.recorder = recorder }
    public func reserve(session: UUID, lease: CaptureAdmission.Lease) throws { try recorder.reserveGuidedTemplate(session: session, lease: lease) }
    public func start(session: UUID, capture: UUID, lease: CaptureAdmission.Lease, inputUID: String?) throws {
        try recorder.startGuidedTemplate(session: session, capture: capture, lease: lease, inputUID: inputUID)
    }
    public func stop(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) -> GuidedCaptureResult? {
        recorder.stopGuidedTemplate(session: session, capture: capture, lease: lease)
    }
    public func clear(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) { recorder.clearGuidedTemplate(session: session, capture: capture, lease: lease) }
    public func release(session: UUID, lease: CaptureAdmission.Lease) { recorder.releaseGuidedTemplate(session: session, lease: lease) }
}
