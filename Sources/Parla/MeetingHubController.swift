import Combine
import Foundation
import ParlaCore

/// App and tests call this same binder. Construction/binding have no service queries.
@MainActor final class MeetingHubController: ObservableObject {
    enum Permission: Equatable { case authorized, undetermined, denied }
    enum SourceChoice: Equatable {
        case microphone
        case selectedApplication(ApplicationSnapshot)
    }
    struct ApplicationSnapshot: Equatable {
        let selectionID: UUID, revision: UUID
        let pid: Int32, launchNanoseconds: Int64
        let bundleID: String, bundlePath: String, executablePath: String, label: String
        private static func text(_ value: String, cap: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= cap && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        var valid: Bool {
            pid > 0 && launchNanoseconds > 0 && Self.text(bundleID,cap:256) && Self.text(label,cap:128) &&
            Self.text(bundlePath,cap:4_096) && Self.text(executablePath,cap:4_096) &&
            bundlePath.hasPrefix("/") && executablePath.hasPrefix("/")
        }
        // Swift String equality normalizes Unicode; source authority requires the original bytes.
        static func == (lhs: Self,rhs: Self) -> Bool {
            lhs.selectionID == rhs.selectionID && lhs.revision == rhs.revision && lhs.pid == rhs.pid &&
            lhs.launchNanoseconds == rhs.launchNanoseconds && lhs.bundleID.utf8.elementsEqual(rhs.bundleID.utf8) &&
            lhs.bundlePath.utf8.elementsEqual(rhs.bundlePath.utf8) && lhs.executablePath.utf8.elementsEqual(rhs.executablePath.utf8) &&
            lhs.label.utf8.elementsEqual(rhs.label.utf8)
        }
    }
    enum ApplicationCapability: Equatable { case unavailable, injectedContractOnly, production }
    enum ApplicationPurpose: Equatable {
        case injectedRecordingContract, audioAccessAttemptContract
        var mode: ApplicationAudioMode {
            switch self { case .injectedRecordingContract: return .retainedRecording; case .audioAccessAttemptContract: return .accessAttempt }
        }
    }
    struct StartChallenge: Equatable {
        let id: UUID, pageLifetime: UUID, ownerEpoch: UUID, sourceRevision: UUID
        let snapshot: ApplicationSnapshot, purpose: ApplicationPurpose
        fileprivate init(pageLifetime: UUID,ownerEpoch: UUID,sourceRevision: UUID,snapshot: ApplicationSnapshot,purpose: ApplicationPurpose) {
            id = UUID(); self.pageLifetime = pageLifetime; self.ownerEpoch = ownerEpoch
            self.sourceRevision = sourceRevision; self.snapshot = snapshot; self.purpose = purpose
        }
    }
    struct ApplicationStartConsent: Equatable {
        let challenge: StartChallenge, startIntent: UUID, session: UUID, source: UUID, captureEpoch: UUID
        let sourceGeneration: UInt64
        fileprivate init(challenge: StartChallenge,intent: UUID) {
            self.challenge = challenge; startIntent = intent; session = UUID(); source = UUID(); captureEpoch = UUID(); sourceGeneration = 1
        }
    }
    /// One cached observation binds Core's key to the complete consumed app authority.
    struct ApplicationAccessObservation: Equatable {
        let consent: ApplicationStartConsent, outcome: ApplicationAudioAccessOutcome
    }
    struct ApplicationAttempt {
        let consent: ApplicationStartConsent, owner: UUID, segment: UUID, nonce: UUID
        let receiveAccessOutcome: @MainActor (ApplicationAudioAccessOutcome) -> Void
        var mode: ApplicationAudioMode { consent.challenge.purpose.mode }
        var binding: SelectedApplicationBinding {
            let s = consent.challenge.snapshot
            return .init(selection:s.selectionID,source:consent.source,sourceGeneration:consent.sourceGeneration,captureEpoch:consent.captureEpoch,
                pid:s.pid,launchNanoseconds:s.launchNanoseconds,bundleID:s.bundleID,bundlePath:s.bundlePath,executablePath:s.executablePath,label:s.label)
        }
    }
    enum ApplicationFactoryResult { case unavailable, injected(MeetingSessionOwner.SingleSourceStreamPort) }
    // Cached contract observations only. Neither .actual nor owner.recording proves OS permission.
    enum ApplicationState: Equatable {
        case unavailable, needsConsent, refusedBeforeStart, injectedRecording, actualAttemptOwned, retiring, retiredPermissionUnknown, heldOrUnavailable
    }
    struct Dependencies {
        let captureCapability: Bool
        let makeStore: () -> MeetingSessionStore
        let microphone: (AudioRecorder.MeetingInput) -> MeetingSessionOwner.MicrophoneStreamPort
        let resolveInput: (String?) throws -> AudioRecorder.MeetingInput
        let authorization: () -> Permission
        let requestAccess: (@escaping (Bool) -> Void) -> Void
        let openPrivacy: () -> Void
        let settings: () throws -> Settings
        let settingsObject: SettingsStore
        let selectionEpoch: () -> UUID
        let enqueue: MeetingRecognitionExecution.Enqueue
        let diagnostics: DiagnosticStore
        let security: () -> Bool, copy: (String) -> Void
        let wall: () throws -> Int64
        let applicationCapability: ApplicationCapability
        let application: (ApplicationAttempt) -> ApplicationFactoryResult
        init(captureCapability: Bool,makeStore: @escaping () -> MeetingSessionStore,
            microphone: @escaping (AudioRecorder.MeetingInput) -> MeetingSessionOwner.MicrophoneStreamPort,
            resolveInput: @escaping (String?) throws -> AudioRecorder.MeetingInput,authorization: @escaping () -> Permission,
            requestAccess: @escaping (@escaping (Bool) -> Void) -> Void,openPrivacy: @escaping () -> Void,
            settings: @escaping () throws -> Settings,settingsObject: SettingsStore,selectionEpoch: @escaping () -> UUID,
            enqueue: @escaping MeetingRecognitionExecution.Enqueue,diagnostics: DiagnosticStore,
            security: @escaping () -> Bool,copy: @escaping (String) -> Void,wall: @escaping () throws -> Int64,
            applicationCapability: ApplicationCapability = .unavailable,
            application: @escaping (ApplicationAttempt) -> ApplicationFactoryResult = { _ in .unavailable }) {
            self.captureCapability = captureCapability; self.makeStore = makeStore; self.microphone = microphone
            self.resolveInput = resolveInput; self.authorization = authorization; self.requestAccess = requestAccess; self.openPrivacy = openPrivacy
            self.settings = settings; self.settingsObject = settingsObject; self.selectionEpoch = selectionEpoch; self.enqueue = enqueue
            self.diagnostics = diagnostics; self.security = security; self.copy = copy; self.wall = wall
            self.applicationCapability = applicationCapability; self.application = application
        }
    }
    struct RecordingChallenge: Identifiable {
        let id = UUID(), page: UUID, epoch: UUID, revision: UUID
        let source: SourceChoice
    }
    @Published private(set) var recordingChallenge: RecordingChallenge?
    @Published private(set) var applications: [ApplicationSnapshot] = []
    var discoverApplications: () -> [ApplicationSnapshot] = { [] }
    var openApplicationPrivacy: () -> Void = {}
    func refreshApplications() {
        guard admits,idle,activeCapture == nil else { return }
        applications = discoverApplications().filter(\.valid)
        if case .selectedApplication(let selected) = sourceChoice,!applications.contains(selected) { _ = acceptSourceChoice(.microphone) }
    }
    private enum Kind: Hashable { case metadata, start, stop, transcription, text, delete, expiry, keep }
    private struct Work { let id: UUID, task: Task<Void,Never> }
    private struct Retirement: Equatable { let reservation: UUID, epoch: UUID, success: Bool }
    @Published private(set) var model = HubMeetingModel()
    private var dependencies: Dependencies?, owner: MeetingSessionOwner?, ownerEpoch = UUID()
    private let recognition = MeetingRecognitionExecution()
    private var configurationObserver: NSObjectProtocol?
    private var work: [Kind:Work] = [:]
    private var page = false, pageIntent = UUID(), startIntent: UUID?, batch: MeetingRecognitionExecution.Authority?
    @Published private(set) var sourceChoice = SourceChoice.microphone
    @Published private(set) var applicationState = ApplicationState.unavailable
    @Published private(set) var applicationAccessOutcome: ApplicationAccessObservation?
    private var pageLifetime = UUID(), sourceRevision = UUID(), challenge: StartChallenge?
    private var frozenInput: AudioRecorder.MeetingInput?
    private final class ActiveCapture {
        let intent: UUID, ownerEpoch: UUID, pageLifetime: UUID, sourceRevision: UUID
        let session: UUID, segment: UUID, epoch: UUID, selection: MeetingSession.Selection
        let consent: ApplicationStartConsent?, port: MeetingSessionOwner.SingleSourceStreamPort
        var microphone: (selection: MeetingSession.Selection,segment: UUID,port: MeetingSessionOwner.SingleSourceStreamPort)?
        var actual: Task<Void,Never>?
        var accessKey: ApplicationAudioAccessKey?, pendingAccessOutcome: ApplicationAudioAccessOutcome?
        var acceptedAccessOutcome = false
        let nonce: UUID
        init(intent: UUID,ownerEpoch: UUID,pageLifetime: UUID,sourceRevision: UUID,session: UUID,segment: UUID,epoch: UUID,
             selection: MeetingSession.Selection,consent: ApplicationStartConsent?,port: MeetingSessionOwner.SingleSourceStreamPort,nonce: UUID = UUID()) {
            self.intent = intent; self.ownerEpoch = ownerEpoch; self.pageLifetime = pageLifetime; self.sourceRevision = sourceRevision
            self.session = session; self.segment = segment; self.epoch = epoch; self.selection = selection; self.consent = consent; self.port = port; self.nonce = nonce
        }
        func matches(_ selection: MeetingSession.Selection) -> Bool {
            self.selection.instance == selection.instance && self.selection.kind == selection.kind &&
            self.selection.generation == selection.generation && self.selection.label.utf8.elementsEqual(selection.label.utf8)
        }
    }
    private var activeCapture: ActiveCapture?
    private var permission: (id: UUID,intent: UUID,page: UUID)?, permissionWaiters: [CheckedContinuation<Void,Never>] = []
    private var output: UUID?, protection: UUID?, quarantine = false
    private var verifiedText: MeetingSessionOwner.VerifiedText?
    private var deadline: (id: UUID,session: UUID,task: Task<Void,Never>)?
    private var reservation: UUID?, lifecycleDriver: (id: UUID,epoch: UUID,task: Task<Retirement,Never>)?, retirement: Retirement?
    private var appleRevision = UUID(), parakeetRevision = UUID(), whisperRevision: UUID?
    private var appleReady = false, appleLocale: String?, appleRefusal: AppleSpeechRefusal?
    private var parakeetReady = false, parakeetRefusal: ParakeetInstallationRefusal?
    private var lastSavedConfiguration: AudioImportOwner.Configuration?
    private var frozenConfiguration: AudioImportOwner.Configuration?
    func bind(_ dependencies: Dependencies) {
        guard self.dependencies == nil else { return }
        self.dependencies = dependencies
        recognition.bind(enqueue:dependencies.enqueue,diagnostics:dependencies.diagnostics)
        model.captureAvailable = dependencies.captureCapability
        configurationObserver = NotificationCenter.default.addObserver(forName:SettingsStore.configurationDidChange,object:dependencies.settingsObject,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savedConfigurationChanged() }
        }
    }
    /// Only completion/reply control flow runs after the exact resource task returns.
    /// This observer owns no store, capture, callback, output or permission resource.
    private func launch(_ kind: Kind,_ action: @escaping () async -> Void) {
        guard work[kind] == nil else { return }
        let id = UUID(), task = Task { await action() }
        work[kind] = .init(id:id,task:task)
        Task { [weak self] in
            await task.value
            guard let self,self.work[kind]?.id == id else { return }
            self.work.removeValue(forKey:kind); self.publish()
            if kind == .expiry || kind == .transcription { self.armExpiry() }
        }
    }
    private func ensureOwner(explicitReentry: Bool = false) throws -> MeetingSessionOwner {
        guard !quarantine,let d = dependencies else { throw MeetingSession.Failure.unavailable }
        if let owner,owner.state != .detached { return owner }
        if owner != nil {
            guard explicitReentry,reservation == nil,lifecycleDriver == nil,retirement?.success == true,work.isEmpty,permission == nil,output == nil else { throw MeetingSession.Failure.held }
            self.owner = nil; ownerEpoch = UUID(); retirement = nil; applicationAccessOutcome = nil
        }
        let stream = MeetingSessionOwner.SingleSourceStreamPort(validate:{ [weak self] selection in
            guard let self,let active = self.activeCapture,self.captureCurrent(active) else { return false }
            let port: MeetingSessionOwner.SingleSourceStreamPort
            if active.matches(selection) { port = active.port }
            else if let mic = active.microphone,mic.selection == selection { port = mic.port }
            else { return false }
            let valid = await port.validate(selection)
            return valid && self.activeCapture === active && self.captureCurrent(active)
        },start:{ [weak self] selection,ingress in
            guard let self,let active = self.activeCapture,self.captureCurrent(active),
                  ingress.context.session == active.session,ingress.context.source == selection.instance,
                  ingress.context.sourceGeneration == selection.generation,ingress.context.epoch == active.epoch,
                  ingress.context.ownerGeneration > 0 else { return .init(source:selection.instance,exit:.notStarted) }
            if let mic = active.microphone,mic.selection == selection,ingress.context.segment == mic.segment {
                return mic.port.start(selection,ingress)
            }
            guard active.matches(selection),ingress.context.segment == active.segment else { return .init(source:selection.instance,exit:.notStarted) }
            // Register the exact context BEFORE an injected start may synchronously deliver evidence.
            if let consent = active.consent,consent.challenge.purpose == .audioAccessAttemptContract {
                let s = consent.challenge.snapshot
                let binding = SelectedApplicationBinding(selection:s.selectionID,source:consent.source,sourceGeneration:consent.sourceGeneration,
                    captureEpoch:consent.captureEpoch,pid:s.pid,launchNanoseconds:s.launchNanoseconds,bundleID:s.bundleID,
                    bundlePath:s.bundlePath,executablePath:s.executablePath,label:s.label)
                active.accessKey = .init(binding:binding,context:ingress.context,nonce:active.nonce)
            }
            let producer = active.port.start(selection,ingress)
            switch producer.exit {
            case .actual(let task):
                active.actual = task // retain the ORIGINAL task before accepting the buffered value
                if producer.source != selection.instance { active.accessKey = nil; active.pendingAccessOutcome = nil }
                if let consent = active.consent {
                    self.applicationState = producer.source != selection.instance ? .heldOrUnavailable : self.captureCurrent(active) ?
                        (consent.challenge.purpose == .audioAccessAttemptContract ? .actualAttemptOwned : .injectedRecording) : .retiring
                    let early = active.pendingAccessOutcome; active.pendingAccessOutcome = nil
                    if let early,producer.source == selection.instance { self.receiveAccessOutcome(early,consent:consent,nonce:active.nonce) }
                }
            case .notStarted:
                active.pendingAccessOutcome = nil; active.accessKey = nil // never a native outcome
            }
            return producer
        },requestStop:{ [weak self] in
            // Stop uses the exact retained port even after consent/start authority has been consumed.
            guard let active = self?.activeCapture else { return }; await active.port.requestStop(); await active.microphone?.port.requestStop()
        })
        let value = MeetingSessionOwner(store:d.makeStore(),singleSource:stream,recognition:recognition.port,wallClock:d.wall,holdEpoch:1)
        value.onChange = { [weak self,weak value] snapshot in
            guard let self,self.owner === value else { return }
            if self.activeCapture?.consent != nil {
                if snapshot.state == .unavailable { self.applicationState = .heldOrUnavailable }
                else if self.applicationState != .heldOrUnavailable && (snapshot.state == .stopping || snapshot.state == .deleting || snapshot.state == .expired) { self.applicationState = .retiring }
            }
            self.publish(snapshot)
            if snapshot.state == .stopping,self.work[.stop] == nil { self.stopAndSave() }
        }
        owner = value; return value
    }
    private func captureCurrent(_ active: ActiveCapture) -> Bool {
        guard activeCapture === active,startCurrent(active.intent),ownerEpoch == active.ownerEpoch,
              pageLifetime == active.pageLifetime,sourceRevision == active.sourceRevision,let d = dependencies,d.captureCapability else { return false }
        if let consent = active.consent {
            return d.applicationCapability != .unavailable && applicationCurrent(consent.challenge) && (d.applicationCapability != .production || d.authorization() == .authorized)
        }
        return sourceChoice == .microphone && d.authorization() == .authorized
    }
    private func applicationCurrent(_ value: StartChallenge) -> Bool {
        admits && value.pageLifetime == pageLifetime && value.ownerEpoch == ownerEpoch && value.sourceRevision == sourceRevision &&
        sourceChoice == .selectedApplication(value.snapshot) && (dependencies?.applicationCapability != .production || value.purpose == .injectedRecordingContract)
    }
    private func revokeCaptureAuthority(newPage: Bool = false) {
        challenge = nil; recordingChallenge = nil; startIntent = nil
        if newPage { pageLifetime = UUID(); sourceRevision = UUID(); applicationAccessOutcome = nil }
        if activeCapture?.consent != nil,applicationState != .heldOrUnavailable { applicationState = .retiring }
    }
    private func captureRetired(_ value: MeetingSessionOwner) {
        guard owner === value,!value.snapshot.pendingStart,!value.snapshot.phaseActive,
              [.idle,.stopped,.detached].contains(value.state) else { return }
        if let active = activeCapture,active.consent != nil { applicationState = active.actual == nil ? .refusedBeforeStart : .retiredPermissionUnknown }
        activeCapture = nil
    }
    @discardableResult func acceptSourceChoice(_ choice: SourceChoice) -> Bool {
        guard activeCapture == nil,idle,reservation == nil,lifecycleDriver == nil,!quarantine,
              owner == nil || owner?.state == .idle || owner?.state == .stopped else { return false }
        if case .selectedApplication(let snapshot) = choice, !snapshot.valid { return false }
        guard choice != sourceChoice else { return true }
        revokeCaptureAuthority(); sourceRevision = UUID(); applicationAccessOutcome = nil; sourceChoice = choice
        if case .selectedApplication = choice,dependencies?.captureCapability == true,dependencies?.applicationCapability != .unavailable {
            applicationState = .needsConsent
        } else { applicationState = .unavailable }
        return true
    }
    func prepareApplicationStart(purpose: ApplicationPurpose = .injectedRecordingContract) -> StartChallenge? {
        challenge = nil
        guard admits,idle,activeCapture == nil,let d = dependencies,d.captureCapability,d.applicationCapability != .unavailable,
              let owner,owner.state == .idle,owner.metadata == nil,!owner.snapshot.pendingStart,!owner.snapshot.phaseActive,
              case .selectedApplication(let snapshot) = sourceChoice,snapshot.valid else { return nil }
        let value = StartChallenge(pageLifetime:pageLifetime,ownerEpoch:ownerEpoch,sourceRevision:sourceRevision,snapshot:snapshot,purpose:purpose)
        challenge = value; applicationState = .needsConsent; return value
    }
    func confirmApplicationStart(challengeID: UUID,affirmed: Bool,purpose: ApplicationPurpose = .injectedRecordingContract) {
        let pending = challenge; challenge = nil // every reply is single use, including denial and a wrong ID
        guard let pending else { return }
        guard affirmed,pending.id == challengeID,pending.purpose == purpose,applicationCurrent(pending),admits,idle,activeCapture == nil,
              let d = dependencies,d.captureCapability,d.applicationCapability != .unavailable,
              let value = owner,value.state == .idle,value.metadata == nil else { applicationState = .refusedBeforeStart; return }
        let intent = UUID(), frozen = ApplicationStartConsent(challenge:pending,intent:intent)
        let nonce = UUID()
        let attempt = ApplicationAttempt(consent:frozen,owner:UUID(),segment:UUID(),nonce:nonce,receiveAccessOutcome:{ [weak self] in
            self?.receiveAccessOutcome($0,consent:frozen,nonce:nonce)
        })
        applicationAccessOutcome = nil
        startIntent = intent
        launch(.start) { [weak self,value] in
            guard let self else { return }
            defer {
                if self.startIntent == intent { self.startIntent = nil }
                if self.activeCapture == nil && self.applicationState == .needsConsent { self.applicationState = .refusedBeforeStart }
                self.publish()
            }
            do {
                await self.settleOldDeadline(session:value.metadata?.session)
                guard self.startCurrent(intent),self.applicationCurrent(pending),self.owner === value else { return }
                try await value.openMetadata()
                guard self.startCurrent(intent),self.applicationCurrent(pending),self.owner === value,value.metadata == nil,
                      d.captureCapability,d.applicationCapability != .unavailable else { return }
                if d.applicationCapability == .production,!self.microphoneAuthorized(d,intent:intent) { return }
                let result = d.application(attempt)
                guard self.startCurrent(intent),self.applicationCurrent(pending),self.owner === value else { return }
                guard case .injected(let port) = result else { self.applicationState = .unavailable; return }
                let binding = attempt.binding
                let selection = MeetingSession.Selection(instance:binding.source,kind:.selectedApplication,label:binding.label,generation:binding.sourceGeneration)
                let active = ActiveCapture(intent:intent,ownerEpoch:self.ownerEpoch,pageLifetime:self.pageLifetime,sourceRevision:self.sourceRevision,
                    session:frozen.session,segment:attempt.segment,epoch:binding.captureEpoch,selection:selection,consent:frozen,port:port,nonce:nonce)
                if d.applicationCapability == .production {
                    let input = try d.resolveInput(try d.settings().inputDeviceUID)
                    active.microphone = (.init(instance:UUID(),kind:.microphone,label:input.label,generation:1),UUID(),d.microphone(input))
                }
                self.activeCapture = active
                guard self.captureCurrent(active) else { self.captureRetired(value); return }
                let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:binding.captureEpoch,mapping:.unknown)
                if let mic = active.microphone {
                    try await value.startSources(owner:attempt.owner,session:frozen.session,selections:[mic.selection,selection],segments:[
                        .init(id:mic.segment,track:0,generation:1,timing:timing,canonicalStart:0),
                        .init(id:attempt.segment,track:1,generation:binding.sourceGeneration,timing:timing,canonicalStart:0)])
                } else {
                    try await value.startSingleSource(owner:attempt.owner,session:frozen.session,selection:selection,
                        segment:.init(id:attempt.segment,track:0,generation:binding.sourceGeneration,timing:timing,canonicalStart:0))
                }
                guard self.captureCurrent(active) else { value.requestStopSaving(); self.stopAndSave(); return }
                self.armExpiry()
            } catch {
                self.model.message = "Recording couldn't start. Check Microphone and System Audio Recording access."
                self.applicationState = self.activeCapture?.actual == nil && value.state == .idle ? .refusedBeforeStart : .heldOrUnavailable
                self.captureRetired(value)
                if self.activeCapture != nil { self.stopAndSave() }
            }
        }
    }
    /// Bounded synchronous sink. It never awaits the source/owner/writer, nor starts capture.
    private func receiveAccessOutcome(_ outcome: ApplicationAudioAccessOutcome,consent: ApplicationStartConsent,nonce: UUID) {
        guard let active = activeCapture,active.consent == consent,active.intent == consent.startIntent,
              consent.challenge.purpose == .audioAccessAttemptContract,active.nonce == nonce,
              ownerEpoch == active.ownerEpoch,pageLifetime == active.pageLifetime,sourceRevision == active.sourceRevision,
              applicationCurrent(consent.challenge),!active.acceptedAccessOutcome,outcome.key == active.accessKey else { return }
        guard active.actual != nil else {
            if active.pendingAccessOutcome == nil { active.pendingAccessOutcome = outcome }
            return
        }
        active.acceptedAccessOutcome = true
        applicationAccessOutcome = .init(consent:consent,outcome:outcome)
        if outcome.disposition == .heldOrUnknownCleanup { applicationState = .heldOrUnavailable }
        // work.start is registered before the factory. Stop waits that admission task;
        // the original producer NEVER awaits Stop, including very early synchronous fake delivery.
        stopAndSave()
    }
    /// Only exact injected-run loss evidence fences that run; stale receipts cannot affect a successor.
    func applicationSourceInvalidated(_ consent: ApplicationStartConsent) {
        guard activeCapture?.consent == consent else { return }
        revokeCaptureAuthority(); sourceRevision = UUID(); applicationAccessOutcome = nil; owner?.requestStopSaving(); stopAndSave()
    }
    private var admits: Bool { page && reservation == nil && lifecycleDriver == nil && !quarantine && protection == nil && output == nil }
    private var idle: Bool { work.isEmpty && permission == nil }
    func openPage() {
        revokeCaptureAuthority(newPage:true)
        if activeCapture != nil { owner?.requestStopSaving(); stopAndSave() }
        page = true; pageIntent = UUID(); model.message = nil
        guard reservation == nil,lifecycleDriver == nil,work[.metadata] == nil else { return }
        do {
            let value = try ensureOwner(explicitReentry:true)
            launch(.metadata) { [weak self,value] in
                if let timer = self?.deadline, timer.session != value.metadata?.session { timer.task.cancel(); await timer.task.value; if self?.deadline?.id == timer.id { self?.deadline = nil } }
                do { try await value.openMetadata(); try await value.evaluateExpiry(deleteID:UUID()); try self?.recognition.prime(value.metadata?.provenance ?? []); self?.armExpiry() }
                catch { self?.storageFailure() }
            }
        } catch { storageFailure() }
    }
    /// Startup maintenance loads only saved metadata; it never grants capture authority.
    func maintainSavedMeeting() {
        guard work[.metadata] == nil,reservation == nil else { return }
        do {
            let value = try ensureOwner()
            launch(.metadata) { [weak self,value] in
                do { try await value.openMetadata(); try await value.evaluateExpiry(deleteID:UUID()); self?.armExpiry() }
                catch { self?.storageFailure() }
            }
        } catch { storageFailure() }
    }
    func retryOpen() { openPage() }
    func leavePage() { page = false; pageIntent = UUID(); revokeCaptureAuthority(newPage:true); verifiedText = nil; owner?.revokeTextReads(); cancelTranscription(); stopAndSave() }
    func windowClosed() { leavePage() }
    /// Focus loss deliberately has no recording side effect.
    func focusChanged() {}
    func chooseMicrophone() { model.message = "Choose a microphone in General. It applies to the next recording." }
    func openMicrophoneSettings() { dependencies?.openPrivacy() }
    func startAndSave() {
        guard admits,idle,activeCapture == nil,dependencies?.captureCapability == true,owner?.metadata == nil else { return }
        recordingChallenge = .init(page:pageLifetime,epoch:ownerEpoch,revision:sourceRevision,source:sourceChoice)
    }
    func confirmRecordingStart(id: UUID,affirmed: Bool) {
        let pending = recordingChallenge; recordingChallenge = nil
        guard let pending,affirmed,pending.id == id,pending.page == pageLifetime,pending.epoch == ownerEpoch,
              pending.revision == sourceRevision,pending.source == sourceChoice,admits,idle else { return }
        switch sourceChoice {
        case .microphone: startMicrophoneConsented()
        case .selectedApplication:
            guard let challenge = prepareApplicationStart() else { return }
            confirmApplicationStart(challengeID:challenge.id,affirmed:true)
        }
    }
    /// Permission grants never resume recording; a fresh explicit Start and acknowledgment are required.
    private func microphoneAuthorized(_ d: Dependencies,intent: UUID) -> Bool {
        switch d.authorization() {
        case .authorized: return true
        case .denied:
            model.message = "Microphone access is off. Allow it in System Settings, then press Start."; return false
        case .undetermined:
            let id = UUID(), lifetime = pageLifetime
            permission = (id,intent,lifetime)
            d.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self,self.permission?.id == id else { return }
                    if self.pageLifetime == lifetime,self.page,self.reservation == nil {
                        self.model.message = granted ? "Microphone access is on. Press Start recording." : "Microphone access is off. Allow it in System Settings, then press Start."
                    }
                    self.permission = nil
                    let pending = self.permissionWaiters; self.permissionWaiters.removeAll(); pending.forEach { $0.resume() }; self.publish()
                }
            }
            return false
        }
    }
    private func startMicrophoneConsented() {
        guard sourceChoice == .microphone,activeCapture == nil,admits,idle,let d = dependencies else { return }
        // Milestone gate precedes authorization, settings and source resolution.
        guard d.captureCapability else { model.message = "Microphone recording is unavailable in this version. Saved meetings remain available."; return }
        guard owner?.metadata == nil else { model.message = "Delete the saved meeting before recording another."; return }
        model.message = nil
        let intent = UUID(); startIntent = intent // synchronous pending fence before the first await
        launch(.start) { [weak self] in
            guard let self else { return }
            defer { if self.startIntent == intent { self.startIntent = nil }; self.publish() }
            do {
                let value = try self.ensureOwner(explicitReentry:true)
                await self.settleOldDeadline(session:value.metadata?.session)
                guard self.startCurrent(intent) else { return }
                try await value.openMetadata()
                guard self.startCurrent(intent),value.metadata == nil else { return }
                guard self.microphoneAuthorized(d,intent:intent) else { return }
                let saved = try d.settings(), input = try d.resolveInput(saved.inputDeviceUID)
                guard self.startCurrent(intent),d.authorization() == .authorized else { return }
                self.frozenInput = input; let port = d.microphone(input)
                let source = UUID(), epoch = UUID(), selection = MeetingSession.Selection(instance:source,kind:.microphone,label:input.label,generation:1)
                let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.unknown)
                let session = UUID(), segment = UUID()
                let active = ActiveCapture(intent:intent,ownerEpoch:self.ownerEpoch,pageLifetime:self.pageLifetime,sourceRevision:self.sourceRevision,
                    session:session,segment:segment,epoch:epoch,selection:selection,consent:nil,port:port)
                self.activeCapture = active
                try await value.startMicrophone(owner:UUID(),session:session,selection:selection,segment:.init(id:segment,track:0,generation:1,timing:timing,canonicalStart:0))
                guard self.captureCurrent(active) else { value.requestStopSaving(); self.stopAndSave(); return }
                self.armExpiry()
            } catch {
                self.model.message = "Recording couldn't start."
                if let value = self.owner { self.captureRetired(value) }
                if self.activeCapture != nil { self.stopAndSave() }
            }
        }
    }
    private func startCurrent(_ intent: UUID) -> Bool { admits && startIntent == intent }
    func stopAndSave() {
        if owner?.state == .recording || owner?.state == .starting { model.message = nil }
        revokeCaptureAuthority(); owner?.requestStopSaving()
        guard work[.stop] == nil else { return }
        let start = work[.start]?.task
        launch(.stop) { [weak self] in
            if let start { await start.value }
            do {
                if let value = self?.owner { try await value.finishStopSaving(); self?.captureRetired(value) }
                await self?.settleOldDeadline(session:nil)
                self?.armExpiry()
            } catch { if self?.activeCapture?.consent != nil { self?.applicationState = .heldOrUnavailable }; self?.storageFailure() }
        }
    }
    func transcribeRemaining() {
        guard admits,idle,let d = dependencies,let value = owner,let metadata = value.metadata,value.state == .stopped,
              !metadata.expired,!metadata.deleting,!metadata.unavailable else { return }
        model.message = nil
        let authority = MeetingRecognitionExecution.Authority(); batch = authority
        let intent = UUID(), epoch = ownerEpoch
        launch(.transcription) { [weak self,value] in
            guard let self else { return }
            do {
                try await value.evaluateExpiry(deleteID:UUID())
                let config = AudioImportOwner.Configuration(try d.settings()); self.adoptConfiguration(config); self.frozenConfiguration = config
                let selection = d.selectionEpoch(), preparation = try self.preparationEpoch(config.request)
                let remaining = metadata.chunks.filter { $0.stage == .sealed && !$0.audioRemoved && $0.accepted == nil }
                guard !remaining.isEmpty else { self.model.message = "There is not enough saved audio to transcribe."; return }
                for chunk in remaining {
                    guard self.admits,authority.current,self.ownerEpoch == epoch else { throw CancellationError() }
                    try self.recognition.prime(value.metadata?.provenance ?? [])
                    let context = MeetingRecognitionExecution.Context(session:metadata.session,chunk:chunk.id,generation:chunk.generation,intent:intent,
                        configuration:config,selectionEpoch:selection,preparationEpoch:preparation,authority:authority,authorize:{[weak self] in
                            guard let self,self.admits,authority.current,self.ownerEpoch == epoch,
                                  (try? AudioImportOwner.Configuration(d.settings())) == config,d.selectionEpoch() == selection,
                                  (try? self.preparationEpoch(config.request)) == preparation else { return false }; return true
                        })
                    let requested = try self.recognition.prepare(context)
                    do { try await value.transcribe(chunk:chunk.id,requested:requested) }
                    catch { await self.recognition.settled(); throw error }
                    await self.recognition.settled()
                }
            } catch { self.model.message = "Some saved audio has no text yet. Previously saved text is kept." }
            if self.batch === authority { self.batch = nil; self.frozenConfiguration = nil }
            await self.settleOldDeadline(session:nil); self.armExpiry()
        }
    }
    func cancelTranscription() { batch?.revoke(); recognition.requestCancel(); owner?.cancelTranscription() }
    func savedConfigurationChanged() {
        // Output review changes independently of the frozen microphone run.
        pageIntent = UUID(); owner?.revokeTextReads()
        guard let dependencies,let current = try? AudioImportOwner.Configuration(dependencies.settings()) else {
            cancelTranscription(); revokePreparation(.appleSpeech); revokePreparation(.parakeet); revokePreparation(.whisper); return
        }
        adoptConfiguration(current)
        if let frozenConfiguration,current != frozenConfiguration { cancelTranscription() }
    }
    private func adoptConfiguration(_ current: AudioImportOwner.Configuration) {
        defer { lastSavedConfiguration = current }
        guard let old = lastSavedConfiguration,old != current else { return }
        revokePreparation(old.request.selection.engine)
        if old.request.selection.engine != current.request.selection.engine { revokePreparation(current.request.selection.engine) }
    }
    func revokePreparation(_ engine: RecognitionEngine) {
        switch engine { case .appleSpeech: appleReady = false; appleRevision = UUID(); case .parakeet: parakeetReady = false; parakeetRevision = UUID(); case .whisper: whisperRevision = nil; case .invalid: break }
        if frozenConfiguration?.request.selection.engine == engine { cancelTranscription() }
    }
    func applePreparationChanged(_ emitted: AppleSpeechSnapshot) {
        let ready = emitted.refusal == nil && (emitted.phase == .ready || (appleReady && emitted.locale == appleLocale && (emitted.phase == .waiting || emitted.phase == .checking)))
        if ready != appleReady || emitted.locale != appleLocale || emitted.refusal != appleRefusal { appleRevision = UUID(); if frozenConfiguration?.request.selection.engine == .appleSpeech { cancelTranscription() } }
        appleReady = ready; appleLocale = emitted.locale; appleRefusal = emitted.refusal
    }
    func parakeetPreparationChanged(_ emitted: ParakeetSnapshot) {
        let ready = emitted.phase == .ready && emitted.refusal == nil
        if ready != parakeetReady || emitted.refusal != parakeetRefusal { parakeetRevision = UUID(); if frozenConfiguration?.request.selection.engine == .parakeet { cancelTranscription() } }
        parakeetReady = ready; parakeetRefusal = emitted.refusal
    }
    func whisperPreparationChanged(_ epoch: UUID?) {
        if whisperRevision != epoch { whisperRevision = epoch; if frozenConfiguration?.request.selection.engine == .whisper { cancelTranscription() } }
    }
    private func preparationEpoch(_ request: RecognitionRequest) throws -> UUID? {
        switch request.selection {
        case .whisper: return whisperRevision
        case .appleSpeech(let locale): guard appleReady,appleLocale == locale,appleRefusal == nil else { throw MeetingSession.Failure.unavailable }; return appleRevision
        case .parakeet: guard parakeetReady,parakeetRefusal == nil else { throw MeetingSession.Failure.unavailable }; return parakeetRevision
        case .invalid: throw MeetingSession.Failure.unavailable
        }
    }
    func openSavedText() { readText(copy:false) }
    func copyText() { readText(copy:true) }
    private func readText(copy: Bool) {
        guard admits,idle,let value = owner,let d = dependencies,d.security() else { return }
        let intent = pageIntent,epoch = ownerEpoch,authority = MeetingRecognitionExecution.Authority(),outputID = copy ? UUID() : nil
        if let outputID { output = outputID } // output operation owns the entire explicit read/copy action
        launch(.text) { [weak self,value] in
            guard let self else { return }
            defer { if let outputID,self.output == outputID { self.output = nil } }
            do {
                let text = try await value.openAcceptedText(authorized:authority.currentClosure)
                guard self.page,self.reservation == nil,self.protection == nil,!self.quarantine,self.output == outputID,
                      self.pageIntent == intent,self.ownerEpoch == epoch,d.security() else { throw CancellationError() }
                self.verifiedText = text
                if copy {
                    let token = try value.beginExplicitOutput(text)
                    do { guard self.page,self.reservation == nil,self.protection == nil,!self.quarantine,d.security(),self.pageIntent == intent else { throw CancellationError() }; d.copy(text.text) }
                    catch { try value.endExplicitOutput(token); throw error }
                    try value.endExplicitOutput(token)
                }
            } catch { self.model.message = "Couldn't open the transcript. Try again in a moment." }
        }
    }
    func deleteConfirmed(session: UUID,intent: UUID) {
        guard admits,owner?.metadata?.session == session,pageIntent == intent,work[.delete] == nil else { return }
        revokeCaptureAuthority(); cancelTranscription(); verifiedText = nil; owner?.revokeTextReads(); cancelDeadline()
        // Admission must settle before intent; producer/consumer joins stay INSIDE owner.delete,
        // after its durable intent. Do not wait a normal Stop before writing delete intent.
        let pending = [work[.start]?.task,work[.metadata]?.task].compactMap { $0 }
        launch(.delete) { [weak self] in
            for task in pending { await task.value }
            do { if let value = self?.owner { try await value.delete(id:UUID()); self?.captureRetired(value) }; await self?.settleOldDeadline(session:nil); self?.model.message = "Saved meeting deleted." }
            catch { self?.model.message = "Couldn't finish deleting. Try again." }
        }
    }
    var recoveryDeleteConfirmation: UUID? { owner?.canDeleteUnavailableMeetingData == true ? pageIntent : nil }
    func deleteAllMeetingDataConfirmed(intent: UUID) {
        guard admits,idle,pageIntent == intent,let value = owner,value.canDeleteUnavailableMeetingData else { return }
        launch(.delete) { [weak self,value] in
            do { try await value.deleteAllUnavailableMeetingData(); self?.model.message = "Saved meeting deleted." }
            catch { self?.model.message = "Couldn't finish deleting. Try again." }
        }
    }
    func keepMeeting(_ keep: Bool) {
        guard admits,idle,let value = owner else { return }
        verifiedText = nil
        launch(.keep) { [weak self,value] in
            do {
                try await value.setKeep(keep)
                await self?.settleOldDeadline(session:nil)
                try await value.evaluateExpiry(deleteID:UUID()); self?.armExpiry()
            } catch { self?.storageFailure() }
        }
    }
    var deleteConfirmation: (session: UUID,intent: UUID)? { owner?.metadata.map { ($0.session,pageIntent) } }
    private func cancelDeadline() { deadline?.task.cancel() }
    private func settleOldDeadline(session: UUID?) async {
        guard let old = deadline,old.session != session else { return }
        old.task.cancel(); await old.task.value
        if deadline?.id == old.id { deadline = nil }
    }
    private func armExpiry() {
        guard let metadata = owner?.metadata,!metadata.deleting,!metadata.kept,work[.transcription] == nil,let d = dependencies,reservation == nil,lifecycleDriver == nil else { return }
        if deadline?.session == metadata.session { return }
        // Never replace a live deadline. Its actual exit is joined first by the metadata/stop action.
        guard deadline == nil else { return }
        do {
            let now = try d.wall(), delta = min(metadata.expires,metadata.rawExpires ?? metadata.expires).subtractingReportingOverflow(now), id = UUID()
            guard now >= metadata.created,!delta.overflow else { throw MeetingSession.Failure.clock }
            let remaining = max(0,delta.partialValue)
            let task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds:UInt64(remaining)) } catch { return }
                guard let self,self.deadline?.id == id,self.reservation == nil,self.lifecycleDriver == nil else { return }
                self.evaluateExpiry()
            }
            deadline = (id,metadata.session,task)
        } catch { storageFailure() }
    }
    private func evaluateExpiry() {
        guard work[.expiry] == nil,let value = owner else { return }
        revokeCaptureAuthority(); cancelTranscription(); value.revokeTextReads()
        launch(.expiry) { [weak self,value] in
            do {
                try await value.evaluateExpiry(deleteID:UUID())
                if value.metadata == nil { self?.captureRetired(value) }
                self?.deadline = nil
            } catch { self?.storageFailure() }
        }
    }
    func withExportProtection<T>(validateDestination: (MeetingSessionStore.Protection) throws -> Void,perform: () throws -> T) throws -> T {
        guard reservation == nil,lifecycleDriver == nil,work.isEmpty,permission == nil,output == nil,protection == nil,!quarantine else { throw MeetingSession.Failure.held }
        let id = UUID(); protection = id // before inert owner/store selection and first clock/primitive
        defer { if owner?.protectionQuarantined == true { quarantine = true } else if protection == id { protection = nil } }
        let value: MeetingSessionOwner
        if let owner { value = owner }
        else { value = try ensureOwner() }
        return try value.withExportProtection(operation:id,authorized:{self.reservation == nil && self.protection == id},validateDestination:validateDestination,perform:perform)
    }
    func reserveShutdown() {
        guard reservation == nil,lifecycleDriver == nil else { return }; reservation = UUID(); retirement = nil
        revokeCaptureAuthority(newPage:true); pageIntent = UUID(); cancelTranscription(); owner?.revokeTextReads(); owner?.requestStopSaving(); owner?.reserveQuit(); cancelDeadline()
        _ = driver() // retain actual retirement before a synchronous participant can cancel intent
        publish()
    }
    func reserveRestart() -> Bool { guard reservation == nil,lifecycleDriver == nil,protection == nil,output == nil,!quarantine else { return false }; reserveShutdown(); return true }
    private func driver() -> (id: UUID,epoch: UUID,task: Task<Retirement,Never>)? {
        guard let reservation else { return nil }
        if let lifecycleDriver {
            guard lifecycleDriver.id == reservation,lifecycleDriver.epoch == ownerEpoch else { return nil }
            return lifecycleDriver
        }
        guard retirement?.reservation != reservation else { return nil }
        let id = reservation, epoch = ownerEpoch, current = owner, pending = work.values.map(\.task), timer = deadline?.task
        let task = Task { [self] () -> Retirement in
            for task in pending { await task.value }
            if let timer { await timer.value }
            if permission != nil { await withCheckedContinuation { permissionWaiters.append($0) } }
            guard !quarantine,protection == nil,output == nil else { return .init(reservation:id,epoch:epoch,success:false) }
            if let current {
                guard await current.beginShutdown() else { return .init(reservation:id,epoch:epoch,success:false) }
                do { try await current.committedDetach(); captureRetired(current) } catch { return .init(reservation:id,epoch:epoch,success:false) }
            }
            return .init(reservation:id,epoch:epoch,success:true)
        }
        let value = (id,epoch,task); lifecycleDriver = value
        Task { [weak self] in
            let result = await task.value
            self?.observeRetirement(result) // receipt only, after the resource driver's actual return
        }
        return value
    }
    private func observeRetirement(_ result: Retirement) {
        guard lifecycleDriver?.id == result.reservation,lifecycleDriver?.epoch == result.epoch else { return }
        lifecycleDriver = nil; deadline = nil
        if result.epoch == ownerEpoch {
            retirement = result
            if !result.success,activeCapture?.consent != nil { applicationState = .heldOrUnavailable }
        }
        publish()
    }
    func drainRestart() async -> Bool {
        guard let intent = reservation else { return false }
        let epoch = ownerEpoch
        if restartReady(intent:intent,epoch:epoch) { return true }
        guard let driver = driver(),driver.id == intent,driver.epoch == epoch else { return false }
        let result = await driver.task.value
        guard result.reservation == intent,result.epoch == epoch else { return false }
        observeRetirement(result) // idempotent with the independent receipt observer
        return restartReady(intent:intent,epoch:epoch)
    }
    private func restartReady(intent: UUID,epoch: UUID) -> Bool {
        guard reservation == intent,ownerEpoch == epoch,let retirement else { return false }
        return retirement.success && retirement.reservation == intent && retirement.epoch == epoch && lifecycleDriver == nil && permission == nil && protection == nil && output == nil && !quarantine
    }
    func restartReady() -> Bool {
        guard let reservation else { return false }
        return restartReady(intent:reservation,epoch:ownerEpoch)
    }
    func beginShutdown(_ reply: @escaping (Bool) -> Void) {
        reserveShutdown()
        guard let intent = reservation else { reply(false); return }
        let epoch = ownerEpoch
        Task { [weak self] in
            guard let self,self.reservation == intent,self.ownerEpoch == epoch else { reply(false); return }
            let result = await self.drainRestart()
            reply(result && self.restartReady(intent:intent,epoch:epoch))
        } // reply-only continuation outside resource driver, bound to its original intent
    }
    /// Test/application joins only registered actual tasks; callers bound their own wait.
    func drainActions() async {
        for _ in 0..<16 {
            let pending = work.values.map(\.task)
            if pending.isEmpty { return }
            for task in pending { await task.value }
            await Task.yield() // allow reply-only identity clearing; no resource work is detached here
        }
    }
    func releaseRestart() { reservation = nil; publish() } // no capture/ASR/output revival or bootstrap
    func cancelShutdown() { releaseRestart() }
    private func storageFailure() { model.message = "Couldn't open the saved meeting."; if owner?.protectionQuarantined == true { quarantine = true } }
    private func publish(_ snapshot: MeetingSessionOwner.Snapshot? = nil) {
        let snapshot = snapshot ?? owner?.snapshot
        model.captureOwned = activeCapture != nil
        model.recoveryDeleteAvailable = owner?.canDeleteUnavailableMeetingData == true
        model.state = snapshot?.state ?? .idle; model.metadata = snapshot?.metadata; model.busy = !work.isEmpty || permission != nil || reservation != nil || lifecycleDriver != nil
        if let active = activeCapture {
            model.source = active.microphone == nil ? active.selection.label : "Microphone + " + active.selection.label
        } else { model.source = snapshot?.metadata?.selections.map(\.label).joined(separator:" + ") ?? frozenInput?.label ?? "Saved microphone" }
        if let verifiedText,verifiedText.metadata == snapshot?.metadata { model.text = verifiedText.text } else { model.text = nil }
    }
}
extension MeetingRecognitionExecution.Authority {
    var currentClosure: @Sendable () -> Bool { { [self] in current } }
}
