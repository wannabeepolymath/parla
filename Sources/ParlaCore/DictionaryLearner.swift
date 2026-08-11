import Foundation

/// Turns a hand-correction the user typed over Parla's own output into a
/// *proposed* dictionary entry.
///
/// Every guard below exists for one reason: a dictionary entry is not a
/// suggestion. It is injected into whisper's `initial_prompt` and into the
/// cleanup prompt of every future dictation, so one wrong entry degrades every
/// dictation from then on. The bias is therefore hard toward false negatives —
/// missing a real correction costs a single dictation, learning a wrong one is
/// permanent until someone notices — and nothing here is ever applied: `propose`
/// only ever produces a proposal, and the Hub asks before it becomes an entry.
///
/// Pure by design. The AX observation that feeds it lives in Parla/Dictation.swift.
public enum DictionaryLearner {

    /// One word the user replaced in text Parla had just typed.
    public struct Proposal: Codable, Equatable, Sendable {
        public let from: String   // what Parla typed
        public let to: String     // what the user typed instead — the candidate entry
        public let at: Date

        public init(from: String, to: String, at: Date = Date()) {
            self.from = from; self.to = to; self.at = at
        }

        /// Dedupe and dismissal identity. Case-insensitive so the same
        /// correction can't slip past a dismissal by arriving capitalized.
        public var key: String { "\(from.lowercased())→\(to.lowercased())" }
    }

    /// A candidate must be a plain word of this length: long enough that the
    /// mishearing means something, short enough that it isn't a phrase.
    static let lengthRange = 3...24

    /// Character-level edit distance over the longer word. openwhispr's ratio:
    /// "Shunade" → "Sinead" is 4/7 = 0.57 and passes, while an unrelated
    /// replacement ("Shunade" → "whatever") doesn't. Above this the user was
    /// rewriting, not fixing a spelling.
    static let maxDistanceRatio = 0.65

    /// A word as it appears (`word`, for the dictionary) plus the canonical form
    /// everything is *compared* on — Eval's WER tokenizer, the one normalizer in
    /// the codebase, so case, punctuation and curly quotes never read as an edit.
    struct Token: Equatable {
        let word: String
        let canon: String
    }

    static func tokens(_ s: String) -> [Token] {
        s.split(whereSeparator: \.isWhitespace).compactMap { chunk -> Token? in
            let canon = Eval.normalizeForWER(String(chunk))
            guard !canon.isEmpty else { return nil } // punctuation-only chunk: invisible to the diff
            return Token(word: chunk.trimmingCharacters(in: CharacterSet.alphanumerics.inverted),
                         canon: canon)
        }
    }

    /// The single word that changed between two versions of a field, or nil for
    /// any other edit — an insertion, a deletion, a multi-word change, a whole
    /// rewrite. Matched inward from both ends: a substitution is the only edit
    /// that leaves the word counts equal with exactly one differing pair, so
    /// everything the user did that wasn't "fix that one word" lands in nil.
    static func singleSubstitution(_ before: String, _ after: String) -> (from: Token, to: Token)? {
        let b = tokens(before), a = tokens(after)
        guard !b.isEmpty, b.count == a.count else { return nil }
        var head = 0
        while head < b.count, b[head].canon == a[head].canon { head += 1 }
        guard head < b.count else { return nil }        // nothing changed
        var tail = b.count - 1
        while tail > head, b[tail].canon == a[tail].canon { tail -= 1 }
        guard tail == head else { return nil }          // more than one word changed
        return (b[head], a[head])
    }

    /// A word Parla could plausibly have misheard: letters, with `'` and `-`
    /// allowed inside. Rejects numbers, emails, paths, code and emoji — none of
    /// which belong in an ASR prompt.
    static func isWordlike(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
    }

    /// The only place a proposal is born.
    ///
    /// - inserted: what Parla typed.
    /// - before: the field's full text immediately after that insertion.
    /// - after: the field's text once the user stopped editing.
    public static func propose(inserted: String, before: String, after: String,
                               dictionary: [String], now: Date = Date()) -> Proposal? {
        guard let (from, to) = singleSubstitution(before, after) else { return nil }
        // The word that changed must be one Parla actually typed. Without this,
        // a user fixing their own older sentence elsewhere in the same field
        // teaches Parla a word it never got wrong.
        guard tokens(inserted).contains(where: { $0.canon == from.canon }) else { return nil }
        let a = from.word, b = to.word
        guard lengthRange.contains(a.count), lengthRange.contains(b.count),
              isWordlike(a), isWordlike(b) else { return nil }
        // Either side already known ⇒ nothing to learn, and re-proposing an
        // entry the user has is noise.
        let known = Set(dictionary.map { $0.lowercased() })
        guard !known.contains(a.lowercased()), !known.contains(b.lowercased()) else { return nil }
        // A correction respells the same word. A distant replacement is the user
        // choosing a different word, which says nothing about what Parla heard.
        let distance = Eval.editDistance(a.lowercased().map { String($0) },
                                         b.lowercased().map { String($0) })
        guard distance > 0,
              Double(distance) <= maxDistanceRatio * Double(max(a.count, b.count)) else { return nil }
        return Proposal(from: a, to: b, at: now)
    }

    /// Proposals awaiting the user's yes/no, at
    /// ~/Library/Application Support/Parla/dictionary-proposals.json.
    ///
    /// On disk rather than in memory because the Hub is where the user answers,
    /// and they may never open it in the session that learned the correction.
    /// Same save style as HistoryStore.
    public final class Store {
        public static let shared = Store()
        public static let cap = 20          // pending; oldest dropped past it
        private static let dismissedCap = 200
        public let url: URL

        private struct File: Codable {
            var pending: [Proposal] = []
            var dismissed: [String] = []    // keys the user said no to
        }
        private var file: File
        /// Touched from the AX settle timer and from the Hub, both on main.
        private let lock = NSLock()

        public init(url: URL? = nil) {
            self.url = url ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Parla/dictionary-proposals.json")
            file = (try? Data(contentsOf: self.url))
                .flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        }

        public var pending: [Proposal] { lock.withLock { file.pending } }

        /// Record a proposal. False ⇒ dropped because it is already pending or
        /// the user dismissed it once before: one "no" is final, since re-asking
        /// about a rejected correction is how a feature earns being turned off.
        @discardableResult
        public func add(_ proposal: Proposal) -> Bool {
            lock.withLock {
                guard !file.dismissed.contains(proposal.key),
                      !file.pending.contains(where: { $0.key == proposal.key }) else { return false }
                file.pending.append(proposal)
                if file.pending.count > Self.cap {
                    file.pending.removeFirst(file.pending.count - Self.cap)
                }
                save()
                return true
            }
        }

        /// Answer a proposal. `dismissed` records it as refused forever; the
        /// accepted case is written to Settings.dictionary by the caller.
        public func resolve(_ proposal: Proposal, dismissed: Bool) {
            lock.withLock {
                file.pending.removeAll { $0.key == proposal.key }
                if dismissed, !file.dismissed.contains(proposal.key) {
                    file.dismissed.append(proposal.key)
                    if file.dismissed.count > Self.dismissedCap {
                        file.dismissed.removeFirst(file.dismissed.count - Self.dismissedCap)
                    }
                }
                save()
            }
        }

        private func save() { // call under lock
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(file).write(to: url, options: .atomic)
        }
    }
}
