import AVFoundation
import Foundation

/// Serialized, process-owned recovery storage. A stash owns its WAV until
/// resolve (including failed recognition); recovery actions own an exclusive lease.
public final class RecordingStore: @unchecked Sendable {
    public static let shared = RecordingStore(requireValidatedPolicy: true)
    public static let retentionDays = 7
    public static let didChange = Notification.Name("ParlaRecordingsChanged")
    public static let dayRange = 1...30
    public static let maximumBytes = 128 * 1_024 * 1_024
    public struct Policy: Equatable, Sendable {
        public let enabled: Bool
        public let days: Int
        public init(enabled: Bool = true, days: Int = 7) {
            self.enabled = enabled; self.days = min(30, max(1, days))
        }
    }
    public struct Failure: Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
    public struct Summary: Equatable, Sendable {
        public let count: Int
        public let bytes: Int
        public init(count: Int, bytes: Int) { self.count = count; self.bytes = bytes }
    }
    public struct Outcome: Equatable {
        public var removed = 0
        public var busy = 0
        public var failed = 0
        public var message: String {
            "Deleted \(removed)." + (busy > 0 ? " \(busy) in use." : "") + (failed > 0 ? " \(failed) couldn’t be deleted." : "")
        }
    }
    public struct Descriptor: Identifiable, Equatable {
        public let id: String
        public let url: URL
        public let date: Date?
        public let expiry: Date?
        public let bytes: Int
        public let duration: TimeInterval?
        public let reason: String?
        public var available: Bool { reason == nil }
    }
    fileprivate struct Identity: Equatable {
        let inode: UInt64
        let bytes: Int
        let modified: Date
    }
    public final class Lease: @unchecked Sendable {
        public let url: URL
        public let operation = PendingOperation(name: "Recovery transcription")
        fileprivate let token = UUID()
        fileprivate var identity: Identity?
        fileprivate var revoked = false
        fileprivate var onRevoke: (() -> Void)?
        fileprivate init(_ url: URL, identity: Identity? = nil) { self.url = url; self.identity = identity }
    }
    public let directory: URL
    private let resolvedDirectory: URL
    public let keepAll: Bool
    private let lock = NSRecursiveLock()
    private var active: [String: Lease] = [:]
    private var captures: Set<UUID> = []
    private var policyValue: Policy?
    private var policyErrorValue: String?
    private var errorValue: String?
    private let writer: ([Float], URL) throws -> Void
    private let remover: (URL) throws -> Void
    /// Optional injected I/O entry observer, inert in production. No content.
    public enum Access { case configure, refreshPolicy, stash, resolve, discard, complete, acquire, prune }
    private let access: (Access) -> Void
    public var policy: Policy? { locked { policyValue } }
    public var policyStatus: String? { locked { policyErrorValue } }
    public var lastError: String? { locked { errorValue } }

    /// Injected stores default to a valid policy. Production shared storage must
    /// be configured from a successfully loaded SettingsStore, never its fallback.
    public init(directory: URL? = nil,
                keepAll: Bool = ProcessInfo.processInfo.environment["PARLA_KEEP_RECORDINGS"] == "1",
                requireValidatedPolicy: Bool = false,
                access: @escaping (Access) -> Void = { _ in },
                writer: @escaping ([Float], URL) throws -> Void = RecordingStore.writeWAV,
                remover: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.access = access
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Parla/recordings")).standardizedFileURL
        self.resolvedDirectory = self.directory.resolvingSymlinksInPath()
        self.keepAll = keepAll; self.writer = writer; self.remover = remover
        policyValue = requireValidatedPolicy ? nil : Policy()
        policyErrorValue = requireValidatedPolicy ? "Settings can’t be read, so audio from failed dictations isn’t being saved." : nil
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    private func report(_ message: String) {
        guard errorValue != message else { return }
        errorValue = message; changed()
    }

    public func configure(settings: Settings, error: String?, now: Date = Date()) {
        locked {
            access(.configure)
            let previousPolicy = policyValue, previousStatus = policyErrorValue
            defer { if previousPolicy != policyValue || previousStatus != policyErrorValue { changed() } }
            if error == nil {
                policyValue = Policy(enabled: settings.recoveryAudioEnabled, days: settings.recoveryAudioDays)
                policyErrorValue = nil
            } else {
                policyErrorValue = policyValue == nil
                    ? "Settings can’t be read, so audio from failed dictations isn’t being saved."
                    : "Settings can’t be read. Fix settings.json to transcribe or save."
            }
            _ = prune(now: now)
        }
    }
    private func owned(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path == url.path && url.deletingLastPathComponent().standardizedFileURL.path == directory.path
            && url.pathExtension.lowercased() == "wav"
    }
    private func owner(_ url: URL) -> Lease? {
        // macOS commonly uses case-insensitive volumes; an alternate spelling
        // must not bypass ownership (conservative on case-sensitive volumes).
        active.values.first { $0.url.lastPathComponent.lowercased() == url.lastPathComponent.lowercased() }
    }
    private func busy(_ url: URL) -> Bool { owner(url) != nil }
    private func safeRoot() throws {
        // Do not follow a recordings directory replaced by a symbolic link.
        guard directory.resolvingSymlinksInPath().path == resolvedDirectory.path else { throw Failure("The recordings folder is an alias, so Parla won’t use it.") }
        do {
            let a = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard a[.type] as? FileAttributeType == .typeDirectory else { throw Failure("Recordings folder is unavailable.") }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }
    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        guard owned(url) else { throw Failure("This file isn’t in Parla’s recordings folder.") }
        try safeRoot()
        return try FileManager.default.attributesOfItem(atPath: url.path) // lstat: never follows leaf symlinks
    }
    private func identity(_ url: URL) throws -> Identity {
        let a = try attributes(url)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let inode = a[.systemFileNumber] as? UInt64, let bytes = a[.size] as? Int,
              let modified = a[.modificationDate] as? Date else { throw Failure("Not a regular audio file.") }
        return Identity(inode: inode, bytes: bytes, modified: modified)
    }
    private func metadata(_ url: URL, now: Date, allowPartial: Bool = false) throws -> (Identity, Double) {
        guard let policyValue else { throw Failure("Fix settings.json first.") }
        guard allowPartial || !FileManager.default.fileExists(atPath: partialMarker(for: url).path) else { throw Failure("This recording is incomplete. Delete it.") }
        let stamp = try identity(url)
        guard stamp.modified >= now.addingTimeInterval(-Double(policyValue.days) * 86_400) else { throw Failure("Recording expired.") }
        guard stamp.bytes > 44, stamp.bytes <= Self.maximumBytes else { throw Failure("Empty or oversized recording.") }
        let header = try FileHandle(forReadingFrom: url)
        defer { try? header.close() }
        let prefix = try header.read(upToCount: 12) ?? Data()
        guard prefix.count == 12, String(data: prefix.prefix(4), encoding: .ascii) == "RIFF",
              String(data: prefix.suffix(4), encoding: .ascii) == "WAVE" else { throw Failure("Corrupt or unsupported WAV.") }
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let seconds = Double(file.length) / format.sampleRate
        guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              format.channelCount > 0, format.channelCount <= 8, seconds.isFinite,
              seconds > 0, seconds <= 1_200 else { throw Failure("Empty, unsupported or longer than 20 minutes.") }
        return (stamp, seconds)
    }
    private func readURLs(includeOrphans: Bool = false) throws -> [URL] {
        try safeRoot()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var wavs = Set(names.filter { $0.lowercased().hasSuffix(".wav") })
        if includeOrphans {
            for name in names {
                if name.hasSuffix(".hyp.txt") {
                    let candidate = String(name.dropLast(8)) + ".wav"
                    if !wavs.contains(where: { $0.lowercased() == candidate.lowercased() }) { wavs.insert(candidate) }
                }
                if name.hasSuffix(".wav.partial") {
                    let candidate = String(name.dropLast(8))
                    if !wavs.contains(where: { $0.lowercased() == candidate.lowercased() }) { wavs.insert(candidate) }
                }
            }
        }
        return wavs.map { directory.appendingPathComponent($0) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    private func urls() -> [URL] {
        do { return try readURLs() }
        catch { report("Couldn’t read the recordings folder."); return [] }
    }

    /// Ownership starts before the injected writer runs, and ends only at resolve.
    @discardableResult public func refreshPolicy(from settings: SettingsStore, now: Date = Date()) -> Bool {
        locked {
            access(.refreshPolicy)
            let current = settings.load()
            let error = settings.lastError
            configure(settings: current, error: error, now: now)
            return error == nil
        }
    }
    public func stash(_ samples: [Float], settings: SettingsStore, now: Date = Date()) -> URL? {
        locked {
            access(.stash)
            refreshPolicy(from: settings, now: now)
            return stash(samples, now: now)
        }
    }
    public func isActive(_ lease: Lease) -> Bool {
        locked { !lease.revoked && active[lease.url.path]?.token == lease.token }
    }
    public func stash(_ samples: [Float], now: Date = Date()) -> URL? {
        locked {
            access(.stash)
            _ = prune(now: now)
            guard policyValue?.enabled == true, !samples.isEmpty else { return nil }
            var lease: Lease?
            do {
                try safeRoot()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = uniqueURL(base: Self.name(now))
                let capture = Lease(url); lease = capture
                active[url.path] = capture; captures.insert(capture.token)
                // A crash or failed cleanup during writing leaves a durable nonviable marker.
                try Data().write(to: partialMarker(for: url), options: .atomic)
                try writer(samples, url)
                capture.identity = try metadata(url, now: now, allowPartial: true).0
                try remover(partialMarker(for: url))
                changed()
                return url
            } catch {
                var partial = false
                if let lease {
                    active[lease.url.path] = nil; captures.remove(lease.token)
                    // A failed/partial write is never offered as a failed dictation.
                    do { try removeOwned(lease.url) } catch { partial = true }
                }
                report(partial ? "Couldn’t save the audio, and a partial file was left. Delete it in Data & Privacy." : "Couldn’t save the audio. Dictation still works.")
                return nil
            }
        }
    }
    public func resolve(_ url: URL?, transcript: String?, secure: Bool) {
        locked {
            access(.resolve)
            guard let url, owned(url) else { return }
            if secure {
                let lease = owner(url)
                let target = lease?.url ?? url
                if let lease { lease.revoked = true; lease.onRevoke?(); release(lease) }
                do { try removeOwned(target); changed() }
                catch { report("Couldn’t delete a recording made in a password field. Delete it in Data & Privacy.") }
                return
            }
            guard let lease = active[url.path], captures.contains(lease.token) else { return }
            finish(lease, transcript: transcript)
        }
    }
    /// Explicit capture disposal authority survives resolve, including corpus
    /// marking. It cannot be acquired for an unrelated recovery recording.
    public struct CaptureDisposal {
        fileprivate let lease: Lease
    }
    public func captureDisposal(for url: URL?) -> CaptureDisposal? {
        locked {
            guard let url, let lease = active[url.path], captures.contains(lease.token) else { return nil }
            return CaptureDisposal(lease: lease)
        }
    }
    @discardableResult public func discard(_ ownership: CaptureDisposal) -> Bool {
        locked {
            access(.discard)
            let lease = ownership.lease
            // An already-resolved capture may have been acquired by recovery or
            // replaced externally. That is no longer ours to delete.
            guard owner(lease.url).map({ $0.token == lease.token }) != false else {
                report("Couldn’t delete the audio because it’s in use."); return false
            }
            do {
                do {
                    guard try identity(lease.url) == lease.identity else { throw Failure("Recording changed.") }
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    // Successful default resolution already removed the WAV.
                }
                lease.revoked = true
                release(lease)
                try removeOwned(lease.url)
                changed(); return true
            } catch {
                release(lease)
                report("Discarded, but its audio couldn’t be deleted. Delete it in Data & Privacy.")
                return false
            }
        }
    }

    private func finish(_ lease: Lease, transcript: String?) {
        defer { release(lease) }
        guard !lease.revoked else { return }
        guard let transcript, !transcript.isEmpty else { return }
        do {
            guard try identity(lease.url) == lease.identity else { throw Failure("Recording changed.") }
            if keepAll, policyValue?.enabled == true {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: sidecar(for: lease.url).path),
                   attributes[.type] as? FileAttributeType != .typeRegular { throw Failure("Unsafe corpus sidecar.") }
                try transcript.write(to: sidecar(for: lease.url), atomically: true, encoding: .utf8)
            } else { try removeOwned(lease.url) }
            changed()
        } catch { report("Done, but its audio couldn’t be deleted. Delete it in Data & Privacy.") }
    }
    public func complete(_ lease: Lease, transcript: String?) {
        locked {
            access(.complete)
            guard active[lease.url.path]?.token == lease.token else { return }; finish(lease, transcript: transcript) }
    }
    public func release(_ lease: Lease) {
        locked {
            if active[lease.url.path]?.token == lease.token { active[lease.url.path] = nil; changed() }
            captures.remove(lease.token); lease.revoked = true; lease.onRevoke = nil
        }
    }
    public func acquire(_ url: URL, now: Date = Date(), onRevoke: (() -> Void)? = nil) throws -> Lease {
        try locked {
            access(.acquire)
            guard !busy(url) else { throw Failure("Recording is busy.") }
            // Preserve the expiry reason while still sweeping before every action.
            let eligibility = Result { try metadata(url, now: now) }
            _ = prune(now: now)
            let stamp = try eligibility.get().0
            guard !FileManager.default.fileExists(atPath: sidecar(for: url).path) else { throw Failure("This recording didn’t fail, so it isn’t listed.") }
            let lease = Lease(url, identity: stamp); lease.onRevoke = onRevoke
            active[url.path] = lease; changed(); return lease
        }
    }
    public func validate(_ lease: Lease, now: Date = Date()) throws {
        try locked {
            guard !lease.revoked, active[lease.url.path]?.token == lease.token else { throw Failure("Recording use was stopped.") }
            guard !FileManager.default.fileExists(atPath: sidecar(for: lease.url).path) else { throw Failure("This recording didn’t fail, so it isn’t listed.") }
            guard try metadata(lease.url, now: now).0 == lease.identity else { throw Failure("This recording changed. Click Refresh.") }
        }
    }
    /// Exact same loader as eval; revalidate at queued use, before any model load.
    public func samples(_ lease: Lease, now: Date = Date()) throws -> [Float] {
        try locked {
            try validate(lease, now: now)
            do {
                let samples = try Eval.loadSamples(url: lease.url)
                try validate(lease, now: now)
                guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw Failure("Audio is empty or corrupt.") }
                return samples
            } catch { report("Couldn’t read the audio file."); throw Failure("Couldn’t read recovery audio.") }
        }
    }
    public func descriptors(now: Date = Date()) -> [Descriptor] {
        locked {
            _ = prune(now: now)
            return urls().compactMap { url in
                guard !FileManager.default.fileExists(atPath: sidecar(for: url).path) else { return nil }
                let stamp = try? identity(url)
                var duration: Double?
                let reason: String?
                if busy(url) { return nil } // never offers active write/ASR/playback
                do { duration = try metadata(url, now: now).1; reason = nil }
                catch { reason = (error as? Failure)?.message ?? "Corrupt or unreadable WAV." }
                return Descriptor(id: url.lastPathComponent, url: url, date: stamp?.modified,
                    expiry: stamp.flatMap { stamp in policyValue.map { stamp.modified.addingTimeInterval(Double($0.days) * 86_400) } },
                    bytes: stamp?.bytes ?? 0, duration: duration, reason: reason)
            }
        }
    }
    @discardableResult public func prune(now: Date = Date()) -> Int {
        locked {
            access(.prune)
            guard let policyValue else { return 0 }
            let cutoff = now.addingTimeInterval(-Double(policyValue.days) * 86_400)
            var removed = 0
            for url in urls() where !busy(url) {
                guard let stamp = try? identity(url), stamp.modified < cutoff else { continue }
                do { try removeOwned(url); removed += 1 }
                catch { report("Couldn’t delete an expired recording. Try again.") }
            }
            if removed > 0 { changed() }; return removed
        }
    }
    public func summary() -> Summary {
        locked {
            let files = urls().filter { !busy($0) }
            return Summary(count: files.count, bytes: files.reduce(0) { $0 + ((try? identity($1).bytes) ?? 0) })
        }
    }
    public func recordings() -> [URL] { locked { urls().filter { !busy($0) } } }
    @discardableResult public func delete(_ url: URL, now: Date = Date()) -> Bool {
        locked {
            guard !busy(url) else { report("This recording is in use, so it wasn’t deleted."); return false }
            do { try removeOwned(url); _ = prune(now: now); changed(); return true }
            catch { report("Couldn’t delete the recording. Try again."); return false }
        }
    }
    @discardableResult public func clear(now: Date = Date()) -> Outcome {
        locked {
            var result = Outcome()
            result.removed = prune(now: now)
            let files: [URL]
            do { files = try readURLs(includeOrphans: true) }
            catch { result.failed = 1; report("Couldn’t read the recordings folder. Nothing was deleted."); return result }
            for url in files {
                if busy(url) { result.busy += 1; continue }
                do { try removeOwned(url); result.removed += 1 }
                catch { result.failed += 1; report("Couldn’t delete some recordings. Try again.") }
            }
            changed(); return result
        }
    }
    private func removeOwned(_ url: URL) throws {
        guard owned(url) else { throw Failure("Outside owned folder.") }; try safeRoot()
        // Unlink leaves only. Attempt audio and hypothesis independently; keep
        // an unfinished marker whenever removal of its audio failed.
        var failure: Error?
        func unlink(_ path: URL) throws {
            do {
                let a = try FileManager.default.attributesOfItem(atPath: path.path)
                guard a[.type] as? FileAttributeType != .typeDirectory else { throw Failure("Refusing directory deletion.") }
                try remover(path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        }
        var audioRemoved = false
        do { try unlink(url); audioRemoved = true } catch { failure = error }
        do { try unlink(sidecar(for: url)) } catch { failure = failure ?? error }
        if audioRemoved { do { try unlink(partialMarker(for: url)) } catch { failure = failure ?? error } }
        if let failure { throw failure }
    }

    private func uniqueURL(base: String) -> URL {
        var url = directory.appendingPathComponent(base + ".wav"); var n = 1
        while [url, sidecar(for: url), partialMarker(for: url)].contains(where: {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil
        }) || active[url.path] != nil {
            url = directory.appendingPathComponent("\(base)-\(n).wav"); n += 1
        }
        return url
    }
    private func partialMarker(for url: URL) -> URL { url.appendingPathExtension("partial") }
    private func sidecar(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("hyp.txt") }

    // MARK: - WAV

    /// Sortable, second-plus-millisecond so two dictations can't collide, and
    /// readable enough that a user looking at the folder knows what they have.
    static func name(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// 16 kHz mono 16-bit PCM — the same thing `sox -d -r 16000 -c 1` produces,
    /// which is what `eval/cases` holds and what `Eval.loadSamples` reads.
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.targetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let format = file.processingFormat   // float32 mono; AVAudioFile converts on write
        var offset = 0
        while offset < samples.count {
            let n = min(16_384, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(n)),
                  let channel = buf.floatChannelData?[0] else { throw Failure("Not enough memory to read the audio.") }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + offset, count: n) }
            try file.write(from: buf)
            offset += n
        }
    }
}
