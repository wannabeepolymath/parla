import Foundation
import ParlaCore

// parla-eval: day-one regression harness. For each NAME.wav with a sibling
// NAME.golden.txt in the cases dir, transcribe → cleanup → compare
// Eval.normalize(actual) == Eval.normalize(golden), and report zero-edit rate
// and asr/llm latency percentiles.

// Nearest-rank percentile over a small sample. p in 0...1.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))
    return sorted[idx]
}

func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "eval/cases"
let dirURL = URL(fileURLWithPath: dir, isDirectory: true)

// Collect NAME.wav that have a sibling NAME.golden.txt.
let fm = FileManager.default
let entries = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
let cases = entries
    .filter { $0.pathExtension == "wav" }
    .map { (wav: $0, golden: $0.deletingPathExtension().appendingPathExtension("golden.txt")) }
    .filter { fm.fileExists(atPath: $0.golden.path) }
    .sorted { $0.wav.lastPathComponent < $1.wav.lastPathComponent }

// Nothing to run — model/key aren't needed, so guide the user and succeed.
if cases.isEmpty {
    print("""
    No eval cases found in \(dir).
    Record one: sox -d -r 16000 -c 1 \(dir)/hello.wav   (Ctrl-C to stop)
    then write the expected cleaned text to \(dir)/hello.golden.txt
    See eval/README.md for details.
    """)
    exit(0)
}

// Model must be present — it is the whole ASR half of the eval.
let modelPath = WhisperTranscriber.defaultModelPath()
guard FileManager.default.fileExists(atPath: modelPath) else {
    FileHandle.standardError.write(Data("error: whisper model not found at \(modelPath)\n".utf8))
    exit(2)
}

let settings = SettingsStore().load()

// Provider client via the shared factory; misconfig (no key, missing baseURL/model) → exit 2.
let client: CleanupProviding
do {
    client = try makeCleanupClient(
        settings: settings, env: ProcessInfo.processInfo.environment)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}

let transcriber: WhisperTranscriber
do {
    transcriber = try WhisperTranscriber(modelPath: modelPath)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}

let prompt = settings.dictionary.isEmpty ? nil : settings.dictionary.joined(separator: ", ")

var passes = 0
var asrTimes: [Double] = []
var llmTimes: [Double] = []
var anyFailed = false

for c in cases {
    let name = c.wav.deletingPathExtension().lastPathComponent
    let golden = (try? String(contentsOf: c.golden, encoding: .utf8)) ?? ""

    let samples: [Float]
    do {
        samples = try Eval.loadSamples(url: c.wav)
    } catch {
        print("FAIL \(name)")
        print("  error: could not read WAV: \(error)")
        anyFailed = true
        continue
    }

    let t0 = Date()
    guard let raw = transcriber.transcribe(samples, initialPrompt: prompt) else {
        print("FAIL \(name)")
        print("  error: transcription failed")
        anyFailed = true
        continue
    }
    let asr = Date().timeIntervalSince(t0)

    let ctx = CleanupContext(dictionary: settings.dictionary, snippets: settings.snippets, appName: nil)
    let t1 = Date()
    let actual: String
    do {
        actual = try await client.clean(transcript: raw, context: ctx)
    } catch {
        print("FAIL \(name)")
        print("  error: cleanup failed: \(error)")
        anyFailed = true
        continue
    }
    let llm = Date().timeIntervalSince(t1)

    asrTimes.append(asr)
    llmTimes.append(llm)

    if Eval.normalize(actual) == Eval.normalize(golden) {
        passes += 1
        print("PASS \(name) (asr \(fmt(asr))s, llm \(fmt(llm))s)")
    } else {
        anyFailed = true
        print("FAIL \(name)")
        print("  golden: \(Eval.normalize(golden))")
        print("  actual: \(Eval.normalize(actual))")
    }
}

let total = cases.count
let pct = total == 0 ? 0 : Int((Double(passes) / Double(total) * 100).rounded())
print("zero-edit rate: \(passes)/\(total) (\(pct)%)")
print("latency p50/p95: asr \(fmt(percentile(asrTimes, 0.5)))s/\(fmt(percentile(asrTimes, 0.95)))s  llm \(fmt(percentile(llmTimes, 0.5)))s/\(fmt(percentile(llmTimes, 0.95)))s")

exit(anyFailed ? 1 : 0)
