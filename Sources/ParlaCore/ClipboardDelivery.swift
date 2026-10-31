import AppKit

public enum ClipboardRestoreMode: Sendable { case fixed, observableRequests, remoteExcluded }

/// Low-level ports. Snapshotting, publication, ownership and timing have one
/// implementation below; fakes do not substitute transaction policy.
protocol ClipboardItem: AnyObject {
    var types: [NSPasteboard.PasteboardType] { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool
    func register(_ provider: ClipboardRequestProvider) -> Bool
}
protocol ClipboardBoard: AnyObject {
    var changeCount: Int { get }
    var denied: Bool { get }
    var items: [ClipboardItem]? { get }
    func makeItem() -> ClipboardItem?
    func clear() -> Int
    func write(_ items: [ClipboardItem]) -> Bool
}

/// Immutable bytes plus a bounded scalar mailbox. No board, snapshot, raw
/// context, model, operation or insertion closure is retained by this object.
/// Its only outward action is a content-free, coalesced notification.
final class ClipboardRequestProvider {
    enum Phase { case preparing, posting, waiting, settling, closed }
    struct Observation {
        var requests = 0, ignored = 0, failures = 0, inFlight = 0
        var first: TimeInterval?, last: TimeInterval?
    }
    let payload: Data
    private let now: () -> TimeInterval
    private let notify: () -> Void
    private let lock = NSLock()
    private var phase = Phase.preparing
    private var injectionComplete: TimeInterval?
    private var observation = Observation()
    private var noticeQueued = false
    init(payload: Data, now: @escaping () -> TimeInterval, notify: @escaping () -> Void) {
        self.payload = payload; self.now = now; self.notify = notify
    }
    func setPhase(_ value: Phase, at time: TimeInterval? = nil) {
        lock.withLock {
            if phase != .closed {
                phase = value
                if value == .waiting { injectionComplete = time }
            }
        }
    }
    private static func increment(_ value: inout Int) { if value < 1_000_000 { value += 1 } }

    /// Entry phase/time precede fulfillment. An invalid board cannot establish
    /// evidence, but a nil-board callback may still fulfill its valid item.
    func provide(validBoard: Bool, validItem: Bool, type: NSPasteboard.PasteboardType,
                 supply: (Data) -> Bool) {
        let supported = validItem && type == .string
        // The short lock is the callback-entry linearization point. Capture the
        // primitive monotonic clock and phase together, before touching AppKit.
        let entry = lock.withLock { () -> (time: TimeInterval, eligible: Bool)? in
            guard phase != .closed, observation.inFlight < Int.max else { return nil }
            let entered = now()
            observation.inFlight += 1
            return (entered, supported && validBoard && phase == .waiting && entered.isFinite
                && injectionComplete.map { entered >= $0 } == true)
        }
        guard let entry else { return }
        let entered = entry.time, eligible = entry.eligible
        let supplied = supported && supply(payload) // never under the lock
        let send = lock.withLock { () -> Bool in
            if eligible && supplied {
                Self.increment(&observation.requests)
                observation.first = observation.first.map { min($0, entered) } ?? entered
                observation.last = observation.last.map { max($0, entered) } ?? entered
            } else { Self.increment(&observation.ignored) }
            if supported && !supplied { Self.increment(&observation.failures) }
            observation.inFlight -= 1
            if noticeQueued { return false }; noticeQueued = true; return true
        }
        if send { notify() }
    }
    /// Timer decisions drain the mailbox under the same lock as callback entry.
    /// Cutting off eligibility and checking in-flight fulfillment are one operation.
    func drain(closeIf: (Observation) -> Bool = { _ in false }) -> Observation {
        lock.withLock {
            noticeQueued = false
            if observation.inFlight == 0 && closeIf(observation) { phase = .settling }
            return observation
        }
    }
    /// After preparation, atomically stop new fulfillment before replacement.
    func closeIfIdle() -> Observation {
        lock.withLock {
            if observation.inFlight == 0 { phase = .closed }
            return observation
        }
    }
    /// A failed pre-clear preparation can leave our promise on the board.
    /// Keep fulfilling it, but never reopen receipt eligibility or timing.
    func hold() { lock.withLock { phase = .settling } }
    // AppKit completion is advisory; it neither closes timing nor loses ownership.
    func finished() {}
}

private final class ReceiptPasteboardItem: NSPasteboardItem {
    var promisesText = false
    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .string && promisesText ? .promised : []
    }
}
private final class NativeClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let source: ClipboardRequestProvider
    weak var expectedItem: NSPasteboardItem?
    weak var expectedBoard: NSPasteboard?
    init(_ source: ClipboardRequestProvider, item: NSPasteboardItem, board: NSPasteboard) {
        self.source = source; expectedItem = item; expectedBoard = board
    }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        source.provide(validBoard: pasteboard != nil && pasteboard === expectedBoard,
                       validItem: item === expectedItem, type: type) { item.setData($0, forType: type) }
    }
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) { source.finished() }
}
private final class NativeClipboardItem: ClipboardItem {
    let item: NSPasteboardItem
    let board: NSPasteboard
    private var provider: NativeClipboardProvider?
    init(_ item: NSPasteboardItem, board: NSPasteboard) { self.item = item; self.board = board }
    var types: [NSPasteboard.PasteboardType] { item.types }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { item.data(forType: type) }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { item.setData(data, forType: type) }
    func register(_ source: ClipboardRequestProvider) -> Bool {
        let adapter = NativeClipboardProvider(source, item: item, board: board)
        guard item.setDataProvider(adapter, forTypes: [.string]) else { return false }
        (item as? ReceiptPasteboardItem)?.promisesText = true
        provider = adapter; return true
    }
}
private final class NativeClipboardBoard: ClipboardBoard {
    let board: NSPasteboard
    init(_ board: NSPasteboard) { self.board = board }
    var changeCount: Int { board.changeCount }
    var denied: Bool {
        if #available(macOS 15.4, *) { return board.accessBehavior == .alwaysDeny }; return false
    }
    var items: [ClipboardItem]? { board.pasteboardItems?.map { NativeClipboardItem($0, board: board) } }
    func makeItem() -> ClipboardItem? { NativeClipboardItem(ReceiptPasteboardItem(), board: board) }
    func clear() -> Int { board.clearContents() }
    func write(_ items: [ClipboardItem]) -> Bool {
        let native = items.compactMap { ($0 as? NativeClipboardItem)?.item }
        return native.count == items.count && board.writeObjects(native)
    }
}

/// Main-thread transaction owner. Providers service immutable prepared data on
/// their callback thread, then signal main asynchronously. No synchronous waits.
final class ClipboardDelivery {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    static let maxData = 8 * 1024 * 1024, maxText = 1024 * 1024
    static let maxItems = 256, maxRepresentations = 1024, maxTypeBytes = 64 * 1024
    private let board: ClipboardBoard
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let enqueue: (@escaping () -> Void) -> Void
    private var busy = false
    private var stopping = false
    private var shutdownReply: ((Bool) -> Void)?
    private(set) var restoreFailed = false
    var isRestorePending: Bool { pending != nil }
    private final class Lease {
        let token: UUID, snapshot: Snapshot, provider: ClipboardRequestProvider?
        let diagnostics: DiagnosticOperation?
        let item: ClipboardItem
        var count: Int, published: TimeInterval = 0, injected: TimeInterval = 0
        var posted = false
        var evidence: DiagnosticClipboard
        var cancelMax: (() -> Void)?, cancelQuiet: (() -> Void)?
        var quietGeneration = 0
        var deferred: DiagnosticClipboard.End?
        var failed = false
        init(token: UUID, item: ClipboardItem, snapshot: Snapshot, count: Int, provider: ClipboardRequestProvider?,
             diagnostics: DiagnosticOperation?, evidence: DiagnosticClipboard) {
            self.item = item; self.token = token; self.snapshot = snapshot; self.count = count; self.provider = provider
            self.diagnostics = diagnostics; self.evidence = evidence
        }
        deinit { cancelMax?(); cancelQuiet?() }
    }
    private var pending: Lease?

    convenience init(board: NSPasteboard = .general) {
        self.init(board: NativeClipboardBoard(board))
    }
    /// Compatibility for existing unique-board fixtures; production uses the
    /// cancellable scheduler below, so only max + one quiet timer remain live.
    convenience init(board: NSPasteboard,
                     schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.init(board: NativeClipboardBoard(board), schedule: { delay, action in schedule(delay, action); return {} })
    }
    init(board: ClipboardBoard,
         now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping Schedule = { delay, action in
             let work = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
             return { work.cancel() }
         }, enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.board = board; self.now = now; self.schedule = schedule; self.enqueue = enqueue
    }
    static func snapshot(_ board: NSPasteboard) -> Snapshot? { snapshot(NativeClipboardBoard(board), capped: false) }
    static func snapshot(_ board: ClipboardBoard, capped: Bool) -> Snapshot? {
        guard !board.denied else { return nil }
        let stamp = board.changeCount
        guard let items = board.items, !capped || items.count <= maxItems else { return nil }
        var result: Snapshot = [], bytes = 0, representations = 0, names = 0
        func add(_ value: Int, to total: inout Int, limit: Int) -> Bool {
            guard value <= limit - total else { return false }; total += value; return true
        }
        for item in items {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if capped {
                    guard add(1, to: &representations, limit: maxRepresentations),
                          add(type.rawValue.utf8.count, to: &names, limit: maxTypeBytes) else { return nil }
                }
                guard let data = item.data(forType: type) else { return nil }
                if capped && !add(data.count, to: &bytes, limit: maxData) { return nil }
                values[type] = data
            }
            result.append(values)
        }
        return board.changeCount == stamp ? result : nil
    }
    private func prepare(_ snapshot: Snapshot) -> [ClipboardItem]? {
        var items: [ClipboardItem] = []
        for values in snapshot {
            guard let item = board.makeItem() else { return nil }
            for (type, data) in values { guard item.setData(data, forType: type) else { return nil } }
            items.append(item)
        }
        return items
    }
    @discardableResult
    func paste(_ text: String, restoreAfter delay: TimeInterval = 0.8,
               mode: ClipboardRestoreMode = .fixed, diagnostics: DiagnosticOperation? = nil,
               postPaste: () -> Void) -> Bool {
        guard !busy, !stopping else { return false }
        busy = true; defer {
            busy = false
            // A quit can reenter during snapshot/item preparation, before a
            // lease exists. Do not approve exit until that attempt has drained.
            if stopping && pending == nil {
                let reply = shutdownReply; shutdownReply = nil; reply?(true)
            }
        }
        if let old = pending {
            restore(old, cause: .superseded)
            guard pending == nil, !stopping else { return false }
        }
        let experimental = mode == .observableRequests
        var evidence = DiagnosticClipboard(mode: mode, delay: delay)
        func refuse() -> Bool {
            evidence.end = .preparationRefused; evidence.restore = .untouched
            diagnostics?.update { $0.clipboard = evidence }; return false
        }
        guard !experimental || text.utf8.count <= Self.maxText else { return refuse() }
        let stamp = board.changeCount
        guard let original = Self.snapshot(board, capped: experimental), stamp == board.changeCount,
              prepare(original) != nil, let item = board.makeItem() else { return refuse() }
        let token = UUID()
        let provider: ClipboardRequestProvider? = experimental ? ClipboardRequestProvider(
            payload: Data(text.utf8), now: now, notify: { [weak self] in
                self?.enqueue { [weak self] in self?.notice(token: token) }
            }) : nil
        if let provider {
            guard item.register(provider) else { return refuse() }
        } else if !item.setData(Data(text.utf8), forType: .string) { return refuse() }
        for type in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"] {
            guard item.setData(Data(), forType: .init(type)) else { return refuse() }
        }
        guard item.setData(Data("io.github.wannabeepolymath.parla".utf8), forType: .init("org.nspasteboard.source")),
              board.changeCount == stamp, !stopping else { return refuse() }
        let cleared = board.clear()
        let lease = Lease(token: token, item: item, snapshot: original, count: cleared, provider: provider, diagnostics: diagnostics, evidence: evidence)
        pending = lease; lease.published = now()
        guard !stopping else { restore(lease, cause: .shutdown); return false }
        guard board.write([item]), board.changeCount == cleared else {
            restore(lease, cause: .publicationFailed); return false
        }
        guard !stopping else { restore(lease, cause: .shutdown); return false }
        lease.published = now()
        provider?.setPhase(.posting)
        postPaste() // willPost + down/up remain synchronous and exactly once
        lease.posted = true; lease.injected = now()
        provider?.setPhase(.waiting, at: lease.injected)
        publishEvidence(lease)
        lease.cancelMax = schedule(experimental ? max(0, lease.published + 8 - now()) : delay) { [weak self] in
            self?.timer(token: token, maximum: true)
        }
        return true
    }
    private func updateObservation(_ lease: Lease, _ observation: ClipboardRequestProvider.Observation) {
        lease.evidence.requestedDelayMs = DiagnosticClipboard.milliseconds(deadline(lease, observation) - lease.published)
        lease.evidence.requests = observation.requests; lease.evidence.ignored = observation.ignored
        lease.evidence.supplyFailures = observation.failures
        lease.evidence.firstRequestMs = observation.first.map { DiagnosticClipboard.milliseconds($0 - lease.published) }
        if observation.requests > 0 { lease.evidence.receipt = .observed; lease.diagnostics?.receipt() }
    }
    private func deadline(_ lease: Lease, _ observation: ClipboardRequestProvider.Observation) -> TimeInterval {
        guard let last = observation.last else { return lease.published + 8 }
        return min(lease.published + 8, max(lease.injected + 0.8, last + 0.3))
    }
    private func notice(token: UUID) {
        guard !busy, let lease = pending, lease.token == token, let provider = lease.provider else { return }
        busy = true; defer { busy = false }
        let observation = provider.drain()
        guard board.changeCount == lease.count else { restore(lease, cause: .ownershipChanged); return }
        updateObservation(lease, observation)
        if let cause = lease.deferred { restore(lease, cause: cause); return }
        guard !lease.failed else { return }
        publishEvidence(lease)
        if now() >= lease.published + 8 {
            if observation.inFlight == 0 { restore(lease, cause: .maximum) }
            return
        }
        guard observation.requests > 0 else { return }
        lease.cancelQuiet?(); lease.quietGeneration += 1
        let generation = lease.quietGeneration, token = lease.token
        lease.cancelQuiet = schedule(max(0, deadline(lease, observation) - now())) { [weak self] in
            guard let self, self.pending?.token == token, self.pending?.quietGeneration == generation else { return }
            self.timer(token: token, maximum: false)
        }
    }
    private func timer(token: UUID, maximum: Bool) {
        guard !busy, let lease = pending, lease.token == token, !lease.failed else { return }
        busy = true; defer { busy = false }
        guard let provider = lease.provider else { restore(lease, cause: .baselineTimer); return }
        let observedTime = now()
        let observation = provider.drain { observedTime >= self.deadline(lease, $0) }
        if board.changeCount != lease.count { restore(lease, cause: .ownershipChanged); return }
        updateObservation(lease, observation)
        let due = now() >= deadline(lease, observation)
        if due {
            guard observation.inFlight == 0 else { return }
            restore(lease, cause: now() >= lease.published + 8 ? .maximum : .quietAfterObservableRequest)
        } else if !maximum {
            // A callback entered before this timer but its notice is still queued.
            lease.quietGeneration += 1
            let generation = lease.quietGeneration
            lease.cancelQuiet?()
            lease.cancelQuiet = schedule(max(0, deadline(lease, observation) - now())) { [weak self] in
                guard let self, self.pending?.quietGeneration == generation else { return }
                self.timer(token: token, maximum: false)
            }
        }
    }
    private func restore(_ lease: Lease, cause: DiagnosticClipboard.End) {
        guard pending?.token == lease.token else { return }
        lease.provider?.setPhase(.settling)
        let observation = lease.provider?.drain(closeIf: { _ in true })
        if let observation, board.changeCount == lease.count { updateObservation(lease, observation) }
        if observation?.inFlight ?? 0 > 0 { lease.deferred = cause; return }
        lease.deferred = nil
        lease.cancelMax?(); lease.cancelQuiet?(); lease.quietGeneration += 1
        // Fresh items BEFORE the final ownership check. Never read our own text.
        let items = prepare(lease.snapshot)
        let finalObservation = lease.provider?.closeIfIdle()
        if finalObservation?.inFlight ?? 0 > 0 { lease.deferred = cause; return }
        if let finalObservation, board.changeCount == lease.count { updateObservation(lease, finalObservation) }
        guard board.changeCount == lease.count else {
            finish(lease, cause: .ownershipChanged, outcome: .skippedOwnershipChanged); return
        }
        if lease.failed { failed(lease); return } // no implicit restore retry
        guard let items else { failed(lease); return }
        lease.count = board.clear()
        let success = items.isEmpty || board.write(items)
        if board.changeCount != lease.count {
            finish(lease, cause: .ownershipChanged, outcome: .skippedOwnershipChanged)
        } else if success { finish(lease, cause: cause, outcome: .restored) }
        else { failed(lease) }
    }
    private func publishEvidence(_ lease: Lease) {
        lease.evidence.elapsedMs = DiagnosticClipboard.milliseconds(now() - lease.published)
        let evidence = lease.evidence
        lease.diagnostics?.update { $0.clipboard = evidence }
    }
    private func failed(_ lease: Lease) {
        lease.provider?.hold()
        lease.failed = true; restoreFailed = true
        lease.evidence.end = .restoreFailed; lease.evidence.restore = .failed
        publishEvidence(lease)
        let reply = shutdownReply; shutdownReply = nil; reply?(false)
    }
    private func finish(_ lease: Lease, cause: DiagnosticClipboard.End, outcome: DiagnosticClipboard.Restore) {
        lease.evidence.end = cause; lease.evidence.restore = outcome
        if lease.posted && lease.provider != nil && lease.evidence.receipt == .unknown { lease.evidence.receipt = .noObservableReceipt }
        publishEvidence(lease)
        pending = nil; restoreFailed = false
        let reply = shutdownReply; shutdownReply = nil; reply?(true)
    }
    /// Shutdown prevents new publication while the existing policy drains.
    /// A failed owned restore cancels quit, retaining the sole RAM original.
    func beginShutdown(_ reply: @escaping (Bool) -> Void) {
        stopping = true
        if busy { shutdownReply = reply; return }
        guard let lease = pending else { reply(true); return }
        if lease.failed {
            if board.changeCount != lease.count { shutdownReply = reply; restore(lease, cause: .ownershipChanged) }
            else { reply(false) }
        } else { shutdownReply = reply }
    }
    func cancelShutdown() { stopping = false; shutdownReply = nil }
}
