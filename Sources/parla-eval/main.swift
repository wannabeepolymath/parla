import Foundation
import ParlaCore

// parla-eval: regression harness over eval/cases.
//
//   parla-eval [dir]            full pipeline: wav → whisper → cleanup
//   parla-eval --asr-only       whisper leg only (no API key needed)
//   parla-eval --cleanup-only   cleanup leg only (no whisper model needed)
//   parla-eval verify [dir]     re-score the committed eval/results.json with
//                               today's normalizer and scorer — no model, no
//                               key, no network. This is the CI gate.
//
// A case is NAME.golden.txt (the expected cleaned text) plus at least one input:
//   NAME.wav      — audio; drives the whisper leg
//   NAME.raw.txt  — verbatim transcript: the ASR reference when a wav exists,
//                   otherwise the cleanup input (a text-only case)
// Golden files may lead with "# category: <tag>" / "# app: <name>" /
// "# bundle: <id>" header lines.
//
// Exit codes: 0 clean · 1 quality regression (some case scored WER > 20 %) ·
// 2 misconfiguration (model or key missing) · 3 infrastructure error. A network
// flake must never read as a quality regression, which is why 3 exists.

enum Mode { case full, asrOnly, cleanupOnly, verify }

let argv = Array(CommandLine.arguments.dropFirst())
let mode: Mode = argv.contains("verify") || argv.contains("--verify") ? .verify
    : argv.contains("--asr-only") ? .asrOnly
    : argv.contains("--cleanup-only") ? .cleanupOnly
    : .full
let dir = argv.first { !$0.hasPrefix("-") && $0 != "verify" } ?? "eval/cases"
let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
let evalRoot = dirURL.deletingLastPathComponent()
let resultsURL = evalRoot.appendingPathComponent("results.json")
let contextURL = evalRoot.appendingPathComponent("context.json")

/// A case scoring worse than this is a failure, not a near miss. macparakeet's
/// threshold: corpus WER hides exactly the dictations that feel broken.
let failThreshold = 0.20

func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    quit(code)
}

/// Every exit taken once the whisper engine may exist goes through here.
/// ggml frees its Metal device from a C++ static destructor at `exit()`, and a
/// whisper context still alive at that point leaves the device's residency set
/// non-empty, so ggml aborts (SIGABRT ⇒ 134) *after* the report has printed —
/// burying the status the run actually earned under an exit code no CI runner
/// can interpret. Dropping the last reference here runs
/// `WhisperTranscriber.deinit` → `whisper_free` while the device is still up.
/// A closure over a top-level `var` references the global rather than capturing
/// it, so `transcriber` below is the only strong reference to release.
func quit(_ code: Int32) -> Never {
    transcriber = nil
    exit(code)
}

// MARK: - Case files

struct CaseResult: Codable {
    var name: String
    var category: String
    var leg: String        // "asr" | "cleanup"
    var reference: String
    var hypothesis: String
    var seconds: Double
    var engine: String     // model that produced it, so a stale fixture is visible
    /// The score this fixture had when it was committed. `verify` re-derives it
    /// from `reference`/`hypothesis` and compares: same bytes in, different score
    /// out, means a scorer changed. Optional so a results.json written before
    /// this field still loads — those fixtures simply have no drift baseline.
    var wer: Double?
}

let headerKeys: Set<String> = ["category", "app", "bundle"]

/// Strip leading "# key: value" headers. Only known keys count, so a golden
/// whose first line is genuinely "#define FOO" keeps its text.
func parseCaseFile(_ text: String) -> (headers: [String: String], body: String) {
    var headers: [String: String] = [:]
    var lines = ArraySlice(text.components(separatedBy: "\n"))
    while let line = lines.first, line.hasPrefix("#") {
        let parts = line.dropFirst().split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { break }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        guard headerKeys.contains(key) else { break }
        headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
        lines = lines.dropFirst()
    }
    return (headers, lines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Reporting

/// Scores every result with the CURRENT normalizer and scorer. Full runs and
/// `verify` both land here, so a change to Eval moves both identically.
func report(_ results: [CaseResult]) -> Bool {
    var qualityFailed = false
    for leg in ["asr", "cleanup"] {
        let rs = results.filter { $0.leg == leg }
        guard !rs.isEmpty else { continue }

        var rates: [Double] = []
        var zeroEdit = 0, edits = 0, refWords = 0
        var byCategory: [String: (edits: Int, ref: Int)] = [:]

        for r in rs {
            let w = Eval.wer(reference: r.reference, hypothesis: r.hypothesis)
            rates.append(w.rate)
            edits += w.edits
            refWords += w.referenceWords
            byCategory[r.category, default: (0, 0)].edits += w.edits
            byCategory[r.category, default: (0, 0)].ref += w.referenceWords

            if Eval.normalize(r.reference) == Eval.normalize(r.hypothesis) {
                zeroEdit += 1
            } else {
                if w.rate > failThreshold { qualityFailed = true }
                print("\(w.rate > failThreshold ? "FAIL" : "near") \(leg) \(r.name) (wer \(pct(w.rate)))")
                print("  golden: \(Eval.normalize(r.reference))")
                print("  actual: \(Eval.normalize(r.hypothesis))")
            }
        }

        let n = rs.count
        let failures = rates.filter { $0 > failThreshold }.count
        let corpus = refWords > 0 ? Double(edits) / Double(refWords) : 0
        print("""
        \(leg): n=\(n)  zero-edit \(zeroEdit)/\(n) (\(pct(Double(zeroEdit) / Double(n))))  \
        wer \(pct(corpus))  p50 \(pct(Eval.percentile(rates, 0.5)))  \
        p90 \(pct(Eval.percentile(rates, 0.9)))  \
        fail(>\(Int(failThreshold * 100))%) \(failures)/\(n)
        """)
        let cats = byCategory.sorted { $0.key < $1.key }.map {
            "\($0.key) \(pct($0.value.ref > 0 ? Double($0.value.edits) / Double($0.value.ref) : 0))"
        }
        print("  by category: " + cats.joined(separator: "  "))
        let secs = rs.map(\.seconds)
        print("  latency p50/p95: \(fmt(Eval.percentile(secs, 0.5)))s/\(fmt(Eval.percentile(secs, 0.95)))s")
    }
    return qualityFailed
}

// MARK: - verify: re-score committed fixtures, offline

if mode == .verify {
    guard let data = try? Data(contentsOf: resultsURL),
          let fixtures = try? JSONDecoder().decode([CaseResult].self, from: data),
          !fixtures.isEmpty
    else {
        print("""
        No committed fixtures at \(resultsURL.path).
        Run `swift run parla-eval` once with a model + key and commit the file;
        `verify` then re-scores those hypotheses offline on every change.
        """)
        exit(0)
    }
    print("verify: re-scoring \(fixtures.count) committed hypotheses (no model, no network)")
    _ = report(fixtures)

    // Verify gates on DRIFT, not on the absolute threshold. The committed file is
    // a baseline, and a baseline legitimately contains cases that fail today —
    // base.en mangles "Kubernetes", and the cleanup model rewrites some goldens.
    // Re-judging those every run would peg CI red forever and teach everyone to
    // ignore it, which is worse than having no gate. What this catches is the
    // scorers moving under fixed inputs: a normalizer that starts folding two
    // spellings together, a WER change, a percentile off-by-one. Same bytes in,
    // different score out, is always a bug.
    let drifted = fixtures.compactMap { fixture -> String? in
        guard let committed = fixture.wer else { return nil } // pre-field fixture
        let rescored = Eval.wer(reference: fixture.reference, hypothesis: fixture.hypothesis).rate
        guard abs(rescored - committed) > 1e-9 else { return nil }
        return String(format: "  %@ %@: committed %.4f, re-scored %.4f",
                      fixture.leg, fixture.name, committed, rescored)
    }
    guard drifted.isEmpty else {
        print("SCORER DRIFT — same inputs, different scores than the committed baseline:")
        drifted.forEach { print($0) }
        print("Re-run `swift run parla-eval` and commit results.json if the change was intended.")
        exit(1)
    }
    print("verify: no drift — scorers reproduce the committed baseline exactly")
    exit(0)
}

// MARK: - Discover cases

let fm = FileManager.default
let entries = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
var wavs: [String: URL] = [:], raws: [String: URL] = [:], goldens: [String: URL] = [:]
for url in entries {
    let file = url.lastPathComponent
    if file.hasSuffix(".golden.txt") { goldens[String(file.dropLast(11))] = url }
    else if file.hasSuffix(".raw.txt") { raws[String(file.dropLast(8))] = url }
    else if file.hasSuffix(".wav") { wavs[String(file.dropLast(4))] = url }
}
// A case needs a golden and an input the current mode can consume.
let names = goldens.keys.filter { name in
    switch mode {
    case .asrOnly: return wavs[name] != nil && raws[name] != nil
    case .cleanupOnly: return raws[name] != nil
    default: return wavs[name] != nil || raws[name] != nil
    }
}.sorted()

if names.isEmpty {
    print("""
    No eval cases found in \(dir) for this mode.
    Text case:  write the raw transcript to \(dir)/name.raw.txt and the expected
                cleaned text to \(dir)/name.golden.txt
    Audio case: sox -d -r 16000 -c 1 \(dir)/name.wav   (Ctrl-C to stop)
    See eval/README.md for details.
    """)
    exit(0)
}

let needsASR = mode != .cleanupOnly && names.contains { wavs[$0] != nil }
let needsCleanup = mode != .asrOnly

// MARK: - Engines

var transcriber: WhisperTranscriber?
var modelPath = ""
if needsASR {
    modelPath = WhisperTranscriber.defaultModelPath()
    guard fm.fileExists(atPath: modelPath) else {
        die("whisper model not found at \(modelPath)", 2)
    }
    do { transcriber = try WhisperTranscriber(modelPath: modelPath) }
    catch { die("\(error)", 2) }
}

// Cleanup context is PINNED to a committed fixture. Reading the developer's
// dictionary and snippets would make every run unreproducible; only the
// provider credentials still come from local Settings.
var settings = SettingsStore().load()
if let data = try? Data(contentsOf: contextURL),
   let fixture = try? JSONDecoder().decode(Settings.self, from: data) {
    settings.dictionary = fixture.dictionary
    settings.snippets = fixture.snippets
} else {
    settings.dictionary = []
    settings.snippets = [:]
    print("note: no \(contextURL.lastPathComponent) — running with an empty dictionary and no snippets")
}

var client: CleanupProviding?
if needsCleanup {
    do {
        client = try makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
    } catch { die("\(error)", 2) }
}
let cleanupEngine = settings.cleanup.provider == "anthropic"
    ? settings.cleanupModel : (settings.cleanup.model ?? settings.cleanup.provider)

struct NoEngine: Error {}
/// The `# bundle:` of the case being run — the destination the cleanup prompt's
/// tone hint is keyed on, and the same value the flatten below uses.
var currentBundle: String?
let pipeline = Pipeline(
    transcribe: { samples, prompt in transcriber?.transcribe(samples, initialPrompt: prompt) ?? "" },
    cleanup: { text, ctx in
        guard let client else { throw NoEngine() }
        // Back off and retry on 429 — here, NOT in CleanupClient. The app is
        // interactive and must fail fast so the user sees a state instead of a
        // stalled pill; a corpus run is a batch job against a per-minute quota,
        // where the only alternative is scoring nothing. Without this a free-tier
        // key errors 26 of 18 cases (retries included) and the run exits 3.
        var delay: UInt64 = 2
        for attempt in 1... {
            do { return try await client.clean(transcript: text, context: ctx) }
            catch let e as CleanupError where e.userMessage == "cleanup rate limited" && attempt < 6 {
                FileHandle.standardError.write("  rate limited, retrying in \(delay)s…\n".data(using: .utf8)!)
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay *= 2
            }
        }
        throw NoEngine() // unreachable: the loop either returns or rethrows
    },
    settings: { settings },
    frontBundleID: { currentBundle })

// MARK: - Run

var results: [CaseResult] = []
var infraFailed = false

for name in names {
    let golden = parseCaseFile((try? String(contentsOf: goldens[name]!, encoding: .utf8)) ?? "")
    let category = golden.headers["category"] ?? "uncategorized"
    let rawRef = raws[name].flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { parseCaseFile($0).body }

    var cleanupInput = rawRef

    if mode != .cleanupOnly, let wav = wavs[name] {
        let samples: [Float]
        do { samples = try Eval.loadSamples(url: wav) } catch {
            print("ERROR \(name): could not read WAV: \(error)")
            infraFailed = true
            continue
        }
        let t0 = Date()
        let heard = pipeline.transcript(samples: samples) ?? ""
        let asr = Date().timeIntervalSince(t0)
        if let rawRef {
            results.append(CaseResult(name: name, category: category, leg: "asr",
                                      reference: rawRef, hypothesis: heard,
                                      seconds: asr, engine: (modelPath as NSString).lastPathComponent,
                                      wer: Eval.wer(reference: rawRef, hypothesis: heard).rate))
        } else {
            print("note: \(name) has no .raw.txt — ASR leg unscored")
        }
        cleanupInput = heard
    }

    guard mode != .asrOnly, let input = cleanupInput else { continue }

    // Empty transcript short-circuits in the app too (Pipeline.transcript is
    // nil ⇒ no cleanup call), so don't spend a request proving it.
    var cleaned = ""
    var llm = 0.0
    if !input.isEmpty {
        currentBundle = golden.headers["bundle"]
        let t1 = Date()
        let out = await pipeline.clean(transcript: input)
        llm = Date().timeIntervalSince(t1)
        if let failure = out.failure {
            print("ERROR \(name): cleanup \(failure)")
            infraFailed = true
            continue
        }
        // Same last mile as the app: newline-submitting targets get flattened.
        cleaned = TextRules.flattensNewlines(bundleID: currentBundle)
            ? TextRules.flattenForTerminal(out.text) : out.text
    }
    results.append(CaseResult(name: name, category: category, leg: "cleanup",
                              reference: golden.body, hypothesis: cleaned,
                              seconds: llm, engine: cleanupEngine,
                              wer: Eval.wer(reference: golden.body, hypothesis: cleaned).rate))
}

let qualityFailed = report(results)

// Only a full run writes fixtures: a partial mode would clobber the other leg.
if mode == .full, !results.isEmpty {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(results) {
        try? data.write(to: resultsURL)
        print("wrote \(resultsURL.path) — commit it so `parla-eval verify` can re-score offline")
    }
}

quit(infraFailed ? 3 : (qualityFailed ? 1 : 0))
