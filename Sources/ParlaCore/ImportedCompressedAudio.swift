import AVFoundation
import Foundation

/// M4A / MP3 import through AVFoundation (no FFmpeg). AVFoundation decodes, downmixes and resamples
/// to 16 kHz mono float. Encoder delay and priming are not mapped, so these sources never get timing.
public enum ImportedCompressedAudio {
    public enum Failure: Error, Equatable {
        case format, native, output, duration
        public var message: String {
            switch self {
            case .format: return "This file has no audio track Parla can read."
            case .native, .output: return "This file couldn’t be decoded. Try exporting it as M4A or WAV."
            case .duration: return "Use a file under 10 minutes and 20 MB."
            }
        }
    }
    public struct Facts: Equatable, Sendable {
        public let container: String
        /// FourCC as reported by the file's format description.
        public let codec: String
        public let sourceRate: Int
        public let sourceChannels: Int
        /// Frame count as the container reports it; not verified against the decode.
        public let reportedSourceFrames: Int
        public let outputFrames: Int
        public let outputRate = 16_000
        public let clipped: Int
    }
    public struct Decoded: Sendable {
        public let samples: [Float]
        public let facts: Facts
    }

    public static func decode(_ bytes: Data, format: ImportedAudio.SourceFormat, canceled: () -> Bool = { false }) throws -> Decoded {
        try decode(bytes, format: format, canceled: canceled, maximumSamples: ImportedWAV.maximumSamples,
                   directory: FileManager.default.temporaryDirectory)
    }

    static func decode(_ bytes: Data, format: ImportedAudio.SourceFormat, canceled: () -> Bool,
                       maximumSamples: Int, directory: URL) throws -> Decoded {
        let ext: String
        switch format {
        case .m4a: ext = "m4a"
        case .mp3: ext = "mp3"
        case .wav, .mov: throw Failure.format
        }
        if canceled() { throw CancellationError() }
        guard !bytes.isEmpty, bytes.count <= ImportedWAV.maximumBytes else { throw Failure.duration }
        // AVFoundation needs a URL: a private copy of the validated bytes, never the original file.
        let url = directory.appendingPathComponent("parla-import-\(UUID().uuidString).\(ext)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.native }
        defer { unlink(url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes); try handle.close() } catch { throw Failure.native }
        if canceled() { throw CancellationError() }

        // Only a readable container with no audio track is a format failure; a corrupt, truncated
        // or protected file that cannot be opened is a decode failure.
        let asset = AVURLAsset(url: url)
        guard let track = try audioTrack(asset) else { throw Failure.format }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.native }
        let source = file.fileFormat.streamDescription.pointee
        let reported = Int(max(0, file.length))
        guard source.mSampleRate.isFinite, source.mSampleRate > 0, source.mChannelsPerFrame > 0 else { throw Failure.native }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.native }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.native }
        reader.add(output)
        guard reader.startReading() else { throw Failure.native }

        var samples: [Float] = [], clipped = 0
        while true {
            if canceled() { reader.cancelReading(); throw CancellationError() }
            let more: Bool = try autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return true }
                let length = CMBlockBufferGetDataLength(block)
                guard length % 4 == 0 else { reader.cancelReading(); throw Failure.output }
                let count = length / 4
                guard samples.count + count <= maximumSamples else { reader.cancelReading(); throw Failure.duration }
                var chunk = [Float](repeating: 0, count: count)
                let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { reader.cancelReading(); throw Failure.native }
                for value in chunk {
                    guard value.isFinite else { reader.cancelReading(); throw Failure.output }
                    if value < -1 || value > 1 { clipped += 1 }
                    samples.append(min(1, max(-1, value)))
                }
                return true
            }
            if !more { break }
        }
        if canceled() { throw CancellationError() }
        guard reader.status == .completed else { throw Failure.native }
        guard !samples.isEmpty else { throw Failure.output }
        let facts = Facts(container: ext.uppercased(), codec: fourCC(source.mFormatID), sourceRate: Int(source.mSampleRate),
                          sourceChannels: Int(source.mChannelsPerFrame), reportedSourceFrames: reported,
                          outputFrames: samples.count, clipped: clipped)
        return Decoded(samples: samples, facts: facts)
    }

    /// The synchronous track getters are deprecated on macOS 13; bridge the completion-handler load.
    private static func audioTrack(_ asset: AVURLAsset) throws -> AVAssetTrack? {
        final class Box: @unchecked Sendable { var tracks: [AVAssetTrack]?; var failed = false }
        let box = Box(), done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .audio) { tracks, error in
            box.tracks = tracks; box.failed = error != nil; done.signal()
        }
        done.wait()
        guard !box.failed else { throw Failure.native }
        return box.tracks?.first
    }

    private static func fourCC(_ id: AudioFormatID) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((id >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(format: "0x%08X", id) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
