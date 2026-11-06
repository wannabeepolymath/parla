import Foundation
import ParlaCore

protocol DictationEditRecording: AnyObject {
    func clear()
    func willPost(raw: String, cleaned: String)
    func completed(posted: Bool)
}

/// Main-thread owner. Scheduled closures retain only tokens, never field text.
/// Paste verification polls reads for at most one second; it never posts again.
final class GuardedDictationController<Identity: Equatable>: DictationEditRecording {
    typealias Edits = GuardedDictationEdits<Identity>
    private let edits: Edits
    private let schedule: OriginalCopyController.Schedule
    private let now: () -> TimeInterval
    private var epoch = UUID()
    private var pending: UUID?
    private var cancellations: [() -> Void] = []
    private(set) var token: UUID?

    init(edits: Edits, now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping OriginalCopyController.Schedule = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }) {
        self.edits = edits; self.now = now; self.schedule = schedule
    }

    func clear() {
        precondition(Thread.isMainThread)
        epoch = UUID(); pending = nil; token = nil; edits.clear()
        let old = cancellations; cancellations = []; old.forEach { $0() }
    }

    func refresh() -> UUID? {
        if edits.receipt == nil { token = nil }
        return token
    }

    func observe(_ event: DictationSession.Event) {
        switch event {
        case .focusSampled(_, .secure), .cleanReady(_, _, _, _, .secure, _): clear()
        case .transcribed(_, _, let probe) where probe.focus == .secure: clear()
        case .transformReady(_, _, let probe, _, _) where probe.focus == .secure: clear()
        default: break
        }
    }

    func observe(_ effect: DictationSession.Effect) {
        switch effect {
        case .captureAccepted, .abortOperation, .secureRefusal, .eraseTypedIfOurs, .replaceTailIfOurs: clear()
        default: break
        }
    }

    func willPost(raw: String, cleaned: String) {
        clear()
        pending = edits.beginInsertion(raw: raw, cleaned: cleaned)
    }

    func completed(posted: Bool) {
        guard let pending else { return }
        guard posted else { clear(); return }
        confirm(pending, epoch: epoch, deadline: now() + 1, remaining: 20)
    }

    private func confirm(_ pending: UUID, epoch: UUID, deadline: TimeInterval, remaining: Int) {
        guard self.epoch == epoch, self.pending == pending else { return }
        guard now() <= deadline else { edits.abandonInsertion(pending); self.pending = nil; return }
        if edits.confirmInsertion(pending, posted: true), let receipt = edits.receipt {
            self.pending = nil; token = UUID()
            cancellations.append(schedule(max(0, receipt.timestamp + Edits.lifetime - now())) { [weak self] in
                guard let self, self.epoch == epoch else { return }
                self.clear()
            })
        } else if remaining > 0, now() < deadline {
            cancellations.append(schedule(0.05) { [weak self] in
                self?.confirm(pending, epoch: epoch, deadline: deadline, remaining: remaining - 1)
            })
        } else {
            edits.abandonInsertion(pending); self.pending = nil
        }
    }

    func perform(_ action: Edits.Action, token: UUID) -> Edits.Outcome {
        guard refresh() == token else { return .refused }
        let outcome = edits.perform(action)
        clear()
        return outcome
    }

    deinit { cancellations.forEach { $0() } }
}
