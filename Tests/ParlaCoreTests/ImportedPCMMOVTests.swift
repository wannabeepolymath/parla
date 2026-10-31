import Foundation
import XCTest
@testable import ParlaCore

// Independently authored inert bytes, never media files or a playable-bitstream claim.
private func pcmBE(_ n: Int, _ width: Int = 4) -> Data {
    Data((0..<width).map { UInt8(truncatingIfNeeded: n >> (8 * (width - 1 - $0))) })
}
private func pcmWords(_ values: Int...) -> Data { pcmRows([values]) }
private func pcmRows(_ rows: [[Int]]) -> Data {
    var bytes: [UInt8] = []
    for row in rows {
        for value in row {
            for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
    }
    return Data(bytes)
}
private func pcmZeros(_ count: Int) -> Data { Data(repeating: 0, count: count) }
private struct PCMAtom {
    var type: String
    var prefix: Data
    var children: [PCMAtom]
    init(_ type: String, _ prefix: Data = Data(), _ children: [PCMAtom] = []) {
        self.type = type; self.prefix = prefix; self.children = children
    }
    var bytes: Data {
        var body = prefix
        for child in children { body.append(child.bytes) }
        return pcmBE(body.count + 8) + Data(type.utf8) + body
    }
    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    mutating func change(_ path: [String], _ edit: (inout PCMAtom) -> Void) {
        guard let first = path.first else { edit(&self); return }
        guard let index = children.firstIndex(where: { $0.type == first }) else {
            preconditionFailure("Missing authored path")
        }
        children[index].change(Array(path.dropFirst()), edit)
    }
    mutating func put(_ offset: Int, _ value: Int, width: Int = 4) {
        prefix.replaceSubrange(offset..<(offset + width), with: pcmBE(value, width))
    }
}
private let pcmTable = ["mdia", "minf", "stbl"]
private let pcmAudioEntry = pcmTable + ["stsd", "sowt"]
private let pcmVisualEntry = pcmTable + ["stsd", "avc1"]
private struct PCMFixture {
    let bytes: Data
    let audioOffsets: [Int]
    let videoOffsets: [Int]
    let payloadBytes: Int
    let boxCount: Int
}
private struct PCMOracle {
    var frames = 6_400
    var audioChunks: [Int]?
    var videoFrames = 1
    var videoChunks: [Int]?
    var videoSizes: [Int]?
    var videoTiming: [[Int]]?
    var sync: [Int]?
    var movieScale = 16_000
    var movieTicks: Int?
    var videoScale: Int?
    var videoTicks: Int?
    var identityEdits = false
    var moovFirst = false
    var brandCount = 1
    var visualTail = Data([0, 0, 0, 9, 0x63, 0x68, 0x72, 0x6d, 0x7f])
    var videoByte: UInt8 = 0xa5
    var extraPayload = 0
    var audioEdit: ((inout PCMAtom) -> Void)?
    var videoEdit: ((inout PCMAtom) -> Void)?
    var movieEdit: ((inout PCMAtom) -> Void)?
    private var matrix: Data { pcmWords(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000) }
    private func runs(_ chunks: [Int]) -> Data {
        var rows: [[Int]] = []
        for i in chunks.indices where i == 0 || chunks[i] != chunks[i - 1] { rows.append([i + 1, chunks[i], 1]) }
        return pcmWords(0, rows.count) + pcmRows(rows)
    }
    func make() -> PCMFixture {
        let ac = audioChunks ?? [frames], vc = videoChunks ?? [videoFrames]
        precondition(ac.reduce(0, +) == frames && vc.reduce(0, +) == videoFrames)
        precondition(videoSizes == nil || videoSizes?.count == videoFrames)
        var pcm = pcmZeros(frames * 2)
        // Literal signed16LE words: minimum, -1, zero, +1, maximum. Rest is zero.
        pcm.replaceSubrange(0..<10, with: Data([0x00, 0x80, 0xff, 0xff, 0, 0, 1, 0, 0xff, 0x7f]))
        var payload = Data(), audioOffsets: [Int] = [], videoOffsets: [Int] = []
        var audioFrame = 0, videoFrame = 0
        for i in 0..<max(ac.count, vc.count) {
            if i < ac.count {
                audioOffsets.append(payload.count)
                let end = audioFrame + ac[i]
                payload.append(pcm[(audioFrame * 2)..<(end * 2)]); audioFrame = end
            }
            if i < vc.count {
                videoOffsets.append(payload.count)
                let end = videoFrame + vc[i]
                let bytes = videoSizes.map { $0[videoFrame..<end].reduce(0, +) } ?? vc[i]
                payload.append(Data(repeating: videoByte, count: bytes)); videoFrame = end
            }
        }
        payload.append(pcmZeros(extraPayload))
        var brandBytes = Data("qt  ".utf8) + pcmBE(0)
        for _ in 0..<brandCount { brandBytes.append(Data("qt  ".utf8)) }
        let brand = PCMAtom("ftyp", brandBytes)
        let movieDuration = movieTicks ?? frames
        func movie(at base: Int) -> PCMAtom {
            func track(_ audio: Bool) -> PCMAtom {
                let count = audio ? frames : videoFrames
                let scale = audio ? 16_000 : (videoScale ?? 16_000 * videoFrames)
                let duration = audio ? frames : (videoTicks ?? frames * videoFrames)
                let tkhd = PCMAtom("tkhd", pcmWords(3, 0, 0, audio ? 1 : 2, 0, movieDuration) + pcmZeros(12)
                                   + pcmBE(audio ? 0x100 : 0, 2) + pcmBE(0, 2) + matrix
                                   + pcmWords(audio ? 0 : 16 << 16, audio ? 0 : 16 << 16))
                let mdhd = PCMAtom("mdhd", pcmWords(0, 0, 0, scale, duration) + pcmBE(0x55c4, 2) + pcmBE(0, 2))
                let hdlr = PCMAtom("hdlr", pcmWords(0, 0) + Data((audio ? "soun" : "vide").utf8) + pcmZeros(12) + Data([0]))
                let entry = audio
                    ? PCMAtom("sowt", pcmZeros(6) + pcmBE(1, 2) + pcmZeros(8) + pcmBE(1, 2) + pcmBE(16, 2) + pcmWords(0, 0x3e800000))
                    : PCMAtom("avc1", pcmZeros(6) + pcmBE(1, 2) + pcmZeros(16) + pcmBE(16, 2) + pcmBE(16, 2) + pcmZeros(50) + visualTail)
                let timeRows = audio ? [[frames, 1]] : (videoTiming ?? [[videoFrames, frames]])
                let offsets = audio ? audioOffsets : videoOffsets
                let sizes = !audio ? videoSizes : nil
                var tables = [PCMAtom("stsd", pcmWords(0, 1), [entry]),
                              PCMAtom("stts", pcmWords(0, timeRows.count) + pcmRows(timeRows)),
                              PCMAtom("stsz", pcmWords(0, audio ? 2 : (sizes == nil ? 1 : 0), count)
                                      + (sizes.map { pcmRows($0.map { [$0] }) } ?? Data())),
                              PCMAtom("stsc", runs(audio ? ac : vc)),
                              PCMAtom("stco", pcmWords(0, offsets.count) + pcmRows(offsets.map { [base + $0] }))]
                if !audio, let sync { tables.append(PCMAtom("stss", pcmWords(0, sync.count) + pcmRows(sync.map { [$0] }))) }
                let dinf = PCMAtom("dinf", Data(), [PCMAtom("dref", pcmWords(0, 1), [PCMAtom("url ", pcmBE(1))])])
                let header = audio ? PCMAtom("smhd", pcmWords(0, 0)) : PCMAtom("vmhd", pcmWords(1, 0, 0))
                var result = PCMAtom("trak", Data(), [tkhd, PCMAtom("mdia", Data(), [mdhd, hdlr,
                    PCMAtom("minf", Data(), [header, dinf, PCMAtom("stbl", Data(), tables)])])])
                if identityEdits { result.children.append(PCMAtom("edts", Data(), [PCMAtom("elst", pcmWords(0, 1, movieDuration, 0, 0x10000))])) }
                if audio { audioEdit?(&result) } else { videoEdit?(&result) }
                return result
            }
            let mvhd = PCMAtom("mvhd", pcmWords(0, 0, 0, movieScale, movieDuration, 0x10000)
                               + pcmBE(0x100, 2) + pcmZeros(10) + matrix + pcmZeros(24) + pcmBE(3))
            var result = PCMAtom("moov", Data(), [mvhd, track(true), track(false)])
            movieEdit?(&result)
            return result
        }
        let before = moovFirst ? movie(at: 0).bytes.count : 0
        let base = brand.bytes.count + before + 8
        let moov = movie(at: base), mdat = PCMAtom("mdat", payload)
        let atoms = moovFirst ? [brand, moov, mdat] : [brand, mdat, moov]
        var bytes = Data()
        for atom in atoms { bytes.append(atom.bytes) }
        return PCMFixture(bytes: bytes, audioOffsets: audioOffsets.map { base + $0 }, videoOffsets: videoOffsets.map { base + $0 },
                          payloadBytes: payload.count, boxCount: atoms.reduce(0) { $0 + $1.count })
    }
}

final class ImportedPCMMOVTests: XCTestCase {
    private let literal: [Float] = [-1, -1.0 / 32768, 0, 1.0 / 32768, 32767.0 / 32768]
    @discardableResult
    private func admits(_ bytes: Data, frames: Int = 6_400, file: StaticString = #filePath, line: UInt = #line) throws -> ImportedPCMMOV.Decoded {
        let decoded = try ImportedPCMMOV.decode(bytes)
        XCTAssertEqual(decoded.facts.sourceFrames, frames, file: file, line: line)
        XCTAssertEqual(decoded.samples.count, frames, file: file, line: line)
        XCTAssertEqual(Array(decoded.samples.prefix(5)), literal, file: file, line: line)
        XCTAssertEqual(decoded.sourceBytes, bytes, file: file, line: line)
        return decoded
    }
    private func refuses(_ bytes: Data, _ expected: ImportedPCMMOV.Failure? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try ImportedPCMMOV.decode(bytes); XCTFail("Unexpected admission", file: file, line: line) }
        catch let failure as ImportedPCMMOV.Failure {
            if let expected { XCTAssertEqual(failure, expected, file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    func testLiteralNormalizationSplitInterleavingAndBothMoviePositions() throws {
        for first in [false, true] {
            var oracle = PCMOracle(); oracle.moovFirst = first
            oracle.audioChunks = [2, 6_398]; oracle.videoFrames = 2; oracle.videoChunks = [1, 1]
            let fixture = oracle.make(), result = try admits(fixture.bytes)
            XCTAssertEqual(result.inspection.audioChunkCount, 2)
            XCTAssertEqual(result.samples[2], 0) // Sentinel straddles video-separated chunks.
            XCTAssertTrue(result.samples.dropFirst(5).allSatisfy { $0 == 0 })
            XCTAssertTrue(result.samples.allSatisfy { $0.isFinite && $0 >= -1 && $0 < 1 })
            XCTAssertEqual(result.facts.profile, "qtPCM16kV1")
            XCTAssertEqual(result.facts.container, "QuickTime MOV")
            XCTAssertEqual(result.facts.encoding, "signed16LE")
            XCTAssertEqual(result.facts.rate, 16_000); XCTAssertEqual(result.facts.outputRate, 16_000)
            XCTAssertEqual(result.facts.channels, 1); XCTAssertEqual(result.facts.clipped, 0)
            XCTAssertEqual(result.facts.outputFrames, 6_400)
            XCTAssertEqual(result.facts.audioTrackID, 1); XCTAssertEqual(result.facts.videoTrackID, 2)
        }
    }
    func testFortySecondsUsesCompactTablesAndOneChunk() throws {
        var oracle = PCMOracle(); oracle.frames = 640_000
        let fixture = oracle.make(), result = try admits(fixture.bytes, frames: 640_000)
        XCTAssertEqual(result.inspection.audioChunkCount, 1)
        XCTAssertLessThan(fixture.bytes.count - fixture.payloadBytes, 2_048)
        XCTAssertEqual(result.samples.last, 0)
    }
    func testExactFrameAndCompleteSourceBoundsSequentially() throws {
        for frames in [6_400, 9_600_000] {
            var oracle = PCMOracle(); oracle.frames = frames
            let fixture = oracle.make(), result = try admits(fixture.bytes, frames: frames)
            XCTAssertEqual(result.inspection.audioChunkCount, 1)
        }
        for frames in [0, 6_399, 9_600_001] {
            // Declare the out-of-dialect count without expanding its payload.
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmTable + ["stsz"]) { $0.put(8, frames) } }
            refuses(oracle.make().bytes, .duration)
        }
        var oracle = PCMOracle()
        let small = oracle.make().bytes.count
        oracle.extraPayload = ImportedPCMMOV.maximumBytes - small
        let fixture = oracle.make()
        XCTAssertEqual(fixture.bytes.count, 20_971_520)
        _ = try admits(fixture.bytes)
        refuses(fixture.bytes + Data([0]), .encodedLimit)
        refuses(Data(), .encodedLimit)
    }
    func testOwnedSnapshotNormalizesSlicesAndSeversExternalMutableBacking() throws {
        let fixture = PCMOracle().make(), original = fixture.bytes
        for prefix in [0, 1, 128] {
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: original.count + prefix, alignment: 1)
            defer { allocation.deallocate() }
            allocation.initializeMemory(as: UInt8.self, repeating: 0xee, count: original.count + prefix)
            original.copyBytes(to: allocation.advanced(by: prefix).assumingMemoryBound(to: UInt8.self), count: original.count)
            let backing = Data(bytesNoCopy: allocation, count: original.count + prefix, deallocator: .none)
            let slice = backing.dropFirst(prefix)
            XCTAssertEqual(slice.startIndex, prefix)
            let inspected = try ImportedPCMMOV.inspect(slice)
            allocation.storeBytes(of: UInt8(0x7f), toByteOffset: prefix + fixture.audioOffsets[0], as: UInt8.self)
            XCTAssertEqual(slice[slice.startIndex + fixture.audioOffsets[0]], 0x7f) // Demonstrate a live input alias.
            XCTAssertEqual(inspected.sourceBytes.startIndex, 0)
            XCTAssertEqual(inspected.sourceBytes.endIndex, original.count)
            XCTAssertEqual(inspected.sourceBytes, original)
            XCTAssertEqual(Array(try inspected.decode().samples.prefix(5)), literal)
            var exported = inspected.sourceBytes; exported[fixture.audioOffsets[0]] = 0x7f
            XCTAssertNotEqual(exported, inspected.sourceBytes)
            XCTAssertEqual(inspected.sourceBytes, original)
        }
        var caller = original
        let inspected = try ImportedPCMMOV.inspect(caller)
        caller[0] ^= 1
        XCTAssertEqual(inspected.sourceBytes, original)
        XCTAssertEqual(Array(try inspected.decode().samples.prefix(5)), literal)
    }
    func testIdentityEditsAndExactRationalClocks() throws {
        var oracle = PCMOracle(); oracle.movieScale = 1_000; oracle.movieTicks = 400
        oracle.videoScale = 600; oracle.videoTicks = 240; oracle.videoTiming = [[1, 240]]
        let absent = try admits(oracle.make().bytes)
        oracle.identityEdits = true
        let present = try admits(oracle.make().bytes)
        XCTAssertEqual(absent.facts, present.facts); XCTAssertEqual(absent.samples, present.samples)
        XCTAssertEqual(present.facts.movieTimescale, 1_000); XCTAssertEqual(present.facts.movieDuration, 400)
        XCTAssertEqual(present.facts.videoTimescale, 600); XCTAssertEqual(present.facts.videoDuration, 240)
        for scale in [1_001, 0xffff_ffff] {
            var changed = oracle; changed.movieScale = scale
            refuses(changed.make().bytes, .timing)
        }
        for (offset, value) in [(4, 0), (4, 2), (8, 399), (12, 1), (12, 0xffff_ffff),
                                (12, 0x8000_0000), (16, 0), (16, 0x20000), (16, 0xffff0000)] {
            for audio in [true, false] {
                var changed = oracle
                let edit: (inout PCMAtom) -> Void = { track in track.change(["edts", "elst"]) { $0.put(offset, value) } }
                if audio { changed.audioEdit = edit } else { changed.videoEdit = edit }
                refuses(changed.make().bytes, .timing)
            }
        }
        var longEdit = oracle
        longEdit.audioEdit = { track in track.change(["edts", "elst"]) { $0.prefix.append(pcmWords(0, 0, 0)) } }
        refuses(longEdit.make().bytes, .malformed)
        var version = oracle
        version.audioEdit = { track in track.change(["edts", "elst"]) { $0.put(0, 0x01000000) } }
        refuses(version.make().bytes, .unsupported)
        var wrongAudioClock = oracle
        wrongAudioClock.audioEdit = { track in track.change(["mdia", "mdhd"]) { $0.put(12, 48_000) } }
        refuses(wrongAudioClock.make().bytes, .timing)
    }
    func testCheckedRationalMultiplicationRefusesOverflowWithoutFallback() throws {
        var oracle = PCMOracle(); oracle.frames = 16_000
        oracle.movieScale = 0xffff_ffff; oracle.movieTicks = 0xffff_ffff
        _ = try admits(oracle.make().bytes, frames: 16_000) // Exact one-second rational positive.
        oracle.videoScale = 1; oracle.videoTicks = 0xffff_ffff
        refuses(oracle.make().bytes, .malformed) // (2^32-1)^2 cannot fit nonnegative Int64.
    }
    func testOpaqueVisualTailAndInertVideoMutationPreserveAudio() throws {
        let oracle = PCMOracle(), baseline = try admits(oracle.make().bytes)
        var changed = oracle
        changed.visualTail = Data(repeating: 0xff, count: oracle.visualTail.count)
        changed.videoByte = 0x19
        changed.videoEdit = { track in track.change(pcmVisualEntry) { $0.put(28, 0xdeadbeef); $0.put(74, 0, width: 2) } }
        let result = try admits(changed.make().bytes)
        XCTAssertEqual(result.facts, baseline.facts); XCTAssertEqual(result.samples, baseline.samples)
        XCTAssertNotEqual(result.sourceBytes, baseline.sourceBytes)
        // Neither successful input certifies playable AVC. No native consumer exists in this API.
        var short = oracle
        short.videoEdit = { track in track.change(pcmVisualEntry) { $0.prefix = Data($0.prefix.prefix(77)) } }
        refuses(short.make().bytes, .malformed)
        for (offset, value, width) in [(6, 2, 2), (24, 0, 2), (26, 0, 2)] {
            var bad = oracle
            bad.videoEdit = { track in track.change(pcmVisualEntry) { $0.put(offset, value, width: width) } }
            refuses(bad.make().bytes)
        }
    }
    func testExactAudioEntrySchemaNoCodecVersionOrEndiannessFallback() throws {
        _ = try admits(PCMOracle().make().bytes)
        // Offsets below are from the 28-byte audio body, independently described in the contract.
        let changes = [(0, 1, 1), (6, 2, 2), (8, 1, 2), (8, 2, 2), (10, 1, 2), (12, 1, 4),
                       (16, 2, 2), (18, 8, 2), (18, 32, 2), (20, 0xffff, 2), (22, 1, 2),
                       (24, 0x3e800001, 4), (24, 48_000 << 16, 4), (24, 0x0000803e, 4)]
        for (offset, value, width) in changes {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmAudioEntry) { $0.put(offset, value, width: width) } }
            refuses(oracle.make().bytes)
        }
        for codec in ["twos", "lpcm", "raw ", "NONE", "mp4a", "enca", "fl32"] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmAudioEntry) { $0.type = codec } }
            refuses(oracle.make().bytes, .format)
        }
        for tail in [Data([0]), PCMAtom("enda", pcmBE(1)).bytes, PCMAtom("wave").bytes,
                     PCMAtom("chan").bytes, PCMAtom("esds").bytes, PCMAtom("sinf").bytes] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmAudioEntry) { $0.prefix.append(tail) } }
            refuses(oracle.make().bytes, .format)
        }
        var twoDescriptions = PCMOracle()
        twoDescriptions.audioEdit = { track in track.change(pcmTable + ["stsd"]) { $0.put(4, 2); $0.children.append($0.children[0]) } }
        refuses(twoDescriptions.make().bytes, .unsupported)
    }
    func testAudioFixedSizeAndTimingTablesAreExact() throws {
        _ = try admits(PCMOracle().make().bytes)
        for fixed in [0, 1, 4] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmTable + ["stsz"]) { $0.put(4, fixed) } }
            refuses(oracle.make().bytes, .format)
        }
        var explicitSizes = PCMOracle()
        explicitSizes.audioEdit = { track in track.change(pcmTable + ["stsz"]) { $0.prefix = pcmWords(0, 0, 6400) + pcmRows(Array(repeating: [2], count: 6400)) } }
        refuses(explicitSizes.make().bytes, .format)
        for (type, offset, value) in [("stsz", 8, 6401), ("stts", 8, 6399), ("stts", 12, 0),
                                     ("stts", 12, 2), ("stts", 4, 0xffff_ffff)] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmTable + [type]) { $0.put(offset, value) } }
            refuses(oracle.make().bytes)
        }
        for type in ["stsz", "stts", "stco", "stsc"] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmTable + [type]) { $0.prefix.append(Data([0])) } }
            refuses(oracle.make().bytes, .malformed)
        }
        var twoTimeRows = PCMOracle()
        twoTimeRows.audioEdit = { track in track.change(pcmTable + ["stts"]) { $0.prefix = pcmWords(0, 2, 3200, 1, 3200, 1) } }
        refuses(twoTimeRows.make().bytes, .timing)
    }
    func testChunkRunGeometryRangesHeadersAndCrossAliases() throws {
        var base = PCMOracle(); base.audioChunks = [2, 6398]
        let fixture = base.make(); _ = try admits(fixture.bytes)
        for (offset, value) in [(8, 0), (8, 2), (12, 0), (12, 6401), (16, 2), (20, 1), (20, 3)] {
            var oracle = base
            oracle.audioEdit = { track in track.change(pcmTable + ["stsc"]) { $0.put(offset, value) } }
            refuses(oracle.make().bytes)
        }
        for offset in [0, fixture.audioOffsets[0] - 8, fixture.audioOffsets[0] - 1,
                       fixture.bytes.count, 0xffff_ffff] {
            var oracle = base
            oracle.audioEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(8, offset) } }
            refuses(oracle.make().bytes, .extent)
        }
        var overlap = base
        overlap.audioEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(12, fixture.audioOffsets[0] + 2) } }
        refuses(overlap.make().bytes, .extent)
        var decrease = base
        decrease.audioEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(8, fixture.audioOffsets[1]); $0.put(12, fixture.audioOffsets[0]) } }
        refuses(decrease.make().bytes, .extent)
        var cross = base
        cross.videoEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(8, fixture.audioOffsets[0]) } }
        refuses(cross.make().bytes, .extent)
        var crossesEnd = base
        crossesEnd.audioEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(12, fixture.audioOffsets[1] + 1) } }
        refuses(crossesEnd.make().bytes, .extent)
        var videoReuse = PCMOracle(); videoReuse.videoFrames = 2; videoReuse.videoChunks = [1, 1]
        let videoFixture = videoReuse.make(); _ = try admits(videoFixture.bytes)
        videoReuse.videoEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(12, videoFixture.videoOffsets[0]) } }
        refuses(videoReuse.make().bytes, .extent)
    }
    func testVideoVariableSizesSyncGeometryAndTiming() throws {
        var oracle = PCMOracle(); oracle.videoFrames = 3; oracle.videoSizes = [1, 2, 3]
        oracle.videoChunks = [1, 2]; oracle.sync = [1, 3]
        _ = try admits(oracle.make().bytes)
        let edits: [(inout PCMAtom) -> Void] = [
            { track in track.change(pcmTable + ["stsz"]) { $0.put(12, 0) } },
            { track in track.change(pcmTable + ["stsz"]) { $0.put(12, 0xffff_ffff) } },
            { track in track.change(pcmTable + ["stts"]) { $0.put(12, 6399) } },
            { track in track.change(pcmTable + ["stss"]) { $0.put(12, 1) } },
            { track in track.change(pcmTable + ["stss"]) { $0.put(12, 4) } },
            { track in track.change(pcmTable + ["stss"]) { $0.put(8, 0) } }
        ]
        for edit in edits {
            var bad = oracle; bad.videoEdit = edit; refuses(bad.make().bytes)
        }
        // Video chunk byte order may differ from presentation order; sort is ONLY an alias proof.
        var reverse = PCMOracle(); reverse.videoFrames = 2; reverse.videoChunks = [1, 1]
        let offsets = reverse.make().videoOffsets
        reverse.videoEdit = { track in track.change(pcmTable + ["stco"]) { $0.put(8, offsets[1]); $0.put(12, offsets[0]) } }
        _ = try admits(reverse.make().bytes)
    }
    func testClosedReferencesTracksHandlersAndStructuralAudioSemantics() throws {
        _ = try admits(PCMOracle().make().bytes)
        let url = ["mdia", "minf", "dinf", "dref", "url "]
        let edits: [(inout PCMAtom) -> Void] = [
            { track in track.change(url) { $0.prefix = pcmBE(0) + Data("file:///outside\0".utf8) } },
            { track in track.change(url) { $0.type = "alis" } },
            { track in track.change(url) { $0.prefix.append(Data([0])) } },
            { track in track.change(["mdia", "minf", "dinf", "dref"]) { $0.put(4, 2) } },
            { $0.children.append(PCMAtom("tref")) },
            { track in track.change(["mdia"]) { $0.children.append(PCMAtom("zzzz")) } },
            { track in track.change(["mdia", "minf"]) { $0.children.append(PCMAtom("hdlr")) } },
            { track in track.change(["mdia", "hdlr"]) { $0.put(4, 1) } },
            { track in track.change(["tkhd"]) { $0.put(0, 7) } }
        ]
        for edit in edits {
            for audio in [true, false] {
                var oracle = PCMOracle()
                if audio { oracle.audioEdit = edit } else { oracle.videoEdit = edit }
                refuses(oracle.make().bytes)
            }
        }
        for type in ["ctts", "stss", "sdtp", "sgpd", "sbgp", "chrm", "co64", "zzzz"] {
            var oracle = PCMOracle()
            oracle.audioEdit = { track in track.change(pcmTable) { $0.children.append(PCMAtom(type)) } }
            refuses(oracle.make().bytes, .unsupported)
        }
        var duplicate = PCMOracle()
        duplicate.audioEdit = { track in track.change(pcmTable) { $0.children.append($0.children[0]) } }
        refuses(duplicate.make().bytes, .malformed)
        var missing = PCMOracle()
        missing.audioEdit = { track in track.change(pcmTable) { $0.children.removeAll { $0.type == "stts" } } }
        refuses(missing.make().bytes, .malformed)
        var extra = PCMOracle(); extra.movieEdit = { $0.children.append($0.children[1]) }
        refuses(extra.make().bytes, .tracks)
        var sameIDs = PCMOracle(); sameIDs.videoEdit = { track in track.change(["tkhd"]) { $0.put(12, 1) } }
        refuses(sameIDs.make().bytes, .tracks)
        var twoAudio = PCMOracle()
        twoAudio.movieEdit = { $0.children[2] = $0.children[1]; $0.children[2].change(["tkhd"]) { $0.put(12, 2) } }
        refuses(twoAudio.make().bytes, .tracks)
        var twoVideo = PCMOracle()
        twoVideo.movieEdit = { $0.children[1] = $0.children[2]; $0.children[1].change(["tkhd"]) { $0.put(12, 1) } }
        refuses(twoVideo.make().bytes, .tracks)
    }
    func testFragmentBrandBoxSizeAndUnknownNestingRefusals() throws {
        let bytes = PCMOracle().make().bytes; _ = try admits(bytes)
        for type in ["moof", "mfra", "mvex", "cmov", "rmra", "uuid", "zzzz"] {
            refuses(bytes + PCMAtom(type).bytes, .unsupported)
            var oracle = PCMOracle(); oracle.movieEdit = { $0.children.append(PCMAtom(type)) }
            refuses(oracle.make().bytes, .unsupported)
        }
        for size in [0, 1] { refuses(bytes + pcmBE(size) + Data("free".utf8), .unsupported) }
        refuses(bytes + pcmBE(7) + Data("free".utf8), .malformed)
        refuses(bytes + pcmBE(0xffff_ffff) + Data("free".utf8), .malformed)
        refuses(bytes + Data([0]), .malformed); refuses(Data(bytes.dropLast()), .malformed)
        var badBrand = bytes; badBrand.replaceSubrange(8..<12, with: Data("isom".utf8))
        refuses(badBrand, .unsupported)
        var badCompatible = bytes; badCompatible.replaceSubrange(16..<20, with: Data("mp42".utf8))
        refuses(badCompatible, .unsupported)
        refuses(bytes + PCMAtom("mdat", Data([0])).bytes, .malformed)
        var nested = PCMAtom("moov")
        for _ in 0..<13 { nested = PCMAtom("moov", Data(), [nested]) }
        var deep = PCMOracle(); deep.movieEdit = { $0.children.append(nested) }
        // Unadmitted nesting is terminal before depth12; this does not exercise a fictitious valid depth13 path.
        refuses(deep.make().bytes, .unsupported)
    }
    func testVersionZeroHeaderPredicatesAndRequiredOuterBoxesRemainClosed() throws {
        let fixture = PCMOracle().make(); _ = try admits(fixture.bytes)
        for (offset, value, width) in [(0, 0x01000000, 4), (12, 0, 4), (20, 0, 4),
                                       (24, 0, 2), (36, 0, 4), (96, 0, 4)] {
            var oracle = PCMOracle()
            oracle.movieEdit = { movie in movie.change(["mvhd"]) { $0.put(offset, value, width: width) } }
            refuses(oracle.make().bytes)
        }
        let edits: [(inout PCMAtom) -> Void] = [
            { track in track.change(["tkhd"]) { $0.put(12, 0) } },
            { track in track.change(["tkhd"]) { $0.put(16, 1) } },
            { track in track.change(["tkhd"]) { $0.put(20, 6399) } },
            { track in track.change(["tkhd"]) { $0.put(34, 1, width: 2) } },
            { track in track.change(["mdia", "mdhd"]) { $0.put(22, 1, width: 2) } },
            { track in track.change(["mdia", "hdlr"]) { $0.prefix.replaceSubrange(8..<12, with: Data("meta".utf8)) } },
            { track in track.change(["mdia", "minf", "smhd"]) { $0.put(4, 1) } }
        ]
        for edit in edits { var oracle = PCMOracle(); oracle.audioEdit = edit; refuses(oracle.make().bytes) }
        for (path, offset, value) in [(pcmTable + ["stts"], 0, 1), (["mdia", "minf", "vmhd"], 0, 0)] {
            var oracle = PCMOracle()
            oracle.videoEdit = { track in track.change(path) { $0.put(offset, value) } }
            refuses(oracle.make().bytes, .unsupported)
        }
        var ctts = PCMOracle()
        ctts.videoEdit = { track in track.change(pcmTable) { $0.children.append(PCMAtom("ctts")) } }
        refuses(ctts.make().bytes, .unsupported)
        refuses(fixture.bytes + Data(fixture.bytes.prefix(20)), .malformed) // duplicate ftyp
        refuses(Data(fixture.bytes.dropFirst(20)), .malformed) // required ftyp absent
        for duplicate in [false, true] {
            var oracle = PCMOracle()
            oracle.movieEdit = { movie in
                if duplicate { movie.children.append(movie.children[0]) }
                else { movie.children.removeFirst() }
            }
            refuses(oracle.make().bytes, .tracks)
        }
    }
    func testExactMetadataAndBoxLimitsWithPositiveControls() throws {
        let fixture = PCMOracle().make(), outside = fixture.bytes.count - fixture.payloadBytes
        let exact = fixture.bytes + PCMAtom("free", pcmZeros(2_097_152 - outside - 8)).bytes
        _ = try admits(exact)
        refuses(fixture.bytes + PCMAtom("free", pcmZeros(2_097_152 - outside - 7)).bytes, .metadataLimit)
        var boxes = fixture.bytes
        for _ in 0..<(4_096 - fixture.boxCount) { boxes.append(PCMAtom("free").bytes) }
        _ = try admits(boxes)
        refuses(boxes + PCMAtom("free").bytes, .boxLimit)
    }
    func testExactCombinedChunksVideoFramesAndExplicitRowLimits() throws {
        func chunks(_ count: Int) -> [Int] {
            Array(repeating: 2, count: 6_400 - count) + Array(repeating: 1, count: count * 2 - 6_400)
        }
        var oracle = PCMOracle(); oracle.audioChunks = chunks(4_095)
        let exact = try admits(oracle.make().bytes)
        XCTAssertEqual(exact.inspection.audioChunkCount, 4_095) // plus one video chunk
        oracle.audioChunks = chunks(4_096); refuses(oracle.make().bytes, .chunkLimit)
        for n in [32_768, 32_769] {
            var video = PCMOracle(); video.videoFrames = n
            if n == 32_768 { _ = try admits(video.make().bytes) }
            else { refuses(video.make().bytes, .videoFrameLimit) }
        }
        var rows = PCMOracle(); rows.videoFrames = 16_000
        rows.videoSizes = Array(repeating: 1, count: 16_000)
        rows.videoTiming = Array(repeating: [1, 6_400], count: 16_000)
        rows.sync = Array(1...759)
        // 4 description/reference entries +1 audio map +2 offsets +1 audio timing
        // +16000 explicit sizes +16000 video timing +759 sync +1 video map =32768.
        _ = try admits(rows.make().bytes)
        rows.sync = Array(1...760); refuses(rows.make().bytes, .rowLimit)
        for type in ["stco", "stsc", "stts"] {
            var huge = PCMOracle()
            huge.audioEdit = { track in track.change(pcmTable + [type]) { $0.put(4, 0xffff_ffff) } }
            refuses(huge.make().bytes, type == "stts" ? .rowLimit : .chunkLimit)
        }
    }
    func testRealStructuralWorkBoundaryIncludesMergeComparisons() throws {
        var oracle = PCMOracle()
        // Independent grammar arithmetic: 38 box reads +34 classifications +10 explicit rows
        // +2 chunk constructions +2 merge emits +1 comparison +2 overlap checks =89.
        // Compatible qt brands contribute one credit each, with actual complete positive input.
        oracle.brandCount = 131_072 - 89
        _ = try admits(oracle.make().bytes)
        oracle.brandCount += 1
        refuses(oracle.make().bytes, .workLimit)
    }
    func testCancellationEveryReachableCheckpointAndBoundedScalarBlocks() throws {
        var oracle = PCMOracle(); oracle.audioChunks = [2, 6_398]
        oracle.videoFrames = 2; oracle.videoChunks = [1, 1]; oracle.videoSizes = [1, 2]
        oracle.videoTiming = [[1, 6400], [1, 6400]]; oracle.sync = [1, 2]; oracle.identityEdits = true
        let fixture = oracle.make()
        var checkpoints = 0
        let complete = try ImportedPCMMOV.decode(fixture.bytes, canceled: { checkpoints += 1; return false })
        XCTAssertEqual(Array(complete.samples.prefix(5)), literal)
        // Sweep the finite real boundary: copy brackets, boxes, classifications, rows, chunks,
        // exact clocks, merge comparisons/emits/alias checks, reserve brackets and scalar blocks.
        for stop in 1...checkpoints {
            var calls = 0
            XCTAssertThrowsError(try ImportedPCMMOV.decode(fixture.bytes, canceled: { calls += 1; return calls == stop })) {
                XCTAssertEqual($0 as? ImportedPCMMOV.Failure, .canceled)
            }
        }
        var long = PCMOracle(); long.frames = 640_000
        let inspection = try ImportedPCMMOV.inspect(long.make().bytes)
        var polls = 0
        XCTAssertEqual(try inspection.decode(canceled: { polls += 1; return false }).samples.count, 640_000)
        // One entry + one post-reserve + one chunk +ceil(N/4096) block +one terminal check.
        XCTAssertEqual(polls, 4 + (640_000 + 4_095) / 4_096)
        for stop in [1, 2, 3, 4, 5, polls - 1, polls] {
            var calls = 0
            XCTAssertThrowsError(try inspection.decode(canceled: { calls += 1; return calls == stop })) {
                XCTAssertEqual($0 as? ImportedPCMMOV.Failure, .canceled)
            }
        }
        XCTAssertEqual(try inspection.decode().samples.count, 640_000)
    }
}
