import SwiftUI
import Speech
import ParlaCore

/// HTTPS-only, credential-free catalog transport. Redirects stay on Hugging Face hosts (desktop policy).
private final class CatalogRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") else {
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
}

/// Explicit Download / Cancel / Delete. ModelCatalog.install checks size, markup and the pinned
/// SHA-256 before an atomic move; nothing here selects a model on its own.
@MainActor final class ModelDownloads: ObservableObject {
    @Published private(set) var progress: [String: Double] = [:]
    @Published var error: String?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: CatalogRedirects(), delegateQueue: nil)
    }()
    func isInstalled(_ model: ModelCatalog.Model) -> Bool { ModelCatalog.isInstalled(model) }
    func download(_ model: ModelCatalog.Model) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        error = nil
        let directory = ModelCatalog.directory
        let staged = directory.appendingPathComponent(model.filename + ".download")
        let task = session.downloadTask(with: model.url) { [weak self] location, response, failure in
            // Session queue, off main. URLSession deletes `location` when this returns, so stage it first.
            var message: String?
            if let failure { message = (failure as? URLError)?.code == .cancelled ? nil : "\(model.displayName) download failed. Check your connection and retry." }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { message = "\(model.displayName) download was refused by the server." }
            else if let location {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staged)
                    try FileManager.default.moveItem(at: location, to: staged)
                    try ModelCatalog.install(staged: staged, as: model, at: URL(fileURLWithPath: ModelCatalog.path(for: model)))
                } catch { message = "\(model.displayName) was not installed: " + ((error as? ModelFileError)?.description ?? "storage error.") }
                try? FileManager.default.removeItem(at: staged)
            }
            Task { @MainActor in self?.finished(model, message) }
        }
        observations[model.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if self?.tasks[model.id] != nil { self?.progress[model.id] = fraction } }
        }
        tasks[model.id] = task; progress[model.id] = 0
        task.resume()
    }
    func cancel(_ model: ModelCatalog.Model) { tasks[model.id]?.cancel() }
    func delete(_ model: ModelCatalog.Model) {
        do { try FileManager.default.removeItem(atPath: ModelCatalog.path(for: model)); objectWillChange.send() }
        catch { self.error = "\(model.displayName) could not be deleted." }
    }
    private func finished(_ model: ModelCatalog.Model, _ message: String?) {
        tasks[model.id] = nil; observations[model.id] = nil; progress[model.id] = nil
        if let message { error = message }
    }
}

struct ModelsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: ModelDownloads
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var locales: [String] = []
    @State private var locale = ""
    @State private var preparing: Double??
    @State private var speechMessage: String?
    var s: Settings { settings.current }
    static func selectionLabel(_ settings: Settings) -> String {
        switch RecognitionRequest(settings: settings).selection {
        case .appleSpeech(let locale): return "Apple Speech · \(locale)"
        case .whisper(let path):
            guard let model = ModelCatalog.model(atPath: path) else { return "None" }
            return model.displayName + (ModelCatalog.isInstalled(model) ? "" : " · not downloaded")
        case .parakeet, .invalid: return "None"
        }
    }
    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { model in row(model) }
            } header: { Text("On-device Whisper") } footer: {
                Text("Models download from Hugging Face over HTTPS. Each file is checked against its pinned size and SHA-256 before it is installed, is kept only on this iPhone and is excluded from backups. English-only models ignore the language setting; Large v3 Turbo is multilingual and slow on iPhone. Parla never switches models on its own.")
            }
            if SpeechTranscriber.isAvailable { appleSpeech }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Models")
            .alert("Models", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) { Button("OK") { downloads.error = nil } } message: { Text(downloads.error ?? "") }
            .task {
                guard SpeechTranscriber.isAvailable else { return }
                locales = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
                locale = s.appleSpeechLocale ?? locales.first { $0 == Locale.current.identifier } ?? locales.first ?? ""
            }
    }
    func selected(_ model: ModelCatalog.Model) -> Bool {
        if case .whisper(let path) = RecognitionRequest(settings: s).selection { return path == ModelCatalog.path(for: model) }
        return false
    }
    func row(_ model: ModelCatalog.Model) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(model.displayName).fontWeight(.semibold); Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if selected(model) { Label(downloads.isInstalled(model) ? "Selected" : "Selected · missing", systemImage: "checkmark.circle.fill").font(.caption) }
            }
            if let fraction = downloads.progress[model.id] {
                ProgressView(value: fraction) { Text(fraction >= 1 ? "Verifying…" : "Downloading…").font(.caption) }
                Button("Cancel", role: .cancel) { downloads.cancel(model) }.disabled(fraction >= 1) // install can't be stopped once verifying
            } else if downloads.isInstalled(model) {
                HStack {
                    if !selected(model) { Button("Use") { settings.update { $0.recognitionEngine = .whisper; $0.whisperModelPath = ModelCatalog.path(for: model) } } }
                    Spacer()
                    Button("Delete", role: .destructive) { downloads.delete(model) }.disabled(coordinator.busy)
                }.buttonStyle(.borderless)
            } else {
                Button("Download \(model.sizeLabel)") { downloads.download(model) }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 4)
    }
    var appleSpeech: some View {
        Section {
            Picker("Language", selection: $locale) { ForEach(locales, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }
            if case .some(let fraction) = preparing {
                ProgressView(value: fraction ?? 0) { Text("Preparing \(locale)…").font(.caption) }
            } else {
                Button("Prepare language") { prepare() }.disabled(locale.isEmpty)
                if s.recognitionEngine == .appleSpeech, s.appleSpeechLocale == locale { Label("Selected", systemImage: "checkmark.circle.fill").font(.caption) }
                else { Button("Use Apple Speech") { settings.update { $0.recognitionEngine = .appleSpeech; $0.appleSpeechLocale = locale } }.disabled(!AppleSpeechLocale.isValid(locale)) }
            }
            if let speechMessage { Text(speechMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Apple Speech") } footer: {
            Text("Apple's on-device recognizer. Prepare downloads the system language assets; dictation refuses to start recognition until they are installed. Dictionary words are not used as hints.")
        }
    }
    func prepare() {
        let target = locale
        preparing = .some(nil); speechMessage = nil
        Task {
            do {
                try await AppleSpeechSetup.prepare(target) { fraction in Task { @MainActor in preparing = .some(fraction) } }
                speechMessage = "\(target) is ready on this iPhone."
            } catch { speechMessage = (error as? AppleSpeechRefusal)?.message ?? "Language assets could not be prepared." }
            preparing = nil
        }
    }
}
