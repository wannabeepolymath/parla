import Foundation

/// An export allowlist, not a log. No free-form request, device, field, error,
/// endpoint or model strings can enter a record. Unknowns remain explicit.
public enum DiagnosticOrigin: String, Codable, Sendable {
    case unknown, dictation, dictatedPreset, spokenTransform, savedTransform, historyRetry, recovery, fileImport
}
public enum DiagnosticStage: String, Codable, CaseIterable, Sendable {
    case captureSetup, finalizationSetup, queueWait, acquisition, asr, cleanup, providerSetup, provider, providerRequest, delivery, previewAcquisition, previewASR, previewLifetime
}
public enum DiagnosticCaptureOutcome: String, Codable, Sendable {
    case unknown, receiving, signal, noMeaningfulSignal, minimumDuration, conversionFailure, captureFailure, deviceLost, canceled
}
public enum DiagnosticDeadline: String, Codable, Sendable { case unknown, pending, receivedInTime, noFirstPCM, endedBeforeDeadline }
public enum DiagnosticASR: String, Codable, Sendable { case unknown, confirmedWindow, text, empty, nilOrError, canceled, minimumDuration, silence }
public enum DiagnosticProviderOutcome: String, Codable, Sendable {
    case unknown, off, localSnippet, preparing, refused, credentialUnavailable, credentialDenied, credentialCanceled, attempted, returned, failed, canceled, invalidResult
}
public enum DiagnosticDelivery: String, Codable, Sendable { case notAttempted, withheld, refused, postedUnverified, axWriteUnverified, axConfirmed }
public enum DiagnosticReason: String, Codable, Sendable {
    case unknown, discarded, secure, staleGeneration, destinationChanged, selectionChanged, noDestination, modifiersHeld, resultUnavailable, previewOnly, acquisitionUnavailable, captureCanceled, supersededCapture
}
public enum DiagnosticRoute: String, Codable, Sendable { case unknown, builtIn, usb, bluetooth, virtual, aggregate, other }
public enum DiagnosticRouteEvidence: String, Codable, Sendable { case unknown, inputAudioUnit }
public enum DiagnosticProvider: String, Codable, Sendable { case unknown, anthropic, openAICompatible, appleIntelligence }

public enum DiagnosticASRModel: String, Codable, Sendable {
    case unavailable
    case parakeetINT4 = "parakeet-tdt-v3-int4"
    case baseEnglish = "base.en", smallEnglish = "small.en-q5_1", turbo = "large-v3-turbo-q5_0"
}
public enum DiagnosticProviderModel: String, Codable, Sendable {
    case unavailable
    case appleIntelligence = "Apple Intelligence · on-device"
    case haiku = "claude-haiku-4-5", sonnet = "claude-sonnet-5"
}

public struct DiagnosticTiming: Codable, Equatable, Sendable {
    public let stage: DiagnosticStage
    public var calls = 0
    public var active = 0
    public var totalMs: Double = 0
    public var firstStartMs: Double?
    public var lastEndMs: Double?
}
/// Additive optional schema-v1 evidence. No reader identity or content strings.
public struct DiagnosticClipboard: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case fixed, observableRequests, remoteExcluded }
    public enum End: String, Codable, Sendable {
        case baselineTimer, quietAfterObservableRequest, maximum, superseded, ownershipChanged
        case preparationRefused, publicationFailed, restoreFailed, shutdown
    }
    public enum Restore: String, Codable, Sendable { case pending, untouched, restored, skippedOwnershipChanged, failed }
    public enum Receipt: String, Codable, Sendable { case unknown, observed, noObservableReceipt }
    public let mode: Mode
    public let floorMs: Int, quietMs: Int, maximumMs: Int
    public internal(set) var requestedDelayMs: Double
    public internal(set) var requests = 0, ignored = 0, supplyFailures = 0
    public internal(set) var firstRequestMs: Double?, elapsedMs: Double = 0
    public internal(set) var end: End?
    public internal(set) var restore: Restore = .pending
    public internal(set) var receipt: Receipt = .unknown
    init(mode: ClipboardRestoreMode, delay: TimeInterval) {
        switch mode {
        case .fixed: self.mode = .fixed
        case .observableRequests: self.mode = .observableRequests
        case .remoteExcluded: self.mode = .remoteExcluded
        }
        floorMs = mode == .observableRequests ? 800 : 0
        quietMs = mode == .observableRequests ? 300 : 0
        maximumMs = mode == .observableRequests ? 8000 : 0
        requestedDelayMs = Self.milliseconds(mode == .observableRequests ? 8 : delay)
    }
    static func milliseconds(_ seconds: Double) -> Double {
        seconds.isFinite ? min(86_400_000, max(0, seconds * 1000)) : 0
    }
}
/// Finite recognition export: no identity keys, paths, versions, language codes or text.
public struct DiagnosticRecognition: Codable, Equatable, Sendable {
    public enum Evidence: String, Codable, Sendable { case admittedCatalog, customUnknown, systemUnknown, provisionalMixedMetadata }
    public enum Outcome: String, Codable, Sendable { case completed, failed, canceled }
    public enum Assembly: String, Codable, Sendable { case completedTail, failedTail, canceledTail, skippedTail }
    public var engine: RecognitionEngine = .whisper
    public var evidence: Evidence?
    public var modelLanguages: RecognitionCapabilities.ModelLanguages = .unknown
    public var sampleRate = 16_000
    public var nativeIncrementalStream = false
    public var cooperativeDecodeAbort = true
    public var cancellableConstruction = false
    public var wordTiming = false
    public var confidence = false
    public var alternatives = false
    public var nativeOutcome: Outcome?
    public var deliveryCanceled = false
    public var assembly: Assembly?
}
/// Preview facts never alter final recognition identity/outcome. No content or paths.
public struct DiagnosticPreview: Codable, Equatable, Sendable {
    public var model: DiagnosticASRModel = .unavailable
    public var status: RecognitionPreviewStatus = .loading
    public var requests = 0
    public var maximumSamples = 0
    public init(modelID: String) { model = DiagnosticASRModel(rawValue: modelID) ?? .unavailable }
}
public struct DiagnosticRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let origin: DiagnosticOrigin
    public var operationFinished = false
    public var cancellationRequested = false
    public var capture: DiagnosticCaptureOutcome = .unknown
    public var firstPCMDeadline: DiagnosticDeadline = .unknown
    public var captureStartedMs: Double?
    public var captureStoppedMs: Double?
    public var firstPCMMs: Double?
    public var route: DiagnosticRoute = .unknown
    public var routeEvidence: DiagnosticRouteEvidence = .unknown
    public var asr: DiagnosticASR = .unknown
    public var recognition: DiagnosticRecognition?
    public var preview: DiagnosticPreview?
    public var activityShadow: DiagnosticActivityShadow?
    public var cleanupFailover: CleanupFailoverEvidence?
    public var segmentedRetry: SegmentedRetrySummary?
    public var provider: DiagnosticProvider = .unknown
    public var providerOutcome: DiagnosticProviderOutcome = .unknown
    public var localGenerationAttempted: Bool?
    public var localCleanupReason: LocalCleanupReason?
    public var providerRequestAttempted = false
    public var delivery: DiagnosticDelivery = .notAttempted
    public var reason: DiagnosticReason = .unknown
    public var clipboard: DiagnosticClipboard?
    public var receiptObserved = false
    public var staleCompletion = false
    public var requestedASR: DiagnosticASRModel = .unavailable
    public var resolvedASR: DiagnosticASRModel = .unavailable
    public var frozenProviderModel: DiagnosticProviderModel = .unavailable
    public var requestedProviderModel: DiagnosticProviderModel = .unavailable
    public var resolvedProviderModel: DiagnosticProviderModel = .unavailable
    public var timings: [DiagnosticTiming] = []
}
public struct DiagnosticVersion: Encodable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    init(_ version: OperatingSystemVersion) {
        major = version.majorVersion; minor = version.minorVersion; patch = version.patchVersion
    }
    init?(_ ownVersion: String?) {
        guard let ownVersion else { return nil }
        let parts = ownVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]; minor = numbers.count > 1 ? numbers[1] : 0; patch = numbers.count > 2 ? numbers[2] : 0
    }
}

public struct DiagnosticSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let appVersion: DiagnosticVersion?
    public let osVersion: DiagnosticVersion
    public let records: [DiagnosticRecord]
    init(records: [DiagnosticRecord], appVersion: String?, osVersion: OperatingSystemVersion) {
        self.records = records; self.appVersion = DiagnosticVersion(appVersion); self.osVersion = DiagnosticVersion(osVersion)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Fixed collection bounds include in-flight work. Evicted/cleared callbacks
/// cannot reinsert themselves. Handles contain identity only, never a record.
public final class DiagnosticStore: @unchecked Sendable {
    public static let shared = DiagnosticStore()
    private struct Entry { let start: TimeInterval; var record: DiagnosticRecord }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let now: () -> TimeInterval
    private let appVersion: () -> String?
    private let osVersion: () -> OperatingSystemVersion
    public let countLimit: Int
    public let byteLimit: Int
    public init(countLimit: Int = 64, byteLimit: Int = 128 * 1024,
                now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                appVersion: @escaping () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String },
                osVersion: @escaping () -> OperatingSystemVersion = { ProcessInfo.processInfo.operatingSystemVersion }) {
        self.appVersion = appVersion; self.osVersion = osVersion
        self.countLimit = max(0, min(128, countLimit)); self.byteLimit = max(512, min(1024 * 1024, byteLimit)); self.now = now
    }
    public func start(id: UUID, origin: DiagnosticOrigin) -> DiagnosticOperation {
        lock.withLock {
            entries.append(Entry(start: now(), record: DiagnosticRecord(id: id, origin: origin)))
            prune()
        }
        return DiagnosticOperation(id: id, store: self)
    }
    public func clear() { lock.withLock { entries.removeAll(keepingCapacity: false) } }
    public func snapshot() -> DiagnosticSnapshot { lock.withLock { DiagnosticSnapshot(records: entries.map(\.record), appVersion: appVersion(), osVersion: osVersion()) } }
    fileprivate func time() -> TimeInterval { now() }
    fileprivate func update(_ id: UUID, _ change: (inout DiagnosticRecord, TimeInterval) -> Void) {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.record.id == id }) else { return }
            let start = entries[index].start
            change(&entries[index].record, start)
            prune()
        }
    }
    fileprivate func captureIncomplete(_ id: UUID) -> Bool {
        lock.withLock {
            guard let record = entries.first(where: { $0.record.id == id })?.record else { return false }
            return record.capture == .deviceLost || record.capture == .conversionFailure || record.capture == .captureFailure
        }
    }
    private func prune() {
        while entries.count > countLimit { entries.removeFirst() }
        // Encoding occurs only at stage/control boundaries, never on the tap.
        while !entries.isEmpty, ((try? DiagnosticSnapshot(records: entries.map(\.record), appVersion: appVersion(), osVersion: osVersion()).encoded().count) ?? Int.max) > byteLimit {
            entries.removeFirst()
        }
    }
}

public final class DiagnosticOperation: @unchecked Sendable {
    public let id: UUID
    private weak var store: DiagnosticStore?
    private let failoverIndex: Int?
    fileprivate init(id: UUID, store: DiagnosticStore, failoverIndex: Int? = nil) { self.id = id; self.store = store; self.failoverIndex = failoverIndex }
    func failoverAttempt(_ index: Int) -> DiagnosticOperation {
        guard let store else { return self }
        return DiagnosticOperation(id: id, store: store, failoverIndex: index)
    }
    public func update(_ change: (inout DiagnosticRecord) -> Void) { store?.update(id) { record, _ in change(&record) } }
    /// Existing owned scalar capture evidence only; no new recorder probe.
    public var activityShadowCaptureIncomplete: Bool {
        guard let store else { return false }
        return store.captureIncomplete(id)
    }
    public func begin(_ stage: DiagnosticStage) -> DiagnosticSpan {
        let time = store?.time() ?? 0
        store?.update(id) { record, start in
            if !record.timings.contains(where: { $0.stage == stage }) { record.timings.append(DiagnosticTiming(stage: stage)) }
            guard let i = record.timings.firstIndex(where: { $0.stage == stage }) else { return }
            record.timings[i].calls = min(1_000_000, record.timings[i].calls + 1)
            record.timings[i].active = min(1_000_000, record.timings[i].active + 1)
            if record.timings[i].firstStartMs == nil { record.timings[i].firstStartMs = Self.ms(time - start) }
        }
        return DiagnosticSpan(operation: self, stage: stage, start: time)
    }
    fileprivate func end(_ stage: DiagnosticStage, start: TimeInterval) {
        let time = store?.time() ?? start
        store?.update(id) { record, origin in
            guard let i = record.timings.firstIndex(where: { $0.stage == stage }) else { return }
            record.timings[i].active = max(0, record.timings[i].active - 1)
            record.timings[i].totalMs = record.timings[i].totalMs + Self.ms(time - start)
            record.timings[i].lastEndMs = Self.ms(time - origin)
        }
    }
    private static func ms(_ seconds: Double) -> Double { seconds.isFinite ? max(0, seconds * 1000) : 0 }
    public func recognition(request: RecognitionRequest, resolved: Bool = false) {
        // Filename match yields a catalog identifier only; never export the path.
        let catalog = (request.selection.engine == .whisper ? RecognitionFactory.ownedModel(path: request.modelPath) : nil).flatMap { DiagnosticASRModel(rawValue: $0.id) }
        update { if resolved { $0.resolvedASR = catalog ?? (request.selection.engine == .parakeet ? .parakeetINT4 : .unavailable) } else { $0.requestedASR = catalog ?? (request.selection.engine == .parakeet ? .parakeetINT4 : .unavailable) } }
    }
    public func recognition(identity: RecognitionIdentity, capabilities: RecognitionCapabilities) {
        update {
            var value = $0.recognition ?? DiagnosticRecognition()
            value.engine = identity.engine
            value.modelLanguages = capabilities.modelLanguages
            switch identity.artifact {
            case .admittedCatalog(let id, _, _):
                value.evidence = .admittedCatalog
                $0.resolvedASR = DiagnosticASRModel(rawValue: id) ?? .unavailable
            case .parakeet: value.evidence = .provisionalMixedMetadata; $0.resolvedASR = .parakeetINT4
            case .systemAssetsRevisionUnknown: value.evidence = .systemUnknown; $0.resolvedASR = .unavailable
            case .customRevisionUnknown: value.evidence = .customUnknown; $0.resolvedASR = .unavailable
            }
            $0.recognition = value
        }
    }
    public func recognitionOutcome(_ result: RecognitionPassResult) {
        update {
            var value = $0.recognition ?? DiagnosticRecognition()
            switch result.native {
            case .completed: value.nativeOutcome = .completed
            case .failed: value.nativeOutcome = .failed
            case .canceled: value.nativeOutcome = .canceled
            }
            value.deliveryCanceled = result.canceled; $0.recognition = value
        }
    }
    public func recognitionAssembly(tail: RecognitionPassResult?, skipped: RecognitionSkip?) {
        update {
            var value = $0.recognition ?? DiagnosticRecognition()
            if skipped != nil { value.assembly = .skippedTail }
            else if let tail {
                switch tail.native {
                case .completed: value.assembly = tail.canceled ? .canceledTail : .completedTail
                case .failed: value.assembly = .failedTail
                case .canceled: value.assembly = .canceledTail
                }
            }
            $0.recognition = value
        }
    }
    public func providerSettings(_ settings: Settings) {
        let provider: DiagnosticProvider
        switch settings.cleanup.provider {
        case "", "anthropic": provider = .anthropic
        case "openai-compatible": provider = .openAICompatible
        case "apple-intelligence": provider = .appleIntelligence
        default: provider = .unknown
        }
        let model = settings.usesAppleIntelligence ? settings.cleanupModelLabel : provider == .anthropic ? settings.cleanupModel : settings.cleanup.model
        update { $0.provider = provider; $0.frozenProviderModel = Self.catalogProviderModel(model) ?? .unavailable }
    }
    public func providerRequest() {
        update { $0.providerRequestAttempted = true; if failoverIndex == nil { $0.providerOutcome = .attempted } }
    }
    public func providerRequestModel(_ model: String) {
        guard failoverIndex == nil else { return }
        update { $0.requestedProviderModel = Self.catalogProviderModel(model) ?? .unavailable }
    }
    public func providerModel(_ model: String?) {
        update {
            if let index = failoverIndex, index < ($0.cleanupFailover?.attempts.count ?? 0) {
                $0.cleanupFailover?.attempts[index].resolved = Self.catalogProviderModel(model) ?? .unavailable
            } else { $0.resolvedProviderModel = Self.catalogProviderModel(model) ?? .unavailable }
        }
    }
    private static func catalogProviderModel(_ model: String?) -> DiagnosticProviderModel? {
        // Deliberately finite: syntactically harmless custom identifiers can be private.
        model.flatMap(DiagnosticProviderModel.init(rawValue:))
    }
    public func disposition(_ reason: DiagnosticReason, delivery: DiagnosticDelivery = .withheld) {
        update { record in
            if record.reason == .unknown || (record.reason != .discarded && record.reason != .captureCanceled && record.reason != .secure && record.reason != .destinationChanged && record.reason != .modifiersHeld) { record.reason = reason }
            if record.delivery != .postedUnverified && record.delivery != .axWriteUnverified && record.delivery != .axConfirmed { record.delivery = delivery }
        }
    }
    public func receipt() { update { $0.receiptObserved = true } } // never promotes delivery
    public func observeCapture(_ facts: CaptureDiagnosticState, deadline: Bool = false, stopped: Bool = false) {
        guard facts.operationID == id else { return }
        store?.update(id) { record, start in
            record.captureStartedMs = Self.ms(facts.started - start)
            if stopped { record.captureStoppedMs = Self.ms((store?.time() ?? facts.started) - start) }
            if let first = facts.firstPCM { record.firstPCMMs = Self.ms(first - start) }
            record.route = facts.route; record.routeEvidence = facts.routeEvidence
            if let first = facts.firstPCM, first <= facts.started + CaptureDiagnosticState.firstPCMDeadline {
                record.firstPCMDeadline = .receivedInTime
            } else if deadline || (facts.firstPCM.map { $0 > facts.started + CaptureDiagnosticState.firstPCMDeadline } == true) {
                record.firstPCMDeadline = .noFirstPCM
            } else if stopped {
                record.firstPCMDeadline = (store?.time() ?? facts.started) >= facts.started + CaptureDiagnosticState.firstPCMDeadline ? .noFirstPCM : .endedBeforeDeadline
            }
            else { record.firstPCMDeadline = .pending }
            if record.capture != .canceled && record.capture != .captureFailure { record.capture = facts.outcome }
        }
    }
    /// Setup refusal and request attempt are different boundaries. Errors are
    /// classified by type; descriptions never participate in the export.
    public func providerRefusal(_ error: Error) {
        update {
            if let credential = error as? CredentialFailure {
                $0.providerOutcome = credential.status == .denied ? .credentialDenied : credential.status == .canceled ? .credentialCanceled : .credentialUnavailable
            } else { $0.providerOutcome = error is CancellationError ? .canceled : .refused }
        }
    }
    public func makeProvider(settings: Settings, factory: () throws -> CleanupProviding) throws -> CleanupProviding {
        providerSettings(settings)
        let span = begin(.providerSetup); defer { span.end() }
        update { $0.providerOutcome = .preparing }
        do {
            let base = try factory()
            let transport = base as? DiagnosticModelObserving
            return ObservedDiagnosticProvider(base: transport?.observing(self) ?? base, operation: self, observesTransport: transport != nil)
        }
        catch {
            providerRefusal(error)
            throw error
        }
    }
}
public final class DiagnosticSpan {
    private let operation: DiagnosticOperation
    private let stage: DiagnosticStage
    private let start: TimeInterval
    private let lock = NSLock()
    private var ended = false
    fileprivate init(operation: DiagnosticOperation, stage: DiagnosticStage, start: TimeInterval) {
        self.operation = operation; self.stage = stage; self.start = start
    }
    public func end() {
        let finish = lock.withLock { if ended { return false }; ended = true; return true }
        if finish { operation.end(stage, start: start) }
    }
}
private struct ObservedDiagnosticProvider: CleanupProviding {
    let base: CleanupProviding
    let operation: DiagnosticOperation
    let observesTransport: Bool
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        let span = operation.begin(.provider); defer { span.end() }
        if !observesTransport { operation.providerRequest() }
        do {
            let text = try await base.clean(transcript: transcript, context: context)
            operation.update { $0.providerOutcome = Task.isCancelled ? .canceled : .returned }
            return text
        } catch {
            operation.update {
                if error is CancellationError || Task.isCancelled { $0.providerOutcome = .canceled }
                else if $0.providerOutcome != .refused { $0.providerOutcome = $0.providerRequestAttempted ? .failed : .refused }
            }
            throw error
        }
    }
}

/// Scalar tap facts, copied under the recorder's existing lock. No audio is
/// retained here, and a bounded deadline observation never stops the capture.
public struct CaptureDiagnosticState: Sendable {
    public static let firstPCMDeadline: TimeInterval = 2
    public let operationID: UUID
    public let started: TimeInterval
    public private(set) var firstPCM: TimeInterval?
    public var route: DiagnosticRoute = .unknown
    public var routeEvidence: DiagnosticRouteEvidence = .unknown
    public private(set) var outcome: DiagnosticCaptureOutcome = .receiving
    private var conversionFailed = false
    public init(operationID: UUID, started: TimeInterval) { self.operationID = operationID; self.started = started }
    public mutating func input(hasPCM: Bool, conversionFailed: Bool, now: TimeInterval) {
        // A warm callback can begin before start and finish conversion after it.
        // That chunk may join existing capture policy, but is not new live PCM.
        if hasPCM && now >= started && firstPCM == nil { firstPCM = now }
        self.conversionFailed = self.conversionFailed || conversionFailed
    }
    public mutating func stop(sampleCount: Int, rms: Float, deviceLost: Bool = false) {
        if deviceLost { outcome = .deviceLost }
        else if conversionFailed { outcome = .conversionFailure }
        else if sampleCount < 6400 { outcome = .minimumDuration }
        else if rms < 1e-4 { outcome = .noMeaningfulSignal }
        else { outcome = .signal }
    }
}

/// The Bool contract is preserved: true means posting, never acceptance. This
/// seam also lets tests drive the actual dispatch evidence without native I/O.
public enum DiagnosticDispatch {
    public static func paste(diagnostics: DiagnosticOperation?, attempt: () -> Bool) -> Bool {
        let span = diagnostics?.begin(.delivery); defer { span?.end() }
        let posted = attempt()
        diagnostics?.update { $0.delivery = posted ? .postedUnverified : .refused }
        return posted
    }
    public static func eventsPosted(_ posted: Bool, diagnostics: DiagnosticOperation?) {
        diagnostics?.update {
            if posted { $0.delivery = .postedUnverified }
            else if $0.delivery != .postedUnverified && $0.delivery != .axWriteUnverified && $0.delivery != .axConfirmed { $0.delivery = .refused }
        }
    }
    public static func replacement(_ result: Inserter.TailSwap, diagnostics: DiagnosticOperation?) {
        diagnostics?.update { record in
            switch result {
            case .replaced: record.delivery = .axConfirmed
            case .unverified: record.delivery = .axWriteUnverified
            case .unavailable: break // no write; caller may post fallback events
            }
        }
    }
}

// Only provider adapters that see the real request/response model can populate
// these fields. Legacy usage callbacks may substitute the requested model.
protocol DiagnosticModelObserving {
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding
}
extension CleanupClient: DiagnosticModelObserving {
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding { var copy = self; copy.diagnostics = diagnostics; return copy }
}
extension OpenAICompatClient: DiagnosticModelObserving {
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding { var copy = self; copy.diagnostics = diagnostics; return copy }
}

/// Exact awaited transport interval, separate from provider setup, prompt
/// preparation, discovery and result validation. Request contents are not stored.
func diagnosticPost(_ request: URLRequest, using http: HTTPPosting, diagnostics: DiagnosticOperation?) async throws -> (Data, URLResponse) {
    let span = diagnostics?.begin(.providerRequest); defer { span?.end() }
    diagnostics?.providerRequest()
    return try await http.post(request)
}
