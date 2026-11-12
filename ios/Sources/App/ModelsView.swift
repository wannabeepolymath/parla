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
            if let failure { message = (failure as? URLError)?.code == .cancelled ? nil : "\(ConsumerCopy.modelName(model)) download failed. Check your connection and retry." }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { message = "\(ConsumerCopy.modelName(model)) download was refused by the server." }
            else if let location {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staged)
                    try FileManager.default.moveItem(at: location, to: staged)
                    try ModelCatalog.install(staged: staged, as: model, at: URL(fileURLWithPath: ModelCatalog.path(for: model)))
                } catch { message = "\(ConsumerCopy.modelName(model)) could not be installed. Check available storage and try downloading again." }
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
        catch { self.error = "\(ConsumerCopy.modelName(model)) could not be deleted." }
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
    @State private var reserved: [String] = []
    @State private var releasing = false
    @State private var locale = ""
    @State private var preparing: Double??
    @State private var speechMessage: String?
    var s: Settings { settings.current }
    static func selectionLabel(_ settings: Settings) -> String {
        switch RecognitionRequest(settings: settings).selection {
        case .appleSpeech(let locale): return "Apple Speech · \(ConsumerCopy.language(locale))"
        case .whisper(let path):
            guard let model = ModelCatalog.model(atPath: path) else { return "None" }
            return ConsumerCopy.modelName(model) + (ModelCatalog.isInstalled(model) ? "" : " · not downloaded")
        case .parakeet, .invalid: return "None"
        }
    }
    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { model in row(model) }
            } header: { Text("Whisper · on this iPhone") } footer: {
                Text("Models download securely from Hugging Face and are checked before installation. They stay on this iPhone and are not backed up. English models only transcribe English. Large v3 Turbo supports multiple languages and can be slow on iPhone. You choose which model to use.")
            }
            if SpeechTranscriber.isAvailable { appleSpeech }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Models")
            .alert("Models", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) { Button("OK") { downloads.error = nil } } message: { Text(downloads.error ?? "") }
            .task {
                guard SpeechTranscriber.isAvailable else { return }
                locales = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
                locale = s.appleSpeechLocale ?? locales.first { $0 == Locale.current.identifier } ?? locales.first ?? ""
                await refreshReservations()
            }
    }
    func selected(_ model: ModelCatalog.Model) -> Bool {
        if case .whisper(let path) = RecognitionRequest(settings: s).selection { return path == ModelCatalog.path(for: model) }
        return false
    }
    func row(_ model: ModelCatalog.Model) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(ConsumerCopy.modelName(model)).fontWeight(.semibold); Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if selected(model) { Label(downloads.isInstalled(model) ? "Selected" : "Download needed", systemImage: "checkmark.circle.fill").font(.caption) }
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
                ProgressView(value: fraction ?? 0) { Text("Preparing \(ConsumerCopy.language(locale))…").font(.caption) }
            } else {
                Button("Prepare language") { prepare() }.disabled(locale.isEmpty || releasing || coordinator.busy || coordinator.isManagingSpeechAssets)
                if s.recognitionEngine == .appleSpeech, s.appleSpeechLocale == locale { Label("Selected", systemImage: "checkmark.circle.fill").font(.caption) }
                else { Button("Use Apple Speech") { settings.update { $0.recognitionEngine = .appleSpeech; $0.appleSpeechLocale = locale } }.disabled(!AppleSpeechLocale.isValid(locale)) }
            }
            ForEach(reserved, id: \.self) { language in
                HStack {
                    Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                    Spacer()
                    Button("Remove language", role: .destructive) { release(language) }
                        .disabled(!AppleSpeechSetup.canRelease(busy: coordinator.busy, preparing: preparing != nil || releasing || coordinator.isManagingSpeechAssets))
                }.buttonStyle(.borderless)
            }
            if let speechMessage { Text(speechMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Apple Speech") } footer: {
            Text("Apple Speech recognizes speech on this iPhone. Prepare downloads the language needed before you can dictate. It does not use your dictionary. Prepared languages stay until you remove them here. Finish dictation before removing a language.")
        }
    }
    func refreshReservations() async {
        do { reserved = try await AppleSpeechNative.assets.observe(locale).reserved.sorted() }
        catch { speechMessage = (error as? AppleSpeechRefusal)?.message ?? "Prepared languages could not be loaded. Try again." }
    }
    func release(_ language: String) {
        guard AppleSpeechSetup.canRelease(busy: coordinator.busy, preparing: preparing != nil || releasing || coordinator.isManagingSpeechAssets) else { return }
        releasing = true; coordinator.isManagingSpeechAssets = true
        Task {
            speechMessage = await AppleSpeechNative.assets.release(language) ? "Removed \(ConsumerCopy.language(language)). Prepare it again before dictating." : "This language could not be removed. Finish dictation and try again."
            await refreshReservations(); releasing = false; coordinator.isManagingSpeechAssets = false
        }
    }
    func prepare() {
        guard !coordinator.busy, !coordinator.isManagingSpeechAssets else { return }
        let target = locale
        coordinator.isManagingSpeechAssets = true
        preparing = .some(nil); speechMessage = nil
        Task {
            do {
                try await AppleSpeechSetup.prepare(target) { fraction in Task { @MainActor in preparing = .some(fraction) } }
                speechMessage = "\(ConsumerCopy.language(target)) is ready on this iPhone."
            } catch { speechMessage = (error as? AppleSpeechRefusal)?.message ?? "This language could not be prepared. Check your connection and try again." }
            await refreshReservations()
            preparing = nil; coordinator.isManagingSpeechAssets = false
        }
    }
}
