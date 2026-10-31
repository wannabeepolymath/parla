import Foundation

public struct GuidedTemplateFailure: Error, LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct GuidedTemplateField: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var key: String
    public var label: String
    public var required: Bool
    public init(id: UUID = UUID(), key: String, label: String, required: Bool = true) {
        self.id = id; self.key = key; self.label = label; self.required = required
    }
}

public struct GuidedTemplateDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var revision: UUID
    public var name: String
    public var body: String
    public var fields: [GuidedTemplateField]
    public init(id: UUID = UUID(), revision: UUID = UUID(), name: String, body: String, fields: [GuidedTemplateField]) {
        self.id = id; self.revision = revision; self.name = name; self.body = body; self.fields = fields
    }
    public func compiled() throws -> GuidedTemplateProgram {
        guard Self.text(name, limit: 120), body.utf8.count <= 8_192, (1...12).contains(fields.count),
              Set(fields.map(\.id)).count == fields.count, Set(fields.map(\.key)).count == fields.count,
              fields.allSatisfy({ Self.key($0.key) && Self.text($0.label, limit: 160) }) else {
            throw GuidedTemplateFailure("Invalid template name, fields or size.")
        }
        return try GuidedTemplateProgram(body: body, fields: fields)
    }
    static func text(_ text: String, limit: Int) -> Bool {
        text.utf8.count <= limit && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func key(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...32).contains(bytes.count) && (97...122).contains(bytes[0])
            && bytes.dropFirst().allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}

public struct GuidedTemplateDocument: Codable, Equatable, Sendable {
    public var format = "parla-guided-templates"
    public var schemaVersion = 1
    public var definitions: [GuidedTemplateDefinition] = []
    public init(definitions: [GuidedTemplateDefinition] = []) { self.definitions = definitions }
    public func validate() throws {
        guard format == "parla-guided-templates", schemaVersion == 1, definitions.count <= 32,
              Set(definitions.map(\.id)).count == definitions.count else { throw GuidedTemplateFailure("Unsupported or invalid template document.") }
        for definition in definitions { _ = try definition.compiled() }
        guard try JSONEncoder().encode(self).count <= 262_144 else { throw GuidedTemplateFailure("Template document exceeds 262,144 bytes.") }
    }
}

/// Compiles only original UTF-8; values are appended verbatim and never reparsed.
public struct GuidedTemplateProgram: Equatable, Sendable {
    public enum Segment: Equatable, Sendable { case literal(String), field(UUID) }
    public let segments: [Segment]
    init(body: String, fields: [GuidedTemplateField]) throws {
        let bytes = Array(body.utf8), keys = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.id) })
        var index = 0, literal: [UInt8] = [], result: [Segment] = [], used: Set<UUID> = [], occurrences = 0
        func matches(_ text: String) -> Bool { bytes[index...].starts(with: text.utf8) }
        func flush() { if !literal.isEmpty { result.append(.literal(String(decoding: literal, as: UTF8.self))); literal.removeAll(keepingCapacity: true) } }
        while index < bytes.count {
            if matches("{{{{") { literal += [123,123]; index += 4 }
            else if matches("}}}}") { literal += [125,125]; index += 4 }
            else if matches("{{") {
                flush(); index += 2
                let start = index
                while index < bytes.count, bytes[index] != 123, bytes[index] != 125 { index += 1 }
                guard index < bytes.count, bytes[index...].starts(with: "}}".utf8) else { throw GuidedTemplateFailure("Unmatched or nested template token.") }
                let key = String(decoding: bytes[start..<index], as: UTF8.self)
                guard GuidedTemplateDefinition.key(key), let id = keys[key] else { throw GuidedTemplateFailure("Unknown or malformed template key.") }
                guard index + 2 == bytes.count || bytes[index + 2] != 125 else { throw GuidedTemplateFailure("Triple closing delimiter is invalid.") }
                index += 2; occurrences += 1
                guard occurrences <= 64 else { throw GuidedTemplateFailure("At most 64 placeholders are supported.") }
                result.append(.field(id)); used.insert(id)
            } else if matches("}}") { throw GuidedTemplateFailure("Unmatched closing template delimiter.") }
            else { literal.append(bytes[index]); index += 1 }
        }
        flush()
        guard used == Set(fields.map(\.id)) else { throw GuidedTemplateFailure("Every field must be referenced by its exact key.") }
        segments = result
    }
    public func render(_ values: [UUID: String]) throws -> String {
        var output = "", count = 0
        for segment in segments {
            let text: String
            switch segment {
            case .literal(let value): text = value
            case .field(let id):
                guard let value = values[id] else { throw GuidedTemplateFailure("Accept or explicitly skip every field.") }
                text = value
            }
            guard text.utf8.count <= 65_536 - count else { throw GuidedTemplateFailure("Completed form exceeds 65,536 bytes.") }
            count += text.utf8.count; output.append(text)
        }
        guard GuidedTemplateDefinition.text(output, limit: 65_536) else { throw GuidedTemplateFailure("Completed form is empty.") }
        return output
    }
}
