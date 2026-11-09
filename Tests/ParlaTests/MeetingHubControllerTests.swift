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
    func hold() {
        let wait = lock.withLock { () -> Bool in enteredValue = true; return !opened }
        if wait, semaphore.wait(timeout:.now()+5) == .timedOut {
            // The wait result is sticky even if open() beat the delayed watchdog.
            lock.withLock { timedOutValue = true }
            XCTFail("Owned latch synchronous wait exceeded five seconds")
            open()
        }
    }
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
    init(capability: Bool = true,bottom: LifecycleMeetingBottom = LifecycleMeetingBottom(),
         applicationCapability: MeetingHubController.ApplicationCapability = .unavailable,
         application: @escaping (MeetingHubController.ApplicationAttempt) -> MeetingHubController.ApplicationFactoryResult = { _ in .unavailable }) throws {
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
        },diagnostics:DiagnosticStore(),security:{[unowned self] in securityAllowed},copy:{[unowned self] in onCopy?(); copies.append($0)},wall:{[unowned self] in try controllerWall?() ?? clock},applicationCapability:applicationCapability,application:application))
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
        r.controller.startConsentedRecording(); XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.resolutions,0)
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0); XCTAssertEqual(r.permissions,0); XCTAssertNil(r.controller.model.metadata)
    }
    @MainActor func testLatePermissionAfterPageLeaveIsEvidenceOnly() async throws {
        let r = try MeetingHubRig(); defer { r.release() }; r.permission = .undetermined
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertNotNil(r.pendingPermission); r.controller.leavePage(); r.pendingPermission?(true); r.pendingPermission = nil
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0)
    }
    @MainActor func testFrozenUIDFocusAndPageStopUseSameBinder() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else { return }
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
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startConsentedRecording()
        guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testMissingSourceRefusesBeforeRecorderFactory() async throws {
        let r = try MeetingHubRig(); defer { r.release() }; var s = r.settings.current; s.inputDeviceUID = "missing"; r.settings.current = s
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startConsentedRecording()
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
        r.bottom.observe = held.observe; r.controller.startConsentedRecording()
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
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else {return}
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
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else {return false}
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
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        XCTAssertEqual(r.controller.model.message,"Microphone access is off. Allow it in System Settings, then press Start.")
        r.permission = .undetermined; r.controller.openMicrophoneSettings(); r.controller.startConsentedRecording()
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        let callback = try XCTUnwrap(r.pendingPermission); r.pendingPermission = nil
        r.permission = .authorized; callback(true); callback(false)
        guard await hubModel(r.controller, {$0.message == "Microphone access is on. Press Start recording." && !$0.busy}) else {return}
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else {return}
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
        r.controller.startConsentedRecording(); guard await hubEntered([entered]) else {return}
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
        r.bottom.observe = held.observe;r.controller.startConsentedRecording();guard await hubEntered([entered]) else {return}
        let competing = try XCTUnwrap(r.admission.acquire(.guidedTemplate));defer {r.admission.release(competing)}
        var saved = r.settings.current;saved.inputDeviceUID = "later";r.settings.current = saved;r.changedSettings()
        held.latch.open();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,0);XCTAssertEqual(r.enqueues,0)
        XCTAssertEqual(r.controller.model.metadata?.selections.first?.label,"Literal microphone")
        let confirmation = try XCTUnwrap(r.controller.deleteConfirmation)
        r.controller.startConsentedRecording();XCTAssertEqual(r.engine.starts.value,0)
        r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
        guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertNil(r.controller.model.metadata);XCTAssertTrue(r.bottom.descriptors.isEmpty);XCTAssertFalse(held.latch.timedOut)
    }
}

// C1 injected source contract. No live CorePort/default recorder/native permission fake.
@MainActor final class HubApplicationBackend {
    let binding: SelectedApplicationBinding
    let stopped = HubOwnedLatch(), bodyExit = HubOwnedLatch(), cleanup = HubOwnedLatch()
    let entered = XCTestExpectation(description:"application actual source body entered")
    let stopRequested = XCTestExpectation(description:"exact application port stop entered")
    let cleanupEntered = XCTestExpectation(description:"actual application cleanup entered")
    let completed = XCTestExpectation(description:"actual application task returned after EOS")
    var forwarded: Task<Void,Never>?
    private(set) var task: Task<Void,Never>?, completionObserver: Task<Void,Never>?, ingress: MeetingAudioIngress?, body: MeetingAudioIngress.Body?
    private(set) var checks = 0, contextChecks = 0, starts = 0, stops = 0, didComplete = false
    private(set) var context: MeetingAudioIngress.Context?, initialFacts: MeetingAudioIngress.Facts?, error: Error?
    var notStarted = false, unknownRetirement = false
    var accessEarly = false, accessFalsePreActual = false
    let accessNativeReturn = AccessTestHold(), accessCleanup = AccessTestHold(), accessTail = AccessTestHold()
    let accessPublished = XCTestExpectation(description:"synchronous evidence sink returned")
    private(set) var accessKey: ApplicationAudioAccessKey?, accessOutcome: ApplicationAudioAccessOutcome?
    private var accessSink: (@MainActor (ApplicationAudioAccessOutcome) -> Void)?
    private var uncertainAccess: CheckedContinuation<Void,Never>?
    var accessPort: MeetingSelectedApplicationCapture.CorePort {
        .init(validate:port.validate,validateContext:port.validateContext,startMode:{ [self] value,ingress,mode,nonce,sink in
            if mode == .retainedRecording { return port.start(value,ingress) }
            stopped.open(); bodyExit.open(); cleanup.open() // retained-only fixture latches have no access role
            starts += 1; self.ingress = ingress; initialFacts = ingress.facts
            let key = ApplicationAudioAccessKey(binding:value,context:ingress.context,nonce:nonce)
            accessKey = key; accessSink = sink
            let evidence = ApplicationAudioAccessOutcome(key:key,progress:unknownRetirement ? .failed(.retirement) : .nativeStartReturned,
                disposition:unknownRetirement ? .heldOrUnknownCleanup : .appOwnedRetired)
            if notStarted {
                if accessFalsePreActual { sink(evidence) } // hostile fake: adapter/controller must discard it
                return .notStarted
            }
            if accessEarly { endAccessIngress(ingress) }
            let actual = Task { @MainActor [self] in
                entered.fulfill()
                if !accessEarly {
                    await accessNativeReturn.wait(); cleanupEntered.fulfill(); await accessCleanup.wait()
                    endAccessIngress(ingress)
                    accessOutcome = evidence; sink(evidence); accessPublished.fulfill()
                }
                if unknownRetirement { await withCheckedContinuation { uncertainAccess = $0 }; return }
                await accessTail.wait()
            }
            task = actual // registered before the hostile synchronous early delivery
            if !unknownRetirement {
                completionObserver = Task { [self] in await actual.value; didComplete = true; completed.fulfill() }
            }
            if accessEarly { accessOutcome = evidence; sink(evidence); accessPublished.fulfill() }
            return .actual(.init(task:actual,requestStop:{ [self] in
                stops += 1; ingress.fence()
                if stops == 1 { stopRequested.fulfill() }
            }))
        })
    }
    private func endAccessIngress(_ ingress: MeetingAudioIngress) {
        do { _ = try ingress.end(ingress.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0)) }
        catch { self.error = error }
    }
    func replayAccess(_ value: ApplicationAudioAccessOutcome) { accessSink?(value) }
    var accessTimedOut: Bool { accessNativeReturn.timedOut || accessCleanup.timedOut || accessTail.timedOut }
    init(_ binding: SelectedApplicationBinding) { self.binding = binding }
    var port: MeetingSelectedApplicationCapture.CorePort {
        .init(validate:{ [self] value in
            checks += 1
            return value.valid && value == binding && value.label.utf8.elementsEqual(binding.label.utf8) &&
                value.bundleID.utf8.elementsEqual(binding.bundleID.utf8) && value.bundlePath.utf8.elementsEqual(binding.bundlePath.utf8) &&
                value.executablePath.utf8.elementsEqual(binding.executablePath.utf8)
        },validateContext:{ [self] value,context in
            contextChecks += 1; self.context = context; return value.matches(context)
        },start:{ [self] value,ingress in
            starts += 1; self.ingress = ingress; initialFacts = ingress.facts
            XCTAssertEqual(value,binding)
            guard !notStarted else { return .notStarted }
            do {
                let first = try ingress.enter()
                let samples: [Float] = [-1,0.5,0,1]
                _ = try samples.withUnsafeBufferPointer { try ingress.receive(first,canonical:$0,input:.init(rate:16_000,channels:1,frames:4)) }
                try ingress.leave(first); body = try ingress.enter()
            } catch { self.error = error; return .notStarted }
            // This exact task is the producer; no wrapper substitutes for its body/cleanup/EOS.
            let actual = Task { @MainActor [self] in
                entered.fulfill()
                await stopped.wait(); await bodyExit.wait()
                do { if let body { try ingress.leave(body); self.body = nil } } catch { self.error = error }
                cleanupEntered.fulfill(); await cleanup.wait()
                do { if !unknownRetirement { _ = try ingress.end(ingress.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0)) } }
                catch { self.error = error }
            }
            task = actual
            if !unknownRetirement {
                // Receipt-only observation AFTER the unchanged actual task returns.
                completionObserver = Task { [self] in await actual.value;didComplete = true;completed.fulfill() }
            }
            return .actual(.init(task:actual,requestStop:{ [self] in
                stops += 1; ingress.fence(); stopped.open()
                if stops == 1 { stopRequested.fulfill() }
            }))
        })
    }
    func release() { ingress?.fence(); stopped.open(); bodyExit.open(); cleanup.open(); accessNativeReturn.open(); accessCleanup.open(); accessTail.open() }
    var timedOut: Bool { stopped.timedOut || bodyExit.timedOut || cleanup.timedOut }
    func latePCM() throws -> Int {
        let ingress = try XCTUnwrap(ingress), body = try XCTUnwrap(body)
        return try [Float(1)].withUnsafeBufferPointer { try ingress.receive(body,canonical:$0,input:.init(rate:16_000,channels:1,frames:1)) }
    }
}

@MainActor final class HubApplicationOperation {
    let entered = XCTestExpectation(description:"application controller operation entered")
    let completed = XCTestExpectation(description:"application controller operation returned")
    private(set) var task: Task<Void,Never>?, observer: Task<Void,Never>?, result: Bool?
    init(_ action: @escaping @MainActor () async -> Bool) {
        let actual = Task { [self] in entered.fulfill();result = await action() }
        task = actual
        observer = Task { [self] in await actual.value;completed.fulfill() }
    }
}
@MainActor enum HubApplicationFailureResources {
    // Fixed suite creates fewer than 48 application fixtures. Failure retention never starts another drain.
    private(set) static var fixtures: [HubApplicationRig] = []
    private(set) static var microphoneFixtures: [MeetingHubRig] = []
    static func retainMicrophone(_ rig: MeetingHubRig) {
        guard !microphoneFixtures.contains(where:{$0 === rig}) else {return}
        precondition(microphoneFixtures.count < 4);microphoneFixtures.append(rig)
    }
    static func retain(_ rig: HubApplicationRig) {
        guard !fixtures.contains(where:{$0 === rig}) else { return }
        precondition(fixtures.count < 48); fixtures.append(rig)
    }
}
@MainActor final class HubApplicationRig {
    let controller = MeetingHubController(), bottom: LifecycleMeetingBottom, settings = HubSavedSettings(), store: SettingsStore
    private(set) var factories = 0, stores = 0, settingsReads = 0, clockReads = 0
    private(set) var attempts: [MeetingHubController.ApplicationAttempt] = [], backends: [HubApplicationBackend] = []
    private(set) var adapters: [MeetingSelectedApplicationCapture] = [], operations: [HubApplicationOperation] = []
    var factoryEntered: XCTestExpectation?, heldGates: [HubOwnedLatch] = []
    var validation: HubOwnedLatch?, validationEntered: XCTestExpectation?, factoryUnavailable = false, notStarted = false
    var unknownRetirement = false, allowSettingsEvent = false, auxiliaryRoots: [URL] = []
    var accessEarly = false, accessFalsePreActual = false, rawPreActualEvidence = false
    enum BindingMutation {case none,source,generation,epoch,label}
    var bindingMutation = BindingMutation.none, clock: Int64 = 1_000_000_000_000, wallOverride: (() throws -> Int64)?
    init(capability: Bool = true,applicationCapability: MeetingHubController.ApplicationCapability = .injectedContractOnly,
         bottom: LifecycleMeetingBottom = LifecycleMeetingBottom()) throws {
        self.bottom = bottom; bottom.retainSourceBytes = true
        let saved = settings
        store = SettingsStore(url:URL(fileURLWithPath:"/virtual/application-contract-settings.json"),credentials:CredentialStore(backend:HubRefusingCredentials()),
            scratchpadIO:.init(read:{_ in XCTFail("scratchpad read");return nil},write:{_,_ in XCTFail("scratchpad write")}),
            documentIO:.init(read:{try JSONEncoder().encode(saved.current)}),atomicWrite:{_,_ in XCTFail("settings write")})
        controller.bind(.init(captureCapability:capability,makeStore:{ [unowned self] in
            stores += 1; return MeetingSessionStore(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{ [unowned self] in clock })
        },microphone:{ _ in XCTFail("application branch reached microphone factory"); return .init(validate:{_ in false},start:{s,_ in .init(source:s.instance,exit:.notStarted)},requestStop:{}) },
        resolveInput:{_ in XCTFail("application branch resolved microphone");throw MeetingSession.Failure.unavailable},
        authorization:{XCTFail("application branch queried microphone permission");return .denied},
        requestAccess:{_ in XCTFail("application branch requested microphone access")},openPrivacy:{XCTFail("application branch opened microphone privacy")},
        settings:{ [unowned self] in settingsReads += 1; if !allowSettingsEvent { XCTFail("application branch read microphone settings") };return settings.current },
        settingsObject:store,selectionEpoch:{XCTFail("capture queried recognition selection");return UUID()},
        enqueue:{_ in XCTFail("capture enqueued recognition");return nil},diagnostics:DiagnosticStore(),security:{false},copy:{_ in XCTFail("capture copied text")},
        wall:{ [unowned self] in clockReads += 1;return try wallOverride?() ?? clock },applicationCapability:applicationCapability,application:{ [unowned self] attempt in
            factories += 1; attempts.append(attempt)
            if factoryUnavailable { return .unavailable }
            let b = attempt.binding
            let binding = SelectedApplicationBinding(selection:b.selection,source:bindingMutation == .source ? UUID() : b.source,
                sourceGeneration:bindingMutation == .generation ? b.sourceGeneration+1 : b.sourceGeneration,
                captureEpoch:bindingMutation == .epoch ? UUID() : b.captureEpoch,pid:b.pid,launchNanoseconds:b.launchNanoseconds,
                bundleID:b.bundleID,bundlePath:b.bundlePath,executablePath:b.executablePath,label:bindingMutation == .label ? "Cafe\u{301}" : b.label)
            let backend = HubApplicationBackend(binding); backend.notStarted = notStarted; backend.unknownRetirement = unknownRetirement
            backend.accessEarly = accessEarly; backend.accessFalsePreActual = accessFalsePreActual
            backends.append(backend); factoryEntered?.fulfill()
            let adapter = MeetingSelectedApplicationCapture(binding:binding,core:attempt.mode == .accessAttempt ? backend.accessPort : backend.port,
                enabled:true,mode:attempt.mode,attemptNonce:attempt.nonce,outcome:attempt.receiveAccessOutcome); adapters.append(adapter)
            let port = adapter.port, rawPreActual = rawPreActualEvidence
            return .injected(.init(validate:{ [unowned self] selection in
                if let validation { validationEntered?.fulfill(); await validation.wait() }
                return await port.validate(selection)
            },start:{ selection,ingress in
                let producer = port.start(selection,ingress)
                if rawPreActual {
                    attempt.receiveAccessOutcome(.init(key:.init(binding:binding,context:ingress.context,nonce:attempt.nonce),
                        progress:.nativeStartReturned,disposition:.appOwnedRetired))
                }
                if case .actual(let actual) = producer.exit {
                    backend.forwarded = actual
                    XCTAssertEqual(actual,backend.task,"accepted adapter must return the exact actual task")
                }
                return producer
            },requestStop:port.requestStop))
        }))
    }
    func release() {
        if !gatesHealthy || controller.model.busy || backends.contains(where:{$0.task != nil && !$0.didComplete}) || operations.contains(where:{$0.result == nil}) {
            HubApplicationFailureResources.retain(self)
        }
        validation?.open();heldGates.forEach {$0.open()};backends.forEach { $0.release() }
    }
    func operation(_ action: @escaping @MainActor () async -> Bool) -> HubApplicationOperation {
        precondition(operations.count < 16); let value = HubApplicationOperation(action); operations.append(value); return value
    }
    private var gatesHealthy: Bool {validation?.timedOut != true && !heldGates.contains(where:{$0.timedOut}) && !backends.contains(where:{$0.timedOut || $0.accessTimedOut})}
    var observationContext = ""
    func observe(_ test: XCTestCase,_ expectations: [XCTestExpectation]) async -> Bool {
        let result = await XCTWaiter.fulfillment(of:expectations,timeout:4)
        guard result == .completed,gatesHealthy else { XCTFail("No bounded application observation or watchdog fired [\(observationContext); \(expectations.map(\.expectationDescription).joined(separator: ", "))]; retained without a teardown join");HubApplicationFailureResources.retain(self);return false }
        return true
    }
    func finish(_ test: XCTestCase,_ operation: HubApplicationOperation) async -> Bool {
        let exact = operation.task
        guard await observe(test,[operation.completed]),operation.result != nil,let exact,operation.task == exact else {
            XCTFail("No matching observed operation return; refusing final join");HubApplicationFailureResources.retain(self);return false
        }
        await exact.value; return true // exact identity AND observed return precede this join
    }
    func drain(_ test: XCTestCase) async -> Bool {
        await finish(test,operation { [controller] in await controller.drainActions();return true })
    }
    func open(_ test: XCTestCase) async -> Bool { controller.openPage();return await drain(test) }
    func start(_ test: XCTestCase,snapshot: MeetingHubController.ApplicationSnapshot = hubApplicationSnapshot()) async -> Bool {
        guard await open(test) else { return false }
        guard controller.acceptSourceChoice(.selectedApplication(snapshot)),let challenge = controller.prepareApplicationStart() else {XCTFail("No pure challenge after open");return false}
        controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true)
        guard await drain(test) else {return false}
        guard let backend = backends.last else {XCTFail("No injected backend on affirmative Start");HubApplicationFailureResources.retain(self);return false}
        return await observe(test,[backend.entered])
    }
    func joinedActual(_ test: XCTestCase,_ backend: HubApplicationBackend) async -> Bool {
        guard await observe(test,[backend.completed]),backend.didComplete,let actual = backend.task,backend.forwarded == actual else {
            XCTFail("No matching observed actual source return; refusing final join");HubApplicationFailureResources.retain(self);return false
        }
        await actual.value
        guard !backend.timedOut,backend.error == nil else {XCTFail("Source cleanup was not successful");HubApplicationFailureResources.retain(self);return false}
        return true
    }
    func state(_ test: XCTestCase,_ predicate: @escaping (HubMeetingModel) -> Bool) async -> Bool {
        let emitted = XCTestExpectation(description:"application controller emitted exact lifecycle state")
        var seen = false
        let sub = controller.$model.sink { value in if !seen && predicate(value) { seen = true; emitted.fulfill() } }
        defer { sub.cancel() };return await observe(test,[emitted])
    }
    func detach(_ test: XCTestCase) async -> Bool {
        controller.reserveShutdown()
        let operation = operation { [controller] in await controller.drainRestart() }
        guard await finish(test,operation) else { return false }
        XCTAssertEqual(operation.result,true); controller.releaseRestart(); return operation.result == true
    }
}
func hubApplicationSnapshot(selection: UUID = UUID(),revision: UUID = UUID(),pid: Int32 = 123,launch: Int64 = 7,
    bundle: String = "example.application",bundlePath: String = "/Applications/Example.app",
    executable: String = "/Applications/Example.app/Contents/MacOS/Example",label: String = "Literal application") -> MeetingHubController.ApplicationSnapshot {
    .init(selectionID:selection,revision:revision,pid:pid,launchNanoseconds:launch,bundleID:bundle,bundlePath:bundlePath,executablePath:executable,label:label)
}

extension MeetingHubControllerTests {
    @MainActor func testFrozenSourceConstructionRenderAndDefaultOffQueryNothing() async throws {
        for gates in [(false,MeetingHubController.ApplicationCapability.injectedContractOnly),(true,.unavailable)] {
            let r = try HubApplicationRig(capability:gates.0,applicationCapability:gates.1);defer {r.release()}
            let snapshot = hubApplicationSnapshot()
            XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(snapshot)))
            XCTAssertNil(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:UUID(),affirmed:true)
            _ = r.controller.model;_ = r.controller.sourceChoice;_ = r.controller.applicationState
            r.controller.startConsentedRecording()
            XCTAssertEqual(r.stores,0);XCTAssertEqual(r.bottom.calls,0);XCTAssertEqual(r.clockReads,0)
            guard await r.open(self) else { return }
            let calls = r.bottom.calls,clocks = r.clockReads
            XCTAssertNil(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:UUID(),affirmed:true)
            XCTAssertEqual(r.bottom.calls,calls);XCTAssertEqual(r.clockReads,clocks);XCTAssertEqual(r.factories,0);XCTAssertEqual(r.settingsReads,0)
            XCTAssertEqual(r.controller.applicationState,.unavailable)
            guard await r.detach(self) else { return }
        }
    }
    @MainActor func testApplicationConsentIsExactSingleUseAndSourceSpecific() async throws {
        let r = try HubApplicationRig();defer {r.release()};guard await r.open(self) else {return}
        let a = hubApplicationSnapshot(),b = hubApplicationSnapshot(pid:124)
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(a)))
        let calls = r.bottom.calls,clocks = r.clockReads
        let first = try XCTUnwrap(r.controller.prepareApplicationStart()),replacement = try XCTUnwrap(r.controller.prepareApplicationStart())
        XCTAssertEqual(r.bottom.calls,calls);XCTAssertEqual(r.clockReads,clocks);XCTAssertEqual(r.settingsReads,0)
        XCTAssertNotEqual(first.id,replacement.id)
        r.controller.confirmApplicationStart(challengeID:first.id,affirmed:true)
        r.controller.confirmApplicationStart(challengeID:replacement.id,affirmed:true);XCTAssertEqual(r.factories,0)
        let denied = try XCTUnwrap(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:denied.id,affirmed:false)
        r.controller.confirmApplicationStart(challengeID:denied.id,affirmed:true);XCTAssertEqual(r.factories,0)
        let old = try XCTUnwrap(r.controller.prepareApplicationStart())
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(b)));XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(a)))
        let current = try XCTUnwrap(r.controller.prepareApplicationStart());XCTAssertNotEqual(old.sourceRevision,current.sourceRevision)
        r.controller.confirmApplicationStart(challengeID:old.id,affirmed:true);XCTAssertEqual(r.factories,0)
        let page = try XCTUnwrap(r.controller.prepareApplicationStart());r.controller.leavePage()
        guard await r.drain(self),await r.open(self) else {return}
        r.controller.confirmApplicationStart(challengeID:page.id,affirmed:true);XCTAssertEqual(r.factories,0)
        let fresh = try XCTUnwrap(r.controller.prepareApplicationStart());XCTAssertNotEqual(page.pageLifetime,fresh.pageLifetime)
        r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true);r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true)
        guard await r.drain(self),let backend = r.backends.first,await r.observe(self,[backend.entered]) else {return}
        XCTAssertEqual(r.factories,1);XCTAssertEqual(backend.starts,1);XCTAssertEqual(r.attempts.first?.consent.challenge,fresh)
        r.controller.stopAndSave();backend.bodyExit.open();backend.cleanup.open()
        guard await r.joinedActual(self,backend),await r.drain(self),await r.detach(self),await r.open(self) else {return}
        XCTAssertNil(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true)
        XCTAssertEqual(r.factories,1);XCTAssertNotNil(r.controller.model.metadata)
        guard await r.detach(self) else {return}
    }
    @MainActor func testSourceSnapshotBoundsAndMissingIncarnationRefuseBeforeFactory() async throws {
        let r = try HubApplicationRig();defer {r.release()}
        let invalid = [hubApplicationSnapshot(pid:0),hubApplicationSnapshot(pid:-1),hubApplicationSnapshot(launch:0),hubApplicationSnapshot(launch:-1),
            hubApplicationSnapshot(bundle:""),hubApplicationSnapshot(bundle:String(repeating:"x",count:257)),hubApplicationSnapshot(bundle:"a\u{0}b"),
            hubApplicationSnapshot(bundlePath:"relative"),hubApplicationSnapshot(bundlePath:"/a\nb"),hubApplicationSnapshot(bundlePath:"/"+String(repeating:"x",count:4096)),
            hubApplicationSnapshot(executable:""),hubApplicationSnapshot(executable:"relative"),hubApplicationSnapshot(executable:"/a\tb"),
            hubApplicationSnapshot(executable:"/"+String(repeating:"x",count:4096)),hubApplicationSnapshot(label:""),hubApplicationSnapshot(label:"a\r"),
            hubApplicationSnapshot(label:String(repeating:"é",count:65))]
        for value in invalid {XCTAssertFalse(r.controller.acceptSourceChoice(.selectedApplication(value)));XCTAssertNil(r.controller.prepareApplicationStart())}
        let selection = UUID(),revision = UUID()
        let composed = hubApplicationSnapshot(selection:selection,revision:revision,label:"Café")
        let decomposed = hubApplicationSnapshot(selection:selection,revision:revision,label:"Cafe\u{301}")
        XCTAssertNotEqual(composed,decomposed)
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot(bundle:String(repeating:"x",count:256),
            bundlePath:"/"+String(repeating:"x",count:4095),executable:"/"+String(repeating:"x",count:4095),label:String(repeating:"é",count:64)))))
        XCTAssertEqual(r.factories,0);XCTAssertEqual(r.stores,0);XCTAssertEqual(r.clockReads,0);XCTAssertEqual(r.bottom.calls,0)
    }
    @MainActor func testApplicationAdapterReceivesExactSourceEpochAndOneRoutePolicy() async throws {
        let r = try HubApplicationRig();defer {r.release()};let snapshot = hubApplicationSnapshot(label:"Café")
        guard await r.start(self,snapshot:snapshot),let backend = r.backends.first else {return}
        let attempt = try XCTUnwrap(r.attempts.first),binding = attempt.binding,context = try XCTUnwrap(backend.context)
        XCTAssertEqual(binding.selection,snapshot.selectionID);XCTAssertEqual(binding.pid,snapshot.pid);XCTAssertEqual(binding.launchNanoseconds,snapshot.launchNanoseconds)
        XCTAssertTrue(binding.bundleID.utf8.elementsEqual(snapshot.bundleID.utf8));XCTAssertTrue(binding.bundlePath.utf8.elementsEqual(snapshot.bundlePath.utf8))
        XCTAssertTrue(binding.executablePath.utf8.elementsEqual(snapshot.executablePath.utf8));XCTAssertTrue(binding.label.utf8.elementsEqual(snapshot.label.utf8))
        XCTAssertEqual(binding.source,attempt.consent.source);XCTAssertEqual(binding.captureEpoch,attempt.consent.captureEpoch)
        XCTAssertEqual(context.session,attempt.consent.session);XCTAssertEqual(context.source,binding.source);XCTAssertEqual(context.sourceGeneration,1)
        XCTAssertEqual(context.segment,attempt.segment);XCTAssertEqual(context.epoch,binding.captureEpoch);XCTAssertGreaterThan(context.ownerGeneration,0)
        XCTAssertEqual(backend.initialFacts?.slots,2);XCTAssertEqual(backend.initialFacts?.allocated,2);XCTAssertEqual(backend.initialFacts?.accepted,0)
        XCTAssertEqual(backend.initialFacts?.rawBytes,1_920_088);XCTAssertEqual(backend.starts,1);XCTAssertEqual(backend.contextChecks,1)
        XCTAssertEqual(r.controller.applicationState,.injectedRecording);XCTAssertEqual(r.controller.model.metadata?.selections.count,1)
        XCTAssertEqual(r.controller.model.metadata?.selections.first?.kind,.selectedApplication)
        r.controller.stopAndSave();backend.bodyExit.open();backend.cleanup.open()
        guard await r.joinedActual(self,backend),await r.drain(self) else {return}
        let ledger = try MeetingSession.Ledger.decode(r.bottom.metadata),chunk = try XCTUnwrap(ledger.chunks.first)
        XCTAssertEqual(chunk.track,0);XCTAssertEqual(chunk.sourceGeneration,1);XCTAssertEqual(chunk.frames,4)
        XCTAssertEqual(chunk.timing,.init(pts:0,denominator:1,sample:0,rate:16_000,epoch:binding.captureEpoch,mapping:.unknown))
        let files = r.bottom.rootNode?.children.values.filter {$0.name.hasSuffix(".source.wav")} ?? []
        XCTAssertEqual(files.count,1);let file = try XCTUnwrap(files.first),bytes = file.bytes(0,file.length)
        let header: [UInt8] = [82,73,70,70,44,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0,100,97,116,97,8,0,0,0]
        XCTAssertEqual(bytes.count,52);XCTAssertEqual(Array(bytes.prefix(44)),header)
        XCTAssertEqual(Array(bytes.dropFirst(44)),[0,128,0,64,0,0,255,127]);XCTAssertEqual(r.settingsReads,0)
        XCTAssertEqual(r.controller.applicationState,.retiredPermissionUnknown)
        guard await r.detach(self) else {return}
        // The injected boundary has no route discovery: one port is not native route qualification.
    }
    @MainActor func testApplicationFactoryRefusalAndForeignSourceNeverAdmitSuccessor() async throws {
        for mode in [0,1,2,3,4,5] {
            let r = try HubApplicationRig();defer {r.release()};r.factoryUnavailable = mode == 0;r.notStarted = mode == 2
            r.bindingMutation = mode == 1 ? .source : mode == 3 ? .generation : mode == 4 ? .label : mode == 5 ? .epoch : .none
            guard await r.open(self) else {return};XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot(label:"Café"))))
            let challenge = try XCTUnwrap(r.controller.prepareApplicationStart())
            r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true)
            guard await r.drain(self) else {return}
            XCTAssertEqual(r.factories,1);XCTAssertEqual(r.settingsReads,0)
            if mode != 2 && mode != 5 {XCTAssertNil(r.controller.model.metadata);XCTAssertEqual(r.backends.first?.starts ?? 0,0)}
            else {XCTAssertNotNil(r.controller.model.metadata);XCTAssertNil(r.controller.prepareApplicationStart())}
            if mode == 5 {
                let backend = try XCTUnwrap(r.backends.first)
                XCTAssertEqual(backend.starts,0);XCTAssertEqual(backend.contextChecks,1)
                XCTAssertNotEqual(backend.context?.epoch,backend.binding.captureEpoch)
            }
            XCTAssertEqual(r.controller.applicationState,mode == 0 ? .unavailable : .refusedBeforeStart)
            r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true);XCTAssertEqual(r.factories,1)
            guard await r.detach(self) else {return}
        }
    }
    @MainActor func testSourceChangeRefusalAndObservedLossNeverRetarget() async throws {
        let r = try HubApplicationRig();defer {r.release()};let snapshot = hubApplicationSnapshot()
        guard await r.start(self,snapshot:snapshot),let backend = r.backends.first else {return}
        let old = try XCTUnwrap(r.attempts.first?.consent)
        for next in [hubApplicationSnapshot(pid:snapshot.pid,launch:snapshot.launchNanoseconds+1),hubApplicationSnapshot(executable:"/other"),hubApplicationSnapshot(),snapshot] {
            XCTAssertFalse(r.controller.acceptSourceChoice(.selectedApplication(next)))
        }
        r.controller.applicationSourceInvalidated(old)
        guard await r.observe(self,[backend.stopRequested]) else {return}
        XCTAssertFalse(try XCTUnwrap(backend.ingress).facts.open);XCTAssertEqual(try backend.latePCM(),0);XCTAssertEqual(r.factories,1)
        XCTAssertNil(r.controller.prepareApplicationStart());backend.bodyExit.open();backend.cleanup.open()
        guard await r.joinedActual(self,backend),await r.drain(self) else {return}
        let deletion = try XCTUnwrap(r.controller.deleteConfirmation);r.controller.deleteConfirmed(session:deletion.session,intent:deletion.intent)
        guard await r.drain(self) else {return}
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        let fresh = try XCTUnwrap(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true)
        guard await r.drain(self),let next = r.backends.last,await r.observe(self,[next.entered]) else {return}
        let new = try XCTUnwrap(r.attempts.last?.consent)
        XCTAssertNotEqual(old.source,new.source);XCTAssertNotEqual(old.captureEpoch,new.captureEpoch);XCTAssertNotEqual(old.session,new.session)
        XCTAssertNotEqual(old.challenge.sourceRevision,new.challenge.sourceRevision)
        r.controller.applicationSourceInvalidated(old);XCTAssertEqual(next.stops,0);XCTAssertTrue(try XCTUnwrap(next.ingress).facts.open)
        XCTAssertEqual(r.factories,2);r.controller.stopAndSave();next.bodyExit.open();next.cleanup.open()
        guard await r.joinedActual(self,next),await r.drain(self),await r.detach(self) else {return}
    }
}

extension MeetingHubControllerTests {
    @MainActor func testApplicationOwnerEpochAndOutputReviewAreIndependent() async throws {
        let r = try HubApplicationRig();defer {r.release()};guard await r.open(self) else {return}
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        let old = try XCTUnwrap(r.controller.prepareApplicationStart())
        guard await r.detach(self),await r.open(self) else {return}
        r.controller.confirmApplicationStart(challengeID:old.id,affirmed:true);XCTAssertEqual(r.factories,0)
        let fresh = try XCTUnwrap(r.controller.prepareApplicationStart())
        XCTAssertNotEqual(old.ownerEpoch,fresh.ownerEpoch);XCTAssertNotEqual(old.pageLifetime,fresh.pageLifetime)
        // The explicit output-settings action can query settings; preparing/confirming capture cannot.
        r.allowSettingsEvent = true;r.controller.savedConfigurationChanged();r.allowSettingsEvent = false
        XCTAssertEqual(r.settingsReads,1)
        r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true)
        guard await r.drain(self),let backend = r.backends.first,await r.observe(self,[backend.entered]) else {return}
        XCTAssertEqual(r.attempts.first?.consent.challenge,fresh);XCTAssertEqual(r.controller.applicationState,.injectedRecording)
        var settings = r.settings.current;settings.inputDeviceUID = "unrelated-output-review";r.settings.current = settings
        r.allowSettingsEvent = true;r.controller.savedConfigurationChanged();r.allowSettingsEvent = false
        XCTAssertEqual(backend.stops,0);XCTAssertTrue(try XCTUnwrap(backend.ingress).facts.open);XCTAssertEqual(r.factories,1)
        r.controller.stopAndSave();backend.bodyExit.open();backend.cleanup.open()
        guard await r.joinedActual(self,backend),await r.drain(self),await r.detach(self) else {return}
    }
}

extension HubApplicationRig {
    func accessDetach(_ test: XCTestCase) async -> Bool {
        controller.reserveShutdown()
        let operation = operation { [controller] in await controller.drainRestart() }
        guard await observe(test,[operation.entered]),await finish(test,operation) else { return false }
        XCTAssertEqual(operation.result,true); controller.releaseRestart(); return operation.result == true
    }
    func accessOpen(_ test: XCTestCase) async -> Bool {
        let settled = XCTestExpectation(description:"new metadata work published its actual settlement")
        var sawBusy = false, seen = false
        let sub = controller.$model.sink { model in
            if model.busy { sawBusy = true }
            if sawBusy,!model.busy,!seen { seen = true; settled.fulfill() }
        }
        defer { sub.cancel() }
        controller.openPage()
        return await observe(test,[settled])
    }
    func accessBegin(_ test: XCTestCase,early: Bool = false,afterOpen: () -> Void = {}) async -> HubApplicationBackend? {
        accessEarly = early
        guard await accessOpen(test) else { return nil }
        afterOpen()
        guard controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())) else { return nil }
        let factory = XCTestExpectation(description:"explicit access factory returned a frozen port")
        factoryEntered = factory
        guard let challenge = controller.prepareApplicationStart(purpose:.audioAccessAttemptContract) else { XCTFail("No access challenge"); return nil }
        controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true,purpose:.audioAccessAttemptContract)
        guard await observe(test,[factory]),let backend = backends.last,await observe(test,[backend.entered]) else { return nil }
        if early {
            guard await observe(test,[backend.accessPublished,backend.accessTail.entered]) else { return nil }
        } else {
            guard await observe(test,[backend.accessNativeReturn.entered]) else { return nil }
        }
        return backend
    }
    func accessDisposition(_ test: XCTestCase,_ backend: HubApplicationBackend) async -> Bool {
        backend.accessNativeReturn.open()
        guard await observe(test,[backend.accessNativeReturn.returned,backend.cleanupEntered,backend.accessCleanup.entered]) else { return false }
        backend.accessCleanup.open()
        guard await observe(test,[backend.accessCleanup.returned,backend.accessPublished]) else { return false }
        if !backend.unknownRetirement { return await observe(test,[backend.accessTail.entered]) }
        return true
    }
    func accessFinish(_ test: XCTestCase,_ backend: HubApplicationBackend) async -> Bool {
        guard !backend.unknownRetirement else { XCTFail("Unknown cleanup has no final join"); return false }
        backend.accessTail.open()
        guard await observe(test,[backend.accessTail.returned]),await joinedActual(test,backend) else { return false }
        return await state(test,{$0.state == .stopped && !$0.busy})
    }
}
extension MeetingHubControllerTests {
    @MainActor func testAccessConsentPurposeIsExactSingleUseAndDefaultOff() async throws {
        for gates in [(false,MeetingHubController.ApplicationCapability.injectedContractOnly),(true,.unavailable)] {
            let r = try HubApplicationRig(capability:gates.0,applicationCapability:gates.1); defer { r.release() }
            XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
            XCTAssertNil(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
            XCTAssertEqual(r.stores,0); XCTAssertEqual(r.bottom.calls,0)
            guard await r.accessOpen(self) else { return }
            XCTAssertNil(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
            r.controller.confirmApplicationStart(challengeID:UUID(),affirmed:true,purpose:.audioAccessAttemptContract)
            XCTAssertEqual(r.factories,0); XCTAssertEqual(r.settingsReads,0)
            guard await r.accessDetach(self) else { return }
        }
        let r = try HubApplicationRig(); defer { r.release() }; guard await r.accessOpen(self) else { return }
        let a = hubApplicationSnapshot(), b = hubApplicationSnapshot(pid:124)
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(a)))
        let retained = try XCTUnwrap(r.controller.prepareApplicationStart())
        r.controller.confirmApplicationStart(challengeID:retained.id,affirmed:true,purpose:.audioAccessAttemptContract)
        r.controller.confirmApplicationStart(challengeID:retained.id,affirmed:true) // consumed wrong purpose
        let access = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        r.controller.confirmApplicationStart(challengeID:access.id,affirmed:true) // retained reply cannot authorize access
        r.controller.confirmApplicationStart(challengeID:access.id,affirmed:true,purpose:.audioAccessAttemptContract)
        for wrongID in [false,true] {
            let value = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
            r.controller.confirmApplicationStart(challengeID:wrongID ? UUID() : value.id,affirmed:wrongID,purpose:.audioAccessAttemptContract)
            r.controller.confirmApplicationStart(challengeID:value.id,affirmed:true,purpose:.audioAccessAttemptContract)
        }
        let old = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(b))); XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(a)))
        r.controller.confirmApplicationStart(challengeID:old.id,affirmed:true,purpose:.audioAccessAttemptContract)
        let page = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        r.controller.leavePage(); guard await r.state(self,{!$0.busy}),await r.accessOpen(self) else { return }
        r.controller.confirmApplicationStart(challengeID:page.id,affirmed:true,purpose:.audioAccessAttemptContract)
        let owner = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        guard await r.accessDetach(self),await r.accessOpen(self) else { return }
        r.controller.confirmApplicationStart(challengeID:owner.id,affirmed:true,purpose:.audioAccessAttemptContract)
        XCTAssertEqual(r.factories,0); XCTAssertNil(r.controller.applicationAccessOutcome); XCTAssertEqual(r.settingsReads,0)
        let fresh = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        XCTAssertNotEqual(owner.ownerEpoch,fresh.ownerEpoch); XCTAssertEqual(fresh.purpose,.audioAccessAttemptContract)
        r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:false,purpose:.audioAccessAttemptContract)
        guard await r.accessDetach(self) else { return }
    }
    @MainActor func testAccessOutcomeIsBoundedPermissionUnknownAndNeverStarts() async throws {
        for unknown in [false,true] {
            let r = try HubApplicationRig(); defer { r.release() }; r.unknownRetirement = unknown
            guard let backend = await r.accessBegin(self) else { return }
            let attempt = try XCTUnwrap(r.attempts.last), key = try XCTUnwrap(backend.accessKey), c = key.context
            XCTAssertEqual(attempt.mode,.accessAttempt); XCTAssertEqual(r.controller.applicationState,.actualAttemptOwned)
            XCTAssertNil(r.controller.applicationAccessOutcome)
            // Every ingress identity field and the per-attempt nonce is independently foreign.
            let contexts: [MeetingAudioIngress.Context] = [
                .init(session:UUID(),ownerGeneration:c.ownerGeneration,source:c.source,sourceGeneration:c.sourceGeneration,segment:c.segment,epoch:c.epoch),
                .init(session:c.session,ownerGeneration:c.ownerGeneration+1,source:c.source,sourceGeneration:c.sourceGeneration,segment:c.segment,epoch:c.epoch),
                .init(session:c.session,ownerGeneration:c.ownerGeneration,source:UUID(),sourceGeneration:c.sourceGeneration,segment:c.segment,epoch:c.epoch),
                .init(session:c.session,ownerGeneration:c.ownerGeneration,source:c.source,sourceGeneration:c.sourceGeneration+1,segment:c.segment,epoch:c.epoch),
                .init(session:c.session,ownerGeneration:c.ownerGeneration,source:c.source,sourceGeneration:c.sourceGeneration,segment:UUID(),epoch:c.epoch),
                .init(session:c.session,ownerGeneration:c.ownerGeneration,source:c.source,sourceGeneration:c.sourceGeneration,segment:c.segment,epoch:UUID())]
            for context in contexts {
                attempt.receiveAccessOutcome(.init(key:.init(binding:key.binding,context:context,nonce:key.nonce),progress:.nativeStartReturned,disposition:.appOwnedRetired))
            }
            attempt.receiveAccessOutcome(.init(key:.init(binding:key.binding,context:c,nonce:UUID()),progress:.nativeStartReturned,disposition:.appOwnedRetired))
            let b = key.binding
            for field in 0..<11 {
                let foreign = SelectedApplicationBinding(selection:field == 0 ? UUID() : b.selection,source:field == 1 ? UUID() : b.source,
                    sourceGeneration:field == 2 ? b.sourceGeneration+1 : b.sourceGeneration,captureEpoch:field == 3 ? UUID() : b.captureEpoch,
                    pid:field == 4 ? b.pid+1 : b.pid,launchNanoseconds:field == 5 ? b.launchNanoseconds+1 : b.launchNanoseconds,
                    bundleID:field == 6 ? b.bundleID+"x" : b.bundleID,bundlePath:field == 7 ? b.bundlePath+"x" : b.bundlePath,
                    executablePath:field == 8 ? b.executablePath+"x" : b.executablePath,label:field == 9 ? b.label+"x" : b.label)
                let nonce = field == 10 ? UUID() : key.nonce
                attempt.receiveAccessOutcome(.init(key:.init(binding:foreign,context:c,nonce:nonce),progress:.nativeStartReturned,disposition:.appOwnedRetired))
            }
            XCTAssertNil(r.controller.applicationAccessOutcome); XCTAssertEqual(backend.stops,0); XCTAssertEqual(r.factories,1)
            guard await r.accessDisposition(self,backend) else { return }
            let cached = try XCTUnwrap(r.controller.applicationAccessOutcome), outcome = cached.outcome
            XCTAssertEqual(cached.consent,attempt.consent)
            XCTAssertEqual(outcome,backend.accessOutcome); XCTAssertEqual(outcome.permission,.unknown)
            XCTAssertEqual(outcome.disposition,unknown ? .heldOrUnknownCleanup : .appOwnedRetired)
            attempt.receiveAccessOutcome(outcome); backend.replayAccess(outcome)
            XCTAssertEqual(r.controller.applicationAccessOutcome,cached); XCTAssertEqual(r.factories,1)
            XCTAssertFalse(backend.didComplete); XCTAssertFalse(r.controller.acceptSourceChoice(.microphone))
            r.allowSettingsEvent = true; r.controller.savedConfigurationChanged(); r.allowSettingsEvent = false
            XCTAssertEqual(r.factories,1); XCTAssertNil(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
            if unknown {
                XCTAssertEqual(r.controller.applicationState,.heldOrUnavailable); XCTAssertNil(backend.completionObserver)
                r.controller.reserveShutdown(); r.controller.releaseRestart(); XCTAssertFalse(r.controller.restartReady())
                HubApplicationFailureResources.retain(r) // no observer/final join for unknown task
            } else {
                guard await r.accessFinish(self,backend) else { return }
                attempt.receiveAccessOutcome(outcome); XCTAssertEqual(r.factories,1)
                r.controller.openPage(); guard await r.state(self,{$0.state == .stopped && !$0.busy}) else { return }
                attempt.receiveAccessOutcome(outcome); XCTAssertNil(r.controller.applicationAccessOutcome)
                guard await r.accessDetach(self) else { return }
            }
        }
        let r = try HubApplicationRig(); defer { r.release() }
        r.notStarted = true; r.accessFalsePreActual = true; r.rawPreActualEvidence = true
        guard await r.accessOpen(self) else { return }
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        let challenge = try XCTUnwrap(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
        r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true,purpose:.audioAccessAttemptContract)
        guard await r.drain(self) else { return }
        XCTAssertNil(r.controller.applicationAccessOutcome); XCTAssertEqual(r.controller.applicationState,.refusedBeforeStart)
        XCTAssertNil(r.backends.first?.task); XCTAssertEqual(r.factories,1)
        guard await r.accessDetach(self) else { return }
    }
}

@MainActor extension MeetingHubController {
    func startConsentedRecording() {
        startAndSave()
        if let pending = recordingChallenge { confirmRecordingStart(id:pending.id,affirmed:true) }
    }
}
