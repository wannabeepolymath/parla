import Foundation

public enum RecognitionAdmission { case standard, readOnlyCatalog }

/// The single production factory. Only the native constructor beneath Whisper is replaceable.
public struct RecognitionFactory {
    public var parakeetPreparedUse: (RecognitionSelection, PendingOperation?) async throws -> ParakeetInstallationLease
    public var parakeetTrust: ParakeetTrustBottom
    public var parakeetApp: URL
    public var parakeetWorker: ParakeetWorker
    public var appleBottom: AppleSpeechBottom
    public var appleClock: AppleSpeechClock
    public var appleInstalledUse: (String, PendingOperation?) async throws -> AppleSpeechLease
    public var native: (String, WhisperComputeConfiguration) throws -> WhisperNativeContext
    public var guardedNative: (String, WhisperComputeConfiguration, PreparationPermit) throws -> WhisperNativeContext
    public var preparation: RecognitionPreparation?
    public var preparationPermission: (() -> Bool)?
    public var runtime: () -> RecognitionRuntime
    public var metadata: (String) -> RecognitionFileGeneration?
    public var directory: URL
    public var catalog: [ModelCatalog.Model]
    public var admit: (String, RecognitionAdmission) throws -> Void

    public init(parakeetPreparedUse: @escaping (RecognitionSelection, PendingOperation?) async throws -> ParakeetInstallationLease = { _, _ in throw ParakeetRefusal.needsPreparation },
                parakeetTrust: ParakeetTrustBottom = .system,
                parakeetApp: URL = Bundle.main.bundleURL,
                parakeetWorker: ParakeetWorker = ParakeetWorker(),
                appleBottom: AppleSpeechBottom = AppleSpeechNative.bottom,
                appleClock: AppleSpeechClock = AppleSpeechClock(),
                appleInstalledUse: @escaping (String, PendingOperation?) async throws -> AppleSpeechLease = { _, _ in throw AppleSpeechRefusal.needsPreparation },
                native: @escaping (String, WhisperComputeConfiguration) throws -> WhisperNativeContext = { try WhisperCContext($0, $1) },
                guardedNative: @escaping (String, WhisperComputeConfiguration, PreparationPermit) throws -> WhisperNativeContext = { try WhisperCContext($0, $1, preparation: $2) },
                preparation: RecognitionPreparation? = nil,
                preparationPermission: (() -> Bool)? = nil,
                runtime: @escaping () -> RecognitionRuntime = { WhisperCContext.runtime },
                metadata: @escaping (String) -> RecognitionFileGeneration? = RecognitionFileGeneration.observe,
                directory: URL = ModelCatalog.directory, catalog: [ModelCatalog.Model] = ModelCatalog.all,
                admit: @escaping (String, RecognitionAdmission) throws -> Void = { try RecognitionFactory.admitInstalled($0, $1) }) {
        self.parakeetPreparedUse = parakeetPreparedUse; self.parakeetTrust = parakeetTrust
        self.parakeetApp = parakeetApp; self.parakeetWorker = parakeetWorker
        self.appleBottom = appleBottom; self.appleClock = appleClock; self.appleInstalledUse = appleInstalledUse
        self.native = native; self.runtime = runtime; self.metadata = metadata
        self.guardedNative = guardedNative; self.preparation = preparation
        self.preparationPermission = preparationPermission
        self.directory = directory; self.catalog = catalog; self.admit = admit
    }
    public static func ownedModel(path: String, directory: URL = ModelCatalog.directory,
                                  catalog: [ModelCatalog.Model] = ModelCatalog.all) -> ModelCatalog.Model? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        return catalog.first { $0.filename == url.lastPathComponent }
    }
    public static func admitInstalled(_ path: String, _ policy: RecognitionAdmission,
                                      directory: URL = ModelCatalog.directory,
                                      catalog: [ModelCatalog.Model] = ModelCatalog.all,
                                      cache: VerifiedCache? = nil) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw TranscriberError(description: "Speech model unavailable") }
        switch policy {
        case .standard:
            if let bad = ModelCatalog.verifyInstalled(path: path) { throw bad }
        case .readOnlyCatalog:
            guard let model = ownedModel(path: path, directory: directory, catalog: catalog),
                  RecognitionFileGeneration.observe(path)?.bytes == model.bytes,
                  (cache ?? VerifiedCache()).isVerified(URL(fileURLWithPath: path)) else {
                throw TranscriberError(description: "Verified catalog model unavailable")
            }
        }
    }
    public func resolve(_ request: RecognitionRequest, policy: RecognitionAdmission = .standard) throws -> RecognitionIdentity {
        guard request.selection.engine == .whisper else { throw AppleSpeechRefusal.configuration }
        try admit(request.modelPath, policy)
        let model = Self.ownedModel(path: request.modelPath, directory: directory, catalog: catalog)
        if policy == .readOnlyCatalog, model == nil { throw TranscriberError(description: "Catalog selection required") }
        let generation = metadata(request.modelPath)
        let artifact: RecognitionArtifact = model.map { .admittedCatalog(id: $0.id, expectedSHA256: $0.sha256, expectedBytes: $0.bytes) } ?? .customRevisionUnknown
        return RecognitionIdentity(engine: request.selection.engine, selection: request.selection, artifact: artifact,
            generation: generation, runtime: runtime(), unknownRevisionScope: model == nil || generation == nil ? UUID() : nil)
    }
    public func acquire(request: RecognitionRequest, resident: RecognitionResident? = nil,
                        policy: RecognitionAdmission = .standard, shouldAbort: (() -> Bool)? = nil,
                        diagnostics: DiagnosticOperation? = nil, capture: UUID = UUID(),
                        operation: PendingOperation? = nil, selectionEpoch: UUID? = nil, preparationEpoch: UUID? = nil) async throws -> RecognitionHandle {
        let span = diagnostics?.begin(.acquisition); defer { span?.end() }
        diagnostics?.recognition(request: request)
        guard shouldAbort?() != true else { throw CancellationError() }
        switch request.selection {
        case .invalid: throw AppleSpeechRefusal.configuration
        case .appleSpeech(let locale):
            guard policy == .standard else { throw AppleSpeechRefusal.configuration }
            try appleBottom.available()
            let lease = try await appleInstalledUse(locale, operation)
            guard shouldAbort?() != true else { throw CancellationError() }
            let identity = RecognitionIdentity(engine: .appleSpeech, selection: request.selection, artifact: .systemAssetsRevisionUnknown,
                generation: nil, runtime: nil, unknownRevisionScope: UUID())
            let client = AppleSpeechRecognition(locale: locale, bottom: appleBottom, clock: appleClock, operation: operation, preparedLease: lease, installedUse: { try await appleInstalledUse($0, operation) })
            let owner = RecognitionResident(request: request, identity: identity, instance: UUID(), client: client)
            diagnostics?.recognition(identity: identity, capabilities: client.capabilities)
            return RecognitionHandle(owner: owner, capture: capture)
        case .parakeet(_, let filter):
            guard policy == .standard else { throw ParakeetRefusal.configuration }
            let lease = try await parakeetPreparedUse(request.selection, operation)
            guard lease.isCurrent, shouldAbort?() != true, !Task.isCancelled else { throw CancellationError() }
            let product = try ParakeetTrust.admit(expected: lease.product, app: parakeetApp, bottom: parakeetTrust)
            guard lease.isCurrent, shouldAbort?() != true, !Task.isCancelled else { throw CancellationError() }
            let client = try ParakeetRecognition(lease: lease, product: product, filter: filter, worker: parakeetWorker)
            let identity = RecognitionIdentity(engine: .parakeet, selection: request.selection, artifact: .parakeet(client.wireIdentity),
                generation: nil, runtime: nil, unknownRevisionScope: client.wireIdentity.session)
            let owner = RecognitionResident(request: request, identity: identity, instance: UUID(), client: client)
            diagnostics?.recognition(identity: identity, capabilities: client.capabilities)
            return RecognitionHandle(owner: owner, capture: capture)
        case .whisper: break
        }
        let identity = try resolve(request, policy: policy) // admission always precedes borrowing
        if preparationPermission?() == false {
            preparation?.revokeDraft()
            throw PreparationRefusal.consentRequired
        }
        guard shouldAbort?() != true else { throw CancellationError() }
        let permit = try preparation?.authorize(identity: identity, policy: policy, resident: resident, operation: operation,
            selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
        guard let runtime = identity.runtime else { throw AppleSpeechRefusal.configuration }
        let owner: RecognitionResident
        if identity.reusable, let resident, resident.identity == identity, resident.request == request,
           permit?.canBorrow(resident.preparation) ?? true {
            owner = resident
        } else {
            if permit != nil, policy == .readOnlyCatalog { throw PreparationRefusal.preparedResidentRequired }
            let client = try WhisperTranscriber(modelPath: request.modelPath, language: request.language,
                native: permit.map { try guardedNative(request.modelPath, runtime.compute, $0) }
                    ?? native(request.modelPath, runtime.compute))
            // Native construction is not cancellable. Its owner stays alive until it actually returns.
            guard metadata(request.modelPath) == identity.generation else { throw TranscriberError(description: "Local model changed during acquisition") }
            guard shouldAbort?() != true else { throw CancellationError() }
            owner = RecognitionResident(request: request, identity: identity, instance: UUID(), client: client)
            try permit?.constructed(owner.preparation)
        }
        try permit?.validate()
        let handle = RecognitionHandle(owner: owner, capture: capture, preparation: permit)
        diagnostics?.recognition(identity: identity, capabilities: owner.capabilities)
        return handle
    }
}

/// The executable uses this exact core entry. Offline branches never call acquire.
public final class EvalRecognition {
    private var handle: RecognitionHandle?
    public init() {}
    public func acquire(needsASR: Bool, request: () -> RecognitionRequest,
                        factory: RecognitionFactory = RecognitionFactory()) async throws {
        guard needsASR else { return }
        handle = try await factory.acquire(request: request())
    }
    public func transcribe(_ samples: [Float], prompt: String?) async -> String? {
        await handle?.recognize(samples, pass: .fullFinal, initialPrompt: prompt).text
    }
    public func release() { handle = nil }
}
