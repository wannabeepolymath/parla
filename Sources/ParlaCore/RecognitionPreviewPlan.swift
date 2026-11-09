import Foundation

/// Frozen after ProfileResolver: global preview, independently selected final.
/// Creating or projecting this value performs no admission, IO or native work.
public struct RecognitionPreviewPlan: Equatable, Sendable {
    public let final: RecognitionRequest
    public let preview: RecognitionRequest?
    public let modelID: String
    public let generation: Int
    public let operationID: UUID
    public let phase = RecognitionPreviewPhase()

    public init?(settings: Settings, final: RecognitionRequest, generation: Int,
                 operationID: UUID, ordinaryPhysical: Bool,
                 directory: URL = ModelCatalog.directory, catalog: [ModelCatalog.Model] = ModelCatalog.all) {
        guard ordinaryPhysical, settings.streamPreviewEnabled,
              let modelID = settings.recognitionPreviewModelID else { return nil }
        self.final = final; self.modelID = modelID
        self.generation = generation; self.operationID = operationID
        if let model = catalog.first(where: { $0.id == modelID }) {
            var value = settings
            value.recognitionEngine = .whisper
            value.whisperModelPath = directory.appendingPathComponent(model.filename).path
            value.language = final.language; value.dictionary = final.dictionary
            preview = RecognitionRequest(settings: value)
        } else { preview = nil }
    }

    public func refusal(directory: URL, catalog: [ModelCatalog.Model]) -> RecognitionPreviewStatus? {
        guard final.selection.engine == .whisper,
              RecognitionFactory.ownedModel(path: final.modelPath, directory: directory, catalog: catalog) != nil else { return .ineligibleFinal }
        guard let preview, RecognitionFactory.ownedModel(path: preview.modelPath, directory: directory, catalog: catalog) != nil else { return .unavailable }
        if englishOnly, let language = final.language, language != "en" { return .languageUnavailable }
        return nil
    }
    public var englishOnly: Bool { modelID.contains(".en") }
}

/// Publication revocation is immediate; native destruction belongs to the queue.
public final class RecognitionPreviewPhase: Equatable, @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isCurrent: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
    public static func == (lhs: RecognitionPreviewPhase, rhs: RecognitionPreviewPhase) -> Bool { lhs === rhs }
}

public enum RecognitionPreviewStatus: String, Codable, Sendable {
    case loading, ready, empty, unavailable, ineligibleFinal, languageUnavailable, limitReached
    public var message: String {
        switch self {
        case .loading: return "Listening…"
        case .ready: return "Listening…"
        case .empty: return "Listening…"
        case .unavailable: return "Listening… (no preview)"
        case .ineligibleFinal: return "Listening… (preview needs a Whisper model)"
        case .languageUnavailable: return "Listening… (no preview for this language)"
        case .limitReached: return "Listening… (preview paused)"
        }
    }
}

public enum RecognitionPreviewUpdate: Equatable, Sendable {
    case draft(String, englishOnly: Bool)
    case status(RecognitionPreviewStatus)
}

/// The only PCM owner handed to a preview pass. No full-buffer ArraySlice escapes.
public struct RecognitionPreviewSuffix: Sendable {
    public static let maximumSamples = 240_000
    public let samples: [Float]
    public let totalCount: Int
    public let range: Range<Int>
    public init(copying samples: [Float]) {
        totalCount = samples.count
        range = max(0, samples.count - Self.maximumSamples)..<samples.count
        self.samples = Array(samples[range])
    }
}

public enum RecognitionPreviewLimits {
    public static let newSamples = 16_000
    public static let interval: TimeInterval = 1
    public static let requests = 600
    public static let displayBytes = 4096
    /// One suffix, preserving scalar boundaries even for multi-byte text.
    public static func displaySuffix(_ text: String) -> String {
        var bytes = 0
        let suffix = text.unicodeScalars.reversed().prefix { scalar in
            let count = scalar.utf8.count
            guard bytes + count <= displayBytes else { return false }
            bytes += count; return true
        }
        return String(String.UnicodeScalarView(suffix.reversed()))
    }
}
