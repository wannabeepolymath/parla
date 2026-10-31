import Darwin
import Foundation
import XCTest
@testable import ParlaCore

/// Separate app-target author, with literal field offsets and inert visual bytes.
/// Never invokes a production writer/parser to manufacture the input or oracle.
enum PCMMOVConnectionFixture {
    static var samples: [Float] {
        let first: [Float] = [-1,-1.0/32768,0,1.0/32768,32767.0/32768]
        return (0..<8000).map { $0 < 5 ? first[$0] : ($0 % 2 == 0 ? 16000.0 : -16000.0) / 32768 }
    }
    static func bytes(video: UInt8 = 0xa5, tail: UInt8 = 0x7f, silent: Bool = false,
                      moovFirst: Bool = false, split: Bool = true) -> Data {
        func uint(_ value: Int, width: Int = 4) -> Data {
            var out = Data(); for byte in (0..<width).reversed() {out.append(UInt8(truncatingIfNeeded:value >> (byte * 8)))}; return out
        }
        func atom(_ name: String, _ body: Data) -> Data {uint(body.count + 8) + Data(name.utf8) + body}
        func fields(_ count: Int, _ values: [(Int,Int)]) -> Data {
            var body = Data(repeating:0,count:count)
            for (offset,value) in values {body.replaceSubrange(offset..<(offset+4),with:uint(value))}; return body
        }
        func table(_ name: String, _ rows: [[Int]]) -> Data {
            var body = uint(0) + uint(rows.count)
            for row in rows {for value in row {body.append(uint(value))}}; return atom(name,body)
        }
        let matrix = fields(36,[(0,0x10000),(16,0x10000),(32,0x40000000)])
        var pcm = Data()
        let edge = [-32768,-1,0,1,32767]
        for frame in 0..<8000 {
            let word = silent ? 0 : frame < 5 ? edge[frame] : frame % 2 == 0 ? 16000 : -16000
            pcm.append(UInt8(truncatingIfNeeded:word)); pcm.append(UInt8(truncatingIfNeeded:word >> 8))
        }
        let framesPerChunk = split ? 4000 : 8000, count = split ? 2 : 1
        var payload = Data(), audio: [Int] = [], visual: [Int] = []
        for chunk in 0..<count {
            audio.append(payload.count); payload.append(pcm[(chunk*framesPerChunk*2)..<((chunk+1)*framesPerChunk*2)])
            visual.append(payload.count); payload.append(video)
        }
        let ftyp = atom("ftyp",Data("qt  ".utf8) + uint(0) + Data("qt  ".utf8))
        func movie(base: Int) -> Data {
            var mvhd = fields(100,[(12,16000),(16,8000),(20,0x10000),(96,3)])
            mvhd.replaceSubrange(24..<26,with:uint(0x100,width:2)); mvhd.replaceSubrange(36..<72,with:matrix)
            func track(audioTrack: Bool) -> Data {
                var tkhd = fields(84,[(0,3),(12,audioTrack ? 1 : 2),(20,8000)])
                tkhd.replaceSubrange(40..<76,with:matrix)
                if audioTrack {tkhd.replaceSubrange(36..<38,with:uint(0x100,width:2))}
                else {tkhd.replaceSubrange(76..<84,with:uint(16 << 16) + uint(16 << 16))}
                var mdhd = fields(24,[(12,16000),(16,8000)])
                mdhd.replaceSubrange(20..<22,with:uint(0x55c4,width:2))
                var hdlr = Data(repeating:0,count:25); hdlr.replaceSubrange(8..<12,with:Data((audioTrack ? "soun" : "vide").utf8))
                var entry = Data(repeating:0,count:audioTrack ? 28 : 79)
                entry.replaceSubrange(6..<8,with:uint(1,width:2))
                if audioTrack {
                    entry.replaceSubrange(16..<20,with:uint(1,width:2) + uint(16,width:2))
                    entry.replaceSubrange(24..<28,with:uint(0x3e800000))
                } else {
                    entry.replaceSubrange(24..<28,with:uint(16,width:2) + uint(16,width:2)); entry[78] = tail
                }
                let stsd = atom("stsd",uint(0) + uint(1) + atom(audioTrack ? "sowt" : "avc1",entry))
                let stts = table("stts",audioTrack ? [[8000,1]] : [[count,8000/count]])
                let stsz = atom("stsz",uint(0) + uint(audioTrack ? 2 : 1) + uint(audioTrack ? 8000 : count))
                let stsc = table("stsc",[[1,audioTrack ? framesPerChunk : 1,1]])
                let stco = table("stco",(audioTrack ? audio : visual).map { [base + $0] })
                let url = atom("url ",uint(1)), dref = atom("dref",uint(0) + uint(1) + url)
                let header = audioTrack ? atom("smhd",fields(8,[])) : atom("vmhd",fields(12,[(0,1)]))
                let stbl = atom("stbl",stsd + stts + stsz + stsc + stco)
                let minf = atom("minf",header + atom("dinf",dref) + stbl)
                return atom("trak",atom("tkhd",tkhd) + atom("mdia",atom("mdhd",mdhd) + atom("hdlr",hdlr) + minf))
            }
            return atom("moov",atom("mvhd",mvhd) + track(audioTrack:true) + track(audioTrack:false))
        }
        let before = moovFirst ? movie(base:0).count : 0
        let moov = movie(base:ftyp.count + before + 8), mdat = atom("mdat",payload)
        return moovFirst ? ftyp + moov + mdat : ftyp + mdat + moov
    }
    static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to:url); guard chmod(url.path,0o600) == 0 else {throw CocoaError(.fileWriteUnknown)}
    }
}

/// Each test owns its release. An independent global queue fails and releases at
/// five seconds, even if a throwing unwrap skips the normal-path signal.
final class MOVTestHold: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value:0)
    private var released = false, entered = false
    private var watchdog: DispatchWorkItem?
    private let releaseOther: (() -> Void)?
    init(_ name: String, release: (() -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) {
        releaseOther = release
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.finish() else {return}
            XCTFail("Five-second owned hold expired: \(name)",file:file,line:line)
        }
        watchdog = work; DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+5,execute:work)
    }
    private func finish() -> Bool {
        let changed = lock.withLock { if released {return false}; released = true; return true }
        if changed {gate.signal(); releaseOther?()}; return changed
    }
    var hasEntered: Bool {lock.withLock {entered}}
    func wait(entered expectation: XCTestExpectation) {
        lock.withLock {entered = true}; expectation.fulfill(); gate.wait()
    }
    func release() { _ = finish(); watchdog?.cancel() }
    deinit {release()}
}


/// Observe the whole awaited work chain, not merely release of its test latch.
/// On timeout the task/fixture remain owned; the caller must preserve and return.
@MainActor func observeMOVCompletion(_ test: XCTestCase, _ name: String,
                                     file: StaticString = #filePath, line: UInt = #line,
                                     work: @escaping @MainActor () async -> Void) async -> Bool {
    let done = test.expectation(description:name)
    var completed = false
    let observation = Task { @MainActor in
        await work()
        completed = true
        done.fulfill()
    }
    await test.fulfillment(of:[done],timeout:3)
    guard completed else {
        XCTFail("Owned work exit was not observed: \(name). Preserve its fixture and task.",file:file,line:line)
        return false
    }
    // The marker follows the actual chain/drain result. No held work is joined on timeout.
    await observation.value
    return true
}
