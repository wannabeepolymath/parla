import Foundation
import ParlaCore

// All owners are driven on main. Native bottoms are closures, never evaluated by init.
typealias CheckSchedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
func scheduleCheck(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
    let item = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return { item.cancel() }
}

enum InertFailure: Error { case forbiddenWrite }
final class RejectingCountingBackend: CredentialBackend {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    private func reject() { lock.withLock { count += 1 } }
    func status(_ scope: CredentialScope) -> CredentialStatus { reject(); return .error }
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead { reject(); return .error }
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { reject(); return .error }
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { reject(); return .error }
    func delete(_ scope: CredentialScope) -> CredentialMutation { reject(); return .error }
}

final class InputCheckSettings {
    private let lock = NSLock()
    private var bytes = Data("{}".utf8)
    let backend = RejectingCountingBackend()
    // A label only. Both document and write bottoms are explicit; no path is opened.
    lazy var store = SettingsStore(url: URL(fileURLWithPath: "/__parla_owned_input_check_ram__/settings.json"),
        credentials: CredentialStore(backend: backend),
        scratchpadIO: ScratchpadPreferenceIO(read: { _ in nil }, write: { _, _ in throw InertFailure.forbiddenWrite }),
        documentIO: .init(read: { [self] in read() }),
        atomicWrite: { _, _ in throw InertFailure.forbiddenWrite })
    func read() -> Data { lock.withLock { bytes } }
    func bind(_ button: MouseButtonBinding?) {
        // Only fixture mouse bytes change. Never call SettingsStore.save/migration.
        let next = button.map { Data("{\"mouseBinding\":{\"buttonNumber\":\($0.buttonNumber)}}".utf8) } ?? Data("{}".utf8)
        lock.withLock { bytes = next }
    }
    func canonical() -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(store.load().hotkeys)) ?? Data()
    }
}

struct LayoutReceipt: Codable {
    var read = false, watched = false
    var switchesSeen = 0, labelsChanged = 0, fallbackKeys = 0
    var savedUnchanged = true
}
final class LayoutCheck {
    static let keys: [(String, UInt16)] = [
        ("A (0)", 0), ("Q (12)", 12), ("Z (6)", 6), ("Y (16)", 16), ("W (13)", 13),
        ("; (41)", 41), ("V (9)", 9), ("§ (10)", 10), ("¥ (93)", 93), ("_ (94)", 94),
        ("JIS , (95)", 95), ("Space", 49), ("Esc", 53), ("←", 123), ("F1", 122)
    ]
    private let snapshot: () -> ShortcutDisplayFormatter
    private let observe: (@escaping () -> Void) -> (() -> Void)
    private let canonical: () -> Data
    private let schedule: CheckSchedule
    private var original: Data?
    private var generation = 0
    private var cancelObserver: (() -> Void)?, cancelDeadline: (() -> Void)?
    private(set) var labels = [String](repeating: "—", count: LayoutCheck.keys.count)
    private(set) var watching = false
    private(set) var receipt = LayoutReceipt()
    var changed: () -> Void = {}
    init(snapshot: @escaping () -> ShortcutDisplayFormatter,
         observe: @escaping (@escaping () -> Void) -> (() -> Void),
         canonical: @escaping () -> Data, schedule: @escaping CheckSchedule = scheduleCheck) {
        self.snapshot = snapshot; self.observe = observe; self.canonical = canonical; self.schedule = schedule
    }
    func read() {
        let bytes = canonical()
        if original == nil { original = bytes }
        receipt.savedUnchanged = receipt.savedUnchanged && original == bytes
        let formatter = snapshot(), fallback = ShortcutDisplayFormatter { _ in nil }
        let next = Self.keys.map { formatter.display(KeyChord($0.1)) }
        if receipt.read { receipt.labelsChanged += zip(labels, next).filter { $0.0 != $0.1 }.count }
        labels = next
        receipt.fallbackKeys = Self.keys.indices.filter { $0 < 11 && next[$0] == fallback.display(KeyChord(Self.keys[$0].1)) }.count
        receipt.read = true; changed()
    }
    func watch() {
        stop(); read(); generation += 1
        let id = generation; watching = true; receipt.watched = true
        cancelObserver = observe { [weak self] in
            guard let self, self.watching, self.generation == id else { return }
            self.receipt.switchesSeen += 1; self.read()
        }
        cancelDeadline = schedule(60) { [weak self] in
            guard let self, self.generation == id, self.watching else { return }
            self.stop()
        }
        changed()
    }
    func stop() {
        generation += 1; watching = false
        cancelObserver?(); cancelObserver = nil; cancelDeadline?(); cancelDeadline = nil
        if let original { receipt.savedUnchanged = receipt.savedUnchanged && original == canonical() }
        changed()
    }
    deinit { cancelObserver?(); cancelDeadline?() }
}

enum MicPermission: String, Codable { case notRead, notDetermined, granted, denied, restricted }
enum MicStatus: String, Codable {
    case idle, starting, signal, silentPCM, conversionFailure, noPCM, stoppedBeforePCM, stopped, routeLost, listening, refused, failed, playbackFailed
    var message: String {
        switch self {
        case .idle: return "Ready. Start a short microphone test."
        case .starting: return "Starting — waiting for input PCM."
        case .signal: return "PCM received; signal detected during this test."
        case .silentPCM: return "PCM received; no signal detected during this test."
        case .conversionFailure: return "Input conversion failed for one or more buffers."
        case .noPCM: return "No input PCM callback within 2 seconds. Check the route and setup."
        case .stoppedBeforePCM: return "Stopped before any input PCM callback. Permission and signal are unknown."
        case .routeLost: return "Input route was lost. Capture is closed."
        case .stopped: return "Capture stopped. Listen to review, or Clear to release the audio."
        case .listening: return "Playing the stopped test locally."
        case .refused: return "Finish the current check before starting a microphone test."
        case .playbackFailed: return "Local playback failed. You can retry Listen or Clear."
        case .failed: return "Couldn’t start the input. Check Microphone permission and the input device, then retry."
        }
    }
}
enum MicEnd: String, Codable { case none, stopped, deadline, sampleLimit, deviceLost, cleared, startFailed }
struct RetainedCounts: Codable, Equatable {
    var samples: Int, preRoll: Int
    var converter: Bool
}
struct MicRunReceipt: Codable {
    var status = MicStatus.starting
    var samples = 0, seconds = 0
    var routeKnown = false, routeFallback: Bool?, routeChanged = false
    var ended = MicEnd.none
    var listened = false, heardConfirmed: Bool?
    var retainedAfterClear: RetainedCounts?
    // Optional evidence remains explicitly null until an observation/user answer.
    enum CodingKeys: String, CodingKey {
        case status, samples, seconds, routeKnown, routeFallback, routeChanged, ended, listened, heardConfirmed, retainedAfterClear
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(samples, forKey: .samples); try c.encode(seconds, forKey: .seconds)
        try c.encode(routeKnown, forKey: .routeKnown); try c.encode(routeFallback, forKey: .routeFallback)
        try c.encode(routeChanged, forKey: .routeChanged); try c.encode(ended, forKey: .ended)
        try c.encode(listened, forKey: .listened); try c.encode(heardConfirmed, forKey: .heardConfirmed)
        try c.encode(retainedAfterClear, forKey: .retainedAfterClear)
    }
}
struct MicReceipt: Codable { var permission = MicPermission.notRead; var runs: [MicRunReceipt] = [] }
final class MicCheck {
    private let capture: MicrophoneTestCapturing
    private let admission: CaptureAdmission
    private let permission: () -> MicPermission
    private let request: (@escaping (Bool) -> Void) -> Void
    private let allowed: () -> Bool
    private let now: () -> TimeInterval
    private let schedule: CheckSchedule
    private let retained: () -> RetainedCounts
    private let playerFactory: () -> MicrophoneTestPlaying
    private var lease: CaptureAdmission.Lease?, suspension: UUID?, operation: UUID?, playbackID: UUID?
    private var permissionGeneration = 0
    private var cancelTick: (() -> Void)?, cancelDeadline: (() -> Void)?
    private var player: MicrophoneTestPlaying?
    private var runIndex: Int?
    private var started: TimeInterval = 0
    private var observedRoute = false
    private(set) var review: [Float] = []
    private(set) var state = MicStatus.idle
    private(set) var captureStatus = MicStatus.idle
    private(set) var route = MicrophoneRoute()
    private(set) var level: Float = 0
    private(set) var sampleCount = 0
    private(set) var capturing = false
    private(set) var askingHeard = false
    private(set) var permissionMessage: String?
    private(set) var receipt = MicReceipt()
    var changed: () -> Void = {}
    var playerActive: Bool { player != nil }
    var elapsed: Double { capturing ? min(10, max(0, now() - started)) : Double(sampleCount) / 16_000 }
    init(capture: MicrophoneTestCapturing, admission: CaptureAdmission,
         permission: @escaping () -> MicPermission, request: @escaping (@escaping (Bool) -> Void) -> Void,
         allowed: @escaping () -> Bool, retained: @escaping () -> RetainedCounts,
         playerFactory: @escaping () -> MicrophoneTestPlaying,
         now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping CheckSchedule = scheduleCheck) {
        self.capture = capture; self.admission = admission; self.permission = permission; self.request = request
        self.allowed = allowed; self.retained = retained; self.playerFactory = playerFactory; self.now = now; self.schedule = schedule
    }
    func start() {
        clear()
        guard allowed() else { state = .refused; changed(); return }
        receipt.permission = permission()
        switch receipt.permission {
        case .granted: permissionMessage = nil
        case .notRead, .notDetermined:
            permissionMessage = "This app hasn't been given microphone access yet."; state = .refused; changed(); return
        case .denied, .restricted:
            permissionMessage = Self.deniedMessage; state = .refused; changed(); return
        }
        guard let lease = admission.acquire(.microphoneTest) else { state = .refused; changed(); return }
        self.lease = lease; suspension = HotkeyMonitor.acquireSuspension()
        let id = UUID(); operation = id; started = now(); capturing = true
        runIndex = receipt.runs.count; receipt.runs.append(MicRunReceipt())
        state = .starting; captureStatus = .starting
        do { try capture.start(operation: id, lease: lease) }
        catch {
            update { $0.status = .failed; $0.ended = .startFailed }
            capturing = false // disposal must preserve the start failure, not record an active Clear.
            clear(); state = .failed; changed(); return
        }
        cancelDeadline = schedule(max(0, 10 - (now() - started))) { [weak self] in
            guard let self, self.operation == id, self.capturing else { return }
            self.stop(reason: .deadline)
        }
        poll(id)
    }
    static let deniedMessage = "Microphone access is off for this app. Turn it on in System Settings › Privacy & Security › Microphone, then press Start again."
    func allowMicrophone() {
        guard receipt.permission == .notDetermined, allowed(), !capturing else { return }
        permissionGeneration += 1; let generation = permissionGeneration
        request { [weak self] granted in
            guard let self, self.permissionGeneration == generation, self.allowed() else { return }
            self.receipt.permission = granted ? .granted : .denied
            self.permissionMessage = granted ? "Access granted. Press Start Microphone Test when you're ready." : Self.deniedMessage
            self.changed() // A grant never calls Start.
        }
    }
    private func update(_ action: (inout MicRunReceipt) -> Void) {
        if let runIndex { action(&receipt.runs[runIndex]) }
    }
    private func observe(_ facts: MicrophoneCaptureSnapshot) {
        let changedRoute = observedRoute && route != facts.route
        route = facts.route; observedRoute = true
        sampleCount = min(AudioRecorder.microphoneTestMaxSamples, max(0, facts.sampleCount))
        level = facts.level.isFinite ? min(1, max(0, facts.level)) : 0
        if facts.ended == .deviceLost { captureStatus = .routeLost }
        else if facts.conversionFailures > 0 { captureStatus = .conversionFailure }
        else if facts.facts?.firstPCM != nil { captureStatus = facts.hasSignal ? .signal : .silentPCM }
        else { captureStatus = now() - started >= CaptureDiagnosticState.firstPCMDeadline ? .noPCM : .starting }
        let known = route.name != nil, fallback = route.fallback
        update {
            $0.status = captureStatus; $0.samples = sampleCount
            $0.seconds = min(10, max(0, Int(now() - started)))
            $0.routeKnown = known; $0.routeFallback = fallback; $0.routeChanged = $0.routeChanged || changedRoute
        }
    }
    private func poll(_ id: UUID) {
        guard operation == id, capturing else { return }
        cancelTick?(); cancelTick = nil
        if let facts = capture.snapshot(operation: id) {
            observe(facts)
            if facts.ended == .deviceLost { stop(reason: .deviceLost); return }
            if facts.ended == .sampleLimit || sampleCount >= AudioRecorder.microphoneTestMaxSamples { stop(reason: .sampleLimit); return }
        } else if now() - started >= CaptureDiagnosticState.firstPCMDeadline { captureStatus = .noPCM }
        state = captureStatus
        let remaining = 10 - (now() - started)
        if remaining <= 0 { stop(reason: .deadline); return }
        // No repeating idle timer, and no poll more frequent than 10 Hz.
        cancelTick = schedule(0.1) { [weak self] in self?.poll(id) }
        changed()
    }
    func stop(reason: MicEnd = .stopped) {
        guard let id = operation, capturing else { return }
        cancelTick?(); cancelTick = nil; cancelDeadline?(); cancelDeadline = nil
        review = Array(capture.stop(operation: id).prefix(AudioRecorder.microphoneTestMaxSamples))
        capturing = false
        if let facts = capture.snapshot(operation: id) { observe(facts) }
        if captureStatus == .starting { captureStatus = .stoppedBeforePCM }
        if reason == .deviceLost { captureStatus = .routeLost }
        sampleCount = review.count; level = 0
        update { $0.status = captureStatus; $0.samples = review.count; $0.ended = reason; $0.seconds = min(10, max(0, Int(now() - started))) }
        let counts = retained()
        if counts.samples != 0 || counts.preRoll != 0 || counts.converter { captureStatus = .failed; update { $0.status = .failed } }
        state = captureStatus == .routeLost ? .routeLost : captureStatus == .failed ? .failed : .stopped; changed()
    }
    func listen() {
        guard allowed(), operation != nil, !capturing, !review.isEmpty, player == nil else { return }
        let id = UUID(); playbackID = id; askingHeard = false
        let player = playerFactory(); self.player = player; state = .listening
        do {
            try player.play(samples: review, sampleRate: 16_000) { [weak self] success in
                guard let self, self.playbackID == id else { return }
                self.stopListening()
                if success { self.askingHeard = true } else { self.state = .playbackFailed }
                self.changed()
            }
            update { $0.listened = true }
        } catch { stopListening(); state = .playbackFailed }
        changed()
    }
    func stopListening() {
        playbackID = nil; player?.stop(); player = nil
        if state == .listening { state = .stopped }
        changed()
    }
    func heard(_ answer: Bool) {
        guard askingHeard, operation != nil, !capturing, !playerActive else { return }
        update { $0.heardConfirmed = answer }; askingHeard = false; changed()
    }
    func clear() {
        permissionGeneration += 1
        let id = operation; operation = nil
        cancelTick?(); cancelTick = nil; cancelDeadline?(); cancelDeadline = nil; playbackID = nil
        player?.stop(); player = nil; askingHeard = false
        if let id {
            if capturing, let facts = capture.snapshot(operation: id) { observe(facts) }
            if capturing { update { $0.status = captureStatus; $0.samples = sampleCount; $0.seconds = min(10, max(0, Int(now() - started))); $0.ended = .cleared } }
            capture.clear(operation: id)
            let counts = retained(); update { $0.retainedAfterClear = counts }
        }
        if let lease { admission.release(lease) }; lease = nil
        if let suspension { HotkeyMonitor.releaseSuspension(suspension) }; suspension = nil
        review = []; runIndex = nil; capturing = false; sampleCount = 0; level = 0
        route = MicrophoneRoute(); observedRoute = false; state = .idle; captureStatus = .idle; permissionMessage = nil
        changed()
    }
    deinit { cancelTick?(); cancelDeadline?(); player?.stop(); if let operation { capture.clear(operation: operation) }; if let lease { admission.release(lease) }; if let suspension { HotkeyMonitor.releaseSuspension(suspension) } }
}

enum TapReceipt: String, Codable { case notTested, ready, unavailable, disabled, invalidPort, permissionLost }
enum MouseResult: String, Codable { case notTested, balanced, incomplete }
struct MouseReceipt: Codable {
    var tap = TapReceipt.notTested
    var arms = 0, accepted = 0, quickTaps = 0, holds = 0, cancels = 0, refusedQueued = 0
    var receiverSelected = 0, receiverOther = 0, pendingAtFinish = 0
    var result = MouseResult.notTested
}
final class MouseCheck {
    private let authority: PhysicalInputAuthority
    private let admission: CaptureAdmission
    private let settings: InputCheckSettings
    private let create: () -> HotkeyMonitor
    private let startMonitor: (HotkeyMonitor) -> Void
    private let scope: () -> Bool
    private let schedule: CheckSchedule
    // Deliberately retained after finish. The owner itself lives through exit().
    private(set) var monitor: HotkeyMonitor?
    private var suspension: UUID?
    private var cancelArm: (() -> Void)?, cancelPhase: (() -> Void)?, cancelFinish: (() -> Void)?
    private var armGeneration = 0
    private var active: MousePress?
    private var unavailable = false, interrupted = false, terminalTimeout = false
    private(set) var selected: MouseButtonBinding?
    private(set) var armed = false, phaseStarted = false, finishing = false
    private(set) var receipt = MouseReceipt()
    private(set) var receiverPresses = 0, receiverReleases = 0, receiverOtherPresses = 0, receiverOtherReleases = 0
    var changed: () -> Void = {}
    var phaseExpired: () -> Void = {}
    var canArm: Bool { !unavailable && !finishing && selected != nil && (!phaseStarted || monitor?.tapStatus == .ready) }
    var onlyFinish: Bool { unavailable || finishing }
    init(settings: InputCheckSettings, authority: PhysicalInputAuthority, admission: CaptureAdmission,
         create: @escaping () -> HotkeyMonitor, startMonitor: @escaping (HotkeyMonitor) -> Void = { $0.start() },
         scope: @escaping () -> Bool, schedule: @escaping CheckSchedule = scheduleCheck) {
        self.settings = settings; self.authority = authority; self.admission = admission
        self.create = create; self.startMonitor = startMonitor; self.scope = scope; self.schedule = schedule
    }
    func rebind(_ binding: MouseButtonBinding?) {
        guard !onlyFinish else { return }
        disarm(); selected = binding; settings.bind(binding); monitor?.reloadMouseConfiguration(); changed()
    }
    // The UI sheet supplies acknowledgement; it is never inferred from focus or elapsed time.
    func arm(acknowledged: Bool) {
        guard canArm, scope(), admission.isAvailable, acknowledged else { return }
        disarm()
        if !phaseStarted {
            phaseStarted = true
            cancelPhase = schedule(300) { [weak self] in
                guard let self, !self.finishing else { return }
                self.terminalTimeout = true; self.disarm(); self.phaseExpired()
            }
            let monitor = create(); self.monitor = monitor
            monitor.onMouseEdge = { [weak self] in self?.receive($0) }
            monitor.onTapStatus = { [weak self] in self?.tapChanged($0) }
            startMonitor(monitor)
            tapChanged(monitor.tapStatus)
        }
        guard !unavailable, monitor?.tapStatus == .ready, scope() else { changed(); return }
        if let suspension { HotkeyMonitor.releaseSuspension(suspension) }; suspension = nil
        armed = true; receipt.arms += 1; armGeneration += 1
        let generation = armGeneration
        cancelArm = schedule(30) { [weak self] in
            guard let self, self.armGeneration == generation, self.armed else { return }
            self.disarm()
        }
        changed()
    }
    func disarm() {
        armed = false; armGeneration += 1
        if suspension == nil { suspension = HotkeyMonitor.acquireSuspension() }
        authority.invalidateQueuedMouseStarts()
        cancelArm?(); cancelArm = nil
        if let active { active.invalidate(); self.active = nil; receipt.cancels += 1 }
        monitor?.reconcileMouseButtons() // owed ups remain eligible while suspended
        changed()
    }
    func focusLost() { disarm() }
    private func tapChanged(_ status: InputTapStatus) {
        guard !unavailable else { return } // a production retry cannot reopen this final phase
        switch status {
        case .ready: receipt.tap = .ready
        case .unavailable: receipt.tap = .unavailable; unavailable = true; disarm()
        case .disabled: receipt.tap = .disabled; interrupted = true; disarm()
        case .invalidPort: receipt.tap = .invalidPort; interrupted = true; disarm()
        case .permissionLost: receipt.tap = .permissionLost; interrupted = true; disarm()
        }
        changed()
    }
    private func receive(_ edge: MouseInputEdge) {
        switch edge {
        case .down(let press):
            guard armed, !finishing, scope(), press.isValid,
                  press.inputEpoch == authority.snapshot.epoch, press.admissionRevision == admission.revision,
                  press.suspensionRevision == HotkeyMonitor.suspensionRevision, !HotkeyMonitor.suspended else {
                press.invalidate(); receipt.refusedQueued += 1; changed(); return
            }
            active = press; receipt.accepted += 1
        case .up(let press, let short):
            if active == press {
                active = nil
                if short { receipt.quickTaps += 1 } else { receipt.holds += 1 }
            }
        case .cancel(let press):
            if active == press { active = nil; receipt.cancels += 1 }
        }
        changed()
    }
    func receiver(button: Int, down: Bool) {
        if button == selected?.buttonNumber {
            if down { receiverPresses += 1 } else { receiverReleases += 1 }
            if armed { receipt.receiverSelected += 1 }
        } else {
            if down { receiverOtherPresses += 1 } else { receiverOtherReleases += 1 }
            receipt.receiverOther += 1
        }
        changed()
    }
    // Returns true for NSApplication.TerminateReply.terminateLater.
    @discardableResult func finish(_ completed: @escaping () -> Void) -> Bool {
        guard !finishing else { return true }
        finishing = true; disarm(); cancelPhase?(); cancelPhase = nil
        if (monitor?.pendingMouseReleaseCount ?? 0) == 0 { finalize(); completed(); return false }
        cancelFinish = schedule(2) { [weak self] in
            guard let self else { return }
            self.cancelFinish = nil
            self.terminalTimeout = self.terminalTimeout || (self.monitor?.pendingMouseReleaseCount ?? 0) > 0
            self.finalize(); completed()
        }
        return true
    }
    private func finalize() {
        receipt.pendingAtFinish = monitor?.pendingMouseReleaseCount ?? 0
        if terminalTimeout || receipt.pendingAtFinish > 0 { receipt.result = .incomplete }
        else if unavailable || receipt.accepted == 0 { receipt.result = .notTested }
        else if interrupted || receipt.receiverSelected > 0 { receipt.result = .incomplete }
        else { receipt.result = .balanced }
        changed()
    }
    deinit {
        cancelArm?(); cancelPhase?(); cancelFinish?()
        if let suspension { HotkeyMonitor.releaseSuspension(suspension) }
        // Live production owners must never reach here before whole-process exit.
    }
}

enum CheckEvidence: String, Codable {
    case notTested, nativeSelectedSource, nativeCapture, productionPlayer, nativeTapOtherMouseOnly, userConfirmedHeard, userReportedNotHeard
}
enum ExitEvidence: String, Codable { case parentVerificationRequired }
enum ScopeEvidence: String, Codable { case notObserved, notClaimed, parentMustClassifyForcedExit }
struct InputCheckReceipt: Encodable {
    enum Kind: String, Codable { case input = "parla-input-check" }
    enum Architecture: String, Codable { case arm64, x86_64, other }
    struct OS: Encodable { var major: Int; var minor: Int }
    struct Evidence: Encodable {
        var layout: CheckEvidence, microphone: CheckEvidence, playback: CheckEvidence, mouse: CheckEvidence, heard: CheckEvidence
        let exit = ExitEvidence.parentVerificationRequired
        let threadSettlement = ScopeEvidence.notClaimed
        let keyboardMouseInterplay = ScopeEvidence.notObserved
        let physicalAction = ScopeEvidence.notObserved
        let forcedExit = ScopeEvidence.parentMustClassifyForcedExit
    }
    let kind = Kind.input, v = 1
    var arch: Architecture
    var osMajorMinor: OS
    var layout: LayoutReceipt, microphone: MicReceipt, mouse: MouseReceipt
    var evidence: Evidence {
        Evidence(layout: layout.read ? .nativeSelectedSource : .notTested,
                 microphone: microphone.runs.isEmpty ? .notTested : .nativeCapture,
                 playback: microphone.runs.contains { $0.listened } ? .productionPlayer : .notTested,
                 mouse: mouse.accepted > 0 ? .nativeTapOtherMouseOnly : .notTested,
                 heard: microphone.runs.contains { $0.heardConfirmed == true } ? .userConfirmedHeard
                    : microphone.runs.contains { $0.heardConfirmed == false } ? .userReportedNotHeard : .notTested)
    }
    enum CodingKeys: String, CodingKey { case kind, v, arch, osMajorMinor, layout, microphone, mouse, evidence }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(v, forKey: .v); try c.encode(arch, forKey: .arch)
        try c.encode(osMajorMinor, forKey: .osMajorMinor); try c.encode(layout, forKey: .layout)
        try c.encode(microphone, forKey: .microphone); try c.encode(mouse, forKey: .mouse); try c.encode(evidence, forKey: .evidence)
    }
}
