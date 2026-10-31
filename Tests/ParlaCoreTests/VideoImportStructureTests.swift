import Foundation
import XCTest
@testable import ParlaCore

// Independent byte oracle: no production parser/writer, native codec, filesystem or media fixture.
// Payload bytes are synthetic; these tests establish container declarations only.
private func be(_ n: UInt64, _ width: Int = 4) -> Data {
    Data((0..<width).map { UInt8(truncatingIfNeeded: n >> (8 * (width - 1 - $0))) })
}
private func words(_ values: UInt64...) -> Data { values.reduce(Data()) { $0 + be($1) } }
private func zeros(_ count: Int) -> Data { Data(repeating: 0, count: count) }

private struct Atom {
    var type: String
    var prefix: Data = Data()
    var children: [Atom] = []
    var body: Data { children.reduce(prefix) { $0 + $1.bytes } }
    var bytes: Data { be(UInt64(body.count + 8)) + Data(type.utf8) + body }
    var boxCount: Int { 1 + children.reduce(0) { $0 + $1.boxCount } }

    init(_ type: String, _ body: Data = Data(), _ children: [Atom] = []) {
        self.type = type; prefix = body; self.children = children
    }
    mutating func change(_ path: [String], _ edit: (inout Atom) -> Void) {
        guard let first = path.first else { edit(&self); return }
        guard let index = children.firstIndex(where: { $0.type == first }) else {
            preconditionFailure("Authored oracle path is absent")
        }
        children[index].change(Array(path.dropFirst()), edit)
    }
    mutating func put(_ offset: Int, _ value: UInt64, width: Int = 4) {
        prefix.replaceSubrange(offset..<(offset + width), with: be(value, width))
    }
}

private struct MovieOracle {
    var rate: UInt64 = 48_000
    var channels: UInt64 = 1
    var packets: UInt64 = 20
    var videoSamples: UInt64 = 1
    var leading: UInt64 = 1024
    var presentation: UInt64 = 19_200
    var audioExtra: [Atom] = []
    var movieExtra: [Atom] = []
    var extraPayload = 0
    var quickTime = false
    var audioEdit: ((inout Atom) -> Void)?
    var videoEdit: ((inout Atom) -> Void)?
    var movieEdit: ((inout Atom) -> Void)?

    private var matrix: Data { words(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000) }
    private func descriptor(_ type: UInt8, _ body: Data) -> Data {
        precondition(body.count < 128)
        return Data([type, UInt8(body.count)]) + body
    }
    var atoms: [Atom] {
        let brand = quickTime ? "qt  " : "isom"
        let ftyp = Atom("ftyp", Data(brand.utf8) + be(0) + Data(brand.utf8))
        let payloadStart = UInt64(ftyp.bytes.count + 8)
        let videoStart = payloadStart + packets * 2
        // Fixture has two bytes per audio packet and one per declared video sample.
        let mdat = Atom("mdat", Data(repeating: 0xa5, count: Int(packets * 2 + videoSamples) + extraPayload))
        let mvhd = Atom("mvhd", words(0, 0, 0, rate, presentation, 0x10000)
                        + be(0x100, 2) + zeros(10) + matrix + zeros(24) + be(3))
        func track(id: UInt64, audio: Bool) -> Atom {
            let count = audio ? packets : videoSamples
            // Video has one constant decode delta per sample; this rational equals the edit
            // duration exactly, without depending on production timing arithmetic.
            let scale = audio ? rate : rate * videoSamples
            let duration = audio ? packets * 1024 : presentation * videoSamples
            let tkhd = Atom("tkhd", words(3, 0, 0, id, 0, presentation) + zeros(12)
                            + be(audio ? 0x100 : 0, 2) + be(0, 2) + matrix
                            + words(audio ? 0 : 16 << 16, audio ? 0 : 16 << 16))
            let mdhd = Atom("mdhd", words(0, 0, 0, scale, duration) + be(0x55c4, 2) + be(0, 2))
            let hdlr = Atom("hdlr", words(0, 0) + Data((audio ? "soun" : "vide").utf8) + zeros(12) + Data([0]))
            let dinf = Atom("dinf", Data(), [Atom("dref", words(0, 1), [Atom("url ", be(1))])])
            let sampleEntry: Atom
            if audio {
                let asc: Data
                switch (rate, channels) {
                case (48_000, 1): asc = Data([0x11, 0x88])
                case (48_000, 2): asc = Data([0x11, 0x90])
                case (44_100, 1): asc = Data([0x12, 0x08])
                default: asc = Data([0x12, 0x10])
                }
                let config = Data([0x40, 0x15, 0, 0, 0]) + words(0, 0) + descriptor(5, asc)
                let es = be(1, 2) + Data([0]) + descriptor(4, config) + descriptor(6, Data([2]))
                let esds = Atom("esds", be(0) + descriptor(3, es))
                sampleEntry = Atom("mp4a", zeros(6) + be(1, 2) + zeros(8) + be(channels, 2)
                                    + be(16, 2) + words(0, rate << 16), [esds])
            } else {
                // Baseline avcC, one length-delimited SPS and PPS. NAL payloads are opaque.
                let avcc = Atom("avcC", Data([1, 66, 0, 30, 0xff, 0xe1, 0, 2, 0x67, 0, 1, 0, 2, 0x68, 0]))
                sampleEntry = Atom("avc1", zeros(6) + be(1, 2) + zeros(16) + be(16, 2) + be(16, 2)
                                    + words(0x480000, 0x480000, 0) + be(1, 2) + zeros(32)
                                    + be(24, 2) + be(0xffff, 2), [avcc])
            }
            let table = Atom("stbl", Data(), [
                Atom("stsd", words(0, 1), [sampleEntry]),
                Atom("stts", words(0, 1, count, audio ? 1024 : presentation)),
                Atom("stsc", words(0, 1, 1, count, 1)),
                Atom("stsz", words(0, audio ? 2 : 1, count)),
                Atom("stco", words(0, 1, audio ? payloadStart : videoStart))
            ])
            let header = audio ? Atom("smhd", words(0, 0)) : Atom("vmhd", words(1, 0, 0))
            let mdia = Atom("mdia", Data(), [mdhd, hdlr, Atom("minf", Data(), [header, dinf, table])])
            var result = Atom("trak", Data(), [tkhd, mdia])
            if audio {
                result.children.append(Atom("edts", Data(), [Atom("elst", words(0, 1, presentation, leading, 0x10000))]))
                result.children += audioExtra; audioEdit?(&result)
            } else { videoEdit?(&result) }
            return result
        }
        var movie = Atom("moov", Data(), [mvhd, track(id: 1, audio: true), track(id: 2, audio: false)] + movieExtra)
        movieEdit?(&movie)
        return [ftyp, mdat, movie]
    }
    var bytes: Data { atoms.reduce(Data()) { $0 + $1.bytes } }
}

final class VideoImportStructureTests: XCTestCase {
    private func refuses(_ data: Data, _ expected: VideoImportStructure.Failure? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
        // This is the only handoff seam: a native consumer must never receive failed preflight.
        var downstreamCalls = 0
        do {
            _ = try VideoImportStructure.inspect(data); downstreamCalls += 1
            XCTFail("Unexpected structural admission", file: file, line: line)
        } catch let failure as VideoImportStructure.Failure {
            if let expected { XCTAssertEqual(failure, expected, file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
        XCTAssertEqual(downstreamCalls, 0, file: file, line: line)
    }

    func testSupportedAACProjectionIsBoundToBytesAndNeverNativeEligible() throws {
        let oracle = MovieOracle(), bytes = oracle.bytes
        let facts = try VideoImportStructure.inspect(bytes)
        XCTAssertEqual(facts.container, .mp4)
        XCTAssertEqual(facts.sourceBytes, bytes)
        XCTAssertEqual(facts.audio.rate, 48_000)
        XCTAssertEqual(facts.audio.channels, 1)
        XCTAssertEqual(facts.audio.packetCount, 20)
        XCTAssertEqual(facts.audio.packetDomainFrames, 20_480)
        XCTAssertEqual(facts.audio.declaredLeadingFrames, 1024)
        XCTAssertEqual(facts.audio.declaredTrailingFrames, 256)
        XCTAssertEqual(facts.audio.declaredPresentationFrames, 19_200)
        XCTAssertEqual(facts.audio.mediaInterval.start, 1024)
        XCTAssertEqual(facts.audio.mediaInterval.timescale, 48_000)
        let start = oracle.atoms[0].bytes.count + 8
        XCTAssertEqual(facts.mediaData, [start..<(start + 41)])
        XCTAssertEqual(facts.audio.packets, (0..<20).map { (start + $0 * 2)..<(start + $0 * 2 + 2) })
        XCTAssertEqual(facts.video.samples, [(start + 40)..<(start + 41)])
        XCTAssertEqual(facts.video.mediaInterval.duration, 19_200)
        XCTAssertEqual(facts.video.mediaInterval.timescale, 48_000)
        XCTAssertEqual(facts.nativeEligibility, .notAdmittedAACDelayAndNativeTrimUnproven)
        XCTAssertEqual(try VideoImportStructure.inspect(bytes), facts)
        var changed = bytes; changed[start] ^= 1
        let changedFacts = try VideoImportStructure.inspect(changed)
        XCTAssertNotEqual(changedFacts.sourceBytes, facts.sourceBytes)
        XCTAssertEqual(facts.sourceBytes, bytes) // value-semantic original survives copy mutation
        XCTAssertEqual(changedFacts.nativeEligibility, facts.nativeEligibility)
    }

    func testNonzeroOriginSlicesReturnDirectlyIndexableByteRanges() throws {
        let oracle = MovieOracle()
        var original = oracle.bytes
        let start = oracle.atoms[0].bytes.count + 8
        // Distinct inert payload bytes reveal shifts within either track, without decoding.
        for offset in 0..<41 { original[start + offset] = UInt8(offset + 1) }
        let audio = (0..<20).map { (start + $0 * 2)..<(start + $0 * 2 + 2) }
        let video = [(start + 40)..<(start + 41)]
        let media = [start..<(start + 41)]
        for prefix in [1, 128] {
            var backing = Data(repeating: 0xee, count: prefix) + original
            let slice = backing.dropFirst(prefix)
            XCTAssertEqual(slice.startIndex, prefix)
            let facts = try VideoImportStructure.inspect(slice)
            XCTAssertEqual(facts.sourceBytes.startIndex, 0)
            XCTAssertEqual(facts.sourceBytes.endIndex, original.count)
            XCTAssertEqual(facts.sourceBytes, original)
            XCTAssertEqual(facts.audio.packets, audio)
            XCTAssertEqual(facts.video.samples, video)
            XCTAssertEqual(facts.mediaData, media)
            for range in audio + video + media {
                guard range.lowerBound >= facts.sourceBytes.startIndex,
                      range.upperBound <= facts.sourceBytes.endIndex else {
                    XCTFail("File range must directly index the retained snapshot"); continue
                }
                XCTAssertEqual(Data(facts.sourceBytes[range]), Data(original[range]))
            }
            backing[prefix + start] ^= 1
            XCTAssertEqual(facts.sourceBytes, original)
            XCTAssertEqual(facts.nativeEligibility, .notAdmittedAACDelayAndNativeTrimUnproven)
        }
    }

    func testMonoStereoIndexedRatesAndQuickTime() throws {
        for rate in [UInt64(44_100), 48_000] {
            for channels in [UInt64(1), 2] {
                var oracle = MovieOracle(); oracle.rate = rate; oracle.channels = channels
                oracle.presentation = rate * 2 / 5; oracle.quickTime = true
                let result = try VideoImportStructure.inspect(oracle.bytes)
                XCTAssertEqual(result.audio.rate, Int(rate)); XCTAssertEqual(result.audio.channels, Int(channels))
                XCTAssertEqual(result.container, .quickTime)
                XCTAssertEqual(result.audio.declaredPresentationFrames, Int64(rate * 2 / 5))
                XCTAssertEqual(result.nativeEligibility, .notAdmittedAACDelayAndNativeTrimUnproven)
            }
        }
    }

    func testExplicitSizeVariantsAndExactMDATExtents() throws {
        let oracle = MovieOracle(), atoms = oracle.atoms
        // A finite 64-bit moov size is supported; offsets precede it and remain unchanged.
        let wideMovie = be(1) + Data("moov".utf8) + be(UInt64(atoms[2].body.count + 16), 8) + atoms[2].body
        let bytes = atoms[0].bytes + atoms[1].bytes + wideMovie
        XCTAssertEqual(try VideoImportStructure.inspect(bytes).audio.packetCount, 20)
        var wideOffset = oracle
        wideOffset.videoEdit = { track in
            track.change(["mdia", "minf", "stbl", "stco"]) { box in
                box.type = "co64"; box.prefix = words(0, 1) + be(UInt64(atoms[0].bytes.count + 48), 8)
            }
        }
        XCTAssertEqual(try VideoImportStructure.inspect(wideOffset.bytes).video.samples.count, 1)
        var variable = oracle
        variable.audioEdit = { track in
            track.change(["mdia", "minf", "stbl", "stsz"]) { box in
                box.prefix = words(0, 0, 20) + (0..<20).reduce(Data()) { bytes, _ in bytes + be(2) }
            }
        }
        XCTAssertEqual(try VideoImportStructure.inspect(variable.bytes).audio.packets.count, 20)
    }

    func testMalformedLengthsZeroProgressAndUnsignedOverflowRefuse() {
        let bytes = MovieOracle().bytes
        refuses(Data(), .encodedLimit)
        refuses(Data([0, 0, 0]), .malformed)
        refuses(be(0) + Data("free".utf8), .malformed)
        refuses(be(7) + Data("free".utf8), .malformed)
        refuses(be(1) + Data("mdat".utf8) + be(UInt64.max, 8), .malformed)
        refuses(bytes.dropLast(), .malformed)
        refuses(bytes + Data([0]), .malformed)
        var huge = MovieOracle()
        huge.videoEdit = { track in
            track.change(["mdia", "minf", "stbl", "stco"]) { box in
                box.type = "co64"; box.prefix = words(0, 1) + be(UInt64.max, 8)
            }
        }
        refuses(huge.bytes, .extent)
        var count = MovieOracle()
        count.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stts"]) { $0.put(4, UInt64(UInt32.max)) } }
        refuses(count.bytes, .malformed)
    }

    func testCompactRepetitionAndProductCountsRefuseBeforeExpansion() {
        for type in ["stts", "stsc", "stsz"] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in
                track.change(["mdia", "minf", "stbl", type]) { box in
                    box.put(type == "stsc" ? 12 : 8, UInt64(UInt32.max))
                }
            }
            refuses(oracle.bytes)
        }
        var oracle = MovieOracle()
        oracle.videoEdit = { track in
            track.change(["mdia", "minf", "stbl", "stsc"]) { $0.put(12, 131_073) }
        }
        refuses(oracle.bytes, .malformed)
    }

    func testEncodedMetadataAndBoxCapsAndCapPlusOne() throws {
        var oracle = MovieOracle()
        let small = oracle.bytes, payload = Int(oracle.packets * 2 + oracle.videoSamples)
        let metadata = small.count - payload
        let exactMetadata = small + Atom("free", zeros(2 * 1024 * 1024 - metadata - 8)).bytes
        _ = try VideoImportStructure.inspect(exactMetadata)
        refuses(small + Atom("free", zeros(2 * 1024 * 1024 - metadata - 7)).bytes, .metadataLimit)
        oracle.extraPayload = 20 * 1024 * 1024 - small.count
        let exactBytes = oracle.bytes
        XCTAssertEqual(exactBytes.count, 20 * 1024 * 1024)
        _ = try VideoImportStructure.inspect(exactBytes)
        refuses(exactBytes + Data([0]), .encodedLimit)
        let count = MovieOracle().atoms.reduce(0) { $0 + $1.boxCount }
        let padding = (0..<(4096 - count)).reduce(Data()) { data, _ in data + Atom("free").bytes }
        _ = try VideoImportStructure.inspect(small + padding)
        refuses(small + padding + Atom("free").bytes, .boxLimit)
    }

    func testExpandedWorkExactCapAndPlusOne() throws {
        var oracle = MovieOracle(); oracle.videoSamples = 65_513
        // Audio: 43 units. Video: 2*N + 3. Total is exactly 131072.
        _ = try VideoImportStructure.inspect(oracle.bytes)
        oracle.videoEdit = { track in
            track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom("stss", words(0, 1, 1))) }
        }
        refuses(oracle.bytes, .workLimit)
    }

    func testDeclaredSampleAndPacketCapsPlusOneWithoutAllocatingRepetitions() {
        for (count, expected) in [(UInt64(32_769), VideoImportStructure.Failure.packetLimit),
                                  (131_073, .sampleLimit)] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stsz"]) { $0.put(8, count) } }
            refuses(oracle.bytes, expected)
        }
        // Combined-track cap includes the 20 already-declared audio samples.
        var combined = MovieOracle()
        combined.videoEdit = { track in track.change(["mdia", "minf", "stbl", "stsz"]) { $0.put(8, 131_053) } }
        refuses(combined.bytes, .sampleLimit)
        // At the nominal caps arithmetic proceeds, then rejects the inconsistent small oracle.
        for count in [UInt64(32_768), 131_052] {
            var exact = MovieOracle()
            let edit: (inout Atom) -> Void = { track in
                track.change(["mdia", "minf", "stbl", "stsz"]) { $0.put(8, count) }
            }
            if count == 32_768 { exact.audioEdit = edit } else { exact.videoEdit = edit }
            refuses(exact.bytes, .timing)
        }
    }

    func testClosedGrammarMissingDuplicateUnknownAndDepthRefuse() {
        for type in ["moof", "mfra", "sidx", "uuid", "cmov", "rmra", "meta", "pssh"] {
            refuses(MovieOracle().bytes + Atom(type).bytes, .unsupported)
        }
        for type in ["mvex", "udta", "cmov", "zzzz"] {
            var oracle = MovieOracle(); oracle.movieExtra = [Atom(type)]
            refuses(oracle.bytes, .unsupported)
        }
        var missing = MovieOracle()
        missing.audioEdit = { track in track.change(["mdia", "minf", "stbl"]) { $0.children.removeAll { $0.type == "stts" } } }
        refuses(missing.bytes, .malformed)
        var duplicate = MovieOracle()
        duplicate.audioEdit = { track in
            track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom("stts", words(0, 1, 20, 1024))) }
        }
        refuses(duplicate.bytes, .malformed)
        var nested = Atom("moov")
        for _ in 0..<13 { nested = Atom("moov", Data(), [nested]) }
        var deep = MovieOracle(); deep.movieExtra = [nested]
        // Closed grammar refuses the first unknown nesting, earlier than the absolute depth cap.
        refuses(deep.bytes, .unsupported)
        var duplicateHeader = MovieOracle()
        duplicateHeader.movieEdit = { $0.children.append($0.children[0]) }
        refuses(duplicateHeader.bytes, .tracks)
    }

    func testExternalEncryptedAndAmbiguousDescriptionsRefuse() {
        var external = MovieOracle()
        external.audioEdit = { track in
            track.change(["mdia", "minf", "dinf", "dref", "url "]) { $0.prefix = be(0) + Data("file:///outside\0".utf8) }
        }
        refuses(external.bytes, .unsupported)
        var alias = MovieOracle()
        alias.videoEdit = { track in track.change(["mdia", "minf", "dinf", "dref", "url "]) { $0.type = "alis" } }
        refuses(alias.bytes, .unsupported)
        for type in ["enca", "lpcm", "sowt"] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stsd", "mp4a"]) { $0.type = type } }
            refuses(oracle.bytes, .format)
        }
        for type in ["sinf", "schm", "tenc", "wave", "chan"] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stsd", "mp4a"]) { $0.children.append(Atom(type)) } }
            refuses(oracle.bytes, .unsupported)
        }
        var multiple = MovieOracle()
        multiple.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stsd"]) { $0.put(4, 2) } }
        refuses(multiple.bytes, .unsupported)
        var selectedDescription = MovieOracle()
        selectedDescription.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stsc"]) { $0.put(16, 2) } }
        refuses(selectedDescription.bytes, .malformed)
    }

    func testTrackCountEnabledAndMediaKindsRefuse() {
        var extra = MovieOracle(); extra.movieEdit = { $0.children.append($0.children[1]) }
        refuses(extra.bytes, .tracks)
        var missing = MovieOracle(); missing.movieEdit = { $0.children.removeLast() }
        refuses(missing.bytes, .tracks)
        var twoAudio = MovieOracle(); twoAudio.movieEdit = { $0.children[2] = $0.children[1] }
        refuses(twoAudio.bytes, .tracks)
        for flags in [UInt64(0), 2] {
            var disabled = MovieOracle()
            disabled.audioEdit = { track in track.change(["tkhd"]) { $0.put(0, flags) } }
            refuses(disabled.bytes, .unsupported)
        }
        var metadataTrack = MovieOracle()
        metadataTrack.videoEdit = { track in
            track.change(["mdia", "hdlr"]) { $0.prefix.replaceSubrange(8..<12, with: Data("meta".utf8)) }
        }
        refuses(metadataTrack.bytes, .tracks)
    }

    func testBothTracksExtentsAndReuseAreChecked() {
        let start = UInt64(MovieOracle().atoms[0].bytes.count + 8)
        for offset in [UInt64(0), start - 1, start, start + 41, UInt64(UInt32.max)] {
            var oracle = MovieOracle()
            oracle.videoEdit = { track in track.change(["mdia", "minf", "stbl", "stco"]) { $0.put(8, offset) } }
            refuses(oracle.bytes, .extent)
        }
        var audioEscape = MovieOracle()
        audioEscape.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stco"]) { $0.put(8, start + 2) } }
        refuses(audioEscape.bytes, .extent) // last audio packet aliases declared video byte
        var zero = MovieOracle()
        zero.videoEdit = { track in track.change(["mdia", "minf", "stbl", "stsz"]) { $0.prefix = words(0, 0, 1, 0) } }
        refuses(zero.bytes, .extent)
        // Two audio chunks referring to the same source range must not be silently reused.
        var repeated = MovieOracle()
        repeated.audioEdit = { track in
            track.change(["mdia", "minf", "stbl", "stco"]) { $0.prefix = words(0, 2, start, start) }
            track.change(["mdia", "minf", "stbl", "stsc"]) { $0.put(12, 10) }
        }
        refuses(repeated.bytes, .extent)
    }

    func testSeparateMDATsAreFiniteAndChunksCannotCrossHeaders() throws {
        let atoms = MovieOracle().atoms
        let start = UInt64(atoms[0].bytes.count + 8)
        var movie = atoms[2]
        movie.children[2].change(["mdia", "minf", "stbl", "stco"]) { $0.put(8, start + 48) }
        let prefix = atoms[0].bytes + Atom("mdat", Data(repeating: 0xa5, count: 40)).bytes
            + Atom("mdat", Data([0xa5])).bytes
        let result = try VideoImportStructure.inspect(prefix + movie.bytes)
        XCTAssertEqual(result.mediaData.count, 2)
        XCTAssertEqual(result.video.samples, [Int(start + 48)..<Int(start + 49)])
        movie.children[1].change(["mdia", "minf", "stbl", "stco"]) { $0.put(8, start + 1) }
        refuses(prefix + movie.bytes, .extent)
    }

    func testDeclaredTrimAndDurationBoundariesRemainUnqualified() throws {
        var leading = MovieOracle(); leading.packets = 35; leading.leading = 16_384
        XCTAssertEqual(try VideoImportStructure.inspect(leading.bytes).audio.declaredLeadingFrames, 16_384)
        leading.leading = 16_385
        refuses(leading.bytes, .timing)
        var trailing = MovieOracle(); trailing.packets = 36; trailing.leading = 1280
        XCTAssertEqual(try VideoImportStructure.inspect(trailing.bytes).audio.declaredTrailingFrames, 16_384)
        trailing.leading = 1279
        refuses(trailing.bytes, .timing)
        var maximum = MovieOracle(); maximum.packets = 28_125; maximum.leading = 0
        maximum.presentation = 28_800_000
        let result = try VideoImportStructure.inspect(maximum.bytes)
        XCTAssertEqual(result.audio.declaredPresentationFrames, 28_800_000)
        XCTAssertEqual(result.audio.declaredLeadingFrames, 0)
        XCTAssertEqual(result.audio.declaredTrailingFrames, 0)
        XCTAssertEqual(result.nativeEligibility, .notAdmittedAACDelayAndNativeTrimUnproven)
        maximum.packets += 1; maximum.presentation += 1
        refuses(maximum.bytes, .timing)
        var short = MovieOracle(); short.presentation = 19_199
        refuses(short.bytes, .timing)
    }

    func testFrameCardinalityCompositionAndEditAmbiguityRefuse() {
        for delta in [UInt64(0), 960, 1023] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["mdia", "minf", "stbl", "stts"]) { $0.put(12, delta) } }
            refuses(oracle.bytes, .timing)
        }
        for type in ["ctts", "cslg", "sbgp", "sgpd", "stz2", "saiz", "saio", "senc"] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom(type)) } }
            refuses(oracle.bytes, .unsupported)
        }
        var absent = MovieOracle(); absent.audioEdit = { $0.children.removeAll { $0.type == "edts" } }
        refuses(absent.bytes, .timing)
        let edits: [(Int, UInt64)] = [(4, 2), (12, UInt64(UInt32.max)), (12, 16_385), (16, 0x20000)]
        for (offset, value) in edits {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(["edts", "elst"]) { $0.put(offset, value) } }
            refuses(oracle.bytes, .timing)
        }
        var rounded = MovieOracle()
        rounded.movieEdit = { movie in
            movie.change(["mvhd"]) { $0.put(12, 48_001) }
        }
        refuses(rounded.bytes, .timing)
        var mismatch = MovieOracle()
        mismatch.audioEdit = { track in track.change(["mdia", "mdhd"]) { $0.put(16, 20_479) } }
        refuses(mismatch.bytes, .timing)
    }

    func testAACConfigurationNestedLengthsAndVideoConfigAreDefensive() {
        let path = ["mdia", "minf", "stbl", "stsd", "mp4a", "esds"]
        for replacement in [Data([0, 0, 0, 0, 3, 0x80, 0x80, 0x80, 0x80]),
                            Data([0, 0, 0, 0, 3, 127, 0]), zeros(4097)] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(path) { $0.prefix = replacement } }
            refuses(oracle.bytes)
        }
        // Change only the actual ASC byte, keeping parent descriptor sizes valid.
        for config in [UInt64(0x118c), 0x2b88, 0x1180, 0x1208, 0x1190] {
            var oracle = MovieOracle()
            oracle.audioEdit = { track in track.change(path) { box in
                box.put(26, config, width: 2)
            } }
            refuses(oracle.bytes, .format)
        }
        for offset in [4, 6, 7, 10] {
            var oracle = MovieOracle()
            oracle.videoEdit = { track in
                track.change(["mdia", "minf", "stbl", "stsd", "avc1", "avcC"]) { box in
                    box.put(offset, offset == 6 ? 255 : 0, width: 1)
                }
            }
            refuses(oracle.bytes)
        }
    }

    func testConfigurationCapAndConflictingOffsetTables() throws {
        func avcBody(spsBytes: Int) -> Data {
            Data([1, 66, 0, 30, 0xff, 0xe1]) + be(UInt64(spsBytes), 2)
                + Data([0x67]) + zeros(spsBytes - 1) + Data([1, 0, 2, 0x68, 0])
        }
        var oracle = MovieOracle()
        oracle.videoEdit = { track in
            track.change(["mdia", "minf", "stbl", "stsd", "avc1", "avcC"]) { $0.prefix = avcBody(spsBytes: 4083) }
        }
        _ = try VideoImportStructure.inspect(oracle.bytes) // exactly 4096 opaque configuration bytes
        oracle.videoEdit = { track in
            track.change(["mdia", "minf", "stbl", "stsd", "avc1", "avcC"]) { $0.prefix = avcBody(spsBytes: 4084) }
        }
        refuses(oracle.bytes, .format)
        var conflict = MovieOracle()
        conflict.videoEdit = { track in
            track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom("co64", words(0, 1) + be(68, 8))) }
        }
        refuses(conflict.bytes, .malformed)
        for entries in [words(0, 0), words(0, 1, 0), words(0, 1, 2), words(0, 2, 1, 1)] {
            var sync = MovieOracle()
            sync.videoEdit = { track in
                track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom("stss", entries)) }
            }
            refuses(sync.bytes, .malformed)
        }
        var leaf = MovieOracle()
        leaf.videoEdit = { track in
            track.change(["mdia", "minf", "stbl"]) { $0.children.append(Atom("stss", words(0, 1, 1))) }
        }
        _ = try VideoImportStructure.inspect(leaf.bytes)
    }
}
