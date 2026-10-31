import ParlaCore

/// Production main input adapter. No second recorder/reducer/processing queue.
/// Each mouse edge retains its consumed press identity through the native hop;
/// the host alone binds it to an actually accepted operation and generation.
@MainActor final class DictationInputRouter {
    private let host: DictationInvocationHost
    private let prepare: () -> DictationSession.Event?
    private let secureRefused: () -> Void
    init(host: DictationInvocationHost, prepare: @escaping () -> DictationSession.Event?,
         secureRefused: @escaping () -> Void) {
        self.host = host; self.prepare = prepare; self.secureRefused = secureRefused
    }
    func mouse(_ edge: MouseInputEdge) {
        switch edge {
        case .down(let press): host.mouseDown(press, prepare: prepare, secureRefused: secureRefused)
        case .up(let press, let short): host.mouseEnd(press, short: short)
        case .cancel(let press): host.mouseEnd(press)
        }
    }
    func captureEnded(generation: Int, reason: AudioRecorder.EndReason) {
        host.captureEnded(generation: generation, reason: reason)
    }
}
