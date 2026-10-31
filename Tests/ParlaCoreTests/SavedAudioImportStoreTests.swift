import Darwin
import Foundation
import XCTest
@testable import ParlaCore

func savedFixtureWAV(frames:Int = 8000) -> Data {
    func le(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    let pcm = (0..<frames).reduce(into: Data()) { $0 += le($1 % 2 == 0 ? 16_000 : -16_000,2) }
    let fmt = le(1,2) + le(1,2) + le(16_000,4) + le(32_000,4) + le(2,2) + le(16,2)
    let chunks = Data("fmt ".utf8) + le(16,4) + fmt + Data("JUNK".utf8) + le(4,4) + Data([17,29,37,43]) + Data("data".utf8) + le(pcm.count,4) + pcm
    return Data("RIFF".utf8) + le(chunks.count + 4,4) + Data("WAVE".utf8) + chunks
}
struct SavedFixtureInput {
    let bytes: Data, original: SavedAudioImportStore.Original, facts: SavedAudioImportStore.Facts, requested: SavedAudioImportStore.Provenance
    init(_ fixture: SavedImportFixture, frames:Int = 8000) throws {
        bytes = savedFixtureWAV(frames:frames)
        let url = fixture.parent.appendingPathComponent("original.wav"); try bytes.write(to:url)
        var s = stat(); XCTAssertEqual(lstat(url.path,&s),0)
        original = .init(lexical:url.path,resolved:url.path,identity:.init(device:s.st_dev,inode:s.st_ino),bytes:s.st_size,
            modifiedSeconds:Int64(s.st_mtimespec.tv_sec),modifiedNanoseconds:Int64(s.st_mtimespec.tv_nsec),
            changedSeconds:Int64(s.st_ctimespec.tv_sec),changedNanoseconds:Int64(s.st_ctimespec.tv_nsec),flags:s.st_flags)
        facts = .init(try ImportedAudio.decode(bytes).transientSourceInfo)
        var settings = Settings(); settings.whisperModelPath = "/synthetic/never-opened.bin"
        requested = try .init(request:RecognitionRequest(settings:settings))
    }
    func admit(_ store: SavedAudioImportStore, now: Date = Date(timeIntervalSince1970:1_000_000)) throws -> SavedAudioImportStore.AttemptToken {
        try store.admit(id:UUID(),bytes:bytes,original:original,facts:facts,label:"Synthetic WAV",requested:requested,now:now,authorized:{true})
    }
}
final class SavedAudioImportStoreTests: XCTestCase {
    func testReservationFailureAfterRegistrationRetiresSourceAndResultDescriptors() throws {
        for resultPhase in [false, true] {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
            let suffix = resultPhase ? ".result.pending" : ".source.pending"
            var armed = false, registered = false, hit = false, closes = 0, writes = 0
            var name: String?, descriptor: Int32?, identity: SavedAudioImportStorage.Identity?
            var system = SavedAudioImportStorage.System()
            system.event = { boundary, member in
                guard armed else { return }
                if boundary == .create, member?.hasSuffix(suffix) == true { name = member }
                if boundary == .registered, member == name { registered = true }
                if registered, !hit, boundary == .enumerate {
                    hit = true
                    throw SavedAudioImportStorage.Failure.io
                }
            }
            system.inspect = { fd, value in
                let status = Darwin.fstat(fd, value)
                if status == 0, armed, descriptor == nil, let name {
                    var named = stat()
                    if lstat(fixture.root.appendingPathComponent(name).path, &named) == 0,
                       named.st_dev == value.pointee.st_dev, named.st_ino == value.pointee.st_ino {
                        descriptor = fd
                        identity = .init(device: named.st_dev, inode: named.st_ino)
                    }
                }
                return status
            }
            system.write = { fd, bytes, count in
                if fd == descriptor { writes += 1 }
                return Darwin.write(fd, bytes, count)
            }
            system.close = { fd in
                if fd == descriptor { closes += 1 }
                return Darwin.close(fd)
            }
            let store = SavedAudioImportStore(storage: fixture.storage(system: system))
            defer {
                armed = false
                // Retire only this fixture's exact still-open allocation on the
                // failing baseline, without hiding the retirement assertions.
                if let descriptor, let identity {
                    var held = stat()
                    if Darwin.fstat(descriptor, &held) == 0,
                       held.st_dev == identity.device, held.st_ino == identity.inode {
                        _ = Darwin.close(descriptor)
                    }
                }
                do { try store.close(); try fixture.closed() }
                catch { try? fixture.receipt("close-uncertain") }
            }
            XCTAssertTrue(try store.bootstrap().isEmpty)
            let token = resultPhase ? try input.admit(store) : nil
            armed = true
            XCTAssertThrowsError(try {
                if let token {
                    _ = try store.saveResult(token, resultID: UUID(), bytes: Data("raw result".utf8),
                        observed: .init(observed: nil), now: Date(timeIntervalSince1970: 1_000_001), authorized: { true })
                } else { _ = try input.admit(store) }
            }())
            XCTAssertTrue(registered)
            XCTAssertTrue(hit)
            let fd = try XCTUnwrap(descriptor)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
            errno = 0
            XCTAssertEqual(fcntl(fd, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: input.original.lexical)), input.bytes)
        }
    }

    func testSourceResultReopenIsExplicitAndSourceCanBeMissing() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        let token = try input.admit(store), now = Date(timeIntervalSince1970:1_000_001)
        XCTAssertEqual(try store.source(token,now:now),input.bytes)
        let result = try store.saveResult(token,resultID:UUID(),bytes:Data("raw only".utf8),observed:.init(observed:nil),now:now,authorized:{true})
        XCTAssertEqual(try store.openResult(token.job,now:now).1,Data("raw only".utf8))
        try store.close()
        var payloadReads = 0; var system = SavedAudioImportStorage.System()
        system.checkpoint = { if $0 == .payloadRead { payloadReads += 1 } }
        let reopened = SavedAudioImportStore(storage:fixture.storage(system:system))
        XCTAssertEqual(try reopened.bootstrap().first?.result?.id,result.id); XCTAssertEqual(payloadReads,0)
        let source = fixture.root.appendingPathComponent(token.source.uuidString.lowercased() + ".source.wav")
        XCTAssertEqual(unlink(source.path),0)
        XCTAssertEqual(try reopened.openResult(token.job,now:now).1,Data("raw only".utf8)); XCTAssertEqual(payloadReads,1)
        try reopened.close(); try fixture.closed()
    }
    func testDeletionJoinsBorrowAndNeverUsesOriginalAsAuthority() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        let token = try input.admit(store), now = Date(timeIntervalSince1970:1_000_001)
        let borrow = try store.borrow(token,now:now)
        try store.intentDelete(token.job)
        XCTAssertThrowsError(try store.source(token,now:now))
        XCTAssertThrowsError(try store.finishDelete(token.job))
        XCTAssertEqual(store.rows().count,1)
        borrow.end(); try store.finishDelete(token.job)
        XCTAssertTrue(store.rows().isEmpty)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
        try store.close(); try fixture.closed()
    }
    func testFixedExpiryAndBackwardClockNeverChooseDestructiveFallback() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        let token = try input.admit(store)
        XCTAssertThrowsError(try store.maintenance(now:Date(timeIntervalSince1970:999_999)))
        XCTAssertEqual(store.rows().count,1)
        XCTAssertThrowsError(try store.source(token,now:Date(timeIntervalSince1970:1_604_800)))
        try store.maintenance(now:Date(timeIntervalSince1970:1_604_800))
        XCTAssertTrue(store.rows().isEmpty)
        try store.close(); try fixture.closed()
    }
    func testFailedMetadataReplacementDoesNotPublishAResult() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
        var failing = false, reads = 0
        var system = SavedAudioImportStorage.System()
        system.checkpoint = { boundary in
            if boundary == .payloadRead { reads += 1 }
            if failing && boundary == .write { failing = false; throw SavedAudioImportStorage.Failure.io }
        }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)), token = try input.admit(store)
        let resultID = UUID(), text = Data("same exact result".utf8), now = Date(timeIntervalSince1970:1_000_001)
        // Fail the metadata allocation before a candidate file exists; then retry.
        failing = true
        XCTAssertThrowsError(try store.saveResult(token,resultID:resultID,bytes:text,observed:.init(observed:nil),now:now,authorized:{true}))
        XCTAssertNil(store.rows().first?.result)
        XCTAssertGreaterThan(reads,0) // connected storage really verified the source earlier
        try store.close(); try fixture.closed() // conservative incomplete manifest is preserved
    }
    func testUnknownEntryAndFutureSchemaArePreserved() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        _ = try input.admit(store); try store.close()
        let unknown = fixture.root.appendingPathComponent("unknown")
        try Data([91,92,93]).write(to:unknown)
        let reopened = SavedAudioImportStore(storage:fixture.storage())
        XCTAssertThrowsError(try reopened.bootstrap())
        XCTAssertThrowsError(try reopened.protection())
        XCTAssertEqual(try Data(contentsOf:unknown),Data([91,92,93]))
        try reopened.close(); try fixture.closed()
    }
}


extension SavedAudioImportStoreTests {
    func testTenAllocatedSlotsAndEleventhRefusalWithoutEviction() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        for _ in 0..<10 {
            let token = try input.admit(store)
            _ = try store.saveResult(token,resultID:UUID(),bytes:Data("raw".utf8),observed:.init(observed:nil),now:Date(timeIntervalSince1970:1_000_000),authorized:{true})
        }
        let ids = store.rows().map(\.id)
        XCTAssertEqual(ids.count,10); XCTAssertThrowsError(try input.admit(store)); XCTAssertEqual(store.rows().map(\.id),ids)
        try store.close(); try fixture.closed()
    }
    func testPublicationFaultCutsNeverAcknowledgeOrModifyTheOriginal() throws {
        for boundary in [SavedAudioImportStorage.Boundary.create,.write,.fileSync,.rename,.directorySync,.verify,.hash,.freeSpace] {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
            var cut = false, hit = false; var system = SavedAudioImportStorage.System()
            system.checkpoint = { at in if cut && !hit && at == boundary { hit = true; throw SavedAudioImportStorage.Failure.io } }
            let store = SavedAudioImportStore(storage:fixture.storage(system:system))
            XCTAssertTrue(try store.bootstrap().isEmpty)
            cut = true
            XCTAssertThrowsError(try input.admit(store),"fault \(boundary)")
            XCTAssertTrue(hit)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
            try store.close()
            let reopened = SavedAudioImportStore(storage:fixture.storage())
            do { _ = try reopened.bootstrap(); XCTAssertTrue(reopened.rows().allSatisfy({$0.result == nil})) }
            catch { XCTAssertNotNil(reopened.failure) }
            try reopened.close(); try fixture.closed()
        }
    }
    func testFailedFirstIntentWithoutEvidenceIsNotDurableAcceptance() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
        var cut = false; var system = SavedAudioImportStorage.System()
        system.checkpoint = { if cut && $0 == .create {cut = false; throw SavedAudioImportStorage.Failure.io} }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)), token = try input.admit(store)
        cut = true; XCTAssertThrowsError(try store.intentDelete(token.job)); XCTAssertTrue(store.rows()[0].deleting)
        try store.close()
        let reopened = SavedAudioImportStore(storage:fixture.storage()); _ = try reopened.bootstrap()
        XCTAssertFalse(reopened.rows()[0].deleting) // no persisted intent can justify a cross-crash fence
        let fresh = try reopened.begin(token.job,requested:input.requested,now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
        XCTAssertEqual(try reopened.source(fresh,now:Date(timeIntervalSince1970:1_000_001)),input.bytes)
        try reopened.close(); try fixture.closed()
    }
    func testPartialFirstIntentRetriesOnlyItsKnownGenerationInCurrentProcess() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
        var cut = false; var system = SavedAudioImportStorage.System()
        system.write = {fd,bytes,count in
            if cut {cut = false; errno = ENOSPC; return -1}; return Darwin.write(fd,bytes,count)
        }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)), token = try input.admit(store)
        cut = true; XCTAssertThrowsError(try store.intentDelete(token.job)); XCTAssertEqual(store.rows().count,1)
        try store.intentDelete(token.job); try store.finishDelete(token.job)
        XCTAssertTrue(store.rows().isEmpty)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
        try store.close(); try fixture.closed()
    }
    func testAcceptedTombstoneSurvivesFailedUnlinkAndReopen() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
        var cut = false; var system = SavedAudioImportStorage.System()
        system.checkpoint = { if cut && $0 == .unlink {cut = false; throw SavedAudioImportStorage.Failure.io} }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)), token = try input.admit(store)
        try store.intentDelete(token.job); cut = true
        XCTAssertThrowsError(try store.finishDelete(token.job)); XCTAssertEqual(store.rows().count,1)
        try store.close()
        let reopened = SavedAudioImportStore(storage:fixture.storage()); _ = try reopened.bootstrap()
        XCTAssertTrue(reopened.rows()[0].deleting)
        XCTAssertThrowsError(try reopened.source(token,now:Date(timeIntervalSince1970:1_000_001)))
        try reopened.finishDelete(token.job); XCTAssertTrue(reopened.rows().isEmpty)
        try reopened.close(); try fixture.closed()
    }
    func testClosedSchemaAndOversizedMetadataRefuseWithoutRewriting() throws {
        for mutation in 0..<4 {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
            _ = try input.admit(store); try store.close()
            let path = fixture.root.appendingPathComponent("manifest.json"), before = try Data(contentsOf:path)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with:before) as? [String:Any])
            if mutation == 0 {document["schema"] = 99}
            if mutation == 1 {document["unknown"] = true}
            if mutation == 2 {document["revision"] = -1}
            let bytes = mutation == 3 ? Data(repeating:32,count:65_537) : try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys])
            try bytes.write(to:path)
            let reopened = SavedAudioImportStore(storage:fixture.storage())
            XCTAssertThrowsError(try reopened.bootstrap()); XCTAssertEqual(try Data(contentsOf:path),bytes)
            try reopened.close(); try fixture.closed()
        }
    }
}

private struct SavedPhaseCut: Equatable, CustomStringConvertible {
    let boundary: SavedAudioImportStorage.Boundary, member: String
    let occurrence: Int
    var description: String { "\(boundary.rawValue):\(member)#\(occurrence)" }
}
private func savedPhaseMember(_ name: String?) -> String? {
    guard let name else {return nil}
    if name == "manifest.next" || name == "manifest.json" {return name}
    for suffix in [".source.pending",".source.wav",".result.pending",".raw.txt"] where name.hasSuffix(suffix) {return suffix}
    return nil
}
extension SavedAudioImportStoreTests {
    /// Trace the successful transaction first, then cut each member/occurrence
    /// in independent real namespaces. Bootstrap is already complete when armed.
    func testSourceAndReplacementResultCutsAfterBootstrapReconstructConservatively() throws {
        let boundaries: Set<SavedAudioImportStorage.Boundary> = [.allocation,.registered,.create,.created,.write,.fileSync,.close,.verify,.hash,.rename,.directorySync,.unlink]
        for resultPhase in [false,true] {
            func run(cut: SavedPhaseCut?) throws -> [SavedPhaseCut] {
                let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture,frames:40000)
                var armed = false, hit = false, events: [SavedPhaseCut] = [], counts: [String:Int] = [:]
                var system = SavedAudioImportStorage.System()
                system.event = {boundary,name in
                    guard armed, boundaries.contains(boundary) else {return}
                    guard let member = savedPhaseMember(name) ?? (boundary == .directorySync ? "retired-result-directory" : nil) else {return}
                    let key = boundary.rawValue+member; counts[key,default:0] += 1
                    let event = SavedPhaseCut(boundary:boundary,member:member,occurrence:counts[key]!)
                    events.append(event)
                    if !hit, event == cut {hit = true; throw SavedAudioImportStorage.Failure.io}
                }
                let store = SavedAudioImportStore(storage:fixture.storage(system:system)), first = try input.admit(store)
                let now = Date(timeIntervalSince1970:1_000_001)
                let old = Data("previous accepted text".utf8), replacement = Data(String(repeating:"replacement exact text\n",count:5000).utf8)
                var attempt = first
                if resultPhase {
                    _ = try store.saveResult(first,resultID:UUID(),bytes:old,observed:.init(observed:nil),now:now,authorized:{true})
                    attempt = try store.begin(first.job,requested:input.requested,now:now,authorized:{true})
                } else {try store.finish(first,canceled:true)}
                armed = true
                do {
                    if resultPhase {_ = try store.saveResult(attempt,resultID:UUID(),bytes:replacement,observed:.init(observed:nil),now:now,authorized:{true})}
                    else {_ = try input.admit(store,now:now)}
                    XCTAssertNil(cut,"cut never hit: \(String(describing:cut))")
                } catch {XCTAssertNotNil(cut); XCTAssertTrue(hit,"\(String(describing:cut)): \(error)")}
                armed = false
                XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
                let uncertainClose: Bool
                do {try store.close(); uncertainClose = false} catch {uncertainClose = true}
                var payloadReads = 0; var nextSystem = SavedAudioImportStorage.System()
                nextSystem.event = {boundary,_ in if boundary == .payloadRead {payloadReads += 1}}
                let next = SavedAudioImportStore(storage:fixture.storage(system:nextSystem))
                do {
                    let rows = try next.bootstrap()
                    XCTAssertEqual(payloadReads,0) // reconstruction never loads source/result
                    if resultPhase, let row = rows.first, row.result != nil {
                        let raw = try next.openResult(row.id,now:now).1
                        XCTAssertTrue([old,replacement].contains(raw))
                        // Before candidate publication/acceptance, the prior pointer survives.
                        if let cut, cut.member == ".result.pending", cut.boundary != .rename {
                            XCTAssertEqual(raw,old,"\(cut)")
                        }
                    }
                    if !resultPhase {XCTAssertTrue(rows.allSatisfy {$0.result == nil})}
                } catch {XCTAssertNotNil(next.failure)}
                try next.close()
                if uncertainClose {try fixture.receipt("close-uncertain")} else {try fixture.closed()}
                return events
            }
            let schedule = try run(cut:nil)
            print("saved phase schedule \(resultPhase ? "replacement" : "source"): " + schedule.map(\.description).joined(separator:","))
            XCTAssertGreaterThan(schedule.count,20)
            for cut in schedule { _ = try run(cut:cut) }
        }
    }
    func testTwoStepRetirementCutsKeepAuthorityRevokedAndSlotChargedUntilFinalSync() throws {
        for boundary in [SavedAudioImportStorage.Boundary.payloadRetired,.authorityRetired,.tombstoneRetired,.allocationRetired] {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
            var armed = false, hit = false; var system = SavedAudioImportStorage.System()
            system.event = {at,_ in if armed && !hit && at == boundary {hit = true; throw SavedAudioImportStorage.Failure.io}}
            let store = SavedAudioImportStore(storage:fixture.storage(system:system)), token = try input.admit(store)
            let now = Date(timeIntervalSince1970:1_000_001), resultID = UUID()
            _ = try store.saveResult(token,resultID:resultID,bytes:Data("accepted".utf8),observed:.init(observed:nil),now:now,authorized:{true})
            try store.intentDelete(token.job); armed = true
            XCTAssertThrowsError(try store.finishDelete(token.job)); XCTAssertTrue(hit)
            armed = false; try store.close()
            let next = SavedAudioImportStore(storage:fixture.storage()); let rows = try next.bootstrap()
            if boundary == .allocationRetired {XCTAssertTrue(rows.isEmpty)}
            else {
                XCTAssertEqual(rows.count,1); XCTAssertTrue(rows[0].deleting); XCTAssertNil(rows[0].result); XCTAssertFalse(rows[0].sourceAvailable)
                XCTAssertThrowsError(try input.admit(next,now:now))
                XCTAssertThrowsError(try next.begin(token.job,requested:input.requested,now:now,authorized:{true}))
                XCTAssertThrowsError(try next.source(token,now:now)); XCTAssertThrowsError(try next.borrow(token,now:now))
                XCTAssertThrowsError(try next.openResult(token.job,now:now))
                XCTAssertThrowsError(try next.association(token.job,resultID:resultID,state:.saved,now:now,authorized:{true}))
                XCTAssertThrowsError(try next.saveResult(token,resultID:UUID(),bytes:Data("late".utf8),observed:.init(observed:nil),now:now,authorized:{true}))
                try next.finish(token,canceled:false); XCTAssertTrue(next.rows()[0].deleting)
                if boundary == .tombstoneRetired {
                    XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(token.job.uuidString.lowercased()+".delete").path))
                }
                try next.intentDelete(token.job); try next.finishDelete(token.job); XCTAssertTrue(next.rows().isEmpty)
            }
            let fresh = try input.admit(next,now:now); XCTAssertEqual(try next.source(fresh,now:now),input.bytes)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
            try next.close(); try fixture.closed()
        }
    }
    func testClosedAuthorityFieldsAndGenerationsPreserveInvalidBytes() throws {
        for mutation in 0..<10 {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
            let token = try input.admit(store)
            _ = try store.saveResult(token,resultID:UUID(),bytes:Data("old accepted".utf8),observed:.init(observed:nil),now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
            try store.close()
            let path = fixture.root.appendingPathComponent("manifest.json")
            var value = try JSONDecoder().decode(SavedAudioImportStore.Ledger.self,from:Data(contentsOf:path))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
            switch mutation {
            case 0: object["revision"] = NSNull()
            case 1: object["owner"] = UUID().uuidString
            case 2: object["root"] = ["device":-1,"inode":1]
            case 3: value.jobs[0].resourcesRetired = true
            case 4: value.jobs[0].source.member = nil
            case 5:
                var jobs = try XCTUnwrap(object["jobs"] as? [[String:Any]])
                var accepted = try XCTUnwrap(jobs[0]["accepted"] as? [String:Any])
                var payload = try XCTUnwrap(accepted["payload"] as? [String:Any])
                payload["published"] = false; accepted["payload"] = payload; jobs[0]["accepted"] = accepted; object["jobs"] = jobs
            case 6: object["jobs"] = NSNull()
            case 7: object["unexpected"] = ["recursive":true]
            case 8: value.jobs[0].retired = value.jobs[0].source // duplicate generation/name
            default: value.jobs[0].source.published = false
            }
            let bytes = [0,1,2,5,6,7].contains(mutation) ? try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) : try JSONEncoder().encode(value)
            try bytes.write(to:path)
            let next = SavedAudioImportStore(storage:fixture.storage())
            XCTAssertThrowsError(try next.bootstrap(),"mutation \(mutation)")
            XCTAssertThrowsError(try next.protection()); XCTAssertEqual(try Data(contentsOf:path),bytes)
            try next.close(); try fixture.closed()
        }
    }
    func testNonfiniteClockBorrowedExpiryAndRetryNeverRenewDeadline() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
        let token = try input.admit(store), originalExpiry = try XCTUnwrap(store.rows().first?.expires)
        for time in [Double.nan,Double.infinity,-Double.infinity,Double.greatestFiniteMagnitude,1e30,999_999] {
            XCTAssertThrowsError(try store.maintenance(now:Date(timeIntervalSince1970:time)))
            XCTAssertEqual(store.rows().first?.expires,originalExpiry)
        }
        let borrow = try store.borrow(token,now:Date(timeIntervalSince1970:1_000_001))
        try store.maintenance(now:originalExpiry); XCTAssertEqual(store.rows().count,1)
        XCTAssertThrowsError(try store.begin(token.job,requested:input.requested,now:originalExpiry,authorized:{true}))
        borrow.end(); try store.maintenance(now:originalExpiry); XCTAssertTrue(store.rows().isEmpty)
        try store.close(); try fixture.closed()
    }
}

extension SavedAudioImportStoreTests {
    func testTombstoneAndRetirementMemberOccurrenceCutsBlockAllNewGenerationsUntilSettlement() throws {
        let boundaries:Set<SavedAudioImportStorage.Boundary> = [.create,.created,.write,.fileSync,.close,.verify,.hash,.rename,.directorySync,.unlink,.payloadRetired,.authorityRetired,.tombstoneRetired,.allocationRetired]
        for intentPhase in [true,false] {
            func run(_ cut:SavedPhaseCut?) throws -> [SavedPhaseCut] {
                let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture)
                var armed = false, hit = false, counts:[String:Int] = [:], trace:[SavedPhaseCut] = []
                var system = SavedAudioImportStorage.System()
                system.event = {boundary,name in
                    guard armed,boundaries.contains(boundary) else {return}
                    let member:String
                    if let name, name.hasSuffix(".delete") {member = ".delete"}
                    else if let known = savedPhaseMember(name) {member = known}
                    else if boundary == .directorySync {member = "payload-or-intent-directory"}
                    else {return}
                    let key = boundary.rawValue+member; counts[key,default:0] += 1
                    let event = SavedPhaseCut(boundary:boundary,member:member,occurrence:counts[key]!)
                    trace.append(event)
                    if !hit,event == cut {hit = true; throw SavedAudioImportStorage.Failure.io}
                }
                let store = SavedAudioImportStore(storage:fixture.storage(system:system)), first = try input.admit(store)
                let now = Date(timeIntervalSince1970:1_000_001)
                _ = try store.saveResult(first,resultID:UUID(),bytes:Data("first raw".utf8),observed:.init(observed:nil),now:now,authorized:{true})
                let other = try input.admit(store,now:now)
                _ = try store.saveResult(other,resultID:UUID(),bytes:Data("other raw".utf8),observed:.init(observed:nil),now:now,authorized:{true})
                if !intentPhase {try store.intentDelete(first.job)}
                armed = true
                do {
                    if intentPhase {try store.intentDelete(first.job)} else {try store.finishDelete(first.job)}
                    XCTAssertNil(cut)
                } catch {XCTAssertNotNil(cut); XCTAssertTrue(hit,"\(String(describing:cut))")}
                armed = false
                let uncertain:Bool
                do {try store.close(); uncertain = false} catch {uncertain = true}
                let next = SavedAudioImportStore(storage:fixture.storage())
                do {
                    let rows = try next.bootstrap()
                    XCTAssertNotNil(rows.first(where:{$0.id == other.job})?.result)
                    XCTAssertEqual(try next.openResult(other.job,now:now).1,Data("other raw".utf8))
                    if let row = rows.first(where:{$0.id == first.job}) {
                        if row.deleting {
                            XCTAssertNil(row.result); XCTAssertFalse(row.sourceAvailable)
                            XCTAssertThrowsError(try next.openResult(first.job,now:now))
                            XCTAssertThrowsError(try next.source(first,now:now))
                            XCTAssertThrowsError(try input.admit(next,now:now))
                            XCTAssertThrowsError(try next.begin(other.job,requested:input.requested,now:now,authorized:{true}))
                            try next.intentDelete(first.job); try next.finishDelete(first.job)
                        } else {
                            // Only failure before exclusive intent creation has no
                            // persisted evidence; the old raw may honestly reopen.
                            XCTAssertTrue(intentPhase); XCTAssertEqual(cut?.boundary,.create); XCTAssertEqual(cut?.member,".delete")
                            XCTAssertEqual(try next.openResult(first.job,now:now).1,Data("first raw".utf8))
                        }
                    }
                } catch {XCTAssertNotNil(next.failure)}
                XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:input.original.lexical)),input.bytes)
                try next.close()
                if uncertain {try fixture.receipt("close-uncertain")} else {try fixture.closed()}
                return trace
            }
            let trace = try run(nil)
            print("saved delete phase schedule \(intentPhase ? "intent" : "retirement"): "+trace.map(\.description).joined(separator:","))
            XCTAssertGreaterThan(trace.count,15)
            for cut in trace {_ = try run(cut)}
        }
    }
}

extension SavedAudioImportStoreTests {
    func testMeetingDomainDoesNotChangeImportSchemaQuotaOrCapacity() throws {
        XCTAssertEqual(SavedAudioImportStore.maximumJobs,10); XCTAssertEqual(SavedAudioImportStore.maximumSource,20_971_520)
        XCTAssertEqual(SavedAudioImportStore.maximumResult,1_048_576); XCTAssertEqual(SavedAudioImportStore.maximumLedger,65_536)
        XCTAssertEqual(SavedAudioImportStore.quota,268_435_456)
        let owner = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!, root = SavedAudioImportStorage.Identity(device:1,inode:1)
        let value = SavedAudioImportStore.Marker(schema:1,owner:owner,root:root), encoder = JSONEncoder()
        let bytes = try encoder.encode(value), decoded = try JSONDecoder().decode(SavedAudioImportStore.Marker.self,from:bytes)
        XCTAssertEqual(decoded,value)
        let meeting = Data("{\"d\":\"parla.meeting.1\",\"v\":1}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedAudioImportStore.Marker.self,from:meeting))
        XCTAssertThrowsError(try SavedAudioImportStore.Provenance.hash(String(repeating:"f",count:65)))
    }
}
