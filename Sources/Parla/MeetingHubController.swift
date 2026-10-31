import Combine
import Foundation
import ParlaCore

/// App and tests call this same binder. Construction/binding have no service queries.
@MainActor final class MeetingHubController: ObservableObject {
    enum Permission: Equatable { case authorized, undetermined, denied }
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
    }
    private enum Kind: Hashable { case metadata, start, stop, transcription, text, delete, expiry }
    private struct Work { let id: UUID, task: Task<Void,Never> }
    private struct Retirement: Equatable { let reservation: UUID, epoch: UUID, success: Bool }
    @Published private(set) var model = HubMeetingModel()
    private var dependencies: Dependencies?, owner: MeetingSessionOwner?, ownerEpoch = UUID()
    private let recognition = MeetingRecognitionExecution()
    private var configurationObserver: NSObjectProtocol?
    private var work: [Kind:Work] = [:]
    private var page = false, pageIntent = UUID(), startIntent: UUID?, batch: MeetingRecognitionExecution.Authority?
    private var microphonePort: MeetingSessionOwner.MicrophoneStreamPort?, frozenInput: AudioRecorder.MeetingInput?
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
        }
    }
    private func ensureOwner(explicitReentry: Bool = false) throws -> MeetingSessionOwner {
        guard !quarantine,let d = dependencies else { throw MeetingSession.Failure.unavailable }
        if let owner,owner.state != .detached { return owner }
        if owner != nil {
            guard explicitReentry,reservation == nil,lifecycleDriver == nil,retirement?.success == true,work.isEmpty,permission == nil,output == nil else { throw MeetingSession.Failure.held }
            self.owner = nil; ownerEpoch = UUID(); retirement = nil
        }
        let stream = MeetingSessionOwner.MicrophoneStreamPort(validate:{[weak self] selection in
            guard let self,self.startIntent != nil,self.page,self.reservation == nil,self.dependencies?.captureCapability == true,
                  self.dependencies?.authorization() == .authorized,let port = self.microphonePort else { return false }
            return await port.validate(selection)
        },start:{[weak self] selection,ingress in
            guard let self,self.page,self.startIntent != nil,self.reservation == nil,self.dependencies?.authorization() == .authorized,
                  let port = self.microphonePort else { return .init(source:selection.instance,exit:.notStarted) }
            return port.start(selection,ingress)
        },requestStop:{[weak self] in await self?.microphonePort?.requestStop() })
        let value = MeetingSessionOwner(store:d.makeStore(),microphone:stream,recognition:recognition.port,wallClock:d.wall,holdEpoch:1)
        value.onChange = { [weak self,weak value] snapshot in
            guard let self,self.owner === value else { return }
            self.publish(snapshot)
            if snapshot.state == .stopping,self.work[.stop] == nil { self.stopAndSave() }
        }
        owner = value; return value
    }
    private var admits: Bool { page && reservation == nil && lifecycleDriver == nil && !quarantine && protection == nil && output == nil }
    private var idle: Bool { work.isEmpty && permission == nil }
    func openPage() {
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
    func retryOpen() { openPage() }
    func leavePage() { page = false; pageIntent = UUID(); startIntent = nil; verifiedText = nil; owner?.revokeTextReads(); cancelTranscription(); stopAndSave() }
    func windowClosed() { leavePage() }
    /// Focus loss deliberately has no recording side effect.
    func focusChanged() {}
    func chooseMicrophone() { model.message = "Choose a microphone in Settings. Changes apply to the next recording." }
    func openMicrophoneSettings() { dependencies?.openPrivacy() }
    func startAndSave() {
        guard admits,idle,let d = dependencies else { return }
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
                try await value.openMetadata()
                guard self.startCurrent(intent),value.metadata == nil else { return }
                switch d.authorization() {
                case .undetermined:
                    let id = UUID(); self.permission = (id,intent,self.pageIntent)
                    self.model.message = "Waiting for microphone access. Recording has not started."
                    d.requestAccess { [weak self] granted in
                        // Always enqueue evidence delivery, including synchronous fake callbacks.
                        // This enqueue is the delivery wrapper's last resource action.
                        // The reply handoff below stays registered through evidence publication.
                        DispatchQueue.main.async {
                            guard let self,self.permission?.id == id else { return }
                            if self.page,self.pageIntent == self.permission?.page,self.reservation == nil {
                                self.model.message = granted ? "Microphone access is ready. Press Start to record and save." : "Microphone access is off. Allow it in System Settings, then press Start."
                            }
                            self.permission = nil; let pending = self.permissionWaiters; self.permissionWaiters.removeAll(); pending.forEach { $0.resume() }; self.publish()
                        }
                    }
                    return // permission never resumes this Start
                case .denied: self.model.message = "Microphone access is off. Allow it in System Settings, then press Start."; return
                case .authorized: break
                }
                let saved = try d.settings(), input = try d.resolveInput(saved.inputDeviceUID)
                guard self.startCurrent(intent),d.authorization() == .authorized else { return }
                self.frozenInput = input; self.microphonePort = d.microphone(input)
                let source = UUID(), epoch = UUID(), selection = MeetingSession.Selection(instance:source,kind:.microphone,label:input.label,generation:1)
                let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.unknown)
                try await value.startMicrophone(owner:UUID(),session:UUID(),selection:selection,segment:.init(id:UUID(),track:0,generation:1,timing:timing,canonicalStart:0))
                self.armExpiry()
            } catch { self.model.message = "Recording could not start. Saved audio, if any, is kept." }
        }
    }
    private func startCurrent(_ intent: UUID) -> Bool { admits && startIntent == intent }
    func stopAndSave() {
        if owner?.state == .recording || owner?.state == .starting { model.message = nil }
        startIntent = nil; owner?.requestStopSaving()
        guard work[.stop] == nil else { return }
        let start = work[.start]?.task
        launch(.stop) { [weak self] in
            if let start { await start.value }
            do { try await self?.owner?.finishStopSaving(); self?.armExpiry() }
            catch { self?.storageFailure() }
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
                let remaining = metadata.chunks.filter { $0.stage == .sealed && $0.accepted == nil }
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
            } catch { self.model.message = "Saved text could not be opened or copied. Try again after storage work finishes." }
        }
    }
    func deleteConfirmed(session: UUID,intent: UUID) {
        guard admits,owner?.metadata?.session == session,pageIntent == intent,work[.delete] == nil else { return }
        startIntent = nil; cancelTranscription(); verifiedText = nil; owner?.revokeTextReads(); cancelDeadline()
        // Admission must settle before intent; producer/consumer joins stay INSIDE owner.delete,
        // after its durable intent. Do not wait a normal Stop before writing delete intent.
        let pending = [work[.start]?.task,work[.metadata]?.task].compactMap { $0 }
        launch(.delete) { [weak self] in
            for task in pending { await task.value }
            do { try await self?.owner?.delete(id:UUID()); await self?.settleOldDeadline(session:nil); self?.model.message = "Saved meeting deleted." }
            catch { self?.model.message = "Deletion is not finished. Saved files may remain." }
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
        guard let metadata = owner?.metadata,!metadata.deleting,let d = dependencies,reservation == nil,lifecycleDriver == nil else { return }
        if deadline?.session == metadata.session { return }
        // Never replace a live deadline. Its actual exit is joined first by the metadata/stop action.
        guard deadline == nil else { return }
        do {
            let now = try d.wall(), delta = metadata.expires.subtractingReportingOverflow(now), id = UUID()
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
        startIntent = nil; cancelTranscription(); value.revokeTextReads()
        launch(.expiry) { [weak self,value] in
            do { try await value.evaluateExpiry(deleteID:UUID()) } catch { self?.storageFailure() }
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
        startIntent = nil; pageIntent = UUID(); cancelTranscription(); owner?.revokeTextReads(); owner?.requestStopSaving(); owner?.reserveQuit(); cancelDeadline()
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
                do { try await current.committedDetach() } catch { return .init(reservation:id,epoch:epoch,success:false) }
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
        if result.epoch == ownerEpoch { retirement = result }
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
    func releaseRestart() { reservation = nil } // no capture/ASR/output revival or bootstrap
    func cancelShutdown() { releaseRestart() }
    private func storageFailure() { model.message = "Saved meeting unavailable. Parla could not safely finish storage work."; if owner?.protectionQuarantined == true { quarantine = true } }
    private func publish(_ snapshot: MeetingSessionOwner.Snapshot? = nil) {
        let snapshot = snapshot ?? owner?.snapshot
        model.state = snapshot?.state ?? .idle; model.metadata = snapshot?.metadata; model.busy = !work.isEmpty || permission != nil || reservation != nil || lifecycleDriver != nil
        model.source = frozenInput?.label ?? snapshot?.metadata?.selections.first?.label ?? "Saved microphone"
        if let verifiedText,verifiedText.metadata == snapshot?.metadata { model.text = verifiedText.text } else { model.text = nil }
    }
}
extension MeetingRecognitionExecution.Authority {
    var currentClosure: @Sendable () -> Bool { { [self] in current } }
}
