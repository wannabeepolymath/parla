import Foundation

public enum VocabularyTransferError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// Intentionally separate from Settings: no credentials, provider, or device fields.
public struct VocabularyDocument: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public var words: [String]
    public var snippets: [String: String]
    public var replacements: [LiteralReplacement]
    public static let maxFileBytes = 1_048_576
    public static let maxEntries = 10_000
    public static let maxTextBytes = 65_536

    public init(settings: Settings) {
        format = "parla-vocabulary"
        version = 1
        words = settings.dictionary
        snippets = settings.snippets
        replacements = settings.replacements
    }

    public var isEmpty: Bool { words.isEmpty && snippets.isEmpty && replacements.isEmpty }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxFileBytes else { throw VocabularyTransferError.invalid("This file is too large (over 1 MB).") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxFileBytes else { throw VocabularyTransferError.invalid("This file is too large (over 1 MB).") }
        // Reject settings dumps and accidental extra fields rather than silently
        // accepting a credentials-bearing object as a vocabulary document.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["format", "version", "words", "snippets", "replacements"]) else {
            throw VocabularyTransferError.invalid("This is a settings file. Choose an exported vocabulary file.")
        }
        if let rules = object["replacements"] as? [[String: Any]],
           rules.contains(where: { Set($0.keys) != Set(["source", "replacement"]) }) {
            throw VocabularyTransferError.invalid("This file isn’t a Parla vocabulary file.")
        }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    private func validate() throws {
        guard format == "parla-vocabulary", version == 1 else {
            throw VocabularyTransferError.invalid("This file isn’t a Parla vocabulary file.")
        }
        guard words.count + snippets.count + replacements.count <= Self.maxEntries else {
            throw VocabularyTransferError.invalid("This file has more than 10,000 entries.")
        }
        guard words.allSatisfy({ !VocabularyHints.normalized($0).isEmpty && $0.utf8.count <= VocabularyHints.maxHintBytes }) else {
            throw VocabularyTransferError.invalid("A word in this file is empty or too long.")
        }
        guard snippets.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.key.utf8.count <= VocabularyHints.maxHintBytes && $0.value.utf8.count <= Self.maxTextBytes }),
              replacements.allSatisfy({ !$0.source.isEmpty && $0.source.utf8.count <= VocabularyHints.maxHintBytes
                  && $0.replacement.utf8.count <= Self.maxTextBytes }) else {
            throw VocabularyTransferError.invalid("A snippet in this file is too long.")
        }
    }

    public func applying(to settings: Settings) -> Settings {
        var next = settings
        next.dictionary = words
        next.snippets = snippets
        next.replacements = replacements
        return next
    }
}

public enum VocabularyImportMode { case merge, replace }

public struct VocabularyImportPreview {
    public let incoming: VocabularyDocument
    public let original: VocabularyDocument
    public let duplicateWords: Int
    public var conflicts: Int { conflictKeys.count }
    public let conflictKeys: [String]

    public init(data: Data, settings: Settings) throws {
        var document = try VocabularyDocument.decode(data)
        var seen = Set<String>()
        let count = document.words.count
        document.words = document.words.map(VocabularyHints.normalized).filter { seen.insert($0.lowercased()).inserted }
        duplicateWords = count - document.words.count
        let original = VocabularyDocument(settings: settings)
        self.original = original
        // One source per rule is unambiguous in the transfer UI. Duplicate source
        // rules in manually edited settings still have deterministic first-wins semantics.
        guard Set(document.replacements.map(\.source)).count == document.replacements.count else {
            throw VocabularyTransferError.invalid("This file has the same replacement twice.")
        }
        let words = Set(original.words.map { VocabularyHints.normalized($0).lowercased() })
        let rules = Dictionary(original.replacements.map { ($0.source, $0.replacement) }, uniquingKeysWith: { a, _ in a })
        conflictKeys = document.words.filter { words.contains($0.lowercased()) }.map { "Word: " + $0 }
            + document.snippets.keys.sorted().filter { original.snippets[$0] != nil }.map { "Snippet: " + $0 }
            + document.replacements.filter { rules[$0.source] != nil }.map { "Replacement: " + $0.source }
        incoming = document
    }

    public func result(mode: VocabularyImportMode) -> VocabularyDocument {
        guard mode == .merge else { return incoming }
        var result = original
        var seen = Set(result.words.map { VocabularyHints.normalized($0).lowercased() })
        result.words += incoming.words.filter { seen.insert($0.lowercased()).inserted }
        result.snippets.merge(incoming.snippets, uniquingKeysWith: { old, _ in old })
        var sources = Set(result.replacements.map(\.source))
        result.replacements += incoming.replacements.filter { sources.insert($0.source).inserted }
        return result
    }
}
