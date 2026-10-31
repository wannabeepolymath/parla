import AppKit
import AVFoundation
import CryptoKit
import Darwin
import XCTest
@testable import ParlaCore
@testable import Parla

final class GuidedClock {
    var now: TimeInterval = 100
    var actions: [UUID:(TimeInterval, () -> Void)] = [:]
    var retired: [() -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let id = UUID(); actions[id] = (now + delay,action); retired.append(action)
        return { self.actions[id] = nil }
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = actions.filter({$0.value.0 <= end}).min(by:{$0.value.0 < $1.value.0}) {
            now = next.value.0; actions[next.key] = nil; next.value.1()
        }
        now = end
    }
}
final class GuidedEngine: MicrophoneCaptureEngine {
    var isRunning = false, fail = false
    var route = MicrophoneRoute(name:"Synthetic input",fallback:false)
    var starts = 0, stops = 0
    var receive: ((AVAudioPCMBuffer) -> Void)?, changed: (() -> Void)?
    var requested: String?
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
        starts += 1; requested = requestedUID; self.receive = receive; self.changed = changed
        if fail { throw AudioRecorder.RecorderError.noInputFormat }; isRunning = true
    }
    func stop() { stops += 1; isRunning = false; receive = nil; changed = nil }
    static func buffer(_ value: Float = 0.25, count: Int = 8000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
        let b = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(max(1,count)))!
        b.frameLength = AVAudioFrameCount(count); b.floatChannelData![0].initialize(repeating:value,count:count); return b
    }
    func feed(_ value: Float = 0.25, count: Int = 8000) { receive?(Self.buffer(value,count:count)) }
}
final class GuidedMemory {
    var settings: Data?, history: Data?
    var copies: [String] = []
    var historyWrites = 0, fullWrites = 0, narrowWrites = 0, forbidden = 0
    var failHistory = false, failLoad = false
    var accesses: [RecordingStore.Access] = [], audioWrites = 0, removes = 0
    var conversion: ((AVAudioPCMBuffer) -> [Float]?)?
    var drain: Result<[Float],GuidedTemplateFailure> = .success([])
    var onDrain: () -> Void = {}
}
@MainActor final class GuidedRig {
    let root: URL, store: SettingsStore, history: HistoryStore, recordings: RecordingStore, hub: HubModel
    let owner = GuidedTemplateOwner(), local = LocalCleanupAdmission(), admission = CaptureAdmission()
    let engine = GuidedEngine(), clock = GuidedClock(), memory = GuidedMemory(), credentials = FakeCredentialBackend(), native = FoundationNativeProbe()
    let recorder: AudioRecorder
    var chain: Task<Void,Never>?
    var secure = false, permitted = true, allowed = true
    var preparation = UUID(), selection = UUID(), refusal: String?
    var factoryProvider: (() -> RecognitionFactory)?
    var invalidations = 0, queued = 0, finished = 0
    init(fields: [String] = ["title"], optional: Bool = false, keepAll: Bool = false) throws {
        root = URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("wave7f1-resume3-child-\(UUID().uuidString.lowercased())",isDirectory:true)
        guard mkdir(root.path,0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try recordWave4BFixture(root,"created")
        let m = memory, c = clock
        store = SettingsStore(url:root.appendingPathComponent("settings.json"),credentials:CredentialStore(backend:credentials),
            scratchpadIO:.init(read:{_ in m.settings},write:{bytes,_ in m.narrowWrites += 1; m.settings = bytes}),
            documentIO:.init(read:{m.settings}),atomicWrite:{bytes,_ in m.fullWrites += 1; m.settings = bytes})
        var s = Settings(); s.whisperModelPath = "/synthetic/ggml-global.bin"; s.language = "hi"; s.dictionary = ["Parla"]
        s.cleanup.provider = "apple-intelligence"; s.inputDeviceUID = "synthetic-input"; s.cleanupEnabled = false; s.outputMode = .raw
        m.settings = try JSONEncoder().encode(s)
        history = HistoryStore(url:root.appendingPathComponent("history.json"),persistence:.init(read:{_ in
            if m.failLoad { throw CocoaError(.fileReadCorruptFile) }
            guard let bytes = m.history else { throw CocoaError(.fileReadNoSuchFile) }; return bytes
        },writeAtomically:{bytes,_ in m.historyWrites += 1; if m.failHistory { throw CocoaError(.fileWriteOutOfSpace) }; m.history = bytes}))
        let recordingDirectory = root.appendingPathComponent("recordings").standardizedFileURL
        try FileManager.default.createDirectory(at:recordingDirectory,withIntermediateDirectories:true)
        // Precreate before RecordingStore freezes its canonical root (root diagnostic3).
        XCTAssertTrue(FileManager.default.fileExists(atPath:recordingDirectory.path))
        recordings = RecordingStore(directory:recordingDirectory,keepAll:keepAll,
            access:{m.accesses.append($0)},writer:{samples,url in
                m.audioWrites += 1; try RecordingStore.writeWAV(samples,to:url)
            },remover:{url in m.removes += 1; try FileManager.default.removeItem(at:url)})
        recorder = AudioRecorder(engine:engine,admission:admission,conversion:{buffer in
            if let conversion = m.conversion { return conversion(buffer) }
            guard let samples = buffer.floatChannelData?[0] else {return nil}; return Array(UnsafeBufferPointer(start:samples,count:Int(buffer.frameLength)))
        },guidedDrain:{m.onDrain(); return m.drain},captureClock:{c.now},scheduleRoute:c.schedule)
        hub = HubModel(store:store,history:history,clipboard:{m.copies.append($0)},recordings:recordings,
            shortcutLabels:ShortcutLabels(center:NotificationCenter(),snapshot:{ShortcutDisplayFormatter{_ in nil}}),diagnostics:DiagnosticStore(),templates:owner)
        hub.loading = true; hub.settings = s; hub.settingsBase = s; hub.words = s.dictionary.map{HubModel.WordRow(text:$0)}; hub.loading = false
        hub.onSaved = { m.forbidden += 1 }; hub.onDownloadModel = {_ in m.forbidden += 1}
        hub.retryFactory = {_,_,_,_ in m.forbidden += 1; throw CancellationError()}
        hub.onTryoutStart = {m.forbidden += 1; return nil}; hub.onTryoutStop = {_ in m.forbidden += 1}
        owner.bind(store:store,capture:RecorderGuidedTemplateCapture(recorder:recorder),admission:admission,local:local)
        owner.clock = {c.now}; owner.schedule = c.schedule; owner.date = {Date(timeIntervalSince1970:123)}
        owner.security = {[unowned self] in secure}; owner.permission = {[unowned self] in permitted}
        owner.allowed = {[unowned self] in allowed}; owner.draftReady = {[unowned self] in hub.templateDraftReady()}
        owner.selectionEpoch = {[unowned self] in selection}; owner.preparationEpoch = {[unowned self] in preparation}
        owner.preparationRefusal = {[unowned self] _ in refusal}
        owner.invalidatePriorAuthority = {[unowned self] in invalidations += 1}
        owner.factory = {[unowned self] _ in factoryProvider?() ?? makeFactory()}; owner.resident = {nil}
        owner.enqueue = {[unowned self] op,work,done in
            queued += 1
            chain = PendingOperationQueue.enqueue(previous:chain,operation:op,completes:true,work:work,finished:{
                await done(); await MainActor.run {self.finished += 1}
            })
        }
        recorder.onGuidedEnd = {[weak owner] session,capture,_ in DispatchQueue.main.async {owner?.captureEnded(session:session,capture:capture)}}
        hub.editTemplate(nil)
        hub.templateEditor?.name = "User bug report"
        hub.templateEditor?.fields = fields.map{GuidedTemplateField(key:$0,label:$0.capitalized,required:!optional)}
        hub.templateEditor?.body = fields.map{$0.capitalized+": {{"+$0+"}}"}.joined(separator:"\r\n")
        hub.saveTemplateDefinition(); XCTAssertNil(hub.templateEditor,hub.templateMessage ?? "editor refused")
    }
    func makeFactory() -> RecognitionFactory {
        let n = native
        return RecognitionFactory(parakeetPreparedUse:{_,_ in XCTFail("Unexpected Parakeet preparation"); throw CancellationError()},
            parakeetTrust:.init(host:{XCTFail("Unexpected host query")},read:{_,_ in XCTFail("Unexpected trust read"); throw CancellationError()},signature:{_,_ in XCTFail("Unexpected signature query")}),
            parakeetApp:root.appendingPathComponent("Synthetic.app"),parakeetWorker:.init(launch:{_ in XCTFail("Unexpected worker"); throw CancellationError()}),
            appleBottom:.init(available:{XCTFail("Unexpected Apple availability")},session:{_ in XCTFail("Unexpected Apple session"); throw CancellationError()}),
            appleInstalledUse:{_,_ in XCTFail("Unexpected Apple preparation"); throw CancellationError()},
            native:{path,_ in n.paths.append(path); n.construct?(); return FoundationNativeProbe.Native(n)},
            guardedNative:{_,_,_ in XCTFail("Unexpected guarded constructor"); throw CancellationError()},
            preparationPermission:{true},runtime:{n.runtime},metadata:{_ in n.metadataReads += 1; return n.generation},
            directory:root.appendingPathComponent("models"),catalog:[],admit:{path,policy in n.admissions += 1; try n.admission?(path,policy)})
    }
    func begin() async {hub.beginTemplate(); await chain?.value}
    func take(_ text: String = "spoken literal", count: Int = 8000, value: Float = 0.25) async {
        native.outputs = [.init(status:0,segments:[text])]; owner.start(); engine.feed(value,count:count); owner.stop(); await chain?.value
    }
    func approve() throws {owner.review(); owner.approve(try XCTUnwrap(owner.session?.preview).id)}
    func close() async throws {
        owner.cancel(); await chain?.value
        XCTAssertTrue(owner.readyForRestart); XCTAssertTrue(admission.isAvailable); XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(recorder.retainedAudioCounts.samples,0); XCTAssertEqual(recorder.retainedAudioCounts.preRoll,0); XCTAssertFalse(recorder.retainedAudioCounts.converter)
        XCTAssertEqual(credentials.reads + credentials.statuses + credentials.adds + credentials.updates + credentials.deletes,0)
        XCTAssertEqual(memory.forbidden,0); XCTAssertEqual(queued,finished)
        XCTAssertFalse(hub.hasPendingSettingsSave)
        try recordWave4BFixture(root,"closed")
        // Retained, exclusively owned fixtures. External cleanup needs two identity checks and lsof.
        let entries = [root] + (FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? [])
        for url in entries {
            var st = stat(); XCTAssertEqual(lstat(url.path,&st),0)
            let sha = st.st_mode & S_IFMT == S_IFREG ? SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined() : "directory"
            try recordWave4BFixture(url,"closed-identity:\(st.st_uid):\(st.st_dev):\(st.st_ino):\(st.st_mode):\(st.st_nlink):\(st.st_size):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(sha)")
        }
    }
}

final class GuidedTemplateConnectedTests: XCTestCase {
    @MainActor func testT07InertDefinitionEntryAndRefusalsNeverStartAutomatically() async throws {
        let r = try GuidedRig(); XCTAssertEqual(r.engine.starts,0); XCTAssertTrue(r.native.paths.isEmpty)
        r.permitted = false; await r.begin(); XCTAssertFalse(r.owner.ownsSession); XCTAssertEqual(r.engine.starts,0)
        r.permitted = true; r.refusal = "Prepare explicitly"; await r.begin(); XCTAssertFalse(r.owner.ownsSession)
        r.refusal = nil; r.allowed = false; await r.begin(); XCTAssertFalse(r.owner.ownsSession)
        r.allowed = true; await r.begin(); XCTAssertTrue(r.owner.ownsSession); XCTAssertEqual(r.engine.starts,0)
        r.owner.cancel(); r.permitted = true; XCTAssertEqual(r.engine.starts,0)
        await r.begin(); await r.take(); XCTAssertEqual(r.engine.starts,1); XCTAssertEqual(r.native.calls.count,1)
        try await r.close()
    }
    @MainActor func testT07T16InvalidSavedBackendsAndClosedPreparationRefuseBeginBeforeReservation() async throws {
        for mode in 0..<4 {
            let r = try GuidedRig(), original = r.memory.settings
            var saved = try r.store.savedRetrySnapshot(), factoryCalls = 0
            let apple = AppleOwnerRig()
            switch mode {
            case 0: saved.recognitionEngine = .invalid
            case 1: saved.recognitionEngine = .appleSpeech; saved.appleSpeechLocale = nil
            case 2: saved.recognitionEngine = .parakeet; saved.parakeetModelID = "unsupported-synthetic"
            default:
                apple.nilRequest = true; apple.configure(); await apple.wait(); await apple.prepare()
                saved.recognitionEngine = .appleSpeech; saved.appleSpeechLocale = "en-US"
                let request = RecognitionRequest(settings:saved)
                XCTAssertNil(apple.owner.cachedRefusal(for:request,deliberate:true))
                XCTAssertTrue(apple.owner.reserveRestart())
                XCTAssertNotNil(apple.owner.cachedRefusal(for:request,deliberate:true))
                r.owner.preparationRefusal = {apple.owner.cachedRefusal(for:$0,deliberate:true)?.message}
            }
            r.memory.settings = try JSONEncoder().encode(saved)
            let writes = r.memory.fullWrites + r.memory.narrowWrites, observations = apple.observations
            r.factoryProvider = {factoryCalls += 1; return r.makeFactory()}
            await r.begin(); r.owner.start(); r.owner.stop(); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
            XCTAssertNil(r.owner.session); XCTAssertTrue(r.owner.readyForRestart)
            XCTAssertEqual(r.engine.starts,0); XCTAssertEqual(factoryCalls,0); XCTAssertTrue(r.native.paths.isEmpty)
            XCTAssertEqual(r.native.admissions,0); XCTAssertEqual(r.native.metadataReads,0)
            XCTAssertEqual(r.invalidations,0); XCTAssertEqual(r.queued,0); XCTAssertTrue(r.admission.isAvailable)
            XCTAssertFalse(HotkeyMonitor.suspended); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            XCTAssertEqual(r.memory.fullWrites + r.memory.narrowWrites,writes); XCTAssertEqual(apple.observations,observations)
            if mode == 3 {apple.owner.releaseRestart()}
            r.memory.settings = original; r.owner.preparationRefusal = { _ in nil }
            await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate); XCTAssertEqual(factoryCalls,1)
            r.factoryProvider = nil; try await r.close()
        }
    }
    @MainActor func testT14ActualTryoutCompletionPrecedesGuidedAdmissionBarrier() async throws {
        let r = try GuidedRig(), control = try GuidedOrdinaryControl(r)
        let entered = expectation(description:"actual tryout decode held"), exit = DispatchSemaphore(value:0)
        let operation = PendingOperation(name:"actual tryout predecessor"), request = RecognitionRequest(settings:try r.store.savedRetrySnapshot())
        var displayed:[String] = [], completions = 0
        r.owner.allowed = {!control.host.tryoutActive}
        XCTAssertTrue(control.host.beginTryout())
        r.native.decode = {entered.fulfill(); exit.wait()}
        let factory = r.makeFactory()
        r.chain = RecognitionAcquisition.enqueueTryout(previous:r.chain,operation:operation,work:{
            await RecognitionAcquisition.tryout(samples:[Float](repeating:0.25,count:8000),request:request,resident:nil,
                factory:factory,operation:operation)
        },current:{control.host.tryoutActive},done:{displayed.append($0)},finished:{
            control.host.endTryout(); completions += 1
            XCTAssertTrue(operation.hasExited); XCTAssertEqual(r.native.live,0)
            r.hub.beginTemplate(); XCTAssertTrue(r.owner.ownsSession); XCTAssertTrue(r.owner.busy)
            r.owner.start(); XCTAssertEqual(r.engine.starts,0)
        })
        let predecessor = r.chain
        await fulfillment(of:[entered],timeout:3)
        r.hub.beginTemplate(); XCTAssertFalse(r.owner.ownsSession); XCTAssertEqual(r.engine.starts,0)
        XCTAssertTrue(displayed.isEmpty); XCTAssertEqual(completions,0)
        exit.signal(); await predecessor?.value; await r.chain?.value
        XCTAssertEqual(displayed,["native original"]); XCTAssertEqual(completions,1)
        XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.owner.busy); XCTAssertEqual(r.engine.starts,0)
        r.native.decode = nil; await r.take("fresh form take"); XCTAssertEqual(r.owner.session?.candidate,"fresh form take")
        XCTAssertEqual(r.native.calls.count,2); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
        r.owner.allowed = {true}; try await r.close()
    }
    @MainActor func testT08T21T23FullUserCreatedBugReportVoiceToSealedCopyAndSingleHistory() async throws {
        let r = try GuidedRig(fields:["title","steps","expected","actual"])
        let values = ["Button fails", "click twice", "A literal {{actual}} $1", "Observed failure"]
        await r.begin()
        for (i,text) in values.enumerated() {
            await r.take(text); XCTAssertEqual(r.owner.session?.candidate,text)
            XCTAssertEqual(r.owner.session?.index,i); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            let starts = r.engine.starts; r.owner.accept(); XCTAssertEqual(r.engine.starts,starts)
        }
        let body = "Title: Button fails\r\nSteps: click twice\r\nExpected: A literal {{actual}} $1\r\nActual: Observed failure"
        XCTAssertNil(r.owner.session?.completion); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
        try r.approve(); let sealed = try XCTUnwrap(r.owner.session?.completion)
        XCTAssertEqual(sealed.body,body); r.owner.approve(r.owner.session!.preview!.id); XCTAssertEqual(r.owner.session?.completion,sealed)
        r.hub.copyTemplate(); r.hub.copyTemplate(); XCTAssertEqual(r.memory.copies,[body,body])
        r.hub.saveCompletedTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertEqual(r.history.entries.count,1); XCTAssertEqual(r.history.entries[0].id,sealed.id)
        XCTAssertEqual(r.history.entries[0].date,sealed.date); XCTAssertEqual(r.history.entries[0].raw,body); XCTAssertNil(r.history.entries[0].cleaned)
        XCTAssertEqual(r.memory.historyWrites,1); XCTAssertTrue(r.history.pendingEntries.isEmpty)
        r.history.clear(); r.hub.saveCompletedTemplate(); XCTAssertTrue(r.history.entries.isEmpty)
        XCTAssertEqual(r.native.paths.count,4); XCTAssertEqual(r.native.calls.map(\.samples.count),[8000,8000,8000,8000])
        XCTAssertEqual(r.native.calls.map(\.prompt),Array(repeating:"Parla",count:4)); XCTAssertEqual(r.native.calls.map(\.language),Array(repeating:"hi",count:4))
        XCTAssertEqual(Set(r.native.calls.map(\.instance)).count,4); XCTAssertEqual(r.native.live,0)
        XCTAssertTrue(r.memory.accesses.isEmpty); XCTAssertEqual(r.memory.audioWrites,0)
        try await r.close()
    }
    @MainActor func testT09RetakeFailureDiscardBackSkipAndApprovedImmutability() async throws {
        let r = try GuidedRig(fields:["title","actual"],optional:true); await r.begin()
        await r.take("first"); r.owner.accept(); r.owner.back()
        await r.take(""); XCTAssertNil(r.owner.session?.candidate)
        let id = r.owner.session!.field.id; XCTAssertEqual(r.owner.session?.accepted[id],.accepted("first"))
        await r.take("replacement"); r.owner.discardTake(); XCTAssertEqual(r.owner.session?.accepted[id],.accepted("first"))
        await r.take("accepted replacement"); r.owner.accept(); r.owner.skip(); try r.approve()
        let result = r.owner.session?.completion; r.owner.back(); r.owner.start(); r.owner.skip(); r.owner.editCandidate("change")
        XCTAssertEqual(r.owner.session?.completion,result); XCTAssertEqual(r.engine.starts,4)
        XCTAssertEqual(result?.body,"Title: accepted replacement\r\nActual: ")
        try await r.close()
    }
    @MainActor func testT12IncompleteFloorNonfiniteDrainAndRouteRefuseBeforeFactory() async throws {
        for mode in 0..<7 {
            let r = try GuidedRig(); await r.begin(); r.owner.start()
            switch mode {
            case 0: break
            case 1: r.engine.feed(count:10)
            case 2: r.engine.feed(0)
            case 3: r.engine.feed(.infinity)
            case 4: r.engine.feed(); r.memory.drain = .failure(GuidedTemplateFailure("synthetic drain failure"))
            case 5: r.engine.feed(); r.engine.changed?()
            default: r.engine.feed(count:480001)
            }
            r.owner.stop(); await r.chain?.value
            XCTAssertTrue(r.native.paths.isEmpty); XCTAssertNil(r.owner.session?.candidate)
            XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0); try await r.close()
        }
    }
    @MainActor func testT16ActualFactoryRefusalsAndNativeFailureKeepPriorAcceptedValue() async throws {
        for mode in 0..<5 {
            let r = try GuidedRig(); await r.begin(); await r.take("old"); r.owner.accept()
            switch mode {
            case 0: r.native.admission = {_,_ in throw CancellationError()}
            case 1: r.native.outputs = [.init(status:-1)]
            case 2: r.native.outputs = [.init(status:0,segments:[" "])]
            case 3: r.native.outputs = [.init(status:0,segments:[String(repeating:"x",count:8193)])]
            default: r.native.construct = {r.native.generation = .init(bytes:9,modified:2)}
            }
            let id = r.owner.session!.field.id
            r.owner.start(); r.engine.feed(); r.owner.stop(); await r.chain?.value
            XCTAssertEqual(r.owner.session?.accepted[id],.accepted("old")); XCTAssertNil(r.owner.session?.candidate)
            XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            try await r.close()
        }
    }
    @MainActor func testT22StorageOnlyRetryHistoryPolicyLoadFailureCollisionAndNoResurrection() async throws {
        let r = try GuidedRig(); await r.begin(); await r.take(); r.owner.accept(); try r.approve()
        let sealed = try XCTUnwrap(r.owner.session?.completion), calls = r.native.calls.count
        r.memory.failHistory = true; r.hub.saveCompletedTemplate(); XCTAssertFalse(r.owner.session!.saved); XCTAssertTrue(r.history.pendingEntries.isEmpty)
        r.memory.failHistory = false; r.memory.failLoad = true; r.hub.saveCompletedTemplate(); XCTAssertFalse(r.owner.session!.saved)
        r.memory.failLoad = false
        var s = try r.store.savedRetrySnapshot(); s.historyEnabled = false; try r.store.save(s)
        r.hub.saveCompletedTemplate(); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertEqual(r.owner.session?.completion,sealed)
        s.historyEnabled = true; try r.store.save(s); r.hub.saveCompletedTemplate()
        XCTAssertTrue(r.owner.session!.saved); XCTAssertEqual(r.history.entries.first?.id,sealed.id); XCTAssertEqual(r.native.calls.count,calls)
        r.history.delete(sealed.id); r.hub.saveCompletedTemplate(); XCTAssertTrue(r.history.entries.isEmpty)
        try await r.close()
    }
    @MainActor func testT03NarrowEditorSavePreservesUnrelatedPendingDraftBaseAndCallback() async throws {
        let r = try GuidedRig(); let base = r.hub.settingsBase, bytes = r.memory.settings
        r.hub.settings.showHudAlways.toggle(); XCTAssertTrue(r.hub.hasPendingSettingsSave)
        let draft = r.hub.settings
        r.hub.editTemplate(nil); r.hub.templateEditor?.name = "invalid"; r.hub.saveTemplateDefinition()
        XCTAssertNotNil(r.hub.templateEditor); XCTAssertEqual(r.memory.settings,bytes)
        r.hub.templateEditor?.fields = [GuidedTemplateField(key:"x",label:"X")]; r.hub.templateEditor?.body = "{{x}}"
        r.hub.saveTemplateDefinition(); XCTAssertNil(r.hub.templateEditor)
        XCTAssertTrue(r.hub.hasPendingSettingsSave); XCTAssertEqual(r.hub.settings.showHudAlways,draft.showHudAlways)
        XCTAssertEqual(r.hub.settingsBase.showHudAlways,base.showHudAlways); XCTAssertEqual(r.memory.forbidden,0)
        r.hub.beginTemplate(); XCTAssertFalse(r.owner.ownsSession)
        // Explicit existing Save completes the unrelated draft, with its callback intact.
        r.hub.flushPendingSave(); XCTAssertFalse(r.hub.hasPendingSettingsSave); XCTAssertEqual(r.memory.forbidden,1); r.memory.forbidden = 0
        XCTAssertEqual(try r.store.savedRetrySnapshot().guidedTemplates.definitions.count,2)
        try await r.close()
    }
}

private final class GuidedProvider: CleanupProviding {
    var calls = 0
    func clean(transcript:String,context:CleanupContext) async throws -> String {calls += 1; return transcript+" cleaned"}
}
@MainActor private final class GuidedOrdinaryControl {
    let r:GuidedRig, machine = DictationSession(diagnostics:nil), provider = GuidedProvider()
    var settings:Settings
    var captured:[Float] = [], pending:(DictationSession.Session,DictationSession.Landed)?
    var ordinary:[OrdinaryDictationFinalization.Entry] = [], insertions = 0, corrections = 0, finals = 0, entries = 0
    var deadline:TimeInterval = 0
    var captureOperation:UUID?
    var storageURL: URL?
    lazy var runtime = AutomationRuntime(clock:GuidedAutomationClock(r.clock),enabled:{true})
    lazy var originals = OriginalCopyController(configuration:{[unowned self] in settings},generation:{[unowned self] in machine.gen},
        now:{[unowned self] in r.clock.now},schedule:{_,_ in {}},security:{.safe},copy:{[unowned self] in r.memory.copies.append($0)})
    lazy var insertion = DictationInsertionExecutor(originals:originals,post:{[unowned self] _,_,dispatch in insertions += 1; dispatch(); return true},didPost:{[unowned self] _ in corrections += 1})
    lazy var undo = CanceledCaptureUndoController(configuration:{[unowned self] in settings},generation:{[unowned self] in machine.gen},
        security:{.safe},now:{[unowned self] in r.clock.now},schedule:{_,_ in {}},copy:{[unowned self] in r.memory.copies.append($0)})
    lazy var preview: CanceledCaptureRecognition = {
        var factory = r.makeFactory()
        factory.directory = URL(fileURLWithPath:"/synthetic",isDirectory:true)
        factory.catalog = [.init(id:"global",displayName:"Synthetic",bytes:1,sha256:String(repeating:"a",count:64))]
        return CanceledCaptureRecognition(controller:undo,factory:factory,verify:{_ in true})
    }()
    lazy var dispatcher = DictationExecutionDispatcher(preview:preview,ordinary:{[unowned self] session,samples,_ in await ordinary(session,samples:samples)})
    lazy var sink = HistoryPersistenceSink(history:r.history,settings:r.store)
    lazy var host = DictationInvocationHost(machine:machine,captureAdmission:r.admission,broker:runtime.broker,results:runtime.results,
        settings:{[unowned self] in settings},configured:{_ in true},capabilities:{_ in nil},secure:{false},keyboardAllowed:{true},automationAllowed:{true},
        explicitEntry:{[unowned self] in entries += 1; r.recorder.resumeWarmthOnExplicitEntry()},send:{[unowned self] in send($0)})
    init(_ r:GuidedRig) throws {
        self.r = r; settings = try r.store.savedRetrySnapshot()
        settings.outputMode = .cleanup; settings.cleanupEnabled = true; settings.keepLastOriginalEnabled = true; settings.canceledCaptureUndoEnabled = true
        settings.automationEnabled = true
        runtime.broker.register(host)
        undo.enqueue = {[unowned self] in r.chain = dispatcher.enqueue(.canceledCaptureUndo($0),previous:r.chain)}
        r.owner.invalidatePriorAuthority = {[unowned self] in r.invalidations += 1; undo.invalidate(); originals.clear(); host.inputAuthority.invalidateQueuedMouseStarts(); host.clearResult()}
    }
    @discardableResult func start() -> Bool {host.keyboard(.startDictation(settings:settings,cleanupConfigured:true,live:false))}
    func send(_ event:DictationSession.Event) {
        r.owner.observe(event); originals.observe(event); undo.observe(event)
        if case .cancelRequested = event {deadline = undo.cancellationDeadline()}
        sink.beginEvent(for:event,currentGeneration:machine.gen)
        machine.send(event) {effect in
            originals.observe(effect)
            switch effect {
            case .captureAccepted(let s): captureOperation = s.operation.id; host.accepted(s); undo.accepted(s,physical:true)
            case .captureAcknowledged(let s): host.acknowledged(s); undo.acknowledged(s)
            case .captureFinalizing(let s): host.finalizing(s)
            case .applyPreferencesAndStartCapture:
                do {try r.recorder.start(diagnosticOperation:captureOperation); send(.recorderStarted(gen:machine.gen))} catch {send(.recorderFailed(gen:machine.gen,message:"synthetic capture refused"))}
            case .sampleFocus(let gen): send(.focusSampled(gen:gen,focus:.editable))
            case .stopCapture,.stopOwnedCapture: captured = r.recorder.stop()
            case .abortOperation(let operation): operation.requestAbort()
            case .transcribeFinal(let s,let ledger): r.chain = dispatcher.enqueue(.ordinary(s,samples:captured,ledger:ledger),previous:r.chain)
            case .polish(let s,let landed): pending = (s,landed)
            case .insertText(let text,_,let context): _ = insertion.insert(text,original:context,operation:machine.effectOperation)
            case .appendHistory,.appendTransformHistory: _ = sink.record(effect,metrics:{nil})
            case .finalResult(let s,let result): finals += 1; host.completed(s,result:result)
            case .cancelCapture(let context): undo.transferred(r.recorder.stopCanceledCapture(operationID:context.operation.id,retain:true),context:context,deadline:deadline)
            case .presentCanceledCapture(let generation): undo.present(generation:generation)
            default: break
            }
        }
        host.synchronizeInput()
    }
    func ordinary(_ s:DictationSession.Session,samples:[Float]) async {
        let finalizer = OrdinaryDictationFinalization(recordings:r.recordings,settings:r.store,entered:{[unowned self] in ordinary.append($0)})
        await finalizer.run(operation:s.operation,samples:samples,window:nil,prepare:{url,_ in
            self.storageURL = url
            XCTAssertNotNil(url,"Synthetic ordinary WAV storage refused: " + (self.r.recordings.lastError ?? "no storage error"))
            return try? await RecognitionAcquisition.acquire(request:s.recognition,resident:nil,factory:self.r.makeFactory(),operation:s.operation)
        },recognized:{_,raw in
            self.pending = nil; self.send(.transcribed(s,raw:raw,probe:.init(focus:.editable,deferInsertionUntilClean:true)))
            finalizer.resolve(transcript:raw,secure:false); return self.pending
        },clean:{context in
            await Pipeline(outputSettings:context.0.effectiveSettings,bundleID:nil,makeClient:{_ in self.provider}).clean(transcript:context.1.raw)
        },completed:{context,text,failure in self.send(.cleanReady(context.0,context.1,text:text,failure:failure,focus:.editable))})
    }
    func reset() {ordinary = []; insertions = 0; corrections = 0; finals = 0; entries = 0; provider.calls = 0; r.memory.accesses = []; r.memory.audioWrites = 0; r.memory.removes = 0; r.memory.copies = []; originals.clear(); undo.invalidate(); host.clearResult()}
}
extension GuidedTemplateConnectedTests {
    @MainActor func testT24RealOrdinaryStorageCorpusProviderInsertionOriginalControlsThenGuidedPrivacyZeros() async throws {
        let r = try GuidedRig(keepAll:true), h = try GuidedOrdinaryControl(r)
        XCTAssertTrue(h.start()); r.engine.feed(); h.send(.stopRequested); await r.chain?.value
        _ = try XCTUnwrap(h.storageURL,"Ordinary storage must succeed before paired privacy controls")
        XCTAssertEqual(h.ordinary,[.stash,.resolve]); XCTAssertEqual(r.memory.audioWrites,1)
        XCTAssertGreaterThan(h.provider.calls,0); XCTAssertGreaterThan(h.insertions,0); XCTAssertGreaterThan(h.corrections,0); XCTAssertGreaterThan(h.finals,0)
        XCTAssertEqual(r.history.entries.count,1)
        let token = try XCTUnwrap(h.originals.refresh().token); XCTAssertTrue(h.originals.copyOriginal(token:token)); XCTAssertFalse(r.memory.copies.isEmpty)
        let wav = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:r.recordings.directory,includingPropertiesForKeys:nil).first{$0.pathExtension == "wav"})
        let corpus = wav.deletingPathExtension().appendingPathExtension("hyp.txt")
        XCTAssertEqual(try String(contentsOf:corpus,encoding:.utf8),"native original")
        // A corpus success is deliberately excluded from failed recovery (RecordingStore.acquire).
        // Produce a distinct failed ordinary take through the same real finalizer, retaining its WAV.
        r.native.outputs = [.init(status:-1)]
        XCTAssertTrue(h.start()); r.engine.feed(); h.send(.stopRequested); await r.chain?.value
        let recoverable = try XCTUnwrap(h.storageURL); XCTAssertNotEqual(recoverable,wav)
        // FoundationNativeProbe repeats its last outcome; reset the failed control before positives.
        r.native.outputs = [.init(status:0,segments:["native original"])]
        // Connected recovery acquisition/full batch/disposal reaches these same store observers.
        r.hub.onRecoveryTranscribe = {lease,request,done in
            r.chain = RecoveryTranscription.enqueue(previous:r.chain,recordings:r.recordings,lease:lease,request:request,authorize:{true},load:{request in
                try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:r.makeFactory(),operation:lease.operation)
            },done:done)
        }
        r.hub.transcribeRecovery(recoverable); await r.chain?.value
        XCTAssertEqual(r.hub.recoveryPreview?.entry?.raw,"native original")
        XCTAssertTrue(r.memory.accesses.contains(.acquire)); XCTAssertTrue(r.memory.accesses.contains(.complete))
        r.hub.discardRecovery(); XCTAssertNil(r.hub.recoveryPreview)
        let removals = r.memory.removes; r.hub.deleteRecovery(recoverable); XCTAssertGreaterThan(r.memory.removes,removals)
        // Automation result publication is real and is revoked at the same Begin boundary.
        let automation = try await h.runtime.broker.startOrJoin().get(); r.engine.feed()
        let automated = try await h.runtime.broker.stop(sessionID:automation.sessionID).get(); await r.chain?.value
        XCTAssertFalse(automated.text.isEmpty); XCTAssertNotNil(h.runtime.results.read())
        let preserved = try Data(contentsOf:wav), sidecar = try Data(contentsOf:corpus)
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        h.reset(); let history = r.history.entries, writes = r.memory.historyWrites
        await r.begin(); await r.take("template value"); r.owner.accept(); try r.approve()
        XCTAssertTrue(r.memory.accesses.isEmpty); XCTAssertEqual(r.memory.audioWrites + r.memory.removes,0)
        XCTAssertTrue(h.ordinary.isEmpty); XCTAssertEqual(h.provider.calls + h.insertions + h.corrections + h.finals,0)
        XCTAssertNil(h.originals.refresh().token); XCTAssertNil(h.runtime.results.read()); XCTAssertEqual(h.undo.view,.empty); XCTAssertEqual(h.undo.retainedAudioCount,0)
        XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertEqual(r.history.entries,history); XCTAssertEqual(r.memory.historyWrites,writes)
        r.owner.cancel(); await r.begin(); r.owner.start(); r.engine.feed(0); r.owner.stop(); await r.chain?.value
        XCTAssertTrue(r.memory.accesses.isEmpty); XCTAssertTrue(h.ordinary.isEmpty); XCTAssertEqual(h.provider.calls+h.insertions+h.corrections+h.finals,0)
        XCTAssertEqual(try Data(contentsOf:wav),preserved); XCTAssertEqual(try Data(contentsOf:corpus),sidecar)
        h.runtime.broker.quit(); try await r.close()
    }
    @MainActor func testT13InvocationHostMouseReleaseDebtsAndB55RefuseForWholeWizard() async throws {
        let r = try GuidedRig(), h = try GuidedOrdinaryControl(r)
        var saved = try r.store.savedRetrySnapshot(); saved.mouseBinding = MouseButtonBinding(buttonNumber:2); try r.store.save(saved)
        let monitor = HotkeyMonitor(store:r.store,inputAuthority:h.host.inputAuthority,captureAdmission:r.admission,buttonState:{_ in .down})
        var pending:[() -> Void] = []; monitor.deliversOnMain = true; monitor.enqueueOnMain = {pending.append($0)}
        let router = DictationInputRouter(host:h.host,prepare:{.startDictation(settings:h.settings,cleanupConfigured:true,live:false)},secureRefused:{XCTFail("Unexpected security")})
        monitor.onMouseEdge = {router.mouse($0)}; monitor.receiveTapStatus(.ready)
        func drain() {while !pending.isEmpty {pending.removeFirst()()}}
        drain()
        XCTAssertTrue(monitor.receiveMouseEvent(button:2,isDown:true,at:100))
        await r.begin(); drain(); XCTAssertEqual(h.entries,0)
        XCTAssertTrue(monitor.receiveMouseEvent(button:2,isDown:false,at:101)); drain()
        let b55 = MicrophoneTestController(capture:RecorderMicrophoneCapture(recorder:r.recorder),admission:r.admission,allowed:{true},permission:{true},now:{r.clock.now},schedule:r.clock.schedule)
        for phase in 0..<4 {
            if phase == 1 {r.owner.start(); r.engine.feed()}
            if phase == 2 {r.owner.stop(); await r.chain?.value}
            if phase == 3 {r.owner.accept(); try r.approve()}
            XCTAssertFalse(h.start()); XCTAssertEqual(h.host.startAutomation(),.busy); XCTAssertFalse(h.host.beginTryout()); XCTAssertNil(h.host.beginShortcutRecording())
            b55.start(); XCTAssertFalse(b55.ownsSession)
            XCTAssertFalse(monitor.receiveMouseEvent(button:2,isDown:true,at:102)); XCTAssertFalse(monitor.receiveMouseEvent(button:2,isDown:false,at:103)); drain()
            XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertEqual(h.entries,0)
        }
        r.owner.cancel(); XCTAssertTrue(h.start()); r.engine.feed(); h.send(.cancelRequested(silent:true))
        XCTAssertTrue(r.admission.isAvailable); XCTAssertTrue(h.host.beginTryout()); h.host.endTryout()
        let shortcut = try XCTUnwrap(h.host.beginShortcutRecording()); h.host.endShortcutRecording(shortcut)
        b55.start(); r.engine.feed(); b55.stop(); XCTAssertTrue(b55.hasReview); b55.clear()
        h.runtime.broker.quit(); try await r.close()
    }
    @MainActor func testT02FullHubWriterAdoptsFreshTemplateBlockAndLargerOrdinarySettings() async throws {
        let r = try GuidedRig(); let original = try r.store.savedRetrySnapshot()
        // A valid legacy document above the narrow 1 MiB budget still supports a full save.
        var large = original; large.snippets = ["large":String(repeating:"x",count:1_048_577)]
        r.memory.settings = try JSONEncoder().encode(large)
        r.hub.loading = true; r.hub.settings = large; r.hub.settingsBase = large
        r.hub.snippets = [HubModel.SnippetRow(trigger:"large",expansion:large.snippets["large"]!)]; r.hub.loading = false
        XCTAssertThrowsError(try r.store.templateDocument())
        r.hub.settings.showHudAlways.toggle(); r.hub.onSaved = {}; r.hub.flushPendingSave()
        XCTAssertNil(r.hub.saveError); XCTAssertEqual(try r.store.savedRetrySnapshot().snippets,large.snippets)
        XCTAssertEqual(r.hub.templateDocument,large.guidedTemplates); XCTAssertEqual(r.hub.settingsBase.guidedTemplates,large.guidedTemplates)
        try await r.close()
    }
    @MainActor func testT23ActualHistoryExportOfComposedResult() async throws {
        let r = try GuidedRig(); await r.begin(); await r.take("composed raw"); r.owner.accept(); try r.approve(); r.hub.saveCompletedTemplate()
        let entry = try XCTUnwrap(r.history.entries.first); var outputs:[Data] = []
        r.hub.historyExportPanel = {_ in r.root.appendingPathComponent("composed.txt")}; r.hub.historyExportWriter = {bytes,_ in outputs.append(bytes)}
        r.hub.prepareHistoryExport(rowID:entry.id); r.hub.exportHistory(content:.original,format:.text)
        XCTAssertEqual(outputs.count,1); XCTAssertTrue(String(decoding:outputs[0],as:UTF8.self).contains("Title: composed raw"))
        XCTAssertEqual(r.history.entries.first?.raw,"Title: composed raw"); XCTAssertNil(r.history.entries.first?.cleaned)
        try await r.close()
    }
}

@MainActor private final class GuidedAutomationClock:AutomationClock {
    let base:GuidedClock
    init(_ base:GuidedClock) {self.base = base}
    var now:TimeInterval {base.now}
    func schedule(after seconds:TimeInterval,_ action:@escaping @MainActor () -> Void) -> () -> Void {
        base.schedule(seconds) {MainActor.assumeIsolated {action()}}
    }
}


extension GuidedTemplateConnectedTests {
    @MainActor func testT03T07PermissionCallbackEditorCloseAndPendingDraftsRemainInert() async throws {
        let r = try GuidedRig(), window = HubWindowController(model:r.hub)
        var callback:((Bool)->Void)?, requests = 0, privacy = 0
        r.hub.microphoneAuthorization = {.notDetermined}
        r.hub.microphoneRequest = {requests += 1; callback = $0}
        r.hub.microphonePrivacy = {privacy += 1}
        r.permitted = false
        r.hub.refreshTemplates(); r.hub.selectTemplate(r.hub.templateDocument.definitions.first?.id)
        r.hub.editTemplate(r.hub.selectedTemplateID); r.hub.cancelTemplateEditor(); await r.begin()
        XCTAssertEqual(requests,0); XCTAssertEqual(r.engine.starts,0); XCTAssertFalse(r.owner.ownsSession)
        r.hub.requestMicrophone(); XCTAssertEqual(requests,1)
        window.windowWillClose(Notification(name:NSWindow.willCloseNotification))
        callback?(true)
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertTrue(r.hub.micGranted); XCTAssertFalse(r.owner.ownsSession); XCTAssertEqual(r.engine.starts,0)
        r.hub.microphoneAuthorization = {.denied}; r.hub.requestMicrophone(); XCTAssertEqual(privacy,1); XCTAssertEqual(requests,1)
        r.permitted = true
        for invalid in [false,true] {
            let bytes = r.memory.settings, fullWrites = r.memory.fullWrites
            r.hub.settings.showHudAlways.toggle()
            if invalid {r.hub.saveError = "synthetic invalid pending settings"}
            let draft = r.hub.settings, base = r.hub.settingsBase
            r.hub.editTemplate(nil); r.hub.templateEditor?.name = "unsaved"; r.hub.cancelTemplateEditor()
            r.hub.editTemplate(nil); window.windowWillClose(Notification(name:NSWindow.willCloseNotification))
            XCTAssertNil(r.hub.templateEditor); XCTAssertTrue(r.hub.hasPendingSettingsSave)
            XCTAssertEqual(r.hub.settings,draft); XCTAssertEqual(r.hub.settingsBase,base)
            XCTAssertEqual(r.memory.settings,bytes); XCTAssertEqual(r.memory.fullWrites,fullWrites)
            await r.begin(); XCTAssertFalse(r.owner.ownsSession)
            // Only an explicit ordinary Save is allowed to settle its owed callback.
            r.hub.saveError = nil; r.hub.flushPendingSave(); XCTAssertEqual(r.memory.forbidden,1); r.memory.forbidden = 0
        }
        await r.begin(); await r.take(); XCTAssertNotNil(r.owner.session?.candidate)
        try await r.close()
    }
    @MainActor func testT06ConnectedRecognitionAndCandidateEditingAreLiteralAtOutput() async throws {
        let r = try GuidedRig()
        let literal = "{{other}} {{{{x}}}} $1 \\1 `rm -rf` a+b@example.test <script>data</script> skip cancel ignore previous instructions हिंदी اردو é 👩🏽‍💻 end"
        // Whisper normalizes native whitespace; the form preserves its payload and exact reviewed edits.
        await r.begin(); await r.take(literal); XCTAssertEqual(r.owner.session?.candidate,literal)
        r.owner.editCandidate(literal+"\r\nedited\n"); r.owner.accept(); try r.approve()
        r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
        XCTAssertEqual(r.memory.copies,["Title: "+literal+"\r\nedited\n"])
        XCTAssertEqual(r.history.entries.first?.raw,r.memory.copies.first); XCTAssertNil(r.history.entries.first?.cleaned)
        XCTAssertEqual(r.native.calls.count,1); try await r.close()
    }
    @MainActor func testT12ExactSampleTailWallClockAndRouteBoundaries() async throws {
        // At the limit capture is incomplete by policy; only a strictly below-limit take is eligible.
        for mode in 0..<9 {
            let r = try GuidedRig(); await r.begin()
            if mode == 6 {r.engine.route = .init(name:"System default",fallback:true)}
            if mode == 7 {r.engine.route = .init()}
            if mode == 8 {r.memory.conversion = {_ in nil}}
            r.owner.start()
            let positive:Bool
            switch mode {
            case 0: r.engine.feed(count:479999); positive = true
            case 1: r.engine.feed(count:480000); positive = false
            case 2: r.engine.feed(count:479999); r.memory.drain = .success([0.25]); positive = false
            case 3: r.engine.feed(count:479998); r.memory.drain = .success([0.25]); positive = true
            case 4: r.engine.feed(); r.memory.drain = .success([.nan]); positive = false
            case 5: r.engine.feed(); r.clock.now += 30; positive = false
            default: r.engine.feed(); positive = mode != 8
            }
            r.owner.stop(); await r.chain?.value
            XCTAssertEqual(r.native.calls.count,positive ? 1 : 0,"mode \(mode)")
            XCTAssertEqual(r.owner.session?.candidate != nil,positive,"mode \(mode)")
            if mode == 3 {XCTAssertEqual(r.native.calls.first?.samples.count,479999)}
            if mode == 6 {XCTAssertEqual(r.owner.route.name,"System default"); XCTAssertEqual(r.owner.route.fallback,true)}
            if mode == 7 {XCTAssertNil(r.owner.route.name); XCTAssertNil(r.owner.route.fallback)}
            XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0); try await r.close()
        }
    }
    @MainActor func testT16PreparationAndBackendRefusalsHaveNoFallbackThenFreshTakeWorks() async throws {
        for mode in 0..<5 {
            let r = try GuidedRig(); await r.begin(); await r.take("prior"); r.owner.accept()
            let field = try XCTUnwrap(r.owner.session?.field.id), count = r.native.calls.count
            switch mode {
            case 0: r.factoryProvider = {var f = r.makeFactory(); f.preparationPermission = {false}; return f}
            case 1: r.factoryProvider = {var f = r.makeFactory(); var observations = 0; f.metadata = {_ in observations += 1; return observations == 1 ? r.native.generation : nil}; return f}
            case 2: r.factoryProvider = {var f = r.makeFactory(); f.native = {_,_ in throw CancellationError()}; return f}
            case 3: r.refusal = "Explicit preparation is no longer valid"
            default: r.native.construct = {r.preparation = UUID()}
            }
            r.owner.start(); r.engine.feed(); r.owner.stop(); await r.chain?.value
            XCTAssertEqual(r.native.calls.count,count); XCTAssertNil(r.owner.session?.candidate)
            if r.owner.session != nil {XCTAssertEqual(r.owner.session?.accepted[field],.accepted("prior"))}
            XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.memory.copies.isEmpty)
            r.owner.cancel(); r.factoryProvider = nil; r.native.construct = nil; r.refusal = nil
            await r.begin(); await r.take("fresh"); XCTAssertEqual(r.owner.session?.candidate,"fresh")
            try await r.close()
        }
    }
    @MainActor func testT19SavedAwayBackDeletionRecreationAndUnrelatedDraftOutputBlock() async throws {
        for mode in 0..<6 {
            let r = try GuidedRig(); await r.begin(); await r.take(); r.owner.accept(); try r.approve()
            let original = r.memory.settings, definition = try XCTUnwrap(r.owner.session?.definition)
            switch mode {
            case 0: var s = try r.store.savedRetrySnapshot(); s.language = "ur"; try r.store.save(s)
            case 1: var s = try r.store.savedRetrySnapshot(); s.inputDeviceUID = "other-input"; try r.store.save(s)
            case 2: var s = try r.store.savedRetrySnapshot(); s.dictionary = ["Changed"]; try r.store.save(s)
            case 3: _ = try r.store.deleteTemplateDefinition(definition.id,expectedRevision:definition.revision)
            case 4:
                var s = try r.store.savedRetrySnapshot(); var d = definition; d.name = "same revision different bytes"
                s.guidedTemplates.definitions = [d]; r.memory.settings = try JSONEncoder().encode(s)
            default: r.hub.settings.showHudAlways.toggle()
            }
            r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
            XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            if mode == 5 {
                XCTAssertNotNil(r.owner.session?.completion); XCTAssertTrue(r.hub.hasPendingSettingsSave)
                r.hub.onSaved = {}; r.hub.flushPendingSave(); r.hub.copyTemplate(); XCTAssertEqual(r.memory.copies.count,1)
            } else {
                r.memory.settings = original; r.hub.refreshTemplates(); r.hub.copyTemplate(); r.hub.saveCompletedTemplate()
                XCTAssertNil(r.owner.session); XCTAssertTrue(r.memory.copies.isEmpty); XCTAssertTrue(r.history.entries.isEmpty)
            }
            try await r.close()
        }
    }
    @MainActor func testT22ConflictingHistoryIdentityCannotReidentifyOrResurrectApprovedResult() async throws {
        let r = try GuidedRig(); await r.begin(); await r.take(); r.owner.accept(); try r.approve()
        let sealed = try XCTUnwrap(r.owner.session?.completion), calls = r.native.calls.count
        let conflict = HistoryEntry(id:sealed.id,date:sealed.date,raw:"unrelated existing row")
        XCTAssertTrue(r.history.appendReviewed(conflict)); let bytes = r.memory.history, writes = r.memory.historyWrites
        r.hub.saveCompletedTemplate(); XCTAssertFalse(r.owner.session!.saved)
        XCTAssertEqual(r.history.entries,[conflict]); XCTAssertEqual(r.memory.history,bytes); XCTAssertEqual(r.memory.historyWrites,writes)
        XCTAssertTrue(r.history.pendingEntries.isEmpty); XCTAssertEqual(r.owner.session?.completion,sealed)
        r.history.delete(sealed.id); r.hub.saveCompletedTemplate(); XCTAssertTrue(r.owner.session!.saved)
        XCTAssertEqual(r.history.entries.first?.id,sealed.id); XCTAssertEqual(r.history.entries.first?.raw,sealed.body)
        XCTAssertEqual(r.history.entries.first?.date,sealed.date); XCTAssertEqual(r.native.calls.count,calls)
        r.history.clear(); r.hub.saveCompletedTemplate(); XCTAssertTrue(r.history.entries.isEmpty); XCTAssertTrue(r.history.pendingEntries.isEmpty)
        try await r.close()
    }
    @MainActor func testT14T24B57OfferPreviewAndHeldActualExitBeforeFormAdmission() async throws {
        for stage in 0..<3 {
            let r = try GuidedRig(), h = try GuidedOrdinaryControl(r)
            XCTAssertTrue(h.start()); r.engine.feed(); h.send(.cancelRequested(silent:true,reason:.shortRelease))
            let token = try XCTUnwrap(h.undo.view.token); XCTAssertGreaterThan(h.undo.retainedAudioCount,0)
            var leave:DispatchSemaphore?
            if stage == 1 {h.undo.undo(token:token); await r.chain?.value; XCTAssertEqual(h.undo.view,.preview(token,"native original"))}
            if stage == 2 {
                let entered = expectation(description:"actual B57 decode"), gate = DispatchSemaphore(value:0); leave = gate
                r.native.decode = {entered.fulfill(); gate.wait()}; h.undo.undo(token:token)
                await fulfillment(of:[entered],timeout:3)
            }
            let calls = r.native.calls.count
            r.hub.beginTemplate(); XCTAssertEqual(h.undo.view,.empty); XCTAssertNil(h.originals.refresh().token)
            if stage == 2 {
                XCTAssertTrue(r.owner.busy); XCTAssertTrue(r.owner.ownsSession); r.owner.start(); XCTAssertFalse(r.engine.isRunning)
                XCTAssertNotNil(h.undo.activeJob); leave?.signal()
            }
            await r.chain?.value; XCTAssertNil(h.undo.activeJob); XCTAssertEqual(h.undo.retainedAudioCount,0)
            XCTAssertFalse(h.undo.copyPreview(token:token)); h.undo.undo(token:token); XCTAssertEqual(r.native.calls.count,calls)
            r.native.decode = nil; await r.take("fresh guided"); XCTAssertEqual(r.owner.session?.candidate,"fresh guided")
            XCTAssertEqual(h.undo.view,.empty); XCTAssertTrue(r.memory.accesses.isEmpty); XCTAssertTrue(h.ordinary.isEmpty)
            r.owner.cancel(); XCTAssertEqual(h.undo.view,.empty); XCTAssertTrue(h.start()); r.engine.feed(); h.send(.cancelRequested(silent:true,reason:.shortRelease))
            XCTAssertNotNil(h.undo.view.token); h.undo.invalidate(); h.runtime.broker.quit(); try await r.close()
        }
    }
}


extension GuidedTemplateConnectedTests {
    @MainActor func testT13HeldASRAndStoppingRejectNativeKeyboardPresetMouseAndAuxiliaryOwners() async throws {
        for stopping in [false,true] {
            let r = try GuidedRig(), h = try GuidedOrdinaryControl(r)
            var saved = try r.store.savedRetrySnapshot(); saved.hotkeys.runSelectedPreset = KeyChord(17,[.ctrl,.opt]); saved.mouseBinding = .init(buttonNumber:2); try r.store.save(saved)
            let monitor = HotkeyMonitor(store:r.store,inputAuthority:h.host.inputAuthority,captureAdmission:r.admission,buttonState:{_ in .down})
            var keyEdges = 0; monitor.onEdge = {_ in keyEdges += 1}; monitor.deliversOnMain = true; monitor.enqueueOnMain = {$0()}; monitor.receiveTapStatus(.ready)
            XCTAssertTrue(monitor.receiveKeyDown(keyCode:17,modifiers:[.ctrl,.opt],at:100)); XCTAssertEqual(keyEdges,1)
            let entered = expectation(description:"shared ASR lane held"), exit = DispatchSemaphore(value:0)
            r.native.decode = {entered.fulfill(); exit.wait()}
            await r.begin(); r.owner.start(); r.engine.feed(); r.owner.stop(); await fulfillment(of:[entered],timeout:3)
            if stopping {r.owner.cancel()}
            let b55 = MicrophoneTestController(capture:RecorderMicrophoneCapture(recorder:r.recorder),admission:r.admission,allowed:{true},permission:{true},now:{r.clock.now},schedule:r.clock.schedule)
            XCTAssertFalse(monitor.receiveKeyDown(keyCode:17,modifiers:[.ctrl,.opt],at:101))
            XCTAssertFalse(monitor.receiveKeyDown(keyCode:49,modifiers:[.fn,.shift],at:102))
            XCTAssertFalse(monitor.receiveKeyDown(keyCode:36,modifiers:[],at:103)); XCTAssertEqual(keyEdges,1)
            XCTAssertFalse(h.host.keyboard(.startSavedPreset(settings:h.settings,cleanupConfigured:true,selection:"source",target:.init(focus:.editable))))
            XCTAssertFalse(h.start()); XCTAssertEqual(h.host.startAutomation(),.busy); XCTAssertFalse(h.host.beginTryout()); XCTAssertNil(h.host.beginShortcutRecording())
            b55.start(); XCTAssertFalse(b55.ownsSession)
            XCTAssertFalse(monitor.receiveMouseEvent(button:2,isDown:true,at:104)); XCTAssertFalse(monitor.receiveMouseEvent(button:2,isDown:false,at:105))
            XCTAssertTrue(r.owner.ownsSession); XCTAssertFalse(r.admission.isAvailable)
            r.owner.cancel(); exit.signal(); await r.chain?.value
            XCTAssertTrue(r.owner.readyForRestart); XCTAssertTrue(monitor.receiveKeyDown(keyCode:17,modifiers:[.ctrl,.opt],at:106)); XCTAssertEqual(keyEdges,2)
            r.native.decode = nil; h.runtime.broker.quit(); try await r.close()
        }
    }
}
