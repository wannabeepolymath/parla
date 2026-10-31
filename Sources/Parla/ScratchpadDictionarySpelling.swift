import Foundation

/// Deliberately orthographic, not a tokenizer, fuzzy corrector, or spellchecker.
enum ScratchpadSpellingPolicy {
    static let documentUnits = 65_536
    static let tokenUnits = 128
    static let tokenBytes = 256
    static let rows = 10_000
    static let workSeconds = 0.020
    static let lifetime = 30.0
    static let transientContentBytes = 1_048_576
    // Conservative logical payload accounting: at most four simultaneous raw /
    // bridged document buffers, original + five outputs and normalization scratch.
    // The borrowed store/view and framework/allocator bookkeeping are separate.
    static func snapshotFitsBudget(_ units: Int) -> Bool {
        units >= 0 && units <= documentUnits
            && units <= (transientContentBytes - 16_384) / (4 * MemoryLayout<UInt16>.size)
    }
    static let version = 1

    struct Refusal: Error { let message: String }
    struct Token { let range: NSRange; let units: [UInt16] }
    struct Choices { let outputs: [String]; let more: Bool; let examinedBytes: Int }
    static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }
    static func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    static func validUTF16(_ units: [UInt16]) -> Bool {
        var i = 0
        while i < units.count {
            let unit = units[i]
            if (0xD800...0xDBFF).contains(unit) {
                guard i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) else { return false }
                i += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { return false }
                i += 1
            }
        }
        return true
    }
    static func fits(_ range: NSRange, in length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= length && range.length <= length - range.location
    }

    private enum Cluster { case word, delimiter, poison }
    private static func cluster(_ text: String) -> Cluster {
        let scalars = Array(text.unicodeScalars)
        let orthographic = scalars.contains {
            CharacterSet.letters.contains($0) || $0.properties.generalCategory == .decimalNumber
                || $0.properties.generalCategory == .connectorPunctuation
        }
        if orthographic && scalars.contains(where: {
            $0.properties.isDefaultIgnorableCodePoint && $0.value != 0x200C && $0.value != 0x200D
        }) { return .poison }
        if !orthographic {
            let emoji = scalars.contains { $0.properties.generalCategory == .otherSymbol && $0.properties.isEmoji }
            // A mark attached to punctuation/space is not an attached word mark.
            // Emoji variation selectors/ZWJ remain a standalone emoji delimiter.
            if scalars.contains(where: { scalar in
                switch scalar.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark:
                    return !emoji || !((0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value))
                case .format: return !emoji || scalar.value != 0x200D
                default: return false
                }
            }) { return .poison }
        }
        var base = false, letter = false
        for (i, scalar) in scalars.enumerated() {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                base = true; letter = true
            case .decimalNumber, .connectorPunctuation: base = true
            case .nonspacingMark, .spacingMark, .enclosingMark:
                // Variation selectors are not orthographic marks for this contract.
                if (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value) { return .poison }
            case .format:
                // Tight rule: joiner INSIDE the same letter cluster, immediately
                // after an attached mark and before another letter. Never strip it.
                guard scalar.value == 0x200C || scalar.value == 0x200D,
                      i > 0, i + 1 < scalars.count,
                      CharacterSet.nonBaseCharacters.contains(scalars[i - 1]),
                      CharacterSet.letters.contains(scalars[i + 1]) else { return .poison }
            case .control:
                return text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } ? .delimiter : .poison
            default:
                if base || scalars.contains(where: { CharacterSet.letters.contains($0) }) { return .poison }
                // U+FFFC attachment, U+FFFD replacement and noncharacters aren't separators.
                if scalar.value == 0xFFFC || scalar.value == 0xFFFD || (0xFFF0...0xFFFF).contains(scalar.value) { return .poison }
                return .delimiter
            }
        }
        if scalars.contains(where: { $0.value == 0x200C || $0.value == 0x200D }), !letter { return .poison }
        return base ? .word : .poison
    }

    static func admitted(_ text: String) -> Bool {
        // Callers must first bound UTF-8 examination to 257 bytes.
        guard text.utf16.count <= tokenUnits, (3...64).contains(text.count),
              text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        return text.allSatisfy { cluster(String($0)) == .word }
    }

    static func token(_ units: [UInt16], selection: NSRange) throws -> Token {
        func refuse() -> Refusal { Refusal(message: "Move inside a word or select one whole word (3–64 characters).") }
        guard snapshotFitsBudget(units.count), !units.isEmpty, fits(selection, in: units.count), validUTF16(units) else { throw refuse() }
        // Raw validation precedes bridging; no replacement-character repair is accepted.
        let text = String(decoding: units, as: UTF16.self) as NSString
        func boundary(_ offset: Int) -> Bool {
            offset == text.length || text.rangeOfComposedCharacterSequence(at: offset).location == offset
        }
        let end = selection.location + selection.length
        guard boundary(selection.location), boundary(end), selection.location > 0 || selection.length > 0 else { throw refuse() }
        func kind(_ range: NSRange) -> Cluster { cluster(text.substring(with: range)) }
        let anchor = selection.length == 0 ? selection.location - 1 : selection.location
        guard anchor >= 0, anchor < text.length else { throw refuse() }
        var range = text.rangeOfComposedCharacterSequence(at: anchor)
        guard kind(range) == .word else { throw refuse() }
        let leftLimit = max(0, selection.location - 129)
        let rightLimit = min(text.length, end + 129)
        while range.location > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: range.location - 1)
            guard previous.location >= leftLimit else { throw refuse() }
            if kind(previous) != .word { break }
            range = NSUnionRange(range, previous)
            guard range.length <= tokenUnits else { throw refuse() }
        }
        while NSMaxRange(range) < text.length {
            let next = text.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            guard NSMaxRange(next) <= rightLimit else { throw refuse() }
            if kind(next) != .word { break }
            range = NSUnionRange(range, next)
            guard range.length <= tokenUnits else { throw refuse() }
        }
        guard selection.length == 0 ? (selection.location > range.location && selection.location <= NSMaxRange(range)) : selection == range else { throw refuse() }
        // A poison cluster or connected compound cannot authorize a fragment.
        // Ordinary punctuation (including a final period) can delimit. A run of
        // identifier punctuation connecting lexical clusters is ambiguous.
        let compound = CharacterSet(charactersIn: "'’ʼ-‐‑‒–—.@/\\:+")
        for direction in [-1, 1] {
            var cursor = direction < 0 ? range.location : NSMaxRange(range)
            var connected = false
            var steps = 0
            while direction < 0 ? cursor > 0 : cursor < text.length {
                let neighbor = text.rangeOfComposedCharacterSequence(at: direction < 0 ? cursor - 1 : cursor)
                steps += neighbor.length
                guard steps <= 129 else { throw refuse() }
                let literal = text.substring(with: neighbor)
                let type = kind(neighbor)
                if type == .poison || (connected && type == .word) { throw refuse() }
                guard literal.unicodeScalars.allSatisfy({ compound.contains($0) }) else { break }
                // Hanging apostrophe/dash/slash/@ are also conservatively refused.
                if literal != "." && literal != ":" { throw refuse() }
                connected = true
                cursor = direction < 0 ? neighbor.location : NSMaxRange(neighbor)
            }
        }
        let literal = text.substring(with: range)
        guard Array(literal.utf8.prefix(tokenBytes + 1)).count <= tokenBytes, admitted(literal) else { throw refuse() }
        return Token(range: range, units: Array(units[range.location..<NSMaxRange(range)]))
    }

    static func candidates(original: [UInt16], words: [String], now: () -> Double) throws -> Choices {
        guard words.count <= rows else { throw Refusal(message: "Dictionary spelling limit: more than 10,000 saved rows.") }
        let started = now()
        func checkTime() throws {
            let current = now()
            guard current.isFinite, current >= started, current - started < workSeconds else { throw Refusal(message: "Dictionary spelling work budget exceeded. Try a smaller saved dictionary.") }
        }
        let input = String(decoding: original, as: UTF16.self)
        let match = key(input)
        var outputs: [String] = [], keys: [String] = []
        var noOpKey: String?, more = false, bytes = 0
        for word in words {
            try checkTime()
            let prefix = Array(word.utf8.prefix(tokenBytes + 1))
            bytes += prefix.count
            guard bytes <= rows * (tokenBytes + 1) else { throw Refusal(message: "Dictionary spelling scan limit exceeded.") }
            guard prefix.count <= tokenBytes else { continue }
            guard admitted(word) else { continue }
            let matching = key(word)
            try checkTime()
            guard matching == match else { continue }
            let canonical = word.precomposedStringWithCanonicalMapping
            guard canonical != noOpKey, !keys.contains(canonical) else { continue }
            if word.utf16.elementsEqual(original) { noOpKey = canonical; continue }
            if outputs.count < 5 { outputs.append(word); keys.append(canonical) }
            else { more = true }
        }
        try checkTime()
        return Choices(outputs: outputs, more: more, examinedBytes: bytes)
    }
}
