import Foundation
import XCTest
@testable import ParlaCore

func meetingID(_ n: UInt64) -> UUID {
    let raw = String(format:"%032llx",n), a = Array(raw)
    return UUID(uuidString:String(a[0..<8])+"-"+String(a[8..<12])+"-"+String(a[12..<16])+"-"+String(a[16..<20])+"-"+String(a[20..<32]))!
}
func meetingProvenance(_ n: UInt64, role: MeetingSession.Provenance.Role, wide: Bool = false) throws -> MeetingSession.Provenance {
    let caps = [128,64,128,32,96,128,128,96,128], text = caps.map { wide ? String(repeating:"\"",count:$0) : "" }
    let member: MeetingSession.Member?
    if wide { member = try .init(meeting:.array([.n(Int32.min),.n(UInt64.max-n),.n(Int64.max),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(3_221_225_471)]),cap:Int64.max) } else { member = nil }
    let digest = wide ? String(repeating:"f",count:64) : ""
    return try .init(id:meetingID(10_000+n),generation:wide ? UInt64.max-10_000 : 1,role:role,engine:.unknown,artifact:.unknown,
        catalogID:text[0],language:text[1],model:text[2],filter:text[3],nativeVersion:text[4],buildScope:text[5],systemScope:text[6],verification:text[7],computeScope:text[8],
        digest:digest,helperDigest:digest,releaseDigest:digest,sdkRevision:digest,modelRevision:digest,expectedBytes:wide ? .max : 0,fileGeneration:member,adapter:wide ? 1_000_000 : 0,compute:wide ? 1_000_000 : 0,hints:false)
}
func meetingWidthLedger(extraRetired: Bool = false) throws -> MeetingSession.Ledger {
    typealias M = MeetingSession
    let session = meetingID(2), revision = UInt64.max-10_000, admitted = Int64.max-M.lifetime
    func member(_ n: Int, _ bytes: Int) throws -> M.Member {
        try .init(meeting:.array([.n(Int32.min),.n(UInt64.max-UInt64(n)),.n(bytes),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(3_221_225_471)]),cap:Int64.max)
    }
    var chunks: [M.Chunk] = [], segments: [M.Segment] = [], gaps: [M.Gap] = []
    let hash = String(repeating:"f",count:64)
    for n in 0..<240 {
        let t = n%2, timing = M.Timing(pts:Int64.max-480_000_000_000,denominator:1_000_000,sample:UInt64.max-480_000,rate:16_000,epoch:meetingID(UInt64(50_000+n)),mapping:.unknown)
        let id = meetingID(UInt64(40_000+n)), generation = UInt64.max-UInt64(20_000+n), attemptGeneration = UInt64.max-UInt64(30_000+n)
        let attempt = M.allocation(session,role:.attempt,generation:attemptGeneration)
        let resultBytes = n < 89 ? 10_000 : 1000
        let result = try M.Result(id:M.allocation(session,role:.result,generation:generation),generation:generation,attempt:attempt,source:id,sourceGeneration:revision,sourceHash:hash,bytes:resultBytes,hash:hash,member:member(20_000+n,resultBytes),requested:30,observed:31,created:admitted)
        chunks.append(try .init(id:id,generation:revision,track:t,sourceGeneration:revision,segment:n,sequence:UInt64.max-10_000+UInt64(n/2),start:UInt64(n/2)*480_000,frames:480_000,bytes:960_044,hash:hash,timing:timing,member:member(40_000+n,960_044),stage:.sealed,accepted:result,attempt:.init(id:attempt,generation:attemptGeneration,requested:30,state:.completed)))
        segments.append(.init(id:meetingID(UInt64(70_000+n)),track:t,generation:revision,timing:timing,canonicalStart:UInt64(n/2)*480_000))
        // Separate generation-bound unknown gap records use earlier adjacent sequence values in a distinct width-only ledger below.
    }
    let tracks = (0..<2).map { t in M.Track(selection:.init(instance:meetingID(UInt64(3+t)),kind:t == 0 ? .microphone : .selectedApplication,label:String(repeating:"\"",count:128),generation:revision),epoch:segments[238+t].timing.epoch,captured:M.maximumTrackFrames,sequence:UInt64.max-10_000+120,segment:238+t) }
    var provenance: [M.Provenance] = []
    for n in 0..<32 { provenance.append(try meetingProvenance(UInt64(n),role:n%2 == 0 ? .requested : .observed,wide:true)) }
    let extraGeneration = UInt64.max-15_000, newAttemptGeneration = UInt64.max-16_000
    let newAttempt = M.allocation(session,role:.attempt,generation:newAttemptGeneration)
    if !extraRetired { chunks[0].attempt = .init(id:newAttempt,generation:newAttemptGeneration,requested:30,state:.pending) }
    let r = try M.Result(id:M.allocation(session,role:.result,generation:extraGeneration),generation:extraGeneration,attempt:extraRetired ? chunks[0].accepted!.attempt : newAttempt,source:chunks[0].id,sourceGeneration:revision,sourceHash:hash,bytes:10_000,hash:hash,member:member(90_000,10_000),requested:30,observed:31,created:admitted)
    let authorityGeneration = extraRetired ? chunks[0].accepted!.generation : r.generation
    let extra = M.Extra(kind:extraRetired ? .retired : .candidate,chunk:0,result:r,stage:extraRetired ? 3 : 2,authority:M.allocation(session,role:.retirement,generation:authorityGeneration))
    // Reserve disjoint sequence positions for all 240 gaps without inventing their extent.
    for n in chunks.indices {
        let c = chunks[n], sequence = UInt64.max-10_000+UInt64((n/2)*2)
        chunks[n] = .init(id:c.id,generation:c.generation,track:c.track,sourceGeneration:c.sourceGeneration,segment:c.segment,sequence:sequence,start:c.start,frames:c.frames,bytes:c.bytes,hash:c.hash,timing:c.timing,member:c.member,stage:c.stage,accepted:c.accepted,attempt:c.attempt)
        gaps.append(.init(id:meetingID(UInt64(80_000+n)),track:c.track,segment:c.segment,sequence:sequence+1,kind:.unknown,start:Int64.max-480_000_000_000,startDenominator:1_000_000,extent:0,extentDenominator:1_000_000))
    }
    let advanced = tracks.map { M.Track(selection:$0.selection,epoch:$0.epoch,captured:$0.captured,sequence:UInt64.max-10_000+240,segment:$0.segment) }
    return .init(owner:meetingID(1),session:session,root:.init(device:.min,inode:.max),admitted:admitted,expires:.max,revision:revision,clock:Int64.max-1,state:.active,tracks:advanced,segments:segments,gaps:gaps,provenance:provenance,chunks:chunks,extra:extra,terminal:nil,deletion:nil)
}
final class MeetingSessionTests: XCTestCase {
    func testCanonicalWidthTiersAndDeletionReserveAreActualSwiftBodies() throws {
        for retired in [false,true] {
            var l = try meetingWidthLedger(extraRetired:retired)
            let ordinary = try l.encoded(tier:MeetingSession.ordinaryBytes)
            XCTAssertLessThanOrEqual(ordinary.count,MeetingSession.ordinaryBytes)
            XCTAssertEqual(try MeetingSession.Ledger.decode(ordinary),l)
            l.terminal = .init(reason:.unknownCoverage,mask:3,generation:.max,frames:[57_600_000,57_600_000],epoch:.max,flags:65_535,errors:Array(repeating:.unknownCoverage,count:16)); l.state = .interrupted
            XCTAssertLessThanOrEqual(try l.encoded(tier:MeetingSession.terminalBytes).count,MeetingSession.terminalBytes)
            let member = try MeetingSession.Member(meeting:.array([.n(Int32.min),.n(UInt64.max),.n(432),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(Int64.min),.n(999_999_999),.n(0)]),cap:4096)
            l.deletion = .init(id:meetingID(90_001),freeze:l.revision-1,digest:l.targetDigest,count:481,member:member,sources:l.sourceDigest,cursor:481,phase:2); l.state = .deleting
            let bytes = try l.encoded(tier:MeetingSession.deletionBytes)
            XCTAssertEqual(try MeetingSession.Ledger.decode(bytes),l)
            XCTAssertLessThanOrEqual(bytes.count,MeetingSession.deletionBytes)
        }
    }
    func testDuplicateUnknownNoncanonicalTypesAndUTF8RefuseBeforeAuthority() throws {
        let valid = try meetingWidthLedger().encoded(tier:MeetingSession.ordinaryBytes)
        var attacks: [Data] = [Data([0xef,0xbb,0xbf])+valid,valid+Data([10]),Data([0xff]),Data("{\"d\":\"parla.meeting.1\",\"d\":\"parla.meeting.1\"}".utf8)]
        let text = String(decoding:valid,as:UTF8.self)
        attacks += [Data(text.replacingOccurrences(of:"\"v\":1",with:"\"v\":true").utf8),Data(text.replacingOccurrences(of:"\"v\":1",with:"\"v\":1.0").utf8),Data(text.replacingOccurrences(of:"\"v\":1",with:"\"v\":01").utf8),Data(text.replacingOccurrences(of:"\"v\":1",with:"\"v\":1,\"unknown\":[]").utf8)]
        for bytes in attacks { XCTAssertThrowsError(try MeetingSession.Ledger.decode(bytes)) }
        XCTAssertThrowsError(try MeetingJSON.parse(Data(repeating:32,count:524_289),cap:524_288))
        XCTAssertThrowsError(try MeetingJSON.parse(.init(repeating:32,count:524_288),cap:524_288).list())
    }
    func testExactEncodedCapsAndScalarDomains() throws {
        let j = MeetingJSON.string(String(repeating:"x",count:524_286))
        XCTAssertEqual(try j.encoded(cap:524_288).count,524_288)
        XCTAssertThrowsError(try j.encoded(cap:524_287))
        XCTAssertThrowsError(try MeetingSession.text("\u{0000}",cap:128))
        XCTAssertThrowsError(try MeetingSession.text(String(repeating:"é",count:65),cap:128))
        for x in [Double.nan,.infinity,-1,Double(Int64.max)] { XCTAssertThrowsError(try MeetingSession.nanoseconds(seconds:x)) }
        XCTAssertThrowsError(try MeetingSession.add(UInt64.max,1)); XCTAssertThrowsError(try MeetingSession.add(Int64.max,1))
        let t = MeetingSession.Timing(pts:.max,denominator:1_000_000,sample:.max,rate:16_000,epoch:meetingID(1),mapping:.validated)
        XCTAssertThrowsError(try t.end(after:480_000))
        XCTAssertEqual(MeetingSession.reservation,232_581_440); XCTAssertEqual(MeetingSession.quota-MeetingSession.reservation,35_854_016)
    }
    func testRetiredAllocationIDsCannotReappearAfterColdMetadata() throws {
        let session = meetingID(2)
        for role in [MeetingSession.AllocationRole.attempt,.result,.retirement] {
            let old = MeetingSession.allocation(session,role:role,generation:10), new = MeetingSession.allocation(session,role:role,generation:11)
            XCTAssertNotEqual(old,new); XCTAssertTrue(MeetingSession.reserved(old,session:session)); XCTAssertEqual(MeetingSession.allocatedGeneration(old,session:session,role:role),10)
        }
        var l = try meetingWidthLedger(); l.chunks[0].attempt = .init(id:meetingID(700),generation:1,requested:30,state:.pending)
        XCTAssertThrowsError(try l.encoded(tier:MeetingSession.ordinaryBytes))
    }
}

// Small metadata-only timing witnesses; Members describe no real filesystem fixture.
private struct MeetingTimingFixture {
    typealias M = MeetingSession
    var ledger: M.Ledger
    init() {
        let epoch = meetingID(200)
        let selections = (0..<2).map { M.Selection(instance:meetingID(UInt64(3+$0)),kind:$0 == 0 ? .microphone : .selectedApplication,label:"",generation:7) }
        let segments = (0..<2).map { M.Segment(id:meetingID(UInt64(100+$0)),track:$0,generation:7,timing:.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.validated),canonicalStart:0) }
        let tracks = selections.enumerated().map { M.Track(selection:$0.element,epoch:epoch,captured:0,sequence:0,segment:$0.offset) }
        ledger = .init(owner:meetingID(1),session:meetingID(2),root:.init(device:1,inode:1),admitted:0,expires:M.lifetime,revision:10,clock:0,state:.active,tracks:tracks,segments:segments,gaps:[],provenance:[],chunks:[],extra:nil,terminal:nil,deletion:nil)
    }
    mutating func segment(track: Int = 0, epoch: UUID = meetingID(200), mapping: M.Mapping = .validated, rate: UInt64 = 16_000) {
        ledger.segments.append(.init(id:meetingID(UInt64(100+ledger.segments.count)),track:track,generation:7,timing:.init(pts:0,denominator:1,sample:0,rate:rate,epoch:epoch,mapping:mapping),canonicalStart:ledger.tracks[track].captured))
        ledger.tracks[track].segment = ledger.segments.count-1; ledger.tracks[track].epoch = epoch
    }
    mutating func chunk(sample: UInt64, pts: Int64, denominator: UInt64 = 16_000, frames: UInt64 = 8000, track: Int = 0) throws {
        let t = ledger.tracks[track], s = ledger.segments[t.segment], bytes = Int(44+frames*2)
        let member = try M.Member(meeting:.array([.n(1),.n(1000+ledger.chunks.count),.n(bytes),.n(0),.n(0),.n(0),.n(0),.n(0),.n(0),.n(0)]),cap:Int64(M.sourceBytes))
        ledger.chunks.append(.init(id:meetingID(UInt64(1000+ledger.chunks.count)),generation:1,track:track,sourceGeneration:7,segment:t.segment,sequence:t.sequence,start:t.captured,frames:frames,bytes:bytes,hash:String(repeating:"a",count:64),timing:.init(pts:pts,denominator:denominator,sample:sample,rate:s.timing.rate,epoch:s.timing.epoch,mapping:s.timing.mapping),member:member,stage:frames < 6400 ? .tooShort : .sealed,accepted:nil,attempt:nil))
        ledger.tracks[track].captured += frames; ledger.tracks[track].sequence += 1
    }
    mutating func gap(start: Int64, extent: Int64 = 8000, denominator: UInt64 = 16_000, extentDenominator: UInt64 = 16_000, kind: M.Gap.Kind = .measured, track: Int = 0) {
        let t = ledger.tracks[track]
        ledger.gaps.append(.init(id:meetingID(UInt64(10_000+ledger.gaps.count)),track:track,segment:t.segment,sequence:t.sequence,kind:kind,start:start,startDenominator:denominator,extent:extent,extentDenominator:extentDenominator))
        ledger.tracks[track].sequence += 1
    }
}
final class MeetingSessionTimingTests: XCTestCase {
    private func accepts(_ l: MeetingSession.Ledger, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNoThrow(try l.validate(),file:file,line:line)
        let encoded = try l.encoded(tier:MeetingSession.ordinaryBytes)
        XCTAssertEqual(try MeetingSession.Ledger.decode(encoded),l,file:file,line:line)
        XCTAssertEqual(try MeetingSession.Ledger.decode(l.json.encoded(cap:MeetingSession.ordinaryBytes)),l,file:file,line:line)
    }
    private func refuses(_ l: MeetingSession.Ledger, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try l.validate(),file:file,line:line)
        XCTAssertThrowsError(try l.encoded(tier:MeetingSession.ordinaryBytes),file:file,line:line)
        // Deliberately bypass Ledger.encoded: hostile decoder bytes cannot be blocked by the encoder first.
        let hostile = try l.json.encoded(cap:MeetingSession.ordinaryBytes)
        XCTAssertThrowsError(try MeetingSession.Ledger.decode(hostile),file:file,line:line)
    }
    func testSampleReuseOverlapAdjacencyAndIndependentForwardGap() throws {
        for sample in [UInt64(0),7999,8000,8001] {
            var f = MeetingTimingFixture(); try f.chunk(sample:0,pts:0); try f.chunk(sample:sample,pts:8000)
            if sample < 8000 { try refuses(f.ledger) } else { try accepts(f.ledger) }
        }
    }
    func testSegmentIDsDoNotResetEpochAndUnknownRecordsDoNotEraseFrontiers() throws {
        var same = MeetingTimingFixture(); try same.chunk(sample:0,pts:0); same.segment(); try same.chunk(sample:0,pts:8000)
        try refuses(same.ledger)
        var fresh = MeetingTimingFixture(); try fresh.chunk(sample:0,pts:0); fresh.segment(epoch:meetingID(201)); try fresh.chunk(sample:0,pts:0)
        try accepts(fresh.ledger)
        for (sample,pts,valid) in [(UInt64(0),Int64(8000),false),(8000,4000,false),(8000,8000,true)] {
            var unknown = MeetingTimingFixture(); try unknown.chunk(sample:0,pts:0); unknown.segment(mapping:.unknown)
            try unknown.chunk(sample:.max,pts:-16_000); try accepts(unknown.ledger)
            unknown.segment(); try unknown.chunk(sample:sample,pts:pts)
            if valid { try accepts(unknown.ledger) } else { try refuses(unknown.ledger) }
        }
    }
    func testUnlikeRateSampleUnitsStaySeparateButReturningRateRetainsFrontier() throws {
        var f = MeetingTimingFixture(); try f.chunk(sample:0,pts:0); f.segment(rate:32_000)
        try f.chunk(sample:0,pts:8000); try accepts(f.ledger)
        f.segment(); try f.chunk(sample:0,pts:16_000); try refuses(f.ledger)
        var pts = MeetingTimingFixture(); try pts.chunk(sample:0,pts:0); pts.segment(rate:32_000)
        try pts.chunk(sample:0,pts:4000); try refuses(pts.ledger)
    }
    func testMeasuredChunkGapGapChunkAndGapGapOrderingWithAdjacency() throws {
        for direction in 0..<3 {
            for start in [Int64(0),4000,8000,9000] {
                var f = MeetingTimingFixture()
                if direction == 0 { try f.chunk(sample:0,pts:0) } else { f.gap(start:0) }
                if direction == 1 { try f.chunk(sample:0,pts:start) } else { f.gap(start:start) }
                if start < 8000 { try refuses(f.ledger) } else { try accepts(f.ledger) }
            }
            var backward = MeetingTimingFixture()
            if direction == 0 { try backward.chunk(sample:16_000,pts:16_000) } else { backward.gap(start:16_000) }
            if direction == 1 { try backward.chunk(sample:0,pts:0) } else { backward.gap(start:0) }
            try refuses(backward.ledger)
        }
    }
    func testEquivalentRationalGapEndpointsAndPhysicalGapOrder() throws {
        var f = MeetingTimingFixture(); f.gap(start:0,extent:1,denominator:1,extentDenominator:2)
        f.gap(start:8000); try accepts(f.ledger)
        f.ledger.gaps.reverse(); try accepts(f.ledger)
        var bad = MeetingTimingFixture(); bad.gap(start:0); bad.gap(start:4000)
        bad.ledger.gaps.reverse(); try refuses(bad.ledger)
        var chunkGap = MeetingTimingFixture(); try chunkGap.chunk(sample:0,pts:0)
        chunkGap.gap(start:1,extent:1,denominator:2,extentDenominator:2); try accepts(chunkGap.ledger)
    }
    func testUnknownGapKeepsUnknownExtentWithoutResettingKnownCoverage() throws {
        for pts in [Int64(4000),8000,32_000] {
            var f = MeetingTimingFixture(); try f.chunk(sample:0,pts:0)
            f.gap(start:.max,extent:0,denominator:1,extentDenominator:1,kind:.unknown)
            try f.chunk(sample:8000,pts:pts)
            if pts < 8000 { try refuses(f.ledger) } else { try accepts(f.ledger) }
        }
        var gaps = MeetingTimingFixture(); gaps.gap(start:0)
        gaps.gap(start:.max,extent:0,kind:.unknown); gaps.gap(start:4000); try refuses(gaps.ledger)
    }
    func testGapDomainsAcrossSegmentsEpochsAndIndependentSources() throws {
        for fresh in [false,true] {
            var f = MeetingTimingFixture(); f.gap(start:0)
            f.segment(epoch:meetingID(fresh ? 201 : 200)); try f.chunk(sample:0,pts:0)
            if fresh { try accepts(f.ledger) } else { try refuses(f.ledger) }
        }
        var sources = MeetingTimingFixture(); sources.gap(start:0,track:0)
        try sources.chunk(sample:0,pts:0,track:1); try sources.chunk(sample:0,pts:8000,track:0)
        try accepts(sources.ledger)
        var samples = MeetingTimingFixture(); try samples.chunk(sample:0,pts:0,track:0); try samples.chunk(sample:0,pts:0,track:1)
        try accepts(samples.ledger)
    }
    func testIntegralSampleExtentsAndCheckedTimingArithmetic() throws {
        var fractional = MeetingTimingFixture(); fractional.segment(rate:11_025); try fractional.chunk(sample:0,pts:0,frames:1); try refuses(fractional.ledger)
        var integral = MeetingTimingFixture(); integral.segment(rate:11_025); try integral.chunk(sample:0,pts:0,frames:640); try accepts(integral.ledger)
        for sample in [UInt64.max-8000,UInt64.max-7999] {
            var f = MeetingTimingFixture(); try f.chunk(sample:sample,pts:0)
            if sample == UInt64.max-8000 { try accepts(f.ledger) } else { try refuses(f.ledger) }
        }
        var pts = MeetingTimingFixture(); try pts.chunk(sample:0,pts:.max,denominator:1); try refuses(pts.ledger)
        var gap = MeetingTimingFixture(); gap.gap(start:1,extent:.max,denominator:1,extentDenominator:1); try refuses(gap.ledger)
    }
}

extension MeetingSessionTimingTests {
    func testAll480KnownTimingEventsRemainBoundedAndLateOverlapRefuses() throws {
        var f = MeetingTimingFixture()
        for n in 0..<240 {
            try f.chunk(sample:UInt64(n)*8000,pts:Int64(n)*16_000)
            f.gap(start:Int64(n)*16_000+8000)
        }
        try accepts(f.ledger)
        let g = f.ledger.gaps.removeLast()
        f.ledger.gaps.append(.init(id:g.id,track:g.track,segment:g.segment,sequence:g.sequence,kind:g.kind,start:g.start-1,startDenominator:g.startDenominator,extent:g.extent,extentDenominator:g.extentDenominator))
        try refuses(f.ledger)
    }
}
