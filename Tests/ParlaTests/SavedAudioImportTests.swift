import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import Parla
@testable import ParlaCore

func retainedSyntheticWAV() -> Data {
    func le(_ n:Int,_ count:Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
    let pcm = (0..<8000).reduce(into:Data()) { $0 += le($1 % 2 == 0 ? 16_000 : -16_000,2) }
    let fmt = le(1,2)+le(1,2)+le(16_000,4)+le(32_000,4)+le(2,2)+le(16,2)
    let chunks = Data("fmt ".utf8)+le(16,4)+fmt+Data("JUNK".utf8)+le(4,4)+Data([11,23,37,47])+Data("data".utf8)+le(pcm.count,4)+pcm
    return Data("RIFF".utf8)+le(chunks.count+4,4)+Data("WAVE".utf8)+chunks
}
final class SavedImportOutputs {var copies:[String] = []}
final class SavedRecordingPorts {
    var accesses:[RecordingStore.Access] = [], writes = 0, removes = 0
    func reset() {accesses = []; writes = 0; removes = 0}
}
final class SavedImportFaults: @unchecked Sendable {
    var resultWriteFails = false, receiptWriteFails = false, historyWritesFail = false, historyWrites = 0
    var boundary: SavedAudioImportStorage.Boundary?, payloadReads = 0, hashes = 0
    var sourceReads = 0, resultReads = 0, factoryEntries = 0
    var event: ((SavedAudioImportStorage.Boundary,String?) throws -> Void)?
    var reached: ((SavedAudioImportStorage.Boundary) -> Void)?
    var closeBorrowFails = false, closeNext = false
}
final class SavedImportClock { var value = Date(timeIntervalSince1970:2_000_000) }
@MainActor final class SavedImportRig {
    let root:URL, settings:SettingsStore, history:HistoryStore, hub:HubModel, saved:SavedAudioImportOwner
    let transient = AudioImportOwner(), native = FoundationNativeProbe(), admission = LocalCleanupAdmission(), credentials = FakeCredentialBackend()
    let outputs = SavedImportOutputs(), recordingPorts = SavedRecordingPorts()
    let recordings:RecordingStore
    var factoryProvider:(() -> RecognitionFactory)?
    var enter:() async throws -> Void = {}
    var copies:[String] {outputs.copies}
    var chain:Task<Void,Never>?, originalReads = 0, payloadReads = 0, written:[Data] = []
    var failure:SavedAudioImportStorage.Boundary?, historyFails = false
    private let testClock = SavedImportClock()
    var now: Date { get {testClock.value} set {testClock.value = newValue} }
    let inode:UInt64
    let faults: SavedImportFaults
    init(faults: SavedImportFaults = .init(), keepAll: Bool = false) throws {
        self.faults = faults
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil)); defer {free(physical)}
        root = URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("wave7e1-saved-app-\(UUID().uuidString.lowercased())")
        guard mkdir(root.path,0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var st = stat(); XCTAssertEqual(lstat(root.path,&st),0); inode = st.st_ino
        try recordWave4BFixture(root,"created")
        let stamp = try JSONSerialization.data(withJSONObject:["uid":st.st_uid,"device":st.st_dev,"inode":st.st_ino,"mode":st.st_mode,"birthSec":st.st_birthtimespec.tv_sec,"birthNS":st.st_birthtimespec.tv_nsec,"mtimeSec":st.st_mtimespec.tv_sec,"mtimeNS":st.st_mtimespec.tv_nsec],options:[.sortedKeys])
        try recordWave4BFixture(root,"identity:"+String(decoding:stamp,as:UTF8.self))
        settings = SettingsStore(url:root.appendingPathComponent("settings.json"),credentials:CredentialStore(backend:credentials))
        var value = Settings(); value.whisperModelPath = "/fake/global.bin"; value.language = "hi"; value.dictionary = ["Parla"]
        try settings.save(value)
        history = HistoryStore(url:root.appendingPathComponent("history.json"),persistence:.init(writeAtomically:{ data,url in
            faults.historyWrites += 1
            if faults.historyWritesFail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to:url,options:.atomic)
        }))
        var system = SavedAudioImportStorage.System()
        system.event = { boundary,name in
            if boundary == .payloadRead, let name {
                if name.hasSuffix(".source.wav") || name.hasSuffix(".source.mov") || name.hasSuffix(".source.pending") {faults.sourceReads += 1}
                if name.hasSuffix(".raw.txt") || name.hasSuffix(".result.pending") {faults.resultReads += 1}
            }
            try faults.event?(boundary,name)
        }
        system.checkpoint = { boundary in
            if boundary == .payloadRead { faults.payloadReads += 1 }
            if boundary == .hash { faults.hashes += 1 }
            if boundary == .borrowRelease && faults.closeBorrowFails {faults.closeBorrowFails = false; faults.closeNext = true}
            faults.reached?(boundary)
            if faults.boundary == boundary { faults.boundary = nil; throw SavedAudioImportStorage.Failure.io }
        }
        system.close = {fd in
            let result = Darwin.close(fd)
            if faults.closeNext {faults.closeNext = false; errno = EIO; return -1}
            return result
        }
        system.write = { fd,bytes,count in
            if faults.receiptWriteFails, String(decoding:Data(bytes:bytes,count:count),as:UTF8.self).contains("\"association\":\"saved\"") {
                faults.receiptWriteFails = false; errno = ENOSPC; return -1
            }
            if faults.resultWriteFails, count == 15, Data(bytes:bytes,count:count) == Data("native original".utf8) {
                faults.resultWriteFails = false; errno = ENOSPC; return -1
            }
            return Darwin.write(fd,bytes,count)
        }
        let clock = testClock
        saved = SavedAudioImportOwner(root:root.appendingPathComponent("saved-imports"),system:system,clock:{clock.value})
        transient.savedImports = saved
        let ports = recordingPorts
        try FileManager.default.createDirectory(at:root.appendingPathComponent("recordings"),withIntermediateDirectories:false)
        recordings = RecordingStore(directory:root.appendingPathComponent("recordings"),keepAll:keepAll,
            access:{ports.accesses.append($0)},writer:{samples,url in
                ports.writes += 1; try savedRecordingWAV(frames:samples.count).write(to:url)
            },remover:{url in ports.removes += 1; try FileManager.default.removeItem(at:url)})
        let outputs = outputs
        hub = HubModel(store:settings,history:history,clipboard:{outputs.copies.append($0)},recordings:recordings,audioImport:transient)
        transient.security = { false }
        transient.sourceAccess.start = { _ in false }; transient.sourceAccess.stop = { _ in XCTFail("unacquired scope stopped") }
        transient.sourceAccess.read = { [unowned self] fd,bytes,count in self.originalReads += 1; return Darwin.read(fd,bytes,count) }
        hub.audioImportExportPanel = { _ in nil }
        hub.historyExportWriter = { [unowned self] bytes,_ in self.written.append(bytes) }
        hub.retryFactory = { _,_,_,_ in XCTFail("Saved import entered cleanup"); throw CancellationError() }
        hub.onSaved = { XCTFail("Saved import flushed settings") }
        hub.onDownloadModel = { _ in XCTFail("Saved import entered downloads") }
        bind()
        hub.refreshAudioImportConfiguration()
    }
    func bind() {
        saved.enqueue = { [unowned self] job,done in
            let next = SavedAudioImportExecution.enqueue(previous:self.chain,admission:self.admission,store:self.saved.store,
                job:job,settings:self.settings,now:{self.now},enter:self.enter,load:{request in
                    self.faults.factoryEntries += 1
                    let factory = await MainActor.run {self.factoryProvider?() ?? self.native.factory()}
                    return try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,
                        selectionEpoch:job.authority.selectionEpoch,preparationEpoch:job.authority.preparationEpoch)
                },done:done)
            if let next { self.chain = next }; return next
        }
    }
    func ready() async { await saved.drain() }
    func source() throws -> URL { let url = root.appendingPathComponent("original.wav"); try retainedSyntheticWAV().write(to:url); return url }
    func run() async throws -> URL {
        await ready(); let url = try source(); hub.selectAudioImport(url); hub.keepAudioImportAndTranscribe(); await chain?.value; await saved.drain(); return url
    }
    func close() async throws {
        saved.invalidate(); transient.invalidate(); await chain?.value; await saved.drain(); try saved.store.close()
        XCTAssertEqual(credentials.reads+credentials.statuses+credentials.adds+credentials.updates+credentials.deletes,0)
        var st = stat(); XCTAssertEqual(lstat(root.path,&st),0); XCTAssertEqual(st.st_ino,inode)
        try recordWave4BFixture(root,"closed")
    }
}
final class SavedAudioImportTests: XCTestCase {
    @MainActor func testExplicitRetainedActionReachesActualFactoryAndReopensWithoutASR() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertTrue(rig.native.paths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
        let url = try rig.source(), original = try Data(contentsOf:url)
        rig.hub.selectAudioImport(url); XCTAssertEqual(rig.originalReads,0)
        rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.native.calls.count,1); XCTAssertEqual(rig.native.admissions,1)
        let review = try XCTUnwrap(rig.saved.review,rig.saved.message ?? "no review")
        XCTAssertNotNil(review.accepted,rig.saved.message ?? "not saved")
        XCTAssertEqual(review.text,"native original")
        XCTAssertEqual(try Data(contentsOf:url),original)
        let row = try XCTUnwrap(rig.saved.rows.first)
        let sourceID = try XCTUnwrap(rig.saved.job?.token?.source)
        XCTAssertEqual(try Data(contentsOf:rig.saved.store.storage.root.appendingPathComponent(sourceID.uuidString.lowercased()+".source.wav")),original)
        XCTAssertTrue(rig.history.entries.isEmpty)
        let reads = rig.originalReads
        rig.hub.discardAudioImport(); XCTAssertNil(rig.saved.review)
        rig.hub.openSavedAudioImport(row.id); await rig.saved.drain()
        XCTAssertEqual(rig.saved.review?.text,"native original"); XCTAssertEqual(rig.native.calls.count,1); XCTAssertEqual(rig.originalReads,reads)
        try await rig.close()
    }
    @MainActor func testSavedTextExportFreezesReviewAndGuardsHardlinkBeforeInjectedWriter() async throws {
        let rig = try SavedImportRig(), original = try await rig.run()
        let safe = rig.root.appendingPathComponent("review.txt"), alias = rig.root.appendingPathComponent("original-hardlink.txt")
        XCTAssertEqual(link(original.path,alias.path),0)
        rig.hub.audioImportExportPanel = { _ in alias }; rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty)
        rig.hub.audioImportExportPanel = { _ in safe }; rig.hub.exportSavedAudioImportText()
        XCTAssertEqual(rig.written,[Data("native original".utf8)])
        rig.written = []
        rig.hub.audioImportExportPanel = { _ in rig.hub.discardAudioImport(); return safe }
        rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty)
        XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
    @MainActor func testManualRetryUsesOwnedBytesAndFreshSavedGlobals() async throws {
        let rig = try SavedImportRig(), original = try await rig.run(), id = try XCTUnwrap(rig.saved.rows.first?.id)
        try Data("outside original changed".utf8).write(to:original)
        var value = try rig.settings.savedRetrySnapshot(); value.language = "en"; value.dictionary = ["Fresh"]
        try rig.settings.save(value)
        rig.hub.refreshAudioImportConfiguration()
        let reads = rig.originalReads
        rig.hub.retrySavedAudioImport(id); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.native.calls.count,2); XCTAssertEqual(rig.native.calls.last?.language,"en"); XCTAssertEqual(rig.native.calls.last?.prompt,"Fresh")
        XCTAssertEqual(rig.originalReads,reads); XCTAssertEqual(try Data(contentsOf:original),Data("outside original changed".utf8))
        try await rig.close()
    }
    @MainActor func testHistoryAssociationSurvivesReopenAndDoesNotResurrectDeletedRow() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run()
        let id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertEqual(rig.history.entries.count,1,rig.saved.message ?? "no status")
        XCTAssertTrue(rig.saved.review?.historySaved == true)
        rig.history.clear()
        rig.hub.discardAudioImport(); rig.hub.openSavedAudioImport(id); await rig.saved.drain()
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
    @MainActor func testDeleteLeavesOriginalAndIndependentHistory() async throws {
        let rig = try SavedImportRig(), original = try await rig.run(), id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        rig.hub.deleteSavedAudioImport(id); await rig.saved.drain()
        XCTAssertTrue(rig.saved.rows.isEmpty,rig.saved.message ?? "no status")
        XCTAssertEqual(try Data(contentsOf:original),retainedSyntheticWAV()); XCTAssertEqual(rig.history.entries.count,1)
        try await rig.close()
    }
}


extension SavedAudioImportTests {
    @MainActor func testResultStorageRetryUsesSameIdentityAndZeroSourceOrASR() async throws {
        let faults = SavedImportFaults(); faults.resultWriteFails = true
        let rig = try SavedImportRig(faults:faults); _ = try await rig.run()
        let review = try XCTUnwrap(rig.saved.review,rig.saved.message ?? "no review")
        XCTAssertNil(review.accepted); let id = review.resultID, bytes = review.bytes, reads = rig.originalReads, sourceReads = faults.sourceReads, resultReads = faults.resultReads
        rig.hub.retrySaveAudioImportResult(); await rig.saved.drain()
        XCTAssertEqual(rig.saved.review?.accepted?.id,id,rig.saved.message ?? "not saved")
        XCTAssertEqual(rig.saved.review?.bytes,bytes); XCTAssertEqual(rig.originalReads,reads); XCTAssertEqual(rig.native.calls.count,1)
        // Payload verification of the same result is expected; source isn't reopened.
        XCTAssertEqual(faults.sourceReads,sourceReads)
        XCTAssertGreaterThan(faults.resultReads,resultReads); XCTAssertEqual(faults.factoryEntries,1)
        try await rig.close()
    }
    @MainActor func testHistoryFailureRetainsCurrentReviewAndRetryDoesNoRecognition() async throws {
        let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults); _ = try await rig.run()
        faults.historyWritesFail = true
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertTrue(rig.saved.review?.historyFailed == true)
        faults.historyWritesFail = false
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertEqual(rig.history.entries.count,1); XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
    @MainActor func testProtectionLookupHasNoPayloadOrHashAndUnknownRootBlocksAllWriters() async throws {
        let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults); _ = try await rig.run()
        let payloads = faults.payloadReads, hashes = faults.hashes
        _ = try rig.saved.store.protection()
        XCTAssertEqual(faults.payloadReads,payloads); XCTAssertEqual(faults.hashes,hashes)
        let unknown = rig.saved.store.storage.root.appendingPathComponent("unclassified")
        try Data([41]).write(to:unknown)
        rig.hub.audioImportExportPanel = { _ in rig.root.appendingPathComponent("out.txt") }
        rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty)
        XCTAssertEqual(try Data(contentsOf:unknown),Data([41]))
        try await rig.close()
    }
}


extension SavedAudioImportTests {
    @MainActor func testHistoryReceiptRetryNeverAppendsAgainEvenIfRowWasDeleted() async throws {
        let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults); _ = try await rig.run()
        faults.receiptWriteFails = true
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertEqual(rig.history.entries.count,1); XCTAssertTrue(rig.saved.review?.historySaved == true); XCTAssertTrue(rig.saved.review?.recordFailed == true)
        rig.history.clear(); let writes = faults.historyWrites
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertEqual(faults.historyWrites,writes); XCTAssertTrue(rig.saved.review?.recordFailed == false)
        XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
    @MainActor func testRestartedHistoryIntentResolvesExactRowAndForbidsAbsentRowAppend() async throws {
        for existing in [false,true] {
            let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults); rig.now = Date(); _ = try await rig.run()
            let review = try XCTUnwrap(rig.saved.review), id = review.jobID
            if existing {rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()}
            try rig.saved.store.association(id,resultID:review.resultID,state:.savingIntent,now:rig.now,authorized:{true})
            rig.saved.invalidate(); await rig.saved.drain(); try rig.saved.store.close()
            let restarted = SavedAudioImportOwner(root:rig.saved.store.storage.root)
            rig.transient.savedImports = restarted; await restarted.drain()
            rig.hub.openSavedAudioImport(id); await restarted.drain()
            XCTAssertNotNil(restarted.review)
            let writes = faults.historyWrites
            rig.hub.saveSavedAudioImportHistory(); await restarted.drain()
            XCTAssertEqual(rig.history.entries.count,existing ? 1 : 0)
            XCTAssertEqual(faults.historyWrites,writes)
            XCTAssertEqual(restarted.review?.historySaved,existing)
            XCTAssertEqual(rig.native.calls.count,1)
            restarted.invalidate(); await restarted.drain(); try restarted.store.close()
            try await rig.close()
        }
    }
}


extension SavedAudioImportTests {
    @MainActor func testCopyIsConnectedAndExpiryRevokesUntilExplicitMaintenance() async throws {
        let rig = try SavedImportRig(), original = try await rig.run()
        rig.hub.copySavedAudioImport(); XCTAssertEqual(rig.copies,["native original"])
        rig.now = rig.now.addingTimeInterval(604_800)
        rig.hub.copySavedAudioImport(); XCTAssertEqual(rig.copies.count,1); XCTAssertNil(rig.saved.review)
        XCTAssertEqual(rig.saved.rows.count,1) // output boundary doesn't silently run deletion
        rig.hub.refreshSavedAudioImports(); await rig.saved.drain()
        XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertEqual(rig.native.calls.count,1)
        XCTAssertEqual(try Data(contentsOf:original),retainedSyntheticWAV())
        try await rig.close()
    }
    @MainActor func testRetainedShortReadWorkBoundRefusesBeforeParserStageOrASR() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let short = rig.root.appendingPathComponent("short-progress.wav")
        try Data(repeating:0,count:160_000).write(to:short)
        var reads = 0
        rig.transient.sourceAccess.read = {fd,bytes,count in reads += 1; return Darwin.read(fd,bytes,min(1,count))}
        rig.hub.selectAudioImport(short); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertLessThanOrEqual(reads,65_536); XCTAssertGreaterThan(reads,64_000)
        XCTAssertTrue(rig.native.calls.isEmpty); XCTAssertTrue(rig.saved.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
        rig.transient.sourceAccess.read = {Darwin.read($0,$1,$2)}
        let valid = try rig.source(); rig.hub.selectAudioImport(valid); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.native.calls.count,1); XCTAssertNotNil(rig.saved.review?.accepted)
        try await rig.close()
    }
    @MainActor func testSourceLeaseCloseFailureKeepsRawRAMAndVetoesReadiness() async throws {
        let faults = SavedImportFaults(); faults.closeBorrowFails = true
        let rig = try SavedImportRig(faults:faults); _ = try await rig.run()
        XCTAssertEqual(rig.native.calls.count,1)
        XCTAssertEqual(rig.saved.review?.text,"native original"); XCTAssertNil(rig.saved.review?.accepted)
        XCTAssertNil(rig.saved.rows.first?.result)
        rig.hub.copySavedAudioImport(); XCTAssertEqual(rig.copies,["native original"])
        XCTAssertFalse(rig.saved.restartReady()); XCTAssertNotNil(rig.saved.shutdownRefusal)
        rig.saved.invalidate(); await rig.saved.drain()
        XCTAssertThrowsError(try rig.saved.store.close())
        try recordWave4BFixture(rig.root,"close-uncertain") // preserve this deliberate fault root
    }
}

private func savedRecordingWAV(frames:Int) -> Data {
    var bytes = savedRateWAV(16000,frames:frames)
    bytes.removeSubrange(36..<48)
    let size = bytes.count-8
    for i in 0..<4 {bytes[4+i] = UInt8(truncatingIfNeeded:size >> (i*8))}
    return bytes
}
private func savedRateWAV(_ rate:Int, frames:Int) -> Data {
    func le(_ n:Int,_ count:Int) -> Data {Data((0..<count).map {UInt8(truncatingIfNeeded:n >> ($0*8))})}
    var pcm = Data(repeating:0,count:frames*2)
    pcm.withUnsafeMutableBytes {(bytes:UnsafeMutableRawBufferPointer) in for i in 0..<frames {bytes[i*2+1] = 64}}
    let fmt = le(1,2)+le(1,2)+le(rate,4)+le(rate*2,4)+le(2,2)+le(16,2)
    let chunks = Data("fmt ".utf8)+le(16,4)+fmt+Data("JUNK".utf8)+le(4,4)+Data([13,31,59,71])+Data("data".utf8)+le(pcm.count,4)+pcm
    return Data("RIFF".utf8)+le(chunks.count+4,4)+Data("WAVE".utf8)+chunks
}
/// The converter object supplies formats only. Conversion is an authored finite
/// bottom that consumes the real parser input and emits constant synthetic PCM.
private final class SavedFakeConversion {
    var creations = 0, calls = 0, supplied = 0, produced = 0, target = 0
    var beforeReturn:(() -> Void)?
    func native() -> ImportedAudio.Native {
        var value = ImportedAudio.Native()
        value.make = {from,to in
            self.creations += 1; self.produced = 0; self.supplied = 0
            return AVAudioConverter(from:from,to:to)
        }
        value.primeInfo = {_ in .init(leadingFrames:0,trailingFrames:0)}
        value.convert = {_,buffer,input in
            self.calls += 1
            if self.supplied == 0 {
                var status = AVAudioConverterInputStatus.noDataNow
                while let pcm = input(4096,&status) as? AVAudioPCMBuffer {self.supplied += Int(pcm.frameLength)}
                XCTAssertEqual(status,.endOfStream)
            }
            let count = min(Int(buffer.frameCapacity),self.target-self.produced)
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData?[0] {for i in 0..<count {channel[i] = 0.5}}
            self.produced += count; self.beforeReturn?()
            return .init(status:count == 0 ? .endOfStream : .haveData)
        }
        return value
    }
}
extension SavedAudioImportTests {
    @MainActor func testRetainedRealReaderAllSevenRatesPreservesEncodedBytesAndFeedsAuthoredPCM() async throws {
        let rig = try SavedImportRig(); await rig.ready(); let conversion = SavedFakeConversion()
        rig.transient.sourceAccess.conversion = conversion.native()
        rig.native.construct = {XCTAssertTrue(rig.saved.store.rows().contains {$0.sourceAvailable})}
        for rate in [8000,16000,22050,24000,32000,44100,48000] {
            let frames = rate*2/5+1, bytes = savedRateWAV(rate,frames:frames)
            conversion.target = frames*16_000/rate
            let url = rig.root.appendingPathComponent("rate-\(rate).wav"); try bytes.write(to:url)
            rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
            XCTAssertNotNil(rig.saved.review?.accepted,rig.saved.message ?? "no saved result")
            let token = try XCTUnwrap(rig.saved.job?.token)
            XCTAssertEqual(try Data(contentsOf:rig.saved.store.storage.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.wav")),bytes)
            let samples = try XCTUnwrap(rig.native.calls.last?.samples)
            XCTAssertEqual(samples.count,frames*16_000/rate); XCTAssertTrue(samples.allSatisfy {$0 == 0.5})
            XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
        XCTAssertEqual(rig.native.calls.count,7); XCTAssertEqual(conversion.creations,6); XCTAssertEqual(rig.faults.factoryEntries,7)
        try await rig.close()
    }
    @MainActor func testRetainedGrammarRejectsDurationSizeAndIncompleteInputBeforeFactory() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        var converterEntries = 0; var fake = ImportedAudio.Native()
        fake.make = {_,_ in converterEntries += 1; return nil}; rig.transient.sourceAccess.conversion = fake
        for rate in [8000,22050,24000,32000,44100,48000] {
            let url = rig.root.appendingPathComponent("bounds-\(rate).wav")
            // Valid grammar reaches the fake bottom; invalid duration never does.
            for frames in [rate*2/5, min(rate*600,(ImportedWAV.maximumBytes-56)/2)] {
                let bytes = savedRateWAV(rate,frames:frames); try bytes.write(to:url)
                let source = try FileImportSource(url:url,access:rig.transient.sourceAccess)
                let before = converterEntries
                XCTAssertThrowsError(try source.readValidated(retainEncoded:true,canceled:{false}))
                XCTAssertEqual(converterEntries,before+1); XCTAssertTrue(source.isClosed)
            }
            let before = converterEntries
            for bytes in [savedRateWAV(rate,frames:rate*2/5-1),savedRateWAV(rate,frames:rate*600+1),Data(savedRateWAV(rate,frames:rate/2).dropLast())] {
                try bytes.write(to:url)
                rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
            }
            XCTAssertEqual(converterEntries,before)
        }
        let tooLarge = rig.root.appendingPathComponent("cap-plus-one.wav")
        try Data(repeating:0,count:ImportedWAV.maximumBytes+1).write(to:tooLarge)
        rig.hub.selectAudioImport(tooLarge); XCTAssertNil(rig.transient.source)
        XCTAssertEqual(rig.faults.factoryEntries,0); XCTAssertTrue(rig.native.paths.isEmpty); XCTAssertTrue(rig.saved.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
        try await rig.close()
    }
    @MainActor func testSourceCommitRefusalNeverResolvesFactoryAndIntentFailureNeverAppendsHistory() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        rig.faults.event = {boundary,name in if boundary == .allocation && name?.hasSuffix(".source.pending") == true {throw SavedAudioImportStorage.Failure.io}}
        let url = try rig.source(); rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.faults.factoryEntries,0); XCTAssertTrue(rig.native.paths.isEmpty)
        let allocated = try XCTUnwrap(rig.saved.rows.first?.id); rig.faults.event = nil
        rig.hub.deleteSavedAudioImport(allocated); await rig.saved.drain(); XCTAssertTrue(rig.saved.rows.isEmpty)
        rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertNotNil(rig.saved.review?.accepted); XCTAssertEqual(rig.faults.factoryEntries,1)
        var hit = false
        rig.faults.event = {boundary,name in if boundary == .write && name == "manifest.next" && !hit {hit = true; throw SavedAudioImportStorage.Failure.io}}
        let writes = rig.faults.historyWrites, sources = rig.faults.sourceReads, factories = rig.faults.factoryEntries
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertTrue(hit); XCTAssertEqual(rig.faults.historyWrites,writes); XCTAssertTrue(rig.history.entries.isEmpty)
        rig.faults.event = nil; rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertEqual(rig.history.entries.count,1); XCTAssertTrue(rig.saved.review?.historySaved == true)
        XCTAssertEqual(rig.faults.sourceReads,sources); XCTAssertEqual(rig.faults.factoryEntries,factories)
        try await rig.close()
    }
    @MainActor func testSavedModalAuthorityCannotReviveAcrossDraftSecurityExpiryAndFreshOpen() async throws {
        for change in 0..<9 {
            let rig = try SavedImportRig(); var preparation:UUID? = UUID(); rig.hub.audioImportPreparationEpoch = {preparation}
            _ = try await rig.run(); let old = try XCTUnwrap(rig.saved.review), now = rig.now
            rig.hub.onSaved = {}
            rig.hub.audioImportExportPanel = {_ in
                switch change {
                case 0: rig.hub.settings.language = "en"; rig.hub.settings.language = "hi"
                case 1: rig.hub.settings.showHudAlways.toggle(); rig.hub.settings.showHudAlways.toggle()
                case 2: rig.transient.security = {true}
                case 3: rig.transient.observe(.focusSampled(gen:-1,focus:.secure))
                case 4: preparation = UUID()
                case 5: rig.hub.leaveAudioImport()
                case 6: rig.hub.selectAudioImport(rig.root.appendingPathComponent("original.wav"))
                case 7: rig.now = now.addingTimeInterval(604_800)
                default: rig.hub.openSavedAudioImport(old.jobID)
                }
                return rig.root.appendingPathComponent("stale.txt")
            }
            rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty)
            await rig.saved.drain()
            XCTAssertFalse(old.authority.current)
            rig.transient.security = {false}; rig.now = now; preparation = old.authority.preparationEpoch
            rig.hub.flushPendingSave(); rig.hub.refreshAudioImportConfiguration()
            XCTAssertFalse(old.authority.current)
            rig.hub.openSavedAudioImport(old.jobID); await rig.saved.drain()
            if change == 7 {
                // Clock rollback after an observed expiry is deliberately refused.
                XCTAssertNil(rig.saved.review)
            } else {
                let fresh = try XCTUnwrap(rig.saved.review); XCTAssertTrue(fresh !== old)
                rig.hub.audioImportExportPanel = {_ in rig.hub.refreshAudioImportConfiguration(); return rig.root.appendingPathComponent("fresh.txt")}
                rig.hub.exportSavedAudioImportText(); XCTAssertEqual(rig.written,[fresh.bytes])
            }
            XCTAssertEqual(rig.native.calls.count,1); try await rig.close()
        }
    }
    @MainActor func testExportDiskRetryFreezesSameBytesAndSettingsHistoryOffDoNotDeleteSavedJobs() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run(); let review = try XCTUnwrap(rig.saved.review)
        let sources = rig.faults.sourceReads, factory = rig.faults.factoryEntries
        var writes:[Data] = [], fail = true
        rig.hub.audioImportExportPanel = {_ in rig.root.appendingPathComponent("retry.txt")}
        rig.hub.historyExportWriter = {data,_ in writes.append(data); if fail {throw CocoaError(.fileWriteOutOfSpace)}}
        rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.saved.review === review)
        fail = false; rig.hub.exportSavedAudioImportText(); XCTAssertEqual(writes,[review.bytes,review.bytes])
        var settings = try rig.settings.savedRetrySnapshot(); settings.historyEnabled = false; try rig.settings.save(settings)
        rig.hub.refreshAudioImportConfiguration(); rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertEqual(rig.saved.rows.count,1)
        settings.historyEnabled = true; try rig.settings.save(settings); rig.hub.refreshAudioImportConfiguration()
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain(); XCTAssertEqual(rig.history.entries.count,1)
        rig.history.clear(); XCTAssertEqual(rig.saved.rows.count,1)
        XCTAssertEqual(rig.faults.sourceReads,sources); XCTAssertEqual(rig.faults.factoryEntries,factory)
        try await rig.close()
    }
}

extension SavedAudioImportTests {
    @MainActor func testSavedAppleUsesActualInstalledLeaseAndRefusesMissingAssetsWithoutFallback() async throws {
        let rig = try SavedImportRig(); await rig.ready(); let apple = AppleOwnerRig(), session = AppleOriginSession()
        apple.configure(); await apple.wait(); await apple.prepare()
        try rig.settings.save(apple.saved); rig.hub.refreshAudioImportConfiguration()
        rig.enter = {await MainActor.run {apple.owner.deliberateEntry()}}
        rig.factoryProvider = {apple.factory(session)}
        _ = try await rig.run()
        XCTAssertEqual(rig.saved.review?.text,"spoken original"); XCTAssertNotNil(rig.saved.review?.accepted)
        XCTAssertEqual(session.calls,1); XCTAssertTrue(rig.native.paths.isEmpty); XCTAssertFalse(apple.owner.hasWork)
        let id = try XCTUnwrap(rig.saved.rows.first?.id), accepted = try XCTUnwrap(rig.saved.review?.accepted?.id)
        apple.installed = false
        rig.hub.retrySavedAudioImport(id); await rig.chain?.value; await rig.saved.drain()
        XCTAssertNil(rig.saved.review); XCTAssertEqual(session.calls,1); XCTAssertTrue(rig.native.paths.isEmpty)
        XCTAssertEqual(rig.saved.rows.first?.result?.id,accepted)
        rig.hub.openSavedAudioImport(id); await rig.saved.drain(); XCTAssertEqual(rig.saved.review?.text,"spoken original")
        XCTAssertFalse(apple.owner.hasWork); try await rig.close()
    }
    @MainActor func testSavedParakeetGetsFreshOneShotUsesAndKeepsBorrowThroughActualExitAndPipeJoin() async throws {
        let rig = try SavedImportRig(); await rig.ready(); let para = try G2aRig()
        var initial = stat(); XCTAssertEqual(lstat(para.root.path,&initial),0)
        let stamp = try JSONSerialization.data(withJSONObject:["uid":initial.st_uid,"device":initial.st_dev,"inode":initial.st_ino,"mode":initial.st_mode,"birthSec":initial.st_birthtimespec.tv_sec,"birthNS":initial.st_birthtimespec.tv_nsec],options:[.sortedKeys])
        try recordWave4BFixture(para.root,"identity:"+String(decoding:stamp,as:UTF8.self))
        try await para.install(); try await para.prepare()
        try rig.settings.save(para.settings); rig.hub.refreshAudioImportConfiguration()
        rig.enter = {try await MainActor.run {try ParakeetAudioEntry.recovery(RecognitionRequest(settings:para.settings),owner:para.owner)}}
        rig.factoryProvider = {ParakeetAudioEntry.factory(owner:para.owner,bottom:para.factory())}
        let first = G2aChild(text:"first private raw"); para.bottoms.append(first)
        _ = try await rig.run()
        XCTAssertEqual(rig.saved.review?.text,"first private raw"); XCTAssertNotNil(rig.saved.review?.accepted)
        XCTAssertEqual(para.owner.ownership.count,0)
        let id = try XCTUnwrap(rig.saved.rows.first?.id), prior = try XCTUnwrap(rig.saved.rows.first?.result?.id)
        let join = G2aLatch(), joined = G2aLatch(), second = G2aChild(holdExit:true,holdIO:true,join:join,joined:joined,text:"second private raw")
        let watchdog = Task {
            do {try await Task.sleep(nanoseconds:5_000_000_000)} catch {return}
            await second.native.loaded.signal(); await second.native.finishIO(); await second.exit.finish(); await joined.signal(); await join.signal()
        }
        defer {watchdog.cancel()}
        para.bottoms.append(second)
        rig.hub.retrySavedAudioImport(id); await second.native.loaded.wait()
        XCTAssertTrue(rig.saved.busy); XCTAssertEqual(para.owner.ownership.count,1)
        rig.hub.cancelSavedAudioImport(); XCTAssertNil(rig.saved.review)
        await second.native.finishIO()
        XCTAssertTrue(rig.saved.busy); XCTAssertEqual(para.owner.ownership.count,1)
        await second.exit.finish(); await joined.wait()
        XCTAssertTrue(rig.saved.busy); XCTAssertEqual(para.owner.ownership.count,1)
        await join.signal(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertFalse(rig.saved.busy); XCTAssertEqual(para.owner.ownership.count,0)
        XCTAssertEqual(rig.saved.rows.first?.result?.id,prior)
        let third = G2aChild(text:"third private raw"); para.bottoms.append(third)
        rig.hub.retrySavedAudioImport(id); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.saved.review?.text,"third private raw"); XCTAssertEqual(para.bottoms.count,4)
        XCTAssertTrue(rig.native.paths.isEmpty); XCTAssertEqual(para.owner.ownership.count,0)
        // These roots are task-owned synthetic installation files. Leave cleanup
        // to receipt/identity-based resource handling, rather than a prefix sweep.
        try recordWave4BFixture(para.root,"closed")
        try await rig.close()
    }
}

private final class SavedPrivacyProvider: CleanupProviding {
    var calls = 0
    func clean(transcript:String,context:CleanupContext) async throws -> String {calls += 1; return transcript+" cleaned"}
}
private final class SavedPrivacyCapture: MicrophoneTestCapturing {
    var starts = 0, stops = 0, clears = 0
    func start(operation:UUID,lease:CaptureAdmission.Lease) throws {starts += 1}
    func snapshot(operation:UUID) -> MicrophoneCaptureSnapshot? {nil}
    func stop(operation:UUID) -> [Float] {stops += 1; return [Float](repeating:0.5,count:8000)}
    func clear(operation:UUID) {clears += 1}
}
/// Actual production storage, reducer, ordinary finalizer, provider pipeline,
/// History sink, insertion/Original, undo dispatcher and preview controller. Only
/// capture/permission/posting/provider/native bottoms are inert synthetic ports.
@MainActor private final class SavedPrivacyHarness {
    let rig:SavedImportRig, machine = DictationSession(diagnostics:nil), provider = SavedPrivacyProvider(), capture = SavedPrivacyCapture()
    var settings:Settings
    var sessions:[DictationSession.Session] = [], pending:(DictationSession.Session,DictationSession.Landed)?
    var ordinaryEntries:[OrdinaryDictationFinalization.Entry] = [], insertions = 0, corrections = 0, clipboardWrites = 0, captures = 0, finals = 0, providerFactories = 0, previewUpdates = 0
    var now:TimeInterval = 100, deadline:TimeInterval = 0
    let samples = [Float](repeating:0.5,count:8000)
    lazy var historySink = HistoryPersistenceSink(history:rig.history,settings:rig.settings)
    lazy var originals = OriginalCopyController(configuration:{[unowned self] in settings},generation:{[unowned self] in machine.gen},now:{[unowned self] in now},schedule:{_,_ in {}},security:{.safe},copy:{[unowned self] text in clipboardWrites += 1; rig.outputs.copies.append(text)})
    lazy var insertion = DictationInsertionExecutor(originals:originals,post:{[unowned self] _,_,dispatch in insertions += 1; clipboardWrites += 1; dispatch(); return true},didPost:{[unowned self] _ in corrections += 1})
    lazy var undo = CanceledCaptureUndoController(configuration:{[unowned self] in settings},generation:{[unowned self] in machine.gen},security:{.safe},now:{[unowned self] in now},schedule:{_,_ in {}},copy:{[unowned self] text in clipboardWrites += 1; rig.outputs.copies.append(text)})
    lazy var undoRecognition = CanceledCaptureRecognition(controller:undo,factory:rig.native.factory(),verify:{_ in true})
    lazy var dispatcher = DictationExecutionDispatcher(preview:undoRecognition,ordinary:{[unowned self] session,samples,_ in await ordinary(session,samples:samples)})
    lazy var microphone = MicrophoneTestController(capture:capture,allowed:{true},permission:{true},now:{[unowned self] in now},schedule:{_,_ in {}})
    init() throws {
        rig = try SavedImportRig(keepAll:true)
        settings = try rig.settings.savedRetrySnapshot(); settings.cleanupEnabled = true; settings.outputMode = .cleanup
        settings.keepLastOriginalEnabled = true; settings.canceledCaptureUndoEnabled = true
        try rig.settings.save(settings); rig.hub.refreshAudioImportConfiguration()
        undo.enqueue = {[unowned self] job in rig.chain = dispatcher.enqueue(.canceledCaptureUndo(job),previous:rig.chain)}
    }
    func send(_ event:DictationSession.Event) {
        rig.transient.observe(event); originals.observe(event); undo.observe(event)
        if case .cancelRequested = event {deadline = undo.cancellationDeadline()}
        historySink.beginEvent(for:event,currentGeneration:machine.gen)
        machine.send(event) {effect in
            originals.observe(effect)
            switch effect {
            case .captureAccepted(let session): sessions.append(session); undo.accepted(session,physical:true)
            case .captureAcknowledged(let session): undo.acknowledged(session)
            case .applyPreferencesAndStartCapture: captures += 1
            case .abortOperation(let operation): operation.requestAbort()
            case .transcribeFinal(let session,let ledger): rig.chain = dispatcher.enqueue(.ordinary(session,samples:samples,ledger:ledger),previous:rig.chain)
            case .polish(let session,let landed): pending = (session,landed)
            case .insertText(let text,_,let context): _ = insertion.insert(text,original:context,operation:machine.effectOperation)
            case .appendHistory,.appendTransformHistory: _ = historySink.record(effect,metrics:{nil})
            case .finalResult: finals += 1
            case .cancelCapture(let context): undo.transferred(samples,context:context,deadline:deadline)
            case .presentCanceledCapture(let generation): undo.present(generation:generation)
            default: break
            }
        }
    }
    func start() {
        send(.startDictation(settings:settings,cleanupConfigured:true,live:false))
        send(.recorderStarted(gen:machine.gen)); send(.focusSampled(gen:machine.gen,focus:.editable))
    }
    func ordinary(_ session:DictationSession.Session,samples:[Float]) async {
        let finalizer = OrdinaryDictationFinalization(recordings:rig.recordings,settings:rig.settings,entered:{[unowned self] in ordinaryEntries.append($0)})
        await finalizer.run(operation:session.operation,samples:samples,window:nil,prepare:{recording,_ in
            XCTAssertNotNil(recording,self.rig.recordings.lastError ?? "missing ordinary stash")
            return try? await RecognitionAcquisition.acquire(request:session.recognition,resident:nil,factory:self.rig.native.factory(),operation:session.operation)
        },recognized:{_,raw in
            self.pending = nil; self.send(.transcribed(session,raw:raw,probe:.init(focus:.editable,deferInsertionUntilClean:true)))
            finalizer.resolve(transcript:raw,secure:false); return self.pending
        },clean:{context in
            let pipeline = Pipeline(outputSettings:context.0.effectiveSettings,bundleID:nil,makeClient:{_ in
                self.providerFactories += 1
                XCTAssertEqual(testStoredKey(self.rig.settings.credentials,.anthropic),"synthetic-provider-key")
                return self.provider
            })
            return await pipeline.clean(transcript:context.1.raw)
        },completed:{context,text,failure in
            self.send(.cleanReady(context.0,context.1,text:text,failure:failure,focus:.editable))
        })
    }
    func previewPositive() async throws {
        let oldGeneration = rig.native.generation
        defer {rig.native.generation = oldGeneration}
        rig.native.generation = .init(bytes:ModelCatalog.all.first(where:{$0.id == "base.en"})!.bytes,modified:1)
        var value = settings; value.whisperModelPath = ModelCatalog.directory.appendingPathComponent("ggml-base.en.bin").path
        value.language = "en"; value.streamPreviewEnabled = true; value.recognitionPreviewModelID = "base.en"
        let operation = PendingOperation(name:"synthetic preview control")
        let plan = try XCTUnwrap(RecognitionPreviewPlan(settings:value,final:.init(settings:value),generation:machine.gen,operationID:operation.id,ordinaryPhysical:true))
        var capturing = true, clock:TimeInterval = 0, factory = rig.native.factory(); factory.directory = ModelCatalog.directory
        let body = RecognitionPreviewCapture(plan:plan,operation:operation,factory:factory,selectionEpoch:UUID(),preparationEpoch:nil,
            capturing:{capturing},suffix:{_ in .init(copying:[Float](repeating:0.5,count:32000))},secure:{false},publish:{update in
                self.previewUpdates += 1
                if case .draft = update {capturing = false}
            },clear:{},releaseAliases:{},clock:{clock},pause:{clock += 1; await Task.yield()})
        let task = PendingOperationQueue.enqueue(previous:rig.chain,operation:operation,completes:true,work:{await body.run()})
        rig.chain = task; await task.value
        XCTAssertGreaterThan(previewUpdates,1)
    }
    func reset() {
        originals.clear(); undo.invalidate(); microphone.clear()
        ordinaryEntries = []; insertions = 0; corrections = 0; clipboardWrites = 0; captures = 0; finals = 0
        provider.calls = 0; providerFactories = 0; previewUpdates = 0; capture.starts = 0; capture.stops = 0; capture.clears = 0
        rig.recordingPorts.reset(); rig.faults.historyWrites = 0; rig.outputs.copies = []
        rig.credentials.reads = 0; rig.credentials.statuses = 0; rig.credentials.adds = 0; rig.credentials.updates = 0; rig.credentials.deletes = 0
    }
}
extension SavedAudioImportTests {
    @MainActor func testConnectedOrdinaryRecoveryOriginalUndoMicrophoneAndPreviewControlsThenSavedPrivacyZeros() async throws {
        let h = try SavedPrivacyHarness(), rig = h.rig; await rig.ready()
        try rig.settings.credentials.replace("synthetic-provider-key",scope:.anthropic)
        h.start(); h.send(.stopRequested); await rig.chain?.value
        XCTAssertEqual(h.ordinaryEntries,[.stash,.resolve]); XCTAssertGreaterThan(rig.recordingPorts.writes,0)
        XCTAssertEqual(h.provider.calls,1); XCTAssertEqual(h.providerFactories,1); XCTAssertGreaterThan(rig.credentials.reads,0)
        XCTAssertGreaterThan(h.insertions,0); XCTAssertGreaterThan(h.corrections,0); XCTAssertGreaterThan(h.finals,0)
        XCTAssertEqual(rig.history.entries.count,1)
        let original = try XCTUnwrap(h.originals.refresh().token); XCTAssertTrue(h.originals.copyOriginal(token:original))
        XCTAssertGreaterThan(h.clipboardWrites,1)
        let corpus = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:rig.recordings.directory,includingPropertiesForKeys:nil).first {$0.pathExtension == "wav"})
        let corpusText = corpus.deletingPathExtension().appendingPathExtension("hyp.txt")
        XCTAssertEqual(try String(contentsOf:corpusText,encoding:.utf8),"native original")
        // A second real recovery store/Hub shares the same settings, History,
        // factory and observable ports, using normal successful-audio disposal.
        let ports = rig.recordingPorts
        try FileManager.default.createDirectory(at:rig.root.appendingPathComponent("recovery-control"),withIntermediateDirectories:false)
        let recovery = RecordingStore(directory:rig.root.appendingPathComponent("recovery-control"),keepAll:false,access:{ports.accesses.append($0)},writer:{samples,url in ports.writes += 1; try savedRecordingWAV(frames:samples.count).write(to:url)},remover:{url in ports.removes += 1; try FileManager.default.removeItem(at:url)})
        let recoveryHub = HubModel(store:rig.settings,history:rig.history,clipboard:{rig.outputs.copies.append($0)},recordings:recovery,audioImport:rig.transient)
        recoveryHub.onRecoveryTranscribe = {lease,request,done in
            rig.chain = RecoveryTranscription.enqueue(previous:rig.chain,recordings:recovery,lease:lease,request:request,authorize:{recovery.refreshPolicy(from:rig.settings)},load:{request in
                try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:rig.native.factory())
            },done:done)
        }
        let good = try XCTUnwrap(recovery.stash(h.samples,settings:rig.settings)); recovery.resolve(good,transcript:nil,secure:false)
        recoveryHub.transcribeRecovery(good); await rig.chain?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:good.path)); XCTAssertNotNil(recoveryHub.recoveryPreview?.entry)
        let failed = try XCTUnwrap(recovery.stash(h.samples,settings:rig.settings)); recovery.resolve(failed,transcript:nil,secure:false)
        rig.native.outputs = [.init(status:-1)]
        recoveryHub.transcribeRecovery(failed); await rig.chain?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath:failed.path)); XCTAssertNotNil(recoveryHub.recoveryPreview?.error)
        rig.native.outputs = [.init(status:0,segments:["native original"])]
        h.settings.whisperModelPath = "/owned/"+ModelCatalog.default.filename
        rig.native.generation = .init(bytes:ModelCatalog.default.bytes,modified:1)
        try rig.settings.save(h.settings); rig.hub.refreshAudioImportConfiguration()
        h.start(); h.send(.cancelRequested(silent:false,reason:.explicitCancel))
        let offer = try XCTUnwrap(h.undo.view.token); h.undo.undo(token:offer); await rig.chain?.value
        guard case .preview(let token,_) = h.undo.view else {return XCTFail("connected undo preview did not run")}
        XCTAssertTrue(h.undo.copyPreview(token:token)); XCTAssertEqual(h.undo.retainedAudioCount,0)
        h.microphone.start(); h.microphone.stop(); XCTAssertEqual(h.capture.starts,1); XCTAssertEqual(h.capture.stops,1); XCTAssertTrue(h.microphone.hasReview)
        h.microphone.clear()
        try await h.previewPositive()
        await rig.saved.drain(); await withCheckedContinuation {continuation in DispatchQueue.main.async {continuation.resume()}}
        let preserved = try [rig.settings.url,rig.history.url,corpus,corpusText,failed].map {($0,try Data(contentsOf:$0))}
        XCTAssertEqual(rig.native.live,0); let nativeCalls = rig.native.calls.count
        h.reset()
        let url = try rig.source(); rig.hub.selectAudioImport(url)
        XCTAssertEqual(rig.originalReads,0); XCTAssertTrue(rig.saved.rows.isEmpty)
        rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertNotNil(rig.saved.review?.accepted); XCTAssertEqual(rig.native.calls.count,nativeCalls+1)
        XCTAssertTrue(h.ordinaryEntries.isEmpty); XCTAssertTrue(rig.recordingPorts.accesses.isEmpty)
        XCTAssertEqual(rig.recordingPorts.writes+rig.recordingPorts.removes,0)
        XCTAssertEqual(h.provider.calls+h.providerFactories+h.insertions+h.corrections+h.clipboardWrites+h.captures+h.finals+h.previewUpdates,0)
        XCTAssertEqual(h.capture.starts+h.capture.stops,0); XCTAssertEqual(rig.faults.historyWrites,0)
        XCTAssertTrue(rig.outputs.copies.isEmpty); XCTAssertEqual(h.undo.view,.empty)
        XCTAssertNil(h.originals.refresh().token); XCTAssertFalse(h.microphone.hasReview)
        XCTAssertEqual(rig.credentials.reads+rig.credentials.statuses+rig.credentials.adds+rig.credentials.updates+rig.credentials.deletes,0)
        for (path,bytes) in preserved {XCTAssertEqual(try Data(contentsOf:path),bytes)}
        try await rig.close()
    }
}

extension SavedAudioImportTests {
    @MainActor func testRetainedReaderEOFPathGrowthReplacementAndPostConversionMutationFailBeforeStaging() async throws {
        for mutation in 0..<4 {
            let rig = try SavedImportRig(); await rig.ready()
            let url = rig.root.appendingPathComponent("changed.wav")
            let bytes = mutation == 3 ? savedRateWAV(44100,frames:17640) : retainedSyntheticWAV()
            try bytes.write(to:url); var changed = false
            if mutation < 3 {
                rig.transient.sourceAccess.read = {fd,buffer,count in
                    if mutation == 0 {return 0}
                    let n = Darwin.read(fd,buffer,count)
                    if !changed {
                        changed = true
                        if mutation == 1 {
                            let writer = Darwin.open(url.path,O_WRONLY|O_CLOEXEC); var byte:UInt8 = 37
                            XCTAssertEqual(pwrite(writer,&byte,1,off_t(bytes.count)),1); XCTAssertEqual(Darwin.close(writer),0)
                        } else {
                            XCTAssertEqual(rename(url.path,rig.root.appendingPathComponent("moved-original.wav").path),0)
                            do {try retainedSyntheticWAV().write(to:url)} catch {XCTFail("Synthetic replacement write failed: \(error)")}
                        }
                    }
                    return n
                }
            } else {
                let fake = SavedFakeConversion(); fake.target = 6400
                fake.beforeReturn = {
                    if !changed {
                        changed = true; let writer = Darwin.open(url.path,O_WRONLY|O_CLOEXEC); var byte:UInt8 = 37
                        XCTAssertEqual(pwrite(writer,&byte,1,55),1); XCTAssertEqual(Darwin.close(writer),0)
                    }
                }
                rig.transient.sourceAccess.conversion = fake.native()
            }
            rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
            XCTAssertTrue(rig.native.paths.isEmpty); XCTAssertEqual(rig.faults.factoryEntries,0)
            XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
            rig.transient.sourceAccess.read = {Darwin.read($0,$1,$2)}
            try retainedSyntheticWAV().write(to:url)
            rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
            XCTAssertNotNil(rig.saved.review?.accepted); XCTAssertEqual(rig.native.calls.count,1)
            try await rig.close()
        }
    }
    @MainActor func testPendingOpenRevokesAcrossForwardedPreparationDraftSelectionPageAndSecurityEvents() async throws {
        for change in 0..<5 {
            let rig = try SavedImportRig(); var epoch:UUID? = UUID(); rig.hub.audioImportPreparationEpoch = {epoch}
            _ = try await rig.run(); let id = try XCTUnwrap(rig.saved.rows.first?.id)
            rig.hub.discardAudioImport()
            let entered = expectation(description:"result Open is held"), gate = DispatchSemaphore(value:0)
            var held = false
            rig.faults.event = {boundary,name in if boundary == .payloadRead && name?.hasSuffix(".raw.txt") == true && !held {held = true; entered.fulfill(); _ = gate.wait(timeout:.now()+5)}}
            rig.hub.openSavedAudioImport(id); await fulfillment(of:[entered],timeout:5)
            switch change {
            case 0: epoch = UUID(); rig.transient.preparationChanged(epoch)
            case 1: rig.hub.settings.language = "en"; rig.hub.settings.language = "hi"
            case 2: rig.hub.selectAudioImport(rig.root.appendingPathComponent("original.wav"))
            case 3: rig.hub.leaveAudioImport()
            default: rig.transient.observe(.focusSampled(gen:-1,focus:.secure))
            }
            gate.signal(); await rig.saved.drain()
            XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
            rig.hub.onSaved = {}; rig.hub.flushPendingSave(); rig.hub.refreshAudioImportConfiguration()
            rig.faults.event = nil; rig.hub.openSavedAudioImport(id); await rig.saved.drain()
            XCTAssertNotNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
            try await rig.close()
        }
    }
}


extension SavedImportRig {
    func movSource(_ name: String = "original.mov", video: UInt8 = 0xa5, tail: UInt8 = 0x7f) throws -> URL {
        let url = root.appendingPathComponent(name)
        try PCMMOVConnectionFixture.write(PCMMOVConnectionFixture.bytes(video:video,tail:tail),to:url); return url
    }
    func runMOV(_ name: String = "original.mov", video: UInt8 = 0xa5, tail: UInt8 = 0x7f) async throws -> URL {
        await ready(); let url = try movSource(name,video:video,tail:tail)
        hub.selectAudioImport(url); hub.keepAudioImportAndTranscribe(); await chain?.value; await saved.drain(); return url
    }
}
extension SavedAudioImportTests {
    @MainActor func testConnectedMOVKeepRetryWholeSourceVideoTailAndFreshGlobals() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let a = PCMMOVConnectionFixture.bytes(), url = try rig.movSource()
        XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
        rig.hub.selectAudioImport(url); let selected = try XCTUnwrap(rig.transient.source)
        XCTAssertEqual(rig.originalReads,0); XCTAssertTrue(rig.native.paths.isEmpty)
        XCTAssertTrue(rig.saved.rows.isEmpty); XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertTrue(rig.copies.isEmpty)
        rig.native.construct = {XCTAssertTrue(selected.isClosed)} // Original read fd is retired BEFORE ASR.
        rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        let review = try XCTUnwrap(rig.saved.review,rig.saved.message ?? "no MOV review"), accepted = try XCTUnwrap(review.accepted)
        let token = try XCTUnwrap(rig.saved.job?.token), source = rig.saved.store.storage.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")
        XCTAssertEqual(try Data(contentsOf:source),a); XCTAssertEqual(try Data(contentsOf:url),a)
        XCTAssertEqual(accepted.sourceHash,SavedAudioImportStorage.digest(a)); XCTAssertEqual(accepted.sourceGeneration,token.source)
        XCTAssertEqual(rig.saved.rows.first?.sourceProfile,.qtPCM16kV1)
        XCTAssertEqual(rig.native.calls.first?.samples,PCMMOVConnectionFixture.samples); XCTAssertEqual(rig.native.calls.count,1)
        XCTAssertGreaterThan(rig.faults.sourceReads,0) // Includes .source.mov verify reads.
        let reads = rig.originalReads, savedReads = rig.faults.sourceReads
        XCTAssertEqual(unlink(url.path),0)
        var settings = try rig.settings.savedRetrySnapshot(); settings.language = "en"; settings.dictionary = ["Fresh"]
        try rig.settings.save(settings); rig.hub.refreshAudioImportConfiguration()
        rig.hub.retrySavedAudioImport(token.job); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.originalReads,reads); XCTAssertGreaterThan(rig.faults.sourceReads,savedReads)
        XCTAssertEqual(rig.native.calls.count,2); XCTAssertEqual(rig.native.calls.last?.samples,PCMMOVConnectionFixture.samples)
        XCTAssertEqual(rig.native.calls.last?.language,"en"); XCTAssertEqual(rig.native.calls.last?.prompt,"Fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        rig.native.construct = nil
        let b = PCMMOVConnectionFixture.bytes(video:0x5a,tail:0x33)
        _ = try await rig.runMOV("visual-mutation.mov",video:0x5a,tail:0x33)
        let second = try XCTUnwrap(rig.saved.review?.accepted), secondToken = try XCTUnwrap(rig.saved.job?.token)
        XCTAssertNotEqual(second.sourceHash,accepted.sourceHash)
        XCTAssertEqual(second.sourceHash,SavedAudioImportStorage.digest(b)); XCTAssertEqual(rig.native.calls.last?.samples,PCMMOVConnectionFixture.samples)
        XCTAssertEqual(try Data(contentsOf:rig.saved.store.storage.root.appendingPathComponent(secondToken.source.uuidString.lowercased()+".source.mov")),b)
        XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertTrue(rig.copies.isEmpty)
        try await rig.close()

        // Same hash-valid bytes and a closed, numeric-valid schema2 ledger.
        // Only MOV requires redecoded Facts equality; legacy WAV stays loose.
        for isMOV in [false,true] {
            let originalRig = try SavedImportRig()
            let original = isMOV ? try await originalRig.runMOV() : try await originalRig.run()
            let prior = try XCTUnwrap(originalRig.saved.review?.accepted)
            let savedToken = try XCTUnwrap(originalRig.saved.job?.token)
            let storageRoot = originalRig.saved.store.storage.root
            let source = storageRoot.appendingPathComponent(savedToken.source.uuidString.lowercased() + (isMOV ? ".source.mov" : ".source.wav"))
            let sourceBytes = try Data(contentsOf:source)
            let expectedHash = SavedAudioImportStorage.digest(sourceBytes)
            XCTAssertEqual(expectedHash,prior.sourceHash)
            try await originalRig.close() // The old manifest generation is no longer held.
            let manifest = storageRoot.appendingPathComponent("manifest.json")
            var ledger = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
            // WAV-only files normally stay schema1. Use the explicit schema2 projection
            // to compare the exact same durable profile boundary as the MOV negative.
            ledger["schema"] = 2
            var jobs = try XCTUnwrap(ledger["jobs"] as? [[String:Any]])
            var facts = try XCTUnwrap(jobs[0]["facts"] as? [String:Any])
            facts["profile"] = isMOV ? "qtPCM16kV1" : "wavPCM"
            facts["frames"] = 8001; facts["outputFrames"] = 8001
            jobs[0]["facts"] = facts; ledger["jobs"] = jobs
            let modified = try JSONSerialization.data(withJSONObject:ledger,options:[.sortedKeys])
            try modified.write(to:manifest)
            XCTAssertEqual(try Data(contentsOf:source),sourceBytes)
            XCTAssertEqual(unlink(original.path),0) // Retry cannot depend on the selected original.
            var ownedReads = 0
            var system = SavedAudioImportStorage.System()
            system.event = {boundary,name in
                if boundary == .payloadRead, name?.hasSuffix(isMOV ? ".source.mov" : ".source.wav") == true {ownedReads += 1}
            }
            let reopened = SavedAudioImportOwner(root:storageRoot,system:system,clock:{originalRig.now})
            guard await observeMOVCompletion(self,"fact-mismatch metadata reopen",work:{await reopened.drain()}) else {
                reopened.invalidate(); try recordWave4BFixture(originalRig.root,"MOV-fact-metadata-exit-unobserved-preserved"); return
            }
            XCTAssertEqual(reopened.metadataReadiness,.ready)
            XCTAssertEqual(reopened.rows.map(\.id),[savedToken.job])
            XCTAssertEqual(reopened.rows.first?.sourceProfile,isMOV ? .qtPCM16kV1 : .wavPCM)
            XCTAssertNil(reopened.store.failure)
            XCTAssertEqual(try Data(contentsOf:manifest),modified) // Bootstrap accepted; no repair.
            XCTAssertEqual(ownedReads,0)
            let transient = AudioImportOwner(); transient.savedImports = reopened; transient.security = {false}
            transient.sourceAccess.read = {fd,buffer,count in originalRig.originalReads += 1; return Darwin.read(fd,buffer,count)}
            let hub = HubModel(store:originalRig.settings,history:originalRig.history,clipboard:{_ in XCTFail("Retry copied output")},audioImport:transient)
            var chain: Task<Void,Never>?, loads = 0
            reopened.enqueue = {job,done in
                let next = SavedAudioImportExecution.enqueue(previous:chain,admission:originalRig.admission,store:reopened.store,
                    job:job,settings:originalRig.settings,now:{originalRig.now},enter:{},load:{request in
                        await MainActor.run {loads += 1}
                        let factory = await MainActor.run {originalRig.native.factory()}
                        return try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,
                            selectionEpoch:job.authority.selectionEpoch,preparationEpoch:job.authority.preparationEpoch)
                    },done:done)
                if let next {chain = next}; return next
            }
            hub.refreshAudioImportConfiguration()
            let originalReads = originalRig.originalReads, nativeCalls = originalRig.native.calls.count
            hub.retrySavedAudioImport(savedToken.job)
            let retryJob = try XCTUnwrap(reopened.job)
            guard await observeMOVCompletion(self,"fact-mismatch Hub Retry exit",work:{await chain?.value; await reopened.drain()}) else {
                reopened.invalidate(); try recordWave4BFixture(originalRig.root,"MOV-fact-retry-exit-unobserved-preserved"); return
            }
            XCTAssertTrue(retryJob.operation.hasExited); XCTAssertGreaterThan(ownedReads,0)
            XCTAssertEqual(originalRig.originalReads,originalReads)
            XCTAssertEqual(try Data(contentsOf:source),sourceBytes)
            XCTAssertEqual(SavedAudioImportStorage.digest(try Data(contentsOf:source)),expectedHash)
            XCTAssertEqual(loads,isMOV ? 0 : 1)
            XCTAssertEqual(originalRig.native.calls.count-nativeCalls,isMOV ? 0 : 1)
            if isMOV {
                XCTAssertNil(reopened.review)
                XCTAssertEqual(reopened.rows.first?.result?.id,prior.id)
            } else {XCTAssertNotNil(reopened.review?.accepted)}
            reopened.invalidate(); transient.invalidate()
            guard await observeMOVCompletion(self,"fact-mismatch close drain",work:{await chain?.value; await reopened.drain()}) else {
                try recordWave4BFixture(originalRig.root,"MOV-fact-close-exit-unobserved-preserved"); return
            }
            try reopened.store.close()
            try recordWave4BFixture(originalRig.root,"MOV-fact-comparison-closed")
        }
    }


    @MainActor func testConnectedMOVTextOnlySaveRetryAndMissingSourceOpenHaveZeroSourceOrASRDelta() async throws {
        let faults = SavedImportFaults(); faults.resultWriteFails = true
        let rig = try SavedImportRig(faults:faults); let original = try await rig.runMOV()
        let review = try XCTUnwrap(rig.saved.review,rig.saved.message ?? "no RAM text")
        XCTAssertNil(review.accepted)
        let id = review.resultID, bytes = review.bytes, date = review.date, token = review.token, observed = review.observed
        let originalReads = rig.originalReads, sources = faults.sourceReads, factories = faults.factoryEntries, calls = rig.native.calls.count
        // Remove both sources before Retry Save. This makes any hidden original or
        // owned-source parse impossible; the current review retains only raw text.
        XCTAssertEqual(unlink(original.path),0)
        let sourceID = try XCTUnwrap(token?.source), source = rig.saved.store.storage.root.appendingPathComponent(sourceID.uuidString.lowercased()+".source.mov")
        XCTAssertEqual(unlink(source.path),0)
        rig.hub.retrySaveAudioImportResult(); await rig.saved.drain()
        let saved = try XCTUnwrap(rig.saved.review?.accepted,rig.saved.message ?? "not saved")
        XCTAssertEqual(saved.id,id); XCTAssertEqual(saved.date,date.timeIntervalSince1970)
        XCTAssertEqual(rig.saved.review?.bytes,bytes); XCTAssertEqual(rig.saved.review?.token,token); XCTAssertEqual(saved.observed,observed)
        XCTAssertEqual(rig.originalReads,originalReads); XCTAssertEqual(faults.sourceReads,sources)
        XCTAssertEqual(faults.factoryEntries,factories); XCTAssertEqual(rig.native.calls.count,calls)
        XCTAssertGreaterThan(faults.resultReads,0)
        rig.hub.discardAudioImport(); rig.hub.openSavedAudioImport(review.jobID); await rig.saved.drain()
        XCTAssertEqual(rig.saved.review?.bytes,bytes); XCTAssertEqual(rig.saved.review?.resultID,id)
        XCTAssertEqual(rig.originalReads,originalReads); XCTAssertEqual(faults.sourceReads,sources)
        XCTAssertEqual(faults.factoryEntries,factories); XCTAssertEqual(rig.native.calls.count,calls)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        XCTAssertEqual(rig.history.entries.map(\.id),[id]); XCTAssertEqual(rig.history.entries.first?.raw,review.text)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain(); XCTAssertEqual(rig.history.entries.count,1)
        try await rig.close()
    }

    @MainActor func testConnectedMOVTextOnlyMetadataReopenDoesNotReadSourceOrTranscribe() async throws {
        let rig = try SavedImportRig(); _ = try await rig.runMOV()
        let id = try XCTUnwrap(rig.saved.rows.first?.id), calls = rig.native.calls.count, originalReads = rig.originalReads
        rig.saved.invalidate(); await rig.saved.drain(); try rig.saved.store.close()
        var payloadReads = 0, hashes = 0, writes = 0
        var system = SavedAudioImportStorage.System()
        system.event = {boundary,_ in
            if boundary == .payloadRead {payloadReads += 1}
            if boundary == .hash {hashes += 1}
            if boundary == .write {writes += 1}
        }
        let reopened = SavedAudioImportOwner(root:rig.saved.store.storage.root,system:system,clock:{rig.now})
        await reopened.drain()
        XCTAssertEqual(reopened.metadataReadiness,.ready); XCTAssertEqual(reopened.rows.map(\.id),[id])
        XCTAssertEqual(reopened.rows.first?.sourceProfile,.qtPCM16kV1)
        XCTAssertEqual(payloadReads,0); XCTAssertEqual(hashes,0); XCTAssertEqual(writes,0)
        XCTAssertEqual(rig.native.calls.count,calls); XCTAssertEqual(rig.originalReads,originalReads)
        reopened.invalidate(); try reopened.store.close(); try await rig.close()
    }

    @MainActor func testConnectedMOVTextOnlyProtectionAliasesModalAuthorityAndSafeDestination() async throws {
        let rig = try SavedImportRig(), original = try await rig.runMOV(), review = try XCTUnwrap(rig.saved.review)
        let alias = rig.root.appendingPathComponent("original-alias.txt"), safe = rig.root.appendingPathComponent("safe.txt")
        XCTAssertEqual(link(original.path,alias.path),0)
        let protected = [alias,rig.saved.store.storage.root.appendingPathComponent("new.txt"),original]
        for destination in protected {
            rig.hub.audioImportExportPanel = {_ in destination}; rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty)
        }
        rig.hub.audioImportExportPanel = {_ in safe}; rig.hub.exportSavedAudioImportText(); XCTAssertEqual(rig.written,[review.bytes])
        rig.written = []
        rig.hub.audioImportExportPanel = {_ in rig.hub.discardAudioImport(); return safe}
        rig.hub.exportSavedAudioImportText(); XCTAssertTrue(rig.written.isEmpty); XCTAssertNil(rig.saved.review)
        rig.hub.openSavedAudioImport(review.jobID); await rig.saved.drain(); XCTAssertNotNil(rig.saved.review)
        rig.now = try XCTUnwrap(rig.saved.rows.first?.expires)
        rig.hub.copySavedAudioImport(); rig.hub.saveSavedAudioImportHistory(); rig.hub.exportSavedAudioImportText()
        XCTAssertTrue(rig.copies.isEmpty); XCTAssertTrue(rig.history.entries.isEmpty); XCTAssertTrue(rig.written.isEmpty)
        XCTAssertEqual(rig.native.calls.count,1); try await rig.close()
    }

    @MainActor func testConnectedMOVMixedJobsWAVResultMalformedRefusalMissingSourceAndFullDisk() async throws {
        let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults)
        _ = try await rig.run(); let wavReview = try XCTUnwrap(rig.saved.review), wavID = wavReview.jobID
        _ = try await rig.runMOV(); let mov = try XCTUnwrap(rig.saved.review), token = try XCTUnwrap(rig.saved.job?.token)
        let oldIDs = rig.saved.rows.map(\.id), count = rig.native.calls.count
        let malformed = rig.root.appendingPathComponent("malformed.mov")
        try PCMMOVConnectionFixture.write(Data(PCMMOVConnectionFixture.bytes().dropLast()),to:malformed)
        rig.hub.selectAudioImport(malformed); rig.hub.keepAudioImportAndTranscribe(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.saved.rows.map(\.id),oldIDs); XCTAssertEqual(rig.native.calls.count,count)
        let missing = rig.saved.store.storage.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.mov")
        XCTAssertEqual(unlink(missing.path),0)
        let originalReads = rig.originalReads, factories = faults.factoryEntries
        rig.hub.retrySavedAudioImport(mov.jobID); await rig.chain?.value; await rig.saved.drain()
        XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.originalReads,originalReads); XCTAssertEqual(faults.factoryEntries,factories)
        rig.hub.openSavedAudioImport(wavID); await rig.saved.drain(); XCTAssertEqual(rig.saved.review?.bytes,wavReview.bytes)
        rig.hub.openSavedAudioImport(mov.jobID); await rig.saved.drain(); XCTAssertEqual(rig.saved.review?.bytes,mov.bytes)
        // Synthetic .space at the actual free-space seam, without changing quotas.
        var failSpace = true
        faults.event = {boundary,_ in
            if boundary == .freeSpace, failSpace {failSpace = false; throw SavedAudioImportStorage.Failure.space}
        }
        _ = try await rig.runMOV("disk-full.mov")
        XCTAssertFalse(failSpace)
        XCTAssertEqual(rig.saved.rows.map(\.id),oldIDs); XCTAssertEqual(rig.native.calls.count,count)
        XCTAssertEqual(faults.factoryEntries,factories); XCTAssertEqual(rig.saved.rows.first?.sourceProfile,.wavPCM)
        try await rig.close()
    }
}


extension SavedAudioImportTests {
    @MainActor func testConnectedMOVKeepRetryMigrationFailureNeverEntersFactoryOrGrantsMOVPayload() async throws {
        for cut in 0..<3 {
            let faults = SavedImportFaults(), rig = try SavedImportRig(faults:faults); _ = try await rig.run()
            let old = try XCTUnwrap(rig.saved.review), source = try XCTUnwrap(rig.saved.job?.token?.source)
            let owned = rig.saved.store.storage.root.appendingPathComponent(source.uuidString.lowercased()+".source.wav")
            let oldBytes = try Data(contentsOf:owned), factories = faults.factoryEntries, calls = rig.native.calls.count
            var hit = false, movAllocations = 0
            faults.event = {boundary,name in
                if boundary == .create, name?.hasSuffix(".source.pending") == true {movAllocations += 1}
                guard !hit else {return}
                let target = cut == 0 ? boundary == .created && name == "manifest.next"
                    : cut == 1 ? boundary == .rename && name == "manifest.next"
                    : boundary == .directorySync && name == "manifest.json"
                if target {hit = true; throw cut == 0 ? SavedAudioImportStorage.Failure.bounds : .revoked}
            }
            _ = try await rig.runMOV("refused.mov")
            XCTAssertTrue(hit); XCTAssertEqual(movAllocations,0); XCTAssertEqual(faults.factoryEntries,factories)
            XCTAssertEqual(rig.native.calls.count,calls); XCTAssertNil(rig.saved.review)
            XCTAssertEqual(rig.saved.rows.map(\.id),[old.jobID]); XCTAssertEqual(rig.saved.store.failure,.uncertain)
            XCTAssertEqual(try Data(contentsOf:owned),oldBytes); XCTAssertFalse(rig.saved.restartReady())
            faults.event = nil; try await rig.close()
        }
    }
}
