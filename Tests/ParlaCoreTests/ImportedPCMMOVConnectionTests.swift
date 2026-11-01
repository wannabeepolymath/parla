import Foundation
import XCTest
@testable import ParlaCore

/// Authored inert container bytes; never a production parser/writer or media export oracle.
enum ConnectedMOVBytes {
    static let literal: [Float] = [-1, -1.0 / 32768, 0, 1.0 / 32768, 32767.0 / 32768]
    static func expected(frames: Int = 8000, silent: Bool = false) -> [Float] {
        (0..<frames).map { i in silent ? 0 : i < 5 ? literal[i] : Float(i % 2 == 0 ? 16000 : -16000) / 32768 }
    }
    static func make(frames: Int = 8000, first: Bool = false, split: Bool = false,
                     video: UInt8 = 0xa5, tail: UInt8 = 0x7f, silent: Bool = false) -> Data {
        func be(_ v: Int, _ n: Int = 4) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * (n - $0 - 1))) }) }
        func words(_ v: Int...) -> Data { v.reduce(into: Data()) { $0.append(be($1)) } }
        func zero(_ n: Int) -> Data { Data(repeating: 0, count: n) }
        func box(_ tag: String, _ data: Data) -> Data { be(data.count + 8) + Data(tag.utf8) + data }
        let matrix = words(0x10000,0,0,0,0x10000,0,0,0,0x40000000)
        var pcm = Data()
        let edge = [-32768,-1,0,1,32767]
        for i in 0..<frames {
            let v = silent ? 0 : i < 5 ? edge[i] : i % 2 == 0 ? 16000 : -16000
            pcm.append(UInt8(truncatingIfNeeded: v)); pcm.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        let chunks = split ? [frames / 2,frames - frames / 2] : [frames]
        var payload = Data(), offsets: [Int] = [], visuals: [Int] = [], cursor = 0
        for count in chunks {
            offsets.append(payload.count); payload.append(pcm[(cursor * 2)..<((cursor + count) * 2)]); cursor += count
            visuals.append(payload.count); payload.append(video)
        }
        let brand = box("ftyp",Data("qt  ".utf8) + words(0) + Data("qt  ".utf8))
        func movie(_ base: Int) -> Data {
            func track(_ audio: Bool) -> Data {
                let tk = words(3,0,0,audio ? 1 : 2,0,frames) + zero(12) + be(audio ? 0x100 : 0,2) + be(0,2)
                let tkhd = box("tkhd",tk + matrix + words(audio ? 0 : 16 << 16,audio ? 0 : 16 << 16))
                let mdhd = box("mdhd",words(0,0,0,16000,frames) + be(0x55c4,2) + be(0,2))
                let hdlr = box("hdlr",words(0,0) + Data((audio ? "soun" : "vide").utf8) + zero(12) + Data([0]))
                let entry: Data
                if audio { entry = box("sowt",zero(6) + be(1,2) + zero(8) + be(1,2) + be(16,2) + words(0,0x3e800000)) }
                else { entry = box("avc1",zero(6) + be(1,2) + zero(16) + be(16,2) + be(16,2) + zero(50) + Data([tail])) }
                let stsd = box("stsd",words(0,1) + entry)
                let stts = audio ? box("stts",words(0,1,frames,1)) : box("stts",words(0,1,chunks.count,frames / chunks.count))
                let stsz = box("stsz",words(0,audio ? 2 : 1,audio ? frames : chunks.count))
                let stsc = box("stsc",words(0,1,1,audio ? chunks[0] : 1,1))
                let positions = audio ? offsets : visuals
                let stco = box("stco",words(0,positions.count) + positions.reduce(into: Data()) { $0.append(be(base + $1)) })
                let dinf = box("dinf",box("dref",words(0,1) + box("url ",words(1))))
                let header = audio ? box("smhd",words(0,0)) : box("vmhd",words(1,0,0))
                let minf = box("minf",header + dinf + box("stbl",stsd + stts + stsz + stsc + stco))
                return box("trak",tkhd + box("mdia",mdhd + hdlr + minf))
            }
            let mvhd = box("mvhd",words(0,0,0,16000,frames,0x10000) + be(0x100,2) + zero(10) + matrix + zero(24) + be(3))
            return box("moov",mvhd + track(true) + track(false))
        }
        let prefix = first ? movie(0).count : 0
        let moov = movie(brand.count + prefix + 8), mdat = box("mdat",payload)
        return first ? brand + moov + mdat : brand + mdat + moov
    }
}

final class ImportedPCMMOVConnectionTests: XCTestCase {
    func testConnectedMOVDispatchExactSustainedSamplesAndLazyFactory() throws {
        var values = 0, converters = 0
        let lazy: () -> ImportedAudio.Native = {
            values += 1; var native = ImportedAudio.Native()
            native.make = { _,_ in converters += 1; XCTFail("Converter must never be constructed"); return nil }
            return native
        }
        for first in [false,true] { for split in [false,true] {
            let bytes = ConnectedMOVBytes.make(first:first,split:split)
            let prefixed = Data([91,92,93]) + bytes
            let decoded = try ImportedAudio.decodeSource(prefixed.dropFirst(3),format:.mov,makeNative:lazy)
            XCTAssertEqual(decoded.samples,ConnectedMOVBytes.expected())
            let facts = decoded.transientSourceInfo
            XCTAssertEqual(facts.profile,.qtPCM16kV1); XCTAssertEqual(facts.origin,.directMOVPCM16k)
            XCTAssertEqual(facts.container,"QuickTime MOV"); XCTAssertEqual(facts.encoding,"signed16LE")
            XCTAssertEqual(facts.sourceRate,16000); XCTAssertEqual(facts.sourceChannels,1)
            XCTAssertEqual(facts.sourceFrames,8000); XCTAssertEqual(facts.outputFrames,8000)
            XCTAssertEqual(facts.outputRate,16000); XCTAssertEqual(facts.clippedSamples,0)
        } }
        XCTAssertEqual(values,0); XCTAssertEqual(converters,0)
        let wav = savedFixtureWAV(), old = try ImportedAudio.decode(wav)
        let wavDecoded = try ImportedAudio.decodeSource(wav,format:.wav,makeNative:lazy)
        XCTAssertEqual(values,1); XCTAssertEqual(converters,0)
        XCTAssertEqual(wavDecoded.samples,old.samples); XCTAssertEqual(wavDecoded.samples,try ImportedWAV.decode(wav))
        XCTAssertEqual(wavDecoded.transientSourceInfo,.wav(old.transientSourceInfo))
    }
    func testConnectedMOVDispatchRefusesRenamingMalformedAndCancellationWithoutNative() throws {
        var values = 0
        let lazy: () -> ImportedAudio.Native = { values += 1; return ImportedAudio.Native() }
        let mov = ConnectedMOVBytes.make()
        var badBrand = mov; badBrand.replaceSubrange(8..<12,with:Data("isom".utf8))
        var badAudio = mov
        let sowt = try XCTUnwrap(badAudio.range(of:Data("sowt".utf8)))
        badAudio.replaceSubrange(sowt,with:Data("mp4a".utf8))
        for bytes in [savedFixtureWAV(),Data(mov.dropLast()),mov + Data([0]),badBrand,badAudio,ConnectedMOVBytes.make(frames:6399),Data(repeating:0,count:20_971_521)] {
            XCTAssertThrowsError(try ImportedAudio.decodeSource(bytes,format:.mov,makeNative:lazy))
        }
        XCTAssertEqual(values,0)
        XCTAssertThrowsError(try ImportedAudio.decodeSource(mov,format:.mov,canceled:{true},makeNative:lazy)) { XCTAssertEqual($0 as? ImportedPCMMOV.Failure,.canceled) }
        XCTAssertEqual(values,0)
        // WAV evaluates its value factory, but never falls back to MOV.
        XCTAssertThrowsError(try ImportedAudio.decodeSource(mov,format:.wav,makeNative:lazy))
        XCTAssertEqual(values,1)
    }
    func testConnectedMOVDispatchWholeSourceMutationAndCancellationDuringExtraction() throws {
        let a = ConnectedMOVBytes.make(video:0xa5,tail:0x7f), b = ConnectedMOVBytes.make(video:0x5a,tail:0x33)
        XCTAssertNotEqual(a,b); XCTAssertNotEqual(SavedAudioImportStorage.digest(a),SavedAudioImportStorage.digest(b))
        XCTAssertEqual(try ImportedAudio.decodeSource(a,format:.mov).samples,ConnectedMOVBytes.expected())
        XCTAssertEqual(try ImportedAudio.decodeSource(b,format:.mov).samples,ConnectedMOVBytes.expected())
        let inspection = try ImportedPCMMOV.inspect(a)
        var checks = 0
        _ = try inspection.decode(canceled:{checks += 1; return false})
        XCTAssertGreaterThan(checks,3)
        // Fixed entry, after reserve, first chunk and scalar-block cancellation cuts.
        for cut in [1,2,3,4] {
            var calls = 0
            XCTAssertThrowsError(try inspection.decode(canceled:{calls += 1; return calls == cut})) { XCTAssertEqual($0 as? ImportedPCMMOV.Failure,.canceled) }
            XCTAssertEqual(calls,cut)
        }
    }
    func testProfileMOVDispatchCompleteLiteralSamplesWithoutNativeConstruction() throws {
        var values = 0, converters = 0
        let lazy: () -> ImportedAudio.Native = {
            values += 1
            var native = ImportedAudio.Native()
            native.make = { _, _ in converters += 1; XCTFail("MOV must never construct a converter"); return nil }
            return native
        }
        let bytes = ProfileMOVBytes.make(), prefixed = Data([0xee, 0xff]) + bytes
        let result = try ImportedAudio.decodeSource(prefixed.dropFirst(2), format: .mov, makeNative: lazy)
        XCTAssertEqual(result.samples, ProfileMOVBytes.expected)
        let facts = result.transientSourceInfo
        XCTAssertEqual(facts.profile, .qtPCM16kV1); XCTAssertEqual(facts.origin, .directMOVPCM16k)
        XCTAssertEqual(facts.encoding, "signed16LE"); XCTAssertEqual(facts.sourceRate, 16_000)
        XCTAssertEqual(facts.sourceChannels, 1); XCTAssertEqual(facts.sourceFrames, 6_400)
        XCTAssertEqual(facts.outputFrames, 6_400); XCTAssertEqual(facts.outputRate, 16_000)
        XCTAssertEqual(facts.clippedSamples, 0)
        XCTAssertEqual(values, 0); XCTAssertEqual(converters, 0)
        for refused in [ProfileMOVBytes.make(valid: false), Data(bytes.dropLast())] {
            XCTAssertThrowsError(try ImportedAudio.decodeSource(refused, format: .mov, makeNative: lazy))
        }
        var checkpoints = 0
        _ = try ImportedAudio.decodeSource(bytes, format: .mov, canceled: { checkpoints += 1; return false }, makeNative: lazy)
        for stop in 1...checkpoints {
            var calls = 0
            XCTAssertThrowsError(try ImportedAudio.decodeSource(bytes, format: .mov,
                                                               canceled: { calls += 1; return calls == stop }, makeNative: lazy)) {
                XCTAssertEqual($0 as? ImportedPCMMOV.Failure, .canceled)
            }
        }
        XCTAssertEqual(values, 0); XCTAssertEqual(converters, 0)
    }

}
