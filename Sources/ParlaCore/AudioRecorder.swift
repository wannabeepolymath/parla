import AVFoundation
import AudioToolbox
import CoreAudio

public struct AudioRecorderError: Error, CustomStringConvertible {
    public let description: String
}

public final class AudioRecorder {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    /// True between a successful start() and stop(). Read on main.
    private var capturing = false
    /// Whether a tap is currently installed on input bus 0. Tracked separately
    /// from `capturing` because a configuration change clears `capturing` while
    /// leaving the tap in place — stop() still has to remove it.
    private var tapInstalled = false

    /// Called with each converted buffer's RMS level. Fires on the audio
    /// thread — callers must hop to main before touching UI.
    public var onLevel: ((Float) -> Void)?

    /// Fired on the main queue when the capture graph broke mid-recording — the
    /// input device was unplugged (AirPods disconnecting), or its format changed.
    /// Without this the engine stops itself, buffers simply stop arriving, and
    /// the UI goes on claiming it is listening while the user keeps talking into
    /// nothing. Audio captured before the break is still in the buffer.
    public var onCaptureInterrupted: (() -> Void)?

    /// Core Audio UID of the mic to record from. nil (or an unresolvable UID)
    /// ⇒ system default input. Applied at each start() while the engine is idle.
    public var inputDeviceUID: String?

    public init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Only a change that actually took the engine down is a lost
            // dictation; a benign reconfiguration that keeps it running is not.
            guard let self, self.capturing, !self.engine.isRunning else { return }
            NSLog("Parla: audio engine stopped by a configuration change (input device lost?)")
            self.capturing = false
            self.onCaptureInterrupted?()
        }
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

    /// The current system default input. Needed to explicitly UNPIN the AUHAL:
    /// once it has been pointed at a specific device it stops tracking the
    /// default, so merely skipping the set (the old behaviour when
    /// inputDeviceUID was nil) silently kept recording from the previously
    /// chosen mic after the user picked "System Default" again.
    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }
        return device
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

    /// Root-mean-square amplitude of samples; 0 for empty input.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// Convert any PCM buffer to 16kHz mono Float32 samples.
    public static func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format == targetFormat {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                             count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        else { return [] }
        let ratio = 16_000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            // endOfStream (not noDataNow) so the converter drains the resampler's
            // tail latency; each buffer is a complete unit (fresh converter per call).
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0],
                                         count: Int(out.frameLength)))
    }

    public func start() throws {
        // Under the lock: the audio thread's tap block appends here, and
        // removeTap/engine.stop() do not prove an already-dispatched block has
        // finished. An unsynchronized Array mutation racing a locked append is
        // undefined behaviour, not just stale audio.
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        // Point the AUHAL input unit at the chosen device before reading its
        // format. Engine is idle here (start is only called after stop).
        // ALWAYS set it — resolving nil/unknown UIDs to the current system
        // default — because an AUHAL pinned on an earlier start() keeps that
        // device until told otherwise.
        if let unit = input.audioUnit,
           var dev = inputDeviceUID.flatMap({ AudioRecorder.deviceID(forUID: $0) })
               ?? AudioRecorder.defaultInputDevice() {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = input.outputFormat(forBus: 0)
        // No usable input device (a desktop Mac with nothing plugged in) reports
        // a 0 Hz format, and installTap raises an Objective-C exception on it —
        // uncatchable from Swift, so the process dies instead of showing the
        // caller's "Mic failed" toast. Refuse as a Swift error first.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError(description:
                "no usable audio input device (format \(format.sampleRate)Hz × \(format.channelCount)ch)")
        }

        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false } // defensive: never double-tap a bus
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let chunk = AudioRecorder.convert(buf)
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
            self.onLevel?(AudioRecorder.rms(chunk))
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            // A failed start must leave the recorder restartable.
            input.removeTap(onBus: 0)
            tapInstalled = false
            engine.stop()
            throw error
        }
        capturing = true
    }

    /// Copy of the samples captured so far, under the lock. Safe to call
    /// mid-recording (the streaming loop polls this).
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stop capture and hand back everything recorded. Safe to call when start()
    /// never succeeded or when a configuration change already downed the engine —
    /// the tap is removed exactly once either way, so the next start() can never
    /// hit AVAudioEngine's "may not have more than one tap" exception.
    public func stop() -> [Float] {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        capturing = false
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
