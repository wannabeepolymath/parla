import Foundation

/// Frozen at recognition entry; Settings/Profile serialization stays unchanged.
public struct RecognitionRequest: Equatable, Sendable {
    public let selection: RecognitionSelection
    /// Saved Whisper configuration, retained across engine changes. Never an Apple asset path.
    public let modelPath: String
    public var metricLabel: String {
        selection.engine == .parakeet ? "parakeet-int4" : selection.engine == .appleSpeech ? "apple-speech" : selection.engine == .invalid ? "unavailable" : URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
    }
    public let language: String?
    public let dictionary: [String]
    public init(settings: Settings) {
        modelPath = settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath()
        if settings.recognitionConfigurationInvalid { selection = .invalid }
        else {
            switch settings.recognitionEngine {
            case .whisper: selection = .whisper(localPath: modelPath)
            case .appleSpeech:
                if let locale = settings.appleSpeechLocale, AppleSpeechLocale.isValid(locale) { selection = .appleSpeech(locale: locale) }
                else { selection = .invalid }
            case .parakeet:
                if settings.parakeetModelID == ParakeetWire.model, settings.parakeetLanguageFilter.map({ ParakeetWire.filters.contains($0) }) ?? true {
                    selection = .parakeet(model: settings.parakeetModelID, filter: settings.parakeetLanguageFilter)
                } else { selection = .invalid }
            case .invalid: selection = .invalid
            }
        }
        language = settings.language; dictionary = settings.dictionary
    }
}
public protocol RecognitionClient: AnyObject {
    var capabilities: RecognitionCapabilities { get }
    var deliveryRevoked: Bool { get }
    func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome
    func recognizeTimed(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String?
}
public extension RecognitionClient {
    var capabilities: RecognitionCapabilities { RecognitionCapabilities() }
    var deliveryRevoked: Bool { false }
    /// No compatibility fallthrough to string-only clients or other backends.
    func recognizeTimed(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        .failed(.unsupportedCapability)
    }
    /// Compatibility for existing injected clients. Production Whisper implements the structured method.
    func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        let text = await transcribe(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
        if let text { return .completed(.init(text: text)) }
        return shouldAbort?() == true ? .canceled : .failed(.clientUnavailable)
    }
}

public final class RecognitionHandle {
    public enum Pass {
        case streamHead(String), streamTail(String), windowedFinal(String), fullFinal, command, warmup, hudPreview
        var kind: RecognitionPassKind {
            switch self {
            case .streamHead: return .streamHead
            case .streamTail: return .streamTail
            case .windowedFinal: return .windowedFinal
            case .fullFinal: return .fullFinal
            case .command: return .command
            case .warmup: return .warmup
            case .hudPreview: return .hudPreview
            }
        }
    }
    public let request: RecognitionRequest
    public let client: RecognitionClient
    public let identity: RecognitionIdentity?
    public let instance: UUID
    public let capture: UUID
    private let preparation: PreparationPermit?
    private let readiness: PreparationReadiness
    public var preparationIsCurrent: Bool { preparation.map { (try? $0.validate()) != nil } ?? true }
    public var resident: RecognitionResident? {
        identity.map { RecognitionResident(request: request, identity: $0, instance: instance, client: client, preparation: readiness) }
    }
    init(owner: RecognitionResident, capture: UUID, preparation: PreparationPermit? = nil) {
        request = owner.request; client = owner.client; identity = owner.identity
        instance = owner.instance; self.capture = capture
        self.preparation = preparation; readiness = owner.preparation
    }
    /// Legacy injection seam, retained for existing generic-client tests. App origins use RecognitionFactory.
    public init(request: RecognitionRequest, residentPath: String? = nil, resident: RecognitionClient? = nil,
                diagnostics: DiagnosticOperation? = nil, load: (String) throws -> RecognitionClient) throws {
        guard request.selection.engine == .whisper else { throw AppleSpeechRefusal.configuration }
        let span = diagnostics?.begin(.acquisition); defer { span?.end() }
        self.request = request; identity = nil; instance = UUID(); capture = UUID()
        preparation = nil; readiness = PreparationReadiness()
        diagnostics?.recognition(request: request)
        if residentPath == request.modelPath, let resident { client = resident }
        else { client = try load(request.modelPath) }
        diagnostics?.recognition(request: request, resolved: true)
    }
    public func window(confirmedText: String, cutSample: Int) -> StreamWindow {
        StreamWindow(confirmedText: confirmedText, cutSample: cutSample,
                     ownership: .init(instance: instance, identity: identity, capture: capture, request: request))
    }
    public func owns(_ window: StreamWindow) -> Bool {
        window.ownership == .init(instance: instance, identity: identity, capture: capture, request: request)
    }
    public func finalResult(samples: [Float], window: StreamWindow?, shouldAbort: (() -> Bool)? = nil,
                            diagnostics: DiagnosticOperation? = nil, rawOnly: Bool = false) async -> RecognitionFinalResult {
        guard shouldAbort?() != true else {
            diagnostics?.update { $0.asr = .canceled }; return .init(text: nil, provenance: .canceled)
        }
        // rawOnly deliberately ignores even a same-owner window (B57).
        if client.capabilities.shadowWindows, !rawOnly, let window, owns(window), let ownership = window.ownership, window.cutSample >= 0, window.cutSample <= samples.count {
            let cut = window.cutSample, tail = Array(samples[cut...])
            let skip = Pipeline.recognitionSkip(samples: tail)
            let result = skip == nil ? await recognize(tail, pass: .windowedFinal(window.confirmedText),
                sampleRange: cut..<samples.count, shouldAbort: shouldAbort, diagnostics: diagnostics) : nil
            if skip != nil { diagnostics?.update { $0.asr = .confirmedWindow } }
            let joined = StreamWindow.join(window.confirmedText, result?.text ?? "")
            let canceled = shouldAbort?() == true || result?.canceled == true
            diagnostics?.recognitionAssembly(tail: result, skipped: skip)
            return .init(text: canceled || joined.isEmpty ? nil : joined,
                         provenance: .assembled(ownership: ownership, confirmedSamples: 0..<cut, tail: result, skipped: skip))
        }
        // Unknown/foreign shortcut evidence is recomputed from the original audio.
        if !rawOnly, let skip = Pipeline.recognitionSkip(samples: samples) {
            diagnostics?.update { $0.asr = skip == .minimumDuration ? .minimumDuration : .silence }
            return .init(text: nil, provenance: .skipped(skip))
        }
        let result = await recognize(samples, pass: .fullFinal, sampleRange: 0..<samples.count,
                               shouldAbort: shouldAbort, diagnostics: diagnostics)
        return .init(text: rawOnly ? result.text : Pipeline.transcriptProjection(result.text), provenance: .pass(result))
    }
    public func finalTranscript(samples: [Float], window: StreamWindow?, shouldAbort: (() -> Bool)? = nil,
                                diagnostics: DiagnosticOperation? = nil, rawOnly: Bool = false) async -> String? {
        await finalResult(samples: samples, window: window, shouldAbort: shouldAbort, diagnostics: diagnostics, rawOnly: rawOnly).text
    }
    /// Exactly one full raw file request; no window/preview/command assembly.
    public func timedFileResult(samples: [Float], shouldAbort: (() -> Bool)? = nil,
                                diagnostics: DiagnosticOperation? = nil) async -> RecognitionFinalResult {
        let result = await recognizePass(samples, pass: .fullFinal, sampleRange: 0..<samples.count,
            shouldAbort: shouldAbort, diagnostics: diagnostics, timedFile: true)
        return .init(text: result.text, provenance: .pass(result))
    }
    public func commandResult(samples: [Float], shouldAbort: (() -> Bool)? = nil,
                              diagnostics: DiagnosticOperation? = nil) async -> RecognitionFinalResult {
        if let skip = Pipeline.recognitionSkip(samples: samples) {
            diagnostics?.update { $0.asr = skip == .minimumDuration ? .minimumDuration : .silence }
            return .init(text: "", provenance: .skipped(skip))
        }
        let result = await recognize(samples, pass: .command, sampleRange: 0..<samples.count, shouldAbort: shouldAbort, diagnostics: diagnostics)
        return .init(text: result.text, provenance: .pass(result))
    }
    public func commandInstruction(samples: [Float], shouldAbort: (() -> Bool)? = nil, diagnostics: DiagnosticOperation? = nil) async -> String? {
        await commandResult(samples: samples, shouldAbort: shouldAbort, diagnostics: diagnostics).text
    }
    public func recognize(_ samples: [Float], pass: Pass, sampleRange: Range<Int>? = nil,
                          shouldAbort: (() -> Bool)? = nil, diagnostics: DiagnosticOperation? = nil,
                          initialPrompt: String? = nil) async -> RecognitionPassResult {
        await recognizePass(samples, pass: pass, sampleRange: sampleRange, shouldAbort: shouldAbort,
                            diagnostics: diagnostics, initialPrompt: initialPrompt)
    }
    private func recognizePass(_ samples: [Float], pass: Pass, sampleRange: Range<Int>?,
                               shouldAbort: (() -> Bool)?, diagnostics: DiagnosticOperation?,
                               initialPrompt: String? = nil, timedFile: Bool = false) async -> RecognitionPassResult {
        let prompt: String?
        if !client.capabilities.manualTextPrompt { prompt = nil }
        else { switch pass {
        case .streamHead(let confirmed), .streamTail(let confirmed), .windowedFinal(let confirmed):
            prompt = StreamWindow.tailPrompt(dictionary: request.dictionary, confirmed: confirmed)
        case .fullFinal, .command, .hudPreview: prompt = initialPrompt ?? VocabularyHints.asrPrompt(request.dictionary)
        case .warmup: prompt = nil
        } }
        let span = diagnostics?.begin(.asr); defer { span?.end() }
        let native: RecognitionNativeOutcome
        var deliveryAuthorized = true
        if timedFile, request.selection.engine != .whisper { native = .failed(.unsupportedCapability) }
        else if timedFile, !preparationIsCurrent { native = .failed(.preparationUnavailable) }
        else if !client.capabilities.manualTextPrompt, initialPrompt != nil { native = .failed(.unsupportedCapability) }
        else if !client.capabilities.shadowWindows, ![RecognitionPassKind.fullFinal, .command].contains(pass.kind) { native = .failed(.unsupportedCapability) }
        else if preparation?.preparationOnly == true, pass.kind != .warmup { native = .failed(.preparationUnavailable) }
        else if shouldAbort?() == true { native = .canceled }
        else if case .warmup = pass, let preparation {
            do {
                native = try await preparation.warmup(readiness: readiness) {
                    await client.recognize(samples, initialPrompt: nil, language: request.language, shouldAbort: shouldAbort)
                }
            } catch { native = .failed(.preparationUnavailable) }
        } else if let preparation {
            let receipt = await preparation.firstRequest(readiness: readiness,
                canceled: { shouldAbort?() == true || client.deliveryRevoked }) {
                if timedFile { return await client.recognizeTimed(samples, initialPrompt: prompt, language: request.language, shouldAbort: shouldAbort) }
                return await client.recognize(samples, initialPrompt: prompt, language: request.language, shouldAbort: shouldAbort)
            }
            native = receipt.native; deliveryAuthorized = receipt.deliveryAuthorized
        } else if timedFile {
            native = await client.recognizeTimed(samples, initialPrompt: prompt, language: request.language, shouldAbort: shouldAbort)
        } else { native = await client.recognize(samples, initialPrompt: prompt, language: request.language, shouldAbort: shouldAbort) }
        let canceled = !deliveryAuthorized || shouldAbort?() == true || client.deliveryRevoked || native == .canceled || (timedFile && !preparationIsCurrent)
        let result = RecognitionPassResult(identity: identity, instance: instance, pass: pass.kind,
            sampleRange: sampleRange, native: native, canceled: canceled)
        diagnostics?.update { $0.asr = canceled ? .canceled : native.text.map { $0.isEmpty ? .empty : .text } ?? .nilOrError }
        diagnostics?.recognitionOutcome(result)
        return result
    }
    public func transcribe(_ samples: [Float], pass: Pass, shouldAbort: (() -> Bool)? = nil, diagnostics: DiagnosticOperation? = nil) async -> String? {
        await recognize(samples, pass: pass, shouldAbort: shouldAbort, diagnostics: diagnostics).text
    }
}
