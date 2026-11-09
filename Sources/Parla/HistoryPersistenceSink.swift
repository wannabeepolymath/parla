import ParlaCore

/// Production history effect boundary, kept independent of AppKit and providers
/// so save failure and HUD ordering can be exercised without launching the app.
final class HistoryPersistenceSink {
    let history: HistoryStore
    private let settings: SettingsStore
    private var saved: Bool?
    private var deferredHUD: HUDState?
    private var permitsStorageHUD = true
    private var ownedMetrics: PipelineMetrics?

    init(history: HistoryStore, settings: SettingsStore) {
        self.history = history; self.settings = settings
    }

    func beginEvent() { saved = nil; deferredHUD = nil; permitsStorageHUD = true; ownedMetrics = nil }

    func beginEvent(for event: DictationSession.Event, currentGeneration: Int) {
        beginEvent()
        if case let .cleanReady(s, _, _, _, _, usage) = event,
           s.settings.usesAppleIntelligence || (s.cleanupFailoverOrigin != nil && usage != nil) {
            // Only this operation's observed local usage; never borrow a newer
            // capture's network tokens or global model label on late completion.
            ownedMetrics = usage ?? PipelineMetrics()
        }
        switch event {
        case .transcribed(let s, _, _), .cleanReady(let s, _, _, _, _, _), .transformReady(let s, _, _, _, _):
            permitsStorageHUD = s.gen == currentGeneration
        default: break
        }
    }

    /// Storage claims can precede or follow append effects. Defer the former
    /// until persistence completes. Ordinary paste feedback stays independent.
    func feedback(_ state: HUDState) -> HUDState? {
        guard state == .savedToHistory || state == .cleanedInHistory else { return state }
        guard permitsStorageHUD else { return nil }
        deferredHUD = state
        guard let saved else { return nil }
        deferredHUD = nil
        return saved ? state : .error("Not saved to history — open History to retry")
    }

    @discardableResult
    func record(_ effect: DictationSession.Effect, insertionFailed: Bool = false,
                metrics: () -> PipelineMetrics? = { Metrics.shared.snapshot() }) -> HUDState? {
        let entry: HistoryEntry
        switch effect {
        case let .appendHistory(raw, cleaned, appName):
            entry = .init(raw: raw, cleaned: cleaned, appName: appName, metrics: ownedMetrics ?? metrics())
        case let .appendTransformHistory(raw, cleaned, appName, operation, usage):
            var operation = operation
            if operation.outcome == .completed, insertionFailed { operation.outcome = .parked }
            entry = .init(raw: raw, cleaned: cleaned, appName: appName, metrics: usage, operation: operation)
        default: return nil
        }
        let current = settings.load()
        // Count follows current settings; write permission was already latched by
        // the machine that emitted this effect. Never re-check historyEnabled.
        if settings.lastError == nil { history.applyCountLimit(current.historyTextCount) }
        saved = history.append(entry)
        guard let deferredHUD else { return nil } // stale completions emit no HUD
        return feedback(deferredHUD)
    }
}
