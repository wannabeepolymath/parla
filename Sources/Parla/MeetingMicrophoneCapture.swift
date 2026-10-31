import Foundation
import ParlaCore

/// Inert, microphone-only Option L adapter. Product composition must opt in at an
/// explicit Start; merely constructing a recorder/adapter/port leaves native input off.
@MainActor final class MeetingMicrophoneCapture {
    private let recorder: AudioRecorder
    private let enabled: Bool
    private var current: (id: UUID, recording: MeetingMicrophoneRecording)?
    init(recorder: AudioRecorder, enabled: Bool = false) {
        self.recorder = recorder; self.enabled = enabled
    }
    func validate(_ selection: MeetingSession.Selection) -> Bool {
        // Pure and NONRESERVING. In particular, never query recorder availability or
        // device/TCC/input-source state here, and never hold a lease across store IO.
        enabled && selection.kind == .microphone && selection.generation > 0
    }
    func start(_ selection: MeetingSession.Selection, ingress: MeetingAudioIngress) -> MeetingSessionOwner.Producer {
        guard validate(selection),current == nil,
              ingress.context.source == selection.instance,ingress.context.sourceGeneration == selection.generation else {
            return .init(source:selection.instance,exit:.notStarted)
        }
        switch recorder.startMeeting(source:selection.instance,generation:selection.generation,ingress:ingress,enabled:true) {
        case .notStarted: return .init(source:selection.instance,exit:.notStarted)
        case .actual(let recording):
            let id = UUID(); current = (id,recording)
            let task = Task { @MainActor [self] in
                await recording.task.value
                if current?.id == id { current = nil }
            }
            return .init(source:selection.instance,exit:.actual(task))
        }
    }
    func requestStop() { current?.recording.requestStop() }
    var port: MeetingSessionOwner.MicrophoneStreamPort {
        .init(validate:{ [self] in validate($0) },start:{ [self] in start($0,ingress:$1) },requestStop:{ [self] in requestStop() })
    }
}
