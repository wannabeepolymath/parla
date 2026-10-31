import Foundation

public enum RecognitionEngine: String, Codable, CaseIterable, Sendable {
    case whisper, appleSpeech, parakeet, invalid
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = (try? c.decode(String.self)).flatMap(Self.init(rawValue:)) ?? .invalid
    }
}
public enum RecognitionSelection: Equatable, Sendable {
    case whisper(localPath: String)
    case appleSpeech(locale: String)
    case parakeet(model: String, filter: String?)
    case invalid
    public var modelPath: String? { if case .whisper(let path) = self { return path }; return nil }
    public var engine: RecognitionEngine {
        switch self { case .whisper: return .whisper; case .appleSpeech: return .appleSpeech; case .parakeet: return .parakeet; case .invalid: return .invalid }
    }
}

/// Observed filesystem generation, not a content digest or attestation.
public struct RecognitionFileGeneration: Equatable, Codable, Hashable, Sendable {
    public let bytes: Int64
    public let modified: TimeInterval
    public let changed: TimeInterval?
    public let fileNumber: UInt64?
    public init(bytes: Int64, modified: TimeInterval, changed: TimeInterval? = nil, fileNumber: UInt64? = nil) {
        self.bytes = bytes; self.modified = modified; self.changed = changed; self.fileNumber = fileNumber
    }
    public static func observe(_ path: String) -> Self? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let bytes = attrs[.size] as? Int64, let date = attrs[.modificationDate] as? Date else { return nil }
        return Self(bytes: bytes, modified: date.timeIntervalSince1970, fileNumber: attrs[.systemFileNumber] as? UInt64)
    }
}
public enum RecognitionArtifact: Equatable, Sendable {
    /// Existing catalog admission policy accepted this expected pin. Freshness remains metadata only.
    case admittedCatalog(id: String, expectedSHA256: String, expectedBytes: Int64)
    case customRevisionUnknown
    case systemAssetsRevisionUnknown
    case parakeet(ParakeetWire.Identity)
}
public struct RecognitionRuntime: Equatable, Sendable {
    public let nativeVersion: String
    public let buildScope: String
    public let adapterRevision: Int
    public let compute: WhisperComputeConfiguration
    public init(nativeVersion: String, buildScope: String, adapterRevision: Int = 1,
                compute: WhisperComputeConfiguration = .nativeDefaults) {
        self.nativeVersion = nativeVersion; self.buildScope = buildScope
        self.adapterRevision = adapterRevision; self.compute = compute
    }
}
/// Requested native defaults; this makes no claim about the device actually used.
public struct WhisperComputeConfiguration: Equatable, Sendable {
    public let defaultsRevision: Int
    public init(defaultsRevision: Int) { self.defaultsRevision = defaultsRevision }
    public static let nativeDefaults = Self(defaultsRevision: 1)
}
public struct RecognitionIdentity: Equatable, Sendable {
    public let engine: RecognitionEngine
    public let selection: RecognitionSelection
    public let artifact: RecognitionArtifact
    public let generation: RecognitionFileGeneration?
    public let runtime: RecognitionRuntime?
    /// Unversioned artifacts cannot authorize reuse between acquisitions.
    public let unknownRevisionScope: UUID?
    public var reusable: Bool {
        if case .admittedCatalog = artifact { return generation != nil && unknownRevisionScope == nil }
        return false
    }
}
public struct RecognitionCapabilities: Equatable, Sendable {
    public enum ModelLanguages: String, Codable, Sendable { case unknown, englishOnly, multilingual, fixedLocale }
    public let modelLanguages: ModelLanguages
    public let sampleRate = 16_000
    public let channels = 1
    public let float32 = true
    public let batchDecode = true
    public let manualTextPrompt: Bool
    public let shadowWindows: Bool
    public let automaticLanguage: Bool
    public let cooperativeDecodeAbort = true
    public let cancellableConstruction = false
    public let nativeIncrementalStream = false
    public let acousticEnrollment = false
    public let wordTiming = false
    public let confidence = false
    public let alternatives = false
    public init(modelLanguages: ModelLanguages = .unknown, manualTextPrompt: Bool = true, shadowWindows: Bool = true, automaticLanguage: Bool = true) {
        self.modelLanguages = modelLanguages; self.manualTextPrompt = manualTextPrompt
        self.shadowWindows = shadowWindows; self.automaticLanguage = automaticLanguage
    }
    public static let parakeet = Self(modelLanguages: .multilingual, manualTextPrompt: false, shadowWindows: false, automaticLanguage: false)
    public static let appleSpeech = Self(modelLanguages: .fixedLocale, manualTextPrompt: false, shadowWindows: false, automaticLanguage: false)
}

public enum RecognitionFailure: String, Codable, Sendable { case nativeDecode, clientUnavailable, preparationUnavailable, unsupportedCapability, appleSpeech, parakeet, deadline }
public enum RecognitionSkip: String, Codable, Sendable { case minimumDuration, silence }
public struct RecognitionPayload: Equatable, Sendable {
    public let text: String
    /// Only native auto-detection evidence, never a requested/guessed language.
    public let detectedLanguage: String?
    public let requestedLocale: String?
    public let resolvedLocale: String?
    public let segments: RecognitionSegments?
    public init(text: String, detectedLanguage: String? = nil, requestedLocale: String? = nil, resolvedLocale: String? = nil,
                segments: RecognitionSegments? = nil) {
        self.text = text; self.detectedLanguage = detectedLanguage; self.requestedLocale = requestedLocale; self.resolvedLocale = resolvedLocale
        self.segments = segments
    }
}
public enum RecognitionNativeOutcome: Equatable, Sendable {
    case completed(RecognitionPayload), failed(RecognitionFailure), canceled
    public var text: String? { if case .completed(let payload) = self { return payload.text }; return nil }
}
public enum RecognitionPassKind: String, Sendable { case streamHead, streamTail, windowedFinal, fullFinal, command, warmup, hudPreview }
public struct RecognitionPassResult: Equatable, Sendable {
    public let identity: RecognitionIdentity?
    public let instance: UUID
    public let pass: RecognitionPassKind
    public let sampleRange: Range<Int>?
    /// Preserved even when delivery cancellation wins after native success/failure.
    public let native: RecognitionNativeOutcome
    public let canceled: Bool
    public var text: String? { canceled ? nil : native.text }
    public var segments: RecognitionSegments? {
        guard !canceled, pass == .fullFinal, case .completed(let payload) = native,
              let segments = payload.segments, sampleRange == 0..<segments.sourceSampleCount else { return nil }
        return segments
    }
}
public struct RecognitionFinalResult: Equatable, Sendable {
    public enum Provenance: Equatable, Sendable {
        case pass(RecognitionPassResult)
        case assembled(ownership: StreamWindow.Ownership, confirmedSamples: Range<Int>, tail: RecognitionPassResult?, skipped: RecognitionSkip?)
        case skipped(RecognitionSkip)
        case canceled
    }
    public let text: String?
    public let provenance: Provenance
    public var segments: RecognitionSegments? {
        guard text != nil, case .pass(let pass) = provenance else { return nil }
        return pass.segments
    }
}

/// One retained owner and its immutable identity. Never a separately mutable path/client pair.
public struct RecognitionResident {
    public let request: RecognitionRequest
    public let identity: RecognitionIdentity
    public let instance: UUID
    public let client: RecognitionClient
    public let preparation: PreparationReadiness
    public init(request: RecognitionRequest, identity: RecognitionIdentity, instance: UUID, client: RecognitionClient,
                preparation: PreparationReadiness = PreparationReadiness()) {
        self.request = request; self.identity = identity; self.instance = instance; self.client = client; self.preparation = preparation
    }
    public var capabilities: RecognitionCapabilities { client.capabilities }
}
