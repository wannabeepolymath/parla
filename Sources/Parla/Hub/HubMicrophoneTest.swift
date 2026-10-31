import AVFoundation
import Combine
import ParlaCore

enum MicrophoneTestLifecycle { case pageLeave, windowClose, resign, quit }

/// Main-thread control owner. Polls scalar facts at 10 Hz; tap never queues UI work.
/// Admission is retained through stopped review/Listen, and released only after close.
final class MicrophoneTestController: ObservableObject {
    enum State: Equatable {
        case idle, starting, signal, silentPCM, conversionFailure, noPCM, stoppedBeforePCM, stopped, routeLost, listening
        case refused(String), failed(String)
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    static let maximumRun: TimeInterval = 10
    @Published private(set) var state: State = .idle
    @Published private(set) var route = MicrophoneRoute()
    @Published private(set) var routeChanged = false
    @Published private(set) var level: Float = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var captureStatus: State = .idle
    private(set) var review: [Float] = []
    private let capture: MicrophoneTestCapturing?
    let admission: CaptureAdmission
    private let allowed: () -> Bool
    private let permission: () -> Bool
    private let playbackAllowed: () -> Bool
    private let now: () -> TimeInterval
    private let schedule: Schedule
    var playerFactory: () -> MicrophoneTestPlaying = { MicrophoneTestPlayer() }
    private var player: MicrophoneTestPlaying?
    private var lease: CaptureAdmission.Lease?
    private var suspension: UUID?
    private(set) var operation: UUID?
    private var playbackID: UUID?
    private var observedRoute = false
    private var started: TimeInterval = 0
    private var cancelTick: (() -> Void)?
    private(set) var capturing = false
    var hasReview: Bool { !review.isEmpty }
    var ownsSession: Bool { operation != nil }
    var playerActive: Bool { player != nil }

    init(capture: MicrophoneTestCapturing? = nil, admission: CaptureAdmission = CaptureAdmission(),
         allowed: @escaping () -> Bool = { false }, permission: @escaping () -> Bool = { false },
         playbackAllowed: @escaping () -> Bool = { true },
         now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping Schedule = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }) {
        self.capture = capture; self.admission = admission; self.allowed = allowed; self.permission = permission
        self.playbackAllowed = playbackAllowed; self.now = now; self.schedule = schedule
    }
    var beforeStart: () -> Void = {}
    func start() {
        beforeStart()
        clear()
        guard playbackAllowed() else {
            state = .refused("Stop recovery playback before starting a microphone test."); return
        }
        guard allowed(), let capture, let lease = admission.acquire(.microphoneTest) else {
            state = .refused("Finish the current dictation, tryout or shortcut recording first."); return
        }
        // Read-only permission evidence. No requestAccess call, even on Start.
        guard permission() else {
            admission.release(lease)
            state = .refused("Allow Microphone in General or System Settings → Privacy & Security, then start again."); return
        }
        let id = UUID(); operation = id; self.lease = lease
        suspension = HotkeyMonitor.acquireSuspension()
        state = .starting; captureStatus = .starting; started = now(); capturing = true
        do { try capture.start(operation: id, lease: lease) }
        catch {
            clear()
            state = .failed("Couldn’t start the input. Check Microphone permission and the input device, then retry.")
            return
        }
        guard operation == id else { return }
        poll(id)
    }
    private func poll(_ id: UUID) {
        guard operation == id, capturing else { return }
        cancelTick?(); cancelTick = nil
        if let facts = capture?.snapshot(operation: id) {
            if observedRoute, route != facts.route { routeChanged = true }
            route = facts.route; observedRoute = true
            sampleCount = min(AudioRecorder.microphoneTestMaxSamples, facts.sampleCount)
            level = facts.level.isFinite ? min(1, max(0, facts.level)) : 0
            if facts.ended == .deviceLost { captureStatus = .routeLost; stop(); return }
            if facts.conversionFailures > 0 { captureStatus = .conversionFailure }
            else if facts.facts?.firstPCM != nil { captureStatus = facts.hasSignal ? .signal : .silentPCM }
            else { captureStatus = now() - started >= CaptureDiagnosticState.firstPCMDeadline ? .noPCM : .starting }
            state = captureStatus
            if facts.ended == .sampleLimit { stop(); return }
        }
        if now() - started >= Self.maximumRun { stop(); return }
        cancelTick = schedule(min(0.1, Self.maximumRun - (now() - started))) { [weak self] in self?.poll(id) }
    }
    func stop() {
        guard let id = operation, capturing else { return }
        cancelTick?(); cancelTick = nil
        // Stop drains conversion and transfers audio; final scalar facts remain
        // available until Clear, so status describes the accepted review buffer.
        review = capture?.stop(operation: id) ?? []
        capturing = false
        if let facts = capture?.snapshot(operation: id) {
            if observedRoute, route != facts.route { routeChanged = true }
            route = facts.route; observedRoute = true
            if facts.ended == .deviceLost { captureStatus = .routeLost }
            else if facts.conversionFailures > 0 { captureStatus = .conversionFailure }
            else if facts.facts?.firstPCM != nil { captureStatus = facts.hasSignal ? .signal : .silentPCM }
            else { captureStatus = now() - started >= CaptureDiagnosticState.firstPCMDeadline ? .noPCM : .stoppedBeforePCM }
        }
        level = 0; sampleCount = review.count
        state = captureStatus == .routeLost ? .routeLost : .stopped
    }
    func listen() {
        guard operation != nil, !capturing, !review.isEmpty, player == nil else { return }
        guard playbackAllowed() else { state = .refused("Stop recovery playback before listening to this test."); return }
        let id = UUID(); playbackID = id
        let player = playerFactory(); self.player = player; state = .listening
        do {
            try player.play(samples: review, sampleRate: 16_000) { [weak self] success in
                guard let self, self.playbackID == id else { return }
                self.stopListening()
                if !success { self.state = .failed("Local playback failed. You can retry Listen or Clear.") }
            }
        } catch { stopListening(); state = .failed("Local playback failed. You can retry Listen or Clear.") }
    }
    func stopListening() {
        playbackID = nil; player?.stop(); player = nil
        if state == .listening { state = .stopped }
    }
    func clear() {
        let id = operation; operation = nil // invalidate callbacks before disposal/release
        cancelTick?(); cancelTick = nil
        stopListening()
        if let id { capture?.clear(operation: id) }
        capturing = false; review = []; sampleCount = 0; level = 0
        route = MicrophoneRoute(); routeChanged = false; observedRoute = false; state = .idle; captureStatus = .idle
        if let lease { admission.release(lease) }; lease = nil
        if let suspension { HotkeyMonitor.releaseSuspension(suspension) }; suspension = nil
    }
    func lifecycle(_ event: MicrophoneTestLifecycle) { clear() }
    deinit { clear() }
}

extension HubModel {
    func startMicrophoneTest() { clearLastOriginal(); microphoneTest.start() }
    func stopMicrophoneTest() { microphoneTest.stop() }
    func listenMicrophoneTest() { microphoneTest.listen() }
    func stopListeningMicrophoneTest() { microphoneTest.stopListening() }
    func clearMicrophoneTest() { microphoneTest.clear() }
    func microphoneTestLifecycle(_ event: MicrophoneTestLifecycle) { microphoneTest.lifecycle(event) }
}
