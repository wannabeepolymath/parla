import AVFoundation
import Foundation

/// The dictation's audio, written to disk *before* whisper runs and deleted the
/// moment it comes back.
///
/// The window that protects is the one Handy #1332 lives in: a crash inside the
/// transcription pass takes the only copy of what the user said with it and the
/// dictation is simply gone. Writing first costs a few ms and one 320 KB file on
/// a typical dictation, and makes that failure recoverable instead of silent.
///
/// Privacy is the design constraint, so the defaults are narrow: nothing
/// survives a successful dictation, anything that touched a password field is
/// deleted before any other rule is consulted, and whatever is left goes after
/// `retentionDays`. The Hub shows the folder, the count and the retention, and
/// can empty it — this is not allowed to be a directory that quietly fills with
/// the user's voice.
///
/// `PARLA_KEEP_RECORDINGS=1` (env-gated like `Trace`, and surfaced in the Hub
/// when it is on) additionally keeps *successful* dictations with whisper's own
/// output beside each file. That is the eval-corpus collector `eval/README.md`
/// asks for: 16 kHz mono WAVs in exactly the shape `eval/cases` consumes, so a
/// week of ordinary use produces the audio cases the ASR leg has never had.
public final class RecordingStore: @unchecked Sendable {
    /// Shared because both the dictation interpreter and the Hub reach it, and
    /// neither owns the other. Same reason `DictionaryLearner.Store` is one.
    public static let shared = RecordingStore()

    /// Visible in the Hub next to the count — see `PrivacyPage`. A constant
    /// rather than a setting: one number nobody has asked to tune, and every
    /// knob here is a knob that can be left on the wrong value.
    public static let retentionDays = 7

    public let directory: URL
    /// Keep successful dictations too (corpus collection). Injected for tests;
    /// the app reads the env once, like `Trace.enabled`.
    public let keepAll: Bool

    public struct Summary: Equatable, Sendable {
        public let count: Int
        public let bytes: Int
        public init(count: Int, bytes: Int) { self.count = count; self.bytes = bytes }
    }

    public init(directory: URL? = nil,
                keepAll: Bool = ProcessInfo.processInfo.environment["PARLA_KEEP_RECORDINGS"] == "1") {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/recordings")
        self.keepAll = keepAll
    }

    // MARK: - Write / resolve

    /// Persist this dictation's audio and return where it went. nil on any
    /// failure — the safety net must never be the thing that fails a dictation.
    ///
    /// `now` is the same injected clock `prune` takes, for the same reason: the
    /// filename is derived from it, so a test can pin the instant and make the
    /// name-collision dodge certain instead of racing a real millisecond.
    public func stash(_ samples: [Float], now: Date = Date()) -> URL? {
        guard !samples.isEmpty else { return nil }
        prune(now: now)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = uniqueURL(base: Self.name(now))
            try Self.writeWAV(samples, to: url)
            return url
        } catch {
            NSLog("%@", "Parla recordings: write failed: \(error)")
            return nil
        }
    }

    /// Decide what happens to a stashed file once the pass is over.
    ///
    /// "Success" is deliberately *a transcript exists*, not *the text landed*:
    /// the file's whole job is to survive the transcription, and by here it has.
    /// Everything else — empty output, a model that never loaded — leaves the
    /// audio as the only evidence of what went wrong, which is the point.
    ///
    /// `secure` outranks both. The flow already refuses a password field at
    /// `.focusSampled` (the capture is discarded, so nothing reaches here at
    /// all); this covers the other half, focus *moving* into one between fn-down
    /// and landing, which the reducer catches at `transcribed` and this must not
    /// be able to outlive.
    public func resolve(_ url: URL?, transcript: String?, secure: Bool) {
        guard let url else { return }
        guard !secure else { return remove(url) }
        guard let transcript, !transcript.isEmpty else { return }  // failure: keep
        guard keepAll else { return remove(url) }
        // Corpus mode. Named `.hyp.txt`, NOT the `.raw.txt` eval reads as its ASR
        // reference: the reference has to be what a human heard, and scoring
        // whisper against its own hypothesis would report 0 % WER forever. This
        // is the draft you correct into `NAME.raw.txt`.
        try? transcript.write(to: sidecar(for: url), atomically: true, encoding: .utf8)
    }

    // MARK: - Retention

    /// Delete anything past the retention window. Called before every stash
    /// rather than on a timer: the only thing that grows this directory is a
    /// dictation, so that is the only moment it can need pruning.
    // ponytail: one directory listing per dictation, off the keypress path and
    // over a handful of files. Move to a launch-time sweep if corpus mode ever
    // leaves thousands here.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        var removed = 0
        for url in recordings() where modified(url).map({ $0 < cutoff }) ?? false {
            remove(url)
            removed += 1
        }
        return removed
    }

    public func summary() -> Summary {
        let urls = recordings()
        let bytes = urls.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return Summary(count: urls.count, bytes: bytes)
    }

    /// Newest first. WAVs only — sidecars travel with their recording.
    public func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Empty the folder, sidecars and all — the Hub's user-initiated delete.
    public func clear() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecar(for: url))
    }

    /// The name is millisecond-resolution, which two dictations will not
    /// realistically share — but "will not realistically" is how you lose one.
    private func uniqueURL(base: String) -> URL {
        var url = directory.appendingPathComponent(base + ".wav")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).wav")
            n += 1
        }
        return url
    }

    private func sidecar(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("hyp.txt")
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

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
    static func writeWAV(_ samples: [Float], to url: URL) throws {
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
                  let channel = buf.floatChannelData?[0] else { return }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + offset, count: n) }
            try file.write(from: buf)
            offset += n
        }
    }
}
