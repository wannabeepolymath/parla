import AVFoundation
import XCTest
@testable import ParlaCore

final class ImportedCompressedAudioTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path) }

    /// 2 s of 440 Hz stereo 44.1 kHz encoded as AAC in an .m4a, generated here; nothing is committed.
    private func m4a(seconds: Double = 2) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-fixture-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                                   AVNumberOfChannelsKey: 2],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) } }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
    private func decode(_ bytes: Data, maximumSamples: Int = ImportedWAV.maximumSamples,
                        canceled: @escaping () -> Bool = { false }) throws -> ImportedCompressedAudio.Decoded {
        try ImportedCompressedAudio.decode(bytes, format: .m4a, canceled: canceled, maximumSamples: maximumSamples, directory: directory)
    }

    func testM4ADecodesTo16kMonoWithReportedFacts() throws {
        let decoded = try decode(try m4a())
        XCTAssertEqual(Double(decoded.samples.count), 32_000, accuracy: 1_600)
        let rms = (decoded.samples.reduce(0) { $0 + $1 * $1 } / Float(decoded.samples.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.05)
        XCTAssertEqual(decoded.facts.sourceRate, 44_100); XCTAssertEqual(decoded.facts.sourceChannels, 2)
        XCTAssertEqual(decoded.facts.codec, "aac "); XCTAssertEqual(decoded.facts.container, "M4A")
        XCTAssertEqual(decoded.facts.outputFrames, decoded.samples.count); XCTAssertEqual(decoded.facts.outputRate, 16_000)
        XCTAssertEqual(try ImportedAudio.decodeSource(try m4a(), format: .m4a).transientSourceInfo.origin, .systemCompressedConversion)
        XCTAssertEqual(try leftovers(), [])
    }
    func testOutputCapRefusesWithoutAPartialResult() throws {
        XCTAssertThrowsError(try decode(try m4a(), maximumSamples: 1_000)) { XCTAssertEqual($0 as? ImportedCompressedAudio.Failure, .duration) }
        XCTAssertEqual(try leftovers(), [])
    }
    func testCancellationAfterTheFirstBufferStopsAndRemovesTheCopy() throws {
        let bytes = try m4a()
        var checks = 0
        // Checks 1–3 precede the first buffer; the fourth follows it.
        XCTAssertThrowsError(try decode(bytes, canceled: { checks += 1; return checks > 3 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(try leftovers(), [])
    }
    /// A valid MPEG-4 container holding one 16×16 H.264 frame and no audio track, generated here.
    private func videoOnly() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-fixture-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixels)
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(adaptor.append(try XCTUnwrap(pixels), withPresentationTime: .zero))
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return try Data(contentsOf: url)
    }
    func testVideoOnlyIsAFormatFailureAndCorruptIsADecodeFailure() throws {
        XCTAssertThrowsError(try decode(try videoOnly())) { XCTAssertEqual($0 as? ImportedCompressedAudio.Failure, .format) }
        let audio = try m4a()
        for corrupt in [Data(repeating: 0, count: 4_096), audio.prefix(audio.count / 2)] {
            XCTAssertThrowsError(try decode(corrupt)) { XCTAssertEqual($0 as? ImportedCompressedAudio.Failure, .native) }
        }
        XCTAssertEqual(try leftovers(), [])
        XCTAssertThrowsError(try ImportedCompressedAudio.decode(audio, format: .wav)) { XCTAssertEqual($0 as? ImportedCompressedAudio.Failure, .format) }
    }
}
