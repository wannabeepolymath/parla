import Foundation
import ParlaCore

/// Inert, one-attempt adapter for one frozen application incarnation. No product binder.
@MainActor final class MeetingSelectedApplicationCapture {
    struct Recording {
        let task: Task<Void,Never>
        let requestStop: () -> Void
    }
    enum Start { case notStarted, actual(Recording) }
    /// Internal app-test seam: value validation and an actual task, never a native fake backend.
    @MainActor struct CorePort {
        let validate: (SelectedApplicationBinding) -> Bool
        let validateContext: (SelectedApplicationBinding,MeetingAudioIngress.Context) -> Bool
        let start: (SelectedApplicationBinding,MeetingAudioIngress) -> Start
        static func live(_ capture: MeetingApplicationAudioCapture) -> Self {
            .init(validate:{ capture.validate($0) },validateContext:{ capture.validate($0,context:$1) },start:{ binding,ingress in
                switch capture.startSelectedApplication(binding:binding,ingress:ingress,enabled:true) {
                case .notStarted: return .notStarted
                case .actual(let recording):
                    return .actual(.init(task:recording.task,requestStop:{ recording.requestStop() }))
                }
            })
        }
    }
    private let binding: SelectedApplicationBinding, core: CorePort, enabled: Bool
    private var attempted = false
    // Retain the complete recording/stop closure for this adapter's lifetime. No observer task
    // clears it or substitutes its own exit for Core's callback/cleanup task.
    private var recording: Recording?
    convenience init(binding: SelectedApplicationBinding, enabled: Bool = false) {
        self.init(binding:binding,core:.live(MeetingApplicationAudioCapture()),enabled:enabled)
    }
    init(binding: SelectedApplicationBinding, core: CorePort, enabled: Bool = false) {
        self.binding = binding; self.core = core; self.enabled = enabled
    }
    func validate(_ selection: MeetingSession.Selection) -> Bool {
        // Pure, nonreserving: no fabricated ingress context, factories, OS checks or leases.
        enabled && selection.kind == .selectedApplication && selection.instance == binding.source &&
        selection.generation == binding.sourceGeneration && selection.label.utf8.elementsEqual(binding.label.utf8) &&
        core.validate(binding)
    }
    func start(_ selection: MeetingSession.Selection, ingress: MeetingAudioIngress) -> MeetingSessionOwner.Producer {
        guard !attempted else { return .init(source:selection.instance,exit:.notStarted) }
        attempted = true // Even refusal consumes this identity; no retry or successor.
        guard validate(selection),core.validateContext(binding,ingress.context) else {
            return .init(source:selection.instance,exit:.notStarted)
        }
        switch core.start(binding,ingress) {
        case .notStarted: return .init(source:selection.instance,exit:.notStarted)
        case .actual(let actual):
            recording = actual
            return .init(source:selection.instance,exit:.actual(actual.task))
        }
    }
    /// Acquisition-only; the owner joins the unchanged actual task and its ingress writer.
    func requestStop() { recording?.requestStop() }
    var port: MeetingSessionOwner.SingleSourceStreamPort {
        .init(validate:{ [self] in validate($0) },start:{ [self] in start($0,ingress:$1) },requestStop:{ [self] in requestStop() })
    }
}
