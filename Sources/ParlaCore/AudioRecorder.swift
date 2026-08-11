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
    }

    /// Hard ceiling on one capture: 10 minutes at 16 kHz (~38 MB of Float).
    /// Also the ceiling on a forgotten hands-free latch, which is otherwise
    /// indefinite sustained Metal load — the app's only thermal risk.
    public static let maxSamples = 10 * 60 * 16_000

    /// Core Audio fires a burst of route changes for one physical event, and
    /// each rebuild provokes the next one. Only the last scheduled rebuild runs.
    static let rebuildDebounce: TimeInterval = 0.5

    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    private var failedBuffers = 0
    private var ended: EndReason?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()

    /// Tap-side state, under `lock`: `capturing` decides whether a converted
    /// chunk joins the dictation or the pre-roll ring.
    private var capturing = false
    private var preRoll = PreRollRing()

    /// Engine-side state. Only ever touched on the main thread: prepare/start/
    /// stop are called from the hotkey handler and the notification observer is
    /// registered on the main queue.
    private var warm = false
    private var boundDevice: AudioDeviceID?
    private var rebuildGeneration = 0

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

    public init() {}

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
        onEnd?(reason)
    }

    /// Tap-side accumulate. nil chunk = the converter dropped that buffer.
    /// Once the capture has ended, further buffers are discarded — the cap is a
    /// ceiling on memory, so it must hold until the owner's stop() lands.
    func append(_ chunk: [Float]?) {
        lock.lock()
        guard ended == nil else { lock.unlock(); return }
        if let chunk { samples.append(contentsOf: chunk) } else { failedBuffers += 1 }
        let hitCap = samples.count >= AudioRecorder.maxSamples
        lock.unlock()
        if hitCap { endCapture(.sampleLimit) }
    }

    // MARK: - Warm engine

    /// Build the engine, bind the device, install the tap and start capturing
    /// into the pre-roll ring — everything `start()` used to do inside the
    /// fn-down handler (240–270 ms on built-in mics, 650–700 ms on USB;
    /// docs/research/03-latency.md §1). Call at launch and on device change.
    ///
    /// Also latches warmth on: without it the recorder behaves exactly as it did
    /// before, cold-opening per press and tearing down at stop. Warm means the
    /// mic indicator stays lit while Parla is idle, so it is the app's call.
    public func prepare() {
        warm = true
        warmUp()
    }

    /// Idempotent build of the warm engine, subject to the Bluetooth gate.
    private func warmUp() {
        guard warm, !engine.isRunning else { return }
        let device = inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:))
        guard !AudioRecorder.isBluetooth(device) else { return }
        // A warm engine is a nicety; failing to get one just means the next
        // start() pays the cold open it always used to.
        try? build(device: device)
    }

    private func build(device: AudioDeviceID?) throws {
        engine = AVAudioEngine() // fresh: a reused engine caches the old device's format
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.resamplerLock.lock()
            let chunk = self.resampler.convert(buf, to: AudioRecorder.targetFormat)
            self.resamplerLock.unlock()
            guard self.route(chunk) else { return }
            // Stamped only for live chunks: a warm tap is already running when
            // fn goes down, so stamping pre-roll would report ~0 ms every time.
            Trace.mark(.firstPCM) // disabled: one bool test, no alloc, no lock
            self.onLevel?(chunk.map(AudioRecorder.rms) ?? 0)
        }
        do {
            try engine.start()
        } catch {
            // A failed build must leave the recorder restartable.
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        boundDevice = device
        observeConfigChanges()
    }

    /// Tap-side fan-out. Returns true when the chunk joined the dictation, false
    /// when it went to the pre-roll ring (warm engine, no capture in flight).
    private func route(_ chunk: [Float]?) -> Bool {
        lock.lock()
        let live = capturing
        if !live, let chunk { preRoll.write(chunk, now: AudioRecorder.nowSeconds()) }
        lock.unlock()
        guard live else { return false }
        append(chunk)
        return true
    }

    private func observeConfigChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let live = self.capturing
            self.lock.unlock()
            guard live else {
                // Idle: the route moved under a warm engine (device swapped,
                // AirPods connected, rate changed). Rebuild once the burst ends.
                self.scheduleRebuild()
                return
            }
            // Mid-dictation a mic that goes away (unplugged, seized by another
            // app) leaves the tap silent forever. End the capture with a reason
            // so stop() still finalizes what was already spoken.
            // ponytail: only a lost input format ends it — a benign
            // reconfiguration (default device swapped, rate changed) keeps a
            // valid format. Follow-up: that swap leaves the tap on the old
            // device, which needs a restart, not an end.
            let format = self.engine.inputNode.inputFormat(forBus: 0)
            guard format.sampleRate == 0 || format.channelCount == 0 else { return }
            self.endCapture(.deviceLost)
        }
    }

    /// Trailing debounce behind a generation counter: a rebuild itself provokes
    /// the next configuration change, so an undebounced handler is a loop that
    /// never settles (docs/research/03-latency.md §7, trap 2).
    private func scheduleRebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecorder.rebuildDebounce) { [weak self] in
            guard let self, self.rebuildGeneration == generation else { return }
            self.lock.lock()
            let live = self.capturing
            self.lock.unlock()
            guard !live else { return } // a dictation started during the debounce
            self.teardown()
            self.warmUp() // re-reads the transport: AirPods leave the engine cold
        }
    }

    /// Stop the engine and hand the device back. Stopping is not enough on its
    /// own: the AUHAL unit stays bound, which keeps a headset in the 16 kHz HFP
    /// profile, so the unit is explicitly pointed at kAudioObjectUnknown.
    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        if let unit = input.audioUnit {
            var unknown = AudioDeviceID(kAudioObjectUnknown)
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &unknown,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        boundDevice = nil
        lock.lock(); preRoll.reset(); lock.unlock()
    }

    // MARK: - Capture

    public func start() throws {
        let device = inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:))
        // Behind the trace gate so a normal start pays no extra HAL queries.
        if Trace.enabled { Trace.setTransport(AudioRecorder.transport(of: device)) }
        // A warm engine bound to some other mic is worse than no warm engine.
        if engine.isRunning && boundDevice != device { teardown() }

        // The ring is claimed before `capturing` flips so the splice has no gap
        // and no overlap: every chunk lands on exactly one side of it.
        let mediaPlaying = engine.isRunning ? AudioRecorder.mediaPlaying() : false
        lock.lock()
        let preRolled = preRoll.take(now: AudioRecorder.nowSeconds(), mediaPlaying: mediaPlaying)
        samples = preRolled
        failedBuffers = 0
        ended = nil
        capturing = true
        lock.unlock()

        if !engine.isRunning {
            // Cold path — what every press used to pay. Also the Bluetooth path:
            // the gate refuses to *hold* a headset open, not to record from one.
            do { try build(device: device) } catch {
                lock.lock(); capturing = false; lock.unlock()
                throw error
            }
        }
        Trace.mark(.recorderStartReturned)
    }

    /// Copy of the samples captured so far, under the lock. Safe to call
    /// mid-recording (the streaming loop polls this).
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func stop() -> [Float] {
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
        // Whatever the tap wrote while stop() ran is this dictation's own tail,
        // already transcribed — never prepend it to the next one.
        preRoll.reset()
        lock.unlock()
        // A cold-path start may have bound a headset; the gate only allows
        // *holding* a non-Bluetooth device.
        if !warm || AudioRecorder.isBluetooth(boundDevice) { teardown() }
        warmUp() // no-op while the engine is still running
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
    func flush() -> [Float] {
        guard let converter, let out else { return [] }
        let outcome = converter.convert(to: out, error: nil) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        guard outcome != .error else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0],
                                         count: Int(out.frameLength)))
    }

    /// Ready the converter for a new stream after a flush, without discarding it.
    func reset() { converter?.reset() }
}
