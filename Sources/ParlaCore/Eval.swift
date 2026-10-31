import Foundation
import AVFoundation

public enum Eval {
    public static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Case/punctuation-sensitive text with horizontal whitespace folded per
    /// line. Line endings and outer whitespace vary freely; internal newlines,
    /// including blank lines, remain significant. Existing normalize/WER stay
    /// deliberately insensitive to all whitespace.
    public static func normalizeStructure(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map(normalize).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Newline positions in whitespace-delimited word offsets. Repeated offsets
    /// encode blank lines. This measures layout independently of spelling and
    /// punctuation, not semantic equivalence (same-length substitutions remain
    /// the job of content checks). Horizontal spacing/indentation is ignored.
    public static func newlineLayout(_ text: String) -> [Int] {
        let lines = normalizeStructure(text).components(separatedBy: "\n")
        var words = 0
        return lines.dropLast().map { line in
            words += line.split(whereSeparator: \.isWhitespace).count
            return words
        }
    }

    // MARK: - Explicit offline cleanup-output policy

    public struct QualityPolicy {
        public let version: Int
        public let cases: [QualityRule]
    }

    private struct QualityDocument: Decodable {
        let version: Int
        let cases: [QualityRule]
    }

    public struct QualityRule: Decodable {
        public let name: String
        public let protected: [String]
        public let alternatives: [String]
    }

    /// Also decodes real parla-eval results; references/scores supplied by a run
    /// are intentionally ignored. Only the reviewed golden is authoritative.
    private struct QualityOutput: Decodable {
        let name: String
        let leg: String
        let hypothesis: String
    }

    public enum QualityError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    /// A small, strict schema: reject unknown fields as well as missing fields,
    /// so a misspelled or unsupported constraint cannot disappear in decoding.
    public static func qualityPolicy(from data: Data) throws -> QualityPolicy {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "cases"],
              let rules = object["cases"] as? [[String: Any]],
              rules.allSatisfy({ Set($0.keys) == ["name", "protected", "alternatives"] }) else {
            throw QualityError.invalid("policy requires version/cases and name/protected/alternatives per case")
        }
        let document = try JSONDecoder().decode(QualityDocument.self, from: data)
        let policy = QualityPolicy(version: document.version, cases: document.cases)
        guard policy.version == 1, !policy.cases.isEmpty else {
            throw QualityError.invalid("policy must have version 1 and non-empty cases")
        }
        var names = Set<String>()
        for rule in policy.cases {
            guard !rule.name.isEmpty,
                  rule.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  names.insert(rule.name).inserted,
                  Set(rule.protected).count == rule.protected.count,
                  rule.protected.allSatisfy({ !$0.isEmpty && normalizeStructure($0) == $0 }),
                  rule.alternatives.allSatisfy({ !normalizeStructure($0).isEmpty }) else {
                throw QualityError.invalid("invalid or duplicate rule: \(rule.name)")
            }
        }
        return policy
    }

    /// Empty return means every required cleanup output meets the reviewed text
    /// policy. Missing/duplicate/unknown cases and unusable rules throw; quality
    /// mismatches return diagnostics. Neither path invokes cleanup or a model.
    public static func checkQuality(policy: QualityPolicy, references: [String: String],
                                    results: Data) throws -> [String] {
        let names = Set(policy.cases.map(\.name))
        guard Set(references.keys) == names else {
            throw QualityError.invalid("golden cases must exactly match policy cases")
        }
        let outputs = try JSONDecoder().decode([QualityOutput].self, from: results)
        var cleanup: [String: String] = [:]
        var keys = Set<String>()
        for output in outputs {
            guard names.contains(output.name), ["asr", "cleanup"].contains(output.leg),
                  keys.insert("\(output.leg)/\(output.name)").inserted else {
                throw QualityError.invalid("unknown or duplicate result: \(output.leg)/\(output.name)")
            }
            if output.leg == "cleanup" { cleanup[output.name] = output.hypothesis }
        }
        guard Set(cleanup.keys) == names else {
            let missing = names.subtracting(cleanup.keys).sorted().joined(separator: ", ")
            throw QualityError.invalid("missing cleanup results: \(missing)")
        }
        func occurrences(_ literal: String, in text: String) -> Int {
            text.components(separatedBy: literal).count - 1
        }
        var failures: [String] = []
        for rule in policy.cases {
            let golden = normalizeStructure(references[rule.name]!)
            let accepted = ([golden] + rule.alternatives).map(normalizeStructure)
            guard !golden.isEmpty, Set(accepted).count == accepted.count else {
                throw QualityError.invalid("empty golden or duplicate accepted text: \(rule.name)")
            }
            for literal in rule.protected {
                let count = occurrences(literal, in: golden)
                guard count > 0, accepted.allSatisfy({ occurrences(literal, in: $0) == count }) else {
                    throw QualityError.invalid("protected literal absent/inconsistent in accepted text: \(rule.name): \(literal)")
                }
            }
            let actual = normalizeStructure(cleanup[rule.name]!)
            if !accepted.contains(actual) {
                failures.append("\(rule.name): output differs from accepted structure/content")
            }
            for literal in rule.protected where occurrences(literal, in: actual) != occurrences(literal, in: golden) {
                failures.append("\(rule.name): protected literal count changed: \(literal)")
            }
        }
        return failures
    }

    /// Word tokens for WER. ONE function for reference and hypothesis — a WER
    /// harness that normalizes only one side is the most common way these
    /// numbers lie, so the scorer below never lets a caller pass raw text in.
    /// Curly quotes fold FIRST (before case/punctuation) because otherwise a
    /// smart-quoted "don't" and a straight one score as a substitution.
    /// Numbers fold to digits LAST, once the text is tokens: whisper writes a
    /// perfectly heard dictation in numerals ("$420", "the 15th"), and a golden
    /// spells it out, so without this the harness fails correct transcriptions.
    public static func werTokens(_ s: String) -> [String] {
        var t = s
        for (curly, straight) in [("\u{2019}", "'"), ("\u{2018}", "'"),
                                  ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            t = t.replacingOccurrences(of: curly, with: straight)
        }
        // "1,250" is one number: drop the grouping comma before the tokenizer
        // splits it into "1" and "250". Digits on both sides only, so a spoken
        // list ("1, 2 and 3" — space after the comma) stays three numbers.
        t = t.replacingOccurrences(of: "(?<=[0-9]),(?=[0-9])", with: "",
                                   options: .regularExpression)
        // "$420" is "four hundred and twenty dollars". Move the symbol behind
        // the number as its word instead of deleting it, because deleting it
        // would let "420 euros" score as a correct hearing of "$420".
        for (symbol, word) in currencySymbols where t.contains(symbol) {
            t = t.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: symbol) + "([0-9][0-9.]*)",
                with: "$1 \(word)", options: .regularExpression)
        }
        return foldNumbers(t.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .map(canonicalWord))
    }

    /// Normalized form of what the WER scorer actually compared — for reports.
    public static func normalizeForWER(_ s: String) -> String {
        werTokens(s).joined(separator: " ")
    }

    // MARK: - Number folding
    //
    // Everything below exists to make ONE claim true: a dictation transcribed
    // correctly but in numerals scores as correct. It is deliberately built to
    // under-fold. A false PASS here hides a real regression forever, while a
    // false near-miss just costs someone a second of reading, so every rule
    // below refuses to guess: shapes it doesn't recognise are left as words.

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Scales that END a group and multiply it. "hundred" is missing on purpose
    /// — it multiplies *within* a group ("nineteen hundred") and is handled there.
    private static let scaleWords: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinals fold to their CARDINAL word, not straight to a digit, so the one
    /// number parser below handles "twenty first" without a second grammar.
    private static let ordinalWords: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four",
        "fifth": "five", "sixth": "six", "seventh": "seven", "eighth": "eight",
        "ninth": "nine", "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve",
        "thirteenth": "thirteen", "fourteenth": "fourteen", "fifteenth": "fifteen",
        "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen",
        "nineteenth": "nineteen", "twentieth": "twenty", "thirtieth": "thirty",
        "fortieth": "forty", "fiftieth": "fifty", "sixtieth": "sixty",
        "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety",
        "hundredth": "hundred", "thousandth": "thousand",
    ]

    private static let currencySymbols: [String: String] = [
        "$": "dollar", "£": "pound", "€": "euro",
    ]
    /// So "$1" and "one dollar" agree. Spelled out rather than derived from the
    /// table above: three words of duplication beats a clever plural rule.
    private static let currencyPlurals: [String: String] = [
        "dollars": "dollar", "pounds": "pound", "euros": "euro",
    ]

    /// Per-token folds that must happen BEFORE the number parser sees the run.
    private static func canonicalWord(_ w: String) -> String {
        if let cardinal = ordinalWords[w] { return cardinal }
        if let singular = currencyPlurals[w] { return singular }
        // "15th" / "1st": whisper writes date ordinals with a suffix, and the
        // tokenizer keeps digits and letters in one token. The all-digits check
        // is what stops this eating "north" or "second".
        for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) {
            let digits = w.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return w
    }

    /// One value below 100: "seven", "nineteen", "twenty one".
    private static func parseSub(_ t: [String], _ i: inout Int) -> Int? {
        guard i < t.count, let v = numberWords[t[i]] else { return nil }
        i += 1
        // ONLY a ten absorbs a following unit. "twenty one" is 21, but "twenty
        // twenty" stays two numbers — summing it to 40 would invent a match
        // against a hypothesis that genuinely said "forty".
        if v >= 20, i < t.count, let unit = numberWords[t[i]], (1...9).contains(unit) {
            i += 1
            return v + unit
        }
        return v
    }

    /// One group below a thousand, plus the "nineteen hundred" form.
    private static func parseGroup(_ t: [String], _ i: inout Int) -> Int? {
        guard var v = parseSub(t, &i) else { return nil }
        guard i < t.count, t[i] == "hundred" else { return v }
        i += 1
        v *= 100
        // "and" is part of a number only straight after a scale word, so "four
        // hundred and twenty" is 420 while "four and twenty" stays two numbers.
        if i + 1 < t.count, t[i] == "and", numberWords[t[i + 1]] != nil { i += 1 }
        if let rest = parseSub(t, &i) { v += rest }
        return v
    }

    /// A whole number starting at `start`, or nil consuming nothing. Scales must
    /// strictly decrease and the trailing group must fit under the last scale,
    /// so "two thousand five hundred" is 2500 while "two thousand five thousand"
    /// is not a number at all. A group that breaks either rule ENDS the number
    /// just before itself and is left for the next scan — stopping short can
    /// only under-fold, where abandoning the run outright would also throw away
    /// the good prefix ("nine thousand" back to the word "nine").
    private static func parseNumber(_ t: [String], from start: Int) -> (value: Int, next: Int)? {
        var i = start, total = 0, lastScale = Int.max
        var complete: (value: Int, next: Int)?   // last point the number was whole
        while true {
            var j = i
            guard let group = parseGroup(t, &j) else { break }
            if j < t.count, let scale = scaleWords[t[j]] {
                guard scale < lastScale else { break }
                total += group * scale
                lastScale = scale
                i = j + 1
                complete = (total, i)
                if i + 1 < t.count, t[i] == "and", numberWords[t[i + 1]] != nil { i += 1 }
                continue
            }
            guard group < lastScale else { break }
            return (total + group, j)
        }
        return complete
    }

    /// Collapse each run of number words into its digit form.
    // ponytail: times and years are left as separate tokens on purpose. "nine
    // thirty" folds to "9" "30", which is exactly what "9:30" and "9.30"
    // tokenize to, so times already match without a clock grammar; "twenty
    // twenty four" stays "20" "24" rather than guessing 2024. Both are
    // under-folds — they cost a near-miss, never a false pass. Add a year/time
    // grammar only if a case is losing to it, and test the wrong forms first.
    private static func foldNumbers(_ t: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < t.count {
            if let number = parseNumber(t, from: i) {
                out.append(String(number.value))
                i = number.next
            } else {
                out.append(t[i])
                i += 1
            }
        }
        return out
    }

    public struct WERScore {
        public let edits: Int
        public let referenceWords: Int
        public init(edits: Int, referenceWords: Int) {
            self.edits = edits
            self.referenceWords = referenceWords
        }
        /// Edits per reference word. An empty reference is 0 when the hypothesis
        /// is empty too (the silence case) and 1 otherwise, so a hallucination
        /// on silence can never divide by zero into a free pass.
        public var rate: Double {
            referenceWords > 0 ? Double(edits) / Double(referenceWords)
                               : (edits == 0 ? 0 : 1)
        }
    }

    public static func wer(reference: String, hypothesis: String) -> WERScore {
        let r = werTokens(reference)
        return WERScore(edits: editDistance(r, werTokens(hypothesis)),
                        referenceWords: r.count)
    }

    /// Levenshtein over word tokens, two rows. O(n·m) is fine on dictations.
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Nearest-rank percentile over a small sample. p in 0...1.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))
        return sorted[idx]
    }

    public static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var all: [Float] = []
        let format = file.processingFormat
        // Guard EOF before reading: for some formats (e.g. Int16 WAV) read(into:)
        // at EOF throws (nilError) instead of returning 0 frames.
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            all.append(contentsOf: AudioRecorder.convert(buf))
        }
        return all
    }
}

public enum EvalCleanupSelection {
    public static func validate(settings: Settings, modelOverride: String?, command: String?) throws {
        if settings.usesAppleIntelligence, modelOverride != nil, command == nil {
            throw LocalCleanupReason.unsupportedAction.error
        }
    }
    public static func label(settings: Settings, modelOverride: String?, command: String?) -> String {
        if let command { return "cmd:" + URL(fileURLWithPath: command).lastPathComponent + (modelOverride.map { " " + $0 } ?? "") }
        return settings.cleanupModelLabel
    }
}
