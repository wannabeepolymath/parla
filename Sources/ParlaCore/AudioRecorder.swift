import AVFoundation
import AudioToolbox
import CoreAudio

public final class AudioRecorder {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    /// Why a capture ended by itself, rather than by the user releasing fn.
    public enum EndReason: Equatable { case sampleLimit, deviceLost }

    /// Hard ceiling on one capture: 10 minutes at 16 kHz (~38 MB of Float).
    /// Also the ceiling on a forgotten hands-free latch, which is otherwise
    /// indefinite sustained Metal load — the app's only thermal risk.
    public static let maxSamples = 10 * 60 * 16_000

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var failedBuffers = 0
    private var ended: EndReason?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()

    /// Owned by the audio thread while the engine runs, by the caller either
    /// side of that — never touched by both, so it needs no lock.
    private let resampler = Resampler()

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

    /// Transport label of the device a start() would open: the selected one, or
    /// the system default when no UID is set. Trace-only (see Trace.transportName).
    private static func transport(of device: AudioDeviceID?) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard let id = device ?? defaultInputDevice() else { return "unknown" }
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw) == noErr else { return "unknown" }
        return Trace.transportName(raw)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown else { return nil }
        return id
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

    public func start() throws {
        samples.removeAll()
        failedBuffers = 0
        ended = nil
        // Previous recording ended with an endOfStream flush; reset so the next
        // one starts on a clean filter without rebuilding on the audio thread.
        resampler.reset()
        let input = engine.inputNode
        // Point the AUHAL input unit at the chosen device before reading its
        // format. Engine is idle here (start is only called after stop). An
        // unresolvable UID leaves the unit on the system default. ponytail: set
        // per-start so unplugging the selected mic self-heals to default.
        let device = inputDeviceUID.flatMap(AudioRecorder.deviceID(forUID:))
        if let device, let unit = input.audioUnit {
            var dev = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // Behind the trace gate so a normal start pays no extra HAL queries.
        if Trace.enabled { Trace.setTransport(AudioRecorder.transport(of: device)) }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            Trace.mark(.firstPCM) // disabled: one bool test, no alloc, no lock
            let chunk = self.resampler.convert(buf, to: AudioRecorder.targetFormat)
            self.append(chunk)
            self.onLevel?(chunk.map(AudioRecorder.rms) ?? 0)
        }
        do {
            try engine.start()
            Trace.mark(.recorderStartReturned)
            // A mic that goes away mid-dictation (unplugged, seized by another
            // app) leaves the tap silent forever. End the capture with a reason
            // so stop() still finalizes what was already spoken.
            // ponytail: only a lost input format ends it — a benign
            // reconfiguration (default device swapped, rate changed) keeps a
            // valid format. Follow-up: that swap leaves the tap on the old
            // device, which needs a restart, not an end.
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let format = self.engine.inputNode.inputFormat(forBus: 0)
                guard format.sampleRate == 0 || format.channelCount == 0 else { return }
                self.endCapture(.deviceLost)
            }
        } catch {
            // A failed start must leave the recorder restartable.
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    /// Copy of the samples captured so far, under the lock. Safe to call
    /// mid-recording (the streaming loop polls this).
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // The tap is gone, so the resampler is ours again: take the tail it has
        // been holding back across every .noDataNow feed.
        let tail = resampler.flush()
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: tail)
        return samples
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
