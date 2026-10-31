import Foundation

/// No native call occurs while constructing these ports. Eval/default core factories never open app storage.
public enum AppleSpeechNative {
    public static var bottom: AppleSpeechBottom {
        AppleSpeechBottom(available: checkAvailability, session: { locale in
            #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
            if #available(macOS 26.0, *) { return NativeAppleSpeechSession(locale: locale) }
            #endif
            throw AppleSpeechRefusal.unsupported
        })
    }
    public static func checkAvailability() throws {
        #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard SpeechTranscriber.isAvailable else { throw AppleSpeechRefusal.deviceUnavailable }; return
        }
        #endif
        throw AppleSpeechRefusal.unsupported
    }
    public static var assets: AppleSpeechAssets {
        AppleSpeechAssets(observe: { locale in
            try checkAvailability()
            #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier == locale }
                guard supported else { throw AppleSpeechRefusal.unsupportedLocale }
                let module = NativeAppleSpeechSession.module(locale)
                let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale }
                let status = await AssetInventory.status(forModules: [module])
                let reserved = await Set(AssetInventory.reservedLocales.map(\.identifier))
                return AppleSpeechAssetObservation(supported: true, installedLocale: installed,
                    moduleInstalled: status == .installed, reserved: reserved, capacity: AssetInventory.maximumReservedLocales)
            }
            #endif
            throw AppleSpeechRefusal.unsupported
        }, reserve: { locale in
            try checkAvailability()
            #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
            if #available(macOS 26.0, *) { return try await AssetInventory.reserve(locale: Locale(identifier: locale)) }
            #endif
            throw AppleSpeechRefusal.unsupported
        }, installation: { locale in
            try checkAvailability()
            #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
            if #available(macOS 26.0, *), let request = try await AssetInventory.assetInstallationRequest(supporting: [NativeAppleSpeechSession.module(locale)]) {
                return NativeAppleSpeechInstallation(request)
            }
            #endif
            return nil
        }, release: { locale in
            #if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
            if #available(macOS 26.0, *) { return await AssetInventory.release(reservedLocale: Locale(identifier: locale)) }
            #endif
            return false
        })
    }
}
#if canImport(Speech) && canImport(AVFAudio) && compiler(>=6.2)
import Speech
import AVFAudio
import CoreMedia

@available(macOS 26.0, *)
private final class NativeAppleSpeechInstallation: AppleSpeechInstallation {
    private let request: AssetInstallationRequest
    private let lock = NSLock()
    private var canceled = false
    init(_ request: AssetInstallationRequest) { self.request = request }
    func cancel() {
        let first = lock.withLock { if canceled { return false }; canceled = true; return true }
        if first { request.progress.cancel() }
    }
    func download(progress: @escaping (AppleSpeechProgress) -> Void) async throws {
        let object = request.progress
        let observer = object.observe(\.fractionCompleted, options: [.initial, .new]) { object, _ in
            progress(AppleSpeechProgress(fraction: object.isIndeterminate ? nil : object.fractionCompleted, cancellable: object.isCancellable))
        }
        defer { observer.invalidate() }
        try await withTaskCancellationHandler(operation: { try await request.downloadAndInstall() }, onCancel: { self.cancel() })
    }
}
@available(macOS 26.0, *)
private final class NativeAppleSpeechSession: AppleSpeechSession {
    let module: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    init(locale: String) {
        module = Self.module(locale); analyzer = SpeechAnalyzer(modules: [module])
    }
    static func module(_ locale: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
    func converter(samples: [Float]) async throws -> AppleSpeechConverter {
        guard let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural) else {
            throw AppleSpeechRefusal.format
        }
        let converter = try NativeAppleSpeechConverter(samples: samples, source: natural, target: format)
        try await analyzer.prepareToAnalyze(in: format)
        return converter
    }
    func collect(ready: @escaping () -> Void, _ emit: @escaping (AppleSpeechEvent) throws -> Void) async throws {
        let results = module.results
        ready()
        for try await result in results {
            let range = result.range, end = CMTimeRangeGetEnd(range)
            guard range.isValid, !range.isEmpty, range.start.isNumeric, end.isNumeric,
                  result.resultsFinalizationTime.isNumeric, range.start.epoch == 0, end.epoch == 0,
                  result.resultsFinalizationTime.epoch == 0 else { throw AppleSpeechRefusal.results }
            try emit(AppleSpeechEvent(text: String(result.text.characters),
                start: AppleSpeechTime(range.start.value, range.start.timescale), end: AppleSpeechTime(end.value, end.timescale),
                finalization: AppleSpeechTime(result.resultsFinalizationTime.value, result.resultsFinalizationTime.timescale), isFinal: result.isFinal))
        }
    }
    func analyze(_ input: AppleSpeechInput) async throws -> AppleSpeechTime? {
        guard let time = try await analyzer.analyzeSequence(NativeAppleSpeechSequence(input: input)) else { return nil }
        guard time.isNumeric, time.epoch == 0 else { throw AppleSpeechRefusal.input }
        return AppleSpeechTime(time.value, time.timescale)
    }
    func finalize(through time: AppleSpeechTime) async throws {
        try await analyzer.finalizeAndFinish(through: CMTime(value: time.value, timescale: time.scale))
    }
    func cancelAndFinish() async { await analyzer.cancelAndFinishNow() }
}
@available(macOS 26.0, *)
private struct NativeAppleSpeechSequence: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput
    let input: AppleSpeechInput
    struct AsyncIterator: AsyncIteratorProtocol {
        let input: AppleSpeechInput
        mutating func next() async throws -> AnalyzerInput? {
            guard let (value, time) = try input.next(), let buffer = value.payload as? AVAudioPCMBuffer else { return nil }
            return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: time.value, timescale: time.scale))
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(input: input) }
}
@available(macOS 26.0, *)
private final class NativeAppleSpeechConverter: AppleSpeechConverter {
    let format: AppleSpeechFormat
    private let samples: [Float]
    private let converter: AVAudioConverter
    private let source: AVAudioFormat, target: AVAudioFormat
    var sourcePrimingUncertainty: Int { Int(converter.primeInfo.leadingFrames) + Int(converter.primeInfo.trailingFrames) }
    private(set) var consumedSourceSamples = 0
    private(set) var ended = false
    private let capacity: AVAudioFrameCount
    // Conversion uses its default priming. Output is an analysis timeline, with priming uncertainty;
    // it is not word alignment or proof of source-sample accuracy.
    init(samples: [Float], source: AVAudioFormat, target: AVAudioFormat) throws {
        guard target.sampleRate.isFinite, target.sampleRate.rounded() == target.sampleRate,
              (8_000...192_000).contains(target.sampleRate), (1...8).contains(target.channelCount),
              [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32].contains(target.commonFormat),
              let converter = AVAudioConverter(from: source, to: target) else { throw AppleSpeechRefusal.format }
        let width = target.commonFormat == .pcmFormatInt16 ? 2 : 4
        format = AppleSpeechFormat(rate: Int32(target.sampleRate), channels: Int(target.channelCount), bytesPerFrame: width * Int(target.channelCount))
        try format.validate()
        self.samples = samples; self.converter = converter; self.source = source; self.target = target
        capacity = AVAudioFrameCount(min(16_000, 1_048_576 / format.bytesPerFrame))
    }
    func next() throws -> AppleSpeechBuffer? {
        guard !ended else { return nil }
        // need-more-input may produce zero frames. A bounded loop prevents no-progress converter spins.
        for _ in 0..<10_000 {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AppleSpeechRefusal.conversion }
            var failure: NSError?, inputFailed = false
            let before = consumedSourceSamples
            let status = converter.convert(to: output, error: &failure) { requested, state in
                guard requested > 0 else { inputFailed = true; state.pointee = .noDataNow; return nil }
                guard self.consumedSourceSamples < self.samples.count else { state.pointee = .endOfStream; return nil }
                let count = min(16_000, Int(requested), self.samples.count - self.consumedSourceSamples)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: self.source, frameCapacity: AVAudioFrameCount(count)),
                      let pointer = buffer.floatChannelData?[0] else { inputFailed = true; state.pointee = .noDataNow; return nil }
                buffer.frameLength = AVAudioFrameCount(count)
                self.samples.withUnsafeBufferPointer { pcm in
                    if let base = pcm.baseAddress { pointer.update(from: base + self.consumedSourceSamples, count: count) }
                }
                self.consumedSourceSamples += count; state.pointee = .haveData; return buffer
            }
            guard !inputFailed, failure == nil else { throw AppleSpeechRefusal.conversion }
            switch status {
            case .error: throw AppleSpeechRefusal.conversion
            case .endOfStream: ended = true
            case .haveData, .inputRanDry: break
            @unknown default: throw AppleSpeechRefusal.conversion
            }
            let frames = Int(output.frameLength), bytes = frames.multipliedReportingOverflow(by: format.bytesPerFrame)
            guard !bytes.overflow, frames <= Int(capacity), bytes.partialValue <= 1_048_576 else { throw AppleSpeechRefusal.conversion }
            if frames > 0 { return AppleSpeechBuffer(frames: frames, bytes: bytes.partialValue, payload: output) }
            if ended { return nil }
            guard consumedSourceSamples > before else { throw AppleSpeechRefusal.conversion }
        }
        throw AppleSpeechRefusal.conversion
    }
}
#endif
