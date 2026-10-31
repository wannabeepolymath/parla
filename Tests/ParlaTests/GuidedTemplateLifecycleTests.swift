import AppKit
import AVFoundation
import Combine
import Foundation
import XCTest
@testable import ParlaCore
@testable import Parla

final class GuidedTemplateLifecycleTests: XCTestCase {
    @MainActor func testT10TypedRecorderReservationRejectsEveryForeignAndStaleOwner() async throws {
        let r = try GuidedRig(); await r.begin()
        let id = try XCTUnwrap(r.owner.session?.id)
        // The exact lease remains in the production owner; public ordinary/B55 ports cannot borrow it.
        XCTAssertThrowsError(try r.recorder.start()); XCTAssertTrue(r.recorder.stop().isEmpty)
        XCTAssertNil(r.admission.acquire(.microphoneTest)); XCTAssertNil(r.admission.acquire(.dictation))
        r.owner.start(); let capture = try XCTUnwrap(r.owner.session?.take?.capture)
        XCTAssertTrue(r.recorder.stopMicrophoneTest(operation:capture).isEmpty); r.recorder.clearMicrophoneTest(operation:capture)
        XCTAssertTrue(r.engine.isRunning); XCTAssertTrue(r.recorder.snapshot().isEmpty)
        let falseAdmission = CaptureAdmission(), foreign = falseAdmission.acquire(.guidedTemplate)!
        XCTAssertNil(r.recorder.stopGuidedTemplate(session:id,capture:capture,lease:foreign))
        r.recorder.clearGuidedTemplate(session:id,capture:capture,lease:foreign); r.recorder.releaseGuidedTemplate(session:id,lease:foreign)
        r.engine.feed(); r.owner.stop(); await r.chain?.value; XCTAssertNotNil(r.owner.session?.candidate)
        r.owner.cancel(); await r.begin(); r.owner.start(); let starts = r.engine.starts
        r.recorder.clearGuidedTemplate(session:id,capture:capture,lease:foreign)
        XCTAssertTrue(r.engine.isRunning); XCTAssertEqual(r.engine.starts,starts)
        try await r.close()
    }
    @MainActor func testT11HeldConversionMustExitBeforeAdapterTransfersOrLeaseReleases() async throws {
        let clock = GuidedClock(), engine = GuidedEngine(), admission = CaptureAdmission()
        let entered = expectation(description:"conversion entered"), done = expectation(description:"tap exited")
        let leave = DispatchSemaphore(value:0), lock = NSLock()
        var conversionExited = false
        let recorder = AudioRecorder(engine:engine,admission:admission,conversion:{_ in
            entered.fulfill(); leave.wait(); lock.withLock {conversionExited = true}; return [Float](repeating:0.2,count:8000)
        },guidedDrain:{.success([])},captureClock:{clock.now},scheduleRoute:clock.schedule)
        let adapter = RecorderGuidedTemplateCapture(recorder:recorder), id = UUID(), capture = UUID(), lease = admission.acquire(.guidedTemplate)!
        try adapter.reserve(session:id,lease:lease); try adapter.start(session:id,capture:capture,lease:lease,inputUID:nil)
        let receive = try XCTUnwrap(engine.receive)
        DispatchQueue.global().async {receive(GuidedEngine.buffer()); done.fulfill()}
        await fulfillment(of:[entered],timeout:3)
        XCTAssertFalse(lock.withLock {conversionExited}); XCTAssertTrue(admission.owns(lease))
        // Release on another executor; synchronous Stop must cross the converter lock before it can return.
        DispatchQueue.global().async {leave.signal()}
        let result = adapter.stop(session:id,capture:capture,lease:lease)
        XCTAssertTrue(lock.withLock {conversionExited}); XCTAssertEqual(result?.samples.count,8000)
        await fulfillment(of:[done],timeout:3)
        receive(GuidedEngine.buffer(0.9)); XCTAssertEqual(recorder.retainedAudioCounts.samples,0)
        adapter.release(session:id,lease:lease); admission.release(lease); XCTAssertTrue(admission.isAvailable)
    }
    @MainActor func testT11OwnerCancelJoinsHeldConverterAndDrainBeforeReleasingTokens() async throws {
        let r = try GuidedRig(), entered = expectation(description:"owned converter held"), exited = expectation(description:"tap exited")
        let revoked = DispatchSemaphore(value:0), lock = NSLock()
        var converterExited = false, drains = 0, releases = 0
        let admission = r.admission
        r.memory.conversion = {_ in
            entered.fulfill(); revoked.wait()
            XCTAssertFalse(admission.isAvailable)
            lock.withLock {converterExited = true}
            return [Float](repeating:0.25,count:8000)
        }
        r.memory.onDrain = {
            drains += 1
            XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession)
            XCTAssertTrue(lock.withLock {converterExited}); XCTAssertFalse(r.engine.isRunning)
            XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
            r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts,1)
        }
        r.owner.unsuspend = {token in
            releases += 1
            XCTAssertTrue(lock.withLock {converterExited}); XCTAssertEqual(drains,1)
            XCTAssertFalse(r.engine.isRunning); XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0)
            HotkeyMonitor.releaseSuspension(token)
        }
        await r.begin(); r.owner.start()
        let receive = try XCTUnwrap(r.engine.receive)
        DispatchQueue.global().async {receive(GuidedEngine.buffer()); exited.fulfill()}
        await fulfillment(of:[entered],timeout:3)
        var revocations = 0
        let publication = r.owner.$session.dropFirst().sink {state in
            guard state == nil, revocations == 0 else {return}
            revocations += 1 // The later disposal reset also publishes nil, after release.
            XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
            revoked.signal()
        }
        r.owner.cancel(); publication.cancel(); XCTAssertEqual(revocations,1)
        await fulfillment(of:[exited],timeout:3)
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        XCTAssertEqual(drains,1); XCTAssertEqual(releases,1); XCTAssertFalse(HotkeyMonitor.suspended)
        receive(GuidedEngine.buffer()); XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0)
        XCTAssertTrue(r.native.paths.isEmpty); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
        r.memory.conversion = nil; r.memory.onDrain = {}; r.owner.unsuspend = HotkeyMonitor.releaseSuspension
        await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate)
        try await r.close()
    }
    @MainActor func testT12T25TimeSampleBoundariesAndSessionTimerCannotCloseSuccessor() async throws {
        let r = try GuidedRig(); await r.begin(); r.owner.start(); r.engine.feed()
        r.clock.advance(30); XCTAssertFalse(r.owner.recording); XCTAssertNil(r.owner.session?.candidate); XCTAssertTrue(r.native.paths.isEmpty)
        let old = r.clock.retired
        r.owner.cancel(); await r.begin(); old.forEach{$0()}; XCTAssertTrue(r.owner.ownsSession)
        r.clock.advance(1200); XCTAssertFalse(r.owner.ownsSession); XCTAssertTrue(r.admission.isAvailable)
        await r.begin(); for _ in 0..<60 {r.owner.start(); r.owner.discardTake()}
        let starts = r.engine.starts; r.owner.start(); XCTAssertEqual(r.engine.starts,starts)
        XCTAssertEqual(r.owner.session?.starts,60); try await r.close()
    }
    @MainActor func testT14ActualPredecessorBarrierHoldsReadyAndCanceledAdmissionUntilExit() async throws {
        let r = try GuidedRig(), entered = RecognitionTestLatch(), exit = RecognitionTestLatch()
        let predecessor = PendingOperation(name:"B57 or ordinary predecessor")
        r.chain = PendingOperationQueue.enqueue(previous:nil,operation:predecessor,completes:true,work:{entered.signal(); await exit.wait()})
        await entered.wait(); r.hub.beginTemplate(); XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession)
        r.owner.start(); XCTAssertEqual(r.engine.starts,0); XCTAssertEqual(r.invalidations,1)
        r.owner.cancel(); XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        r.hub.beginTemplate(); XCTAssertEqual(r.invalidations,1)
        exit.signal(); await r.chain?.value; XCTAssertTrue(predecessor.hasExited); XCTAssertTrue(r.owner.readyForRestart)
        await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate); try await r.close()
    }
    @MainActor func testT17HeldActualConstructorAndDecodeKeepQueueLifetimeAndPreventSuccessor() async throws {
        for constructor in [true,false] {
            let r = try GuidedRig(), entered = expectation(description:"native entered"), leave = DispatchSemaphore(value:0)
            let block = {entered.fulfill(); leave.wait()}
            if constructor {r.native.construct = block} else {r.native.decode = block}
            await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop()
            await fulfillment(of:[entered],timeout:3)
            r.owner.cancel(); XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession)
            XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
            r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts,1)
            XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            leave.signal(); await r.chain?.value
            XCTAssertTrue(r.owner.readyForRestart); XCTAssertEqual(r.native.live,0); XCTAssertTrue(r.admission.isAvailable)
            r.native.construct = nil; r.native.decode = nil; await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate)
            try await r.close()
        }
    }
    @MainActor func testT18CancellationAtEveryPublishedPhaseAndBeforeDequeueNeverPublishes() async throws {
        for stage in 0..<6 {
            let r = try GuidedRig(); await r.begin()
            if stage == 1 {r.owner.start(); r.engine.feed()}
            if stage >= 2 {await r.take()}
            if stage >= 3 {r.owner.accept()}
            if stage >= 4 {r.owner.review()}
            if stage >= 5 {r.owner.approve(try XCTUnwrap(r.owner.session?.preview).id)}
            r.owner.cancel(); r.owner.stop(); r.owner.cancel(); r.owner.accept(); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
            await r.chain?.value; XCTAssertNil(r.owner.session); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            try await r.close()
        }
    }
    @MainActor func testT19T20ObservedAwayBackNeverRevivesAndUnchangedRefreshPreserves() async throws {
        for change in 0..<7 {
            let r = try GuidedRig(); await r.begin(); await r.take(); r.owner.accept(); try r.approve()
            r.hub.refreshTemplates(); XCTAssertNotNil(r.owner.session?.completion)
            switch change {
            case 0: r.hub.settings.language = "en"; r.hub.settings.language = "hi"
            case 1: let old = r.preparation; r.preparation = UUID(); r.owner.preparationChanged(); r.preparation = old
            case 2: let old = r.selection; r.selection = UUID(); r.owner.observeSaved(); r.selection = old
            case 3: r.owner.observe(.focusSampled(gen:-1,focus:.secure))
            case 4: r.secure = true; r.hub.copyTemplate(); r.secure = false
            case 5: let original = r.memory.settings; r.memory.settings = Data("{broken".utf8); r.hub.refreshTemplates(); r.memory.settings = original
            default:
                let d = try XCTUnwrap(r.hub.templateDocument.definitions.first); var edit = d; edit.name = "new revision"
                _ = try r.store.saveTemplateDefinition(edit,expectedRevision:d.revision)
            }
            XCTAssertNil(r.owner.session); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
            XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            if r.hub.hasPendingSettingsSave {r.hub.onSaved = {}; r.hub.flushPendingSave()}
            try await r.close()
        }
    }
    @MainActor func testT20ActualRetainedWindowPageEditorAndPreparationControlsRevoke() async throws {
        let r = try GuidedRig(), window = HubWindowController(model:r.hub)
        for action in 0..<5 {
            await r.begin(); r.owner.start(); r.engine.feed()
            switch action {
            case 0: window.windowWillClose(Notification(name:NSWindow.willCloseNotification))
            case 1: window.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification))
            case 2: r.hub.requestedPage = .general; r.hub.requestedPage = nil
            case 3: r.hub.editTemplate(r.hub.selectedTemplateID); r.hub.cancelTemplateEditor()
            default: r.hub.leaveTemplates()
            }
            XCTAssertNil(r.owner.session); XCTAssertFalse(r.engine.isRunning); XCTAssertTrue(r.admission.isAvailable)
        }
        try await r.close()
    }
    @MainActor func testT26ShippingQuitIntentBeforeLocalDrainAndCanceledQuitCannotRevive() async throws {
        let r = try GuidedRig(), entered = expectation(description:"quit native held"), exit = DispatchSemaphore(value:0)
        r.native.decode = {entered.fulfill(); exit.wait()}; await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of:[entered],timeout:3)
        let reply = expectation(description:"termination replies after native exit"); var replies:[Bool] = []
        let coordinator = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},
            localCleanup:{done in r.local.beginShutdown(chain:{r.chain},reply:done)},cancelLocalCleanup:{r.local.cancelShutdown()},
            cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0); reply.fulfill()},failure:{},
            onIntent:{AppDelegate.guidedQuitIntent(r.owner,imports:r.hub.audioImport)})
        XCTAssertEqual(coordinator.request(),.terminateLater); XCTAssertEqual(coordinator.request(),.terminateLater)
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(replies.isEmpty)
        exit.signal(); await r.chain?.value; await fulfillment(of:[reply],timeout:3)
        XCTAssertEqual(replies,[true]); XCTAssertTrue(r.owner.readyForRestart); r.local.cancelShutdown()
        r.native.decode = nil; await r.begin(); XCTAssertNotNil(r.owner.session)
        let canceled = TerminationCoordinator(clipboard:{$0(false)},updater:{$0(true)},localCleanup:{done in r.local.beginShutdown(chain:{r.chain},reply:done)},
            cancelLocalCleanup:{r.local.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{_ in},failure:{},
            onIntent:{AppDelegate.guidedQuitIntent(r.owner,imports:r.hub.audioImport)})
        XCTAssertEqual(canceled.request(),.terminateCancel); XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.readyForRestart)
        try await r.close()
    }
    @MainActor func testT27ActualShippingRestartReservationsUnwindAndUpdateFailureNeverRevives() async throws {
        let r = try GuidedRig(), apple = AppleOwnerRig(), imports = SavedAudioImportOwner(root:r.root.appendingPathComponent("saved"))
        let base = r.makeFactory()
        let para = ParakeetPreparation(inputs:.init(release:{nil},terms:{nil},product:{nil},os:{"synthetic"},host:.supported),
            storage:ParakeetInstallationStorage(root:r.root.appendingPathComponent("installation"),transport:G2aTransport([:]),hook:{_ in}),
            trust:base.parakeetTrust,app:base.parakeetApp,worker:base.parakeetWorker)
        let experimental = ExperimentalHistoryRetryOwner(), reservation = ImportRestartReservation()
        await imports.drain(); await r.begin()
        let claimed = await AppDelegate.withSavedImportRestart(imports,parakeet:para,apple:apple.owner,local:r.local,experimental:experimental,guided:r.owner,
            chain:{r.chain},reservation:reservation,claim:{XCTAssertTrue(r.owner.readyForRestart); return true})
        XCTAssertTrue(claimed); XCTAssertTrue(reservation.isHeld); XCTAssertNil(r.owner.session)
        let update = UpdateTerminationIntent(); XCTAssertFalse(update.installFailed(releaseRestart:{reservation.release()}))
        XCTAssertFalse(reservation.isHeld); XCTAssertNil(r.owner.session)
        await r.begin(); XCTAssertNotNil(r.owner.session)
        XCTAssertTrue(experimental.reserveRestart())
        let rejected = await AppDelegate.withSavedImportRestart(imports,parakeet:para,apple:apple.owner,local:r.local,experimental:experimental,guided:r.owner,
            chain:{r.chain},claim:{XCTFail("Partially rejected reservation reached commit"); return true})
        XCTAssertFalse(rejected); XCTAssertNil(r.owner.session); XCTAssertFalse(para.admissionClosed)
        experimental.releaseRestart(); try imports.store.close(); try await r.close()
    }
}


private final class GuidedSpeechConverter: AppleSpeechConverter {
    let format = AppleSpeechFormat(rate:16000,channels:1,bytesPerFrame:4)
    var consumedSourceSamples = 0, ended = false
    let count: Int
    init(_ count: Int) {self.count = count}
    func next() throws -> AppleSpeechBuffer? {
        guard consumedSourceSamples < count else {ended = true; return nil}
        let n = min(16000,count-consumedSourceSamples); consumedSourceSamples += n
        return AppleSpeechBuffer(frames:n,bytes:n*4,payload:NSObject())
    }
}
private final class GuidedSpeechSession: AppleSpeechSession {
    let collected = RecognitionTestLatch(), release = RecognitionTestLatch(), canceled = RecognitionTestLatch(), cancelRelease = RecognitionTestLatch()
    var hold = false, holdCancel = false, calls = 0, cancels = 0
    var samples: [Float] = []
    func converter(samples:[Float]) async throws -> AppleSpeechConverter {self.samples = samples; calls += 1; return GuidedSpeechConverter(samples.count)}
    func collect(ready:@escaping () -> Void,_ emit:@escaping (AppleSpeechEvent) throws -> Void) async throws {
        ready(); await release.wait()
        try emit(.init(text:"spoken native",start:.init(0,16000),end:.init(4000,16000),finalization:.init(4000,16000)))
    }
    func analyze(_ input:AppleSpeechInput) async throws -> AppleSpeechTime? {while try input.next() != nil {}; return .init(input.frames,16000)}
    func finalize(through:AppleSpeechTime) async throws {collected.signal(); if hold {await release.wait()}; release.signal()}
    func cancelAndFinish() async {cancels += 1; canceled.signal(); if holdCancel {await cancelRelease.wait()}; release.signal(); release.signal()}
}
private struct GuidedParaProduct {
    let binary:Data, resource = Data("bounded synthetic resource".utf8), identity:ParakeetProductIdentity
    init() {
        var binary = Data()
        for n:UInt32 in [0xfeedfacf,0x0100000c,0,2,1,24,0,0,0x32,24,1,0x000e0000,0,0] {
            binary.append(contentsOf:[UInt8(n & 255),UInt8(n >> 8 & 255),UInt8(n >> 16 & 255),UInt8(n >> 24)])
        }
        self.binary = binary
        identity = .init(protocolVersion:1,adapterRevision:1,sdk:ParakeetWire.sdk,
            helperSHA256:ParakeetDataRelease.sha256(binary),sourceSHA256:String(repeating:"a",count:64),
            resources:["Contents/Resources/fixture":ParakeetDataRelease.sha256(resource)],team:"TESTTEAM123")
    }
    var trust:ParakeetTrustBottom {.init(host:{},read:{url,_ in
        switch url.lastPathComponent {
        case "parakeet-product.json": return try JSONEncoder().encode(identity)
        case "ParlaParakeetHelper": return binary
        case "fixture": return resource
        default: throw ParakeetRefusal.codeIdentity
        }
    },signature:{_,team in XCTAssertEqual(team,identity.team)})}
}
extension GuidedTemplateLifecycleTests {
    @MainActor func testT15ActualAppleAndParakeetFactoriesUseFreshFullRawTakeAndRetake() async throws {
        for apple in [true,false] {
            let r = try GuidedRig(); var s = try r.store.savedRetrySnapshot()
            s.recognitionEngine = apple ? .appleSpeech : .parakeet; s.appleSpeechLocale = "en-US"
            try r.store.save(s)
            var constructors = 0, leases = 0, releases = 0
            var sessions:[GuidedSpeechSession] = [], children:[G2aChild] = []
            let product = GuidedParaProduct()
            r.factoryProvider = {
                var factory = r.makeFactory()
                if apple {
                    factory.appleBottom = .init(available:{},session:{locale in
                        XCTAssertEqual(locale,"en-US"); constructors += 1
                        let session = GuidedSpeechSession(); sessions.append(session); return session
                    })
                    factory.appleInstalledUse = {_,operation in
                        leases += 1; return AppleSpeechLease(operation:try XCTUnwrap(operation),retirement:{releases += 1})
                    }
                } else {
                    factory.parakeetPreparedUse = {selection,_ in
                        XCTAssertEqual(selection,s.recognitionSelectionForGuidedTest); leases += 1
                        return .init(directory:r.root.appendingPathComponent("synthetic-installation"),product:product.identity,osScope:"synthetic-os",release:{releases += 1})
                    }
                    factory.parakeetTrust = product.trust
                    factory.parakeetWorker = .init(launch:{_ in
                        constructors += 1; let child = G2aChild(text:"spoken native"); children.append(child); return child
                    })
                }
                return factory
            }
            await r.begin()
            for _ in 0..<3 {await r.take(); XCTAssertEqual(r.owner.session?.candidate,"spoken native"); r.owner.accept()}
            // Apple holds acquisition and recognition leases; both survive the owned native joins.
            XCTAssertEqual(constructors,3); XCTAssertEqual(leases,apple ? 6 : 3); XCTAssertEqual(releases,apple ? 6 : 3)
            XCTAssertTrue(r.native.paths.isEmpty); XCTAssertTrue(r.native.calls.isEmpty)
            XCTAssertEqual(sessions.map(\.calls),apple ? [1,1,1] : [])
            for session in sessions {XCTAssertEqual(session.samples,[Float](repeating:0.25,count:8000))}
            XCTAssertEqual(children.count,apple ? 0 : 3); try await r.close()
        }
    }
    @MainActor func testT17AppleCollectorAndCancellationJoinHoldSessionUntilActualExit() async throws {
        let r = try GuidedRig(), session = GuidedSpeechSession(); session.hold = true; session.holdCancel = true
        var s = try r.store.savedRetrySnapshot(); s.recognitionEngine = .appleSpeech; s.appleSpeechLocale = "en-US"; try r.store.save(s)
        var retired = 0
        r.factoryProvider = {var f = r.makeFactory(); f.appleBottom = .init(available:{},session:{_ in session})
            f.appleInstalledUse = {_,op in .init(operation:try XCTUnwrap(op),retirement:{retired += 1})}; return f}
        await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop(); await session.collected.wait()
        r.owner.cancel(); await session.canceled.wait()
        XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.owner.readyForRestart); XCTAssertNil(r.owner.session); XCTAssertEqual(retired,0)
        r.hub.beginTemplate(); XCTAssertEqual(r.engine.starts,1)
        session.cancelRelease.signal(); await r.chain?.value
        XCTAssertEqual(retired,2); XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.memory.copies.isEmpty)
        try await r.close()
    }
    @MainActor func testT17ParakeetTerminalIOExitAndPipeJoinAreSeparateFromPublication() async throws {
        let r = try GuidedRig(), product = GuidedParaProduct(), join = G2aLatch(), joined = G2aLatch()
        let child = G2aChild(holdExit:true,holdIO:true,join:join,joined:joined,text:"late terminal")
        var s = try r.store.savedRetrySnapshot(); s.recognitionEngine = .parakeet; try r.store.save(s)
        var retired = 0
        r.factoryProvider = {var f = r.makeFactory(); f.parakeetTrust = product.trust
            f.parakeetPreparedUse = {_,_ in .init(directory:r.root.appendingPathComponent("synthetic-installation"),product:product.identity,osScope:"synthetic-os",release:{retired += 1})}
            f.parakeetWorker = .init(launch:{_ in child}); return f}
        await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop(); await child.native.loaded.wait()
        r.owner.cancel(); XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession)
        await child.native.finishIO(); XCTAssertTrue(r.owner.ownsSession); XCTAssertEqual(retired,0)
        await child.exit.finish(); await joined.wait(); XCTAssertTrue(r.owner.ownsSession); XCTAssertEqual(retired,0)
        await join.signal(); await r.chain?.value
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertEqual(retired,1); XCTAssertTrue(r.history.entries.isEmpty)
        try await r.close()
    }
}
private extension Settings {
    var recognitionSelectionForGuidedTest:RecognitionSelection {RecognitionRequest(settings:self).selection}
}


extension GuidedTemplateLifecycleTests {
    @MainActor func testT10ExactLiveLeaseRejectsWrongSessionCaptureAndStaleStop() async throws {
        let c = GuidedClock(), engine = GuidedEngine(), admission = CaptureAdmission()
        let recorder = AudioRecorder(engine:engine,admission:admission,conversion:{_ in [Float](repeating:0.25,count:8000)},guidedDrain:{.success([])},captureClock:{c.now},scheduleRoute:c.schedule)
        let adapter = RecorderGuidedTemplateCapture(recorder:recorder), session = UUID(), first = UUID(), lease = admission.acquire(.guidedTemplate)!
        try adapter.reserve(session:session,lease:lease)
        XCTAssertThrowsError(try adapter.start(session:UUID(),capture:first,lease:lease,inputUID:nil))
        try adapter.start(session:session,capture:first,lease:lease,inputUID:"owned-input"); engine.feed()
        XCTAssertNil(adapter.stop(session:UUID(),capture:first,lease:lease)); XCTAssertNil(adapter.stop(session:session,capture:UUID(),lease:lease))
        adapter.clear(session:session,capture:UUID(),lease:lease); adapter.release(session:UUID(),lease:lease)
        XCTAssertTrue(engine.isRunning); XCTAssertTrue(recorder.stop().isEmpty); XCTAssertNil(recorder.stopCanceledCapture(operationID:first,retain:true))
        XCTAssertEqual(adapter.stop(session:session,capture:first,lease:lease)?.samples.count,8000)
        XCTAssertNil(adapter.stop(session:session,capture:first,lease:lease))
        let next = UUID(); try adapter.start(session:session,capture:next,lease:lease,inputUID:nil)
        adapter.clear(session:session,capture:first,lease:lease); XCTAssertTrue(engine.isRunning)
        adapter.clear(session:session,capture:next,lease:lease); adapter.release(session:session,lease:lease); admission.release(lease)
        XCTAssertTrue(admission.isAvailable); XCTAssertEqual(recorder.retainedAudioCounts.samples,0)
    }
    @MainActor func testT11StartFailureAndWarmthRemainColdThroughoutWizardAndAfterDisposal() async throws {
        let r = try GuidedRig(); r.recorder.setWarm(true); XCTAssertTrue(r.engine.isRunning)
        let oldTap = try XCTUnwrap(r.engine.receive), oldRoute = try XCTUnwrap(r.engine.changed)
        r.engine.feed(); XCTAssertGreaterThan(r.recorder.retainedAudioCounts.preRoll,0)
        await r.begin(); XCTAssertFalse(r.engine.isRunning); XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll,0)
        r.recorder.resumeWarmthOnExplicitEntry(); XCTAssertFalse(r.engine.isRunning)
        r.engine.fail = true; r.owner.start(); XCTAssertFalse(r.owner.recording); XCTAssertNil(r.owner.session?.take)
        XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.engine.isRunning)
        r.engine.fail = false; await r.take("only post start"); r.owner.accept(); r.owner.review()
        for _ in 0..<3 {r.recorder.setWarm(true); r.recorder.resumeWarmthOnExplicitEntry(); oldTap(GuidedEngine.buffer()); oldRoute()}
        XCTAssertFalse(r.engine.isRunning); XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll,0)
        r.owner.approve(try XCTUnwrap(r.owner.session?.preview).id); XCTAssertFalse(r.engine.isRunning)
        r.owner.cancel(); XCTAssertFalse(r.engine.isRunning)
        r.recorder.resumeWarmthOnExplicitEntry(); XCTAssertTrue(r.engine.isRunning)
        r.recorder.setWarm(false); XCTAssertFalse(r.engine.isRunning); try await r.close()
    }
    @MainActor func testT18T25AbsoluteExpiryAcrossPublishedAndQueuedActualExitStages() async throws {
        for stage in 0..<9 {
            let r = try GuidedRig()
            var exit:RecognitionTestLatch?
            if stage == 6 {
                let entered = RecognitionTestLatch(), held = RecognitionTestLatch(); exit = held
                r.chain = PendingOperationQueue.enqueue(previous:nil,operation:PendingOperation(name:"held admission"),completes:true,work:{entered.signal(); await held.wait()})
                await entered.wait(); r.hub.beginTemplate()
            } else {await r.begin()}
            if stage == 1 {r.owner.start(); r.engine.feed()}
            if (2...5).contains(stage) {await r.take()}
            if (3...5).contains(stage) {r.owner.accept()}
            if (4...5).contains(stage) {r.owner.review()}
            if stage == 5 {r.owner.approve(try XCTUnwrap(r.owner.session?.preview).id)}
            var nativeExit:DispatchSemaphore?
            if stage >= 7 {
                let entered = expectation(description:"expiry native stage"), held = DispatchSemaphore(value:0); nativeExit = held
                if stage == 7 {r.native.construct = {entered.fulfill(); held.wait()}}
                else {r.native.decode = {entered.fulfill(); held.wait()}}
                r.owner.start(); r.engine.feed(); r.owner.stop(); await fulfillment(of:[entered],timeout:3)
                if stage == 8 {r.owner.cancel(); XCTAssertTrue(r.owner.busy)}
            }
            r.clock.advance(1200); XCTAssertNil(r.owner.session); XCTAssertFalse(r.owner.recording)
            r.hub.copyTemplate(); r.hub.saveCompletedTemplate(); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            if stage >= 6 {XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)}
            exit?.signal(); nativeExit?.signal(); await r.chain?.value
            XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable); try await r.close()
        }
    }
    @MainActor func testT18CancelAfterQueuedTakeBeforeAcquisitionSettlesExactlyOnce() async throws {
        let r = try GuidedRig(); await r.begin()
        let entered = RecognitionTestLatch(), exit = RecognitionTestLatch()
        r.chain = PendingOperationQueue.enqueue(previous:r.chain,operation:PendingOperation(name:"prior actual completion"),completes:true,work:{entered.signal(); await exit.wait()})
        await entered.wait(); r.owner.start(); r.engine.feed(); r.owner.stop()
        r.owner.cancel(); r.owner.stop(); r.owner.discardTake(); r.hub.beginTemplate()
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.native.paths.isEmpty)
        exit.signal(); await r.chain?.value
        XCTAssertTrue(r.native.paths.isEmpty); XCTAssertTrue(r.owner.readyForRestart)
        XCTAssertEqual(r.queued,r.finished); await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate)
        try await r.close()
    }
    @MainActor func testT25AbsoluteExpiryOfQueuedTakeSkipsAcquisitionButJoinsPredecessor() async throws {
        let r = try GuidedRig(); await r.begin()
        let entered = RecognitionTestLatch(), exit = RecognitionTestLatch(), predecessor = PendingOperation(name:"held queued-take predecessor")
        r.chain = PendingOperationQueue.enqueue(previous:r.chain,operation:predecessor,completes:true,work:{entered.signal(); await exit.wait()})
        await entered.wait(); r.owner.start(); r.engine.feed(); r.owner.stop()
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.native.paths.isEmpty)
        r.clock.advance(1200)
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy)
        XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertFalse(predecessor.hasExited)
        r.hub.beginTemplate(); r.owner.start(); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertEqual(r.engine.starts,1); XCTAssertTrue(r.native.paths.isEmpty)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
        exit.signal(); await r.chain?.value
        XCTAssertTrue(predecessor.hasExited); XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        XCTAssertFalse(HotkeyMonitor.suspended); XCTAssertEqual(r.queued,r.finished)
        XCTAssertEqual(r.native.admissions,0); XCTAssertEqual(r.native.metadataReads,0); XCTAssertTrue(r.native.paths.isEmpty)
        await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate)
        try await r.close()
    }
    @MainActor func testT20ShippingSecurityPreludeAndActualPreparationControlsRevokeBeforeLateEvents() async throws {
        for mode in 0..<4 {
            let r = try GuidedRig(), apple = AppleOwnerRig(); r.hub.bindAppleSpeech(apple.owner)
            r.hub.onPreparationConsent = {_ in}
            await r.begin(); XCTAssertNotNil(r.owner.session); r.owner.start(); r.engine.feed(); XCTAssertTrue(r.engine.isRunning)
            switch mode {
            case 0:
                let stale = DictationSession.Session(gen:-99,mode:.dictation,settings:try r.store.savedRetrySnapshot(),cleanupConfigured:true,live:false,diagnostics:nil)
                stale.operation.revoke()
                AppDelegate.observeTransientSecurity(.transcribed(stale,raw:"irrelevant",probe:.init(focus:.secure)),templates:r.owner,imports:r.hub.audioImport)
            case 1: r.hub.setPreparationEnabled(true)
            case 2: r.hub.onAppleSpeechAction(.prepare,"en-US",UUID())
            default: r.hub.loadError = "synthetic saved settings failure"
            }
            XCTAssertNil(r.owner.session); XCTAssertFalse(r.engine.isRunning); r.hub.copyTemplate(); XCTAssertTrue(r.memory.copies.isEmpty)
            if r.hub.hasPendingSettingsSave {r.hub.onSaved = {}; r.hub.flushPendingSave()}
            r.hub.loadError = nil; try await r.close()
        }
    }
    @MainActor func testT26IdleLookingWizardQuitRegistersBeforeAwaitAndKeepsAllParticipants() async throws {
        for stage in 0..<4 {
            let r = try GuidedRig()
            await r.begin()
            if stage == 1 {r.owner.start(); r.engine.feed()}
            if stage >= 2 {await r.take(); r.owner.accept(); r.owner.review()}
            if stage == 3 {r.owner.approve(try XCTUnwrap(r.owner.session?.preview).id)}
            var order:[String] = [], replies:[Bool] = []
            let coordinator = TerminationCoordinator(clipboard:{order.append("clipboard"); $0(true)},updater:{order.append("updater"); $0(true)},
                localCleanup:{done in order.append("local"); XCTAssertTrue(r.owner.readyForRestart); r.local.beginShutdown(chain:{r.chain},reply:done)},cancelLocalCleanup:{r.local.cancelShutdown()},
                cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0)},failure:{},onIntent:{order.append("intent"); AppDelegate.guidedQuitIntent(r.owner,imports:r.hub.audioImport)})
            XCTAssertEqual(coordinator.request(),.terminateNow); XCTAssertEqual(order.first,"intent"); XCTAssertTrue(order.contains("clipboard")); XCTAssertTrue(order.contains("updater")); XCTAssertTrue(order.contains("local"))
            XCTAssertNil(r.owner.session); XCTAssertFalse(r.engine.isRunning); r.local.cancelShutdown()
            try await r.close()
        }
    }
    @MainActor func testT27EveryConcretePartialRestartReservationUnwindsWithoutRevival() async throws {
        for blocked in 0..<5 {
            let r = try GuidedRig(), apple = AppleOwnerRig(), saved = SavedAudioImportOwner(root:r.root.appendingPathComponent("saved")), base = r.makeFactory()
            let para = ParakeetPreparation(inputs:.init(release:{nil},terms:{nil},product:{nil},os:{"synthetic"},host:.supported),storage:.init(root:r.root.appendingPathComponent("installation"),transport:G2aTransport([:]),hook:{_ in}),trust:base.parakeetTrust,app:base.parakeetApp,worker:base.parakeetWorker)
            let experimental = ExperimentalHistoryRetryOwner()
            await saved.drain(); await r.begin()
            let reserve:[() -> Bool] = [{para.reserveRestart()},{apple.owner.reserveRestart()},{r.local.reserveRestart()},{experimental.reserveRestart()},{saved.reserveRestart()}]
            let release:[() -> Void] = [{para.releaseRestart()},{apple.owner.releaseRestart()},{r.local.releaseRestart()},{experimental.releaseRestart()},{saved.releaseRestart()}]
            XCTAssertTrue(reserve[blocked]())
            let allowed = await AppDelegate.withSavedImportRestart(saved,parakeet:para,apple:apple.owner,local:r.local,experimental:experimental,guided:r.owner,chain:{r.chain},claim:{XCTFail("rejected participant reached updater"); return true})
            XCTAssertFalse(allowed); XCTAssertNil(r.owner.session)
            for i in 0..<5 {
                if i == blocked {XCTAssertFalse(reserve[i](),"preexisting reservation released")}
                else {XCTAssertTrue(reserve[i](),"acquired set leaked at \(i)"); release[i]()}
            }
            release[blocked](); try saved.store.close(); try await r.close()
        }
    }
}


private final class GuidedSpeechDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var now:TimeInterval = 100
    private var waiter:CheckedContinuation<Void,Error>?
    private var canceled = false
    let waiting = XCTestExpectation(description:"fake Apple watchdog waiting")
    var clock:AppleSpeechClock {.init(now:{self.lock.withLock{self.now}},wait:{_ in
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {(c:CheckedContinuation<Void,Error>) in
                let stop = self.lock.withLock {() -> Bool in if self.canceled {return true}; self.waiter = c; return false}
                if stop {c.resume(throwing:CancellationError())}; self.waiting.fulfill()
            }
        },onCancel:{
            let c = self.lock.withLock {() -> CheckedContinuation<Void,Error>? in self.canceled = true; let c = self.waiter; self.waiter = nil; return c}
            c?.resume(throwing:CancellationError())
        })
    })}
    func expire() {
        let c = lock.withLock {() -> CheckedContinuation<Void,Error>? in now = 161; let c = waiter; waiter = nil; return c}
        c?.resume()
    }
}
extension GuidedTemplateLifecycleTests {
    @MainActor func testT17AppleWatchdogAndHeldAcquisitionDoNotInventActualExit() async throws {
        for acquiring in [false,true] {
            let r = try GuidedRig(), speech = GuidedSpeechSession(), watchdog = GuidedSpeechDeadline()
            let entered = RecognitionTestLatch(), release = RecognitionTestLatch()
            var s = try r.store.savedRetrySnapshot(); s.recognitionEngine = .appleSpeech; s.appleSpeechLocale = "en-US"; try r.store.save(s)
            var retired = 0
            speech.hold = true; speech.holdCancel = true
            r.factoryProvider = {
                var f = r.makeFactory(); f.appleClock = watchdog.clock
                f.appleBottom = .init(available:{},session:{_ in speech})
                f.appleInstalledUse = {_,op in
                    if acquiring {entered.signal(); await release.wait()}
                    return .init(operation:try XCTUnwrap(op),retirement:{retired += 1})
                }; return f
            }
            await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop()
            if acquiring {await entered.wait()}
            else {
                await speech.collected.wait(); await fulfillment(of:[watchdog.waiting],timeout:3)
                watchdog.expire(); await speech.canceled.wait()
            }
            r.owner.cancel(); XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertEqual(retired,0)
            r.hub.beginTemplate(); XCTAssertEqual(r.engine.starts,1); XCTAssertFalse(r.admission.isAvailable)
            if acquiring {release.signal()} else {speech.cancelRelease.signal()}
            await r.chain?.value; XCTAssertTrue(r.owner.readyForRestart); XCTAssertEqual(retired,acquiring ? 1 : 2)
            XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty); try await r.close()
        }
    }
    @MainActor func testT27ActualRestartWaitsForGuidedNativeAndReservesAllParticipantsBeforeAwait() async throws {
        let r = try GuidedRig(), apple = AppleOwnerRig(), saved = SavedAudioImportOwner(root:r.root.appendingPathComponent("saved")), base = r.makeFactory()
        let para = ParakeetPreparation(inputs:.init(release:{nil},terms:{nil},product:{nil},os:{"synthetic"},host:.supported),storage:.init(root:r.root.appendingPathComponent("installation"),transport:G2aTransport([:]),hook:{_ in}),trust:base.parakeetTrust,app:base.parakeetApp,worker:base.parakeetWorker)
        let experimental = ExperimentalHistoryRetryOwner(), entered = expectation(description:"restart actual native"), release = DispatchSemaphore(value:0)
        await saved.drain(); r.native.decode = {entered.fulfill(); release.wait()}
        await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop(); await fulfillment(of:[entered],timeout:3)
        let reserved = expectation(description:"restart sampled actual chain"), witness = PendingOperation(name:"closed restart witness")
        var observed = false, claims = 0
        let task = Task { @MainActor in
            await AppDelegate.withSavedImportRestart(saved,parakeet:para,apple:apple.owner,local:r.local,experimental:experimental,guided:r.owner,chain:{
                if !observed {observed = true; reserved.fulfill()}
                return r.chain
            },claim:{claims += 1; return false})
        }
        await fulfillment(of:[reserved],timeout:3)
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(para.admissionClosed); XCTAssertTrue(apple.owner.admissionClosed)
        XCTAssertFalse(experimental.admits); XCTAssertFalse(r.local.admit(witness)); XCTAssertFalse(saved.reserveRestart()); XCTAssertEqual(claims,0)
        release.signal(); let claimed = await task.value; XCTAssertFalse(claimed); XCTAssertEqual(claims,1)
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertFalse(para.admissionClosed); XCTAssertFalse(apple.owner.admissionClosed); XCTAssertTrue(experimental.admits)
        XCTAssertTrue(r.local.admit(witness)); r.local.exited(witness); witness.finish()
        XCTAssertTrue(saved.reserveRestart()); saved.releaseRestart(); try saved.store.close(); try await r.close()
    }
    @MainActor func testT26ResourceFreeOwnerWithoutHubRegistersAndDrainsAdmissionBarrier() async throws {
        let c = GuidedClock(), engine = GuidedEngine(), admission = CaptureAdmission(), local = LocalCleanupAdmission()
        let recorder = AudioRecorder(engine:engine,admission:admission,conversion:{_ in []},guidedDrain:{.success([])},captureClock:{c.now},scheduleRoute:c.schedule)
        let definition = GuidedTemplateDefinition(name:"No Hub yet",body:"{{x}}",fields:[.init(key:"x",label:"X")])
        var s = Settings(); s.whisperModelPath = "/synthetic/no-model.bin"; s.guidedTemplates = .init(definitions:[definition])
        let bytes = try JSONEncoder().encode(s), backend = FakeCredentialBackend()
        let store = SettingsStore(url:URL(fileURLWithPath:"/synthetic/no-hub-settings"),credentials:CredentialStore(backend:backend),documentIO:.init(read:{bytes}))
        let owner = GuidedTemplateOwner(), imports = AudioImportOwner(), entered = RecognitionTestLatch(), release = RecognitionTestLatch()
        let preparation = UUID(), selection = UUID()
        owner.bind(store:store,capture:RecorderGuidedTemplateCapture(recorder:recorder),admission:admission,local:local)
        owner.security = {false}; owner.permission = {true}; owner.allowed = {true}; owner.draftReady = {true}
        owner.clock = {c.now}; owner.schedule = c.schedule; owner.preparationEpoch = {preparation}; owner.selectionEpoch = {selection}; owner.preparationRefusal = {_ in nil}
        var chain:Task<Void,Never>? = PendingOperationQueue.enqueue(previous:nil,operation:PendingOperation(name:"before Hub barrier"),completes:true,work:{entered.signal(); await release.wait()})
        await entered.wait()
        owner.enqueue = {op,work,done in chain = PendingOperationQueue.enqueue(previous:chain,operation:op,completes:true,work:work,finished:done)}
        XCTAssertEqual(engine.starts,0); owner.begin(definition); XCTAssertTrue(owner.ownsSession); XCTAssertTrue(owner.busy)
        let replied = expectation(description:"no Hub lifetime drained"), coordinator = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},localCleanup:{local.beginShutdown(chain:{chain},reply:$0)},cancelLocalCleanup:{local.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{XCTAssertTrue($0); replied.fulfill()},failure:{},onIntent:{AppDelegate.guidedQuitIntent(owner,imports:imports)})
        XCTAssertEqual(coordinator.request(),.terminateLater); XCTAssertTrue(owner.ownsSession); XCTAssertNil(owner.session)
        release.signal(); await chain?.value; await fulfillment(of:[replied],timeout:3)
        XCTAssertTrue(owner.readyForRestart); XCTAssertTrue(admission.isAvailable); XCTAssertEqual(engine.starts,0)
        XCTAssertEqual(backend.reads+backend.statuses+backend.adds+backend.updates+backend.deletes,0)
    }
}


/// Memory-only health storage: no bundle, model file or private preparation namespace.
private final class GuidedSafeStartStorage: PreparationStorage {
    private let lock = NSLock()
    private var bytes: Data?
    private var failTerminal = false
    private var terminalNotifications: [(PreparationPhase, UUID)] = []
    private var notifiedAttempts = Set<UUID>()
    private var replaceHook: ((PreparationLedger?, PreparationLedger) -> Void)?
    var beforeReplace: ((PreparationLedger?, PreparationLedger) -> Void)? {
        get { lock.withLock { replaceHook } }
        set { lock.withLock { replaceHook = newValue } }
    }
    var failTerminalWrites: Bool {
        get { lock.withLock { failTerminal } }
        set { lock.withLock { failTerminal = newValue } }
    }
    var ledger: PreparationLedger? { lock.withLock { bytes.flatMap { try? JSONDecoder().decode(PreparationLedger.self, from: $0) } } }
    func takeTerminalNotification(phase: PreparationPhase = .nativeConstruction, attempt: UUID? = nil) -> Bool {
        lock.withLock {
            guard let index = terminalNotifications.firstIndex(where: { $0.0 == phase && (attempt == nil || $0.1 == attempt) }) else { return false }
            terminalNotifications.remove(at: index); return true
        }
    }
    func read() throws -> Data? { lock.withLock { bytes } }
    func replace(_ data: Data, authorized: () -> Bool) throws {
        let next = try JSONDecoder().decode(PreparationLedger.self, from: data)
        let observation = lock.withLock { (bytes.flatMap { try? JSONDecoder().decode(PreparationLedger.self, from: $0) }, replaceHook) }
        observation.1?(observation.0, next) // No fixture lock is held over an observation wait.
        try lock.withLock {
            guard authorized() else { throw PreparationRefusal.revoked }
            let previous = bytes.flatMap { try? JSONDecoder().decode(PreparationLedger.self, from: $0) }
            let retired = next.entries.compactMap { entry -> (PreparationPhase, UUID)? in
                guard entry.pending == nil, let attempt = entry.consumed,
                      previous?.entries.contains(where: { $0.key == entry.key && $0.pending?.attempt == attempt }) == true else { return nil }
                return (entry.key.p, attempt)
            }
            if !retired.isEmpty {
                for event in retired where notifiedAttempts.insert(event.1).inserted { terminalNotifications.append(event) }
                if failTerminal { throw PreparationRefusal.trackingUnavailable }
            }
            bytes = data
        }
    }
    func quarantine() throws { throw PreparationRefusal.trackingUnavailable }
    func reset(_ data: Data) throws { lock.withLock { bytes = data } }
}

extension GuidedTemplateLifecycleTests {
    @MainActor func testS1AuthorizedColdSafeStartRefreshKeepsCurrentFormAndJoinsExit() async throws {
        let r = try GuidedRig(), memory = GuidedSafeStartStorage(), consent = UUID()
        let build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
        let core = RecognitionPreparation(storage: { memory }, build: { build })
        let preparation = NativePreparation(core: core, catalogSelection: { _ in true })
        var saved = try r.store.savedRetrySnapshot()
        let directory = r.root.appendingPathComponent("synthetic-models")
        saved.whisperModelPath = directory.appendingPathComponent(ModelCatalog.default.filename).path
        saved.nativePreparationSafeStartEnabled = true; saved.nativePreparationConsent = consent
        r.memory.settings = try JSONEncoder().encode(saved)
        r.hub.loading = true; r.hub.settings = saved; r.hub.settingsBase = saved; r.hub.loading = false
        try core.prepareConsent(consent); preparation.configure(saved, epoch: r.selection)
        r.native.generation = .init(bytes: ModelCatalog.default.bytes, modified: 7)
        r.owner.preparationEpoch = { core.admissionEpoch }
        r.owner.preparationRefusal = { preparation.cachedRefusal(for: $0)?.description }
        r.owner.operationPreparationRefusal = { request, operation, selection, epoch in
            core.cachedRefusal(for: request.selection, operation: operation,
                selectionEpoch: selection, preparationEpoch: epoch)?.description
        }
        let store = r.store
        r.factoryProvider = {
            var factory = r.makeFactory(); let bottom = factory.native
            factory.directory = directory; factory.catalog = [ModelCatalog.default]; factory.preparation = core
            factory.preparationPermission = {
                guard let value = try? store.savedRetrySnapshot() else { return false }
                return core.matchesSavedPermission(value)
            }
            factory.guardedNative = { path, compute, permit in try permit.nativeEntry { try bottom(path, compute) } }
            return factory
        }
        let entered = expectation(description: "actual permitted cold construction held")
        let refreshed = expectation(description: "preparing notification observed on main")
        let leave = DispatchSemaphore(value: 0)
        var observed = false
        preparation.onChange = { snapshot in
            r.hub.preparationSnapshot = snapshot
            r.owner.preparationChanged() // The shipping direct and Hub notification routes.
            if core.hasActiveEntry, !observed { observed = true; refreshed.fulfill() }
        }
        core.changed = { DispatchQueue.main.async { preparation.refresh() } }
        r.native.construct = { entered.fulfill(); leave.wait() }
        defer { leave.signal(); core.changed = nil; preparation.onChange = { _ in }; r.native.construct = nil }
        await r.begin()
        let form = try XCTUnwrap(r.owner.session?.id)
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered, refreshed], timeout: 3)
        XCTAssertEqual(core.snapshot.status, .preparing); XCTAssertTrue(core.hasActiveEntry)
        XCTAssertEqual(r.owner.session?.id, form, "An unchanged current constructor must not revoke its own form.")
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
        leave.signal(); await r.chain?.value
        XCTAssertFalse(core.hasActiveEntry); XCTAssertEqual(core.snapshot.status, .ready)
        XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.candidate, "native original")
        XCTAssertEqual(r.native.paths.count, 1); XCTAssertEqual(r.native.calls.count, 1)
        XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
        core.changed = nil; preparation.onChange = { _ in }; r.native.construct = nil
        try await r.close()
    }
}


/// Real preparation/factory/owner composition above the same explicit fake bottoms as GuidedRig.
@MainActor private final class GuidedSafeStartRig {
    let r: GuidedRig, memory = GuidedSafeStartStorage(), core: RecognitionPreparation, preparation: NativePreparation
    let request: RecognitionRequest
    var operation: PendingOperation?
    init(fields: [String] = ["title"], enabled: Bool = true, buildLookup: @escaping () -> Void = {}) throws {
        let rig = try GuidedRig(fields: fields), storage = memory
        let build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
        let health = RecognitionPreparation(storage: { storage }, build: { buildLookup(); return build })
        let wrapper = NativePreparation(core: health, catalogSelection: { _ in true })
        r = rig; core = health; preparation = wrapper
        var saved = try rig.store.savedRetrySnapshot(); let consent = UUID()
        let directory = rig.root.appendingPathComponent("synthetic-models")
        saved.whisperModelPath = directory.appendingPathComponent(ModelCatalog.default.filename).path
        saved.nativePreparationSafeStartEnabled = enabled; saved.nativePreparationConsent = enabled ? consent : nil
        request = RecognitionRequest(settings: saved)
        rig.memory.settings = try JSONEncoder().encode(saved)
        rig.hub.loading = true; rig.hub.settings = saved; rig.hub.settingsBase = saved; rig.hub.loading = false
        if enabled { try health.prepareConsent(consent) }
        wrapper.configure(saved, epoch: rig.selection)
        rig.native.generation = .init(bytes: ModelCatalog.default.bytes, modified: 7)
        rig.owner.preparationEpoch = { health.admissionEpoch }
        rig.owner.preparationRefusal = { wrapper.cachedRefusal(for: $0)?.description }
        rig.owner.operationPreparationRefusal = { request, operation, selection, epoch in
            health.cachedRefusal(for: request.selection, operation: operation,
                selectionEpoch: selection, preparationEpoch: epoch)?.description
        }
        rig.owner.discardedPreparationAuthority = { request, operation, selection, epoch in
            health.cachedFormAuthority(for: request.selection, discarding: operation,
                selectionEpoch: selection, preparationEpoch: epoch)?.description
        }
        let enqueue = rig.owner.enqueue!
        rig.owner.enqueue = { [weak self] operation, work, done in
            self?.operation = operation; enqueue(operation, work, done)
        }
        let store = rig.store
        rig.factoryProvider = {
            var factory = rig.makeFactory(); let bottom = factory.native
            factory.directory = directory; factory.catalog = [ModelCatalog.default]; factory.preparation = health
            factory.preparationPermission = {
                guard let saved = try? store.savedRetrySnapshot() else { return false }
                return health.matchesSavedPermission(saved)
            }
            factory.guardedNative = { path, compute, permit in try permit.nativeEntry { try bottom(path, compute) } }
            return factory
        }
        wrapper.onChange = { snapshot in
            rig.hub.preparationSnapshot = snapshot
            rig.owner.preparationChanged() // Shipping Hub forwarding plus direct route, in shipping order.
        }
        health.changed = { DispatchQueue.main.async { wrapper.refresh() } }
    }
    func refresh() { preparation.refresh() }
    func refusal(_ operation: PendingOperation, selection: UUID? = nil, epoch: UUID? = nil,
                 target: RecognitionSelection? = nil) -> PreparationRefusal? {
        core.cachedRefusal(for: target ?? request.selection, operation: operation,
            selectionEpoch: selection ?? r.selection, preparationEpoch: epoch ?? core.admissionEpoch)
    }
    func formAuthority(_ operation: PendingOperation, selection: UUID? = nil, epoch: UUID? = nil,
                       target: RecognitionSelection? = nil) -> PreparationRefusal? {
        core.cachedFormAuthority(for: target ?? request.selection, discarding: operation,
            selectionEpoch: selection ?? r.selection, preparationEpoch: epoch ?? core.admissionEpoch)
    }
    func close() async throws {
        await r.chain?.value
        // Drain all already-enqueued main refreshes before detaching the observers.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        core.changed = nil; preparation.onChange = { _ in }; r.native.construct = nil
        r.factoryProvider = nil; try await r.close()
    }
}

extension GuidedTemplateLifecycleTests {
    @MainActor func testS1TerminalSuccessBeforeExitKeepsExactOwnerAndCompetingCallerBusy() async throws {
        let s = try GuidedSafeStartRig(), r = s.r
        let entered = expectation(description: "constructor held"), terminal = expectation(description: "terminal refresh before actual exit")
        let constructorExit = DispatchSemaphore(value: 0), actualExit = DispatchSemaphore(value: 0)
        let core = s.core, memory = s.memory, wrapper = s.preparation
        core.changed = {
            let hold = memory.takeTerminalNotification() && core.hasActiveEntry
            DispatchQueue.main.async { wrapper.refresh(); if hold { terminal.fulfill() } }
            if hold { XCTAssertFalse(Thread.isMainThread); if !Thread.isMainThread { actualExit.wait() } }
        }
        r.native.construct = { entered.fulfill(); constructorExit.wait() }
        defer { constructorExit.signal(); actualExit.signal() }
        await r.begin(); let form = try XCTUnwrap(r.owner.session?.id)
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = core.admissionEpoch
        s.refresh(); XCTAssertEqual(r.owner.session?.id, form); XCTAssertNil(s.refusal(operation))
        XCTAssertEqual(core.cachedRefusal(for: s.request.selection), .busy)
        XCTAssertEqual(s.refusal(PendingOperation(name: "foreign UUID")), .busy)
        XCTAssertEqual(s.refusal(operation, selection: UUID()), .revoked)
        XCTAssertEqual(s.refusal(operation, epoch: UUID()), .revoked)
        XCTAssertEqual(s.refusal(operation, target: .appleSpeech(locale: "en-US")), .busy)
        XCTAssertFalse(operation.shouldAbort); XCTAssertFalse(operation.hasExited); XCTAssertTrue(r.native.calls.isEmpty)
        constructorExit.signal(); await fulfillment(of: [terminal], timeout: 3)
        let ledger = try XCTUnwrap(memory.ledger)
        XCTAssertEqual(ledger.entries.count, 1); XCTAssertNil(ledger.entries.first?.pending)
        XCTAssertNotNil(ledger.entries.first?.consumed); XCTAssertEqual(ledger.entries.first?.outcome, .completed)
        XCTAssertEqual(core.admissionEpoch, epoch); XCTAssertEqual(core.snapshot.status, .preparing)
        XCTAssertTrue(core.hasActiveEntry); XCTAssertNil(s.refusal(operation))
        XCTAssertEqual(core.cachedRefusal(for: s.request.selection), .busy)
        XCTAssertEqual(r.owner.session?.id, form); XCTAssertNil(r.owner.session?.candidate)
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertFalse(operation.shouldAbort); XCTAssertFalse(operation.hasExited)
        XCTAssertTrue(r.native.calls.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        actualExit.signal(); await r.chain?.value
        XCTAssertTrue(operation.hasExited); XCTAssertFalse(core.hasActiveEntry); XCTAssertEqual(core.snapshot.status, .ready)
        XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.candidate, "native original")
        XCTAssertEqual(r.native.paths.count, 1); XCTAssertEqual(r.native.calls.count, 1)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }

    @MainActor func testS1QueuedGuidedTakeCannotBorrowForeignActivePermitAndJoinsPredecessor() async throws {
        let s = try GuidedSafeStartRig(), r = s.r
        let mayEnter = RecognitionTestLatch(), entered = expectation(description: "foreign nativeEntry held")
        let leave = DispatchSemaphore(value: 0), predecessor = PendingOperation(name: "deliberate foreign preparation predecessor")
        defer { mayEnter.signal(); leave.signal() }
        await r.begin(); r.owner.start(); r.engine.feed()
        let request = s.request, selection = r.selection, epoch = s.core.admissionEpoch, factory = try XCTUnwrap(r.factoryProvider)()
        var foreignFactory = factory
        foreignFactory.guardedNative = { path, compute, permit in
            try permit.nativeEntry { entered.fulfill(); leave.wait(); return try factory.native(path, compute) }
        }
        // This fake schedule introduces ONE foreign active constructor, after the guided take queues.
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: predecessor, completes: true, work: {
            await mayEnter.wait()
            do { _ = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: foreignFactory,
                operation: predecessor, selectionEpoch: selection, preparationEpoch: epoch) }
            catch { XCTFail("Foreign predecessor unexpectedly failed: \(error)") }
        })
        r.owner.stop(); let guided = try XCTUnwrap(s.operation)
        XCTAssertEqual(guided.stage, .queued); XCTAssertFalse(guided.hasExited)
        mayEnter.signal(); await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(s.core.hasActiveEntry); XCTAssertNil(s.refusal(predecessor))
        XCTAssertEqual(s.refusal(guided), .revoked) // Notification has revoked the queued guided operation.
        s.refresh(); XCTAssertNil(r.owner.session); XCTAssertTrue(guided.shouldAbort)
        XCTAssertFalse(predecessor.shouldAbort); XCTAssertFalse(predecessor.hasExited); XCTAssertFalse(guided.hasExited)
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertTrue(r.native.paths.isEmpty); XCTAssertTrue(r.native.calls.isEmpty)
        r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, 1)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        leave.signal(); await r.chain?.value
        XCTAssertTrue(predecessor.hasExited); XCTAssertTrue(guided.hasExited); XCTAssertFalse(s.core.hasActiveEntry)
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable); XCTAssertFalse(HotkeyMonitor.suspended)
        // Only the deliberately introduced foreign constructor ran; no guided acquisition/decode occurred.
        XCTAssertEqual(r.native.paths.count, 1); XCTAssertTrue(r.native.calls.isEmpty); XCTAssertNil(r.owner.session)
        try await s.close()
    }

    @MainActor func testS1GenuineDraftRevokeCancelsHeldOwnerWithoutInventingExitOrRevival() async throws {
        let s = try GuidedSafeStartRig(), r = s.r
        let entered = expectation(description: "owned constructor before revoke"), leave = DispatchSemaphore(value: 0)
        r.native.construct = { entered.fulfill(); leave.wait() }; defer { leave.signal() }
        await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation)
        s.refresh(); XCTAssertNotNil(r.owner.session); XCTAssertNil(s.refusal(operation))
        s.preparation.revokeDraft()
        XCTAssertNil(r.owner.session); XCTAssertTrue(operation.shouldAbort); XCTAssertEqual(s.refusal(operation), .revoked)
        XCTAssertTrue(s.core.hasActiveEntry); XCTAssertFalse(operation.hasExited)
        XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertTrue(r.native.calls.isEmpty)
        r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, 1)
        leave.signal(); await r.chain?.value; s.refresh()
        XCTAssertTrue(operation.hasExited); XCTAssertFalse(s.core.hasActiveEntry); XCTAssertNil(r.owner.session)
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertTrue(r.native.calls.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }

    @MainActor func testS1TerminalPersistenceFaultWinsWithSameEpochAndRetainsActualExit() async throws {
        let s = try GuidedSafeStartRig(), r = s.r
        let entered = expectation(description: "constructor before terminal fault"), fault = expectation(description: "fault notification before exit")
        let constructorExit = DispatchSemaphore(value: 0), actualExit = DispatchSemaphore(value: 0)
        let core = s.core, memory = s.memory, wrapper = s.preparation
        core.changed = {
            let hold = memory.takeTerminalNotification() && core.hasActiveEntry
            DispatchQueue.main.async { wrapper.refresh(); if hold { fault.fulfill() } }
            if hold { XCTAssertFalse(Thread.isMainThread); if !Thread.isMainThread { actualExit.wait() } }
        }
        r.native.construct = { entered.fulfill(); constructorExit.wait() }
        defer { constructorExit.signal(); actualExit.signal() }
        await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = core.admissionEpoch, selection = r.selection
        s.refresh(); XCTAssertNotNil(r.owner.session); XCTAssertNil(s.refusal(operation))
        memory.failTerminalWrites = true; constructorExit.signal()
        await fulfillment(of: [fault], timeout: 3)
        XCTAssertEqual(core.admissionEpoch, epoch); XCTAssertEqual(r.selection, selection)
        XCTAssertTrue(core.persistenceFailed); XCTAssertEqual(core.snapshot.status, .trackingUnavailable)
        XCTAssertEqual(s.refusal(operation), .trackingUnavailable)
        XCTAssertEqual(core.cachedRefusal(for: s.request.selection), .busy, "Default competing-caller behavior remains unchanged.")
        XCTAssertNil(r.owner.session); XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(operation.hasExited)
        XCTAssertTrue(core.hasActiveEntry); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy)
        XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
        XCTAssertTrue(r.native.calls.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, 1)
        actualExit.signal(); await r.chain?.value; s.refresh()
        XCTAssertFalse(core.hasActiveEntry); XCTAssertTrue(operation.hasExited); XCTAssertTrue(core.persistenceFailed)
        XCTAssertEqual(core.snapshot.status, .trackingUnavailable); XCTAssertNil(r.owner.session)
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        r.hub.beginTemplate(); XCTAssertNil(r.owner.session); XCTAssertEqual(r.engine.starts, 1)
        r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertTrue(r.native.calls.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }
}


extension GuidedTemplateLifecycleTests {
    @MainActor func testS2DiscardHeldColdTakeKeepsEarlierFieldAndJoinsExit() async throws {
        let s = try GuidedSafeStartRig(fields: ["title", "body"]), r = s.r
        await r.begin(); await r.take("earlier field stays"); r.owner.accept()
        let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
        XCTAssertEqual(accepted.count, 1)
        let entered = expectation(description: "second field native constructor held"), leave = DispatchSemaphore(value: 0)
        r.native.construct = { entered.fulfill(); leave.wait() }; defer { leave.signal() }
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = s.core.admissionEpoch
        r.owner.discardTake(); s.refresh() // Both shipping notification routes observe intentional attempt revocation.
        XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(operation.hasExited); XCTAssertTrue(s.core.hasActiveEntry)
        XCTAssertEqual(s.core.admissionEpoch, epoch); XCTAssertEqual(s.refusal(operation), .revoked)
        XCTAssertEqual(s.memory.ledger?.entries.first?.outcome, .canceled)
        XCTAssertNil(s.memory.ledger?.entries.first?.pending)
        XCTAssertEqual(r.owner.session?.id, form, "Discard take must not cancel its unchanged form.")
        XCTAssertEqual(r.owner.session?.accepted, accepted); XCTAssertNil(r.owner.session?.candidate)
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        let starts = r.engine.starts; r.owner.start(); XCTAssertEqual(r.engine.starts, starts)
        XCTAssertEqual(r.native.calls.count, 1); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        leave.signal(); await r.chain?.value
        XCTAssertTrue(operation.hasExited); XCTAssertFalse(s.core.hasActiveEntry)
        XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
        XCTAssertNil(r.owner.session?.candidate); XCTAssertNil(r.owner.session?.take); XCTAssertFalse(r.owner.busy)
        XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        r.native.construct = nil
        await r.take("fresh second take")
        XCTAssertEqual(r.owner.session?.candidate, "fresh second take"); XCTAssertEqual(r.owner.session?.accepted, accepted)
        XCTAssertNotEqual(s.operation, operation); XCTAssertEqual(r.native.calls.count, 2)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }
}


/// Test-local reference to the exact permit the guarded fake bottom receives; entry is never replaced.
private final class GuidedPermitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PreparationPermit?
    var permit: PreparationPermit? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
/// Awaits main-queue callbacks already dispatched (core.changed refreshes) without blocking main.
@MainActor private func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

extension GuidedTemplateLifecycleTests {
    @MainActor func testS2QueuedDiscardBeforeDequeueKeepsFormInBothSafeStartModes() async throws {
        for enabled in [false, true] {
            let s = try GuidedSafeStartRig(fields: ["title", "body"], enabled: enabled), r = s.r
            await r.begin(); await r.take("earlier field stays"); r.owner.accept()
            let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
            let ledger = try s.memory.read(), paths = r.native.paths.count, calls = r.native.calls.count
            let admissions = r.native.admissions, reads = r.native.metadataReads
            let entered = RecognitionTestLatch(), exit = RecognitionTestLatch(), predecessor = PendingOperation(name: "held S2 predecessor")
            defer { exit.signal() }
            r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: predecessor, completes: true, work: { entered.signal(); await exit.wait() })
            await entered.wait(); r.owner.start(); r.engine.feed(); r.owner.stop()
            let operation = try XCTUnwrap(s.operation)
            XCTAssertEqual(operation.stage, .queued); XCTAssertFalse(operation.shouldAbort)
            r.owner.discardTake(); s.refresh(); r.hub.refreshTemplates()
            XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(operation.hasExited); XCTAssertFalse(predecessor.hasExited)
            XCTAssertEqual(s.refusal(operation), .revoked, "Default operation query still refuses the discarded take.")
            XCTAssertNil(s.formAuthority(operation))
            XCTAssertEqual(r.owner.session?.id, form, "Queued Discard must keep its form (Safe Start \(enabled)).")
            XCTAssertEqual(r.owner.session?.accepted, accepted); XCTAssertNil(r.owner.session?.candidate)
            XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
            XCTAssertTrue(HotkeyMonitor.suspended)
            let starts = r.engine.starts, queued = r.queued; r.owner.start()
            XCTAssertEqual(r.engine.starts, starts); XCTAssertEqual(r.queued, queued)
            exit.signal(); await r.chain?.value; s.refresh(); r.hub.refreshTemplates()
            XCTAssertTrue(predecessor.hasExited); XCTAssertTrue(operation.hasExited); XCTAssertEqual(r.queued, r.finished)
            XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertNil(r.owner.session?.candidate); XCTAssertNil(r.owner.session?.take); XCTAssertFalse(r.owner.busy)
            XCTAssertEqual(r.native.paths.count, paths); XCTAssertEqual(r.native.calls.count, calls)
            XCTAssertEqual(r.native.admissions, admissions); XCTAssertEqual(r.native.metadataReads, reads)
            XCTAssertEqual(try s.memory.read(), ledger)
            await r.take("fresh second take")
            XCTAssertEqual(r.owner.session?.candidate, "fresh second take"); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertNotEqual(s.operation, operation); XCTAssertEqual(r.native.paths.count, paths + 1)
            XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            try await s.close()
        }
    }

    @MainActor func testS2DiscardAfterQueueChildEntersBeforeOwnerMainBoundary() async throws {
        for enabled in [false, true] {
            let s = try GuidedSafeStartRig(fields: ["title", "body"], enabled: enabled), r = s.r
            await r.begin(); await r.take("earlier field stays"); r.owner.accept()
            let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
            let ledger = try s.memory.read(), paths = r.native.paths.count, calls = r.native.calls.count
            let admissions = r.native.admissions, reads = r.native.metadataReads
            let childEntered = RecognitionTestLatch(), proceed = RecognitionTestLatch(), base = try XCTUnwrap(r.owner.enqueue)
            defer { proceed.signal() }
            // Real queue, unchanged guards: the child has passed both abort checks and is running. The wrapper pauses it
            // before the owner's work body submits its first MainActor boundary (not literally pending on main).
            r.owner.enqueue = { operation, work, done in
                base(operation, { childEntered.signal(); await proceed.wait(); await work() }, done)
            }
            r.owner.start(); r.engine.feed(); r.owner.stop(); r.owner.enqueue = base
            let operation = try XCTUnwrap(s.operation)
            await childEntered.wait()
            XCTAssertFalse(operation.shouldAbort); XCTAssertFalse(operation.hasExited); XCTAssertEqual(operation.stage, .queued)
            r.owner.discardTake()
            XCTAssertTrue(operation.shouldAbort); XCTAssertEqual(r.owner.session?.id, form); XCTAssertTrue(r.owner.busy)
            proceed.signal(); await r.chain?.value
            XCTAssertTrue(operation.hasExited); XCTAssertEqual(r.queued, r.finished)
            XCTAssertEqual(r.owner.session?.id, form, "An entered child's owner boundary must not cancel the form (Safe Start \(enabled)).")
            XCTAssertEqual(r.owner.session?.accepted, accepted); XCTAssertNil(r.owner.session?.candidate)
            XCTAssertNil(r.owner.session?.take); XCTAssertFalse(r.owner.busy)
            XCTAssertEqual(r.native.paths.count, paths); XCTAssertEqual(r.native.calls.count, calls)
            XCTAssertEqual(r.native.admissions, admissions); XCTAssertEqual(r.native.metadataReads, reads)
            XCTAssertEqual(try s.memory.read(), ledger)
            s.refresh(); r.hub.refreshTemplates(); XCTAssertEqual(r.owner.session?.id, form)
            await r.take("fresh second take")
            XCTAssertEqual(r.owner.session?.candidate, "fresh second take"); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertNotEqual(s.operation, operation); XCTAssertEqual(r.native.paths.count, paths + 1)
            XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            try await s.close()
        }
    }

    @MainActor func testS2FinishedHandoffRefreshPublishesOnceAndDiscardMarkerSuppressesStagedResult() async throws {
        for enabled in [false, true] {
            for discard in [false, true] {
                let s = try GuidedSafeStartRig(fields: ["title", "body"], enabled: enabled), r = s.r
                await r.begin(); await r.take("earlier field stays"); r.owner.accept()
                let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
                let calls = r.native.calls.count
                let handoff = RecognitionTestLatch(), release = RecognitionTestLatch(), base = try XCTUnwrap(r.owner.enqueue)
                defer { release.signal() }
                // Wraps only the finished callback: the real queue has already called operation.finish() before it runs.
                r.owner.enqueue = { operation, work, done in
                    base(operation, work, { handoff.signal(); await release.wait(); await done() })
                }
                r.native.outputs = [.init(status: 0, segments: ["second field text"])]
                r.owner.start(); r.engine.feed(); r.owner.stop(); r.owner.enqueue = base
                await handoff.wait()
                let operation = try XCTUnwrap(s.operation)
                XCTAssertTrue(operation.hasExited); XCTAssertFalse(operation.shouldAbort); XCTAssertEqual(operation.stage, .finished)
                XCTAssertEqual(r.native.calls.count, calls + 1); XCTAssertFalse(s.core.hasActiveEntry)
                XCTAssertEqual(s.refusal(operation), .revoked, "An exited operation never regains permission.")
                XCTAssertEqual(r.finished + 1, r.queued)
                if discard {
                    r.owner.discardTake()
                    XCTAssertFalse(operation.shouldAbort, "Finished revoke is a no-op; only the owner marker remains.")
                }
                s.refresh(); r.hub.refreshTemplates()
                XCTAssertEqual(r.owner.session?.id, form, "Handoff refresh must keep the form (Safe Start \(enabled), discard \(discard)).")
                XCTAssertEqual(r.owner.session?.accepted, accepted); XCTAssertNil(r.owner.session?.candidate)
                XCTAssertNotNil(r.owner.session?.take); XCTAssertTrue(r.owner.busy)
                let starts = r.engine.starts, queued = r.queued; r.owner.start()
                XCTAssertEqual(r.engine.starts, starts); XCTAssertEqual(r.queued, queued); XCTAssertTrue(s.operation === operation)
                release.signal(); await r.chain?.value; s.refresh()
                XCTAssertEqual(r.queued, r.finished); XCTAssertFalse(r.owner.busy); XCTAssertNil(r.owner.session?.take)
                XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
                XCTAssertEqual(r.native.calls.count, calls + 1); XCTAssertTrue(s.operation === operation)
                if discard {
                    XCTAssertNil(r.owner.session?.candidate, "The local discard marker suppresses the staged result.")
                } else {
                    XCTAssertEqual(r.owner.session?.candidate, "second field text"); r.owner.accept()
                    XCTAssertEqual(r.owner.session?.accepted.count, 2)
                }
                XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
                try await s.close()
            }
        }
    }

    @MainActor func testS2GenuineRevocationWhileDiscardedConstructorHeldCancelsWithoutRevival() async throws {
        for mode in 0..<6 {
            let s = try GuidedSafeStartRig(fields: ["title", "body"]), r = s.r, box = GuidedPermitBox()
            let provider = try XCTUnwrap(r.factoryProvider)
            r.factoryProvider = {
                var factory = provider(); let guarded = factory.guardedNative
                factory.guardedNative = { path, compute, permit in box.permit = permit; return try guarded(path, compute, permit) }
                return factory
            }
            await r.begin(); await r.take("earlier field stays"); r.owner.accept(); box.permit = nil
            let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
            let calls = r.native.calls.count
            let entered = expectation(description: "discarded constructor held \(mode)"), leave = DispatchSemaphore(value: 0)
            r.native.construct = { entered.fulfill(); leave.wait() }; defer { leave.signal() }
            r.owner.start(); r.engine.feed(); r.owner.stop()
            await fulfillment(of: [entered], timeout: 3)
            let operation = try XCTUnwrap(s.operation), permit = try XCTUnwrap(box.permit)
            r.owner.discardTake(); s.refresh(); r.hub.refreshTemplates()
            XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertNil(s.formAuthority(operation), "Form observation is healthy for the exact discarded owner.")
            XCTAssertEqual(s.refusal(operation), .revoked); XCTAssertThrowsError(try permit.validate())
            XCTAssertEqual(s.core.cachedRefusal(for: s.request.selection), .busy)
            switch mode {
            case 0: r.secure = true; r.owner.observeSaved(); r.secure = false
            case 1:
                let original = r.memory.settings; var changed = try r.store.savedRetrySnapshot(); changed.language = "en"
                r.memory.settings = try JSONEncoder().encode(changed); r.hub.refreshTemplates(); r.memory.settings = original
            case 2: r.hub.settings.language = "en"; r.hub.settings.language = "hi"
            case 3: let old = r.selection; r.selection = UUID(); s.refresh(); r.selection = old
            case 4: let port = r.owner.preparationEpoch; r.owner.preparationEpoch = { UUID() }; s.refresh(); r.owner.preparationEpoch = port
            default: s.preparation.revokeDraft()
            }
            XCTAssertNil(r.owner.session, "Genuine revocation \(mode) must win over the local discard.")
            s.refresh(); r.hub.refreshTemplates(); XCTAssertNil(r.owner.session)
            XCTAssertTrue(s.core.hasActiveEntry); XCTAssertFalse(operation.hasExited); XCTAssertTrue(operation.shouldAbort)
            XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy); XCTAssertFalse(r.admission.isAvailable)
            XCTAssertTrue(HotkeyMonitor.suspended)
            let starts = r.engine.starts; r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, starts)
            leave.signal(); await r.chain?.value; s.refresh()
            XCTAssertTrue(operation.hasExited); XCTAssertFalse(s.core.hasActiveEntry); XCTAssertNil(r.owner.session)
            XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
            r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
            XCTAssertEqual(r.native.calls.count, calls); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            if r.hub.hasPendingSettingsSave { r.hub.onSaved = {}; r.hub.flushPendingSave() }
            try await s.close()
        }
    }

    @MainActor func testS2DiscardTriggeredTerminalFaultWinsWhileConstructorHeld() async throws {
        let s = try GuidedSafeStartRig(fields: ["title", "body"]), r = s.r
        await r.begin(); await r.take("earlier field stays"); r.owner.accept()
        let calls = r.native.calls.count
        let entered = expectation(description: "constructor held before discard fault"), leave = DispatchSemaphore(value: 0)
        r.native.construct = { entered.fulfill(); leave.wait() }; defer { leave.signal() }
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = s.core.admissionEpoch, selection = r.selection
        s.refresh(); XCTAssertNotNil(r.owner.session); XCTAssertNil(s.refusal(operation))
        // Only the worker is held. Discard's terminal write fails on main; its notification is dispatched, never waited on main.
        s.memory.failTerminalWrites = true; r.owner.discardTake()
        XCTAssertTrue(operation.shouldAbort); XCTAssertTrue(s.core.persistenceFailed)
        await drainMainQueue() // shipping core.changed -> main refresh -> direct + Hub routes
        XCTAssertNil(r.owner.session, "Same-epoch persistence fault wins over the local discard.")
        XCTAssertEqual(s.core.admissionEpoch, epoch); XCTAssertEqual(r.selection, selection)
        XCTAssertEqual(s.core.snapshot.status, .trackingUnavailable)
        XCTAssertEqual(s.formAuthority(operation), .trackingUnavailable); XCTAssertEqual(s.refusal(operation), .trackingUnavailable)
        XCTAssertEqual(s.core.cachedRefusal(for: s.request.selection), .busy)
        XCTAssertFalse(operation.hasExited); XCTAssertTrue(s.core.hasActiveEntry)
        XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertEqual(r.native.calls.count, calls)
        let starts = r.engine.starts; r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, starts)
        leave.signal(); await r.chain?.value; await drainMainQueue(); s.refresh()
        XCTAssertFalse(s.core.hasActiveEntry); XCTAssertTrue(operation.hasExited); XCTAssertTrue(s.core.persistenceFailed)
        XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        r.hub.beginTemplate(); XCTAssertNil(r.owner.session); XCTAssertEqual(r.engine.starts, starts)
        r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertEqual(r.native.calls.count, calls); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }

    @MainActor func testS2ForeignSameEpochActiveEntryCannotLendAuthorityToQueuedDiscardedTake() async throws {
        let s = try GuidedSafeStartRig(fields: ["title", "body"]), r = s.r
        await r.begin(); await r.take("earlier field stays"); r.owner.accept()
        let form = try XCTUnwrap(r.owner.session?.id), paths = r.native.paths.count, calls = r.native.calls.count
        let mayEnter = RecognitionTestLatch(), entered = expectation(description: "foreign nativeEntry held")
        let leave = DispatchSemaphore(value: 0), predecessor = PendingOperation(name: "foreign same-epoch constructor")
        defer { mayEnter.signal(); leave.signal() }
        r.owner.start(); r.engine.feed()
        let request = s.request, selection = r.selection, epoch = s.core.admissionEpoch, factory = try XCTUnwrap(r.factoryProvider)()
        var foreignFactory = factory
        foreignFactory.guardedNative = { path, compute, permit in
            try permit.nativeEntry { entered.fulfill(); leave.wait(); return try factory.native(path, compute) }
        }
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: predecessor, completes: true, work: {
            await mayEnter.wait()
            do { _ = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: foreignFactory,
                operation: predecessor, selectionEpoch: selection, preparationEpoch: epoch) }
            catch { XCTFail("Foreign predecessor unexpectedly failed: \(error)") }
        })
        r.owner.stop(); let guided = try XCTUnwrap(s.operation)
        XCTAssertEqual(guided.stage, .queued)
        r.owner.discardTake(); s.refresh(); r.hub.refreshTemplates()
        XCTAssertTrue(guided.shouldAbort); XCTAssertEqual(r.owner.session?.id, form); XCTAssertNil(s.formAuthority(guided))
        mayEnter.signal(); await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(s.core.hasActiveEntry); XCTAssertEqual(s.core.admissionEpoch, epoch)
        XCTAssertEqual(s.formAuthority(guided), .busy, "A foreign active entry is not the discarded take's own.")
        XCTAssertEqual(s.formAuthority(PendingOperation(name: "unrelated")), .busy)
        XCTAssertNil(s.formAuthority(predecessor), "Only the exact active owner observes its unchanged grant.")
        XCTAssertEqual(s.formAuthority(predecessor, target: .appleSpeech(locale: "en-US")), .busy)
        XCTAssertEqual(s.formAuthority(predecessor, selection: UUID()), .revoked)
        XCTAssertEqual(s.formAuthority(predecessor, epoch: UUID()), .revoked)
        XCTAssertEqual(s.refusal(guided), .revoked); XCTAssertNil(s.refusal(predecessor))
        s.refresh(); XCTAssertNil(r.owner.session)
        XCTAssertFalse(predecessor.shouldAbort); XCTAssertFalse(predecessor.hasExited); XCTAssertFalse(guided.hasExited)
        XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(HotkeyMonitor.suspended)
        let starts = r.engine.starts; r.hub.beginTemplate(); r.owner.start(); XCTAssertEqual(r.engine.starts, starts)
        leave.signal(); await r.chain?.value
        XCTAssertTrue(predecessor.hasExited); XCTAssertTrue(guided.hasExited); XCTAssertFalse(s.core.hasActiveEntry)
        XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable); XCTAssertFalse(HotkeyMonitor.suspended)
        // Only the deliberately introduced foreign constructor ran; the discarded guided take never acquired or decoded.
        XCTAssertEqual(r.native.paths.count, paths + 1); XCTAssertEqual(r.native.calls.count, calls); XCTAssertNil(r.owner.session)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try await s.close()
    }
}

extension GuidedTemplateLifecycleTests {
    @MainActor func testB53OwnedFirstRealRefreshPreservesFormAndDiscardDrains() async throws {
        for discard in [false, true] { try await checkOwnedFirstReal(discard: discard, retired: false) }
    }

    @MainActor func testB53RetiredFirstRealKeepsFormUntilActualExitIncludingDiscard() async throws {
        for discard in [false, true] { try await checkOwnedFirstReal(discard: discard, retired: true) }
    }

    @MainActor func testB53DiscardedFirstRealStillObservesGenuineRevocations() async throws {
        for mode in 0..<7 { try await checkOwnedFirstReal(discard: true, retired: false, revoke: mode) }
    }

    @MainActor private func checkOwnedFirstReal(discard: Bool, retired: Bool, revoke: Int? = nil) async throws {
        let s = try GuidedSafeStartRig(fields: ["title", "body"]), r = s.r
        // Establish accepted data through the real owner/factory path before observing the held second take.
        let changed = s.core.changed; s.core.changed = nil
        await r.begin(); await r.take("earlier field stays"); r.owner.accept(); await drainMainQueue()
        let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
        XCTAssertEqual(accepted.count, 1)
        while s.memory.takeTerminalNotification(phase: .firstRealAudioRequest) {}
        s.core.changed = changed
        let entered = expectation(description: "owned first request held: retired=\(retired), discard=\(discard)")
        let leave = DispatchSemaphore(value: 0)
        defer { leave.signal() }
        if retired {
            let core = s.core, memory = s.memory, wrapper = s.preparation
            let attemptLock = NSLock()
            var expectedAttempt: UUID?
            core.changed = {
                let pending = memory.ledger?.entries.first(where: { $0.key.p == .firstRealAudioRequest })?.pending?.attempt
                let expected = attemptLock.withLock { if expectedAttempt == nil { expectedAttempt = pending }; return expectedAttempt }
                let hold = expected.map { memory.takeTerminalNotification(phase: .firstRealAudioRequest, attempt: $0) } == true && core.hasActiveEntry
                DispatchQueue.main.async { wrapper.refresh(); if hold { entered.fulfill() } }
                if hold { XCTAssertFalse(Thread.isMainThread); if !Thread.isMainThread { leave.wait() } }
            }
        } else {
            r.native.decode = { entered.fulfill(); leave.wait() }
        }
        r.native.outputs = [.init(status: 0, segments: ["second field result"])]
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = s.core.admissionEpoch, selection = r.selection
        let first = try XCTUnwrap(s.memory.ledger?.entries.first(where: { $0.key.p == .firstRealAudioRequest }))
        XCTAssertEqual(first.pending == nil, retired)
        if retired { XCTAssertEqual(first.outcome, .completed) }
        else { XCTAssertEqual(first.pending?.operation, operation.id) }
        XCTAssertTrue(s.core.hasActiveEntry); XCTAssertFalse(operation.hasExited)
        XCTAssertNil(s.refusal(operation), "Exact owned first-real work must preserve its form.")
        XCTAssertEqual(s.core.cachedRefusal(for: s.request.selection), .busy)
        XCTAssertEqual(s.refusal(PendingOperation(name: "foreign first-real observer")), .busy)
        XCTAssertEqual(s.refusal(operation, selection: UUID()), .revoked)
        XCTAssertEqual(s.refusal(operation, epoch: UUID()), .revoked)
        XCTAssertEqual(s.refusal(operation, target: .appleSpeech(locale: "en-US")), .busy)
        if discard {
            if revoke == 6 { s.memory.failTerminalWrites = true }
            r.owner.discardTake()
            XCTAssertEqual(s.refusal(operation), revoke == 6 ? .trackingUnavailable : .revoked)
            if revoke != 6 { XCTAssertNil(s.formAuthority(operation)) }
        }
        s.refresh(); r.hub.refreshTemplates()
        if let revoke {
            switch revoke {
            case 0: r.secure = true; r.owner.observeSaved(); r.secure = false
            case 1:
                let original = r.memory.settings; var saved = try r.store.savedRetrySnapshot(); saved.language = "en"
                r.memory.settings = try JSONEncoder().encode(saved); r.hub.refreshTemplates(); r.memory.settings = original
            case 2: r.hub.settings.language = "en"; r.hub.settings.language = "hi"
            case 3: r.selection = UUID(); s.refresh(); r.selection = selection
            case 4: let port = r.owner.preparationEpoch; r.owner.preparationEpoch = { UUID() }; s.refresh(); r.owner.preparationEpoch = port
            case 5: s.preparation.revokeDraft()
            default: XCTAssertTrue(s.core.persistenceFailed)
            }
            await drainMainQueue(); s.refresh()
            XCTAssertNil(r.owner.session, "Real invalidation must win, mode \(revoke).")
        } else {
            XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertNil(r.owner.session?.candidate)
        }
        if revoke == 5 { XCTAssertNotEqual(s.core.admissionEpoch, epoch) }
        else { XCTAssertEqual(s.core.admissionEpoch, epoch) }
        XCTAssertFalse(operation.hasExited); XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession)
        XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
        let successorOperation = PendingOperation(name: "first-request exit barrier")
        let successor = PendingOperationQueue.enqueue(previous: r.chain, operation: successorOperation,
            completes: true, work: {}, finished: {})
        await drainMainQueue(); XCTAssertFalse(successorOperation.hasExited)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        leave.signal(); await successor.value; await drainMainQueue()
        s.core.changed = changed // The held-attempt observer must not observe a later fresh take.
        r.native.decode = nil
        XCTAssertTrue(operation.hasExited); XCTAssertFalse(s.core.hasActiveEntry); XCTAssertFalse(r.owner.busy)
        if revoke != nil {
            XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(r.admission.isAvailable)
        } else {
            XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertEqual(r.owner.session?.candidate, discard ? nil : "second field result")
            XCTAssertEqual(r.native.calls.count, 2)
            if discard {
                await r.take("fresh explicit take")
                XCTAssertEqual(r.owner.session?.candidate, "fresh explicit take")
                XCTAssertNotEqual(s.operation, operation)
            }
        }
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        if r.hub.hasPendingSettingsSave { r.hub.onSaved = {}; r.hub.flushPendingSave() }
        try await s.close()
    }
}

extension GuidedTemplateLifecycleTests {
    @MainActor func testB53OwnStorageIOKeepsFormWhileAdmissionAndForeignCallersStayBusy() async throws {
        for boundary in 0..<5 { try await checkOwnedPreparationIO(boundary: boundary, discard: false) }
    }

    @MainActor func testB53DiscardDuringOwnStorageIOKeepsOnlyFormAuthorityUntilReturn() async throws {
        for boundary in 0..<5 { try await checkOwnedPreparationIO(boundary: boundary, discard: true) }
    }

    @MainActor func testB53OwnStorageIOCannotHideRevocationOrTerminalFailure() async throws {
        for boundary in 0..<5 {
            for revoke in 0..<3 { try await checkOwnedPreparationIO(boundary: boundary, discard: revoke != 2, revoke: revoke) }
        }
    }

    @MainActor private func checkOwnedPreparationIO(boundary: Int, discard: Bool, revoke: Int? = nil) async throws {
        // 0: lazy build; 1/2: constructor/first-request pending; 3/4: their terminal writes.
        let entered = expectation(description: "selected IO boundary \(boundary), discard \(discard), revoke \(String(describing: revoke))")
        let leave = DispatchSemaphore(value: 0), gateLock = NSLock()
        var didHold = false
        let s = try GuidedSafeStartRig(fields: ["title", "body"], buildLookup: {
            if boundary == 0 { entered.fulfill(); XCTAssertFalse(Thread.isMainThread); if !Thread.isMainThread { leave.wait() } }
        }), r = s.r, box = GuidedPermitBox()
        defer { leave.signal() }
        let provider = try XCTUnwrap(r.factoryProvider)
        r.factoryProvider = {
            var factory = provider(); let guarded = factory.guardedNative
            factory.guardedNative = { path, compute, permit in
                box.permit = permit; return try guarded(path, compute, permit)
            }
            return factory
        }
        let changed = s.core.changed
        if boundary != 0 {
            s.core.changed = nil
            await r.begin(); await r.take("earlier accepted field"); r.owner.accept(); await drainMainQueue()
            s.core.changed = changed
        } else { await r.begin() }
        let form = try XCTUnwrap(r.owner.session?.id), accepted = try XCTUnwrap(r.owner.session?.accepted)
        XCTAssertEqual(accepted.count, boundary == 0 ? 0 : 1)
        let phase: PreparationPhase = [1, 3].contains(boundary) ? .nativeConstruction : .firstRealAudioRequest
        if boundary != 0 {
            s.memory.beforeReplace = { previous, next in
                guard let entry = next.entries.first(where: { $0.key.p == phase }) else { return }
                let old = previous?.entries.first(where: { $0.key == entry.key })
                let matches = boundary < 3
                    ? entry.pending != nil && old?.pending != entry.pending
                    : entry.pending == nil && entry.consumed != nil && old?.pending?.attempt == entry.consumed
                let hold = gateLock.withLock { if !matches || didHold { return false }; didHold = true; return true }
                if hold { entered.fulfill(); XCTAssertFalse(Thread.isMainThread); if !Thread.isMainThread { leave.wait() } }
            }
        }
        let calls = r.native.calls.count
        r.native.outputs = [.init(status: 0, segments: ["native original"])]
        r.owner.start(); r.engine.feed(); r.owner.stop()
        await fulfillment(of: [entered], timeout: 3)
        let operation = try XCTUnwrap(s.operation), epoch = s.core.admissionEpoch
        XCTAssertTrue(s.core.hasActiveEntry); XCTAssertFalse(operation.hasExited)
        XCTAssertNil(s.refusal(operation))
        XCTAssertEqual(s.core.cachedRefusal(for: s.request.selection), .busy)
        XCTAssertEqual(s.refusal(PendingOperation(name: "same-epoch foreign IO observer")), .busy)
        XCTAssertEqual(s.refusal(operation, target: .appleSpeech(locale: "en-US")), .busy)
        XCTAssertEqual(s.refusal(operation, epoch: UUID()), .revoked)
        XCTAssertEqual(s.refusal(operation, selection: UUID()), .revoked)
        if let permit = box.permit { XCTAssertThrowsError(try permit.validate(), "Observation must not authorize entry during IO.") }
        if discard {
            r.owner.discardTake()
            XCTAssertEqual(s.refusal(operation), .revoked)
            XCTAssertNil(s.formAuthority(operation), "Only the exact discarded form may observe its own pending IO.")
        }
        s.refresh(); r.hub.refreshTemplates(); await drainMainQueue()
        XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
        XCTAssertNil(r.owner.session?.candidate); XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession)
        XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(HotkeyMonitor.suspended)
        if let revoke {
            switch revoke {
            case 0: r.secure = true; r.owner.observeSaved(); r.secure = false
            case 1: s.preparation.revokeDraft()
            default: s.memory.failTerminalWrites = true
            }
            if revoke != 2 {
                s.refresh(); r.hub.refreshTemplates()
                XCTAssertNil(r.owner.session)
                if revoke == 1 { XCTAssertNotNil(s.formAuthority(operation)) }
                else { XCTAssertEqual(s.refusal(operation), .revoked) }
            }
        }
        let successorOperation = PendingOperation(name: "owned IO actual-exit barrier")
        let successor = PendingOperationQueue.enqueue(previous: r.chain, operation: successorOperation,
            completes: true, work: {}, finished: {})
        await drainMainQueue(); XCTAssertFalse(successorOperation.hasExited)
        XCTAssertFalse(operation.hasExited); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        if boundary < 4 { XCTAssertEqual(r.native.calls.count, calls) }
        leave.signal(); await successor.value; await drainMainQueue()
        s.memory.beforeReplace = nil
        XCTAssertTrue(operation.hasExited); XCTAssertFalse(s.core.hasActiveEntry); XCTAssertFalse(r.owner.busy)
        // A discarded pre-active write can fail authorization; its real storage fault must win.
        let faulted = s.core.snapshot.status == .trackingUnavailable
        if revoke != nil || faulted {
            XCTAssertNil(r.owner.session)
        } else {
            XCTAssertEqual(r.owner.session?.id, form); XCTAssertEqual(r.owner.session?.accepted, accepted)
            XCTAssertEqual(r.owner.session?.candidate, discard ? nil : "native original")
        }
        let noDecode = discard && boundary < 4 || revoke == 2 && [0, 1, 3].contains(boundary)
        XCTAssertEqual(r.native.calls.count, calls + (noDecode ? 0 : 1))
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        if revoke == 1 { XCTAssertNotEqual(s.core.admissionEpoch, epoch) }
        try await s.close()
    }
}
