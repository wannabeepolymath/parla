import Foundation
import XCTest
@testable import ParlaCore

final class MeetingAudioIngressTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"11111111-1111-1111-1111-%012x",n))! }
    private func make(armed: Bool = true) throws -> MeetingAudioIngress {
        let ingress = MeetingAudioIngress(context:.init(session:id(1),ownerGeneration:3,source:id(2),sourceGeneration:7,segment:id(3),epoch:id(4)))
        if armed { try ingress.reserve(id:id(10),slot:1); try ingress.reserve(id:id(11),slot:2); try ingress.activate() }
        return ingress
    }
    private func receive(_ ingress: MeetingAudioIngress, _ samples: [Float], shape: MeetingAudioIngress.InputShape? = nil) throws -> Int {
        let body = try ingress.enter(); defer { try? ingress.leave(body) }
        return try samples.withUnsafeBufferPointer { try ingress.receive(body,canonical:$0,input:shape ?? .init(rate:16_000,channels:1,frames:samples.count)) }
    }
    private func feed(_ ingress: MeetingAudioIngress, frames: Int, value: Float = 0) throws {
        for offset in stride(from:0,to:frames,by:8_192) {
            let n = min(8_192,frames-offset); XCTAssertEqual(try receive(ingress,Array(repeating:value,count:n)),n)
        }
    }
    private func end(_ ingress: MeetingAudioIngress, tail: [Float] = []) throws -> Bool {
        let drain = ingress.fence()
        return try tail.withUnsafeBufferPointer { try ingress.end(drain,tail:$0) }
    }
    // Independent file oracle: literal canonical header, size fields patched from expected PCM byte length.
    // No production encoder, quantizer, ChunkInput or decoder is called to construct expected bytes.
    private func wav(_ pcm: [UInt8]) -> Data {
        var header: [UInt8] = [82,73,70,70,0,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,
                               128,62,0,0,0,125,0,0,2,0,16,0,100,97,116,97,0,0,0,0]
        for i in 0..<4 { header[4+i] = UInt8(truncatingIfNeeded:(36+pcm.count) >> (i*8)); header[40+i] = UInt8(truncatingIfNeeded:pcm.count >> (i*8)) }
        return Data(header+pcm)
    }
    func testInertPrechargeAndOpaqueForeignReusedHandles() throws {
        let a = try make(armed:false), b = try make()
        XCTAssertEqual(a.facts.rawBytes,0); XCTAssertEqual(a.facts.allocated,0)
        XCTAssertThrowsError(try a.enter()); XCTAssertThrowsError(try a.activate())
        XCTAssertThrowsError(try a.reserve(id:a.context.session,slot:1))
        let permit = try a.reserve(id:id(10),slot:1)
        XCTAssertThrowsError(try a.activate()); XCTAssertThrowsError(try a.reserve(id:id(10),slot:2))
        try a.reserve(id:id(11),slot:2); try a.activate()
        XCTAssertThrowsError(try a.reserve(id:id(12),slot:3)); XCTAssertThrowsError(try a.reserve(id:id(13),slot:241))
        XCTAssertThrowsError(try b.take(permit)); XCTAssertFalse(b.permitAllowed(permit))
        let body = try a.enter()
        XCTAssertThrowsError(try a.enter()); XCTAssertThrowsError(try b.leave(body))
        try a.leave(body); XCTAssertThrowsError(try a.leave(body))
        XCTAssertTrue(try end(a)); XCTAssertTrue(try end(b))
        XCTAssertEqual(a.facts.allocated,2); XCTAssertTrue(a.facts.settled); XCTAssertTrue(a.facts.unknown) // overlapping entry was refused truthfully
        XCTAssertThrowsError(try a.reserve(id:id(12),slot:3)); XCTAssertThrowsError(try a.activate())
        XCTAssertThrowsError(try a.end(a.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0)))
    }
    func testQuantizationIndependentPCMAndFullWAVOracle() throws {
        let ingress = try make()
        let samples: [Float] = [-Float.greatestFiniteMagnitude,-1,-32767.0/32768,-0.5,-Float.ulpOfOne,0,Float.ulpOfOne,0.5,32767.0/32768,1,Float.greatestFiniteMagnitude]
        let pcm: [UInt8] = [0,128,0,128,1,128,0,192,0,0,0,0,0,0,0,64,255,127,255,127,255,127]
        XCTAssertEqual(try receive(ingress,samples),samples.count); XCTAssertTrue(try end(ingress))
        let permit = try XCTUnwrap(ingress.readyPermit), delivery = try ingress.take(permit)
        XCTAssertEqual(delivery.bytes,wav(pcm)); XCTAssertEqual(delivery.frames,11); XCTAssertEqual(delivery.start,0)
        XCTAssertTrue(ingress.permitAllowed(permit)); XCTAssertThrowsError(try ingress.take(permit))
        try ingress.retire(permit); XCTAssertThrowsError(try ingress.retire(permit)); XCTAssertFalse(ingress.permitAllowed(permit))
        XCTAssertEqual(ingress.facts.copies,1); XCTAssertEqual(ingress.facts.snapshotBytes,0); XCTAssertTrue(ingress.facts.settled)
    }
    func testConcatenatedIndependentPCMOracleAcrossEverySplitAndEOS() throws {
        for split in [1,6_399,6_400,8_191] {
            let ingress = try make(), pattern: [Float] = [-1,0.5,0,1], words: [[UInt8]] = [[0,128],[0,64],[0,0],[255,127]]
            let total = 480_003
            for offset in stride(from:0,to:total,by:split) {
                let input = (offset..<min(offset+split,total)).map { pattern[$0 % 4] }
                XCTAssertEqual(try receive(ingress,input),input.count)
            }
            let first = try ingress.take(XCTUnwrap(ingress.readyPermit))
            XCTAssertEqual(first.frames,480_000); XCTAssertEqual(first.sequence,0)
            let expectedFirst = (0..<480_000).flatMap { words[$0 % 4] }
            XCTAssertEqual(first.bytes,wav(expectedFirst)); try ingress.retire(first.permit)
            XCTAssertTrue(try end(ingress,tail:[-0.5,1]))
            let last = try ingress.take(XCTUnwrap(ingress.readyPermit))
            XCTAssertEqual(last.start,480_000); XCTAssertEqual(last.sequence,1); XCTAssertEqual(last.frames,5)
            let expectedTail: [UInt8] = (480_000..<total).flatMap { words[$0 % 4] }+[0,192,255,127]
            XCTAssertEqual(last.bytes,wav(expectedTail))
            var concatenated = Data(first.bytes.dropFirst(44)); concatenated.append(last.bytes.dropFirst(44))
            XCTAssertEqual(concatenated,Data(expectedFirst+expectedTail))
            try ingress.retire(last.permit); XCTAssertTrue(ingress.facts.settled); XCTAssertFalse(ingress.facts.unknown)
        }
    }
    func testExactFrameEdgesAndEmptyRetirement() throws {
        for frames in [0,1,6_399,6_400,479_999,480_000] {
            let ingress = try make(); XCTAssertEqual(try receive(ingress,[]),0)
            try feed(ingress,frames:frames); XCTAssertTrue(try end(ingress))
            if frames == 0 { XCTAssertNil(ingress.readyPermit); XCTAssertEqual(ingress.facts.copies,0) }
            else {
                let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit))
                XCTAssertEqual(delivery.frames,UInt64(frames)); XCTAssertEqual(delivery.bytes,wav(Array(repeating:0,count:frames*2)))
                try ingress.retire(delivery.permit)
            }
            XCTAssertTrue(ingress.facts.settled); XCTAssertFalse(ingress.facts.unknown); XCTAssertEqual(ingress.facts.allocated,2)
        }
    }
    func testNonfiniteOversizeAndFormatRefuseBeforeCopyPreservingPrefix() throws {
        for invalid in [[Float.nan],[Float.infinity],[-Float.infinity],Array(repeating:0,count:32_769)] {
            let ingress = try make(); XCTAssertEqual(try receive(ingress,[0.5]),1)
            XCTAssertThrowsError(try receive(ingress,invalid,shape:.init(rate:16_000,channels:1,frames:8_192)))
            XCTAssertFalse(ingress.facts.open); XCTAssertTrue(ingress.facts.unknown); XCTAssertEqual(ingress.facts.accepted,1)
            XCTAssertTrue(try end(ingress)); let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit))
            XCTAssertEqual(delivery.bytes,wav([0,64])); try ingress.retire(delivery.permit)
        }
        for shape in [MeetingAudioIngress.InputShape(rate:.nan,channels:1,frames:1),.init(rate:.infinity,channels:1,frames:1),
                      .init(rate:7_999,channels:1,frames:1),.init(rate:192_001,channels:1,frames:1),.init(rate:44_100.5,channels:1,frames:1),
                      .init(rate:16_000,channels:0,frames:1),.init(rate:16_000,channels:3,frames:1),.init(rate:16_000,channels:1,frames:8_193),
                      .init(rate:16_000,channels:1,frames:-1),.init(rate:16_000,channels:1,frames:0)] {
            let ingress = try make(); XCTAssertThrowsError(try receive(ingress,[0],shape:shape)); XCTAssertEqual(ingress.facts.accepted,0)
            XCTAssertTrue(try end(ingress)); XCTAssertTrue(ingress.facts.settled)
        }
        for rate in [8_000.0,192_000.0] {
            let ingress = try make(); XCTAssertEqual(try receive(ingress,[0],shape:.init(rate:rate,channels:2,frames:1)),1)
            XCTAssertTrue(try end(ingress)); let d = try ingress.take(XCTUnwrap(ingress.readyPermit)); try ingress.retire(d.permit)
        }
    }
    func testEOSCapacityNonfiniteAndOneShotDrainIdentity() throws {
        for tail in [[Float.nan],Array(repeating:Float(0),count:32_769),[0,0]] {
            let ingress = try make(); try feed(ingress,frames:479_999)
            XCTAssertFalse(try end(ingress,tail:tail)); XCTAssertTrue(ingress.facts.unknown); XCTAssertEqual(ingress.facts.accepted,479_999)
            let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit)); XCTAssertEqual(delivery.frames,479_999); try ingress.retire(delivery.permit)
        }
        let maximum = try make()
        XCTAssertEqual(try receive(maximum,Array(repeating:0,count:32_768),shape:.init(rate:8_000,channels:2,frames:8_192)),32_768)
        XCTAssertTrue(try end(maximum,tail:Array(repeating:0,count:32_768)))
        let maximumDelivery = try maximum.take(XCTUnwrap(maximum.readyPermit))
        XCTAssertEqual(maximumDelivery.frames,65_536); try maximum.retire(maximumDelivery.permit)
        let unused = try make()
        XCTAssertFalse(try end(unused,tail:[1])); XCTAssertTrue(unused.facts.unknown); XCTAssertTrue(unused.facts.settled)
        let a = try make(), b = try make(), foreign = b.fence()
        a.fence()
        XCTAssertThrowsError(try a.end(foreign,tail:UnsafeBufferPointer<Float>(start:nil,count:0)))
        XCTAssertFalse(a.facts.ended); XCTAssertTrue(try end(a)); XCTAssertTrue(try end(b))
        let boundary = try make(); try feed(boundary,frames:479_999)
        XCTAssertTrue(try end(boundary,tail:[1])); let d = try boundary.take(XCTUnwrap(boundary.readyPermit))
        XCTAssertEqual(d.frames,480_000); XCTAssertEqual(d.bytes.suffix(2),Data([255,127])); try boundary.retire(d.permit)
    }
    func testTwoBufferPressureAndRevokedWritingPermit() throws {
        let ingress = try make(); try feed(ingress,frames:480_000)
        let first = try ingress.take(XCTUnwrap(ingress.readyPermit))
        try feed(ingress,frames:479_999)
        XCTAssertEqual(try receive(ingress,[0.5,1]),1) // one accepted prefix frame, one unknown frame
        XCTAssertFalse(ingress.facts.open); XCTAssertTrue(ingress.facts.unknown); XCTAssertEqual(ingress.facts.slots,2)
        XCTAssertEqual(ingress.facts.rawBytes,1_920_088); XCTAssertEqual(ingress.facts.snapshotBytes,960_044)
        XCTAssertLessThanOrEqual(ingress.facts.rawBytes+ingress.facts.snapshotBytes+131_072+65_536,4_194_304)
        XCTAssertThrowsError(try ingress.reserve(id:id(12),slot:3)); XCTAssertTrue(try end(ingress))
        try ingress.retire(first.permit)
        let second = try ingress.take(XCTUnwrap(ingress.readyPermit)); XCTAssertEqual(second.frames,480_000)
        XCTAssertEqual(second.start,480_000); XCTAssertEqual(second.bytes.suffix(2),Data([0,64]))
        XCTAssertTrue(ingress.permitAllowed(second.permit)); ingress.revoke(); XCTAssertFalse(ingress.permitAllowed(second.permit))
        XCTAssertEqual(ingress.facts.slots,1); try ingress.retire(second.permit); XCTAssertTrue(ingress.facts.settled)
    }
    func testFenceRejectsLateBodyAndRequiresActualLeaveBeforeEnd() throws {
        let ingress = try make(), body = try ingress.enter(), drain = ingress.fence()
        XCTAssertThrowsError(try ingress.enter())
        let n = try [Float(1)].withUnsafeBufferPointer { try ingress.receive(body,canonical:$0,input:.init(rate:16_000,channels:1,frames:1)) }
        XCTAssertEqual(n,0); XCTAssertEqual(ingress.facts.accepted,0)
        XCTAssertThrowsError(try ingress.end(drain,tail:UnsafeBufferPointer<Float>(start:nil,count:0)))
        XCTAssertFalse(ingress.facts.producerFinished); try ingress.leave(body)
        XCTAssertTrue(try ingress.end(drain,tail:UnsafeBufferPointer<Float>(start:nil,count:0))); XCTAssertTrue(ingress.facts.settled)
    }
    func testFrameCeilingIsRetainedSampleCountAndNeverTiming() throws {
        let ingress = try make()
        for index in 0..<120 {
            try feed(ingress,frames:480_000)
            let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit))
            XCTAssertEqual(delivery.start,UInt64(index)*480_000); try ingress.retire(delivery.permit)
            if ingress.facts.open { try ingress.reserve(id:id(100+index),slot:ingress.facts.allocated+1) }
        }
        XCTAssertEqual(ingress.facts.accepted,57_600_000); XCTAssertFalse(ingress.facts.open)
        XCTAssertEqual(ingress.facts.reason,.frameCeiling); XCTAssertFalse(ingress.facts.unknown)
        XCTAssertTrue(try end(ingress)); XCTAssertTrue(ingress.facts.settled)
    }
    func testExplicitUnknownEmptyClosureSealsLiteralPrefixWithoutInventingTail() throws {
        let ingress = try make()
        XCTAssertEqual(try receive(ingress,[-1,0.5]),2)
        XCTAssertTrue(try ingress.end(ingress.fence(),tail:.init(start:nil,count:0),closure:.unknown(.unknownCoverage)))
        XCTAssertTrue(ingress.facts.ended); XCTAssertTrue(ingress.facts.unknown)
        XCTAssertEqual(ingress.facts.reason,.unknownCoverage)
        let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit))
        XCTAssertEqual(delivery.bytes,wav([0,128,0,64])); try ingress.retire(delivery.permit)
        XCTAssertTrue(ingress.facts.settled)
        XCTAssertThrowsError(try ingress.end(ingress.fence(),tail:.init(start:nil,count:0),closure:.complete))
    }
    func testExplicitClosureChecksForeignTokenBodyOneShotAndRevokedWriter() throws {
        let a = try make(), b = try make(), body = try a.enter(), token = a.fence()
        XCTAssertThrowsError(try a.end(b.fence(),tail:.init(start:nil,count:0),closure:.unknown(.invalidTail)))
        XCTAssertThrowsError(try a.end(token,tail:.init(start:nil,count:0),closure:.unknown(.invalidTail)))
        XCTAssertFalse(a.facts.ended); XCTAssertFalse(a.facts.unknown); XCTAssertNil(a.facts.reason)
        try a.leave(body)
        XCTAssertTrue(try a.end(token,tail:.init(start:nil,count:0),closure:.complete))
        XCTAssertThrowsError(try a.end(token,tail:.init(start:nil,count:0),closure:.unknown(.invalidTail)))
        XCTAssertFalse(a.facts.unknown); XCTAssertNil(a.facts.reason)
        let revoked = try make(); try feed(revoked,frames:480_000)
        let writing = try revoked.take(XCTUnwrap(revoked.readyPermit)); revoked.revoke()
        XCTAssertFalse(try revoked.end(revoked.fence(),tail:.init(start:nil,count:0),closure:.unknown(.unknownCoverage)))
        XCTAssertFalse(revoked.permitAllowed(writing.permit)); XCTAssertEqual(revoked.facts.slots,1)
        XCTAssertTrue(revoked.facts.unknown); try revoked.retire(writing.permit)
        XCTAssertTrue(revoked.facts.settled); XCTAssertTrue(try end(b))
    }

}
