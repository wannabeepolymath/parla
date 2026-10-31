import Foundation
import ParlaCore

/// Documentary existing-schema facts. Empty/zero/false missing facts are unspecified,
/// never catalog attestation, detected language, no-hints evidence or device evidence.
@MainActor final class MeetingRecognitionExecution {
    final class Authority: @unchecked Sendable {
        private let lock = NSLock(); private var valid = true
        func revoke() { lock.withLock { valid = false } }
        var current: Bool { lock.withLock { valid } }
    }
    struct Context {
        let session: UUID, chunk: UUID, generation: UInt64, intent: UUID
        let configuration: AudioImportOwner.Configuration, selectionEpoch: UUID, preparationEpoch: UUID?
        let authority: Authority
        let authorize: () -> Bool
        var current: Bool { authority.current && authorize() }
    }
    final class Job: @unchecked Sendable {
        let operation: PendingOperation, bytes: Data, context: Context, requested: MeetingSession.Provenance
        private let lock = NSLock()
        private var result: Result<(Data,RecognitionIdentity?),Error> = .failure(CancellationError())
        init(bytes: Data,context: Context,requested: MeetingSession.Provenance,diagnostics: DiagnosticStore) {
            self.bytes = bytes; self.context = context; self.requested = requested
            operation = PendingOperation(name:"Meeting transcription",origin:.fileImport,diagnostics:diagnostics)
            operation.diagnostics?.recognition(request:context.configuration.request)
            operation.diagnostics?.disposition(.previewOnly,delivery:.notAttempted)
        }
        func revoke() { context.authority.revoke(); operation.revoke(); operation.requestAbort() }
        func put(_ value: Result<(Data,RecognitionIdentity?),Error>) { lock.withLock { result = value } }
        func take() -> Result<(Data,RecognitionIdentity?),Error> { lock.withLock { result } }
    }
    typealias Enqueue = (Job) -> Task<Void,Never>?
    private var enqueue: Enqueue?, diagnostics: DiagnosticStore?
    private var context: Context?, requested: MeetingSession.Provenance?, job: Job?
    private var consumerExit: Task<Result<MeetingSessionOwner.RawResult,Error>,Never>?
    private var rows: [MeetingSession.Provenance] = []
    func bind(enqueue: @escaping Enqueue,diagnostics: DiagnosticStore) { self.enqueue = enqueue; self.diagnostics = diagnostics }
    func prime(_ registry: [MeetingSession.Provenance]) throws {
        guard consumerExit == nil,registry.count <= 32,Set(registry.map(\.id)).count == registry.count else { throw MeetingSession.Failure.held }
        rows = registry
    }
    private static func tuple(_ row: MeetingSession.Provenance,id: UUID,generation: UInt64) throws -> MeetingSession.Provenance {
        try .init(id:id,generation:generation,role:row.role,engine:row.engine,artifact:row.artifact,catalogID:row.catalogID,language:row.language,
            model:row.model,filter:row.filter,nativeVersion:row.nativeVersion,buildScope:row.buildScope,systemScope:row.systemScope,
            verification:row.verification,computeScope:row.computeScope,digest:row.digest,helperDigest:row.helperDigest,releaseDigest:row.releaseDigest,
            sdkRevision:row.sdkRevision,modelRevision:row.modelRevision,expectedBytes:row.expectedBytes,fileGeneration:nil,adapter:row.adapter,compute:row.compute,hints:row.hints)
    }
    private func intern(_ row: MeetingSession.Provenance) throws -> MeetingSession.Provenance {
        for existing in rows where try Self.tuple(row,id:existing.id,generation:existing.generation) == existing { return existing }
        guard rows.count < 32 else { throw MeetingSession.Failure.bounds }
        rows.append(row); return row // tentative until the store accepts; next action re-primes from metadata
    }
    func prepare(_ context: Context) throws -> MeetingSession.Provenance {
        guard consumerExit == nil,context.current else { throw MeetingSession.Failure.held }
        let row = try intern(Self.requestedProvenance(request:context.configuration.request,id:UUID(),generation:1))
        self.context = context; requested = row; return row
    }
    var port: MeetingSessionOwner.RecognitionPort {
        .init(run:{[self] in run($0,requested:$1)},requestCancel:{[self] in requestCancel()})
    }
    private func run(_ bytes: Data,requested: MeetingSession.Provenance) -> Task<Result<MeetingSessionOwner.RawResult,Error>,Never> {
        guard consumerExit == nil,let context,context.current,self.requested == requested,let enqueue,let diagnostics else {
            return Task { .failure(MeetingSession.Failure.stale) }
        }
        let job = Job(bytes:bytes,context:context,requested:requested,diagnostics:diagnostics); self.job = job
        guard let queued = enqueue(job) else { job.revoke(); self.job = nil; return Task { .failure(CancellationError()) } }
        let exit = Task { @MainActor [self] () -> Result<MeetingSessionOwner.RawResult,Error> in
            await queued.value // includes actual child return, operation.finish and local admission.exited
            do {
                guard job.context.current,!job.operation.shouldAbort else { throw CancellationError() }
                let (bytes,identity) = try job.take().get()
                let observed = try intern(Self.observedProvenance(identity:identity,id:UUID(),generation:1))
                return .success(try .init(bytes:bytes,observed:observed))
            } catch { return .failure(error) }
        }
        consumerExit = exit; return exit
    }
    /// Called only after owner.transcribe joined the exact consumer and its storage cleanup.
    func settled() async {
        if let consumerExit { _ = await consumerExit.value }
        consumerExit = nil; job = nil; context = nil; requested = nil
    }
    func requestCancel() { context?.authority.revoke(); job?.revoke() }
    static func enqueue(previous: Task<Void,Never>?,admission: LocalCleanupAdmission,job: Job,settings: SettingsStore,
        enter: @escaping () async throws -> Void,load: @escaping (RecognitionRequest) async throws -> RecognitionHandle) -> Task<Void,Never>? {
        guard job.context.current,admission.admit(job.operation) else { job.revoke(); job.operation.finish(); return nil }
        return PendingOperationQueue.enqueue(previous:previous,operation:job.operation,completes:true,work:{
            await execute(job,settings:settings,enter:enter,load:load)
        },finished:{ await MainActor.run { admission.exited(job.operation) } })
    }
    nonisolated static func execute(_ job: Job,settings: SettingsStore,enter: @escaping () async throws -> Void,
        load: @escaping (RecognitionRequest) async throws -> RecognitionHandle) async {
        do {
            let current = { job.context.authority.current && !job.operation.shouldAbort }
            let authorize = { current() && (try? AudioImportOwner.Configuration(settings.savedRetrySnapshot())) == job.context.configuration }
            guard authorize() else { throw CancellationError() }
            let result = try await FileRecognitionBatch.runResult(request:job.context.configuration.request,operation:job.operation,
                samples:{ try ImportedAudio.decode(job.bytes,canceled:{!current()}).samples },
                validate:{ guard authorize(),awaitAuthority(job) else { throw CancellationError() } },active:current,authorize:authorize,
                rawOnly:true,timed:false,enter:enter,load:load)
            guard authorize(),result.raw.utf8.count <= 65_536 else { throw MeetingSession.Failure.bounds }
            job.put(.success((Data(result.raw.utf8),result.observedIdentity)))
        } catch { job.put(.failure(error)) }
    }
    nonisolated private static func awaitAuthority(_ job: Job) -> Bool { job.context.authority.current }
    /// Only already-admitted actual facts enter these rows. No private path is persisted.
    static func requestedProvenance(request: RecognitionRequest,id: UUID,generation: UInt64) throws -> MeetingSession.Provenance {
        var engine = MeetingSession.Provenance.Engine.unknown, language = request.language ?? "",model = "",filter = "",hints = false
        switch request.selection {
        case .whisper: engine = .whisper; hints = !request.dictionary.isEmpty
        case .appleSpeech(let locale): engine = .appleSpeech; language = locale
        case .parakeet(let selected,let selectedFilter): engine = .parakeet; model = selected; filter = selectedFilter ?? ""
        case .invalid: throw MeetingSession.Failure.schema
        }
        return try row(id:id,generation:generation,role:.requested,engine:engine,language:language,model:model,filter:filter,hints:hints)
    }
    static func observedProvenance(identity: RecognitionIdentity?,id: UUID,generation: UInt64) throws -> MeetingSession.Provenance {
        guard let identity else { return try row(id:id,generation:generation,role:.observed,engine:.unknown) }
        guard identity.engine != .invalid,identity.engine == identity.selection.engine else { throw MeetingSession.Failure.schema }
        var engine = MeetingSession.Provenance.Engine.unknown, artifact = MeetingSession.Provenance.Artifact.unknown
        var language = "",model = "",filter = "",catalog = "",digest = "",expected: UInt64 = 0
        switch (identity.selection,identity.artifact) {
        case (.whisper,.admittedCatalog(let id,let hash,let bytes)):
            guard let count = UInt64(exactly:bytes) else { throw MeetingSession.Failure.schema }; engine = .whisper; catalog = id; digest = hash; expected = count
        case (.whisper,.customRevisionUnknown): engine = .whisper; artifact = .customUnknown
        case (.appleSpeech(let locale),.systemAssetsRevisionUnknown): engine = .appleSpeech; artifact = .systemUnknown; language = locale
        case (.parakeet(let selected,let selectedFilter),.parakeet): engine = .parakeet; model = selected; filter = selectedFilter ?? ""
        default: throw MeetingSession.Failure.schema
        }
        guard let adapter = UInt64(exactly:identity.runtime?.adapterRevision ?? 0),let compute = UInt64(exactly:identity.runtime?.compute.defaultsRevision ?? 0) else { throw MeetingSession.Failure.schema }
        return try row(id:id,generation:generation,role:.observed,engine:engine,artifact:artifact,language:language,model:model,filter:filter,
            hints:false,catalog:catalog,digest:digest,expected:expected,native:identity.runtime?.nativeVersion ?? "",build:identity.runtime?.buildScope ?? "",adapter:adapter,compute:compute)
    }
    private static func row(id: UUID,generation: UInt64,role: MeetingSession.Provenance.Role,engine: MeetingSession.Provenance.Engine,
        artifact: MeetingSession.Provenance.Artifact = .unknown,language: String = "",model: String = "",filter: String = "",hints: Bool = false,
        catalog: String = "",digest: String = "",expected: UInt64 = 0,native: String = "",build: String = "",adapter: UInt64 = 0,compute: UInt64 = 0) throws -> MeetingSession.Provenance {
        try .init(id:id,generation:generation,role:role,engine:engine,artifact:artifact,catalogID:catalog,language:language,model:model,filter:filter,
            nativeVersion:native,buildScope:build,systemScope:"",verification:"",computeScope:"",digest:digest,helperDigest:"",releaseDigest:"",sdkRevision:"",modelRevision:"",
            expectedBytes:expected,fileGeneration:nil,adapter:adapter,compute:compute,hints:hints)
    }
}
