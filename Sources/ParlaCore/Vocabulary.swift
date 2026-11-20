import Foundation

/// The loaded model's prompt budget. Use it transiently; never store it.
public struct PromptBudget {
    public let capacity: Int              // whisper_n_text_ctx / 2 - 1
    public let count: (String) -> Int     // loaded model's tokenizer
    public init(capacity: Int, count: @escaping (String) -> Int) {
        self.capacity = capacity
        self.count = count
    }
}

/// Saved order is priority. UTF-8 bytes are the resource guard; with a
/// `PromptBudget`, the model's tokens decide which terms are retained.
public enum VocabularyHints {
    public static let maxHintBytes = 256
    public static let asrBytes = 2_048
    public static let cleanupBytes = 8_192

    public static func normalized(_ word: String) -> String {
        word.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func select(_ words: [String], byteLimit: Int) -> [String] {
        var seen = Set<String>()
        var used = 0
        return words.compactMap { word in
            let word = normalized(word)
            guard !word.isEmpty, word.utf8.count <= maxHintBytes,
                  seen.insert(word.lowercased()).inserted else { return nil }
            let cost = word.utf8.count + (used == 0 ? 0 : 2)
            guard used + cost <= byteLimit else { return nil }
            used += cost
            return word
        }
    }

    /// Byte admission, then token admission in priority order. A term that
    /// does not fit is skipped; later cheaper terms may still be admitted.
    // ponytail: recomputed per pass; memoize on (words, capacity) only if profiling shows it.
    public static func select(_ words: [String], budget: PromptBudget?) -> [String] {
        let candidates = select(words, byteLimit: asrBytes)
        guard let budget else { return candidates }
        var used = 0
        var selected: [String] = []
        for term in candidates {
            let cost = budget.count(selected.isEmpty ? term : ", " + term)
            if used + cost <= budget.capacity { selected.append(term); used += cost }
        }
        // Tokenization is not additive across the ", " boundaries.
        while !selected.isEmpty, budget.count(selected.joined(separator: ", ")) > budget.capacity { selected.removeLast() }
        return selected
    }

    public static func asrPrompt(_ words: [String], budget: PromptBudget? = nil) -> String? {
        let selected = select(words, budget: budget)
        return selected.isEmpty ? nil : selected.joined(separator: ", ")
    }
}

/// Exact, case-sensitive literals. Array order breaks equal-length ties.
public struct LiteralReplacement: Codable, Equatable, Sendable {
    public var source: String
    public var replacement: String
    public init(source: String = "", replacement: String = "") {
        self.source = source
        self.replacement = replacement
    }

    public static func apply(_ rules: [Self], to text: String) -> String {
        // No bound for the existing ordinary policy.
        try! write(rules, to: text, maximumBytes: nil)
    }

    public static func boundedApply(_ rules: [Self], to text: String, maximumBytes: Int) throws -> String {
        try write(rules, to: text, maximumBytes: maximumBytes)
    }

    private static func write(_ rules: [Self], to text: String, maximumBytes: Int?) throws -> String {
        let ordered = rules.enumerated().filter { !$0.element.source.isEmpty }.sorted {
            let a = $0.element.source.count, b = $1.element.source.count
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
        // Marks and connector punctuation are word constituents too (e.g. Hindi
        // vowel signs, decomposed accents, and identifier underscores).
        func isWord(_ character: Character) -> Bool {
            character.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                    || $0.properties.generalCategory == .connectorPunctuation
            }
        }
        var result = "", bytes = 0
        func append(_ value: String) throws {
            if let maximumBytes {
                guard value.utf8.count <= maximumBytes - bytes else { throw CleanupError(description: "Too long to preview") }
            }
            bytes += value.utf8.count
            result += value
        }
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let match = ordered.first { rule in
                guard let end = text.index(cursor, offsetBy: rule.source.count, limitedBy: text.endIndex),
                      text[cursor..<end] == rule.source else { return false }
                let leftOK = !isWord(rule.source.first!) || cursor == text.startIndex
                    || !isWord(text[text.index(before: cursor)])
                let rightOK = !isWord(rule.source.last!) || end == text.endIndex || !isWord(text[end])
                return leftOK && rightOK
            }
            if let match {
                try append(match.replacement)
                cursor = text.index(cursor, offsetBy: match.source.count)
            } else {
                try append(String(text[cursor]))
                cursor = text.index(after: cursor)
            }
        }
        return result
    }
}

public enum LocalVocabulary {
    /// Whole-utterance snippets are locked: replacements never touch expansions.
    public static func finalize(_ text: String, settings: Settings) -> String {
        Pipeline.snippetExpansion(transcript: text, snippets: settings.snippets)
            ?? LiteralReplacement.apply(settings.replacements, to: text)
    }
}
