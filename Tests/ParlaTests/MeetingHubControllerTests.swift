import Combine
import AVFoundation
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

/// Every new held bottom has defer-release plus an independent global five-second fail-release.
final class HubOwnedLatch: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value:0)
    private var opened = false, enteredValue = false, timedOutValue = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    private var watchdog: DispatchWorkItem?
    init() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fail = self.lock.withLock { !self.opened }
            if fail { self.lock.withLock { self.timedOutValue = true }; XCTFail("Owned latch exceeded five seconds"); self.open() }
        }
        watchdog = item; DispatchQueue.global().asyncAfter(deadline:.now()+5,execute:item)
    }
    func wait() async { await withCheckedContinuation { c in let immediate = lock.withLock { () -> Bool in enteredValue = true; if opened { return true }; waiters.append(c); return false }; if immediate { c.resume() } } }
    func hold() { let wait = lock.withLock { () -> Bool in enteredValue = true; return !opened }; if wait { _ = semaphore.wait(timeout:.now()+5) } }
    func open() {
        let result = lock.withLock { () -> (Bool,[CheckedContinuation<Void,Never>]) in if opened { return (false,[]) }; opened = true; let all = waiters; waiters.removeAll(); return (true,all) }
        guard result.0 else { return }; watchdog?.cancel(); semaphore.signal(); result.1.forEach { $0.resume() }
    }
    var entered: Bool { lock.withLock { enteredValue } }
    var timedOut: Bool { lock.withLock { timedOutValue } }
    deinit { watchdog?.cancel() }
}
final class HubSavedSettings: @unchecked Sendable {
    private let lock = NSLock(); private var value = Settings()
    var current: Settings { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    init() { value.whisperModelPath = "/virtual/model"; value.inputDeviceUID = "first"; value.language = "en" }
}
@MainActor final class MeetingHubRig {
    let controller = MeetingHubController(), engine = AdapterEngine(), converter = AdapterConverter(), admission = CaptureAdmission()
    let bottom: LifecycleMeetingBottom
    let settings = HubSavedSettings(), store: SettingsStore
    let localAdmission = LocalCleanupAdmission()
    let recorder: AudioRecorder
    var loads = 0
    var clock: Int64 = 1_000_000_000_000, permissions = 0, resolutions = 0, microphoneFactories = 0, enqueues = 0, copies: [String] = []
    var permission = MeetingHubController.Permission.authorized, pendingPermission: ((Bool) -> Void)?
    var processTask: Task<Void,Never>?, queueGate: HubOwnedLatch?, consumerGate: HubOwnedLatch?
    var acquisitionGate: HubOwnedLatch?, validationGate: HubOwnedLatch?
    var consumerEntered: XCTestExpectation?, acquisitionEntered: XCTestExpectation?, validationEntered: XCTestExpectation?
    var recognitionJobs: [MeetingRecognitionExecution.Job] = [], meetingStores: [MeetingSessionStore] = []
    var enqueued: XCTestExpectation?, recognitionText: ((MeetingRecognitionExecution.Job) -> String?)?
    var securityAllowed = true, literalText: String? = "Literal raw text\nkept verbatim."
    var onCopy: (() -> Void)?, controllerWall: (() throws -> Int64)?
    let selectedEpoch = UUID()
    init(capability: Bool = true,bottom: LifecycleMeetingBottom = LifecycleMeetingBottom()) throws {
        self.bottom = bottom
        let settings = settings
        store = SettingsStore(url:URL(fileURLWithPath:"/virtual/meeting-settings.json"),credentials:CredentialStore(backend:HubRefusingCredentials()),
            scratchpadIO:.init(read:{_ in XCTFail("No scratchpad reads");return nil},write:{_,_ in XCTFail("No scratchpad writes")}),
            documentIO:.init(read:{try JSONEncoder().encode(settings.current)}),atomicWrite:{_,_ in XCTFail("No settings writes")})
        let engine = engine, converter = converter
        recorder = AudioRecorder(engine:engine,admission:admission,captureClock:{0},meetingConverter:{_ in converter},meetingBindingCheck:{ requested in
            guard engine.requestedUID == requested else { throw MeetingSession.Failure.stale }
        })
        bottom.retainSourceBytes = true; bottom.retainResultBytes = true
        controller.bind(.init(captureCapability:capability,makeStore:{[unowned self] in
            let value = MeetingSessionStore(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{[unowned self] in clock})
            meetingStores.append(value); return value
        },microphone:{[unowned self] input in
            microphoneFactories += 1
            let port = MeetingMicrophoneCapture(recorder:recorder,input:input,enabled:true).port
            return .init(validate:{ [unowned self] selection in
                if let gate = validationGate { validationEntered?.fulfill(); await gate.wait() }
                return await port.validate(selection)
            },start:port.start,requestStop:port.requestStop)
        },
        resolveInput:{[unowned self] uid in resolutions += 1; guard let uid,uid != "missing" else { throw MeetingSession.Failure.unavailable }; return try .init(uid:uid,label:"Literal microphone") },
        authorization:{[unowned self] in permissions += 1; return permission },requestAccess:{[unowned self] in pendingPermission = $0 },openPrivacy:{},
        settings:{[unowned self] in settings.current},settingsObject:store,selectionEpoch:{[unowned self] in selectedEpoch},enqueue:{[unowned self] job in
            enqueues += 1; recognitionJobs.append(job); enqueued?.fulfill()
            let gate = consumerGate, entered = consumerEntered
            let text: String?
            if let recognitionText {text = recognitionText(job)} else {text = literalText}
            let acquisition = acquisitionGate, acquisitionEntry = acquisitionEntered
            let next = MeetingRecognitionExecution.enqueue(previous:processTask,admission:localAdmission,job:job,settings:store,enter:{},load:{ request in
                loads += 1
                if let acquisition { acquisitionEntry?.fulfill(); await acquisition.wait() }
                let client = HubLiteralRecognizer(gate:gate,entered:entered,text:text)
                if request.selection.engine == .whisper {
                    return try RecognitionHandle(request:request,load:{_ in client})
                }
                guard request.selection.engine == .appleSpeech || request.selection.engine == .parakeet else { throw AppleSpeechRefusal.configuration }
                // Typed injected resident for authority tests; no backend/native admission is claimed.
                let identity = RecognitionIdentity(engine:request.selection.engine,selection:request.selection,
                    artifact:request.selection.engine == .appleSpeech ? .systemAssetsRevisionUnknown : .customRevisionUnknown,
                    generation:nil,runtime:nil,unknownRevisionScope:UUID())
                return RecognitionHandle(owner:RecognitionResident(request:request,identity:identity,instance:UUID(),client:client),capture:UUID())
            })
            if let next { processTask = next }; return next
        },diagnostics:DiagnosticStore(),security:{[unowned self] in securityAllowed},copy:{[unowned self] in onCopy?(); copies.append($0)},wall:{[unowned self] in try controllerWall?() ?? clock}))
    }
    func release() { pendingPermission?(false); pendingPermission = nil; queueGate?.open(); consumerGate?.open(); converter.drainGate?.open(); controller.stopAndSave() }
    func changedSettings() { NotificationCenter.default.post(name:SettingsStore.configurationDidChange,object:store) }
}
final class HubLiteralRecognizer: RecognitionClient {
    let gate: HubOwnedLatch?, entered: XCTestExpectation?, text: String?
    init(gate: HubOwnedLatch?, entered: XCTestExpectation? = nil, text: String? = "Literal raw text\nkept verbatim.") { self.gate = gate; self.entered = entered; self.text = text }
    func transcribe(_ samples: [Float],initialPrompt: String?,language: String?,shouldAbort: (() -> Bool)?) async -> String? {
        if let gate { entered?.fulfill(); await gate.wait() }
        return text
    }
}
extension XCTestCase {
    @MainActor func hubEntered(_ expectations: [XCTestExpectation]) async -> Bool {
        let result = await XCTWaiter.fulfillment(of:expectations,timeout:4)
        guard result == .completed else { XCTFail("Actual entry was not observed within four seconds"); return false }; return true
    }
    @MainActor func hubComplete(_ action: @escaping @MainActor () async -> Void) async -> Bool {
        let done = expectation(description:"complete owned action chain")
        var returned = false
        Task { await action(); returned = true; done.fulfill() }
        let result = await XCTWaiter.fulfillment(of:[done],timeout:4)
        guard result == .completed,returned else { XCTFail("Unobserved chain exit; do not await held task"); return false }; return true
    }
}
final class MeetingHubControllerTests: XCTestCase {
    @MainActor func testConstructorBinderAndCapabilityGateQueryNothing() async throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }
        XCTAssertEqual(r.bottom.calls,0); XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.resolutions,0); XCTAssertEqual(r.engine.queries.value,0)
        r.controller.startAndSave(); XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.resolutions,0)
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0); XCTAssertEqual(r.permissions,0); XCTAssertNil(r.controller.model.metadata)
    }
    @MainActor func testLatePermissionAfterPageLeaveIsEvidenceOnly() async throws {
        let r = try MeetingHubRig(); defer { r.release() }; r.permission = .undetermined
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertNotNil(r.pendingPermission); r.controller.leavePage(); r.pendingPermission?(true); r.pendingPermission = nil
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0)
    }
    @MainActor func testFrozenUIDFocusAndPageStopUseSameBinder() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        XCTAssertEqual(r.engine.requestedUID,"first"); var saved = r.settings.current; saved.inputDeviceUID = "later"; r.settings.current = saved; r.changedSettings()
        r.controller.focusChanged(); XCTAssertEqual(r.controller.model.state,.recording)
        r.engine.emit([Float](repeating:0.5,count:8000)); r.controller.leavePage()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.controller.model.state,.stopped); XCTAssertEqual(r.engine.requestedUID,"first"); XCTAssertEqual(r.enqueues,0)
        let sources = r.bottom.rootNode!.children.values.filter { $0.name.hasSuffix(".source.wav") }
        XCTAssertEqual(sources.count,1); let bytes = sources.first!.bytes(0,16044)
        XCTAssertEqual(Array(bytes.prefix(4)),[82,73,70,70]); XCTAssertEqual(Array(bytes.suffix(4)),[0,64,0,64])
    }
    @MainActor func testSharedCaptureContentionNeverFallsBack() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        let held = r.admission.acquire(.guidedTemplate)!; defer { r.admission.release(held) }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testMissingSourceRefusesBeforeRecorderFactory() async throws {
        let r = try MeetingHubRig(); defer { r.release() }; var s = r.settings.current; s.inputDeviceUID = "missing"; r.settings.current = s
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.microphoneFactories,0); XCTAssertEqual(r.engine.starts.value,0)
    }
}


final class HubCheckpointHold: @unchecked Sendable {
    let latch = HubOwnedLatch(), entered: XCTestExpectation
    private let lock = NSLock(), match: (String,String?) -> Bool
    private var armed = true
    init(entered: XCTestExpectation,match: @escaping (String,String?) -> Bool) { self.entered = entered; self.match = match }
    func observe(_ operation: String,_ name: String?) {
        let take = lock.withLock { () -> Bool in guard armed,match(operation,name) else { return false }; armed = false; return true }
        if take { entered.fulfill(); latch.hold() }
    }
}
extension MeetingHubControllerTests {
    @MainActor func testFrozenUIDSurvivesSavedUIDEditWhileDurableAdmissionIsHeld() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        let entered = expectation(description:"durable admission actually entered")
        let held = HubCheckpointHold(entered:entered,match:{$0 == "write" && $1 == "owner.json"}); defer {held.latch.open()}
        r.bottom.observe = held.observe; r.controller.startAndSave()
        guard await hubEntered([entered]) else {return}
        var settings = r.settings.current; settings.inputDeviceUID = "later"; r.settings.current = settings; r.changedSettings()
        XCTAssertEqual(r.engine.starts.value,0); held.latch.open()
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        XCTAssertEqual(r.engine.requestedUID,"first"); r.controller.stopAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else {return}; XCTAssertFalse(held.latch.timedOut)
    }
    @MainActor func testFiniteSourceEndSchedulesExternalStopWithoutObserverSelfJoin() async throws {
        let r = try MeetingHubRig(); defer {r.release()}
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        r.engine.emit([Float](repeating:0.5,count:8000)); r.engine.changeRoute()
        // Observe the event-driven terminal publication. No Stop action is issued here.
        guard await hubModel(r.controller, { $0.state == .stopped && $0.metadata?.terminal != nil }) else { return }
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.controller.model.state,.stopped); XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.enqueues,0)
        XCTAssertEqual(r.controller.model.metadata?.unknownCoverage,true)
    }
}

struct HubRefusingCredentials: CredentialBackend {
    func status(_ scope: CredentialScope) -> CredentialStatus { XCTFail("No credential status query"); return .denied }
    func read(_ scope: CredentialScope,interactive: Bool) -> CredentialRead { XCTFail("No credential read"); return .denied }
    func add(_ value: String,scope: CredentialScope,interactive: Bool) -> CredentialMutation { XCTFail("No credential add"); return .denied }
    func update(_ value: String,scope: CredentialScope,interactive: Bool) -> CredentialMutation { XCTFail("No credential update"); return .denied }
    func delete(_ scope: CredentialScope) -> CredentialMutation { XCTFail("No credential delete"); return .denied }
}


/// Branch-owned one-shot observations: no test-owned resource task is canceled to fake exit.
extension XCTestCase {
    @MainActor func hubModel(_ controller: MeetingHubController, _ predicate: @escaping (HubMeetingModel) -> Bool) async -> Bool {
        let done = XCTestExpectation(description:"controller emitted requested state")
        var observed = false
        let subscription = controller.$model.sink { value in
            if !observed && predicate(value) { observed = true; done.fulfill() }
        }
        defer { subscription.cancel() }
        return await hubEntered([done])
    }
    @MainActor func hubSaved(_ r: MeetingHubRig, frames: Int = 8000, sample: Float = 0.5) async -> Bool {
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return false}
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return false}
        guard await hubEntered([r.engine.started]) else {return false}
        if frames > 0 { r.engine.emit(Array(repeating:sample,count:frames)) }
        r.controller.stopAndSave(); return await hubComplete({await r.controller.drainActions()})
    }
}
@MainActor final class HubRestartDrain {
    let entered: XCTestExpectation, exited: XCTestExpectation
    let task: Task<Void,Never>
    private final class Receipt { var result: Bool? }
    private let receipt: Receipt
    init(_ controller: MeetingHubController) {
        let entered = XCTestExpectation(description:"actual restart drain entered")
        let exited = XCTestExpectation(description:"actual restart drain returned")
        self.entered = entered;self.exited = exited
        let receipt = Receipt(); self.receipt = receipt
        task = Task { entered.fulfill(); receipt.result = await controller.drainRestart(); exited.fulfill() }
    }
    var returned: Bool { receipt.result != nil }
    var allowed: Bool? { receipt.result }
}
extension MeetingHubControllerTests {
    @MainActor func testPermissionDeniedDuplicateGrantAndSettingsReturnRequireExplicitStart() async throws {
        let r = try MeetingHubRig(); defer {r.release()}
        r.permission = .denied; r.controller.openPage()
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        XCTAssertEqual(r.controller.model.message,"Microphone access is off. Allow it in System Settings, then press Start.")
        r.permission = .undetermined; r.controller.openMicrophoneSettings(); r.controller.startAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        let callback = try XCTUnwrap(r.pendingPermission); r.pendingPermission = nil
        r.permission = .authorized; callback(true); callback(false)
        guard await hubModel(r.controller, {$0.message == "Microphone access is ready. Press Start to record and save." && !$0.busy}) else {return}
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        callback(true) // old callback cannot affect this run
        r.controller.stopAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.microphoneFactories,1); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testHeldValidationDrainEntersBeforeReleaseAndCancellationDoesNotStartProducer() async throws {
        let r = try MeetingHubRig(), gate = HubOwnedLatch(); defer {gate.open();r.release()}
        let entered = XCTestExpectation(description:"actual adapter validation entered")
        r.validationGate = gate; r.validationEntered = entered
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave(); guard await hubEntered([entered]) else {return}
        XCTAssertTrue(r.controller.reserveRestart()); let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned); XCTAssertFalse(r.controller.restartReady()); XCTAssertEqual(r.engine.starts.value,0)
        XCTAssertTrue(r.bottom.descriptors.isEmpty, "Validation precedes durable admission")
        r.controller.releaseRestart(); gate.open()
        guard await hubEntered([drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,false); XCTAssertEqual(r.engine.starts.value,0); XCTAssertFalse(gate.timedOut)
        guard await hubModel(r.controller, {!$0.busy}) else {return}
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.enqueues,0); XCTAssertEqual(r.meetingStores.count,2)
    }
    @MainActor func testEmptyTooShortAndSilentSavedAudioNeverConstructRecognizer() async throws {
        for (frames,sample,stage) in [(0,Float(0.5),Optional<MeetingSession.Stage>.none),(100,Float(0.5),.some(.tooShort)),(8000,Float(0),.some(.sealed))] {
            let r = try MeetingHubRig(); defer {r.release()}
            guard await hubSaved(r,frames:frames,sample:sample) else {return}
            XCTAssertEqual(r.controller.model.metadata?.chunks.first?.stage,stage)
            r.controller.transcribeRemaining(); guard await hubComplete({await r.controller.drainActions()}) else {return}
            XCTAssertTrue(r.recognitionJobs.isEmpty || frames == 8000)
            XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0)
            XCTAssertEqual(r.enqueues,frames == 8000 ? 1 : 0)
            // The real FileRecognitionBatch speech floor runs before its load closure.
            XCTAssertEqual(r.recognitionJobs.filter {$0.operation.hasExited}.count,r.enqueues)
            XCTAssertEqual(r.microphoneFactories,1); XCTAssertEqual(r.loads,0)
        }
    }
}


extension MeetingHubControllerTests {
    @MainActor func testLateCompetingCaptureDuringControllerAdmissionNeverStartsFrozenSource() async throws {
        let r = try MeetingHubRig();defer {r.release()}
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        let entered = XCTestExpectation(description:"controller durable admission held before recorder lease")
        let held = HubCheckpointHold(entered:entered,match:{$0 == "write" && $1 == "owner.json"});defer {held.latch.open()}
        r.bottom.observe = held.observe;r.controller.startAndSave();guard await hubEntered([entered]) else {return}
        let competing = try XCTUnwrap(r.admission.acquire(.guidedTemplate));defer {r.admission.release(competing)}
        var saved = r.settings.current;saved.inputDeviceUID = "later";r.settings.current = saved;r.changedSettings()
        held.latch.open();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,0);XCTAssertEqual(r.enqueues,0)
        XCTAssertEqual(r.controller.model.metadata?.selections.first?.label,"Literal microphone")
        let confirmation = try XCTUnwrap(r.controller.deleteConfirmation)
        r.controller.startAndSave();XCTAssertEqual(r.engine.starts.value,0)
        r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertNil(r.controller.model.metadata);XCTAssertTrue(r.bottom.descriptors.isEmpty);XCTAssertFalse(held.latch.timedOut)
    }
}
