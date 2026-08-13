import Foundation
import ParlaCore

// parla-eval: regression harness over eval/cases.
//
//   parla-eval [dir]            full pipeline: wav → whisper → cleanup
//   parla-eval --asr-only       whisper leg only (no API key needed)
//   parla-eval --cleanup-only   cleanup leg only (no whisper model needed)
//   parla-eval --model <id>     use <id> as the cleanup model for THIS run;
//                               settings.json is never written
//   parla-eval --out <path>     read/write fixtures at <path> instead of
//                               eval/results.json, so two runs can sit side by side
//   parla-eval --cleanup-cmd <exe>
//                               run the cleanup leg through an external command
//                               (system prompt as argv[1], --model as argv[2],
//                               user message on stdin, cleaned text on stdout)
//                               instead of an HTTP
//                               provider — for A/B-ing models you have a CLI for
//                               but no API key. Compare two such runs with each
//                               other, never with a real-provider baseline.
//   parla-eval verify [dir]     re-score the committed eval/results.json with
//                               today's normalizer and scorer — no model, no
//                               key, no network. This is the CI gate.
//   parla-eval compare a b      diff two results files: aggregates per leg and
//                               category, then the cases they disagree on most
//   parla-eval --self-check     assert the compare arithmetic offline
//
// A case is NAME.golden.txt (the expected cleaned text) plus at least one input:
//   NAME.wav      — audio; drives the whisper leg
//   NAME.raw.txt  — verbatim transcript: the ASR reference when a wav exists,
//                   otherwise the cleanup input (a text-only case)
// Golden files may lead with "# category: <tag>" / "# app: <name>" /
// "# bundle: <id>" header lines.
//
// Exit codes: 0 clean · 1 quality regression (some case scored WER > 20 %) ·
// 2 misconfiguration (model or key missing, unusable compare arguments) ·
// 3 infrastructure error. A network flake must never read as a quality
// regression, which is why 3 exists. `compare` never returns 1: one model
// scoring worse than another is the answer the mode exists to produce, not a
// failure of the mode.

enum Mode { case full, asrOnly, cleanupOnly, verify, compare }

/// A case scoring worse than this is a failure, not a near miss. macparakeet's
/// threshold: corpus WER hides exactly the dictations that feel broken.
let failThreshold = 0.20

func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
/// Metric changes are printed in percentage POINTS: 1.8 % → 1.2 % is −0.6pp.
/// Calling that "−33 %" would make a two-case wobble read like a landslide.
func pp(_ delta: Double) -> String { String(format: "%+.1fpp", delta * 100) }
func padR(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
func padL(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
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

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())

/// Removes `--flag value` from `args` and returns the value. Value-taking flags
/// are consumed BEFORE the positional scan below, or `--model foo` would leave
/// "foo" looking like the case directory.
func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
        die("\(name) needs a value", 2)
    }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

let modelOverride = takeOption("--model")
let outPath = takeOption("--out")
let cleanupCmd = takeOption("--cleanup-cmd")

let mode: Mode = args.contains("compare") ? .compare
    : args.contains("verify") || args.contains("--verify") ? .verify
    : args.contains("--asr-only") ? .asrOnly
    : args.contains("--cleanup-only") ? .cleanupOnly
    : .full
let positional = args.filter { !$0.hasPrefix("-") && $0 != "verify" && $0 != "compare" }
let dir = positional.first ?? "eval/cases"
let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
let evalRoot = dirURL.deletingLastPathComponent()
let resultsURL = outPath.map { URL(fileURLWithPath: $0) }
    ?? evalRoot.appendingPathComponent("results.json")
let contextURL = evalRoot.appendingPathComponent("context.json")

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

/// One leg's aggregates, scored with TODAY's normalizer and scorer. `report`
/// and `compare` both read from here, so the two can never end up disagreeing
/// about what "zero-edit rate" or "corpus WER" means.
struct Summary {
    var n = 0, zeroEdit = 0, edits = 0, refWords = 0
    var rates: [Double] = [], seconds: [Double] = []
    var byCategory: [String: (edits: Int, ref: Int)] = [:]
    var corpusWER: Double { refWords > 0 ? Double(edits) / Double(refWords) : 0 }
    var zeroEditRate: Double { n > 0 ? Double(zeroEdit) / Double(n) : 0 }
    /// 0 for a category this run never scored — the caller unions both runs'
    /// category sets, so an absent one has no edits to report.
    func categoryWER(_ key: String) -> Double {
        guard let c = byCategory[key], c.ref > 0 else { return 0 }
        return Double(c.edits) / Double(c.ref)
    }
}

func summarize(_ rs: [CaseResult]) -> Summary {
    var s = Summary()
    s.n = rs.count
    for r in rs {
        let w = Eval.wer(reference: r.reference, hypothesis: r.hypothesis)
        s.rates.append(w.rate)
        s.seconds.append(r.seconds)
        s.edits += w.edits
        s.refWords += w.referenceWords
        s.byCategory[r.category, default: (0, 0)].edits += w.edits
        s.byCategory[r.category, default: (0, 0)].ref += w.referenceWords
        if Eval.normalize(r.reference) == Eval.normalize(r.hypothesis) { s.zeroEdit += 1 }
    }
    return s
}

/// Scores every result with the CURRENT normalizer and scorer. Full runs and
/// `verify` both land here, so a change to Eval moves both identically.
func report(_ results: [CaseResult]) -> Bool {
    var qualityFailed = false
    for leg in ["asr", "cleanup"] {
        let rs = results.filter { $0.leg == leg }
        guard !rs.isEmpty else { continue }
        let s = summarize(rs)

        for r in rs where Eval.normalize(r.reference) != Eval.normalize(r.hypothesis) {
            let w = Eval.wer(reference: r.reference, hypothesis: r.hypothesis)
            if w.rate > failThreshold { qualityFailed = true }
            print("\(w.rate > failThreshold ? "FAIL" : "near") \(leg) \(r.name) (wer \(pct(w.rate)))")
            print("  golden: \(Eval.normalize(r.reference))")
            print("  actual: \(Eval.normalize(r.hypothesis))")
        }

        let n = s.n
        let failures = s.rates.filter { $0 > failThreshold }.count
        print("""
        \(leg): n=\(n)  zero-edit \(s.zeroEdit)/\(n) (\(pct(s.zeroEditRate)))  \
        wer \(pct(s.corpusWER))  p50 \(pct(Eval.percentile(s.rates, 0.5)))  \
        p90 \(pct(Eval.percentile(s.rates, 0.9)))  \
        fail(>\(Int(failThreshold * 100))%) \(failures)/\(n)
        """)
        let cats = s.byCategory.keys.sorted().map { "\($0) \(pct(s.categoryWER($0)))" }
        print("  by category: " + cats.joined(separator: "  "))
        print("  latency p50/p95: \(fmt(Eval.percentile(s.seconds, 0.5)))s/\(fmt(Eval.percentile(s.seconds, 0.95)))s")
    }
    return qualityFailed
}

// MARK: - compare: diff two result files

/// Exit 3 (infrastructure), never 1: a compare that cannot read its inputs has
/// measured nothing, which is a different thing from measuring a worse model.
func loadResults(_ path: String) -> [CaseResult] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        die("cannot read \(path)", 3)
    }
    guard let rs = try? JSONDecoder().decode([CaseResult].self, from: data), !rs.isEmpty else {
        die("\(path) is not a non-empty parla-eval results file", 3)
    }
    return rs
}

/// Pairs two runs by leg+name — one case name scored on two legs is two
/// different measurements and must never be diffed against each other. Cases
/// on one side only come back as notes: a corpus grows between runs and that
/// is not an error. Sharing *nothing* is, and the caller exits 2 on it.
func pair(_ a: [CaseResult], _ b: [CaseResult])
    -> (shared: [(CaseResult, CaseResult)], onlyA: [String], onlyB: [String]) {
    func keyed(_ rs: [CaseResult]) -> [String: CaseResult] {
        Dictionary(rs.map { ("\($0.leg)/\($0.name)", $0) }, uniquingKeysWith: { first, _ in first })
    }
    let (ka, kb) = (keyed(a), keyed(b))
    return (ka.keys.filter { kb[$0] != nil }.sorted().map { (ka[$0]!, kb[$0]!) },
            ka.keys.filter { kb[$0] == nil }.sorted(),
            kb.keys.filter { ka[$0] == nil }.sorted())
}

struct Disagreement {
    let a: CaseResult, b: CaseResult
    let werA: Double, werB: Double
    /// The two runs land on opposite sides of the zero-edit line. Worth its own
    /// flag because a punctuation-only difference moves the product promise
    /// without moving WER at all — the WER normalizer folds punctuation away.
    let zeroFlip: Bool
    var magnitude: Double { abs(werB - werA) }
}

/// Cases the two runs scored differently, biggest disagreement first. This list
/// is the "why"; the aggregates above it are only the "whether".
func disagreements(_ pairs: [(CaseResult, CaseResult)]) -> [Disagreement] {
    pairs.compactMap { x, y -> Disagreement? in
        let wx = Eval.wer(reference: x.reference, hypothesis: x.hypothesis).rate
        let wy = Eval.wer(reference: y.reference, hypothesis: y.hypothesis).rate
        let zx = Eval.normalize(x.reference) == Eval.normalize(x.hypothesis)
        let zy = Eval.normalize(y.reference) == Eval.normalize(y.hypothesis)
        guard abs(wx - wy) > 1e-9 || zx != zy else { return nil }
        return Disagreement(a: x, b: y, werA: wx, werB: wy, zeroFlip: zx != zy)
    }
    // Name breaks ties so the same two files always print the same order.
    .sorted {
        if abs($0.magnitude - $1.magnitude) > 1e-9 { return $0.magnitude > $1.magnitude }
        if $0.zeroFlip != $1.zeroFlip { return $0.zeroFlip }
        return $0.a.name < $1.a.name
    }
}

/// 18 pads past the longest label in use ("  self-correction"), so the metric
/// columns stay aligned when a category name is long.
func metricRow(_ label: String, _ x: Double, _ y: Double) {
    print("  \(padR(label, 18)) \(padL(pct(x), 7)) → \(padL(pct(y), 7))   \(padL(pp(y - x), 8))")
}

// The compare arithmetic is the one part of this harness that a real run cannot
// check: exercising it needs two corpus runs, an API key and two round trips per
// case, which is precisely why it would otherwise ship unverified. These
// fixtures cost nothing and fail loudly if the counting, the pairing or the
// disagreement ranking breaks.
if args.contains("--self-check") {
    func c(_ leg: String, _ name: String, _ cat: String, _ ref: String, _ hyp: String) -> CaseResult {
        CaseResult(name: name, category: cat, leg: leg, reference: ref, hypothesis: hyp,
                   seconds: 1, engine: "e", wer: nil)
    }
    // `short` is 2 reference words and `long` is 8 on purpose: corpus WER and a
    // mean of per-case rates are the same number only when every reference has
    // the same length, so equal-length fixtures cannot tell the two apart.
    // `short` also appears on BOTH legs, which is what a name-only pairing would
    // silently collapse. `tidy` differs by punctuation alone.
    let long = "alpha bravo charlie delta echo foxtrot golf hotel"
    let longMiss = "alpha bravo charlie delta echo foxtrot golf zulu"
    let a = [c("cleanup", "short", "s", "alpha bravo", "zulu yankee"),
             c("cleanup", "long", "l", long, longMiss),
             c("cleanup", "tidy", "l", "Ship it.", "Ship it."),
             c("asr", "short", "s", "alpha bravo", "alpha bravo")]
    let b = [c("cleanup", "short", "s", "alpha bravo", "alpha bravo"),
             c("cleanup", "long", "l", long, longMiss),
             c("cleanup", "tidy", "l", "Ship it.", "Ship it"),
             c("asr", "short", "s", "alpha bravo", "alpha bravo")]

    let sa = summarize(a.filter { $0.leg == "cleanup" })
    let sb = summarize(b.filter { $0.leg == "cleanup" })
    precondition(sa.n == 3 && sa.edits == 3 && sa.refWords == 12 && sa.zeroEdit == 1, "summarize counts")
    precondition(abs(sa.corpusWER - 3.0 / 12.0) < 1e-9, "corpus WER is edits/refWords")
    precondition(abs(sa.rates.reduce(0, +) / 3 - sa.corpusWER) > 0.05,
                 "fixture no longer separates corpus WER from a mean of rates")
    precondition(abs(sa.zeroEditRate - 1.0 / 3.0) < 1e-9, "zero-edit rate is zeroEdit/n")
    precondition(abs(sb.corpusWER - 1.0 / 12.0) < 1e-9, "B scores better")
    precondition(sa.categoryWER("s") == 1 && sa.categoryWER("absent") == 0, "per-category WER")

    let (shared, onlyA, onlyB) = pair(a, b + [c("cleanup", "extra", "l", "alpha", "alpha")])
    precondition(shared.count == 4, "pairs by leg+name — 'short' is on both legs and must not collapse")
    precondition(shared.allSatisfy { $0.0.leg == $0.1.leg && $0.0.name == $0.1.name }, "pairs line up")
    precondition(onlyA.isEmpty && onlyB == ["cleanup/extra"], "one-sided cases are notes, not errors")

    let d = disagreements(shared.filter { $0.0.leg == "cleanup" })
    precondition(d.map(\.a.name) == ["short", "tidy"], "worst first; 'long' scored the same and drops out")
    precondition(abs(d[0].werA - 1) < 1e-9 && d[0].werB == 0 && d[0].zeroFlip, "short: B fixed it")
    // `tidy` scores the same WER on both sides and flips zero-edit. Ranking on
    // WER alone drops it, and zero-edit is the product promise.
    precondition(d[1].magnitude < 1e-9 && d[1].zeroFlip, "punctuation-only flip survives")

    print("self-check: compare arithmetic OK")
    exit(0)
}

// MARK: - compare: diff two result files

if mode == .compare {
    guard positional.count == 2 else {
        die("compare needs two results files: parla-eval compare a.json b.json", 2)
    }
    let (pathA, pathB) = (positional[0], positional[1])
    let (shared, onlyA, onlyB) = pair(loadResults(pathA), loadResults(pathB))
    guard !shared.isEmpty else {
        die("no case in common between \(pathA) and \(pathB) — different corpora?", 2)
    }
    print("A = \(pathA)")
    print("B = \(pathB)")
    if !onlyA.isEmpty { print("note: only in A: \(onlyA.joined(separator: " "))") }
    if !onlyB.isEmpty { print("note: only in B: \(onlyB.joined(separator: " "))") }

    for leg in ["asr", "cleanup"] {
        let pairs = shared.filter { $0.0.leg == leg }
        guard !pairs.isEmpty else { continue }
        let sa = summarize(pairs.map { $0.0 }), sb = summarize(pairs.map { $0.1 })
        let engA = Set(pairs.map { $0.0.engine }).sorted().joined(separator: ",")
        let engB = Set(pairs.map { $0.1.engine }).sorted().joined(separator: ",")
        print("\n\(leg): n=\(pairs.count)   A = \(engA)   B = \(engB)")

        print("  \(padR("zero-edit", 18)) \(padL("\(sa.zeroEdit)/\(sa.n)", 7)) → "
            + "\(padL("\(sb.zeroEdit)/\(sb.n)", 7))   \(padL(pp(sb.zeroEditRate - sa.zeroEditRate), 8))")
        metricRow("corpus WER", sa.corpusWER, sb.corpusWER)
        metricRow("p50", Eval.percentile(sa.rates, 0.5), Eval.percentile(sb.rates, 0.5))
        metricRow("p90", Eval.percentile(sa.rates, 0.9), Eval.percentile(sb.rates, 0.9))
        print("  \(padR("latency p50/p95", 18)) "
            + "\(fmt(Eval.percentile(sa.seconds, 0.5)))s/\(fmt(Eval.percentile(sa.seconds, 0.95)))s → "
            + "\(fmt(Eval.percentile(sb.seconds, 0.5)))s/\(fmt(Eval.percentile(sb.seconds, 0.95)))s")

        print("  by category (WER):")
        for cat in Set(sa.byCategory.keys).union(sb.byCategory.keys).sorted() {
            metricRow("  " + cat, sa.categoryWER(cat), sb.categoryWER(cat))
        }

        let diffs = disagreements(pairs)
        guard !diffs.isEmpty else { print("  every case scored identically"); continue }
        print("  disagreements (\(diffs.count)/\(pairs.count) cases), worst first — "
            + "read these, the numbers above only say whether something moved:")
        for d in diffs.prefix(10) {
            print("    \(padL(pp(d.werB - d.werA), 8))  \(d.a.name)  A \(pct(d.werA)) → B \(pct(d.werB))"
                + (d.zeroFlip ? "  [zero-edit flip]" : ""))
            print("      golden: \(Eval.normalize(d.a.reference))")
            print("      A:      \(Eval.normalize(d.a.hypothesis))")
            print("      B:      \(Eval.normalize(d.b.hypothesis))")
        }
        if diffs.count > 10 { print("    … and \(diffs.count - 10) more") }
    }
    // Exit 0 even when the two runs differ wildly. A quality difference is the
    // RESULT this mode exists to produce, not a failure of it — same discipline
    // that keeps a network flake (3) out of the quality regression code (1).
    exit(0)
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

// --model overrides the model for THIS run only: `settings` is a loaded copy and
// parla-eval never writes it back, so an A/B costs no hand-editing of
// settings.json. The two provider shapes read different fields — anthropic takes
// `cleanupModel`, openai-compatible takes `cleanup.model` (nil there means "ask
// the server for its first model") — and the run only ever uses one of them, so
// setting both overrides whichever provider is configured. Credentials and base
// URL still come from Settings; only the model name moves.
if let modelOverride {
    settings.cleanupModel = modelOverride
    settings.cleanup.model = modelOverride
}

/// Routes the cleanup leg through an external command instead of an HTTP
/// provider. It exists for one situation, and it is a real one: you need to
/// compare two models and there is no API key for them on the machine, but
/// something on PATH can already reach them (`claude -p`, `ollama run`, `llm`).
///
/// What is measured stays Parla's: both prompts come from `PromptBuilder`, the
/// same call `CleanupClient` makes, so only the transport moves. What is NOT
/// comparable is the absolute score against a run through a real provider — a
/// CLI wraps its own harness around the model. Two runs of *this* mode against
/// each other are a fair A/B; one of these against `eval/results.json` is not.
///
/// Contract: argv[1] is the system prompt, argv[2] is `--model`'s value (empty
/// when it was not passed), the user message arrives on stdin, and the cleaned
/// text is expected on stdout. A non-zero exit is a cleanup failure carrying
/// stderr, so a broken command cannot masquerade as an empty polish.
///
/// The model reaches the command as an argument rather than an environment
/// variable of the wrapper's own invention so that the same value is what gets
/// recorded in each fixture's `engine` field. A run nobody can attribute to a
/// model is not much of an A/B.
struct CommandCleanupClient: CleanupProviding {
    let path: String
    let model: String

    func clean(transcript: String, context: CleanupContext) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [PromptBuilder.system(context: context), model]
        let stdIn = Pipe(), stdOut = Pipe(), stdErr = Pipe()
        p.standardInput = stdIn; p.standardOutput = stdOut; p.standardError = stdErr
        try p.run()
        // Drain stderr on its own thread. Reading the two pipes in sequence
        // deadlocks the moment the child fills the one we are not reading, and
        // a hung eval is indistinguishable from a slow model.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = stdErr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        stdIn.fileHandleForWriting.write(Data(PromptBuilder.user(transcript: transcript,
                                                                 context: context).utf8))
        stdIn.fileHandleForWriting.closeFile()
        let outData = stdOut.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw CleanupError(description: "cleanup command exited \(p.terminationStatus): "
                + msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

var client: CleanupProviding?
if needsCleanup {
    if let cleanupCmd {
        guard FileManager.default.isExecutableFile(atPath: cleanupCmd) else {
            die("--cleanup-cmd \(cleanupCmd) is not an executable file", 2)
        }
        client = CommandCleanupClient(path: cleanupCmd, model: modelOverride ?? "")
    } else {
        do {
            client = try makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
        } catch { die("\(error)", 2) }
    }
}
// `engine` is what makes a stale fixture visible, so it has to name what
// actually produced the text. With --cleanup-cmd the configured provider is not
// involved at all, and labelling those fixtures with `cleanup.model` claims a
// run came from a provider that was never called.
let cleanupEngine: String = {
    guard let cleanupCmd else {
        return settings.cleanup.provider == "anthropic"
            ? settings.cleanupModel : (settings.cleanup.model ?? settings.cleanup.provider)
    }
    let exe = URL(fileURLWithPath: cleanupCmd).lastPathComponent
    // The command picks its own model; --model is the only way it can be named
    // here, which is why it is passed through to the command as argv[2].
    return "cmd:\(exe)" + (modelOverride.map { " \($0)" } ?? "")
}()
if modelOverride != nil {
    print("cleanup model for this run: \(cleanupEngine) (--model; settings.json untouched)")
}

struct NoEngine: Error {}
/// The `# bundle:` of the case being run — the destination the cleanup prompt's
/// tone hint is keyed on, and the same value the flatten below uses.
var currentBundle: String?
let pipeline = Pipeline(
    // flatMap, not ?? "": a failed pass must score as a failure, not as silence.
    transcribe: { samples, prompt in transcriber.flatMap { $0.transcribe(samples, initialPrompt: prompt) } },
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

// A partial mode must not write the DEFAULT path: it would clobber the other
// leg's fixtures in the committed baseline. An explicit --out names a fresh
// file with no other leg in it, which is what lets `--cleanup-only --out` A/B a
// cleanup model without the whisper model installed.
if !results.isEmpty, mode == .full || outPath != nil {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(results) {
        try? data.write(to: resultsURL)
        // An --out file is one side of an A/B, not the baseline; telling you to
        // commit it would put a non-default model's scores under the CI gate.
        print("wrote \(resultsURL.path)" + (outPath == nil
            ? " — commit it so `parla-eval verify` can re-score offline"
            : " — diff it with `parla-eval compare <a> <b>`"))
    }
}

quit(infraFailed ? 3 : (qualityFailed ? 1 : 0))
