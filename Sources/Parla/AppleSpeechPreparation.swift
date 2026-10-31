import Combine
import Foundation
import ParlaCore

struct AppleSpeechSnapshot: Equatable {
    enum Phase: String { case idle, checking, waiting, reserving, downloading, verifying, ready, stopping, unavailable }
    var phase: Phase = .idle
    var locale: String?
    var progress: AppleSpeechProgress?
    var refusal: AppleSpeechRefusal?
    var token = UUID()
    var message: String { refusal?.message ?? (phase == .ready ? "Apple Speech assets ready. Recognition rechecks installed state at use." : "Apple Speech: " + phase.rawValue) }
}
/// One app-only preparation and lease owner. Init/render never performs IO or native queries.
@MainActor final class AppleSpeechPreparation: ObservableObject {
    typealias Enqueue = (PendingOperation, @escaping () async -> Void, @escaping () async -> Void) -> Void
    @Published private(set) var snapshot = AppleSpeechSnapshot()
    var enqueue: Enqueue = { operation, _, _ in operation.revoke() }
    private let assets: AppleSpeechAssets, clock: AppleSpeechClock
    private let openStorage: () throws -> PreparationStorage
    private var storage: PreparationStorage?, record: AppleSpeechReservationRecord?
    private var trackingFailed = false
    private var references = Set<String>()
    private var configuredEngine: RecognitionEngine?
    private var target: String?
    private var epoch = UUID()
    private var settingsValid = false
    private var readyLocales = Set<String>()
    private var worker: PendingOperation?
    private var latestCheck: String?
    private let uses = AppleSpeechLeases()
    var retireHandles: () async -> Void = {}
    private var quit = false, restart = false, canceledQuit = false
    private var drain: Task<Void, Never>?
    var hasWork: Bool { worker != nil || uses.count > 0 }
    var admissionClosed: Bool { quit || restart }
    init(assets: AppleSpeechAssets, clock: AppleSpeechClock = AppleSpeechClock(), storage: @escaping () throws -> PreparationStorage) {
        self.assets = assets; self.clock = clock; openStorage = storage
    }
    static func application() -> AppleSpeechPreparation {
        AppleSpeechPreparation(assets: AppleSpeechNative.assets, storage: {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let parent = support.appendingPathComponent("Parla-apple-speech-reservations", isDirectory: true)
            if mkdir(parent.path, 0o700) != 0, errno != EEXIST { throw AppleSpeechRefusal.trackingUnavailable }
            return try PrivatePreparationStorage(root: parent.appendingPathComponent("v1", isDirectory: true))
        })
    }
    private func loadRecord() throws {
        guard !trackingFailed else { throw AppleSpeechRefusal.trackingUnavailable }
        if record != nil { return }
        do {
            let io = try openStorage(); let value = try AppleSpeechReservationRecord.decode(io.read())
            storage = io; record = value
        } catch { trackingFailed = true; throw AppleSpeechRefusal.trackingUnavailable }
    }
    private func persist(_ next: AppleSpeechReservationRecord, intent: Bool = false) throws {
        do {
            guard let storage else { throw AppleSpeechRefusal.trackingUnavailable }
            try storage.replace(try intent ? next.encodedIntent() : next.encoded(), authorized: { true })
            record = next
        } catch { trackingFailed = true; throw AppleSpeechRefusal.trackingUnavailable }
    }
    private func put(_ locale: String, state: AppleSpeechReservationRecord.State, prepared: Bool = false, intent: Bool = false) throws {
        guard var next = record else { throw AppleSpeechRefusal.trackingUnavailable }
        if let i = next.entries.firstIndex(where: { $0.locale == locale }) { next.entries[i] = .init(locale: locale, state: state, prepared: prepared) }
        else {
            guard next.entries.count < 32 else { throw AppleSpeechRefusal.capacity }
            next.entries.append(.init(locale: locale, state: state, prepared: prepared))
        }
        try persist(next, intent: intent)
    }
    func configure(_ settings: Settings, valid: Bool = true) {
        settingsValid = valid
        var next = Set<String>()
        if settings.recognitionEngine == .appleSpeech, let locale = settings.appleSpeechLocale { next.insert(locale) }
        for profile in settings.profiles where profile.enabled {
            var globals = settings; globals.profiles = [profile]
            let resolved = ProfileResolver.resolve(globals, at: ProfileDestination(bundleID: profile.targetKind == .app ? profile.target : "com.apple.Safari", browserURL: profile.targetKind == .host ? "https://" + profile.target : nil))
            if case .appleSpeech(let locale) = RecognitionRequest(settings: resolved.settings).selection { next.insert(locale) }
        }
        let changedReferences = references != next || configuredEngine != settings.recognitionEngine
        references = next; configuredEngine = settings.recognitionEngine
        let selected: String? = settings.recognitionEngine == .appleSpeech ? settings.appleSpeechLocale : nil
        if target != selected || changedReferences || !valid {
            epoch = UUID(); target = selected; cancel(); latestCheck = nil
            if worker == nil { snapshot = AppleSpeechSnapshot(locale: selected, refusal: valid ? nil : .configuration) }
        }
        if valid, let selected, !admissionClosed { recheck(selected) }
    }
    func draftChanged() {
        epoch = UUID(); settingsValid = false; latestCheck = nil; cancel()
        if worker == nil { snapshot = AppleSpeechSnapshot(refusal: .configuration) }
    }
    func deliberateEntry() { if canceledQuit { quit = false; canceledQuit = false } }
    func cachedRefusal(for request: RecognitionRequest, deliberate: Bool = false) -> AppleSpeechRefusal? {
        if deliberate { deliberateEntry() }
        if request.selection.engine == .invalid { return .configuration }
        guard case .appleSpeech(let locale) = request.selection else { return nil }
        if admissionClosed { return .closed }
        return readyLocales.contains(locale) ? nil : (snapshot.locale == locale ? snapshot.refusal : nil) ?? .needsPreparation
    }
    /// Every actual use repeats installed/reservation checks. No reserve/install ports exist in this method.
    func installedUse(_ locale: String, operation supplied: PendingOperation?) async throws -> AppleSpeechLease {
        guard !admissionClosed else { throw AppleSpeechRefusal.closed }
        try loadRecord()
        guard record?.entries.contains(where: { $0.locale == locale && $0.prepared }) == true else { throw AppleSpeechRefusal.needsPreparation }
        let operation = supplied ?? PendingOperation(name: "Apple Speech recognition")
        guard !operation.shouldAbort else { throw AppleSpeechRefusal.revoked }
        let lease = uses.retain(locale: locale, operation: operation) // protects observation and handle lifetime
        do {
            let observation = try await assets.observe(locale)
            try observation.validateInstalled()
            guard observation.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
            guard !admissionClosed, !operation.shouldAbort else { throw AppleSpeechRefusal.revoked }
            return lease
        } catch { lease.release(); throw error }
    }
    func recheck(_ locale: String) {
        guard !admissionClosed, settingsValid, AppleSpeechLocale.isValid(locale) else { return }
        if worker != nil { latestCheck = locale; return }
        start(.recheck, locale: locale)
    }
    enum Action { case prepare, recheck, release }
    func act(_ action: Action, locale: String, token: UUID) {
        guard snapshot.token == token, !admissionClosed, settingsValid, AppleSpeechLocale.isValid(locale), worker == nil else { return }
        start(action, locale: locale)
    }
    private func publish(_ phase: AppleSpeechSnapshot.Phase, locale: String, progress: AppleSpeechProgress? = nil, refusal: AppleSpeechRefusal? = nil) {
        snapshot = AppleSpeechSnapshot(phase: phase, locale: locale, progress: progress, refusal: refusal)
    }
    private func start(_ action: Action, locale: String) {
        let operation = PendingOperation(name: "Apple Speech language"), generation = epoch
        if action != .recheck { readyLocales.remove(locale) }
        worker = operation; publish(.waiting, locale: locale)
        enqueue(operation, { [self] in await run(action, locale: locale, generation: generation, operation: operation) }, { [self] in
            await MainActor.run { exited(operation, locale: locale) }
        })
    }
    private func exited(_ operation: PendingOperation, locale: String) {
        guard worker == operation else { return }
        worker = nil
        if snapshot.phase == .stopping { publish(.unavailable, locale: locale, refusal: .revoked) }
        if let check = latestCheck { latestCheck = nil; recheck(check) }
    }
    func cancel(token: UUID) { guard snapshot.token == token else { return }; cancel() }
    func cancel() {
        guard let worker else { return }
        worker.revoke(); publish(.stopping, locale: snapshot.locale ?? ""); worker.requestAbort()
    }
    private func current(_ operation: PendingOperation, _ generation: UUID) -> Bool {
        !operation.shouldAbort && generation == epoch && !admissionClosed && settingsValid
    }
    private func run(_ action: Action, locale: String, generation: UUID, operation: PendingOperation) async {
        guard current(operation, generation) else { return }
        let deadline = clock.now() + (action == .prepare ? 180 : 60)
        let watchdog = Task { [clock] in
            do {
                try await clock.wait(max(0, deadline - clock.now()))
                if !Task.isCancelled, clock.now() >= deadline {
                    operation.revoke(); publish(.stopping, locale: locale, refusal: .deadline); operation.requestAbort()
                }
            } catch { }
        }
        do {
            try loadRecord()
            publish(.checking, locale: locale)
            let initial = try await assets.observe(locale); try initial.validate()
            guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
            switch action {
            case .recheck:
                try initial.validateInstalled()
                guard initial.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
                guard record?.entries.contains(where: { $0.locale == locale && $0.prepared }) == true else { throw AppleSpeechRefusal.needsPreparation }
            case .prepare:
                guard initial.reserved.contains(locale) || initial.reserved.count < initial.capacity else { throw AppleSpeechRefusal.capacity }
                let knownOwned = record?.entries.contains { $0.locale == locale && $0.state == .owned } == true
                try put(locale, state: .intent, intent: true) // durable before any OS mutation
                publish(.reserving, locale: locale)
                let acquired = try await assets.reserve(locale)
                // A true reserve alone establishes ownership; false/preexisting never does.
                let owned = knownOwned || (acquired && !initial.reserved.contains(locale))
                try put(locale, state: owned ? .owned : .preparedUnknown)
                guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
                let request = try await assets.installation(locale)
                guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
                if let request {
                    publish(.downloading, locale: locale, progress: .init(fraction: nil, cancellable: true))
                    let cancel = AppleSpeechCancellation { request.cancel() }
                    let observer = operation.observePreparationRevocation { cancel.revoke() }
                    let stream = AsyncStream<AppleSpeechProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let progress = Task { [self] in
                        var last: TimeInterval? = clock.now()
                        for await scalar in stream.stream {
                            if let last { try? await clock.wait(max(0, 0.25 - (clock.now() - last))) }
                            guard !Task.isCancelled, current(operation, generation) else { continue }
                            publish(.downloading, locale: locale, progress: scalar); last = clock.now()
                        }
                    }
                    let outcome: Result<Void, Error>
                    do { try await request.download { stream.continuation.yield($0) }; outcome = .success(()) }
                    catch { outcome = .failure(error) }
                    // OS may retry downloads after this initial attempt; cancellation is not network-stop proof.
                    stream.continuation.finish(); progress.cancel(); await progress.value
                    operation.removePreparationRevocation(observer); await cancel.join()
                    try outcome.get()
                }
                guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
                publish(.verifying, locale: locale)
                let final = try await assets.observe(locale); try final.validateInstalled()
                guard final.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
                guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
                try put(locale, state: owned ? .owned : .preparedUnknown, prepared: true)
            case .release:
                guard !references.contains(locale), !uses.contains(locale),
                      record?.entries.contains(where: { $0.locale == locale && $0.state == .owned }) == true else { throw AppleSpeechRefusal.protectedReservation }
                try put(locale, state: .releasing, intent: true)
                _ = await assets.release(locale)
                let final = try await assets.observe(locale)
                guard !final.reserved.contains(locale) else { throw AppleSpeechRefusal.reservationUnavailable }
                guard var next = record else { throw AppleSpeechRefusal.trackingUnavailable }
                next.entries.removeAll { $0.locale == locale }; try persist(next)
            }
            guard current(operation, generation), clock.now() < deadline else { throw AppleSpeechRefusal.revoked }
            if action == .release { readyLocales.remove(locale) } else { readyLocales.insert(locale) }
            publish(action == .release ? .idle : .ready, locale: locale)
        } catch {
            readyLocales.remove(locale)
            let reason = clock.now() >= deadline ? AppleSpeechRefusal.deadline : error as? AppleSpeechRefusal ?? .native
            if generation == epoch { publish(operation.shouldAbort ? .stopping : .unavailable, locale: locale, refusal: reason) }
        }
        watchdog.cancel(); await watchdog.value
    }
    private func close(restarting: Bool) {
        if restarting { restart = true } else { quit = true; canceledQuit = false }
        epoch = UUID(); latestCheck = nil; cancel()
        for operation in uses.operations { operation.revoke(); operation.requestAbort() }
    }
    func beginShutdown(chain: @escaping () -> Task<Void, Never>?, reply: @escaping (Bool) -> Void) {
        close(restarting: false)
        guard drain == nil else { reply(false); return }
        drain = Task { [self] in
            var previous = chain()
            while true {
                await previous?.value
                let next = chain(); if next == previous { break }; previous = next
            }
            await retireHandles(); drain = nil; reply(!hasWork)
        }
    }
    func cancelShutdown() { canceledQuit = true }
    func reserveRestart() -> Bool {
        guard !restart, !quit else { return false }; close(restarting: true); return true
    }
    func releaseRestart() { restart = false }
    func retireForRestart() async { await retireHandles() }
    func restartReady() -> Bool { restart && !hasWork }
}
