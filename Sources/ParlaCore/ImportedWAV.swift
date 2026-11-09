import Foundation

/// Complete, deliberately narrow PCM-WAV grammar. No codec, resampler or IO.
public enum ImportedWAV {
    public static let maximumBytes = 20 * 1024 * 1024
    public static let maximumSamples = 9_600_000
    public enum Failure: Error, Equatable {
        case size, format, structure, duration
        public var message: String {
            switch self {
            case .size: return "Choose a WAV file under 20 MB."
            case .format: return "Use a mono 16 kHz 16-bit WAV file."
            case .structure: return "This WAV file seems damaged."
            case .duration: return "Use a file under 10 minutes."
            }
        }
    }
    public static func decode(_ bytes: Data, canceled: () -> Bool = { false }) throws -> [Float] {
        guard bytes.count <= maximumBytes else { throw Failure.size }
        guard bytes.count >= 12 else { throw Failure.structure }
        return try bytes.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
            func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
            func tag(_ p: Int, _ s: String) -> Bool { zip(s.utf8, 0..<4).allSatisfy { $0.0 == b[p + $0.1] } }
            guard tag(0, "RIFF"), tag(8, "WAVE") else { throw Failure.format }
            guard u32(4) == b.count - 8 else { throw Failure.structure }
            var offset = 12, chunks = 0, format = false
            var pcm: Range<Int>?
            while offset < b.count {
                if canceled() { throw CancellationError() }
                chunks += 1
                guard chunks <= 128, b.count - offset >= 8 else { throw Failure.structure }
                let length = u32(offset + 4), start = offset + 8
                guard length <= b.count - start else { throw Failure.structure }
                let end = start + length, pad = length & 1
                guard pad <= b.count - end else { throw Failure.structure }
                if tag(offset, "fmt ") {
                    guard !format, pcm == nil, length == 16 else { throw Failure.structure }
                    guard u16(start) == 1, u16(start + 2) == 1, u32(start + 4) == 16_000,
                          u32(start + 8) == 32_000, u16(start + 12) == 2, u16(start + 14) == 16 else { throw Failure.format }
                    format = true
                } else if tag(offset, "data") {
                    guard format, pcm == nil, length > 0, length & 1 == 0 else { throw Failure.structure }
                    guard (6400...maximumSamples).contains(length / 2) else { throw Failure.duration }
                    pcm = start..<end
                }
                offset = end + pad
            }
            guard offset == b.count, format, let pcm else { throw Failure.structure }
            var samples = [Float](); samples.reserveCapacity(pcm.count / 2)
            for start in stride(from: pcm.lowerBound, to: pcm.upperBound, by: 32_768) {
                if canceled() { throw CancellationError() }
                for p in stride(from: start, to: min(start + 32_768, pcm.upperBound), by: 2) {
                    samples.append(Float(Int16(bitPattern: UInt16(u16(p)))) / 32_768)
                }
            }
            guard samples.count == pcm.count / 2 else { throw Failure.structure }
            return samples
        }
    }
}
