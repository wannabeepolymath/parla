import Combine
import Foundation
import ParlaCore

struct CatalogDownloadRow: Equatable {
    enum Phase: String { case downloading = "Downloading", pausing = "Pausing", verifying = "Verifying", installing = "Installing", paused = "Paused", failed = "Retry", installed = "Verified" }
    var phase: Phase
    var percent: Int = 0
    var active: Bool { [.downloading, .pausing, .verifying, .installing].contains(phase) }
    var actions: [CatalogDownloadAction] {
        switch phase {
        case .downloading, .verifying, .installing: return [.pause]
        case .pausing: return []
        case .paused: return [.resume, .discard]
        case .failed: return [.retry, .discard]
        case .installed: return []
        }
    }
}
enum CatalogDownloadAction: String { case download = "Download", pause = "Pause", resume = "Resume", retry = "Retry", discard = "Discard" }

/// Main-thread owner of publication and UI. The concrete task remains retained
/// until disk/transport/install exits. UUID + artifact + generation are captured
/// in the worker; selection authority has its own immediately revoked epoch.
@MainActor
final class CatalogDownloadOwner: ObservableObject {
    @Published private(set) var rows: [String: CatalogDownloadRow] = [:]
    private(set) var activeID: String?
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var permit: Permit?
    private var settlement: ((Bool) -> Void)?
    private var quitting = false
    private var restartReserved = false
    private var discarding = false
    let catalog: [ModelCatalog.Model]
    let storage: CatalogDownloadStorage
    private let transport: CatalogDownloadTransport
    private let chunkBytes: Int64
    private let enqueueProgress: (@escaping @MainActor () -> Void) -> Void
    private let destination: (ModelCatalog.Model) -> URL
    private let cache: VerifiedCache
    private let installer: (URL, ModelCatalog.Model, URL, VerifiedCache) throws -> Void
    /// Supplied by the actual Hub/settings binding.
    var selectionIntent: (ModelCatalog.Model) -> (() -> Void) = { _ in {} }
    var onStart: () -> Void = {}
    var onFailure: () -> Void = {}
    var isActive: Bool { task != nil }

    init(root: URL, catalog: [ModelCatalog.Model] = ModelCatalog.all,
         transport: CatalogDownloadTransport = CatalogURLSessionTransport(), chunkBytes: Int64 = 8 << 20,
         destination: @escaping (ModelCatalog.Model) -> URL = { URL(fileURLWithPath: ModelCatalog.path(for: $0)) },
         cache: VerifiedCache = VerifiedCache(),
         enqueueProgress: @escaping (@escaping @MainActor () -> Void) -> Void = { event in DispatchQueue.main.async { event() } },
         installer: @escaping (URL, ModelCatalog.Model, URL, VerifiedCache) throws -> Void = { try ModelCatalog.install(staged: $0, as: $1, at: $2, cache: $3) }) {
        precondition(catalog.count <= 3 && Set(catalog.map(\.id)).count == catalog.count && chunkBytes > 0)
        self.catalog = catalog; self.storage = CatalogDownloadStorage(root: root, catalog: catalog)
        self.transport = transport; self.chunkBytes = chunkBytes; self.destination = destination
        self.cache = cache; self.installer = installer; self.enqueueProgress = enqueueProgress
        // Discovery is passive: bounded metadata only, no network/hash/install,
        // settings, credentials or model selection.
        for model in catalog {
            do {
                if let m = try storage.inspect(model) {
                    rows[model.id] = .init(phase: .paused, percent: Int(m.committed * 100 / model.bytes))
                }
            } catch { rows[model.id] = .init(phase: .failed) }
        }
    }
    func act(_ action: CatalogDownloadAction, model: ModelCatalog.Model) {
        guard catalog.contains(model) else { return }
        switch action {
        case .download, .resume, .retry: start(model)
        case .pause: if activeID == model.id { pause() }
        case .discard:
            guard activeID == nil || activeID == model.id else { return }
            if isActive { discarding = true; pause() }
            else { discard(model) }
        }
    }
    private func start(_ model: ModelCatalog.Model) {
        guard !isActive, !quitting, !restartReserved else { return }
        let id = UUID(), authority = Permit(), intent = selectionIntent(model)
        onStart()
        token = id; permit = authority; activeID = model.id; discarding = false
        rows[model.id] = .init(phase: .downloading)
        let storage = storage, transport = transport, chunkBytes = chunkBytes, enqueueProgress = enqueueProgress
        let dest = destination(model), cache = cache, installer = installer
        let work = Task.detached { [weak self] in
            let result: Result<Void, Error>
            do {
                try await Self.transfer(model, generation: id, authority: authority, storage: storage,
                    transport: transport, chunkBytes: chunkBytes, destination: dest, cache: cache, installer: installer) { phase, committed in
                    enqueueProgress { [weak self] in
                        guard let self, self.token == id, self.activeID == model.id, authority.allowed else { return }
                        self.rows[model.id] = .init(phase: phase, percent: Int(committed * 100 / model.bytes))
                    }
                }
                result = .success(())
            } catch { result = .failure(error) }
            await MainActor.run { [weak self] in self?.finished(model, id: id, authority: authority, intent: intent, result: result) }
        }
        task = work
    }
    func pause() {
        guard let model = activeID, isActive else { return }
        permit?.revoke(); task?.cancel()
        rows[model] = .init(phase: .pausing, percent: rows[model]?.percent ?? 0)
    }
    private func discard(_ model: ModelCatalog.Model) {
        do { try storage.discard(model); rows[model.id] = nil }
        catch { rows[model.id] = .init(phase: .failed); onFailure() }
    }
    private func finished(_ model: ModelCatalog.Model, id: UUID, authority: Permit,
                          intent: @escaping () -> Void, result: Result<Void, Error>) {
        guard token == id, activeID == model.id else { return }
        task = nil; token = nil; permit = nil; activeID = nil
        let canPublish = authority.allowed
        switch result {
        case .success:
            rows[model.id] = .init(phase: .installed, percent: 100)
            if canPublish { intent() }
        case .failure:
            if canPublish { rows[model.id] = .init(phase: .failed, percent: rows[model.id]?.percent ?? 0); onFailure() }
            else {
                let committed = (try? storage.inspect(model))?.committed ?? 0
                rows[model.id] = .init(phase: .paused, percent: Int(committed * 100 / model.bytes))
            }
        }
        if discarding { discarding = false; discard(model) }
        let done = settlement; settlement = nil; done?(true)
    }
    func beginShutdown(_ reply: @escaping (Bool) -> Void) {
        quitting = true
        guard isActive else { reply(true); return }
        settlement = reply; pause()
    }
    func cancelShutdown() { settlement = nil; quitting = false } // no ghost resume
    func waitForExit() async { await task?.value }
    func claimRestartIfIdle() -> Bool {
        guard !isActive else { return false }
        restartReserved = true
        return true
    }
    /// A failed update releases only its reservation, never an independent quit.
    func releaseRestartReservation() { restartReserved = false }

    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        var allowed: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        func revoke() { lock.lock(); valid = false; lock.unlock() }
        func check() throws { guard allowed, !Task.isCancelled else { throw CancellationError() } }
        /// Linearize checkpoint publication against Pause. Data and journal
        /// writes/synchronization happen before this short rename-only gate.
        func commit(_ publish: () throws -> Void) throws {
            lock.lock(); defer { lock.unlock() }
            guard valid, !Task.isCancelled else { throw CancellationError() }
            try publish()
        }
    }

    private nonisolated static func transfer(_ model: ModelCatalog.Model, generation: UUID, authority: Permit,
        storage: CatalogDownloadStorage, transport: CatalogDownloadTransport, chunkBytes: Int64,
        destination: URL, cache: VerifiedCache,
        installer: (URL, ModelCatalog.Model, URL, VerifiedCache) throws -> Void,
        progress: @escaping (CatalogDownloadRow.Phase, Int64) -> Void) async throws {
        try authority.check()
        // A crash after publication may leave a completed journal whose stage
        // was moved. Recovery is explicit and re-verifies the published bytes;
        // discovery never hashes, caches or selects anything.
        if let completed = try storage.read(model), completed.matches(model), completed.committed == model.bytes,
           try storage.stageIsMissing(completed) {
            try ModelCatalog.verify(fileAt: destination, is: model)
            try authority.check()
            cache.record(destination)
            try storage.finish(model)
            return
        }
        var manifest = try storage.prepare(model, generation: generation)
        var restarted = false, full = false
        while manifest.committed < model.bytes {
            try authority.check()
            if manifest.committed > 0 && manifest.validator == nil {
                guard !restarted else { throw CatalogDownloadFailure() }
                try storage.reset(&manifest, model, commit: authority.commit); restarted = true; full = true
            }
            let start = manifest.committed, end = start + min(chunkBytes, model.bytes - start) - 1
            var request = URLRequest(url: model.url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !full { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
            if start > 0 { request.setValue(manifest.validator?.value, forHTTPHeaderField: "If-Range") }
            let chunk = try storage.chunk()
            defer { storage.removeChunk(chunk) }
            let http = try await transport.fetch(request, to: chunk, maximum: model.bytes, chunkMaximum: end - start + 1)
            try authority.check()
            guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
                  !(http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("multipart") ?? false) else { throw CatalogDownloadFailure() }
            let validator = CatalogDownloadValidator.response(http)
            let count = try storage.chunkSize(chunk, maximum: model.bytes)
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard Int64(length) == count else { throw CatalogDownloadFailure() }
            }
            switch http.statusCode {
            case 206:
                guard !full, http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(model.bytes)",
                      count == end - start + 1,
                      start == 0 || (manifest.validator != nil && validator == manifest.validator) else { throw CatalogDownloadFailure() }
            case 200:
                // An ignored Range / changed If-Range is a separate bounded
                // whole response. Never join it to the old prefix.
                guard count == model.bytes else { throw CatalogDownloadFailure() }
                if start > 0 { try storage.reset(&manifest, model, commit: authority.commit) }
            case 416:
                guard http.value(forHTTPHeaderField: "Content-Range") == "bytes */\(model.bytes)", count == 0,
                      !restarted else { throw CatalogDownloadFailure() }
                try storage.reset(&manifest, model, commit: authority.commit); restarted = true; full = true
                continue
            default: throw CatalogDownloadFailure()
            }
            try authority.check()
            try storage.append(chunk, to: &manifest, count: count, validator: validator, model: model, commit: authority.commit)
            progress(.downloading, manifest.committed)
        }
        // Complete local pinned bytes (including a recovered complete stage)
        // always take the unchanged size/markup/full-SHA installer.
        try authority.check()
        progress(.verifying, manifest.committed)
        let stage = try storage.stage(manifest)
        try storage.fault(.install)
        try authority.check()
        progress(.installing, manifest.committed)
        do { try installer(stage, model, destination, cache) }
        catch let error as ModelFileError {
            // Rejected bytes cannot become useful on another verification
            // attempt. Retain an empty owned checkpoint for explicit Retry;
            // never trigger a hidden replacement request here.
            try storage.reset(&manifest, model, commit: authority.commit)
            throw error
        }
        try storage.fault(.publication)
        try storage.finish(model)
    }
}
