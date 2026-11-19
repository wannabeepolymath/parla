import Foundation
import Darwin

/// `parla-eval corpus-run`: produces the saved-run file `corpus-check` admits, ASR leg only.
/// Exit 0 written and admitted · 2 refused input or arguments · 3 infrastructure.
/// Quality is never an exit code here; `corpus-check` reports it.
public enum EvalCorpusRun {
    struct Options: Equatable {
        let manifest: String, out: String, runID: String, configRevision: String
        let whisperModel: String?, context: String?
    }
    struct Engine: Encodable, Equatable {
        let leg = "asr"
        let id: String, revision: String, configRevision: String
        let transport = "local"
    }
    struct Row: Encodable {
        let leg = "asr", inputOrigin = "audio"
        let caseID: String, audioSHA256: String, referenceSHA256: String, referenceRevision: String
        let status: String, reason: String?, hypothesis: String?, seconds: Double?
        let inputSHA256: String
        enum CodingKeys: CodingKey {
            case caseID, leg, audioSHA256, referenceSHA256, referenceRevision, status, reason, hypothesis, seconds, inputOrigin, inputSHA256
        }
        // Explicit null: the schema requires every key, and synthesized Codable omits nil.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(caseID, forKey: .caseID); try c.encode(leg, forKey: .leg)
            try c.encode(audioSHA256, forKey: .audioSHA256); try c.encode(referenceSHA256, forKey: .referenceSHA256)
            try c.encode(referenceRevision, forKey: .referenceRevision); try c.encode(status, forKey: .status)
            try c.encode(reason, forKey: .reason); try c.encode(hypothesis, forKey: .hypothesis)
            try c.encode(seconds, forKey: .seconds); try c.encode(inputOrigin, forKey: .inputOrigin)
            try c.encode(inputSHA256, forKey: .inputSHA256)
        }
    }
    struct Run: Encodable {
        let version = 1, route = "asr-only"
        let runID: String, manifestSHA256: String, manifestRevision: String
        let engines: [Engine], rows: [Row]
    }
    enum Failure: Error, Equatable {
        case refused(String), infrastructure(String)
        var code: Int32 { if case .refused = self { return 2 }; return 3 }
        var message: String {
            switch self {
            case .refused(let why): return "corpus-run refused: \(why)"
            case .infrastructure(let why): return "corpus-run failed: \(why)"
            }
        }
    }

    static func options(_ arguments: [String]) throws -> Options {
        guard arguments.first == "corpus-run", arguments.count >= 2,
              !arguments[1].hasPrefix("-"), !arguments[1].isEmpty else { throw Failure.refused("arguments") }
        var values: [String: String] = [:]
        var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--out", "--run-id", "--config-revision", "--whisper-model", "--context"].contains(flag),
                  values[flag] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("-"), !arguments[index + 1].isEmpty else { throw Failure.refused("arguments") }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let out = values["--out"], let runID = values["--run-id"], let config = values["--config-revision"],
              (try? EvalCorpusJSON.string(runID).id()) != nil, (try? EvalCorpusJSON.string(config).id()) != nil,
              out.hasSuffix(".json"),
              (try? EvalCorpusIO.components(absolute(out), absolute: true)) != nil else { throw Failure.refused("arguments") }
        return Options(manifest: arguments[1], out: out, runID: runID, configRevision: config,
                       whisperModel: values["--whisper-model"], context: values["--context"])
    }
    private static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Catalog ids map onto the schema's ID grammar (`base.en` → `base-en`).
    static func engine(modelPath: String, configRevision: String) -> Engine {
        guard let model = RecognitionFactory.ownedModel(path: modelPath) else {
            return Engine(id: "custom", revision: "unknown", configRevision: configRevision)
        }
        let id = String(model.id.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? Character(scalar) : "-"
        })
        return Engine(id: id, revision: String(model.sha256.prefix(16)), configRevision: configRevision)
    }

    /// Typed outcome → schema row status/reason. `nil` means no engine answered.
    static func row(_ result: RecognitionPassResult?) -> (status: String, reason: String?, hypothesis: String?) {
        guard let result else { return ("failed", "engine", nil) }
        if result.canceled { return ("failed", "cancelled", nil) }
        switch result.native {
        case .completed(let payload): return ("success", nil, payload.text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failed(.nativeDecode): return ("failed", "decode", nil)
        case .failed: return ("failed", "engine", nil)
        case .canceled: return ("failed", "cancelled", nil)
        }
    }

    /// Executable entry. Refusals happen before any engine exists; the engine is released before return.
    public static func main(arguments: [String]) async -> (code: Int32, output: String) {
        let recognition = EvalRecognition()
        defer { recognition.release() }
        do {
            let options = try Self.options(arguments)
            guard !exists(options.out) else { throw Failure.refused("output exists") }
            do { _ = try EvalCorpus.evaluate(.init(manifest: options.manifest, results: nil, against: nil)) }
            catch let error as EvalCorpusError { throw Failure.refused(error.rawValue) }
            var settings = Settings()
            settings.whisperModelPath = options.whisperModel
            if let context = options.context {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: context)),
                      let fixture = try? JSONDecoder().decode(Settings.self, from: data) else { throw Failure.refused("context") }
                settings.dictionary = fixture.dictionary
            }
            let request = RecognitionRequest(settings: settings)
            guard FileManager.default.fileExists(atPath: request.modelPath) else { throw Failure.refused("model") }
            do { try await recognition.acquire(needsASR: true, request: { request }) }
            catch { throw Failure.refused("engine") }
            let report = try await produce(options, engine: Self.engine(modelPath: request.modelPath, configRevision: options.configRevision),
                                           recognize: { await recognition.recognize($0) })
            return (0, report)
        } catch let failure as Failure {
            return (failure.code, failure.message)
        } catch {
            return (3, Failure.infrastructure("unexpected").message)
        }
    }

    /// Admits the manifest, recognizes every case in manifest order, writes `out` once, then self-verifies.
    static func produce(_ options: Options, engine: Engine,
                        recognize: ([Float]) async -> RecognitionPassResult?) async throws -> String {
        let manifestURL = URL(fileURLWithPath: absolute(options.manifest))
        let io: EvalCorpusIO, snapshot: EvalCorpusIO.Snapshot, manifest: EvalCorpus.Manifest
        let order: [(id: String, path: String)]
        do {
            io = try EvalCorpusIO(manifest: options.manifest)
            snapshot = try io.manifest(options.manifest)
            let json = try EvalCorpusJSON.parse(snapshot.data)
            // Manifest admission hashes every audio file against its declared digest.
            manifest = try EvalCorpus.Manifest(json, digest: snapshot.digest, io: io, now: Date().timeIntervalSince1970)
            guard case .object(let top) = json else { throw EvalCorpusError.schema }
            order = try top.field("cases").array(limit: 256).map { value -> (id: String, path: String) in
                guard case .object(let c) = value, case .object(let audio) = try c.field("audio") else { throw EvalCorpusError.schema }
                return (try c.field("id").id(), try audio.field("path").string())
            }
        } catch let error as EvalCorpusError { throw Failure.refused(error.rawValue) }

        var rows: [Row] = []
        for (id, path) in order {
            let c = manifest.cases[id]!
            func row(_ status: String, _ reason: String?, _ hypothesis: String?, _ seconds: Double?) -> Row {
                Row(caseID: id, audioSHA256: c.audio, referenceSHA256: c.verbatim.hash, referenceRevision: c.verbatim.revision,
                    status: status, reason: reason, hypothesis: hypothesis, seconds: seconds, inputSHA256: c.audio)
            }
            let t0 = Date()
            // ponytail: AVAudioFile only opens URLs, so decode re-opens the path the digest was taken from;
            // io.revalidate() below and the self-verify rehash catch a file swapped after admission.
            guard let samples = try? Eval.loadSamples(url: manifestURL.deletingLastPathComponent().appendingPathComponent(path)) else {
                rows.append(row("failed", "engine", nil, Date().timeIntervalSince(t0))); continue
            }
            if Pipeline.recognitionSkip(samples: samples) != nil {
                rows.append(row("skipped", "policy", nil, nil)); continue
            }
            let start = Date()
            let outcome = Self.row(await recognize(samples))
            rows.append(row(outcome.status, outcome.reason, outcome.hypothesis, Date().timeIntervalSince(start)))
        }
        do { try io.revalidate() } catch let error as EvalCorpusError { throw Failure.refused(error.rawValue) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Run(runID: options.runID, manifestSHA256: snapshot.digest,
                                          manifestRevision: manifest.revision, engines: [engine], rows: rows))
        try write(data, to: options.out)
        do {
            return try EvalCorpus.evaluate(.init(manifest: options.manifest, results: options.out, against: nil))
        } catch {
            unlink(options.out)
            throw Failure.infrastructure("self-verify " + ((error as? EvalCorpusError)?.rawValue ?? "unexpected"))
        }
    }

    /// The only write: a new 0600 file, never an existing one.
    static func write(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? Failure.refused("output exists") : Failure.infrastructure("write") }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard close(fd) == 0, complete else { unlink(path); throw Failure.infrastructure("write") }
    }
}
