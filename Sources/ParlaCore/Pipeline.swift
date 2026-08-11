import Foundation

public struct Pipeline {
    public var transcribe: ([Float], String?) -> String
    public var cleanup: (String, CleanupContext) async throws -> String
    public var settings: () -> Settings
    /// The destination app's bundle ID, not its name: the only thing the prompt
    /// does with the destination is pick a tone hint by `AppCategory`, and that
    /// is keyed on the bundle ID (`CleanupContext.appName` reaches nothing).
    public var frontBundleID: () -> String?

    public init(transcribe: @escaping ([Float], String?) -> String,
                cleanup: @escaping (String, CleanupContext) async throws -> String,
                settings: @escaping () -> Settings,
                frontBundleID: @escaping () -> String?) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.settings = settings
        self.frontBundleID = frontBundleID
    }

    /// Whisper pass only: trimmed transcript, nil when empty. Split from clean()
    /// so the caller can finalize raw text instantly and polish behind it.
    public func transcript(samples: [Float]) -> String? {
        let s = settings()
        let prompt = s.dictionary.isEmpty ? nil : s.dictionary.joined(separator: ", ")
        let t = transcribe(samples, prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Whole-transcript snippet match — TypeWhisper's `literal_locked`. When the
    /// whole transcript IS a trigger the expansion is a pure string substitution,
    /// so doing it here is instant and right every time, where asking the LLM for
    /// it was neither. Whole-transcript only on purpose: expanding a trigger buried
    /// in a longer utterance re-introduces the "did they mean the phrase or the
    /// snippet" ambiguity this removes, so those stay with the prompt block.
    /// Case and punctuation fold because this matches ASR output, via the same
    /// normalizer the eval harness scores with. Longest trigger wins so two
    /// triggers that fold alike resolve identically every run — a Dictionary has
    /// no order to fall back on.
    public static func snippetExpansion(transcript: String,
                                        snippets: [String: String]) -> String? {
        let key = Eval.normalizeForWER(transcript)
        guard !key.isEmpty else { return nil }
        return snippets.filter { Eval.normalizeForWER($0.key) == key }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// LLM cleanup, sanitized. Never throws — cleanup must never kill a
    /// dictation, so failures hand back the raw transcript and a safe message
    /// so the caller can tell the user why nothing changed.
    public func clean(transcript: String) async -> (text: String, failure: String?) {
        let s = settings()
        // Deterministic snippet: no network, no sanitizer, no length ceiling —
        // this text is ours, not a model's.
        if let expansion = Pipeline.snippetExpansion(transcript: transcript,
                                                     snippets: s.snippets) {
            return (expansion, nil)
        }
        let ctx = CleanupContext(dictionary: s.dictionary, snippets: s.snippets,
                                 appName: nil, bundleID: frontBundleID())
        do {
            let cleaned = CleanupSanitizer.sanitize(try await cleanup(transcript, ctx))
            if cleaned.isEmpty {
                NSLog("Parla cleanup sanitized to empty, keeping raw transcript")
                return (transcript, "cleanup returned no text")
            }
            // ponytail: char-count ceiling against LLM repetition loops (same
            // failure class as the whisper loops guarded in Transcriber). Cleanup
            // legitimately grows text a little (punctuation) and triggered
            // snippets a lot, so allow 2x + 200 plus matched expansions; upgrade
            // to repeated-substring detection if a real cleanup ever trips this.
            let rawLower = transcript.lowercased()
            let allowance = 2 * transcript.count + 200
                + s.snippets.reduce(0) { total, snippet in
                    let key = snippet.key.lowercased()
                    guard !key.isEmpty else { return total }
                    var count = 0
                    var start = rawLower.startIndex
                    while let range = rawLower.range(of: key, range: start..<rawLower.endIndex) {
                        count += 1
                        start = range.upperBound
                    }
                    return total + snippet.value.count * count
                }
            if cleaned.count > allowance {
                NSLog("Parla cleanup output degenerate (\(cleaned.count) chars for \(transcript.count)-char transcript), keeping raw transcript")
                return (transcript, "cleanup returned invalid text")
            }
            return (cleaned, nil)
        } catch let error as CleanupError {
            NSLog("%@", "Parla cleanup failed, keeping raw transcript: \(error)")
            return (transcript, error.userMessage)
        } catch let error as URLError {
            NSLog("%@", "Parla cleanup failed, keeping raw transcript: \(error)")
            return (transcript, error.code == .timedOut
                    ? "cleanup timed out" : "cleanup network unavailable")
        } catch {
            NSLog("%@", "Parla cleanup failed, keeping raw transcript: \(error)")
            return (transcript, "cleanup failed")
        }
    }

    public func process(samples: [Float]) async -> String? {
        guard let t = transcript(samples: samples) else { return nil }
        return await clean(transcript: t).text
    }
}
