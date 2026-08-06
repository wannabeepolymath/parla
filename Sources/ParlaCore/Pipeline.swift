import Foundation

public struct Pipeline {
    /// nil ⇒ the whisper pass failed or was aborted (not "no speech" — that is "").
    public var transcribe: ([Float], String?) -> String?
    public var cleanup: (String, CleanupContext) async throws -> String
    public var settings: () -> Settings
    public var frontAppName: () -> String?

    public init(transcribe: @escaping ([Float], String?) -> String?,
                cleanup: @escaping (String, CleanupContext) async throws -> String,
                settings: @escaping () -> Settings,
                frontAppName: @escaping () -> String?) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.settings = settings
        self.frontAppName = frontAppName
    }

    /// Whisper pass only: trimmed transcript, nil when empty OR when the pass
    /// failed. Split from clean() so the caller can finalize raw text instantly
    /// and polish behind it.
    public func transcript(samples: [Float]) -> String? {
        let s = settings()
        let prompt = s.dictionary.isEmpty ? nil : s.dictionary.joined(separator: ", ")
        guard let t = transcribe(samples, prompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// LLM cleanup, sanitized. Never throws — cleanup must never kill a
    /// dictation, so failures hand back the raw transcript and a safe message
    /// so the caller can tell the user why nothing changed.
    public func clean(transcript: String) async -> (text: String, failure: String?) {
        let s = settings()
        let ctx = CleanupContext(dictionary: s.dictionary, snippets: s.snippets,
                                 appName: frontAppName())
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
            // Floor. The ceiling above only catches runaway EXPANSION; a model
            // that answers the transcript, summarises it, or refuses in one line
            // comes back far SHORTER, and that was typed straight over the
            // user's words with nothing to stop it. Cleanup legitimately shrinks
            // filler-heavy speech ("um, so, like, the thing is…"), so the floor
            // is deliberately generous and only applies once the transcript is
            // long enough for a ratio to mean anything.
            // ponytail: a length ratio, not a relatedness check — proving the
            // output still says what the user said needs a second model call.
            // Upgrade only if drift is observed above this floor.
            if transcript.count >= 80, cleaned.count < transcript.count / 5 {
                NSLog("Parla cleanup output truncated (\(cleaned.count) chars for \(transcript.count)-char transcript), keeping raw transcript")
                return (transcript, "cleanup returned truncated text")
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
