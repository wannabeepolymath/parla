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
            let token = try input.admit(store); try store.close()
            let sourcePath = fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")
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
    for suffix in [".source.pending",".source.wav",".source.mov",".result.pending",".raw.txt"] where name.hasSuffix(suffix) {return suffix}
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


private struct ConnectedMOVInput {
    let bytes: Data, facts: SavedAudioImportStore.Facts, original: SavedAudioImportStore.Original
    let requested: SavedAudioImportStore.Provenance
    init(_ fixture: SavedImportFixture, video: UInt8 = 0xa5, tail: UInt8 = 0x7f) throws {
        bytes = ConnectedMOVBytes.make(video:video,tail:tail)
        facts = .init(try ImportedAudio.decodeSource(bytes,format:.mov).transientSourceInfo)
        // Original is protection metadata, never a pathname opened by the Store.
        original = .init(lexical:fixture.parent.appendingPathComponent("original.mov").path,
            resolved:fixture.parent.appendingPathComponent("original.mov").path,identity:fixture.identity,
            bytes:Int64(bytes.count),modifiedSeconds:1,modifiedNanoseconds:0,changedSeconds:1,changedNanoseconds:0,flags:0)
        var settings = Settings(); settings.whisperModelPath = "/synthetic/never-opened.bin"
        requested = try .init(request:RecognitionRequest(settings:settings))
    }
    func admit(_ store: SavedAudioImportStore, now: Date = Date(timeIntervalSince1970:1_000_001),
               started: TimeInterval? = nil, credits: Int = 0, authorized: () -> Bool = {true}) throws -> SavedAudioImportStore.AttemptToken {
        try store.admit(id:UUID(),bytes:bytes,original:original,facts:facts,label:"Inert MOV",requested:requested,
            now:now,startedUptime:started,priorWorkCredits:credits,authorized:authorized)
    }
}
private func connectedDocument(_ bytes: Data) throws -> [String:Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
}
private func connectedJobs(_ bytes: Data) throws -> [[String:Any]] {
    try XCTUnwrap(connectedDocument(bytes)["jobs"] as? [[String:Any]])
}
private func connectedLedger(_ bytes: Data) throws -> SavedAudioImportStore.Ledger {
    let schema = try XCTUnwrap(connectedDocument(bytes)["schema"] as? Int)
    let decoder = JSONDecoder(); decoder.userInfo[SavedAudioImportStore.ledgerSchemaKey] = schema
    return try decoder.decode(SavedAudioImportStore.Ledger.self,from:bytes)
}
private func connectedPreserve(_ fixture: SavedImportFixture, _ store: SavedAudioImportStore) {
    do { try store.close(); try fixture.closed() } catch { try? fixture.receipt("close-uncertain") }
}

extension SavedAudioImportStoreTests {
    func testConnectedMOVSchemaGoldenKeysWholeSourceAndSameTokenSnapshot() throws {
        let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
        let store = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,store)}
        let oldToken = try wav.admit(store)
        _ = try store.saveResult(oldToken,resultID:UUID(),bytes:Data("legacy text".utf8),observed:.init(observed:nil),now:Date(timeIntervalSince1970:1_000_000),authorized:{true})
        let path = fixture.root.appendingPathComponent("manifest.json"), before = try Data(contentsOf:path)
        let oldLedger = try JSONDecoder().decode(SavedAudioImportStore.Ledger.self,from:before)
        let oldJob = try XCTUnwrap(oldLedger.jobs.first)
        let oldFacts = try connectedDocument(JSONEncoder().encode(oldJob.facts))
        XCTAssertEqual(Set(oldFacts.keys),Set(["rate","frames","outputFrames","clipped"]))
        XCTAssertEqual(oldFacts["rate"] as? Int,16000); XCTAssertEqual(oldFacts["frames"] as? Int,8000)
        XCTAssertEqual(oldFacts["outputFrames"] as? Int,8000); XCTAssertEqual(oldFacts["clipped"] as? Int,0)
        XCTAssertEqual(oldJob.source.kind,.source); XCTAssertTrue(oldJob.source.final.hasSuffix(".source.wav"))
        let token = try mov.admit(store), bytes = try Data(contentsOf:path), ledger = try connectedLedger(bytes)
        XCTAssertEqual(ledger.schema,2); XCTAssertEqual(ledger.jobs.first,oldJob)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedAudioImportStore.Ledger.self,from:bytes))
        XCTAssertThrowsError(try JSONEncoder().encode(ledger))
        let document = try connectedDocument(bytes)
        XCTAssertEqual(Set(document.keys),Set(["schema","owner","root","revision","jobs"]))
        let jobs = try connectedJobs(bytes), job = try XCTUnwrap(jobs.last)
        let facts = try XCTUnwrap(job["facts"] as? [String:Any])
        XCTAssertEqual(Set(facts.keys),Set(["profile","rate","frames","outputFrames","clipped"]))
        XCTAssertEqual(facts["profile"] as? String,"qtPCM16kV1")
        let source = try XCTUnwrap(ledger.jobs.last?.source)
        XCTAssertEqual(source.kind,.pcmMOVSource); XCTAssertTrue(source.final.hasSuffix(".source.mov"))
        XCTAssertEqual(source.hash,SavedAudioImportStorage.digest(mov.bytes)); XCTAssertEqual(source.bytes,Int64(mov.bytes.count))
        XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(source.final)),mov.bytes)
        let snapshot = try store.sourceSnapshot(token,now:Date(timeIntervalSince1970:1_000_001))
        XCTAssertEqual(snapshot.bytes,mov.bytes); XCTAssertEqual(snapshot.facts,mov.facts)
        let invalid = [
            SavedAudioImportStore.AttemptToken(job:oldToken.job,source:token.source,id:token.id,revision:token.revision),
            .init(job:token.job,source:UUID(),id:token.id,revision:token.revision),
            .init(job:token.job,source:token.source,id:UUID(),revision:token.revision),
            .init(job:token.job,source:token.source,id:token.id,revision:token.revision + 1)]
        for other in invalid {XCTAssertThrowsError(try store.sourceSnapshot(other,now:Date(timeIntervalSince1970:1_000_001)))}
        XCTAssertThrowsError(try store.sourceSnapshot(token,now:Date(timeIntervalSince1970:1_000_001),authorized:{false}))
        let marker = try connectedDocument(Data(contentsOf:fixture.root.appendingPathComponent("owner.json")))
        XCTAssertEqual(marker["schema"] as? Int,1)
        try store.intentDelete(token.job)
        let tombstone = try connectedDocument(Data(contentsOf:fixture.root.appendingPathComponent(token.job.uuidString.lowercased()+".delete")))
        XCTAssertEqual(tombstone["schema"] as? Int,1)
    }

    func testConnectedMOVSchemaClosedProfilesKindsAndCanonicalRoundtripPreserveBytes() throws {
        // Independent exact mutations, one fresh owned namespace per case.
        for cut in 0..<11 {
            let fixture = try SavedImportFixture(), input = try ConnectedMOVInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
            let token = try input.admit(store); try store.close()
            let sourcePath = fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")
            let path = fixture.root.appendingPathComponent("manifest.json")
            var document = try connectedDocument(Data(contentsOf:path)), jobs = try XCTUnwrap(document["jobs"] as? [[String:Any]])
            var job = jobs[0], facts = try XCTUnwrap(job["facts"] as? [String:Any]), source = try XCTUnwrap(job["source"] as? [String:Any])
            switch cut {
            case 0: facts.removeValue(forKey:"profile")
            case 1: facts["profile"] = NSNull()
            case 2: facts["profile"] = "future"
            case 3: facts["version"] = 1
            case 4: document["schema"] = 3
            case 5: document["schema"] = 1; facts.removeValue(forKey:"profile")
            case 6: source["kind"] = "source"
            case 7: facts["profile"] = "wavPCM"
            case 8: facts["outputFrames"] = 7999
            case 9: facts["clipped"] = 1
            default: var original = try XCTUnwrap(job["original"] as? [String:Any]); original["bytes"] = input.bytes.count - 1; job["original"] = original
            }
            job["facts"] = facts; job["source"] = source; jobs[0] = job; document["jobs"] = jobs
            let invalid = try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys]); try invalid.write(to:path)
            let reopened = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,reopened)}
            XCTAssertThrowsError(try reopened.bootstrap(),"cut \(cut)")
            XCTAssertNotNil(reopened.failure); XCTAssertEqual(try Data(contentsOf:path),invalid)
            XCTAssertEqual(try Data(contentsOf:sourcePath),input.bytes)
        }
    }

    func testConnectedMOVSchemaPureAdmissionRejectsDetachedFactsBeforeStorageGrant() throws {
        let fixture = try SavedImportFixture(), input = try ConnectedMOVInput(fixture)
        let store = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,store)}
        var encoded = try connectedDocument({ () throws -> Data in
            let e = JSONEncoder(); e.userInfo[SavedAudioImportStore.ledgerSchemaKey] = 2; return try e.encode(input.facts)
        }())
        encoded["frames"] = 8001; encoded["outputFrames"] = 8001
        let d = JSONDecoder(); d.userInfo[SavedAudioImportStore.ledgerSchemaKey] = 2
        let detached = try d.decode(SavedAudioImportStore.Facts.self,from:JSONSerialization.data(withJSONObject:encoded))
        for bytes in [Data(input.bytes.dropLast()),savedFixtureWAV(),input.bytes] {
            XCTAssertThrowsError(try store.admit(id:UUID(),bytes:bytes,original:input.original,facts:detached,label:"detached",requested:input.requested,now:Date(timeIntervalSince1970:1_000_000),authorized:{true}))
            XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.path))
        }
        XCTAssertThrowsError(try input.admit(store,credits:65_536))
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.path))
        XCTAssertThrowsError(try input.admit(store,authorized:{false}))
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.path))
    }

    func testConnectedMOVMigrationPreservesSettledJobsAndNeverReadsOldPayloads() throws {
        let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
        var armed = false, oldPayloadEvents = 0, oldNames = Set<String>()
        var system = SavedAudioImportStorage.System()
        system.event = { boundary,name in
            if armed, let name, oldNames.contains(name), [.payloadRead,.hash,.write,.rename,.unlink].contains(boundary) {oldPayloadEvents += 1}
        }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {connectedPreserve(fixture,store)}
        let token = try wav.admit(store), now = Date(timeIntervalSince1970:1_000_001)
        let result = try store.saveResult(token,resultID:UUID(),bytes:Data("legacy exact raw".utf8),observed:.init(observed:nil),now:now,authorized:{true})
        try store.association(token.job,resultID:result.id,state:.saved,now:now,authorized:{true})
        let path = fixture.root.appendingPathComponent("manifest.json"), old = try connectedLedger(Data(contentsOf:path))
        let job = try XCTUnwrap(old.jobs.first)
        let savedBeforeMigration = try XCTUnwrap(job.accepted)
        var expectedSaved = result; expectedSaved.association = .saved
        XCTAssertEqual(savedBeforeMigration,expectedSaved) // Only the explicit association action changed it.
        oldNames = [job.source.final,(try XCTUnwrap(job.accepted)).id.uuidString.lowercased()+".raw.txt"]
        var snapshots: [String:Data] = [:]
        for name in oldNames {snapshots[name] = try Data(contentsOf:fixture.root.appendingPathComponent(name))}
        armed = true; _ = try mov.admit(store); armed = false
        let next = try connectedLedger(Data(contentsOf:path))
        XCTAssertEqual(next.schema,2); XCTAssertEqual(next.owner,old.owner); XCTAssertEqual(next.root,old.root)
        XCTAssertEqual(next.jobs.first,job); XCTAssertEqual(oldPayloadEvents,0)
        for name in oldNames {XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(name)),snapshots[name])}
        XCTAssertEqual(try store.openResult(token.job,now:now).0,savedBeforeMigration)
        try store.close()
        var reads = 0; var reopenSystem = SavedAudioImportStorage.System(); reopenSystem.checkpoint = {if $0 == .payloadRead {reads += 1}}
        let reopened = SavedAudioImportStore(storage:fixture.storage(system:reopenSystem)); defer {connectedPreserve(fixture,reopened)}
        _ = try reopened.bootstrap(); XCTAssertEqual(reads,0)
        XCTAssertEqual(Set(reopened.rows().map(\.sourceProfile)),Set([.wavPCM,.qtPCM16kV1]))
        XCTAssertEqual(try reopened.openResult(token.job,now:now).1,Data("legacy exact raw".utf8))
    }

    func testConnectedMOVMigrationQuiescenceAndSchema2WAVOnlyNeverDowngrades() throws {
        let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
        var failAllocation = false, hit = false; var system = SavedAudioImportStorage.System()
        system.event = {boundary,name in
            if failAllocation, !hit, boundary == .allocation, name?.hasSuffix(".source.pending") == true {hit = true; throw SavedAudioImportStorage.Failure.io}
        }
        let store = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {connectedPreserve(fixture,store)}
        let token = try wav.admit(store), path = fixture.root.appendingPathComponent("manifest.json")
        let queued = try Data(contentsOf:path)
        XCTAssertThrowsError(try mov.admit(store)); XCTAssertEqual(try Data(contentsOf:path),queued)
        let borrow = try store.borrow(token,now:Date(timeIntervalSince1970:1_000_001)); defer {borrow.end()}
        try store.finish(token,canceled:true)
        let settled = try Data(contentsOf:path)
        XCTAssertThrowsError(try mov.admit(store)); XCTAssertEqual(try Data(contentsOf:path),settled)
        borrow.end()
        // Acknowledge migration, fail the separate source transaction before allocation.
        failAllocation = true; XCTAssertThrowsError(try mov.admit(store)); XCTAssertTrue(hit)
        let schema2 = try connectedLedger(Data(contentsOf:path)); XCTAssertEqual(schema2.schema,2)
        // Preserve the fully valid schema2 WAV-only projection, removing only the
        // authored unallocated staging row in this explicit corruption-test fixture.
        let wavOnly = SavedAudioImportStore.Ledger(schema:2,owner:schema2.owner,root:schema2.root,revision:schema2.revision,jobs:[schema2.jobs[0]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.userInfo[SavedAudioImportStore.ledgerSchemaKey] = 2
        try store.close(); let bytes = try encoder.encode(wavOnly); try bytes.write(to:path)
        let reopened = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,reopened)}
        XCTAssertEqual(try reopened.bootstrap().count,1)
        try reopened.maintenance(now:Date(timeIntervalSince1970:1_000_001))
        XCTAssertEqual(try Data(contentsOf:path),bytes)
        let retry = try reopened.begin(token.job,requested:wav.requested,now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
        XCTAssertEqual(try reopened.sourceSnapshot(retry,now:Date(timeIntervalSince1970:1_000_001)).facts.profile,.wavPCM)
        XCTAssertEqual(try connectedLedger(Data(contentsOf:path)).schema,2)
    }
}


extension SavedAudioImportStoreTests {
    func testConnectedMOVMigrationCutsExactAllocationRevocationAndPostRenameUncertainty() throws {
        // a: expire only AFTER O_EXCL, before create returns its Member.
        // b: revoke at the actual pre-rename authorization guard.
        // c: one-shot .revoked at the post-rename directory sync (disk may be schema2).
        for cut in 0..<3 {
            let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
            var armed = false, hit = false, authorized = true, tick: TimeInterval = 100
            var allocationFD: Int32?, retired = 0, nextCreates = 0, sourceCreates = 0
            var system = SavedAudioImportStorage.System(); system.uptime = {tick}
            system.inspect = {fd,s in
                let result = Darwin.fstat(fd,s)
                if result == 0, armed, allocationFD == nil {
                    var named = stat()
                    if lstat(fixture.root.appendingPathComponent("manifest.next").path,&named) == 0,
                       named.st_dev == s.pointee.st_dev, named.st_ino == s.pointee.st_ino {allocationFD = fd}
                }
                return result
            }
            system.close = {fd in if fd == allocationFD {retired += 1}; return Darwin.close(fd)}
            system.event = {boundary,name in
                guard armed else {return}
                if boundary == .create, name == "manifest.next" {nextCreates += 1}
                if boundary == .create, name?.hasSuffix(".source.pending") == true {sourceCreates += 1}
                guard !hit else {return}
                if cut == 0, boundary == .created, name == "manifest.next" {hit = true; tick = 131}
                if cut == 1, boundary == .rename, name == "manifest.next" {hit = true; authorized = false}
                if cut == 2, boundary == .directorySync, name == "manifest.json" {hit = true; throw SavedAudioImportStorage.Failure.revoked}
            }
            let store = SavedAudioImportStore(storage:fixture.storage(system:system))
            defer {armed = false; connectedPreserve(fixture,store)}
            let token = try wav.admit(store), now = Date(timeIntervalSince1970:1_000_001)
            let accepted = try store.saveResult(token,resultID:UUID(),bytes:Data("unchanged linked result".utf8),observed:.init(observed:nil),now:now,authorized:{true})
            try store.association(token.job,resultID:accepted.id,state:.saved,now:now,authorized:{true})
            let path = fixture.root.appendingPathComponent("manifest.json"), before = try Data(contentsOf:path), old = try connectedLedger(before)
            let oldJob = try XCTUnwrap(old.jobs.first), sourceName = oldJob.source.final, textName = (try XCTUnwrap(oldJob.accepted)).id.uuidString.lowercased()+".raw.txt"
            let sourceBytes = try Data(contentsOf:fixture.root.appendingPathComponent(sourceName)), textBytes = try Data(contentsOf:fixture.root.appendingPathComponent(textName))
            armed = true
            XCTAssertThrowsError(try mov.admit(store,started:100,authorized:{authorized})) {error in
                XCTAssertEqual(error as? SavedAudioImportStorage.Failure,cut == 0 ? .bounds : .revoked)
            }
            // Test the fd BEFORE subsequent filesystem helpers can reuse its integer.
            if cut == 0 {
                let fd = try XCTUnwrap(allocationFD); XCTAssertEqual(retired,1)
                errno = 0; XCTAssertEqual(fcntl(fd,F_GETFD),-1); XCTAssertEqual(errno,EBADF)
            }
            XCTAssertTrue(hit); XCTAssertEqual(nextCreates,1); XCTAssertEqual(sourceCreates,0)
            XCTAssertEqual(store.failure,.uncertain)
            armed = false
            let disk = try Data(contentsOf:path), onDisk = try connectedLedger(disk)
            XCTAssertEqual(onDisk.jobs,[oldJob]); XCTAssertEqual(onDisk.owner,old.owner); XCTAssertEqual(onDisk.root,old.root)
            XCTAssertEqual(onDisk.schema,cut == 2 ? 2 : 1)
            if cut != 2 {XCTAssertEqual(disk,before)}
            let next = fixture.root.appendingPathComponent("manifest.next")
            XCTAssertEqual(FileManager.default.fileExists(atPath:next.path),cut == 0)
            if cut == 0 {XCTAssertEqual(try Data(contentsOf:next),Data())}
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(sourceName)),sourceBytes)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(textName)),textBytes)
            XCTAssertEqual(store.rows().map(\.id),[token.job]) // No MOV token/job/payload grant.
            XCTAssertThrowsError(try store.begin(token.job,requested:wav.requested,now:now,authorized:{true}))
            XCTAssertThrowsError(try mov.admit(store))
            try store.close()
            let reopened = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,reopened)}
            if cut == 0 {
                XCTAssertThrowsError(try reopened.bootstrap())
                XCTAssertEqual(try Data(contentsOf:next),Data()) // Unknown next is preserved, never salvaged.
            } else {
                XCTAssertEqual(try reopened.bootstrap().map(\.id),[token.job])
                XCTAssertEqual(try reopened.openResult(token.job,now:now).1,textBytes)
                XCTAssertEqual(try connectedLedger(Data(contentsOf:path)).schema,cut == 2 ? 2 : 1)
            }
        }
    }

    func testConnectedMOVMigrationCutsFinitePerMemberPublicationSchedule() throws {
        let cuts: [(SavedAudioImportStorage.Boundary,String)] = [
            (.create,"manifest.next"),(.created,"manifest.next"),(.write,"manifest.next"),
            (.fileSync,"manifest.next"),(.close,"manifest.next"),(.verify,"manifest.next"),
            (.payloadRead,"manifest.next"),(.hash,"manifest.next"),(.rename,"manifest.next"),(.directorySync,"manifest.json")]
        for (boundary,member) in cuts {
            let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
            var armed = false, hit = false, occurrence = 0, movAllocations = 0
            var system = SavedAudioImportStorage.System()
            system.event = {at,name in
                guard armed else {return}
                if at == .create, name?.hasSuffix(".source.pending") == true {movAllocations += 1}
                if at == boundary, name == member {
                    occurrence += 1
                    if occurrence == 1 {hit = true; throw SavedAudioImportStorage.Failure.io}
                }
            }
            let store = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {armed = false; connectedPreserve(fixture,store)}
            let token = try wav.admit(store); try store.finish(token,canceled:false)
            let path = fixture.root.appendingPathComponent("manifest.json"), before = try Data(contentsOf:path), old = try connectedLedger(before)
            armed = true; XCTAssertThrowsError(try mov.admit(store)); armed = false
            XCTAssertTrue(hit,"\(boundary):\(member)#1"); XCTAssertEqual(occurrence,1); XCTAssertEqual(movAllocations,0)
            XCTAssertEqual(store.failure,.uncertain)
            let disk = try Data(contentsOf:path), next = try connectedLedger(disk)
            XCTAssertEqual(next.jobs,old.jobs); XCTAssertEqual(next.owner,old.owner); XCTAssertEqual(next.root,old.root)
            XCTAssertEqual(next.schema,boundary == .directorySync ? 2 : 1)
            if boundary != .directorySync {XCTAssertEqual(disk,before)}
            // This exact schedule's cleanup rules, independent of the mere throw.
            let shouldRetainNext = [SavedAudioImportStorage.Boundary.created,.close,.rename].contains(boundary)
            XCTAssertEqual(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("manifest.next").path),shouldRetainNext && boundary != .directorySync)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(old.jobs[0].source.final)),wav.bytes)
        }
        // Complete rename AND actual directory fsync before faulting only the
        // final named manifest readback's temporary descriptor close.
        do {
            let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
            let manifest = fixture.root.appendingPathComponent("manifest.json")
            var armed = false, pendingSync = false, synced = false, hit = false
            var finalReadFD: Int32?, readbackCloses = 0, movAllocations = 0
            var system = SavedAudioImportStorage.System()
            system.event = {boundary,name in
                guard armed else {return}
                if boundary == .directorySync, name == "manifest.json" {pendingSync = true}
                if boundary == .create, name?.hasSuffix(".source.pending") == true {movAllocations += 1}
            }
            system.sync = {fd in
                let status = Darwin.fsync(fd)
                if armed, pendingSync, status == 0 {pendingSync = false; synced = true}
                return status
            }
            system.inspect = {fd,value in
                let status = Darwin.fstat(fd,value)
                if status == 0, armed, synced, finalReadFD == nil, value.pointee.st_mode & S_IFMT == S_IFREG {
                    var named = stat()
                    if lstat(manifest.path,&named) == 0, named.st_dev == value.pointee.st_dev, named.st_ino == value.pointee.st_ino {finalReadFD = fd}
                }
                return status
            }
            system.close = {fd in
                let status = Darwin.close(fd)
                if armed, fd == finalReadFD {
                    readbackCloses += 1
                    if !hit {hit = true; errno = EIO; return -1}
                }
                return status
            }
            let store = SavedAudioImportStore(storage:fixture.storage(system:system))
            defer {armed = false; connectedPreserve(fixture,store)}
            let token = try wav.admit(store), now = Date(timeIntervalSince1970:1_000_001)
            _ = try store.saveResult(token,resultID:UUID(),bytes:Data("preserved readback result".utf8),observed:.init(observed:nil),now:now,authorized:{true})
            let before = try connectedLedger(Data(contentsOf:manifest)), oldJob = try XCTUnwrap(before.jobs.first)
            let textName = (try XCTUnwrap(oldJob.accepted)).id.uuidString.lowercased()+".raw.txt"
            let oldSource = try Data(contentsOf:fixture.root.appendingPathComponent(oldJob.source.final))
            let oldText = try Data(contentsOf:fixture.root.appendingPathComponent(textName))
            armed = true; XCTAssertThrowsError(try mov.admit(store))
            XCTAssertTrue(synced); XCTAssertTrue(hit); XCTAssertEqual(readbackCloses,1)
            let fd = try XCTUnwrap(finalReadFD)
            errno = 0; XCTAssertEqual(fcntl(fd,F_GETFD),-1); XCTAssertEqual(errno,EBADF)
            armed = false
            XCTAssertEqual(store.failure,.uncertain); XCTAssertEqual(movAllocations,0)
            let disk = try connectedLedger(Data(contentsOf:manifest))
            XCTAssertEqual(disk.schema,2); XCTAssertEqual(disk.jobs,before.jobs)
            XCTAssertEqual(disk.owner,before.owner); XCTAssertEqual(disk.root,before.root)
            XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("manifest.next").path))
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(oldJob.source.final)),oldSource)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(textName)),oldText)
            XCTAssertEqual(store.rows().map(\.id),[token.job])
            XCTAssertThrowsError(try store.begin(token.job,requested:wav.requested,now:now,authorized:{true}))
            XCTAssertThrowsError(try mov.admit(store))
        }

    }

    func testConnectedMOVMigrationPreflightHeadroomBudgetAndUnknownNamespacePreserveSchema1() throws {
        for cut in 0..<4 {
            let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
            var armed = false, allocations = 0; var system = SavedAudioImportStorage.System()
            system.freeBytes = {_ in armed && cut == 0 ? 0 : Int64.max}
            system.event = {boundary,name in if armed, boundary == .create, name == "manifest.next" {allocations += 1}}
            let store = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {armed = false; connectedPreserve(fixture,store)}
            let token = try wav.admit(store); try store.finish(token,canceled:true)
            let path = fixture.root.appendingPathComponent("manifest.json"), before = try Data(contentsOf:path)
            if cut == 2 {try Data([17]).write(to:fixture.root.appendingPathComponent("manifest.next"),options:[]); XCTAssertEqual(chmod(fixture.root.appendingPathComponent("manifest.next").path,0o600),0)}
            if cut == 3 {try Data([29]).write(to:fixture.root.appendingPathComponent("unexplained")); XCTAssertEqual(chmod(fixture.root.appendingPathComponent("unexplained").path,0o600),0)}
            armed = true; XCTAssertThrowsError(try mov.admit(store,credits:cut == 1 ? 65_500 : 0)); armed = false
            XCTAssertEqual(allocations,0); XCTAssertEqual(try Data(contentsOf:path),before)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.wav")),wav.bytes)
            if cut == 2 {XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent("manifest.next")),Data([17]))}
            if cut == 3 {XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent("unexplained")),Data([29]))}
        }
    }

    func testConnectedMOVMixedJobsQuotaExpiryMissingSourceAndHashRefusal() throws {
        let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
        let store = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,store)}
        let old = try wav.admit(store), now = Date(timeIntervalSince1970:1_000_001)
        _ = try store.saveResult(old,resultID:UUID(),bytes:Data("WAV result".utf8),observed:.init(observed:nil),now:now,authorized:{true})
        let token = try mov.admit(store)
        _ = try store.saveResult(token,resultID:UUID(),bytes:Data("MOV result".utf8),observed:.init(observed:nil),now:now,authorized:{true})
        let expiry = try XCTUnwrap(store.rows().first(where:{$0.id == token.job})?.expires)
        let fresh = try store.begin(token.job,requested:mov.requested,now:now,authorized:{true})
        XCTAssertEqual(store.rows().first(where:{$0.id == token.job})?.expires,expiry)
        let source = fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")
        var corrupt = mov.bytes; corrupt[32] ^= 1; try corrupt.write(to:source)
        XCTAssertThrowsError(try store.sourceSnapshot(fresh,now:now))
        XCTAssertThrowsError(try store.openResult(old.job,now:now)) // Changed member freezes the shared metadata projection.
        XCTAssertEqual(unlink(source.path),0)
        XCTAssertEqual(try store.openResult(old.job,now:now).1,Data("WAV result".utf8))
        XCTAssertThrowsError(try store.sourceSnapshot(fresh,now:now))
        XCTAssertEqual(try store.openResult(token.job,now:now).1,Data("MOV result".utf8))
        try store.finish(fresh,canceled:true)
        for _ in 0..<8 {let t = try mov.admit(store); try store.finish(t,canceled:true)}
        XCTAssertEqual(store.rows().count,10)
        let ids = store.rows().map(\.id); XCTAssertThrowsError(try mov.admit(store)); XCTAssertEqual(store.rows().map(\.id),ids)
        XCTAssertThrowsError(try store.sourceSnapshot(fresh,now:expiry))
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:wav.original.lexical)),wav.bytes)
    }
}


extension SavedAudioImportStoreTests {
    func testConnectedMOVSchemaLegacyWAVFactsRemainLooseAcrossMetadataProjectionAndRetry() throws {
        let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture,frames:40000)
        let store = SavedAudioImportStore(storage:fixture.storage()), token = try input.admit(store)
        try store.finish(token,canceled:true); try store.close()
        let path = fixture.root.appendingPathComponent("manifest.json")
        var doc = try connectedDocument(Data(contentsOf:path)), jobs = try XCTUnwrap(doc["jobs"] as? [[String:Any]])
        // These old numeric predicates deliberately do not assert converter output
        // floor/ceil or equality to a later decode. Keep their old acceptance.
        jobs[0]["facts"] = ["rate":44100,"frames":17641,"outputFrames":6401,"clipped":5]
        doc["jobs"] = jobs
        let legacy = try JSONSerialization.data(withJSONObject:doc,options:[.sortedKeys]); try legacy.write(to:path)
        let reopened = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,reopened)}
        XCTAssertEqual(try reopened.bootstrap().count,1); XCTAssertEqual(try Data(contentsOf:path),legacy)
        let before = try connectedLedger(legacy), oldJob = before.jobs[0], mov = try ConnectedMOVInput(fixture)
        _ = try mov.admit(reopened)
        let mixed = try connectedLedger(Data(contentsOf:path)); XCTAssertEqual(mixed.schema,2); XCTAssertEqual(mixed.jobs[0],oldJob)
        // Settle MOV before the ordinary WAV retry; do not mutate old WAV facts.
        let movRow = try XCTUnwrap(reopened.rows().last)
        let movToken = try reopened.begin(movRow.id,requested:mov.requested,now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
        try reopened.finish(movToken,canceled:true)
        let fresh = try reopened.begin(token.job,requested:input.requested,now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
        let snapshot = try reopened.sourceSnapshot(fresh,now:Date(timeIntervalSince1970:1_000_001))
        XCTAssertEqual(snapshot.facts,oldJob.facts); XCTAssertEqual(snapshot.facts.profile,.wavPCM)
        XCTAssertEqual(try ImportedAudio.decodeSource(snapshot.bytes,format:.wav).samples.count,40000)
        XCTAssertEqual(snapshot.facts.outputFrames,6401); XCTAssertEqual(snapshot.facts.clipped,5)
    }

    func testConnectedMOVMigrationBoundsRevisionAndProspectiveQuotaRefuseBeforePublication() throws {
        for cut in 0..<2 {
            let fixture = try SavedImportFixture(), input = try SavedFixtureInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
            if cut == 0 {let token = try input.admit(store); try store.finish(token,canceled:true)}
            else {for _ in 0..<10 {let token = try input.admit(store); try store.finish(token,canceled:true)}}
            try store.close()
            let path = fixture.root.appendingPathComponent("manifest.json")
            if cut == 0 {
                var doc = try connectedDocument(Data(contentsOf:path)); doc["revision"] = UInt64.max
                try JSONSerialization.data(withJSONObject:doc,options:[.sortedKeys]).write(to:path)
            }
            let before = try Data(contentsOf:path), mov = try ConnectedMOVInput(fixture)
            var writes = 0; var system = SavedAudioImportStorage.System()
            system.event = {boundary,name in if boundary == .create, name == "manifest.next" {writes += 1}}
            let reopened = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {connectedPreserve(fixture,reopened)}
            _ = try reopened.bootstrap(); XCTAssertThrowsError(try mov.admit(reopened))
            XCTAssertEqual(writes,0); XCTAssertEqual(try Data(contentsOf:path),before)
            XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("manifest.next").path))
        }
    }
}


extension SavedAudioImportStoreTests {
    func testConnectedMOVMigrationSerializedActiveAndPendingMatrixNeverRepairsOrPublishes() throws {
        for cut in 0..<7 {
            let fixture = try SavedImportFixture(), wav = try SavedFixtureInput(fixture), mov = try ConnectedMOVInput(fixture)
            let store = SavedAudioImportStore(storage:fixture.storage()), token = try wav.admit(store)
            _ = try store.saveResult(token,resultID:UUID(),bytes:Data("old linked text".utf8),observed:.init(observed:nil),now:Date(timeIntervalSince1970:1_000_000),authorized:{true})
            try store.close()
            let path = fixture.root.appendingPathComponent("manifest.json")
            var doc = try connectedDocument(Data(contentsOf:path)), jobs = try XCTUnwrap(doc["jobs"] as? [[String:Any]])
            var job = jobs[0]
            switch cut {
            case 0: job["state"] = "queued"
            case 1: job["state"] = "running"
            case 2: job["state"] = "staging"
            case 3: job["state"] = "deleting"
            case 4: job["candidate"] = job.removeValue(forKey:"accepted")
            case 5:
                let accepted = try XCTUnwrap(job.removeValue(forKey:"accepted") as? [String:Any]); job["retired"] = accepted["payload"]
            default: job["state"] = "deleting"; job["resourcesRetired"] = true
            }
            jobs[0] = job; doc["jobs"] = jobs
            let before = try JSONSerialization.data(withJSONObject:doc,options:[.sortedKeys]); try before.write(to:path)
            let names = try FileManager.default.contentsOfDirectory(atPath:fixture.root.path).sorted()
            var publications = 0; var system = SavedAudioImportStorage.System()
            system.event = {boundary,name in if boundary == .create, name == "manifest.next" {publications += 1}}
            let reopened = SavedAudioImportStore(storage:fixture.storage(system:system)); defer {connectedPreserve(fixture,reopened)}
            if cut == 6 {XCTAssertThrowsError(try reopened.bootstrap())}
            else {_ = try reopened.bootstrap()}
            XCTAssertThrowsError(try mov.admit(reopened),"active/pending cut \(cut)")
            XCTAssertEqual(publications,0); XCTAssertEqual(try Data(contentsOf:path),before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:fixture.root.path).sorted(),names)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.wav")),wav.bytes)
        }
    }
    func testConnectedMOVSchemaOversizedManifestAndAcceptedHashBindingsPreserveInvalidBytes() throws {
        for cut in 0..<4 {
            let fixture = try SavedImportFixture(), mov = try ConnectedMOVInput(fixture), store = SavedAudioImportStore(storage:fixture.storage())
            let token = try mov.admit(store)
            _ = try store.saveResult(token,resultID:UUID(),bytes:Data("MOV linked result".utf8),observed:.init(observed:nil),now:Date(timeIntervalSince1970:1_000_001),authorized:{true})
            try store.close()
            let path = fixture.root.appendingPathComponent("manifest.json")
            var doc = try connectedDocument(Data(contentsOf:path)), jobs = try XCTUnwrap(doc["jobs"] as? [[String:Any]])
            var accepted = try XCTUnwrap(jobs[0]["accepted"] as? [String:Any])
            if cut == 0 {accepted["sourceHash"] = String(repeating:"0",count:64)}
            if cut == 1 {accepted["sourceGeneration"] = UUID().uuidString}
            if cut == 2 {doc["unknown"] = true}
            jobs[0]["accepted"] = accepted; doc["jobs"] = jobs
            let invalid = cut == 3 ? Data(repeating:32,count:65_537) : try JSONSerialization.data(withJSONObject:doc,options:[.sortedKeys])
            try invalid.write(to:path)
            let reopened = SavedAudioImportStore(storage:fixture.storage()); defer {connectedPreserve(fixture,reopened)}
            XCTAssertThrowsError(try reopened.bootstrap()); XCTAssertEqual(try Data(contentsOf:path),invalid)
            XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")),mov.bytes)
        }
    }
}
