import XCTest
import AVFoundation
@testable import ParlaCore

/// 440Hz sine, `frames` long, starting at sample `offset` of that sine.
private func sineBuffer(rate: Double, channels: AVAudioChannelCount,
                        frames: AVAudioFrameCount, offset: Int = 0) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let ptr = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            ptr[i] = sinf(2 * .pi * 440 * Float(offset + i) / Float(rate))
        }
    }
    return buf
}

final class AudioTests: XCTestCase {
    /// 0.5s 440Hz sine at 48kHz stereo → expect ~8000 mono samples at 16kHz.
    func testConvertResamplesTo16kMono() throws {
        let buf = sineBuffer(rate: 48_000, channels: 2, frames: 24_000)
        let out = AudioRecorder.convert(buf)
        XCTAssertEqual(out.count, 8_000, accuracy: 200)
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.5) // signal survived
    }

    func testConvertPassthroughAt16kMono() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
        buf.frameLength = 1600
        XCTAssertEqual(AudioRecorder.convert(buf).count, 1600, accuracy: 50)
    }

    /// The reason the converter is cached: feeding one sine through a single
    /// Resampler in six pieces must give the same stream as converting it whole.
    /// A per-buffer converter restarts its filter at each piece and diverges.
    func testChunkedConversionMatchesOneShot() throws {
        let whole = AudioRecorder.convert(sineBuffer(rate: 48_000, channels: 2, frames: 24_000))

        let resampler = Resampler()
        var chunked: [Float] = []
        for piece in 0..<6 {
            let buf = sineBuffer(rate: 48_000, channels: 2, frames: 4_000, offset: piece * 4_000)
            chunked += try XCTUnwrap(resampler.convert(buf, to: AudioRecorder.targetFormat))
        }
        chunked += resampler.flush()

        // Draining each piece would emit the filter tail six times over.
        XCTAssertEqual(chunked.count, whole.count, accuracy: 4)
        // And no seam: 440Hz at 16kHz steps by at most ~0.173 between samples.
        let step = (1..<chunked.count).map { abs(chunked[$0] - chunked[$0 - 1]) }.max() ?? 0
        XCTAssertLessThan(step, 0.25)
    }

    /// A mid-recording device change swaps the input format; the cached
    /// converter must be rebuilt rather than reused or dropped.
    func testResamplerRebuildsOnInputFormatChange() throws {
        let resampler = Resampler()
        let at48k = try XCTUnwrap(resampler.convert(
            sineBuffer(rate: 48_000, channels: 2, frames: 4_800), to: AudioRecorder.targetFormat))
        let at44k = try XCTUnwrap(resampler.convert(
            sineBuffer(rate: 44_100, channels: 1, frames: 4_410), to: AudioRecorder.targetFormat))
        let at44kSteady = try XCTUnwrap(resampler.convert(
            sineBuffer(rate: 44_100, channels: 1, frames: 4_410, offset: 4_410),
            to: AudioRecorder.targetFormat))

        // A converter primes its filter on its first buffer, so the first output
        // after a build — and after a rebuild — is short by the filter delay.
        // Nothing is lost: those frames stay in the converter and come out of the
        // next call, or out of flush() (see testChunkedConversionMatchesOneShot).
        XCTAssertGreaterThan(at48k.count, 1_000)
        XCTAssertGreaterThan(at44k.count, 1_000)
        // Steady state is the assertion that matters here: 4410 frames at 44.1k
        // yield a full 1600 at 16k only if the converter was cached across the
        // two calls rather than rebuilt — a rebuild would re-prime and come up short.
        XCTAssertEqual(at44kSteady.count, 1_600, accuracy: 200)
        XCTAssertGreaterThan(at44k.map(abs).max() ?? 0, 0.5) // signal survived the rebuild
    }
}

func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy,
        "\(a) not within \(accuracy) of \(b)", file: file, line: line)
}
