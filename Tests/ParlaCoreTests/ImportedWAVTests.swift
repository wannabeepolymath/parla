import XCTest
@testable import ParlaCore

final class ImportedWAVTests: XCTestCase {
    private func le(_ value: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func chunk(_ tag: String, _ bytes: Data, pad: Bool = true) -> Data {
        Data(tag.utf8) + le(bytes.count, 4) + bytes + (pad && bytes.count & 1 == 1 ? Data([0]) : Data())
    }
    private func fmt(channels: Int = 1, rate: Int = 16_000, tag: Int = 1, bits: Int = 16) -> Data {
        le(tag, 2) + le(channels, 2) + le(rate, 4) + le(32_000, 4) + le(2, 2) + le(bits, 2)
    }
    private func riff(_ chunks: Data) -> Data { Data("RIFF".utf8) + le(chunks.count + 4, 4) + Data("WAVE".utf8) + chunks }
    private func pcm(_ frames: Int = 6400) -> Data { Data(repeating: 0x7F, count: frames * 2) }
    func testT02ExactScalarNormalizationAndAncillaryPadding() throws {
        var bytes = pcm(); bytes.replaceSubrange(0..<8, with: Data([0, 128, 255, 127, 255, 255, 0, 0]))
        let samples = try ImportedWAV.decode(riff(chunk("JUNK", Data([9])) + chunk("fmt ", fmt()) + chunk("data", bytes) + chunk("LIST", Data([8]))))
        XCTAssertEqual(samples.count, 6400)
        XCTAssertEqual(Array(samples.prefix(4)), [-1, 32767.0 / 32768, -1.0 / 32768, 0])
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 >= -1 && $0 < 1 })
    }
    func testT03ExactDurationAndEncodedBounds() throws {
        for count in [6400, ImportedWAV.maximumSamples] {
            XCTAssertEqual(try ImportedWAV.decode(riff(chunk("fmt ", fmt()) + chunk("data", pcm(count)))).count, count)
        }
        for count in [0, 6399, ImportedWAV.maximumSamples + 1] {
            XCTAssertThrowsError(try ImportedWAV.decode(riff(chunk("fmt ", fmt()) + chunk("data", pcm(count)))))
        }
        XCTAssertThrowsError(try ImportedWAV.decode(Data(repeating: 0, count: ImportedWAV.maximumBytes + 1)))
        let base = chunk("fmt ", fmt()) + chunk("data", pcm())
        let padding = ImportedWAV.maximumBytes - (12 + base.count + 8)
        XCTAssertEqual(try ImportedWAV.decode(riff(base + chunk("JUNK", Data(repeating: 0, count: padding)))).count, 6400)
    }
    func testT03CompleteGrammarChunkCountAndCancellation() throws {
        let base = chunk("fmt ", fmt()) + chunk("data", pcm())
        let empty = chunk("JUNK", Data())
        XCTAssertEqual(try ImportedWAV.decode(riff(base + Data((0..<126).flatMap { _ in empty }))).count, 6400)
        let invalid = [
            riff(base + Data((0..<127).flatMap { _ in empty })),
            riff(base + chunk("data", pcm())), riff(base + chunk("fmt ", fmt())),
            riff(chunk("data", pcm()) + chunk("fmt ", fmt())), riff(chunk("fmt ", fmt())),
            riff(chunk("fmt ", fmt()) + chunk("data", Data([1, 2, 3]))),
            riff(base + chunk("JUNK", Data([1]), pad: false)),
            riff(base) + Data([0]), Data(riff(base).dropLast()),
            riff(base + Data("JUNK".utf8) + le(Int(UInt32.max), 4)),
            riff(chunk("fmt ", fmt() + Data([0, 0])) + chunk("data", pcm()))
        ]
        for bytes in invalid { XCTAssertThrowsError(try ImportedWAV.decode(bytes)) }
        XCTAssertThrowsError(try ImportedWAV.decode(riff(base), canceled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testT04UnsupportedFormatsRefuseWholeInput() throws {
        for format in [fmt(channels: 2), fmt(rate: 48_000), fmt(tag: 3), fmt(tag: 0xFFFE), fmt(tag: 6), fmt(bits: 32)] {
            XCTAssertThrowsError(try ImportedWAV.decode(riff(chunk("fmt ", format) + chunk("data", pcm()))))
        }
        for tag in ["RIFX", "RF64", "ftyp"] {
            var bytes = riff(chunk("fmt ", fmt()) + chunk("data", pcm()))
            bytes.replaceSubrange(0..<4, with: tag.utf8)
            XCTAssertThrowsError(try ImportedWAV.decode(bytes))
        }
    }
}
