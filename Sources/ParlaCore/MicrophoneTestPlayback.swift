import AVFoundation

public protocol MicrophoneTestPlaying: AnyObject {
    func play(samples: [Float], sampleRate: Double, finished: @escaping (Bool) -> Void) throws
    func stop()
}

/// Constructed only by Listen. Float PCM is scheduled in memory, never encoded to a file.
public final class MicrophoneTestPlayer: MicrophoneTestPlaying {
    public init() {}
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    public func play(samples: [Float], sampleRate: Double, finished: @escaping (Bool) -> Void) throws {
        stop()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioRecorder.RecorderError.noInputFormat
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: source.count) }
        }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        self.engine = engine; self.node = node
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { finished(true) }
        }
        do { try engine.start(); node.play() } catch { stop(); throw error }
    }
    public func stop() { node?.stop(); engine?.stop(); node = nil; engine = nil }
    deinit { stop() }
}
