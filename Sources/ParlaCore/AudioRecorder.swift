import AVFoundation
import AudioToolbox
import CoreAudio

public final class AudioRecorder {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    /// Why a capture ended by itself, rather than by the user releasing fn.
    public enum EndReason: Equatable, Sendable { case sampleLimit, deviceLost }

    public enum RecorderError: Error {
        /// The input node reported a 0 Hz / 0 ch format. `installTap` throws an
        /// ObjC exception on one of those, which Swift cannot catch — so refuse
        /// first. Seen when a route change lands mid-build (FluidVoice #752).
        case noInputFormat
        case captureBusy
    }

    /// Hard ceiling on one capture: 10 minutes at 16 kHz (~38 MB of Float).
    /// Also the ceiling on a forgotten hands-free latch, which is otherwise
    /// indefinite sustained Metal load — the app's only thermal risk.
    public static let maxSamples = 10 * 60 * 16_000

    /// Core Audio fires a burst of route changes for one physical event, and
    /// each rebuild provokes the next one. Only the last scheduled rebuild runs.
    static let rebuildDebounce: TimeInterval = 0.5

    private var engine: AVAudioEngine?
    private let testEngine: MicrophoneCaptureEngine?
    public let admission: CaptureAdmission
    private var captureLease: CaptureAdmission.Lease?
    private var meetingID: UUID? // control-side exclusion; callback reads only under lock
    private let meetingConverter: ((AVAudioFormat) -> MeetingPCMConverting?)?
    private enum UnsavedPurpose: Equatable { case microphoneTest(UUID), guidedTemplate(session: UUID, capture: UUID) }
    private var unsavedPurpose: UnsavedPurpose?
    private var diagnosticID: UUID? {
        get { if case .microphoneTest(let id) = unsavedPurpose { return id }; return nil }
        set { unsavedPurpose = newValue.map(UnsavedPurpose.microphoneTest) }
    }
    private var guidedScope: (session: UUID, lease: CaptureAdmission.Lease)?
    private let guidedDrain: (() -> Result<[Float], GuidedTemplateFailure>)?
    public var onGuidedEnd: ((UUID, UUID, EndReason) -> Void)?
    private var diagnosticRequestedUID: String?
    private var warmthSuspended = false
    private var captureOperationID: UUID?
    private var captureStartedAt: TimeInterval = 0
    private var postStartPCM = false
    private var canceledCaptureDisrupted = false
    private var captureFormat: AVAudioFormat?
    private var transferring = false
    private let captureClock: () -> TimeInterval
    private var engineEpoch = UUID() // under lock, rejects old engine callbacks
    private var localRoute = MicrophoneRoute()
    private var latestLevel: Float = 0
    private var hasSignal = false
    private var sampleCeiling = AudioRecorder.maxSamples
    private var cancelRebuild: (() -> Void)?
    private let scheduleRoute: CaptureDiagnosticCoordinator.Schedule
    private let conversion: ((AVAudioPCMBuffer) -> [Float]?)?
    private var engineRunning: Bool { testEngine?.isRunning ?? engine?.isRunning ?? false }
    private var samples: [Float] = []
    private var failedBuffers = 0
    private var ended: EndReason?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()

    /// Tap-side state, under `lock`: `capturing` decides whether a converted
    /// chunk joins the dictation or the pre-roll ring.
    private var capturing = false
    private var preRoll = PreRollRing()
    /// When the tap last delivered a buffer, live or pre-roll. Under `lock`.
    private var lastFeed: TimeInterval?
    private var captureDiagnostics: CaptureDiagnosticState?

    public func diagnosticSnapshot(for operationID: UUID) -> CaptureDiagnosticState? {
        lock.withLock { captureDiagnostics?.operationID == operationID ? captureDiagnostics : nil }
    }

    /// Legacy engine-side state is controlled on main by the hotkey/notification
    /// paths. Explicit meeting entry transfers the idle engine slot to its own
    /// serial control executor while meetingID excludes those legacy paths.
    private var warm = false
    /// Whether the mic was granted at the moment the *current* engine's input
    /// unit started. `warm` only records that the app wants warmth, so without
    /// this a unit built unauthorized (start()'s cold path builds whatever TCC
    /// says) would be latched warm and reused forever — see shouldTeardown.
    private var builtAuthorized = false
    private var boundDevice: AudioDeviceID?
    private var rebuildGeneration = 0
    /// Mid-capture rebuilds since start() — see rebuildAction.
    private var resumes = 0

    /// Shared with the audio thread now that the engine can outlive a capture:
    /// stop() flushes the filter tail while the tap is still converting pre-roll.
    private let resampler = Resampler()
    private let resamplerLock = NSLock()

    /// Called with each converted buffer's RMS level. Fires on the audio
    /// thread — callers must hop to main before touching UI.
    public var onLevel: ((Float) -> Void)?

    /// Called once when the capture ends on its own (see endCapture). Fires off
    /// the main thread; the owner is expected to run its ordinary stop path.
    public var onEnd: ((EndReason) -> Void)?

    /// Core Audio UID of the mic to record from. nil (or an unresolvable UID)
    /// ⇒ system default input. Applied at each start() while the engine is idle.
    public var inputDeviceUID: String?

    public init(engine: MicrophoneCaptureEngine? = nil, admission: CaptureAdmission = CaptureAdmission(),
                conversion: ((AVAudioPCMBuffer) -> [Float]?)? = nil,
                guidedDrain: (() -> Result<[Float], GuidedTemplateFailure>)? = nil,
                captureClock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                meetingConverter: ((AVAudioFormat) -> MeetingPCMConverting?)? = nil,
                scheduleRoute: @escaping CaptureDiagnosticCoordinator.Schedule = { delay, action in
                    let work = DispatchWorkItem(block: action)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                    return { work.cancel() }
                }) {
        self.meetingConverter = meetingConverter
        self.guidedDrain = guidedDrain
        self.captureClock = captureClock
        self.testEngine = engine; self.admission = admission; self.conversion = conversion; self.scheduleRoute = scheduleRoute
    }

    // MARK: - Input device selection (macOS Core Audio HAL)

    public struct InputDevice: Equatable {
        public let uid: String
        public let name: String
        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    /// All Core Audio devices that expose an input stream, newest API order.
    public static func availableInputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var str: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &str) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let str else { return nil }
        return str as String
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Transport of the device a start() would open: the selected one, or the
    /// system default when no UID is set.
    private static func transportRaw(of device: AudioDeviceID?) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard let id = device ?? defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        else { return nil }
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw) == noErr else { return nil }
        return raw
    }

    /// Trace-only label (see Trace.transportName).
    private static func transport(of device: AudioDeviceID?) -> String {
        Trace.transportName(transportRaw(of: device) ?? kAudioDeviceTransportTypeUnknown)
    }

    /// The warm-engine gate, pure half. Holding a Bluetooth *input* open drags
    /// the link from A2DP down to 16 kHz HFP/SCO for as long as it is held —
    /// the user's music degrades and headset battery roughly halves — and idle
    /// prewarm on the route changes that causes is self-sustaining
    /// (docs/research/03-latency.md §7: 3,714 route changes in 40 h idle).
    static func isBluetoothTransport(_ raw: UInt32) -> Bool {
        raw == kAudioDeviceTransportTypeBluetooth || raw == kAudioDeviceTransportTypeBluetoothLE
    }

    /// An unclassifiable transport is treated as not-Bluetooth: refusing to warm
    /// on every device we cannot read would disable the feature outright.
    static func isBluetooth(_ device: AudioDeviceID?) -> Bool {
        guard let raw = transportRaw(of: device) else { return false }
        return isBluetoothTransport(raw)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Something is driving the default output, so whatever it is was in the
    /// room and the mic's pre-roll picked it up. Pressing fn cannot un-record
    /// audio the user did not intend to hand over, so the ring is dropped.
    /// ponytail: `IsRunningSomewhere` is true for an app merely holding the
    /// output open, so this over-discards. Erring that way is the safe one; a
    /// precise signal needs the private MediaRemote API.
    static func mediaPlaying() -> Bool {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Monotonic seconds. Date jumps with NTP and would poison a pre-roll age.
    static func nowSeconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Root-mean-square amplitude of samples; 0 for empty input.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// Convert one self-contained PCM buffer to 16kHz mono Float32 samples.
    /// Fresh converter, drained immediately — for offline whole-buffer work.
    /// The capture path uses the recorder's own resampler instead, so that the
    /// filter state carries across tap buffers.
    public static func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let resampler = Resampler()
        return (resampler.convert(buffer, to: targetFormat) ?? []) + resampler.flush()
    }

    /// Tap buffers the converter dropped during the last recording. Without a
    /// count, a total conversion failure is indistinguishable from a silent mic.
    public func conversionFailures() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failedBuffers
    }

    /// Mark the capture ended, so the tap stops accumulating and `onEnd` fires
    /// once. Deliberately does NOT tear the engine down: stop() stays the single
    /// place that finalizes, so a mic that dies mid-dictation produces the same
    /// transcript as a normal fn-up instead of silently producing nothing.
    public func endCapture(_ reason: EndReason) {
        lock.lock()
        guard ended == nil else { lock.unlock(); return }
        ended = reason
        lock.unlock()
        guard lock.withLock({ meetingID == nil }) else { return }
        let purpose = lock.withLock { unsavedPurpose }
        if case .guidedTemplate(let session, let capture) = purpose { onGuidedEnd?(session, capture, reason) }
        else if purpose == nil { onEnd?(reason) }
    }

    /// Tap-side accumulate. nil chunk = the converter dropped that buffer.
    /// Once the capture has ended, further buffers are discarded — the cap is a
    /// ceiling on memory, so it must hold until the owner's stop() lands.
    func append(_ chunk: [Float]?) {
        lock.lock()
        guard ended == nil else { lock.unlock(); return }
        if let chunk {
            if unsavedPurpose != nil {
                let rms = Self.rms(chunk)
                if rms.isFinite {
                    samples.append(contentsOf: chunk.prefix(max(0, sampleCeiling - samples.count)))
                    latestLevel = rms; hasSignal = hasSignal || rms > 0.0001
                } else { failedBuffers += 1; latestLevel = 0 }
            } else { samples.append(contentsOf: chunk) }
        } else { failedBuffers += 1 }
        let hitCap = samples.count >= sampleCeiling
        lock.unlock()
        if hitCap { endCapture(.sampleLimit) }
    }

    // MARK: - Warm engine

    /// Turn the warm engine on or off, and act on it now. On: build the engine,
    /// bind the device, install the tap and start filling the pre-roll ring —
    /// everything `start()` would otherwise do inside the fn-down handler
    /// (240–270 ms built-in, 650–700 ms USB; docs/research/03-latency.md §1).
    /// Off: hand the mic back, so macOS's orange indicator goes out.
    ///
    /// Warmth is the user's call (`Settings.warmMic`), because its price is that
    /// indicator staying lit for as long as Parla runs. Call at launch, on device
    /// change, and whenever the setting is saved — it is idempotent both ways.
    ///
    /// Deliberately does NOT rebind a warm engine already running on another mic
    /// — warmUp()'s `!engine.isRunning` guard makes that a no-op, which is also
    /// what keeps a mid-dictation call (mic switched while hands-free is latched)
    /// from pulling the tap out from under the capture. start() self-heals on the
    /// next press, so a mic switch costs one cold open, never a wrong recording.
    ///
    /// Switching off mid-dictation is likewise deferred rather than obeyed on the
    /// spot: tearing the tap out from under a latched hands-free capture would
    /// lose what is being spoken. `warm` is false from here on, so stop()'s
    /// shouldTeardown finalizes normally and its trailing warmUp() is a no-op.
    public func setWarm(_ on: Bool) {
        warm = on
        guard meetingID == nil, unsavedPurpose == nil, guidedScope == nil, !warmthSuspended else { return }
        guard !on else { return warmUp() }
        lock.lock()
        let live = capturing
        lock.unlock()
        if !live { teardown() }
    }

    /// Idempotent build of the warm engine, subject to the permission and
    /// Bluetooth gates.
    private func warmUp() {
        guard meetingID == nil, warm, !warmthSuspended, unsavedPurpose == nil, guidedScope == nil, !engineRunning else { return }
        // An input unit started before TCC grants the mic runs happily and
        // delivers zeros; the later grant never reaches a unit that is already
        // going. Without this, a fresh install would latch a permanently silent
        // warm engine at launch and every dictation until relaunch would hear
        // nothing. start()'s cold path is unaffected, and the stop() after the
        // first dictation re-warms for real.
        guard testEngine != nil || AudioRecorder.micAuthorized() else { return }
        let device = testEngine == nil ? inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:)) : nil
        guard testEngine != nil || !AudioRecorder.isBluetooth(device) else { return }
        // A warm engine is a nicety; failing to get one just means the next
        // start() pays the cold open it always used to.
        try? build(device: device)
    }

    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// stop()'s teardown decision, pure so it can be checked without an engine.
    /// `builtAuthorized` is the crux: a unit started before TCC granted the mic
    /// runs and delivers zeros forever, and the later grant never reaches it —
    /// so it must be handed back at stop(), warm or not, and rebuilt against the
    /// fresh grant. That also covers a grant that lands mid-dictation.
    /// `capturedNothing` is the other dead-unit signal: a capture with not one
    /// sample in it, pre-roll included, means the tap is no longer being fed.
    static func shouldTeardown(warm: Bool, builtAuthorized: Bool, bluetooth: Bool,
                               capturedNothing: Bool) -> Bool {
        !warm || !builtAuthorized || bluetooth || capturedNothing
    }

    /// What a settled route change calls for, pure so it can be checked without
    /// an engine. Idle, the warm engine is rebuilt against the new route. Mid-
    /// dictation the question is whether the engine survived: AVAudioEngine stops
    /// itself on a configuration change and nothing else restarts it, so a
    /// stopped one has to be rebuilt under the capture — while a running one was
    /// built by this very press, after the change, and must be left alone.
    ///
    /// A rebuild can itself provoke the next change (opening an AirPods mic drops
    /// the link to HFP). Each lap under a capture is a hole in the dictation, so
    /// past `maxResumes` the capture ends and what was said is finalized.
    /// Tap buffers arrive every ~85 ms; this many seconds without one, by the
    /// time the debounce fires, means the engine is not feeding whatever
    /// `isRunning` says. nil = built and not yet fed, which proves nothing.
    static let feedGap: TimeInterval = 0.3
    static func recentlyFed(lastFeed: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastFeed else { return true }
        return now - lastFeed <= feedGap
    }

    enum RebuildAction: Equatable { case none, resumeCapture, endCapture, rewarm }
    /// ponytail: a guess with headroom — one real device switch costs one or two
    /// laps. Raise it if `Parla.log` ever shows dictations ending here.
    static let maxResumes = 3
    static func rebuildAction(live: Bool, engineRunning: Bool, resumes: Int) -> RebuildAction {
        guard live else { return .rewarm }
        guard !engineRunning else { return .none }
        return resumes < maxResumes ? .resumeCapture : .endCapture
    }

    private func build(device: AudioDeviceID?) throws {
        let epoch = UUID()
        lock.withLock { engineEpoch = epoch; lastFeed = nil }
        if let testEngine {
            try testEngine.start(requestedUID: unsavedPurpose == nil ? inputDeviceUID : diagnosticRequestedUID, receive: { [weak self] buffer in
                self?.receive(buffer, epoch: epoch)
            }, changed: { [weak self] in self?.configurationChanged(epoch: epoch) })
            updateDiagnosticRoute(); return
        }
        let engine = AVAudioEngine() // fresh: a reused engine caches the old device's format
        self.engine = engine
        let input = engine.inputNode
        // Point the AUHAL input unit at the chosen device before reading its
        // format. An unresolvable UID leaves the unit on the system default.
        // ponytail: resolved per build so unplugging the selected mic self-heals.
        if let device, let unit = input.audioUnit {
            var dev = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputFormat }
        resamplerLock.lock(); resampler.reset(); resamplerLock.unlock()
        lock.lock(); lastFeed = nil; lock.unlock() // this engine has not fed anything yet
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.receive(buf, epoch: epoch)
        }
        // Read *before* the start that may raise the TCC prompt: whatever the
        // user answers afterwards cannot reach a unit that is already running.
        let authorized = AudioRecorder.micAuthorized()
        do {
            try engine.start()
        } catch {
            // A failed build must leave the recorder restartable.
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        boundDevice = device
        builtAuthorized = authorized
        updateDiagnosticRoute()
        observeConfigChanges()
    }

    /// Read the bound input AU, not the requested UID/default device. No labels
    /// or identifiers leave this method; HAL failure means unknown.
    private func updateDiagnosticRoute() {
        if let testEngine {
            lock.withLock { localRoute = testEngine.route }
            return
        }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var route = DiagnosticRoute.unknown
        var evidence = DiagnosticRouteEvidence.unknown
        if let unit = engine?.inputNode.audioUnit,
           AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr,
           device != kAudioObjectUnknown, let transport = AudioRecorder.transportRaw(of: device) {
            evidence = .inputAudioUnit
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: route = .builtIn
            case kAudioDeviceTransportTypeUSB: route = .usb
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: route = .bluetooth
            case kAudioDeviceTransportTypeVirtual: route = .virtual
            case kAudioDeviceTransportTypeAggregate: route = .aggregate
            case kAudioDeviceTransportTypeUnknown: route = .unknown
            default: route = .other
            }
        }
        let actualUID = device == kAudioObjectUnknown ? nil : Self.stringProperty(device, kAudioDevicePropertyDeviceUID)
        let name = device == kAudioObjectUnknown ? nil : Self.stringProperty(device, kAudioObjectPropertyName)
        let requestedUID = unsavedPurpose == nil ? inputDeviceUID : diagnosticRequestedUID
        lock.withLock {
            localRoute = MicrophoneRoute(name: name, fallback: actualUID.map { requestedUID != nil && requestedUID != $0 })
            if capturing { captureDiagnostics?.route = route; captureDiagnostics?.routeEvidence = evidence }
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer, epoch: UUID) {
        let receivedAt = Self.nowSeconds()
        resamplerLock.lock()
        guard lock.withLock({ engineEpoch == epoch }) else { resamplerLock.unlock(); return }
        lock.withLock {
            if capturing {
                if let captureFormat, captureFormat != buffer.format { canceledCaptureDisrupted = true }
                captureFormat = buffer.format
            }
        }
        let chunk: [Float]?
        if let conversion { chunk = conversion(buffer) }
        else { chunk = resampler.convert(buffer, to: Self.targetFormat) }
        if lock.withLock({ if case .guidedTemplate = unsavedPurpose { return captureClock() - captureStartedAt >= 30 || captureClock() < captureStartedAt }; return false }) {
            endCapture(.sampleLimit)
        }
        let live = route(chunk, hasPCM: buffer.frameLength > 0, receivedAt: receivedAt)
        let diagnostic = lock.withLock { unsavedPurpose != nil }
        resamplerLock.unlock()
        if live, !diagnostic {
            Trace.mark(.firstPCM)
            onLevel?(chunk.map(Self.rms) ?? 0)
        }
    }

    /// Tap-side fan-out. Returns true when the chunk joined the dictation, false
    /// when it went to the pre-roll ring (warm engine, no capture in flight).
    private func route(_ chunk: [Float]?, hasPCM: Bool, receivedAt: TimeInterval) -> Bool {
        let now = AudioRecorder.nowSeconds()
        lock.lock()
        guard meetingID == nil else { lock.unlock(); return false }
        let live = capturing
        lastFeed = now
        if live, hasPCM, receivedAt >= captureStartedAt, let chunk, !chunk.isEmpty { postStartPCM = true }
        if live { captureDiagnostics?.input(hasPCM: hasPCM, conversionFailed: chunk == nil, now: receivedAt) }
        if !live, unsavedPurpose == nil, guidedScope == nil, let chunk { preRoll.write(chunk, now: now) }
        lock.unlock()
        guard live else { return false }
        append(chunk)
        return true
    }

    private func configurationChanged(epoch: UUID) {
        guard lock.withLock({ engineEpoch == epoch }) else { return }
        lock.withLock { if capturing { canceledCaptureDisrupted = true } }
        if lock.withLock({ if case .guidedTemplate = unsavedPurpose { return true }; return false }) {
            endCapture(.deviceLost); return
        }
        scheduleRebuild()
    }

    private func observeConfigChanges() {
        let epoch = lock.withLock { engineEpoch }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The route moved (device swapped, AirPods connected, rate changed)
            // and the engine has stopped itself. Idle or mid-dictation, the
            // answer is a rebuild once the burst ends — see scheduleRebuild.
            self?.configurationChanged(epoch: epoch)
        }
    }

    /// Trailing debounce behind a generation counter: a rebuild itself provokes
    /// the next configuration change, so an undebounced handler is a loop that
    /// never settles (docs/research/03-latency.md §7, trap 2).
    private func scheduleRebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        cancelRebuild?()
        cancelRebuild = scheduleRoute(AudioRecorder.rebuildDebounce) { [weak self] in
            guard let self, self.meetingID == nil, self.rebuildGeneration == generation else { return }
            self.lock.lock()
            let live = self.capturing
            let fed = AudioRecorder.recentlyFed(lastFeed: self.lastFeed, now: AudioRecorder.nowSeconds())
            self.lock.unlock()
            if self.unsavedPurpose != nil {
                self.updateDiagnosticRoute()
                if !self.engineRunning || !fed { self.endCapture(.deviceLost) }
                return // diagnostic capture never rebuilds/warms behind its owner
            }
            switch AudioRecorder.rebuildAction(live: live, engineRunning: self.engineRunning && fed,
                                               resumes: self.resumes) {
            case .none:
                self.updateDiagnosticRoute()
            case .endCapture:
                NSLog("Parla recorder: route would not settle, ending the capture")
                self.endCapture(.deviceLost)
            case .rewarm:
                self.teardown()
                self.warmUp() // re-reads the transport: AirPods leave the engine cold
            case .resumeCapture:
                // Same samples, new engine: `capturing` never drops, so the tap
                // on the rebuilt engine appends to the dictation already in
                // flight. What was said during the debounce and the device open
                // is lost — unavoidable, the old engine was already stopped.
                // No warm gate here: the Bluetooth rule is about *holding* a
                // headset between dictations, not about recording from one.
                self.resumes += 1
                self.teardown()
                do {
                    try self.build(device: self.inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:)))
                    NSLog("Parla recorder: route changed mid-dictation, capture resumed")
                } catch {
                    // No usable input left (unplugged, seized by another app):
                    // end with a reason so stop() still finalizes what was said.
                    self.endCapture(.deviceLost)
                }
            }
        }
    }

    /// Stop the engine and hand the device back. Stopping is not enough on its
    /// own: the AUHAL unit stays bound, which keeps a headset in the 16 kHz HFP
    /// profile, so the unit is explicitly pointed at kAudioObjectUnknown.
    private func teardown() {
        rebuildGeneration &+= 1
        cancelRebuild?(); cancelRebuild = nil
        // Serialize invalidation with the converter; a queued tap cannot feed a new run.
        resamplerLock.withLock { lock.withLock { engineEpoch = UUID() } }
        if let testEngine {
            testEngine.stop()
            lock.withLock { preRoll.discard() }
            return
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { lock.withLock { preRoll.discard() }; return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        if let unit = input.audioUnit {
            var unknown = AudioDeviceID(kAudioObjectUnknown)
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &unknown,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        self.engine = nil
        boundDevice = nil
        builtAuthorized = false // describes the built engine, and there is none now
        lock.lock(); preRoll.reset(); lock.unlock()
    }

    /// Option L: pure caller validation never reserves. This explicit entry alone claims
    /// the shared .meeting lease, after owner durable admission/hold/two-slot precharge.
    /// Disabled by default, including when a fake engine was injected.
    @MainActor public func startMeeting(source: UUID, generation: UInt64, ingress: MeetingAudioIngress,
                                        enabled: Bool = false) -> MeetingMicrophoneStart {
        guard enabled,generation > 0,ingress.context.source == source,ingress.context.sourceGeneration == generation,
              ingress.facts.open,ingress.facts.slots == 2,meetingID == nil,
              unsavedPurpose == nil,guidedScope == nil,captureLease == nil,!transferring,
              !lock.withLock({ capturing }),let lease = admission.acquire(.meeting) else { return .notStarted }
        let id = UUID()
        // Invalidate legacy callbacks without joining resamplerLock on MainActor.
        // Any previously entered warm body can finish independently on its own thread.
        lock.withLock { meetingID = id; engineEpoch = UUID(); samples = []; preRoll.discard() }
        warmthSuspended = true; rebuildGeneration &+= 1
        cancelRebuild?(); cancelRebuild = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }; configObserver = nil
        let transport = MeetingTransport(engine:engine,injected:testEngine,requestedUID:inputDeviceUID)
        engine = nil; boundDevice = nil; builtAuthorized = false
        let run = MeetingRecorderRun(ingress:ingress,makeConverter:meetingConverter ?? { NativeMeetingConverter(format:$0) })
        let task = Task { @MainActor [self,run,transport] in
            // One bounded control queue, never a task per callback or a timeout loser.
            await transport.perform { [self] in
                transport.retirePrevious()
                resamplerLock.withLock { resampler.discard() }
                guard !run.gate.isClosed else { return }
                do { try transport.start(gate:run.gate) }
                catch { run.requestStop(.unknownCoverage) }
            }
            await run.gate.waitForStop()
            // stop may block and may itself wait for a tap. No recorder/ingress/gate lock,
            // resamplerLock or MainActor is held across this worker call.
            await transport.perform { transport.stop() }
            await run.gate.waitForBodies()
            let closed = await transport.perform { run.finish() }
            guard closed else { await run.retainFailedClosure(); return }
            // finish disposes converter/storage and severs the gate before exact release.
            if lock.withLock({ meetingID == id }),admission.owns(lease) {
                lock.withLock { meetingID = nil }; admission.release(lease)
            }
        }
        return .actual(.init(task:task,stop:{ run.requestStop() }))
    }

    /// The recorder's single engine slot is transferred here, never duplicated. Legacy
    /// idle transport is stopped and released before a meeting engine can be created.
    /// Only this serial executor accesses the transferred native slot.
    private final class MeetingTransport: @unchecked Sendable {
        private var engine: AVAudioEngine?
        private let injected: MicrophoneCaptureEngine?, requestedUID: String?
        private var tap = false, observer: NSObjectProtocol?
        private let queue = DispatchQueue(label:"Parla.meeting.recorder-control")
        init(engine: AVAudioEngine?, injected: MicrophoneCaptureEngine?, requestedUID: String?) {
            self.engine = engine; self.injected = injected; self.requestedUID = requestedUID
            tap = engine != nil // the ordinary slot installs its tap before retaining a running engine
        }
        private struct Operation<Value>: @unchecked Sendable { let execute: () -> Value }
        func perform<Value: Sendable>(_ work: @escaping () -> Value) async -> Value {
            let operation = Operation(execute:work)
            return await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning:operation.execute()) }
            }
        }
        func retirePrevious() {
            if let injected { if injected.isRunning { injected.stop() }; return }
            stop()
        }
        func start(gate: MeetingSourceGate) throws {
            if let injected {
                try injected.start(requestedUID:requestedUID,receive:{ [gate] in gate.receive($0) },changed:{ [gate] in gate.changed() })
                return
            }
            guard !gate.isClosed else { return }
            let fresh = AVAudioEngine(); engine = fresh
            let input = fresh.inputNode
            if let requestedUID,let device = AudioRecorder.deviceID(forUID:requestedUID),let unit = input.audioUnit {
                var device = device
                AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let format = input.outputFormat(forBus:0)
            let shape = MeetingAudioIngress.InputShape(rate:format.sampleRate,channels:Int(format.channelCount),frames:0)
            guard shape.valid,format.commonFormat == .pcmFormatFloat32,!format.isInterleaved else { throw RecorderError.noInputFormat }
            input.installTap(onBus:0,bufferSize:4096,format:format) { [gate] buffer,_ in gate.receive(buffer) }; tap = true
            observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:fresh,queue:nil) { [gate] _ in gate.changed() }
            try fresh.start() // synchronous PCM followed by throw still belongs to the actual task
        }
        func stop() {
            if let injected { injected.stop(); return }
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
            guard let engine else { return }
            if tap { engine.inputNode.removeTap(onBus:0); tap = false }
            engine.stop()
            if let unit = engine.inputNode.audioUnit {
                var unknown = AudioDeviceID(kAudioObjectUnknown)
                AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&unknown,UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            self.engine = nil
        }
    }

    // MARK: - Capture

    public func start(diagnosticOperation: UUID? = nil) throws {
        guard meetingID == nil, unsavedPurpose == nil, guidedScope == nil, !transferring else { throw RecorderError.captureBusy }
        // A new ordinary press deliberately replaces the current ordinary capture.
        // Auxiliary owners must release their own lease before dictation can enter.
        guard let lease = captureLease ?? admission.acquire(.dictation), admission.owns(lease) else { throw RecorderError.captureBusy }
        captureLease = lease
        warmthSuspended = false
        sampleCeiling = Self.maxSamples
        do { try startCapture(diagnosticOperation: diagnosticOperation) }
        catch { teardown(); admission.release(lease); captureLease = nil; throw error }
    }

    private func startCapture(diagnosticOperation: UUID? = nil) throws {
        let device = testEngine == nil ? inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:)) : nil
        // Behind the trace gate so a normal start pays no extra HAL queries.
        if Trace.enabled { Trace.setTransport(AudioRecorder.transport(of: device)) }
        // A warm engine bound to some other mic is worse than no warm engine — and
        // so is one that still reports isRunning but has stopped feeding its tap.
        // Nothing else would ever rebuild that one (stop() keeps a warm engine,
        // warmUp() skips a running one), so every dictation would be silence
        // until relaunch. The pre-roll ring going stale is the tell.
        lock.lock()
        let wedged = preRoll.isStale(now: AudioRecorder.nowSeconds())
        lock.unlock()
        if engineRunning && (boundDevice != device || wedged) { teardown() }

        // The ring is claimed before `capturing` flips so the splice has no gap
        // and no overlap: every chunk lands on exactly one side of it.
        let mediaPlaying = testEngine == nil && engineRunning ? AudioRecorder.mediaPlaying() : false
        lock.lock()
        let preRolled = preRoll.take(now: AudioRecorder.nowSeconds(), mediaPlaying: mediaPlaying)
        captureOperationID = diagnosticOperation; captureStartedAt = captureClock(); postStartPCM = false
        canceledCaptureDisrupted = false; captureFormat = nil
        captureDiagnostics = diagnosticOperation.map { CaptureDiagnosticState(operationID: $0, started: AudioRecorder.nowSeconds()) }
        samples = preRolled
        failedBuffers = 0
        ended = nil
        capturing = true
        lock.unlock()
        resumes = 0

        if !engineRunning {
            // Cold path — what every press used to pay. Also the Bluetooth path:
            // the gate refuses to *hold* a headset open, not to record from one.
            do { try build(device: device) } catch {
                lock.lock(); capturing = false; lock.unlock()
                throw error
            }
        }
        updateDiagnosticRoute()
        Trace.mark(.recorderStartReturned)
    }

    /// Copy of the samples captured so far, under the lock. Safe to call
    /// mid-recording (the streaming loop polls this).
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        // Guided PCM is available only through its exact owned capture API.
        if meetingID != nil { return [] }
        if case .guidedTemplate = unsavedPurpose { return [] }
        return guidedScope == nil ? samples : []
    }

    /// Copy under the recorder lock; a stale capture cannot sample its successor.
    /// Array(slice) owns just the suffix, rather than retaining the full recording.
    public func previewSuffix(operationID: UUID) -> RecognitionPreviewSuffix? {
        lock.withLock {
            guard unsavedPurpose == nil, guidedScope == nil, capturing, captureOperationID == operationID else { return nil }
            return RecognitionPreviewSuffix(copying: samples)
        }
    }


    /// Exact whole-session ownership suspends warmth even when no take exists.
    public func reserveGuidedTemplate(session: UUID, lease: CaptureAdmission.Lease) throws {
        guard meetingID == nil, lease.owner == .guidedTemplate, admission.owns(lease), guidedScope == nil,
              unsavedPurpose == nil, captureLease == nil, !lock.withLock({ capturing }) else { throw RecorderError.captureBusy }
        guidedScope = (session, lease); warmthSuspended = true
        teardown(); resamplerLock.withLock { resampler.discard() }
        lock.withLock { samples = []; preRoll.discard() }
    }
    private func ownsGuided(_ session: UUID, _ lease: CaptureAdmission.Lease) -> Bool {
        guidedScope?.session == session && guidedScope?.lease == lease && lease.owner == .guidedTemplate && admission.owns(lease)
    }
    public func startGuidedTemplate(session: UUID, capture: UUID, lease: CaptureAdmission.Lease, inputUID: String?) throws {
        guard ownsGuided(session, lease), unsavedPurpose == nil else { throw RecorderError.captureBusy }
        teardown(); resamplerLock.withLock { resampler.discard() }
        lock.withLock {
            unsavedPurpose = .guidedTemplate(session: session, capture: capture)
            diagnosticRequestedUID = inputUID; localRoute = MicrophoneRoute()
            samples = []; preRoll.discard(); sampleCeiling = 480_000
            captureStartedAt = captureClock(); captureFormat = nil; canceledCaptureDisrupted = false
            postStartPCM = false; failedBuffers = 0; ended = nil; latestLevel = 0; hasSignal = false; capturing = true
        }
        do { try build(device: testEngine == nil ? inputUID.flatMap(Self.deviceID(forUID:)) : nil) }
        catch { clearGuidedTemplate(session: session, capture: capture, lease: lease); throw error }
    }
    public func stopGuidedTemplate(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) -> GuidedCaptureResult? {
        guard ownsGuided(session, lease), unsavedPurpose == .guidedTemplate(session: session, capture: capture) else { return nil }
        teardown() // joins in-flight conversion and invalidates old tap epochs
        return resamplerLock.withLock {
            defer { resampler.discard() }
            let drain = guidedDrain?() ?? resampler.flushResult()
            return lock.withLock {
                capturing = false
                var complete = ended == nil && failedBuffers == 0 && !canceledCaptureDisrupted
                let elapsed = captureClock() - captureStartedAt
                complete = complete && elapsed >= 0 && elapsed < 30
                switch drain {
                case .failure: complete = false
                case .success(let tail):
                    if !tail.allSatisfy(\.isFinite) || tail.count > sampleCeiling - samples.count { complete = false }
                    samples.append(contentsOf: tail.prefix(max(0, sampleCeiling - samples.count)))
                }
                complete = complete && samples.count < sampleCeiling && samples.allSatisfy(\.isFinite)
                let output = GuidedCaptureResult(samples: complete ? samples : [], route: localRoute, complete: complete)
                samples = []; preRoll.discard(); unsavedPurpose = nil; captureFormat = nil; diagnosticRequestedUID = nil
                latestLevel = 0; hasSignal = false; postStartPCM = false
                return output
            }
        }
    }
    public func clearGuidedTemplate(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) {
        _ = stopGuidedTemplate(session: session, capture: capture, lease: lease)
    }
    public func releaseGuidedTemplate(session: UUID, lease: CaptureAdmission.Lease) {
        guard ownsGuided(session, lease), unsavedPurpose == nil else { return }
        guidedScope = nil // warmth remains suspended until an existing explicit entry
    }

    public static let microphoneTestMaxSamples = 160_000

    /// Explicit entry only. Closing a test never silently reopens the input.
    public func resumeWarmthOnExplicitEntry() {
        guard meetingID == nil, unsavedPurpose == nil, guidedScope == nil else { return }
        warmthSuspended = false; warmUp()
    }

    public func startMicrophoneTest(operation: UUID, lease: CaptureAdmission.Lease) throws {
        guard meetingID == nil, admission.owns(lease), lease.owner == .microphoneTest, unsavedPurpose == nil, guidedScope == nil,
              captureLease == nil else { throw RecorderError.captureBusy }
        warmthSuspended = true
        teardown() // also closes an already-warm normal engine and drops its pre-roll
        resamplerLock.withLock { resampler.discard() }
        lock.withLock {
            diagnosticID = operation; diagnosticRequestedUID = inputDeviceUID; localRoute = MicrophoneRoute()
            samples = []; samples.reserveCapacity(Self.microphoneTestMaxSamples)
            sampleCeiling = Self.microphoneTestMaxSamples
            latestLevel = 0; hasSignal = false; failedBuffers = 0; ended = nil
            captureDiagnostics = CaptureDiagnosticState(operationID: operation, started: Self.nowSeconds())
            capturing = true
        }
        do { try build(device: testEngine == nil ? inputDeviceUID.flatMap(Self.deviceID(forUID:)) : nil) }
        catch { clearMicrophoneTest(operation: operation); throw error }
    }

    public func microphoneTestSnapshot(operation: UUID) -> MicrophoneCaptureSnapshot? {
        // Route queries belong on the control thread, never in the tap.
        if diagnosticID == operation, engineRunning { updateDiagnosticRoute() }
        return lock.withLock {
            guard diagnosticID == operation else { return nil }
            return MicrophoneCaptureSnapshot(facts: captureDiagnostics, route: localRoute,
                sampleCount: samples.count, level: latestLevel, hasSignal: hasSignal,
                conversionFailures: failedBuffers, ended: ended)
        }
    }

    public func stopMicrophoneTest(operation: UUID) -> [Float] {
        guard diagnosticID == operation, lock.withLock({ capturing }) else { return [] }
        teardown() // stop first; invalidate taps and pending route work before flushing
        let tail = resamplerLock.withLock { () -> [Float] in
            defer { resampler.discard() }
            return resampler.flush()
        }
        return lock.withLock {
            capturing = false
            samples.append(contentsOf: tail.prefix(max(0, sampleCeiling - samples.count)))
            let result = samples
            samples = [] // transfer sole logical ownership to controller, no recorder alias
            preRoll.discard()
            captureDiagnostics?.stop(sampleCount: result.count, rms: Self.rms(result), deviceLost: ended == .deviceLost)
            latestLevel = 0
            return result
        }
    }

    public func clearMicrophoneTest(operation: UUID) {
        guard diagnosticID == operation else { return }
        _ = stopMicrophoneTest(operation: operation)
        resamplerLock.withLock { resampler.discard() }
        lock.withLock {
            samples = []; preRoll.discard(); captureDiagnostics = nil
            diagnosticID = nil; diagnosticRequestedUID = nil; localRoute = MicrophoneRoute(); latestLevel = 0; hasSignal = false
        }
    }

    /// Scalar storage inspection for disposal fixtures; no sample data leaves this view.
    public var retainedAudioCounts: (samples: Int, preRoll: Int, converter: Bool) {
        resamplerLock.withLock { lock.withLock { (samples.count, preRoll.count, resampler.hasStorage) } }
    }

    /// Dictation-only owned disposal. No warm-up; stale owners cannot stop a new capture.
    /// Teardown invalidates tap/rebuild epochs before drain. Both locks always nest
    /// resampler → samples. Scalar canceled diagnostics survive the move.
    public func stopCanceledCapture(operationID: UUID, retain: Bool) -> [Float]? {
        guard meetingID == nil, !transferring, unsavedPurpose == nil, guidedScope == nil, captureOperationID == operationID,
              let lease = captureLease, lease.owner == .dictation, admission.owns(lease) else { return nil }
        transferring = true
        defer { transferring = false }
        warmthSuspended = true
        teardown()
        let result = resamplerLock.withLock { () -> [Float]? in
            defer { resampler.discard() }
            let tail = resampler.flush()
            return lock.withLock {
                capturing = false
                samples.append(contentsOf: tail)
                let elapsed = captureClock() - captureStartedAt
                let accepted = retain && ended == nil && resumes == 0 && !canceledCaptureDisrupted
                    && CanceledCaptureLimits.accepts(samples, elapsed: elapsed, postStartPCM: postStartPCM)
                captureDiagnostics?.stop(sampleCount: samples.count, rms: Self.rms(samples), deviceLost: ended == .deviceLost)
                let moved = accepted ? samples : nil
                samples = []; preRoll.discard(); postStartPCM = false; captureOperationID = nil; captureFormat = nil
                latestLevel = 0; hasSignal = false
                return moved
            }
        }
        if captureLease == lease { captureLease = nil; admission.release(lease) }
        return result
    }

    public func stop() -> [Float] {
        guard meetingID == nil, unsavedPurpose == nil, guidedScope == nil else { return [] } // only diagnostic owner may close it
        defer { if let captureLease { admission.release(captureLease) }; captureLease = nil }
        lock.lock()
        capturing = false
        lock.unlock()
        // Take the tail the resampler has been holding back across every
        // .noDataNow feed, then ready it for the pre-roll that follows.
        resamplerLock.lock()
        let tail = resampler.flush()
        resampler.reset()
        resamplerLock.unlock()
        lock.lock()
        samples.append(contentsOf: tail)
        let captured = samples
        captureFormat = nil
        let failures = failedBuffers
        let diagnosticEnd = ended
        // Whatever the tap wrote while stop() ran is this dictation's own tail,
        // already transcribed — never prepend it to the next one.
        preRoll.reset()
        lock.unlock()
        let rms = AudioRecorder.rms(captured)
        lock.withLock { captureDiagnostics?.stop(sampleCount: captured.count, rms: rms, deviceLost: diagnosticEnd == .deviceLost) }
        // The production reader of the failure count, which is the whole reason
        // it is kept: "Parla heard nothing" otherwise logs identically whether the
        // mic was silent or every tap buffer failed to convert.
        if failures > 0 {
            NSLog("Parla recorder: %d tap buffers failed to convert (%d samples captured)",
                  failures, captured.count)
        }
        // A cold-path start may have bound a headset (the gate only allows
        // *holding* a non-Bluetooth device) or a mic that was not yet granted.
        if AudioRecorder.shouldTeardown(warm: warm, builtAuthorized: builtAuthorized,
                                        bluetooth: testEngine == nil && AudioRecorder.isBluetooth(boundDevice),
                                        capturedNothing: captured.isEmpty) {
            teardown()
        }
        warmUp() // no-op while the engine is still running; rebuilds after a teardown
        return captured
    }
}

/// The 1.0 s of already-resampled 16 kHz mono the warm engine's tap keeps behind
/// it, so `start()` can prepend the speech that landed before the key went down.
/// Capacity and prepend length are Hex's numbers, adopted unchanged by both
/// macparakeet and FluidVoice (docs/research/03-latency.md §2).
struct PreRollRing {
    static let capacity = 16_000        // 1.0 s at the target rate
    static let prependSamples = 7_200   // 0.45 s
    /// A ring this stale means the tap stopped feeding (device suspended, engine
    /// wedged); prepending it would splice in audio from a different moment.
    static let maxAge: TimeInterval = 2

    private var samples: [Float] = []
    private var lastWrite: TimeInterval?

    /// Explicit: private storage would otherwise make the synthesized one
    /// file-private, and the tests build the ring directly.
    init() {}

    mutating func write(_ chunk: [Float], now: TimeInterval) {
        samples.append(contentsOf: chunk)
        // ponytail: ≤64 KB memmove per tap buffer (~every 85 ms) to keep this a
        // plain array; a head-index ring if it ever shows up in a profile.
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        lastWrite = now
    }

    /// The newest ≤0.45 s, and always empties the ring so nothing is prepended
    /// twice. Nothing when the ring is stale, or when media was playing at press
    /// time — that pre-roll is the user's speakers, not the user, and no pause
    /// after the fact can un-record it.
    mutating func take(now: TimeInterval, mediaPlaying: Bool) -> [Float] {
        defer { reset() }
        guard !mediaPlaying, let lastWrite, now - lastWrite <= Self.maxAge else { return [] }
        return Array(samples.suffix(Self.prependSamples))
    }

    /// The tap stopped feeding — `take`'s own test, without consuming the ring.
    /// A ring not yet written (just built, just reset) is not stale: its first
    /// buffer is ~85 ms away.
    func isStale(now: TimeInterval) -> Bool {
        guard let lastWrite else { return false }
        return now - lastWrite > Self.maxAge
    }

    var count: Int { samples.count }
    mutating func discard() { samples = []; lastWrite = nil }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastWrite = nil
    }
}

/// One `AVAudioConverter` reused across buffers, rebuilt only when the input
/// format changes. Building one per buffer restarts the resampler's filter at
/// every buffer edge — at 48k→16k that is a discontinuity every ~85 ms for the
/// whole recording — and allocates on the audio thread. The cost of reuse is a
/// tail the converter holds back until `flush()`.
///
/// Not thread-safe; the owner is responsible for handing it between threads.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var out: AVAudioPCMBuffer?

    /// nil when the buffer could not be converted at all, which the caller
    /// counts — an empty array here would read as silence.
    func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> [Float]? {
        if buffer.format == target {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                             count: Int(buffer.frameLength)))
        }
        if inputFormat != buffer.format {
            // Device or sample-rate change: the held filter state belongs to the
            // old stream, so start over rather than carry it into the new one.
            converter = AVAudioConverter(from: buffer.format, to: target)
            inputFormat = buffer.format
            out = nil
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        // ponytail: one output buffer, grown on demand, instead of VoiceInk's
        // free-list — the tap is serial and convert() copies out before returning.
        if (out?.frameCapacity ?? 0) < capacity {
            out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        }
        guard let out else { return nil }
        var fed = false
        let outcome = converter.convert(to: out, error: nil) { _, status in
            // noDataNow (not endOfStream) leaves the converter open, so the next
            // buffer continues the same filter run instead of starting a new one.
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard outcome != .error else { return nil }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0],
                                         count: Int(out.frameLength)))
    }

    /// Frames still inside the resampler. Call once, after the last buffer.
    func flush() -> [Float] { (try? flushResult().get()) ?? [] }
    func flushResult() -> Result<[Float], GuidedTemplateFailure> {
        guard let converter, let out else { return .success([]) }
        let outcome = converter.convert(to: out, error: nil) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        guard outcome != .error else { return .failure(GuidedTemplateFailure("Converter drain failed.")) }
        return .success(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
    }

    /// Ready the converter for a new stream after a flush, without discarding it.
    func reset() { converter?.reset() }
    var hasStorage: Bool { converter != nil || out != nil }
    func discard() { converter = nil; inputFormat = nil; out = nil }
}

/// Meeting-specific bounded converter. Never changes legacy Resampler semantics.
/// Source shape/representation/finiteness was checked before constructing this object.
/// No supplied tap buffer survives feed. Only fixed owned input/output buffers persist.
private final class NativeMeetingConverter: MeetingPCMConverting {
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let input: AVAudioPCMBuffer?, output: AVAudioPCMBuffer?
    init?(format: AVAudioFormat) {
        self.format = format
        if format == AudioRecorder.targetFormat {
            converter = nil; input = nil; output = nil; return
        }
        guard let converter = AVAudioConverter(from:format,to:AudioRecorder.targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8_192),
              let output = AVAudioPCMBuffer(pcmFormat:AudioRecorder.targetFormat,frameCapacity:32_768) else { return nil }
        self.converter = converter; self.input = input; self.output = output
    }
    func feed(_ source: AVAudioPCMBuffer, output destination: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        let count = Int(source.frameLength)
        guard count <= 8_192,source.format == format,let channels = source.floatChannelData else { return .init(frames:0,status:.failed) }
        if converter == nil {
            guard count <= destination.count,let destination = destination.baseAddress else { return .init(frames:0,status:.failed) }
            destination.update(from:channels[0],count:count)
            return .init(frames:count,status:.inputExhausted) // exact canonical passthrough has no hidden EOS state
        }
        guard let converter,let input,let output,let owned = input.floatChannelData else { return .init(frames:0,status:.failed) }
        for channel in 0..<Int(format.channelCount) { owned[channel].update(from:channels[channel],count:count) }
        input.frameLength = source.frameLength; output.frameLength = 0
        var fed = false, refusedRequest = false
        let result = converter.convert(to:output,error:nil) { requested,status in
            if fed { status.pointee = .noDataNow; return nil }
            // Do not guess at partially consumed source ownership or reuse a tap buffer.
            // Unqualified request shapes close conservatively; no padding/slicing fiction.
            guard Int(requested) >= count else { refusedRequest = true; status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        let n = copyOutput(output,to:destination)
        guard n >= 0,result != .error else { return .init(frames:max(0,n),status:.failed) }
        let status: MeetingConversionStep.Status = fed && !refusedRequest && result == .inputRanDry ? .inputExhausted : .haveData
        return .init(frames:n,status:status)
    }
    func finish(output destination: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        guard let converter,let output else { return .init(frames:0,status:.endOfStream) }
        output.frameLength = 0
        let result = converter.convert(to:output,error:nil) { _,status in status.pointee = .endOfStream; return nil }
        let n = copyOutput(output,to:destination)
        guard n >= 0 else { return .init(frames:0,status:.failed) }
        switch result {
        case .endOfStream: return .init(frames:n,status:.endOfStream)
        case .error: return .init(frames:n,status:.failed)
        case .inputRanDry: return .init(frames:n,status:.inputExhausted)
        case .haveData: return .init(frames:n,status:.haveData)
        @unknown default: return .init(frames:n,status:.failed)
        }
    }
    private func copyOutput(_ output: AVAudioPCMBuffer, to destination: UnsafeMutableBufferPointer<Float>) -> Int {
        let count = Int(output.frameLength)
        guard count <= 32_768,count <= destination.count else { return -1 }
        if count > 0 {
            guard let from = output.floatChannelData?[0],let to = destination.baseAddress else { return -1 }
            to.update(from:from,count:count)
        }
        return count
    }
}
