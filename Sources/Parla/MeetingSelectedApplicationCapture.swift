import Foundation
import ParlaCore

/// Inert, one-attempt adapter for one frozen application incarnation. No product binder.
@MainActor final class MeetingSelectedApplicationCapture {
    struct Recording {
        let task: Task<Void,Never>
        let requestStop: () -> Void
    }
    enum Start { case notStarted, actual(Recording) }
    /// Old injected clients retain their original contract and explicitly refuse access mode.
    @MainActor struct CorePort {
        let validate: (SelectedApplicationBinding) -> Bool
        let validateContext: (SelectedApplicationBinding,MeetingAudioIngress.Context) -> Bool
        let start: (SelectedApplicationBinding,MeetingAudioIngress) -> Start
        let startMode: (SelectedApplicationBinding,MeetingAudioIngress,ApplicationAudioMode,UUID,
                        @escaping @MainActor (ApplicationAudioAccessOutcome) -> Void) -> Start
        init(validate: @escaping (SelectedApplicationBinding) -> Bool,
             validateContext: @escaping (SelectedApplicationBinding,MeetingAudioIngress.Context) -> Bool,
             start: @escaping (SelectedApplicationBinding,MeetingAudioIngress) -> Start) {
            self.validate = validate; self.validateContext = validateContext; self.start = start
            startMode = { binding,ingress,mode,_,_ in
                guard mode == .retainedRecording else { return .notStarted }
                return start(binding,ingress)
            }
        }
        init(validate: @escaping (SelectedApplicationBinding) -> Bool,
             validateContext: @escaping (SelectedApplicationBinding,MeetingAudioIngress.Context) -> Bool,
             startMode: @escaping (SelectedApplicationBinding,MeetingAudioIngress,ApplicationAudioMode,UUID,
                                  @escaping @MainActor (ApplicationAudioAccessOutcome) -> Void) -> Start) {
            self.validate = validate; self.validateContext = validateContext; self.startMode = startMode
            start = { binding,ingress in startMode(binding,ingress,.retainedRecording,UUID(),{ _ in }) }
        }
        static func live(_ capture: MeetingApplicationAudioCapture) -> Self {
            .init(validate:{ capture.validate($0) },validateContext:{ capture.validate($0,context:$1) },startMode:{ binding,ingress,mode,nonce,outcome in
                switch capture.startSelectedApplication(binding:binding,ingress:ingress,enabled:true,mode:mode,attemptNonce:nonce,outcome:outcome) {
                case .notStarted: return .notStarted
                case .actual(let recording):
                    return .actual(.init(task:recording.task,requestStop:{ recording.requestStop() }))
                }
            })
        }
    }
    private let binding: SelectedApplicationBinding, core: CorePort, enabled: Bool
    let mode: ApplicationAudioMode, attemptNonce: UUID
    private let outcome: @MainActor (ApplicationAudioAccessOutcome) -> Void
    private var attempted = false, starting = false, delivered = false
    private var expectedKey: ApplicationAudioAccessKey?, pending: ApplicationAudioAccessOutcome?
    // Retain the complete recording/stop closure. Publication is weak; resource ownership is not.
    private var recording: Recording?
    convenience init(binding: SelectedApplicationBinding, enabled: Bool = false,
                     mode: ApplicationAudioMode = .retainedRecording, attemptNonce: UUID = UUID(),
                     outcome: @escaping @MainActor (ApplicationAudioAccessOutcome) -> Void = { _ in }) {
        self.init(binding:binding,core:.live(MeetingApplicationAudioCapture()),enabled:enabled,mode:mode,attemptNonce:attemptNonce,outcome:outcome)
    }
    init(binding: SelectedApplicationBinding, core: CorePort, enabled: Bool = false,
         mode: ApplicationAudioMode = .retainedRecording, attemptNonce: UUID = UUID(),
         outcome: @escaping @MainActor (ApplicationAudioAccessOutcome) -> Void = { _ in }) {
        self.binding = binding; self.core = core; self.enabled = enabled
        self.mode = mode; self.attemptNonce = attemptNonce; self.outcome = outcome
    }
    func validate(_ selection: MeetingSession.Selection) -> Bool {
        // Pure, nonreserving: no fabricated ingress context, factories, OS checks or leases.
        enabled && selection.kind == .selectedApplication && selection.instance == binding.source &&
        selection.generation == binding.sourceGeneration && selection.label.utf8.elementsEqual(binding.label.utf8) &&
        core.validate(binding)
    }
    private func receive(_ value: ApplicationAudioAccessOutcome) {
        guard mode == .accessAttempt,!delivered,value.key == expectedKey else { return }
        if starting { if pending == nil { pending = value }; return }
        guard recording != nil else { return } // .notStarted cannot publish native evidence
        delivered = true; outcome(value)
    }
    func start(_ selection: MeetingSession.Selection, ingress: MeetingAudioIngress) -> MeetingSessionOwner.Producer {
        guard !attempted else { return .init(source:selection.instance,exit:.notStarted) }
        attempted = true // Even refusal consumes this identity; no retry or successor.
        guard validate(selection),core.validateContext(binding,ingress.context) else {
            return .init(source:selection.instance,exit:.notStarted)
        }
        expectedKey = .init(binding:binding,context:ingress.context,nonce:attemptNonce)
        starting = true
        let result = core.startMode(binding,ingress,mode,attemptNonce,{ [weak self] in self?.receive($0) })
        starting = false
        switch result {
        case .notStarted:
            pending = nil; expectedKey = nil
            return .init(source:selection.instance,exit:.notStarted)
        case .actual(let actual):
            recording = actual
            let early = pending; pending = nil
            if let early { receive(early) }
            return .init(source:selection.instance,exit:.actual(actual.task))
        }
    }
    /// Acquisition-only; the owner joins the unchanged actual task and its ingress writer.
    func requestStop() { recording?.requestStop() }
    var port: MeetingSessionOwner.SingleSourceStreamPort {
        .init(validate:{ [self] in validate($0) },start:{ [self] in start($0,ingress:$1) },requestStop:{ [self] in requestStop() })
    }
}
