import CryptoKit
import Foundation

public struct ModelFileError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

/// The whisper models Parla knows how to fetch, each pinned to the exact bytes
/// HuggingFace serves today. Every size and hash below was read from
/// `huggingface.co/api/models/ggerganov/whisper.cpp/tree/main` — the `lfs.oid`
/// of an LFS entry *is* its SHA-256 — not copied from a third-party list. A
/// model whose hash could not be verified from that source is simply absent:
/// a wrong hash is worse than a missing catalog entry, because it bricks the
/// download path for a file that was actually fine.
public enum ModelCatalog {
    public struct Model: Identifiable, Equatable, Sendable {
        /// whisper.cpp's own model name — also the filename and URL stem, so
        /// there is one string to get right instead of three.
        public let id: String
        public let displayName: String
        /// Content-length of the download, which is also the size on disk: a
        /// ggml `.bin` is stored exactly as served, no container, no unpacking.
        public let bytes: Int64
        public let sha256: String

        public var filename: String { "ggml-\(id).bin" }
        /// Same URL shape scripts/download-model.sh already uses.
        public var url: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        }
        public var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Three rungs, not Handy's 67: a floor, a middle, and the best model that
    /// still fits in a reasonable download. Quantization is nearly free quality
    /// — large-v3-turbo-q5_0 is 574 MB against 1,620 MB for the same weights
    /// unquantized (docs/research/04-asr-engines.md §1).
    public static let all: [Model] = [
        Model(id: "base.en",
              displayName: "Base (English)",
              bytes: 147_964_211,
              sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        Model(id: "small.en-q5_1",
              displayName: "Small (English, quantized)",
              bytes: 190_098_681,
              sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"),
        Model(id: "large-v3-turbo-q5_0",
              displayName: "Large v3 Turbo (quantized)",
              bytes: 574_041_195,
              sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]

    /// base.en stays the default: every existing install already has this file
    /// on disk, and switching the default would greet them with ⚠️ and a
    /// 574 MB download they didn't ask for. The better models are one click
    /// away in the Hub — and Tier 1 #5's WER harness should decide the default,
    /// not this change.
    public static let `default` = all[0]

    public static func model(id: String) -> Model? { all.first { $0.id == id } }

    /// Which catalog entry a path refers to, by filename. Anything else is the
    /// user's own model via `settings.whisperModelPath` and is never verified —
    /// nothing is pinned for it.
    public static func model(atPath path: String) -> Model? {
        let name = (path as NSString).lastPathComponent
        return all.first { $0.filename == name }
    }

    public static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/models")
    }

    public static func path(for model: Model) -> String {
        directory.appendingPathComponent(model.filename).path
    }

    public static func isInstalled(_ model: Model) -> Bool {
        FileManager.default.fileExists(atPath: path(for: model))
    }

    // MARK: - Verification

    /// An HTML error page saved as a model: corporate proxies and captive
    /// portals return one with HTTP 200 and no markup content-type, so the only
    /// reliable tell is the payload itself (vibe #353). Checked before the hash
    /// because it names the real failure — "we got a login page", not "hash
    /// mismatch" — and before whisper, which reports it as an unloadable model.
    public static func looksLikeMarkup(_ head: Data) -> Bool {
        let prefix = String(decoding: head.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["<!doctype", "<html", "<head", "<?xml"].contains { prefix.hasPrefix($0) }
    }

    /// Streamed in 4 MiB chunks — a 574 MB `Data(contentsOf:)` would resident
    /// the whole file just to hash it.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Length, then markup, then the pinned hash — cheapest and most specific
    /// first. Both numbers go into the length error (vibe PR #1245): "expected
    /// N got M" is diagnosable from a log line, "invalid model" is not.
    public static func verify(fileAt url: URL, is model: Model) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int64 else {
            throw ModelFileError(description: "\(model.id): downloaded file is missing")
        }
        guard size == model.bytes else {
            throw ModelFileError(description:
                "\(model.id): expected \(model.bytes) bytes, got \(size)")
        }
        let head: Data = try {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return handle.readData(ofLength: 512)
        }()
        guard !looksLikeMarkup(head) else {
            throw ModelFileError(description:
                "\(model.id): server returned a web page, not a model")
        }
        let digest = try sha256(ofFileAt: url)
        guard digest == model.sha256 else {
            throw ModelFileError(description:
                "\(model.id): sha256 \(digest) != pinned \(model.sha256)")
        }
    }

    // MARK: - Install

    /// vibe PR #1245's shape. `staged` is URLSession's own temp file — that IS
    /// the `.part` staging, and copying it to one of our own would cost another
    /// 574 MB of I/O for nothing. Verified *before* anything on disk is touched;
    /// the model already in place is renamed aside rather than deleted, and put
    /// back if the move fails. Parla used to `removeItem` first, so a failed
    /// move left the user with no model at all.
    public static func install(staged: URL, as model: Model, at dest: URL,
                               cache: VerifiedCache = VerifiedCache()) throws {
        try verify(fileAt: staged, is: model)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = dest.appendingPathExtension("backup")
        try? fm.removeItem(at: backup) // a backup left behind by an earlier crash
        let hadExisting = fm.fileExists(atPath: dest.path)
        if hadExisting { try fm.moveItem(at: dest, to: backup) }
        do {
            try fm.moveItem(at: staged, to: dest)
        } catch {
            if hadExisting { try? fm.moveItem(at: backup, to: dest) }
            throw error
        }
        try? fm.removeItem(at: backup)
        // We just hashed these exact bytes — don't hash them again at launch.
        cache.record(dest)
    }

    /// Load-time gate: nil when the file is safe to hand to whisper.
    ///
    /// Only files Parla itself put in its models directory are checked. A
    /// `whisperModelPath` pointing anywhere else is the user's own model and
    /// their escape hatch if HuggingFace ever re-uploads one of ours (pindrop
    /// #785: a 64-byte re-upload bricked every install that compared sizes).
    public static func verifyInstalled(path: String, cache: VerifiedCache = VerifiedCache()) -> ModelFileError? {
        let url = URL(fileURLWithPath: path)
        // A file that isn't there yet is not a damaged file — the caller's own
        // load failure already says "no model".
        guard FileManager.default.fileExists(atPath: path),
              url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              let model = model(atPath: path) else { return nil }
        guard !cache.isVerified(url) else { return nil }
        do {
            try verify(fileAt: url, is: model)
            cache.record(url)
            return nil
        } catch {
            return error as? ModelFileError
                ?? ModelFileError(description: "\(model.id): \(error.localizedDescription)")
        }
    }
}

/// Hash verdicts, persisted next to the models and keyed on `(size, mtime)`.
/// ghost-pepper #163: streaming SHA-256 over a multi-GB model on every launch
/// (and 2-3× per render of a models panel) is a visible hang. Identity, not
/// path, is the key — macparakeet's disk-identity rule: a re-download at the
/// same path changes mtime, so the stale verdict is dropped instead of
/// blessing different bytes.
public struct VerifiedCache {
    let url: URL

    public init(url: URL = ModelCatalog.directory.appendingPathComponent("verified.json")) {
        self.url = url
    }

    /// `"<size>-<mtime>"`, nil when the file is gone.
    static func identity(of file: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(size)-\(mtime.timeIntervalSince1970)"
    }

    private func entries() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func isVerified(_ file: URL) -> Bool {
        guard let identity = Self.identity(of: file) else { return false }
        return entries()[file.path] == identity
    }

    public func record(_ file: URL) {
        guard let identity = Self.identity(of: file) else { return }
        var map = entries()
        map[file.path] = identity
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
