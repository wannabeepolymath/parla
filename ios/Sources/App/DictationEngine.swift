import SwiftUI
import ParlaCore

/// Desktop `Settings` through the desktop `SettingsStore`, as protected JSON in the app's own
/// Application Support (never the App Group). Keys go through `CredentialStore.shared`.
@MainActor final class AppSettings: ObservableObject {
    let store: SettingsStore
    @Published private(set) var current = Settings()
    @Published var error: String?
    init(root: URL) {
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: .shared,
            atomicWrite: { try $0.write(to: $1, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) })
        reset()
    }
    /// Seeds a missing file, then reloads. iOS first run has no provider configured,
    /// so model cleanup starts off rather than failing every dictation.
    func reset() {
        if !FileManager.default.fileExists(atPath: store.url.path) {
            var first = Settings(); first.cleanupEnabled = false
            do { try store.save(first) } catch { self.error = "Could not create settings." }
        }
        reload()
    }
    func reload() { current = Self.normalized(store.load()); if let failure = store.lastError { error = "Settings could not be read: \(failure)" } }
    /// iOS moves the app container on update, so a saved catalog path follows today's models directory.
    nonisolated static func normalized(_ settings: Settings) -> Settings {
        var settings = settings
        if let path = settings.whisperModelPath, let model = ModelCatalog.model(atPath: path) { settings.whisperModelPath = ModelCatalog.path(for: model) }
        return settings
    }
    func update(_ body: (inout Settings) -> Void) {
        var next = current; body(&next)
        guard next != current else { return }
        do { try store.save(next) } catch { self.error = (error as? CredentialFailure)?.description ?? "Settings were not saved. Your previous settings are unchanged." }
        reload()
    }
    func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { self.current[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

/// The desktop core assembled for one iPhone dictation. No bundle ID or profile: iOS keyboards cannot learn the host app.
enum DictationEngine {
    typealias Transcribe = ([Float], String?) async -> String?
    struct Outcome: Equatable {
        var raw: String
        var cleaned: String?
        var final: String
        var cleanupFailure: String?
    }
    /// 300 s of 16 kHz mono, the Android capture cap.
    static let maximumSamples = 300 * 16_000
    static let factory = RecognitionFactory(appleInstalledUse: { locale, operation in try await AppleSpeechSetup.installedUse(locale, operation) })

    /// Checked before the microphone opens so a missing model routes to Models, never to a key screen.
    static func recognitionIssue(_ settings: Settings) -> String? {
        switch RecognitionRequest(settings: settings).selection {
        case .whisper(let path): FileManager.default.fileExists(atPath: path) ? nil : "Download and select a speech model in Models before dictating."
        case .appleSpeech: nil
        case .parakeet, .invalid: "Choose a speech model in Models before dictating."
        }
    }
    static func pipeline(_ settings: Settings, credentials: CredentialStore) -> Pipeline {
        Pipeline(outputSettings: settings, bundleID: nil, failureLogging: .contentFree) {
            try makeCleanupClient(settings: $0, env: [:], credentials: credentials, http: CleanupHTTP())
        }
    }
    /// Desktop floor first (no model load for silence), then `Pipeline.transcript` with its vocabulary hints.
    static func recognize(_ samples: [Float], pipeline: Pipeline, acquire: () async throws -> Transcribe) async throws -> String {
        if let skip = Pipeline.recognitionSkip(samples: samples) {
            throw ParlaError.message(skip == .minimumDuration ? "That recording was too short to transcribe." : "No speech was detected in that recording.")
        }
        var pipeline = pipeline
        pipeline.transcribe = try await acquire()
        let text = await pipeline.transcript(samples: samples)
        try Task.checkCancellation()
        guard let text else { throw ParlaError.message("Speech recognition returned no text. Retry from History.") }
        return text
    }
    /// Never throws for cleanup: a failure keeps the raw text and carries the reason.
    static func finish(raw: String, pipeline: Pipeline) async -> Outcome {
        let (text, failure) = await pipeline.clean(transcript: raw)
        return Outcome(raw: raw, cleaned: failure == nil && pipeline.settings().outputMode != .raw ? text : nil, final: text, cleanupFailure: failure)
    }
    /// One handle per dictation, released when the closure is (Android parity: no idle resident model).
    static func localRecognizer(_ settings: Settings, operation: PendingOperation) async throws -> Transcribe {
        let handle: RecognitionHandle
        do { handle = try await factory.acquire(request: RecognitionRequest(settings: settings), shouldAbort: { operation.shouldAbort }, operation: operation) }
        catch is CancellationError { throw CancellationError() }
        catch let refusal as AppleSpeechRefusal { throw ParlaError.message(refusal.message) }
        catch { throw ParlaError.message("The selected speech model is unavailable or failed verification. Open Models to download or select it.") }
        // The handle derives the same VocabularyHints prompt from its frozen request; Apple Speech refuses a manual one.
        return { samples, _ in await handle.recognize(samples, pass: .fullFinal, shouldAbort: { operation.shouldAbort }).text }
    }
}

/// Explicit Prepare and per-use checks for Apple's on-device SpeechAnalyzer assets.
enum AppleSpeechSetup {
    static func installedUse(_ locale: String, _ operation: PendingOperation?) async throws -> AppleSpeechLease {
        let observation = try await AppleSpeechNative.assets.observe(locale)
        try observation.validateInstalled()
        guard observation.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
        return AppleSpeechLease(operation: operation ?? PendingOperation(name: "Apple Speech recognition")) {}
    }
    static func prepare(_ locale: String, assets: AppleSpeechAssets = AppleSpeechNative.assets, progress: @escaping (Double?) -> Void) async throws {
        let observation = try await assets.observe(locale)
        try observation.validate()
        if !observation.reserved.contains(locale) {
            guard observation.reserved.count < observation.capacity else { throw AppleSpeechRefusal.capacity }
            do {
                guard try await assets.reserve(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
            } catch {
                // Capacity may change between observation and reserve; retain a useful recovery message.
                if let latest = try? await assets.observe(locale), latest.reserved.count >= latest.capacity { throw AppleSpeechRefusal.capacity }
                throw error
            }
        }
        if let installation = try await assets.installation(locale) { try await installation.download { progress($0.fraction) } }
        let ready = try await assets.observe(locale)
        try ready.validateInstalled()
        guard ready.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
    }
    static func canRelease(busy: Bool, preparing: Bool) -> Bool { !busy && !preparing }
}

/// Both completion POSTs and optional /models GETs use the same bounded, redirect-refusing transport.
struct CleanupHTTP: HTTPPosting {
    static let maximumResponseBytes = 256 * 1024
    var configuration: () -> URLSessionConfiguration = { .ephemeral }
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let transfer = CleanupTransfer()
        var request = request; request.timeoutInterval = min(15, request.timeoutInterval)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(request, configuration: configuration(), continuation: $0) }
        } onCancel: { transfer.cancel() }
    }
}

final class CleanupTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var failure: Error?
    private var cancelled = false
    func start(_ request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval; configuration.timeoutIntervalForResource = request.timeoutInterval
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let task = lock.withLock {
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request); self.task = task
            if cancelled { task.cancel() }
            return task
        }
        task.resume()
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = URLError(.httpTooManyRedirects); completionHandler(nil); task.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(CleanupHTTP.maximumResponseBytes) else {
            failure = URLError(.dataLengthExceedsMaximum); completionHandler(.cancel); return
        }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, data.count <= CleanupHTTP.maximumResponseBytes - body.count else {
            failure = URLError(.dataLengthExceedsMaximum); dataTask.cancel(); return
        }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let continuation = lock.withLock { self.task = nil; self.session = nil; defer { self.continuation = nil }; return self.continuation }
        defer { body = Data() }
        if lock.withLock({ cancelled }) { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: (body, response)) }
        else { continuation?.resume(throwing: URLError(.badServerResponse)) }
    }
}
