import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class MeetingRecognitionExecutionTests: XCTestCase {
    @MainActor func testRequestedAndNilObservedAreDistinctConservativeFacts() throws {
        var settings = Settings(); settings.whisperModelPath = "/private/never-persist/model"; settings.language = "fr"; settings.dictionary = ["Literal"]
        let requested = try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:settings),id:UUID(),generation:1)
        let observed = try MeetingRecognitionExecution.observedProvenance(identity:nil,id:UUID(),generation:1)
        XCTAssertEqual(requested.engine,.whisper); XCTAssertEqual(requested.language,"fr"); XCTAssertTrue(requested.hints); XCTAssertEqual(requested.model,"")
        XCTAssertEqual(observed.engine,.unknown); XCTAssertEqual(observed.artifact,.unknown); XCTAssertEqual(observed.language,""); XCTAssertFalse(observed.hints)
        XCTAssertNil(observed.fileGeneration); XCTAssertEqual(observed.nativeVersion,""); XCTAssertEqual(observed.digest,"")
    }
    @MainActor func testAvailableOverlongProvenanceRefusesRatherThanTruncates() throws {
        var settings = Settings(); settings.whisperModelPath = "/virtual/model"; settings.language = String(repeating:"f",count:65)
        XCTAssertThrowsError(try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:settings),id:UUID(),generation:1))
        settings.recognitionEngine = .invalid
        XCTAssertThrowsError(try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:settings),id:UUID(),generation:1))
    }
    @MainActor func testLoadedExactRegistryRowReusesIDAndGenerationForTwentyParts() throws {
        let execution = MeetingRecognitionExecution(); var settings = Settings(); settings.whisperModelPath = "/virtual/model"
        let request = RecognitionRequest(settings:settings),id = UUID()
        let row = try MeetingRecognitionExecution.requestedProvenance(request:request,id:id,generation:17)
        try execution.prime([row])
        for _ in 0..<20 {
            let context = MeetingRecognitionExecution.Context(session:UUID(),chunk:UUID(),generation:1,intent:UUID(),configuration:.init(settings),selectionEpoch:UUID(),preparationEpoch:nil,authority:.init(),authorize:{true})
            XCTAssertEqual(try execution.prepare(context),row)
        }
    }
    @MainActor func testThirtyTwoRowsRefuseNovelTupleWithoutEviction() throws {
        let execution = MeetingRecognitionExecution(); var settings = Settings(); settings.whisperModelPath = "/virtual/model"
        var rows: [MeetingSession.Provenance] = []
        for i in 0..<32 { settings.language = "literal-\(i)"; rows.append(try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:settings),id:UUID(),generation:1)) }
        try execution.prime(rows); settings.language = "new-literal"
        let context = MeetingRecognitionExecution.Context(session:UUID(),chunk:UUID(),generation:1,intent:UUID(),configuration:.init(settings),selectionEpoch:UUID(),preparationEpoch:nil,authority:.init(),authorize:{true})
        XCTAssertThrowsError(try execution.prepare(context)); try execution.prime(rows)
        settings.language = "literal-0"
        let reused = MeetingRecognitionExecution.Context(session:UUID(),chunk:UUID(),generation:1,intent:UUID(),configuration:.init(settings),selectionEpoch:UUID(),preparationEpoch:nil,authority:.init(),authorize:{true})
        XCTAssertEqual(try execution.prepare(reused),rows[0])
    }
    @MainActor func testSharedQueuePredecessorCancelBeforeDequeueSettlesActualChain() async throws {
        let r = try MeetingHubRig(),gate = HubOwnedLatch(); defer { gate.open(); r.release() }
        let execution = MeetingRecognitionExecution(), authority = MeetingRecognitionExecution.Authority()
        let context = MeetingRecognitionExecution.Context(session:UUID(),chunk:UUID(),generation:1,intent:UUID(),configuration:.init(r.settings.current),selectionEpoch:r.selectedEpoch,preparationEpoch:nil,authority:authority,authorize:{true})
        let row = try execution.prepare(context)
        let job = MeetingRecognitionExecution.Job(bytes:Data(),context:context,requested:row,diagnostics:DiagnosticStore())
        var factories = 0
        let predecessor = Task { await gate.wait() }
        let next = MeetingRecognitionExecution.enqueue(previous:predecessor,admission:r.localAdmission,job:job,settings:r.store,enter:{XCTFail("Canceled before dequeue")},load:{request in factories += 1; return try RecognitionHandle(request:request,load:{_ in HubLiteralRecognizer(gate:nil)})})!
        job.revoke(); XCTAssertFalse(job.operation.hasExited); gate.open()
        guard await hubComplete({await next.value}) else { return }
        XCTAssertTrue(job.operation.hasExited); XCTAssertEqual(factories,0)
    }
    @MainActor func testExplicitRawTranscriptionAndVerifiedCopyViaProductionController() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        r.engine.emit([Float](repeating:0.5,count:8000)); r.controller.stopAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.enqueues,0); r.controller.transcribeRemaining()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.enqueues,1); XCTAssertEqual(r.controller.model.metadata?.provenance.count,2)
        r.controller.copyText(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.copies,["Literal raw text\nkept verbatim."])
    }
    @MainActor func testSavedSettingsEventRevokesHeldConsumerAndCannotRestartIt() async throws {
        let r = try MeetingHubRig(),gate = HubOwnedLatch(); defer { gate.open(); r.release() }; r.consumerGate = gate
        let entered = XCTestExpectation(description:"actual recognizer entered before settings event")
        r.consumerEntered = entered
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        r.engine.emit([Float](repeating:0.5,count:8000)); r.controller.stopAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.transcribeRemaining()
        guard await hubEntered([entered]) else {return}
        var changed = r.settings.current; changed.language = "fr"; r.settings.current = changed; r.changedSettings()
        r.controller.reserveShutdown(); XCTAssertFalse(r.controller.restartReady())
        let drain = HubRestartDrain(r.controller);guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned);gate.open()
        guard await hubEntered([drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,true)
        XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0)
    }
}


extension MeetingRecognitionExecutionTests {
    @MainActor func testRequestedAndObservedNoveltyAtThirtyTwoPreservesDurablePrefixBeforeReserve() async throws {
        let r = MeetingSequenceRig()
        guard await hubComplete({do {try await r.seed(2);try await r.transcribe(0)} catch {XCTFail("prefix failed")}}) else {return}
        let prefix = try XCTUnwrap(r.owner.metadata?.chunks[0].accepted),originalSettings = r.settings.current
        // Fill only the bounded registry, with failed requested attempts; no capacity/chunk campaign.
        for i in 0..<30 {
            var settings = r.settings.current;settings.language = "novel-\(i)"
            let row = try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:settings),id:UUID(),generation:1)
            let token = try r.owner.store.beginAttempt(chunk:r.ids[1],requested:row,authorized:{true})
            _ = try r.owner.store.finishAttempt(token,canceled:false,authorized:{true})
        }
        guard await hubComplete({do {try await r.owner.openMetadata()} catch {XCTFail("registry refresh failed")}}) else {return}
        let full = try XCTUnwrap(r.owner.metadata);XCTAssertEqual(full.provenance.count,32)
        let jobs = r.jobs.count,revision = full.revision,events = r.bottom.events.count
        var novel = r.settings.current;novel.language = "thirty-third";r.settings.current = novel
        guard await hubComplete({do {try await r.transcribe(1);XCTFail("requested novelty must refuse before attempt")} catch {}}) else {return}
        XCTAssertEqual(r.jobs.count,jobs);XCTAssertEqual(try r.owner.store.metadata()?.revision,revision);XCTAssertEqual(r.bottom.events.count,events)
        r.settings.current = originalSettings
        r.identity = RecognitionIdentity(engine:.appleSpeech,selection:.appleSpeech(locale:"fr-FR"),artifact:.systemAssetsRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:UUID())
        let startEvents = r.bottom.events.count
        guard await hubComplete({do {try await r.transcribe(1);XCTFail("observed novelty must refuse before result reserve")} catch {}}) else {return}
        XCTAssertEqual(r.jobs.count,jobs+1)
        XCTAssertFalse(r.bottom.events.dropFirst(startEvents).contains {$0.0 == "exclusive-create" && $0.1?.hasSuffix(".result.pending") == true})
        XCTAssertEqual(r.owner.metadata?.provenance,full.provenance)
        XCTAssertEqual(r.owner.metadata?.chunks[0].accepted,prefix);XCTAssertNil(r.owner.metadata?.chunks[1].accepted)
        XCTAssertTrue(r.bottom.names.contains(prefix.id.uuidString.lowercased()+".raw.txt"))
        guard await hubComplete({do {try await r.detach()} catch {XCTFail("detach failed")}}) else {return}
    }
    @MainActor func testFiniteConservativeObservedCatalogCustomAppleAndInvalidMapping() throws {
        let runtime = RecognitionRuntime(nativeVersion:"literal-native",buildScope:"literal-build",adapterRevision:7,compute:.init(defaultsRevision:9))
        let generation = RecognitionFileGeneration(bytes:123,modified:4,changed:5,fileNumber:6)
        let catalog = RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/never/persist"),artifact:.admittedCatalog(id:"literal-id",expectedSHA256:String(repeating:"a",count:64),expectedBytes:123),generation:generation,runtime:runtime,unknownRevisionScope:nil)
        let c = try MeetingRecognitionExecution.observedProvenance(identity:catalog,id:UUID(),generation:17)
        XCTAssertEqual(c.role,.observed);XCTAssertEqual(c.engine,.whisper);XCTAssertEqual(c.artifact,.unknown)
        XCTAssertEqual(c.catalogID,"literal-id");XCTAssertEqual(c.digest,String(repeating:"a",count:64));XCTAssertEqual(c.expectedBytes,123)
        XCTAssertEqual(c.nativeVersion,"literal-native");XCTAssertEqual(c.buildScope,"literal-build");XCTAssertEqual(c.adapter,7);XCTAssertEqual(c.compute,9)
        XCTAssertEqual(c.language,"");XCTAssertEqual(c.model,"");XCTAssertNil(c.fileGeneration)
        let custom = RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/private/model"),artifact:.customRevisionUnknown,generation:generation,runtime:nil,unknownRevisionScope:UUID())
        let u = try MeetingRecognitionExecution.observedProvenance(identity:custom,id:UUID(),generation:1)
        XCTAssertEqual(u.artifact,.customUnknown);XCTAssertEqual(u.model,"");XCTAssertEqual(u.digest,"");XCTAssertEqual(u.expectedBytes,0);XCTAssertNil(u.fileGeneration)
        let apple = RecognitionIdentity(engine:.appleSpeech,selection:.appleSpeech(locale:"fr-FR"),artifact:.systemAssetsRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:UUID())
        let a = try MeetingRecognitionExecution.observedProvenance(identity:apple,id:UUID(),generation:1)
        XCTAssertEqual(a.artifact,.systemUnknown);XCTAssertEqual(a.language,"fr-FR");XCTAssertEqual(a.systemScope,"");XCTAssertEqual(a.verification,"")
        var appleRequest = Settings();appleRequest.whisperModelPath = "/virtual/model";appleRequest.recognitionEngine = .appleSpeech;appleRequest.appleSpeechLocale = "en-US";appleRequest.language = "fr"
        let requestedApple = try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:appleRequest),id:UUID(),generation:1)
        XCTAssertEqual(requestedApple.engine,.appleSpeech);XCTAssertEqual(requestedApple.language,"en-US");XCTAssertEqual(requestedApple.artifact,.unknown);XCTAssertEqual(requestedApple.systemScope,"")
        for invalid in [
            RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/v"),artifact:.admittedCatalog(id:"x",expectedSHA256:"invalid",expectedBytes:1),generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/v"),artifact:.customRevisionUnknown,generation:nil,runtime:.init(nativeVersion:"x",buildScope:"",compute:.init(defaultsRevision:-1)),unknownRevisionScope:nil),
            RecognitionIdentity(engine:.invalid,selection:.invalid,artifact:.customRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.appleSpeech,selection:.whisper(localPath:"/v"),artifact:.customRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/v"),artifact:.systemAssetsRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/v"),artifact:.admittedCatalog(id:"x",expectedSHA256:String(repeating:"a",count:64),expectedBytes:-1),generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.appleSpeech,selection:.appleSpeech(locale:String(repeating:"x",count:65)),artifact:.systemAssetsRevisionUnknown,generation:nil,runtime:nil,unknownRevisionScope:nil),
            RecognitionIdentity(engine:.whisper,selection:.whisper(localPath:"/v"),artifact:.customRevisionUnknown,generation:nil,runtime:.init(nativeVersion:"x",buildScope:"",adapterRevision:-1),unknownRevisionScope:nil)
        ] {XCTAssertThrowsError(try MeetingRecognitionExecution.observedProvenance(identity:invalid,id:UUID(),generation:1))}
    }
}


extension MeetingRecognitionExecutionTests {
    @MainActor func testQueuedMeetingJobAndActualDrainWaitForPredecessorWithoutFactoryEntry() async throws {
        let r = try MeetingHubRig(),gate = HubOwnedLatch();defer {gate.open();r.release()}
        guard await hubSaved(r) else {return}
        let predecessorEntered = XCTestExpectation(description:"shared predecessor actually entered")
        let enqueued = XCTestExpectation(description:"meeting appended to actual shared lane")
        let predecessorExit = XCTestExpectation(description:"shared predecessor actually returned")
        r.processTask = Task {predecessorEntered.fulfill();await gate.wait();predecessorExit.fulfill()}
        guard await hubEntered([predecessorEntered]) else {return}
        r.enqueued = enqueued;r.controller.transcribeRemaining()
        guard await hubEntered([enqueued]) else {return}
        let job = try XCTUnwrap(r.recognitionJobs.first)
        XCTAssertEqual(r.loads,0);XCTAssertFalse(job.operation.hasExited)
        XCTAssertTrue(r.controller.reserveRestart());let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned);XCTAssertFalse(r.controller.restartReady());XCTAssertEqual(r.loads,0)
        gate.open();guard await hubEntered([predecessorExit,drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,true);XCTAssertTrue(job.operation.hasExited);XCTAssertEqual(r.loads,0)
        XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0);XCTAssertFalse(gate.timedOut)
    }
}


extension MeetingRecognitionExecutionTests {
    @MainActor func testActualControllerAcceptedPrefixFailureAndExplicitOrderedResumeNeverRewritePrefix() async throws {
        let seed = MeetingSequenceRig()
        guard await hubComplete({do {try await seed.seed(3,speech:true);try await seed.detach()} catch {XCTFail("durable source setup failed")}}) else {return}
        let r = try MeetingHubRig(bottom:seed.bottom);defer {r.release()}
        var failSecond = true
        r.recognitionText = {job in
            let index = seed.ids.firstIndex(of:job.context.chunk)!
            return failSecond && index == 1 ? nil : "literal-\(index)"
        }
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.controller.model.metadata?.chunks.map(\.id),seed.ids)
        r.controller.transcribeRemaining();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.recognitionJobs.map {$0.context.chunk},[seed.ids[0],seed.ids[1]])
        let prefix = try XCTUnwrap(r.controller.model.metadata?.chunks[0].accepted)
        let prefixName = prefix.id.uuidString.lowercased()+".raw.txt"
        let prefixBytes = try XCTUnwrap(seed.bottom.rootNode?.children[prefixName]).bytes(0,prefix.bytes)
        XCTAssertNil(r.controller.model.metadata?.chunks[1].accepted);XCTAssertNil(r.controller.model.metadata?.chunks[2].accepted)
        failSecond = false;r.controller.transcribeRemaining()
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.recognitionJobs.map {$0.context.chunk},[seed.ids[0],seed.ids[1],seed.ids[1],seed.ids[2]])
        XCTAssertEqual(r.controller.model.metadata?.chunks[0].accepted,prefix)
        XCTAssertEqual(seed.bottom.rootNode?.children[prefixName]?.bytes(0,prefix.bytes),prefixBytes)
        XCTAssertEqual(r.controller.model.metadata?.chunks.compactMap(\.accepted).count,3)
        r.controller.copyText();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.copies,["literal-0\n\nliteral-1\n\nliteral-2"])
        XCTAssertEqual(r.engine.starts.value,0)
        r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered,drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,true);XCTAssertTrue(r.bottom.descriptors.isEmpty)
    }
}
