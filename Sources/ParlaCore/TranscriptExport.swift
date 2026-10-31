import Foundation

/// Export data is deliberately smaller than HistoryEntry: no configuration,
/// operation, retry provenance, usage or errors can cross this boundary.
public struct TranscriptExport: Equatable, Sendable {
    public enum Content: String, CaseIterable, Sendable {
        case original = "Original", result = "Result"
    }
    public enum Format: String, CaseIterable, Sendable {
        case text = "Plain text", markdown = "Markdown"
        public var fileExtension: String { self == .text ? "txt" : "md" }
        public func suggestedFilename(now: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return "parla-transcripts-\(formatter.string(from: now)).\(fileExtension)"
        }
    }
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let date: Date
        public let appLabel: String?
        public init(text: String, date: Date, appLabel: String? = nil) {
            self.text = text; self.date = date; self.appLabel = appLabel
        }
    }
    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    public func encoded(content: Content, format: Format) -> Data {
        let date = ISO8601DateFormatter()
        let sections = entries.enumerated().map { index, entry in
            let metadata = "Entry \(index + 1) · \(date.string(from: entry.date)) · \(content.rawValue)"
            let app = entry.appLabel.map { "App: " + Self.metadata($0, markdown: format == .markdown) }
            switch format {
            case .text:
                return ([metadata] + (app.map { [$0] } ?? [])).joined(separator: "\n")
                    + "\n\n" + entry.text + "\n"
            case .markdown:
                // A fence longer than every source run cannot be closed by any
                // transcript line, including headings and embedded code blocks.
                let longest = entry.text.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" })
                    .map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                return "## " + metadata + "\n" + (app.map { "\n" + $0 + "\n" } ?? "")
                    + "\n" + fence + "text\n" + entry.text
                    + (entry.text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
            }
        }
        return Data(sections.joined(separator: format == .text ? "\n--------\n\n" : "\n---\n\n").utf8)
    }

    private static func metadata(_ value: String, markdown: Bool) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 10: return "\\n"
            case 13: return "\\r"
            case 9: return "\\t"
            case 0...31, 127, 0x85, 0x2028, 0x2029: return " "
            default:
                let punctuation = (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
                    || (91...96).contains(scalar.value) || (123...126).contains(scalar.value)
                return (markdown && punctuation ? "\\" : "") + String(scalar)
            }
        }.joined()
    }
}
