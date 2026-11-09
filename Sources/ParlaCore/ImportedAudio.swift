import AVFoundation
import Foundation

/// A complete, bounded PCM snapshot. Native code receives PCM buffers, never a container or path.
public enum ImportedAudio {
    public struct SourceInfo: Equatable, Sendable {
        public enum Origin: Equatable, Sendable { case strictPCM16k, systemPCMConversion }
        public let container = "RIFF WAV"
        public let encoding = "PCM16LE"
        public let sourceRate: Int
        public let sourceChannels = 1
        public let sourceFrames: Int
        public let outputFrames: Int
        public let outputRate = 16_000
        public let origin: Origin
        public let clippedSamples: Int
    }
    public struct Decoded: Sendable {
        public let samples: [Float]
        public let transientSourceInfo: SourceInfo
    }
    /// Closed, extension-selected source routing. No sniffing or native MOV fallback.
    public enum SourceFormat: Equatable, Sendable { case wav, mov }
    public enum SourceProfile: String, Codable, Sendable { case wavPCM, qtPCM16kV1 }
    public enum SourceFacts: Equatable, Sendable {
        case wav(SourceInfo)
        case mov(ImportedPCMMOV.Facts)
        public enum Origin: Equatable, Sendable { case strictPCM16k, systemPCMConversion, directMOVPCM16k }
        public var profile: SourceProfile {
            switch self { case .wav: return .wavPCM; case .mov: return .qtPCM16kV1 }
        }
        public var container: String {
            switch self { case .wav(let info): return info.container; case .mov(let facts): return facts.container }
        }
        public var encoding: String {
            switch self { case .wav(let info): return info.encoding; case .mov(let facts): return facts.encoding }
        }
        public var sourceRate: Int {
            switch self { case .wav(let info): return info.sourceRate; case .mov(let facts): return facts.rate }
        }
        public var sourceChannels: Int {
            switch self { case .wav(let info): return info.sourceChannels; case .mov(let facts): return facts.channels }
        }
        public var sourceFrames: Int {
            switch self { case .wav(let info): return info.sourceFrames; case .mov(let facts): return facts.sourceFrames }
        }
        public var outputFrames: Int {
            switch self { case .wav(let info): return info.outputFrames; case .mov(let facts): return facts.outputFrames }
        }
        public var outputRate: Int {
            switch self { case .wav(let info): return info.outputRate; case .mov(let facts): return facts.outputRate }
        }
        public var clippedSamples: Int {
            switch self { case .wav(let info): return info.clippedSamples; case .mov(let facts): return facts.clipped }
        }
        public var origin: Origin {
            switch self {
            case .wav(let info):
                switch info.origin { case .strictPCM16k: return .strictPCM16k; case .systemPCMConversion: return .systemPCMConversion }
            case .mov: return .directMOVPCM16k
            }
        }
    }
    public struct SourceDecoded: Sendable {
        public let samples: [Float]
        public let transientSourceInfo: SourceFacts
        fileprivate init(_ decoded: Decoded) {
            samples = decoded.samples; transientSourceInfo = .wav(decoded.transientSourceInfo)
        }
        fileprivate init(_ decoded: ImportedPCMMOV.Decoded) {
            samples = decoded.samples; transientSourceInfo = .mov(decoded.facts)
        }
    }
    public static func decodeSource(_ bytes: Data, format: SourceFormat,
                                    canceled: () -> Bool = { false },
                                    makeNative: () -> Native = { Native() }) throws -> SourceDecoded {
        switch format {
        case .wav: return SourceDecoded(try decode(bytes, canceled: canceled, native: makeNative()))
        case .mov: return SourceDecoded(try ImportedPCMMOV.decode(bytes, canceled: canceled))
        }
    }

    public enum Failure: Error, Equatable {
        case format, structure, duration, native, output
        public var message: String {
            switch self {
            case .format: return "Use a mono 16-bit WAV file."
            case .structure: return "This WAV file seems damaged."
            case .duration: return "Use a file under 10 minutes and 20 MB."
            case .native, .output: return "This WAV couldn’t be converted. Save it as a mono 16 kHz WAV and try again."
            }
        }
    }

    // Only the native bottom is replaceable. Parser, input ownership, accounting and drain stay real.
    struct Step {
        let status: AVAudioConverterOutputStatus
        var error: NSError? = nil
    }
    public struct Native {
        public init() {}
        var make: (AVAudioFormat, AVAudioFormat) -> AVAudioConverter? = { AVAudioConverter(from: $0, to: $1) }
        var primeInfo: (AVAudioConverter) -> AVAudioConverterPrimeInfo = { $0.primeInfo }
        var configure: (AVAudioConverter) -> Void = {
            $0.primeMethod = .normal; $0.downmix = false; $0.channelMap = [0]
        }
        var convert: (AVAudioConverter, AVAudioPCMBuffer, @escaping AVAudioConverterInputBlock) -> Step = { converter, output, input in
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            return Step(status: status, error: error)
        }
    }
    private struct Layout {
        let pcm: Range<Int>, rate: Int, frames: Int, floor: Int, ceil: Int
    }

    public static func decode(_ bytes: Data, canceled: () -> Bool = { false }) throws -> Decoded {
        try decode(bytes, canceled: canceled, native: Native(), inputChunkLimit: 4096)
    }

    public static func decode(_ bytes: Data, canceled: () -> Bool = { false }, native: Native) throws -> Decoded {
        try decode(bytes, canceled: canceled, native: native, inputChunkLimit: 4096)
    }

    static func decode(_ bytes: Data, canceled: () -> Bool = { false }, native: Native,
                       inputChunkLimit: Int) throws -> Decoded {
        if canceled() { throw CancellationError() }
        let layout = try inspect(bytes, canceled: canceled)
        if layout.rate == 16_000 {
            let samples = try ImportedWAV.decode(bytes, canceled: canceled)
            return Decoded(samples: samples, transientSourceInfo: info(layout, count: samples.count, clipped: 0))
        }
        guard (1...4096).contains(inputChunkLimit) else { throw Failure.native }
        return try withoutActuallyEscaping(canceled) { check in
            try autoreleasepool {
                try convert(bytes, layout: layout, canceled: check, native: native, inputChunkLimit: inputChunkLimit)
            }
        }
    }

    private static func info(_ layout: Layout, count: Int, clipped: Int) -> SourceInfo {
        SourceInfo(sourceRate: layout.rate, sourceFrames: layout.frames, outputFrames: count,
                   origin: layout.rate == 16_000 ? .strictPCM16k : .systemPCMConversion, clippedSamples: clipped)
    }

    private static func inspect(_ bytes: Data, canceled: () -> Bool) throws -> Layout {
        guard bytes.count <= ImportedWAV.maximumBytes else { throw ImportedWAV.Failure.size }
        guard bytes.count >= 12 else { throw Failure.structure }
        return try bytes.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
            func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
            func tag(_ p: Int, _ s: String) -> Bool { zip(s.utf8, 0..<4).allSatisfy { $0.0 == b[p + $0.1] } }
            guard tag(0, "RIFF"), tag(8, "WAVE") else { throw Failure.format }
            guard u32(4) == b.count - 8 else { throw Failure.structure }
            var offset = 12, chunks = 0
            var rate: Int?, pcm: Range<Int>?
            while offset < b.count {
                if canceled() { throw CancellationError() }
                chunks += 1
                guard chunks <= 128, b.count - offset >= 8 else { throw Failure.structure }
                let length = u32(offset + 4), start = offset + 8
                guard length <= b.count - start else { throw Failure.structure }
                let end = start + length, pad = length & 1
                guard pad <= b.count - end else { throw Failure.structure }
                if tag(offset, "fmt ") {
                    guard rate == nil, pcm == nil, length == 16 else { throw Failure.structure }
                    let r = u32(start + 4)
                    guard [8000, 16000, 22050, 24000, 32000, 44100, 48000].contains(r),
                          u16(start) == 1, u16(start + 2) == 1, u32(start + 8) == 2 * r,
                          u16(start + 12) == 2, u16(start + 14) == 16 else { throw Failure.format }
                    rate = r
                } else if tag(offset, "data") {
                    guard rate != nil, pcm == nil, length > 0, length & 1 == 0 else { throw Failure.structure }
                    pcm = start..<end
                }
                offset = end + pad
            }
            guard offset == b.count, let rate, let pcm else { throw Failure.structure }
            let n = Int64(pcm.count / 2), r = Int64(rate)
            let (fifths, fifthOverflow) = n.multipliedReportingOverflow(by: 5)
            let (maximum, maximumOverflow) = r.multipliedReportingOverflow(by: 600)
            let (q, qOverflow) = n.multipliedReportingOverflow(by: 16_000)
            let (rounded, roundOverflow) = q.addingReportingOverflow(r - 1)
            guard !fifthOverflow, !maximumOverflow, !qOverflow, !roundOverflow,
                  fifths >= 2 * r, n <= maximum, rounded / r <= Int64(ImportedWAV.maximumSamples) else { throw Failure.duration }
            return Layout(pcm: pcm, rate: rate, frames: Int(n), floor: Int(q / r), ceil: Int(rounded / r))
        }
    }

    private static func valid(_ format: AVAudioFormat, rate: Int) -> Bool {
        let d = format.streamDescription.pointee
        return format.sampleRate.isFinite && format.sampleRate == Double(rate) && format.channelCount == 1
            && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
            && d.mSampleRate == Double(rate) && d.mFormatID == kAudioFormatLinearPCM
            && d.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && d.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            && d.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && d.mChannelsPerFrame == 1 && d.mBitsPerChannel == 32
            && d.mBytesPerFrame == 4 && d.mBytesPerPacket == 4 && d.mFramesPerPacket == 1
    }

    private static func valid(_ buffer: AVAudioPCMBuffer, rate: Int, capacity: Int) -> Bool {
        guard valid(buffer.format, rate: rate), Int(buffer.frameCapacity) == capacity,
              buffer.frameLength <= buffer.frameCapacity, buffer.stride == 1,
              let channels = buffer.floatChannelData else { return false }
        let list = buffer.audioBufferList.pointee
        return list.mNumberBuffers == 1 && list.mBuffers.mNumberChannels == 1
            && list.mBuffers.mData == UnsafeMutableRawPointer(channels[0])
            && Int(list.mBuffers.mDataByteSize) == Int(buffer.frameLength) * 4
    }

    private final class Input {
        let bytes: Data, layout: Layout, buffer: AVAudioPCMBuffer
        let canceled: () -> Bool
        let limit: Int
        var cursor = 0, callbacks = 0, eos = false
        var failure: Error?
        init(bytes: Data, layout: Layout, buffer: AVAudioPCMBuffer, canceled: @escaping () -> Bool, limit: Int) {
            self.bytes = bytes; self.layout = layout; self.buffer = buffer; self.canceled = canceled; self.limit = limit
        }
        func supply(_ requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            status.pointee = .endOfStream
            callbacks += 1
            if canceled() { failure = CancellationError() }
            guard failure == nil else { return nil }
            guard callbacks <= 131_072, requested > 0, requested <= UInt32(Int32.max) else {
                failure = Failure.native; return nil
            }
            guard cursor < layout.frames else { eos = true; return nil }
            let count = min(Int(requested), limit, layout.frames - cursor)
            guard count > 0, buffer.frameCapacity == 4096, buffer.frameLength <= buffer.frameCapacity else {
                failure = Failure.native; return nil
            }
            buffer.frameLength = AVAudioFrameCount(count)
            guard valid(buffer, rate: layout.rate, capacity: 4096), let output = buffer.floatChannelData?[0] else {
                failure = Failure.native; return nil
            }
            bytes.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                let start = layout.pcm.lowerBound + cursor * 2
                for i in 0..<count {
                    let p = start + i * 2
                    let word = UInt16(b[p]) | UInt16(b[p + 1]) << 8
                    output[i] = Float(Int16(bitPattern: word)) / 32_768
                }
            }
            if canceled() { failure = CancellationError(); return nil }
            cursor += count; status.pointee = .haveData
            return buffer
        }
    }

    private static func convert(_ bytes: Data, layout: Layout, canceled: @escaping () -> Bool,
                                native: Native, inputChunkLimit: Int) throws -> Decoded {
        func check() throws { if canceled() { throw CancellationError() } }
        try check()
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(layout.rate), channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              valid(from, rate: layout.rate), valid(to, rate: 16_000) else { throw Failure.native }
        try check()
        let created = native.make(from, to)
        try check()
        guard let converter = created else { throw Failure.native }
        native.configure(converter)
        try check()
        let prime = native.primeInfo(converter)
        guard valid(converter.inputFormat, rate: layout.rate), valid(converter.outputFormat, rate: 16_000),
              converter.primeMethod == .normal, !converter.downmix, converter.channelMap == [0],
              prime.leadingFrames <= 16_384, prime.trailingFrames <= 16_384 else { throw Failure.native }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 4096),
              let tail = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 1),
              valid(inputBuffer, rate: layout.rate, capacity: 4096),
              valid(output, rate: 16_000, capacity: 4096), valid(tail, rate: 16_000, capacity: 1) else { throw Failure.native }
        let input = Input(bytes: bytes, layout: layout, buffer: inputBuffer, canceled: canceled, limit: inputChunkLimit)
        var samples = [Float](); samples.reserveCapacity(layout.ceil)
        var clipped = 0
        for _ in 0..<8192 {
            try check()
            // A tail is scoped to this call and released before another is allocated.
            let completed: Decoded? = try autoreleasepool {
                let remaining = layout.ceil - samples.count
                let capacity = remaining > 0 ? min(4096, remaining) : 1
                guard (1...4096).contains(capacity), remaining == 0 ? capacity == 1 : capacity <= remaining else { throw Failure.output }
                let buffer: AVAudioPCMBuffer
                if capacity == 4096 { buffer = output }
                else if capacity == 1 { buffer = tail }
                else {
                    guard let sized = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(capacity)) else { throw Failure.native }
                    buffer = sized
                }
                buffer.frameLength = 0
                guard valid(buffer, rate: 16_000, capacity: capacity) else { throw Failure.native }
                let before = input.cursor
                let step = native.convert(converter, buffer, input.supply)
                try check()
                if let failure = input.failure { throw failure }
                guard step.error == nil, step.status != .error,
                      valid(buffer, rate: 16_000, capacity: capacity) else { throw Failure.native }
                let count = Int(buffer.frameLength)
                if step.status == .endOfStream {
                    guard count == 0, input.cursor == layout.frames, input.eos,
                          (layout.floor...layout.ceil).contains(samples.count),
                          (6400...ImportedWAV.maximumSamples).contains(samples.count) else { throw Failure.output }
                    return Decoded(samples: samples, transientSourceInfo: info(layout, count: samples.count, clipped: clipped))
                }
                // A fractional floor may be tentative output; only later zero-frame EOS completes it.
                let terminalFraction = input.cursor == layout.frames && input.eos
                    && layout.ceil == layout.floor + 1 && count > 0 && count == capacity - 1
                    && samples.count + count == layout.floor
                guard step.status == .haveData || step.status == .inputRanDry,
                      step.status != .haveData || count == capacity || terminalFraction,
                      count <= remaining, count > 0 || input.cursor > before,
                      let channel = buffer.floatChannelData?[0] else { throw Failure.output }
                for i in 0..<count {
                    let value = channel[i]
                    guard value.isFinite else { throw Failure.output }
                    if value < -1 || value > 1 { clipped += 1 }
                    samples.append(min(1, max(-1, value)))
                }
                try check()
                return nil
            }
            if let completed { return completed }
        }
        throw Failure.output
    }
}
