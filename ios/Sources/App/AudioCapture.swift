import AVFoundation
import CallKit
import Foundation
import UIKit
import ParlaCore

// The tap converts each buffer to 16 kHz mono Float32 through one streaming Resampler. UI/lifecycle work stays on MainActor.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private let resampler = Resampler()
    private var samples: [Float] = []
    private var full = false
    private var failed = false
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !full, !failed else { return }
        guard let converted = resampler.convert(buffer) else { failed = true; return }
        take(converted)
    }
    private func take(_ converted: [Float]) {
        let room = DictationEngine.maximumSamples - samples.count
        samples.append(contentsOf: converted.prefix(room))
        if converted.count >= room { full = true }
    }
    /// Drains the converter once; later tap callbacks are ignored.
    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if !full, !failed { take(resampler.flush()) }
        full = true
        return samples
    }
    var state: (full: Bool, failed: Bool) { lock.lock(); defer { lock.unlock() }; return (full, failed) }
}
@MainActor final class AudioCapture {
    private var engine: AVAudioEngine?
    private var sink: SampleSink?
    private var observers: [NSObjectProtocol] = []
    private var cue: AVAudioPlayer?
    private var cueCleanup: Task<Void, Never>?
    private var generation: UUID?
    var onInvalidated: (() -> Void)?  // interruption, route change or media reset; captured audio is still in stop()
    var limitReached: Bool { sink?.state.full ?? false }
    var conversionFailed: Bool { sink?.state.failed ?? false }
    var inputName: String { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone Microphone" }
    static let duringCall = ParlaError.message("Can't record during a call. End the call and try again.")
    /// The session below is non-mixable: during a phone or CallKit call its activation
    /// fails with insufficientPriority ('!pri'), so name the call instead of a generic failure.
    static func startFailure(_ error: Error, callActive: Bool) -> ParlaError {
        if callActive || (error as NSError).code == AVAudioSession.ErrorCode.insufficientPriority.rawValue { return duringCall }
        return error as? ParlaError ?? .message("Could not start the microphone. Check permissions and other audio apps.")
    }
    private static var callActive: Bool { CXCallObserver().calls.contains { !$0.hasEnded } }
    func start(microphoneID: String?, feedback: Bool) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ParlaError.message("Microphone access is denied. Enable it in iPhone Settings → Parla.") }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw ParlaError.unavailable }
        // Refuse before activation: a non-mixable session must not grab audio from a call.
        guard !Self.callActive else { throw Self.duringCall }
        let session = AVAudioSession.sharedInstance()
        do {
            cueCleanup?.cancel(); cueCleanup = nil; cue?.stop()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            if let microphoneID, let input = session.availableInputs?.first(where: { $0.uid == microphoneID }) { try session.setPreferredInput(input) }
            if feedback {
                let duration = playCue("dictation-start")
                try await Task.sleep(for: .seconds(duration))
            }
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active else { throw ParlaError.unavailable }
            let engine = AVAudioEngine()
            let node = engine.inputNode; let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ParlaError.message("Microphone is unavailable or in use.") }
            let sink = SampleSink()
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
            self.engine = engine; self.sink = sink
            try engine.start()
            let token = UUID(); generation = token
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.onInvalidated?()
                    }
                })
            }
        } catch is CancellationError { stop(feedback: false); throw CancellationError() }
        catch { stop(feedback: false); throw Self.startFailure(error, callActive: Self.callActive) }
    }
    /// Returns everything captured so far (empty after a failed start).
    @discardableResult func stop(feedback: Bool) -> [Float] {
        generation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        let samples = sink?.finish() ?? []; sink = nil
        cueCleanup?.cancel(); cueCleanup = nil; cue?.stop()
        if feedback {
            let duration = playCue("dictation-stop")
            cueCleanup = Task {
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                cue?.stop(); cue = nil; cueCleanup = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } else {
            cue = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return samples
    }
    @discardableResult private func playCue(_ name: String) -> TimeInterval {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return 0 }
        cue = try? AVAudioPlayer(contentsOf: url); cue?.play()
        return min((cue?.duration ?? 0) + 0.05, 2)
    }
}
